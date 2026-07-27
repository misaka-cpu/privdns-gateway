#!/usr/bin/env python3
"""紧急完整恢复(break-glass)—— 复用受控 Bash `pdg rollback --dir`, 但保住救援入口。

与"恢复受管配置"(cfgrestore)是**两件不同的事**, 页面上也分开:
  · 配置恢复: 只换 pdgtx 白名单里的配置, 有 before-image、失败自动回滚;
  · 完整恢复: 换整份快照(二进制 / Bot 程序 / platform / backend / bot.env / WLOC / unit),
    **没有 pdgtx 的二次自动回滚** —— 出事只能靠操作前那份 pre-rescue 快照或 SSH。

对现有 Bash 路径逐行审查后的结论(不改恢复系统本身, 只在外面加保护):
  1. 解包只覆盖清单内成员(tar -T), **不删除**快照里没有的文件 —— 所以旧快照不会"删掉"救援
     平面; 但**新快照**里带着旧的救援凭据/代码, 恢复时会**覆盖**它们, 用户当场失联;
  2. 恢复末尾会 `nft -f /etc/nftables.conf`, 而快照里的那份没有救援端口放行 —— 端口被切断;
  3. 它明确重启的是 mosdns / mihomo / pdg-bot / pdg-probe81 (+pdg-mitm), **不含救援服务**;
  4. `_lock` 认 PDG_LOCKED —— 于是 pre-rescue 快照与恢复可以在**同一把锁**下完成, 不必改它;
  5. 中途失败没有二次回滚, 只打印"可能已部分恢复"。
所以这里的职责是: 锁内复核 → 备份救援控制平面 → pre-rescue 快照 → 固定 argv 调用 → 逐项
复原被覆盖的救援文件 → 补回救援端口放行 → 生成**受控的结构化结果** → 写唯一一条脱敏审计。
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/pdg-bot")
import pdgtx  # noqa: E402
import rescue_const as C  # noqa: E402

PDG_BIN = "/usr/local/bin/pdg"          # 固定绝对路径, 不查 PATH
MAX_CAPTURE = 64 * 1024                 # 子进程输出上限: 只留末尾摘要, 不让它撑爆内存
RESTORE_TIMEOUT = int(os.environ.get("PDG_BREAKGLASS_TIMEOUT", "1800"))
MIN_FREE_MB = 200                       # 低于这个可用空间不开始(解包 + pre-rescue 快照要地方)


def _protected_paths():
    """**固定**的受保护路径白名单: 救援控制平面自身。

    绝不由请求决定 —— 那等于让调用方指定"这次恢复不要覆盖哪些文件"。清单只含:
    救援服务代码与启动所需的最小 helper、凭据、unit。事务核心 pdgtx 与配置恢复 helper
    cfgrestore **不在其中**: 它们是业务侧的恢复目标, 保护它们等于让回滚回不干净; 它们缺失
    时救援服务照样能起来(状态页可用, 恢复类功能会如实说明不可用)。"""
    p = C.paths()
    here = os.path.dirname(os.path.abspath(__file__))
    out = [p["PDG_RESCUE_TOKEN"], p["PDG_RESCUE_CERT"], p["PDG_RESCUE_KEY"]]
    # 跟随事务核心的沙箱根: 用例与 E2E 把整棵树挪了根, 写死绝对路径会让"保护"保护到宿主上
    # 的另一份文件去, 而沙箱里的那份照样被覆盖(第一版就是这样漏的)。
    installed = pdgtx.FSROOT + "/opt/pdg-bot"
    for name in ("rescue.py", "rescue_const.py", "rescue.sh"):
        out.append(os.path.join(installed, name))
        out.append(os.path.join(here, name))
    unit_dir = os.environ.get("PDG_UNIT_DIR", pdgtx.FSROOT + "/etc/systemd/system")
    out.append(os.path.join(unit_dir, "pdg-rescue.socket"))
    out.append(os.path.join(unit_dir, "pdg-rescue.service"))
    seen, uniq = set(), []
    for x in out:
        r = os.path.realpath(x) if os.path.exists(x) else x
        if r not in seen:
            seen.add(r)
            uniq.append(x)
    return tuple(uniq)


class _Guard:
    """把受保护文件抄一份到 0700 的保管区, 恢复完再逐项比对复原。"""

    def __init__(self, paths):
        self.dir = tempfile.mkdtemp(prefix="pdg-rescue-guard.")
        os.chmod(self.dir, 0o700)
        self.saved = {}                 # path -> (副本路径 or None(当时不存在), mode, uid, gid)
        for i, p in enumerate(paths):
            if not os.path.isfile(p):
                self.saved[p] = (None, None, None, None)
                continue
            st = os.stat(p)
            cp = os.path.join(self.dir, "%03d" % i)
            shutil.copy2(p, cp)
            os.chmod(cp, 0o600)
            self.saved[p] = (cp, st.st_mode & 0o777, st.st_uid, st.st_gid)

    def restore_changed(self):
        """返回 (被复原的路径列表, 失败项列表)。只动**内容确实变了或被删了**的。"""
        fixed, failed = [], []
        for p, (cp, mode, uid, gid) in self.saved.items():
            try:
                if cp is None:
                    continue            # 操作前本来就没有: 不去创造它
                cur = None
                if os.path.isfile(p):
                    with open(p, "rb") as f:
                        cur = f.read()
                with open(cp, "rb") as f:
                    want = f.read()
                if cur == want:
                    continue
                os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
                pdgtx.atomic_write(p, want, mode or 0o600, uid, gid)
                fixed.append(os.path.basename(p))
            except Exception as e:  # noqa: BLE001
                failed.append("%s(%s)" % (os.path.basename(p), type(e).__name__))
        return fixed, failed

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def _tail(text, n=2000):
    """只留末尾摘要并脱敏 —— 子进程输出既可能很大, 也可能带着配置片段。"""
    t = (text or "")[-n:]
    return pdgtx.redact(t)


def _free_mb(path):
    try:
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize // (1024 * 1024)
    except OSError:
        return 0


def _nft_bin():
    try:
        sys.path.insert(0, "/opt/pdg-bot")
        import nftscan
        return nftscan.nft_bin()
    except Exception:  # noqa: BLE001
        return shutil.which("nft") or ""


def _rescue_port_open():
    """运行中的规则里还有救援端口的放行吗? 读不到返回 None(说不清就别乱改)。"""
    exe = _nft_bin()
    if not exe:
        return None
    rc, out = _run([exe, "list", "chain", "inet", "pdg", "input"], timeout=15)
    if rc != 0 or not out:
        return None
    return re.search(r"dport[^\n]*\b%d\b" % C.port(), out) is not None


def _reopen_rescue_port(cidr):
    """把救援端口的放行加回运行中的规则。只加**一条**明确的规则, 不重写用户的防火墙。"""
    exe = _nft_bin()
    if not exe or not cidr:
        return False, "找不到 nft 或内网卡段"
    rc, out = _run([exe, "insert", "rule", "inet", "pdg", "input",
                    "ip", "saddr", cidr, "tcp", "dport", str(C.port()), "accept"], timeout=20)
    if rc != 0:
        return False, _tail(out, 200)
    return True, ""


def _run(argv, timeout=60, env=None, cwd=None):
    """固定 argv 数组执行, **绝不** shell=True / bash -c 拼接。输出截断。"""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, env=env, cwd=cwd)
        out = (p.stdout or b"")[-MAX_CAPTURE:].decode("utf-8", "replace")
        return p.returncode, out
    except subprocess.TimeoutExpired:
        return 124, "超时(%ds)" % timeout
    except OSError as e:
        return 127, "%s: %s" % (type(e).__name__, e)


def _child_env():
    """子进程的最小环境: 不带 Cookie / CSRF / 会话 / Token, 只留跑得起来所需的。
    PDG_LOCKED=1 告诉 pdg 侧"锁已经由调用方持有" —— 于是 pre-rescue 快照与恢复在**同一把
    锁**下完成, 中间没有别的进程插进来的空隙。"""
    keep = ("PATH", "LANG", "LC_ALL", "TERM", "HOME", "PDG_TX_FSROOT", "PDG_TX_ROOT",
            "PDG_LOCKFILE", "PDG_CORE_BINDIR", "PDG_SNAP_DIR", "REPO_DIR", "PDG_STABLE_SAMPLES",
            "PDG_STABLE_INTERVAL", "PDG_UNIT_DIR")
    env = {k: v for k, v in os.environ.items()
           if k in keep or k.startswith("PDG_STUB_")}      # PDG_STUB_* 只在测试沙箱里存在
    env.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    env["PDG_LOCKED"] = "1"
    env["PDG_NONINTERACTIVE"] = "1"
    return env


def _pdg_path():
    return os.environ.get("PDG_BIN", PDG_BIN)


class _GlobalLock:
    """与 pdgtx / pdg 用同一把 flock。拿不到就是 BUSY —— 不排队。"""

    def __init__(self):
        self.f = None

    def __enter__(self):
        path = pdgtx.LOCKFILE
        os.makedirs(os.path.dirname(path) or "/", exist_ok=True)
        self.f = open(path, "w")
        try:
            fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.f.close()
            self.f = None
            raise pdgtx.TxBusy("已有配置操作正在执行")
        return self

    def __exit__(self, *exc):
        if self.f:
            try:
                fcntl.flock(self.f, fcntl.LOCK_UN)
            finally:
                self.f.close()
                self.f = None
        return False


def _result(snapshot_id, **kw):
    """**受控**的结构化结果: 字段固定, 值由本模块生成, 不放配置正文与子进程原始输出。"""
    out = {"operation": "full_breakglass_restore", "snapshot_id": snapshot_id,
           "pre_rescue_snapshot_id": "", "restored": [], "failed": [], "skipped": [],
           "protected": [], "validation": {}, "final_state": "", "error_class": "",
           "audit_warning": "", "detail": ""}
    out.update(kw)
    return out


def _snapshot_ids(cr):
    return cr.snapshot_ids()


def run(snapshot_id, *, expect_digest="", trigger_source="rescue", cfgrestore=None):
    """执行一次紧急完整恢复。返回受控结构化结果(不抛异常给 HTTP 层)。"""
    cr = cfgrestore
    if cr is None:
        import cfgrestore as cr  # noqa: F811
    t0 = time.time()
    res = _result(snapshot_id)
    if snapshot_id not in _snapshot_ids(cr):
        res.update(final_state="REFUSED", error_class="UNKNOWN_SNAPSHOT",
                   detail="快照不存在或不在服务端索引里")
        return res
    try:
        lock = _GlobalLock()
        lock.__enter__()
    except pdgtx.TxBusy:
        res.update(final_state="BUSY", error_class="BUSY", detail="已有配置操作正在执行")
        return res
    guard = None
    try:
        # ── 锁内复核: 路径、摘要、pending、磁盘 ──────────────────────────────
        path = cr.snapshot_path(snapshot_id)
        if not path:
            res.update(final_state="REFUSED", error_class="UNSAFE_SNAPSHOT",
                       detail="快照路径不安全(软链/越界)")
            return res
        st = os.stat(path)
        if expect_digest and cr.snapshot_digest(snapshot_id) != expect_digest:
            res.update(final_state="REFUSED", error_class="DIGEST_MISMATCH",
                       detail="快照内容在确认之后发生了变化, 已中止")
            return res
        if st.st_uid != 0 and os.geteuid() == 0:
            res.update(final_state="REFUSED", error_class="UNSAFE_SNAPSHOT",
                       detail="快照属主不是 root")
            return res
        if st.st_mode & 0o022:
            res.update(final_state="REFUSED", error_class="UNSAFE_SNAPSHOT",
                       detail="快照文件对组/其它用户可写")
            return res
        fmt_members, err = cr.list_members(snapshot_id)
        if err:
            res.update(final_state="REFUSED", error_class="UNREADABLE_SNAPSHOT", detail=err)
            return res
        fmt = cr.snap_format(fmt_members)
        if fmt not in ("v1.6", "legacy-dnsdist"):
            res.update(final_state="REFUSED", error_class="UNKNOWN_FORMAT",
                       detail="快照结构无法识别(%s), 拒绝执行" % fmt)
            return res
        try:
            pend = pdgtx.pending_recovery()
        except Exception:  # noqa: BLE001
            pend = []
            res["audit_warning"] = "读不到事务目录, 未能确认是否有未完成事务"
        if pend:
            res.update(final_state="REFUSED", error_class="PENDING_TX",
                       detail="有 %d 笔未完成的配置事务, 请先逐笔处理" % len(pend))
            return res
        if _free_mb(pdgtx.FSROOT + "/var/lib") < MIN_FREE_MB:
            res.update(final_state="REFUSED", error_class="NO_SPACE",
                       detail="可用磁盘不足 %d MB, 拒绝执行" % MIN_FREE_MB)
            return res

        # ── pre-rescue 快照: 失败即拒绝(Web 第一版不提供强制跳过)──────────────
        rc, out = _run([_pdg_path(), "snapshot"], timeout=900, env=_child_env())
        pre_id = ""
        m = re.search(r"backups/([0-9]{8}-[0-9]{6})/snap\.tar\.gz", out or "")
        if m:
            pre_id = m.group(1)
        if rc != 0 or not pre_id or not cr.snapshot_path(pre_id):
            res.update(final_state="REFUSED", error_class="PRE_SNAPSHOT_FAILED",
                       detail="操作前快照没做成, 拒绝执行完整恢复(%s)" % _tail(out, 200))
            return res
        res["pre_rescue_snapshot_id"] = pre_id

        # ── 保护救援控制平面 ────────────────────────────────────────────────
        protected = _protected_paths()
        guard = _Guard(protected)
        res["protected"] = [os.path.basename(p) for p in protected]
        port_before = _rescue_port_open()

        # ── 固定 argv 调用受控 Bash 恢复 ────────────────────────────────────
        snap_dir = os.path.dirname(path)
        rc, out = _run([_pdg_path(), "rollback", "--dir", snap_dir],
                       timeout=RESTORE_TIMEOUT, env=_child_env())
        res["detail"] = _tail(out)

        # ── 复原被覆盖的救援文件 + 补回端口放行 ─────────────────────────────
        fixed, gfailed = guard.restore_changed()
        res["restored"] = ["(见 pdg rollback 输出摘要)"] if rc == 0 else []
        if fixed:
            res["skipped"] = []
        res["validation"]["rescue_files_reprotected"] = fixed
        if gfailed:
            res["failed"] += ["救援文件复原失败: " + x for x in gfailed]
        port_after = _rescue_port_open()
        res["validation"]["rescue_port_before"] = port_before
        res["validation"]["rescue_port_after"] = port_after
        if port_before and port_after is False:
            cidr = C.internal_cidr()
            good, why = _reopen_rescue_port(cidr)
            res["validation"]["rescue_port_reopened"] = good
            if not good:
                res["failed"].append("救援端口放行未能补回(%s)" % why)
        # 救援服务不该被这次恢复停掉/重启
        res["validation"]["rescue_service_untouched"] = _rescue_untouched(out)
        res["validation"]["kernel"] = _svc_state("mihomo")
        res["validation"]["dns"] = _svc_state("mosdns")

        if rc == 0 and not res["failed"]:
            res["final_state"] = "RESTORED"
        elif rc == 0:
            res["final_state"] = "RESTORED_WITH_ISSUES"
            res["error_class"] = "PROTECTION_REPAIR_FAILED"
        else:
            res["final_state"] = "PARTIAL_OR_FAILED"
            res["error_class"] = "ROLLBACK_RC_%d" % rc
            res["failed"].append("pdg rollback 退出码 %d" % rc)
        return res
    finally:
        if guard is not None:
            guard.close()
        try:
            _audit(res, t0, trigger_source)
        except Exception as e:  # noqa: BLE001
            res["audit_warning"] = "审计写入失败(%s)" % type(e).__name__
        lock.__exit__()


def _rescue_untouched(out):
    """Bash 恢复的输出里不该出现对救援 unit 的 stop/restart。它明确重启的是
    mosdns/mihomo/pdg-bot/pdg-probe81(+pdg-mitm), 这里再兜一道。"""
    return not re.search(r"(restart|stop)\s+pdg-rescue", out or "")


def _svc_state(unit):
    rc, out = _run(["systemctl", "is-active", unit], timeout=15)
    return (out or "").strip() or ("未知" if rc == 127 else "inactive")


def _audit(res, t0, trigger_source):
    """唯一一条审计, 走 5.1 的受控入口(原子写 + 轮转 + 脱敏)。只记标量与计数。"""
    pdgtx.audit_event(
        "rescue", "full_breakglass_restore", res.get("final_state") or "UNKNOWN",
        {"event": "full_breakglass_restore", "trigger_source": trigger_source,
         "snapshot": res.get("snapshot_id", ""),
         "pre_rescue_snapshot": res.get("pre_rescue_snapshot_id", ""),
         "started_at": t0, "ended_at": time.time(),
         "restored_count": len(res.get("restored") or []),
         "failed_count": len(res.get("failed") or []),
         "protected_count": len(res.get("protected") or []),
         "error_class": res.get("error_class", ""),
         "audit_warning": res.get("audit_warning", "")})
