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


def _protected_members():
    """固定的受保护**成员名**(相对快照根)。单一来源是 lib/rescue.sh —— bash 侧的
    --preserve-rescue 读的是同一份, 不存在"两边各保护一半"的可能。"""
    return C.protected_members()


def _protected_paths():
    """受保护成员 → 本机绝对路径(跟随沙箱根)。仅用于**校验**"它们确实没被动过"。"""
    root = pdgtx.FSROOT
    return tuple(os.path.join(root, m) for m in _protected_members())


class _Witness:
    """受保护文件的**见证者**: 只记指纹, 不做备份恢复。

    保护本身由 Bash 侧的 --preserve-rescue **事前排除**完成 —— 那才是"从未被覆盖"。这里的
    职责是事后如实回答"到底有没有被动过": 如果指纹变了, 说明保护漏了, 那是必须报出来的缺陷,
    而不是悄悄补回来了事(补回来的那一瞬之前, 盘上已经是旧凭据了)。"""

    def __init__(self, paths):
        self.marks = {}
        for p in paths:
            try:
                with open(p, "rb") as f:
                    self.marks[p] = pdgtx._sha(f.read())
            except OSError:
                self.marks[p] = None            # 当时就不存在

    def violations(self):
        out = []
        for p, want in self.marks.items():
            try:
                with open(p, "rb") as f:
                    cur = pdgtx._sha(f.read())
            except OSError:
                cur = None
            if cur != want:
                out.append(os.path.basename(p))
            elif want is None and os.path.exists(p):
                out.append(os.path.basename(p))
        return out


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
        # 保护模式是**前置条件**: 装的 pdg 不支持它就别开始 —— 连 pre-rescue 快照都不该打,
        # 那只会在拒绝之前白占一份磁盘。
        if not _supports_preserve():
            res.update(final_state="REFUSED", error_class="NO_PRESERVE_MODE",
                       detail="已安装的 pdg 不支持 --preserve-rescue, 拒绝从 Web 执行完整恢复"
                              "(否则救援入口会被旧快照覆盖)。请用 SSH 处理。")
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

        # ── 救援平面: **事前排除**(由 Bash 侧的固定保护模式做), 这里只做见证与校验 ──
        protected = _protected_paths()
        witness = _Witness(protected)
        res["protected"] = list(_protected_members())
        port_before = _rescue_port_open()

        # ── 固定 argv 调用受控 Bash 恢复(带固定保护模式)────────────────────
        snap_dir = os.path.dirname(path)
        rc, out = _run([_pdg_path(), "rollback", "--dir", snap_dir, "--preserve-rescue"],
                       timeout=RESTORE_TIMEOUT, env=_child_env())
        res["detail"] = _tail(out)

        # ── 校验: 受保护文件必须**从未被动过**; 动了就是缺陷, 如实报告 ──────
        violations = witness.violations()
        res["validation"]["protected_intact"] = not violations
        if violations:
            res["failed"].append("受保护的救援文件被改动了: " + "、".join(violations))
            res["error_class"] = res["error_class"] or "PROTECTION_VIOLATED"
        res["restored"] = ["(见 pdg rollback 输出摘要)"] if rc == 0 else []
        port_after = _rescue_port_open()
        res["validation"]["rescue_port_before"] = port_before
        res["validation"]["rescue_port_after"] = port_after
        res["validation"]["nft_applies"] = _count_nft_applies(out)
        if port_before and port_after is False:
            # 到这一步还没有放行, 说明候选注入失败了 —— 报出来, 不再"事后补一条"掩盖它
            res["failed"].append("恢复后运行态缺少救援端口放行(候选注入未生效)")
            res["error_class"] = res["error_class"] or "RESCUE_PORT_LOST"
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
        try:
            _audit(res, t0, trigger_source)
        except Exception as e:  # noqa: BLE001
            res["audit_warning"] = "审计写入失败(%s)" % type(e).__name__
        lock.__exit__()


def _supports_preserve():
    """已安装的 pdg 支不支持固定保护模式。不支持就**不允许**从 Web 执行完整恢复 ——
    那等于让用户点一个会把自己锁在门外的按钮。"""
    p = _pdg_path()
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return "--preserve-rescue" in f.read()
    except OSError:
        return False


def _count_nft_applies(out):
    """恢复过程里真正执行了几次 `nft -f`。期望恰好 1 次(候选已含救援放行, 不需要补第二次)。"""
    return len(re.findall(r"\bnft -f\b", out or ""))


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
