#!/usr/bin/env python3
"""统一配置事务核心(5.1)—— CLI / Bot / 更新器 / 定时任务共用的**同一套**写入语义。

为什么要有它: v1.6.2 之前每条写路径各自实现"备份→写→重启→出事再还原"。同一台机器上因此
存在七八套语义不一的局部事务: 有的不上跨进程锁, 有的重启完连 is-active 都不查, 有的把内核
配置与 mosdns 规则分两步落盘 —— 于是"规则写进去了但 DNS 侧没劫持"这类**看着成功、实际半套**
的状态没人拦得住, 事后也查不出是谁改的。

本模块把这件事收敛成一条流水线, 任何入口都必须走完:

    BEGIN → 事务 ID → 全局锁 → 基线 → 候选 → 脱敏差异 → 前置检查 → 校验 →
    before-image → 原子落盘 → 服务动作 → 观察 → COMMIT / ROLLBACK → 审计

硬纪律:
  · 调用方**只能给逻辑目标名**(白名单), 不能给任意路径; 服务动作与校验器同样是白名单;
  · 校验没过之前, 现网一个字节都不动;
  · 回滚要么完整(并**验证**到位), 要么如实报 ROLLBACK_FAILED 并保留恢复材料;
  · 锁拿不到就退出, 锁不可用就**拒绝写**(fail-closed), 绝不退化成"没锁也写";
  · 元数据 / 差异 / 审计 / 日志一律脱敏, token、密码、UUID、节点链接、secret 不落盘。

不引入数据库、消息队列、常驻进程或任何第三方依赖 —— 纯标准库。
"""

import errno
import fcntl
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

SCHEMA_VERSION = 1

# 测试用的根前缀: 白名单结构不变, 只是整棵树挂到沙箱里。调用方**不能**用它逃出白名单 ——
# 它只在进程环境里生效, 且对所有目标一视同仁。
FSROOT = os.environ.get("PDG_TX_FSROOT", "")
TX_ROOT = os.environ.get("PDG_TX_ROOT", FSROOT + "/var/lib/privdns-gateway/tx")
LOCKFILE = os.environ.get("PDG_LOCKFILE", FSROOT + "/run/privdns-gateway.lock")
AUDIT = os.path.join(TX_ROOT, "index.jsonl")
AUDIT_MAX_LINES = int(os.environ.get("PDG_TX_AUDIT_LINES", "500"))
AUDIT_MAX_BYTES = int(os.environ.get("PDG_TX_AUDIT_BYTES", str(512 * 1024)))
TX_KEEP = int(os.environ.get("PDG_TX_KEEP", "20"))
# 硬门探针的落点。**判据本身不可关闭**, 只有落点可配 —— 沙箱测试要能起真的 socket 来验证
# 这条门确实在工作(而不是给测试开一个"跳过健康检查"的后门)。
DNS_PROBE = os.environ.get("PDG_TX_DNS_PROBE", "127.0.0.1:53")
REDIR_PROBE = int(os.environ.get("PDG_TX_REDIR_PORT", "7893"))
DOT_PROBE = int(os.environ.get("PDG_TX_DOT_PORT", "853"))      # DoT 入口: 手机就靠它进来

# ── 状态机 ────────────────────────────────────────────────────────────────────
# ABORTED = 还没碰现网就结束(前置/校验/基线不过, 或 PREPARING/VALIDATED 阶段被中断)。
# 它与 ROLLED_BACK 必须分开: 前者"什么都没发生", 后者"改过又还原了", 排障时含义完全不同。
PREPARING = "PREPARING"
VALIDATED = "VALIDATED"
APPLYING = "APPLYING"
OBSERVING = "OBSERVING"
COMMITTED = "COMMITTED"
ROLLING_BACK = "ROLLING_BACK"
ROLLED_BACK = "ROLLED_BACK"
ROLLBACK_FAILED = "ROLLBACK_FAILED"
ABORTED = "ABORTED"

# 可以被 GC 回收的**明确终态**: 事情已经了结, 材料也清过了。
# ROLLBACK_FAILED 不在其中 —— 它的恢复材料还留着给人工修复用。
GC_TERMINAL = (COMMITTED, ROLLED_BACK, ABORTED)
TERMINAL = (COMMITTED, ROLLED_BACK, ROLLBACK_FAILED, ABORTED)
# 中断在这些状态 = 现网**已经**被改过, 必须先 recover 才允许下一次写。
# OBSERVING 同样在内: 那时文件已全部落盘、服务动作也做完了, 只是还没判定成不成功 ——
# 此刻断电与停在 APPLYING 没有本质区别, 现网都处在"新配置已生效但没人确认过"的状态。
NEEDS_RECOVERY = (APPLYING, OBSERVING, ROLLING_BACK, ROLLBACK_FAILED)

_ALLOWED = {
    PREPARING: (VALIDATED, ABORTED),
    VALIDATED: (APPLYING, ABORTED),
    APPLYING: (OBSERVING, ROLLING_BACK),
    OBSERVING: (COMMITTED, ROLLING_BACK),
    ROLLING_BACK: (ROLLED_BACK, ROLLBACK_FAILED),
    COMMITTED: (), ROLLED_BACK: (), ROLLBACK_FAILED: (), ABORTED: (),
}


_UNSET = object()          # 与 expect=None("当时这个文件不存在")区分开


class TxBusy(Exception):
    """锁被别人占着 —— 调用方应立即友好返回, 不要排队。"""


class TxRefused(Exception):
    """还没动现网就拒绝(前置检查/校验/基线)。现网保证零改动。"""


class TxError(Exception):
    """事务内部错误(状态机非法跳转、白名单越界等)。"""


# ── 目标白名单 ────────────────────────────────────────────────────────────────
# 每项: 逻辑名 → (相对路径, mode, 是否含凭据, 默认校验器)
# 动态名(mosdns_rule:x / ruleset:x / unit:x)另有正则约束, 见 resolve_target。
_STATIC = {
    "model":          ("/etc/sing-box/config.json", 0o600, True, ("json_model",)),
    "mihomo_cfg":     ("/etc/mihomo/config.yaml", 0o600, True, ("mihomo_check",)),
    "mosdns_conf":    ("/etc/mosdns/config.yaml", 0o644, False, ("mosdns_probe",)),
    "rs_meta":        ("/opt/pdg-bot/rulesets.json", 0o644, False, ("json_any",)),
    "profile_env":    ("/etc/privdns-gateway/profile.env", 0o600, False, ("kv_env",)),
    "nftables_conf":  ("/etc/nftables.conf", 0o644, False, ("nft_check",)),
    "mitm_json":      ("/etc/privdns-gateway/mitm.json", 0o600, False, ("json_any",)),
    "mitm_hijack":    ("/etc/mosdns/rules/mitm_hijack.txt", 0o644, False, ("mosdns_lines",)),
    "sysctl_tfo":     ("/etc/sysctl.d/99-pdg-tfo.conf", 0o644, False, ("kv_env",)),
    "dot_marker":     ("/opt/pdg-bot/dot-domain", 0o644, False, ("hostname_line",)),
    "cert_fullchain": ("/etc/mosdns/certs/fullchain.pem", 0o644, False, ("pem_cert",)),
    "cert_privkey":   ("/etc/mosdns/certs/privkey.pem", 0o600, True, ("pem_key",)),
}
_MOSDNS_RULE_RE = re.compile(r"^[A-Za-z0-9_!.-]+\.txt$")
_RULESET_RE = re.compile(r"^[A-Za-z0-9_.-]+\.(json|mrs)$")
_UNIT_RE = re.compile(r"^[A-Za-z0-9_.@-]+\.(service|timer)$")

# 目标 → 该目标牵动哪个服务(决定基线范围、观察范围)
_TARGET_SVC = {
    "model": "mihomo", "mihomo_cfg": "mihomo", "rs_meta": "mihomo",
    "mosdns_conf": "mosdns", "mitm_hijack": "mosdns",
    "cert_fullchain": "mosdns", "cert_privkey": "mosdns",
    "mitm_json": "pdg-mitm",
}

_SERVICE_UNITS = ("mosdns", "mihomo", "pdg-mitm", "pdg-bot", "pdg-probe81")
# 只有 pdg-mitm 需要"目标态": WLOC 开 = 让它跑起来(操作前通常没在跑), 关 = 让它停下。
# 不给 mosdns/mihomo 开 start/stop —— 那两个在本项目里永远应该是 active, 给它们加"停"
# 这种能力只会让某天写错的事务把 DNS 停掉。
_STATE_UNITS = ("pdg-mitm",)
_ACTIONS = tuple(["restart:" + u for u in _SERVICE_UNITS] +
                 ["start:" + u for u in _STATE_UNITS] +
                 ["stop:" + u for u in _STATE_UNITS] +
                 ["daemon-reload", "nft:apply", "sysctl:apply"])


# ── 目标 → 服务动作(**唯一**一份)────────────────────────────────────────────
# 恢复类操作以前固定发 restart:mihomo + restart:mosdns, 于是"只换了一份规则集元数据"也要把
# DNS 和内核一起重启一遍: 无谓的服务中断, 而且只要那两个里有一个本来就坏着, 一次本可以安全
# 完成的元数据恢复就失败了。动作必须从**这次真正变了的目标**推出来。
#
# 判据按真实依赖, 不按名字猜:
#   · rs_meta 是 bot 的标签/计数元数据, 内核读的是 ruleset:* 里的**内容** → 自己不触发重启;
#   · profile_env / dot_marker 是持久化意图与续期提示, 不被运行中的服务直接读 → 无动作;
#   · 证书与 mitm_hijack 由 mosdns 读(DoT 与劫持表) → mosdns;
#   · nftables_conf 只需要重新应用防火墙, 不该顺手重启 mihomo/mosdns;
#   · unit:* 改的是 systemd 单元文件 → daemon-reload。
_TARGET_ACTIONS = {
    "model": ("restart:mihomo",),
    "mihomo_cfg": ("restart:mihomo",),
    "mosdns_conf": ("restart:mosdns",),
    "mitm_hijack": ("restart:mosdns",),
    "cert_fullchain": ("restart:mosdns",),
    "cert_privkey": ("restart:mosdns",),
    "nftables_conf": ("nft:apply",),
    "sysctl_tfo": ("sysctl:apply",),
    "rs_meta": (),
    "profile_env": (),
    "dot_marker": (),
}
_PREFIX_ACTIONS = (("mosdns_rule:", ("restart:mosdns",)),
                   ("ruleset:", ("restart:mihomo",)),
                   ("unit:", ("daemon-reload",)))
# 动作取决于"要开还是要关"、通用推导给不出答案的目标: 必须由调用方显式声明。
# mitm_json 就是这一类 —— WLOC 打开时要 start:pdg-mitm, 关闭时要 stop:pdg-mitm, 光看文件
# 本身推不出来。这里 fail-closed, 不许猜(猜错就是把用户刚关掉的 MITM 又拉起来)。
EXPLICIT_ONLY = frozenset({"mitm_json"})
# 固定执行顺序(可测试): 先把防火墙/内核参数落到位, 再 reload 单元, 最后重启服务(DNS 先于内核)。
_ACTION_ORDER = ("nft:apply", "sysctl:apply", "daemon-reload",
                 "restart:mosdns", "restart:mihomo", "restart:pdg-mitm")


def actions_for_targets(names):
    """一组**确实变了的**目标 → 去重、定序的服务动作。

    未知目标或"没有明确动作语义"的目标一律抛 TxError(fail-closed)—— 默认把所有服务重启一遍
    只会把问题盖住: 出事时谁也说不清那次重启到底是不是必要的。"""
    want = set()
    for n in sorted(set(names)):
        resolve_target(n)          # 名字合法性用**白名单本身**判(ruleset:../x 之流在这里就出局)
        if n in EXPLICIT_ONLY:
            raise TxError("目标 %s 的服务动作取决于目标状态, 必须由调用方显式声明" % n)
        if n in _TARGET_ACTIONS:
            want.update(_TARGET_ACTIONS[n])
            continue
        for pfx, acts in _PREFIX_ACTIONS:
            if n.startswith(pfx):
                want.update(acts)
                break
        else:
            raise TxError("不知道目标 %s 变更后该做什么服务动作, 拒绝执行" % n)
    unknown = want - set(_ACTION_ORDER)
    if unknown:
        raise TxError("动作表里出现了未排序的动作: %s" % ", ".join(sorted(unknown)))
    return tuple(a for a in _ACTION_ORDER if a in want)


def expected_states(actions):
    """本笔事务对各 unit 的**期望终态**, 只由显式动作决定(没写动作的 unit 不在其中)。"""
    exp = {}
    for a in actions:
        verb, _, unit = a.partition(":")
        if verb in ("restart", "start"):
            exp[unit] = "active"
        elif verb == "stop":
            exp[unit] = "inactive"
    return exp


def action_conflicts(actions):
    """同一个 unit 上互相矛盾的动作(restart 又 stop 之类)。返回冲突说明列表, 空 = 没问题。"""
    seen = {}
    for a in actions:
        verb, _, unit = a.partition(":")
        if verb not in ("restart", "start", "stop"):
            continue
        want = "inactive" if verb == "stop" else "active"
        if unit in seen and seen[unit][1] != want:
            return ["%s 上同时要求 %s 和 %s —— 期望终态自相矛盾"
                    % (unit, seen[unit][0], a)]
        seen[unit] = (a, want)
    return []


# 证书目录允许自定义(PDG_CERT_DIR), 但**只认项目自己的可信配置**, 不接受调用方传路径 ——
# 白名单的意义就在于目标集合由项目决定。取值顺序: profile.env → 环境变量 → 默认。
# 任何一条不满足"绝对路径 + 无软链成分"就退回默认目录, 而不是照单全收。
_CERT_DIR_DEFAULT = "/etc/mosdns/certs"


def _trusted_cert_dir():
    val = ""
    try:
        with open(FSROOT + "/etc/privdns-gateway/profile.env", encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if ln.startswith("PDG_CERT_DIR="):
                    val = ln.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    val = val or os.environ.get("PDG_CERT_DIR", "")
    if not val:
        return _CERT_DIR_DEFAULT
    if not val.startswith("/") or val.rstrip("/") != os.path.normpath(val).rstrip("/"):
        return _CERT_DIR_DEFAULT                      # 相对路径 / 含 .. → 不认
    real = os.path.realpath(FSROOT + val)
    if real != os.path.normpath(FSROOT + val):        # 路径里有软链成分 → 不认
        return _CERT_DIR_DEFAULT
    return val.rstrip("/")


def resolve_target(name):
    """逻辑名 → (绝对路径, mode, secret, 校验器)。越界一律抛错。"""
    if name in ("cert_fullchain", "cert_privkey"):
        leaf = "fullchain.pem" if name == "cert_fullchain" else "privkey.pem"
        mode = 0o644 if name == "cert_fullchain" else 0o600
        val = ("pem_cert",) if name == "cert_fullchain" else ("pem_key",)
        return (FSROOT + _trusted_cert_dir() + "/" + leaf, mode,
                name == "cert_privkey", val)
    if name in _STATIC:
        rel, mode, secret, val = _STATIC[name]
        return FSROOT + rel, mode, secret, val
    for pfx, rex, base, mode, val in (
            ("mosdns_rule:", _MOSDNS_RULE_RE, "/etc/mosdns/rules/", 0o644, ("mosdns_lines",)),
            ("ruleset:", _RULESET_RE, "/etc/sing-box/rs/", 0o644, ("ruleset_format",)),
            ("unit:", _UNIT_RE, "/etc/systemd/system/", 0o644, ("systemd_unit",))):
        if name.startswith(pfx):
            leaf = name[len(pfx):]
            if not rex.match(leaf) or "/" in leaf or leaf.startswith("."):
                raise TxError("目标名不合法: %s" % name)
            return FSROOT + base + leaf, mode, False, val
    raise TxError("不在白名单里的目标: %s" % name)


def target_service(name):
    if name in _TARGET_SVC:
        return _TARGET_SVC[name]
    if name.startswith("mosdns_rule:"):
        return "mosdns"
    if name.startswith("ruleset:"):
        return "mihomo"
    return None


# ── 脱敏 ──────────────────────────────────────────────────────────────────────
_SECRET_PATTERNS = [
    (re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{30,}\b"), "<token>"),                 # TG bot token
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"\b[0-9a-fA-F]{32,}\b"), "<hex>"),                              # secret/hash 串
    (re.compile(r"(?i)\b(vmess|vless|trojan|ss|ssr|hysteria2?|tuic|anytls)://\S+"), "<link>"),
    (re.compile(r"(?i)(password|passwd|secret|token|uuid|psk|private[-_]?key)"
                r"\s*[:=]\s*\"?[^\s\"',}]+"), r"\1=<redacted>"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
     "<private-key>"),
    (re.compile(r"(?i)https?://[^\s\"']*[?&](secret|token|key)=[^\s\"'&]+"), "<url-with-secret>"),
]


def redact(s):
    """任何要落盘/回给用户的文本都先过这里。宁可多打码, 也不让凭据进日志。"""
    if s is None:
        return ""
    out = str(s)
    for rex, rep in _SECRET_PATTERNS:
        out = rex.sub(rep, out)
    return out


# ── 原子写 ────────────────────────────────────────────────────────────────────
def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path, data, mode=0o600, uid=None, gid=None):
    """写临时文件 → fsync → replace → fsync 父目录。断电时要么旧的要么新的, 没有半个。"""
    d = os.path.dirname(path) or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".pdgtx.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        if uid is not None and gid is not None:
            try:
                os.chown(tmp, uid, gid)
            except OSError:
                pass
        os.replace(tmp, path)
        _fsync_dir(d)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _read_target(path):
    """读现网文件。返回 (bytes 或 None, stat 或 None)。拒绝符号链接/硬链接目标。"""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.ENOTDIR):
            return None, None
        if e.errno == errno.ELOOP:
            raise TxError("目标是符号链接, 拒绝写入: %s" % path)
        raise
    try:
        st = os.fstat(fd)
        if st.st_nlink > 1:
            raise TxError("目标是硬链接(nlink=%d), 拒绝写入: %s" % (st.st_nlink, path))
        with os.fdopen(fd, "rb") as f:
            return f.read(), st
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


# ── 服务与健康 ────────────────────────────────────────────────────────────────
def _run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout or ""
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "%s: %s" % (type(e).__name__, e)


def _svc_prop_ex(unit, prop):
    """返回 (值, 查询是否成功)。**空字符串是合法值**(某些属性确实为空), 与"命令失败"必须分开 ——
    混在一起会让"查不到"被当成"没有", 于是回滚复核悄悄跳过。"""
    rc, out = _run(["systemctl", "show", "-p", prop, "--value", unit], timeout=15)
    return (out.strip(), rc == 0)


def _svc_prop(unit, prop):
    return _svc_prop_ex(unit, prop)[0]


def _svc_active(unit):
    rc, out = _run(["systemctl", "is-active", unit], timeout=15)
    return out.strip() == "active"


def _stable_interval(interval):
    if interval is not None:
        return interval
    try:
        return float(os.environ.get("PDG_STABLE_INTERVAL", "0.6"))
    except ValueError:
        return 0.6


def svc_stable(unit, samples=None, interval=None, max_polls=15):
    """稳定 active 判据 —— **CLI 与 Bot 从此共用这一份**:
    连续 N 次 is-active 都是 active, 且观察窗口内 NRestarts 没有增长。
    只看一次 is-active 会把"起来即崩"判成成功: 崩溃循环里总有那么一瞬是 active。"""
    n = samples if samples is not None else int(os.environ.get("PDG_STABLE_SAMPLES", "3"))
    interval = _stable_interval(interval)
    r0 = _svc_prop(unit, "NRestarts") or "0"
    streak = 0
    for _ in range(max_polls):
        if _svc_active(unit):
            streak += 1
            if streak >= n:
                break
        else:
            streak = 0
        time.sleep(interval)
    if streak < n:
        return False, "%s 没有稳定 active" % unit
    r1 = _svc_prop(unit, "NRestarts") or "0"
    try:
        if int(r1) > int(r0):
            return False, "%s 在观察窗口内重启了(NRestarts %s→%s), 判为起来即崩" % (unit, r0, r1)
    except ValueError:
        pass
    return True, ""


def svc_inactive_stable(unit, samples=None, interval=None, max_polls=15):
    """稳定 inactive 判据 —— 与 svc_stable 对称, 供 stop:<unit> 使用。

    必须看 ActiveState 而不是 `is-active` 的真假: failed / activating / deactivating / unknown
    都"不是 active", 但它们都**不等于我们把它停下来了** —— 尤其 failed, 那是它自己死了。
    连续 N 次都明确 inactive 才算数, 免得把"停下来又被 systemd 拉起"判成成功。"""
    n = samples if samples is not None else int(os.environ.get("PDG_STABLE_SAMPLES", "3"))
    interval = _stable_interval(interval)
    streak, last = 0, ""
    for _ in range(max_polls):
        st = (_svc_prop(unit, "ActiveState") or "unknown").strip() or "unknown"
        last = st
        if st == "inactive":
            streak += 1
            if streak >= n:
                return True, ""
        else:
            streak = 0
        time.sleep(interval)
    return False, "%s 没有稳定 inactive(ActiveState=%s)" % (unit, last)


def _dns_answers(host="127.0.0.1", port=53, timeout=2.0):
    """本机 DNS 是否在应答(不看答案内容, 也不需要公网)。"""
    q = (b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
         b"\x07example\x03com\x00\x00\x01\x00\x01")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(q, (host, port))
        data, _ = s.recvfrom(512)
        return len(data) >= 12 and data[:2] == b"\x12\x34"
    except OSError:
        return False
    finally:
        s.close()


def _tcp_listening(port, host="127.0.0.1", timeout=1.5):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        return s.connect_ex((host, port)) == 0
    except OSError:
        return False
    finally:
        s.close()


def health_snapshot(services, relax_units=()):
    """本次事务**范围内**的硬门指标。与公网无关 —— 出口探测那类属软门, 不在这里。

    relax_units: 本笔事务显式给了 start:/stop: 的 unit。它们的 active 与否由"期望终态"单独判
    (见 Tx._observe), 不进这份快照 —— 否则"开启 WLOC"这种操作前 pdg-mitm 本来就没在跑的场景,
    会在基线阶段被判成"操作前硬门就是坏的"而根本开不了事务。**只放宽这一个 unit 的 active 检查**,
    DNS / DoT / redir 端口以及其它服务一条都不放宽。"""
    h = {}
    for u in sorted(set(services)):
        if u in relax_units:
            continue
        if u == "pdg-mitm" and not _svc_prop(u, "LoadState") == "loaded":
            continue
        h["svc:" + u] = _svc_active(u)
    if "mosdns" in services:
        host, _, port = DNS_PROBE.partition(":")
        h["dns:" + DNS_PROBE] = _dns_answers(host, int(port or 53))
        # DoT(853)是手机端唯一的入口: mosdns 起来了但 853 没在听, 对用户等于全断 ——
        # 这条必须进硬门。仍是本机端口检查, 与公网连通性无关(那类只做软门)。
        h["port:%d" % DOT_PROBE] = _tcp_listening(DOT_PROBE)
    if "mihomo" in services:
        h["port:%d" % REDIR_PROBE] = _tcp_listening(REDIR_PROBE)
    return h


# ── 校验器 ────────────────────────────────────────────────────────────────────
def _v_json_any(path, data, ctx):
    try:
        json.loads(data.decode("utf-8"))
    except Exception as e:  # noqa: BLE001
        return False, "不是合法 JSON: %s" % type(e).__name__
    return True, ""


def _v_json_model(path, data, ctx):
    ok, err = _v_json_any(path, data, ctx)
    if not ok:
        return ok, err
    doc = json.loads(data.decode("utf-8"))
    if not isinstance(doc, dict) or "outbounds" not in doc or "route" not in doc:
        return False, "config.json 缺 outbounds/route, 不像本项目的数据模型"
    return True, ""


def _v_mihomo_check(path, data, ctx):
    """对**候选**文件跑真 mihomo -t(不是对现网)。"""
    exe = shutil.which("mihomo") or (FSROOT + "/usr/local/bin/mihomo")
    if not os.access(exe, os.X_OK):
        return False, "找不到 mihomo, 无法校验候选配置"
    d = tempfile.mkdtemp(prefix="pdgtx-mihomo.")
    try:
        cand = os.path.join(d, "config.yaml")
        atomic_write(cand, data, 0o600)
        rc, out = _run([exe, "-t", "-d", FSROOT + "/etc/mihomo", "-f", cand], timeout=60)
        return (rc == 0), ("" if rc == 0 else redact(out[-400:]))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _v_nft_check(path, data, ctx):
    d = tempfile.mkdtemp(prefix="pdgtx-nft.")
    try:
        cand = os.path.join(d, "nftables.conf")
        atomic_write(cand, data, 0o644)
        exe = _nft_bin()
        if not exe:
            return False, "机器上找不到 nft, 无法校验防火墙候选配置"
        rc, out = _run([exe, "-c", "-f", cand], timeout=30)
        return (rc == 0), ("" if rc == 0 else redact(out[-300:]))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _nft_bin():
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import nftscan
        return nftscan.nft_bin()
    except Exception:  # noqa: BLE001
        return shutil.which("nft") or ""


_MOSDNS_LINE = re.compile(r"^(#.*|\s*|(domain|full|keyword|regexp):\S+|[A-Za-z0-9_.*-]+)$")


def _v_mosdns_lines(path, data, ctx):
    """domain/规则文件的严格行级格式校验。

    这**不是** mosdns 完整配置强校验 —— 它只保证这类文件里不会混进 mosdns 加载不了的行;
    真正的门是落盘后 mosdns 能否稳定起来(见观察期)。事务报告里会如实标成 line-format。"""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return False, "不是 UTF-8 文本"
    for i, ln in enumerate(text.splitlines(), 1):
        if not _MOSDNS_LINE.match(ln.strip()):
            return False, "第 %d 行不是合法的 mosdns 域名条目: %r" % (i, ln[:60])
    return True, ""


def _v_ruleset_format(path, data, ctx):
    if path.endswith(".mrs"):
        if not data[:8].startswith(b"MRS") and b"MRS" not in data[:64]:
            return False, ".mrs 文件头不像 mihomo 原生规则集"
        return True, ""
    return _v_json_any(path, data, ctx)


def _v_kv_env(path, data, ctx):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return False, "不是 UTF-8 文本"
    for i, ln in enumerate(text.splitlines(), 1):
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s or s.startswith("="):
            return False, "第 %d 行不是 KEY=VALUE" % i
    return True, ""


def _v_hostname_line(path, data, ctx):
    s = data.decode("utf-8", "replace").strip()
    if not re.match(r"^(?=.{1,253}$)([a-z0-9-]+\.)+[a-z]{2,}$", s):
        return False, "不是合法域名"
    return True, ""


def _v_pem_cert(path, data, ctx):
    if b"-----BEGIN CERTIFICATE-----" not in data:
        return False, "不是 PEM 证书"
    d = tempfile.mkdtemp(prefix="pdgtx-pem.")
    try:
        p = os.path.join(d, "c.pem")
        atomic_write(p, data, 0o600)
        rc, out = _run(["openssl", "x509", "-noout", "-in", p], timeout=15)
        if rc == 127:
            return True, ""                      # 没有 openssl: 退到头部判据, 不假装强校验
        return (rc == 0), ("" if rc == 0 else "openssl 认为证书不合法")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _v_pem_key(path, data, ctx):
    if b"PRIVATE KEY-----" not in data:
        return False, "不是 PEM 私钥"
    d = tempfile.mkdtemp(prefix="pdgtx-key.")
    try:
        p = os.path.join(d, "k.pem")
        atomic_write(p, data, 0o600)
        rc, out = _run(["openssl", "pkey", "-noout", "-in", p], timeout=15)
        if rc == 127:
            return True, ""
        return (rc == 0), ("" if rc == 0 else "openssl 认为私钥不合法")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _v_systemd_unit(path, data, ctx):
    text = data.decode("utf-8", "replace")
    if "[Unit]" not in text or not ("[Service]" in text or "[Timer]" in text):
        return False, "unit 缺 [Unit]/[Service]|[Timer] 段"
    return True, ""


# ── mosdns 候选配置的强校验 ────────────────────────────────────────────────────
# mosdns v5.3.4 **没有** validate/dry-run 子命令(实测: 只有 config gen|conv), 而坏配置
# `mosdns start` 会立刻 FATAL 退出、好配置会常驻并占用配置里写的端口。所以强校验只能"真起
# 一个探针":
#   1) 首选 unshare -n: 独立网络命名空间里起 lo, 端口与生产完全隔离, 配置原样不动;
#   2) 退而求其次: 把候选**副本**里本项目已知形态的监听地址改到 127.0.0.1 的随机高端口再起;
#   3) 两条都不可用 → 拒绝应用(不拿结构检查冒充强校验)。
_LISTEN_RE = re.compile(rb"(?m)^(\s*(?:addr|listen)\s*:\s*)([\"']?)([^\"'\s#]+)\2")
NETNS_MARK = "PDGTX_NETNS_READY"      # 证明"已经进了命名空间, 马上要 exec mosdns"


def _mosdns_bin():
    return shutil.which("mosdns") or (FSROOT + "/usr/local/bin/mosdns")


def _mosdns_probe_run(cmd, timeout, workdir, marker=None):
    """跑探针。返回 (结果, 说明):

      True  = 熬过观察窗口 → 候选配置能起来;
      False = mosdns **确实**起了又提前退出 → 候选配置有问题;
      None  = 探针本身没跑起来(命名空间没权限、命令缺失…)→ **基础设施不可用**, 不是候选的错。

    区分后两者靠 marker: 它在真正 exec mosdns **之前**打印。输出里没有 marker, 说明连
    mosdns 都没执行到 —— 那时把候选判成"配置有错"是冤枉它, 而 auto 模式还应该退到备用探针。"""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             universal_newlines=True, cwd=workdir)
    except OSError as e:
        return None, "探针无法启动: %s" % type(e).__name__
    t0 = time.time()
    while time.time() - t0 < timeout:
        if p.poll() is not None:
            out = p.stdout.read() if p.stdout else ""
            txt = redact((out or "").strip()[-400:])
            if marker and marker not in (out or ""):
                return None, txt or "探针环境不可用(未执行到 mosdns)"
            return False, txt or "mosdns 提前退出"
        time.sleep(0.2)
    p.terminate()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
    return True, ""


def _v_mosdns_probe(path, data, ctx):
    exe = _mosdns_bin()
    if not os.access(exe, os.X_OK):
        return False, "找不到 mosdns 二进制, 无法对候选配置做强校验"
    wait = float(os.environ.get("PDG_TX_MOSDNS_PROBE_SECS", "3"))
    d = tempfile.mkdtemp(prefix="pdgtx-mosdns.")
    try:
        # 探针工作目录要能读到 rules/ 等相对资源。这里**不能**直接软链现网的 rules 目录:
        # 同一笔事务如果也在改规则文件(恢复备份就是典型 —— mosdns 配置与 custom_direct/
        # custom_hijack 一起换), 那样探针验的是"新配置 + 旧规则", 通过了也不代表候选整体成立。
        # 所以逐个文件软链现网内容, 再用**本事务的候选**覆盖同名文件(候选是删除的就不放)。
        cand = os.path.join(d, "config.yaml")
        atomic_write(cand, data, 0o600)
        live_rules = FSROOT + "/etc/mosdns/rules"
        probe_rules = os.path.join(d, "rules")
        try:
            os.makedirs(probe_rules, exist_ok=True)
            if os.path.isdir(live_rules):
                for leaf in os.listdir(live_rules):
                    src = os.path.join(live_rules, leaf)
                    if os.path.isfile(src):
                        os.symlink(src, os.path.join(probe_rules, leaf))
            for name, t in sorted(getattr(ctx, "targets", {}).items() if ctx else []):
                if not (name.startswith("mosdns_rule:") or name == "mitm_hijack"):
                    continue
                leaf = os.path.basename(t["path"])
                dst = os.path.join(probe_rules, leaf)
                if os.path.islink(dst) or os.path.exists(dst):
                    os.unlink(dst)
                if t["data"] is not None:                # None = 本次要删掉它 → 探针里也不该有
                    atomic_write(dst, t["data"], 0o644)
        except OSError:
            pass
        mode = os.environ.get("PDG_TX_MOSDNS_PROBE_MODE", "auto")
        if mode in ("auto", "netns") and shutil.which("unshare"):
            # marker 在 exec mosdns 之前打印: 没有它 = 连命名空间都没进去(容器缺 CAP_SYS_ADMIN
            # 是最常见的情况), 属基础设施不可用, 不能算候选配置有错。
            # `ip link set lo up`(有 iproute2 时)保证 127.0.0.1 可绑; 没有 ip 命令也先试一把
            inner = ("ip link set lo up 2>/dev/null; echo %s; exec %s start -c %s -d %s"
                     % (NETNS_MARK, exe, cand, d))
            ok, err = _mosdns_probe_run(["unshare", "-n", "-r", "bash", "-c", inner], wait, d,
                                        marker=NETNS_MARK)
            if ok is not None:
                return ok, (err and ("netns 探针: " + err))
            if mode == "netns":
                return False, "netns 不可用(%s)" % (err or "无权限")[:80]
            # auto: netns 用不了 → 退到高端口探针(下面), 但**不放宽判据**
        if mode in ("auto", "port"):
            # 备用: 只改副本里的监听地址(生产文件不动), 换到随机高端口再起
            patched, n = _rewrite_listen(data)
            if n == 0:
                return False, "无法安全改写候选里的监听地址(非本项目已知形态), 拒绝在生产端口上做探针"
            cand2 = os.path.join(d, "config-probe.yaml")
            atomic_write(cand2, patched, 0o600)
            ok, err = _mosdns_probe_run([exe, "start", "-c", cand2, "-d", d], wait, d)
            if ok is not None:
                return ok, (err and ("高端口探针: " + err))
        return False, "两种强校验方式(netns / 高端口)都不可用 —— 拒绝应用 mosdns 配置"
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _rewrite_listen(data):
    """把候选副本里的监听地址改到 127.0.0.1 随机高端口。返回 (新内容, 改写条数)。"""
    used = []

    def _pick():
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.close()
        used.append(p)
        return p

    def _sub(m):
        val = m.group(3).decode()
        if not re.match(r"^([0-9.]*|\[?::\]?)?:\d+$", val) and not val.startswith(":"):
            return m.group(0)
        return b"%s%s127.0.0.1:%d%s" % (m.group(1), m.group(2), _pick(), m.group(2))

    out, n = _LISTEN_RE.subn(_sub, data)
    return out, n


VALIDATORS = {
    "json_any": _v_json_any, "json_model": _v_json_model, "mihomo_check": _v_mihomo_check,
    "nft_check": _v_nft_check, "mosdns_lines": _v_mosdns_lines, "mosdns_probe": _v_mosdns_probe,
    "ruleset_format": _v_ruleset_format, "kv_env": _v_kv_env, "hostname_line": _v_hostname_line,
    "pem_cert": _v_pem_cert, "pem_key": _v_pem_key, "systemd_unit": _v_systemd_unit,
}
# 只做行级格式校验的目标: 报告里要标出来, 不能说成完整配置强校验
LINE_LEVEL_ONLY = ("mosdns_lines", "kv_env", "hostname_line")


# ── 全局锁(fail-closed)────────────────────────────────────────────────────────
class _Lock:
    """整笔事务持有同一把跨进程锁。拿不到 → TxBusy; **打不开锁文件 → TxRefused**。

    以前 CLI 与 Bot 在锁文件不可用时都会"退化成没有跨进程锁继续写"。那正是最危险的时候:
    /run 有问题往往意味着系统本身不正常, 而此刻两个进程同时改配置没有任何东西拦得住。"""

    def __init__(self, path=None):
        self.path = path or LOCKFILE
        self.f = None

    def __enter__(self):
        d = os.path.dirname(self.path) or "/"
        try:
            os.makedirs(d, exist_ok=True)
            self.f = open(self.path, "w")
        except OSError as e:
            raise TxRefused("锁文件不可用(%s: %s) —— 为避免并发写坏配置, 本次拒绝执行"
                            % (self.path, e.__class__.__name__))
        try:
            fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.f.close(); self.f = None
            raise TxBusy("已有配置操作正在执行")
        return self

    def __exit__(self, *exc):
        if self.f:
            try:
                fcntl.flock(self.f, fcntl.LOCK_UN)
            except OSError:
                pass
            self.f.close()
            self.f = None
        return False


# ── 事务 ──────────────────────────────────────────────────────────────────────
def _ensure_root(root):
    """事务根目录本身也要 0700 —— 只把 txid 子目录收紧, 上层仍是 755 的话, 目录名(操作类型、
    时间)照样是公开的。"""
    try:
        os.makedirs(root, mode=0o700, exist_ok=True)
        if (os.stat(root).st_mode & 0o777) != 0o700:
            os.chmod(root, 0o700)
    except OSError:
        pass


def new_txid():
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8]


def _runner_sha():
    try:
        with open(os.path.abspath(__file__), "rb") as f:
            return _sha(f.read())
    except OSError:
        return ""


def _restore_runtime(bi):
    """把运行时状态按 before-image 还原, 并**逐项验证到位**。返回未恢复项列表(空=全好)。

    以前这几步的返回码一律不看: sysctl -w 失败、nft -f 报错、systemctl stop 没停下来, 都会
    被当成"已还原", 最后打上 ROLLED_BACK —— 文件是回去了, 运行时却没有, 而用户以为全好了。
    普通回滚与 recover 现在共用这一份判据, 免得两条路各说各话。"""
    failed = []
    for key, val in (bi.get("sysctl") or {}).items():
        if not val:
            continue
        rc, out = _run(["sysctl", "-w", "%s=%s" % (key, val)], timeout=15)
        if rc != 0:
            failed.append("sysctl %s 写回失败(%s)" % (key, redact(out)[-60:])); continue
        rc2, cur = _run(["sysctl", "-n", key], timeout=15)          # 复读比对, 不信写入回执
        if rc2 != 0 or cur.strip() != str(val).strip():
            failed.append("sysctl %s 实际值是 %r(期望 %r)" % (key, cur.strip(), val))
    if bi.get("nft_loaded"):
        exe = _nft_bin()
        if not exe:
            failed.append("找不到 nft, 无法确认防火墙已还原")
        else:
            rc, out = _run([exe, "-f", FSROOT + "/etc/nftables.conf"], timeout=60)
            if rc != 0:
                failed.append("nft -f 还原失败(%s)" % redact(out)[-60:])
            elif _run([exe, "list", "table", "inet", "pdg"], timeout=15)[0] != 0:
                failed.append("inet pdg 表没有回到内核")
    for u, st in (bi.get("services") or {}).items():
        if st.get("active"):
            _run(["systemctl", "reset-failed", u], timeout=30)
            rc, out = _run(["systemctl", "restart", u], timeout=120)
            if rc != 0:
                failed.append("%s 重启失败(%s)" % (u, redact(out)[-60:])); continue
            ok, why = svc_stable(u)
            if not ok:
                failed.append(why)
        else:
            # 原来没在跑的必须**明确停稳**: 判据与 stop:<unit> 完全一致(连续采样 ActiveState
            # 为 inactive)。只看"不是 active"会把 failed / activating / deactivating 当成
            # "停好了" —— failed 尤其危险, 那是它自己死了, 不是我们把它停下的。
            rc, out = _run(["systemctl", "stop", u], timeout=60)
            if rc != 0:
                failed.append("%s 停止失败(%s)" % (u, redact(out)[-60:]))
            else:
                ok, why = svc_inactive_stable(u)
                if not ok:
                    failed.append("%s 未能停回操作前的状态: %s" % (u, why))
        # enabled 本事务从不修改(没有 enable/disable 动作), 所以它必须与操作前一致 ——
        # 不一致说明有别的东西动过 unit。**查不到也算没复核到位**: 空字符串以前会让这一步
        # 悄悄跳过, 于是"回滚完成"是猜的。
        # enabled 本事务从不修改, 所以回滚后必须与操作前**完全一致**。这里要分三件事:
        #   · 查询失败 → 没复核到位, 单独记;
        #   · 操作前根本没记过这一项(旧格式 before-image) → 无从比对, 跳过;
        #   · 记过就精确比对 —— **包括合法的空字符串**(以前 `was and …` 会让空值悄悄跳过,
        #     于是"原本为空、回滚后变成 enabled"这种不一致会被当成回滚成功)。
        now, q_ok = _svc_prop_ex(u, "UnitFileState")
        if not q_ok:
            failed.append("%s 的开机自启状态查不到(systemctl 查询失败), 无法复核回滚是否到位" % u)
        elif "enabled" in st:
            was = (st.get("enabled") or "").strip()
            if was != now.strip():
                failed.append("%s 的开机自启状态从 %r 变成了 %r(本事务没改过它)"
                              % (u, was, now.strip()))
    return failed


class Tx:
    """一笔事务。stage/derive/service 之后 commit()。

    mode='normal'   基线里与本次目标相关的硬门必须**先是好的**, 否则拒绝开始 ——
                    在已经坏掉的组件上做普通变更, 出了事根本分不清是谁弄坏的。
    mode='repair'   rollback / restore / recover 这类修复操作: 允许在降级基线上跑,
                    成功判据收窄为"目标服务能起来且不再比操作前更差"。
    """

    def __init__(self, source, op, mode="normal", txid=None, root=None):
        if mode not in ("normal", "repair"):
            raise TxError("mode 只能是 normal / repair")
        self.root = root or TX_ROOT
        self.txid = txid or new_txid()
        self.dir = os.path.join(self.root, self.txid)
        self.source, self.op, self.mode = source, op, mode
        self.state = PREPARING
        self.targets = {}          # name -> {"path","data"(bytes|None),"expect","validators"}
        self.watches = {}          # 只读依赖: name -> {"path","sha256","absent","optional"}
        self.audit_extra = {}      # 调用方补充的**非敏感标量**维度, 并进同一条审计记录
        self._read_sha = {}        # read_for_update 记下的"候选所依据的源内容" sha
        self.derivers = []         # (target, fn)
        self.actions = []
        self.warnings = []
        self.meta = {
            "schema_version": SCHEMA_VERSION, "runner_sha256": _runner_sha(),
            "runner_file": os.path.abspath(__file__),
            "txid": self.txid, "source": source, "op": op, "mode": mode,
            "state": PREPARING, "started_at": time.time(), "ended_at": None,
            "targets": [], "services": [], "validations": [], "baseline": {},
            "observed": {}, "warnings": [], "error": "", "error_class": "",
            "rollback_complete": None, "diff": [],
        }
        _ensure_root(self.root)                      # TX_ROOT 自身也必须 0700
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        os.makedirs(os.path.join(self.dir, "candidate"), mode=0o700, exist_ok=True)
        os.makedirs(os.path.join(self.dir, "before"), mode=0o700, exist_ok=True)
        self._save_meta()

    # ---- 元数据 ----
    def _save_meta(self):
        self.meta["state"] = self.state
        self.meta["warnings"] = [redact(w) for w in self.warnings]
        atomic_write(os.path.join(self.dir, "meta.json"),
                     json.dumps(self.meta, ensure_ascii=False, indent=1).encode(), 0o600)

    def _set_state(self, new):
        if new not in _ALLOWED.get(self.state, ()):
            raise TxError("非法状态跳转: %s → %s" % (self.state, new))
        self.state = new
        self._save_meta()

    # ---- 组装 ----
    def read_for_update(self, target):
        """读一份目标内容**并记住它的 sha**, 供随后 stage 当前置条件。返回 (bytes|None, sha|None)。

        为什么必须有这一步: 调用方的典型形态是"先读现网 → 算出新内容 → stage"。如果 stage
        时才去取当前 sha, 那这中间别人提交的修改就会被当成"前置条件"记下来, 最后被本次候选
        覆盖 —— 丢更新, 而且事后完全看不出来。前置条件要盯的是**生成候选时看到的那一份**。"""
        path, _m, _s, _v = resolve_target(target)
        cur, _st = _read_target(path)
        sha = _sha(cur) if cur is not None else None
        self._read_sha[target] = sha
        return cur, sha

    def watch(self, target, optional=False):
        """登记一个**只读依赖**: 候选是根据它算出来的, 但本次不打算改它。返回它当前的 bytes(或 None)。

        典型场景: mihomo 配置由 model + rs_meta 渲染, 而本次只改 mitm.json —— model/rs_meta
        不该被"假装 stage 一遍再原样写回"(那会凭空产生一次写入、一份 before-image 和一次
        服务牵连)。watch 只记 sha, 在拿到全局锁、动生产文件之前再核对一次: 变了就
        PRECONDITION_FAILED, 生产文件一个字节都不动。

        只接受白名单逻辑目标名(resolve_target 把关), 不接受任意路径; 软链/硬链/穿越的拒绝
        判据与写目标完全一致(走同一个 _read_target)。"""
        if self.state != PREPARING:
            raise TxError("watch 只能在 PREPARING 阶段")
        path, _m, _s, _v = resolve_target(target)
        cur, _st = _read_target(path)
        if cur is None and not optional:
            raise TxRefused("只读依赖 %s 不存在, 无法据它生成候选" % target)
        self.watches[target] = {"path": path, "optional": bool(optional),
                                "sha256": _sha(cur) if cur is not None else None,
                                "absent": cur is None}
        self.meta["watched"] = {n: {"sha256": w["sha256"], "absent": w["absent"],
                                    "optional": w["optional"]}
                                for n, w in sorted(self.watches.items())}
        self._save_meta()
        return cur

    def stage(self, target, data, expect=_UNSET):
        """登记一个目标的候选内容。data=None 表示"这次要把它删掉"。

        expect: 生成该候选时所依据的源内容 sha(None = 当时不存在)。不给就用 read_for_update
        记下的那一份; 都没有才退回"stage 当刻的现网"(适用于内容与旧值无关的整份覆盖)。"""
        if self.state != PREPARING:
            raise TxError("stage 只能在 PREPARING 阶段")
        path, mode, secret, validators = resolve_target(target)
        cur, _st = _read_target(path)
        if data is not None and not isinstance(data, bytes):
            data = str(data).encode("utf-8")
        idx = len(self.targets)
        cpath = os.path.join(self.dir, "candidate", "%02d-%s" % (idx, _safe_leaf(target)))
        if data is not None:
            atomic_write(cpath, data, 0o600)
        if expect is not _UNSET:
            exp = expect
        elif target in self._read_sha:
            exp = self._read_sha[target]
        else:
            exp = _sha(cur) if cur is not None else None
        self.targets[target] = {
            "path": path, "mode": mode, "secret": secret, "validators": list(validators),
            "data": data, "candidate": cpath if data is not None else None,
            "expect": exp,
            "existed": cur is not None,
        }
        self.meta.setdefault("target_paths", {})[target] = path
        return self

    def derive(self, target, fn):
        """由已 stage 的内容派生出另一个目标的候选(如 model → mihomo 渲染)。
        fn 是**Python 可调用对象**, 不是 shell 字符串 —— 事务核心不接受任何形式的命令串。"""
        if not callable(fn):
            raise TxError("deriver 必须是可调用对象")
        resolve_target(target)
        self.derivers.append((target, fn))
        return self

    def service(self, action):
        if action not in _ACTIONS:
            raise TxError("不在白名单里的服务动作: %s" % action)
        if action not in self.actions:
            # 同一个 unit 上"又要它跑又要它停"是组装错误, 现在就拦 —— 拖到执行期才发现,
            # 前一半动作已经真的做了。
            bad = action_conflicts(self.actions + [action])
            if bad:
                raise TxError("服务动作冲突: %s" % "; ".join(bad))
            self.actions.append(action)
        return self

    def warn(self, msg):
        self.warnings.append(redact(msg))
        return self

    # ---- 提交 ----
    def commit(self):
        try:
            with _Lock():
                return self._commit_locked()
        except TxBusy:
            self._abort("锁被占用", "BUSY")
            raise
        except TxRefused as e:
            self._abort(str(e), "REFUSED")
            raise

    def abort_unstarted(self, why="调用方在候选阶段放弃", cls="ABANDONED"):
        """候选阶段就放弃的事务: 转 ABORTED、写脱敏原因、删候选与 before 材料、记一条审计。

        只处理 PREPARING / VALIDATED —— APPLYING / OBSERVING / ROLLING_BACK / ROLLBACK_FAILED
        的材料**必须留给 recover**, 那是现网已经被动过的证据。幂等: 已是终态时什么都不做。
        返回是否真的收尾了。"""
        if self.state not in (PREPARING, VALIDATED):
            return False
        prev = self.state
        try:
            self.meta["error"] = redact(why)[:200]
            self.meta["error_class"] = self.meta.get("error_class") or cls
            self.meta["ended_at"] = time.time()
            self.state = ABORTED
            self._save_meta()
        except Exception:  # noqa: BLE001
            # ABORTED 没落盘 → **不许删证据**: 状态回退成原样, 目录与候选留给 doctor/recover
            # 去看。这里也不能往外抛 —— 调用方的原始异常/返回值优先。
            self.state = prev
            return False
        try:
            self._note_leftovers(self._cleanup_materials())   # ABORTED 落盘成功后才清材料
        except Exception:  # noqa: BLE001
            self.warnings.append("事务材料清理过程本身出错, 材料保留在事务目录")
            self.meta["warnings"] = [redact(w) for w in self.warnings]
        try:
            _audit(self)
        except Exception:  # noqa: BLE001
            pass                            # 审计写不进去不改变业务结果
        return True

    # 用法: `with Tx(...) as t:` —— 候选阶段 return / 抛异常都会自动收尾, 不留 PREPARING 目录
    # 和含凭据的候选文件。SIGKILL 不会走到这里, 那种残留仍由 stale_unstarted / 显式 abort 处理。
    def __enter__(self):
        return self

    def __exit__(self, et, ev, tb):
        # abort_unstarted 自身已是严格 no-throw; 这层 try 是"两条路径语义一致"的保险 ——
        # finally 里直接调它的那些生产入口(tx_apply / _mitm_transact / …)也同样不会被它影响。
        try:
            self.abort_unstarted("候选阶段异常: %s" % et.__name__ if et is not None
                                 else "调用方在候选阶段返回")
        except Exception:  # noqa: BLE001
            pass
        return False

    def _abort(self, why, cls=""):
        if self.state in (PREPARING, VALIDATED):
            self.meta["error"] = redact(why)
            # 已经分好类的(如 PRECONDITION_FAILED)不要被笼统的 REFUSED 盖掉 —— 审计要看得出
            # 到底是"别人先改了"还是"校验没过"。
            self.meta["error_class"] = self.meta.get("error_class") or cls
            self.meta["ended_at"] = time.time()
            self.state = ABORTED
            self._save_meta()
            self._note_leftovers(self._cleanup_materials())
            _audit(self)

    def _commit_locked(self):
        # 0) 上一笔没跑完的事务必须先处理 —— 不静默删证据, 也不在半套状态上继续写
        pend = pending_recovery(self.root, exclude=self.txid)
        if pend:
            raise TxRefused("上一笔事务 %s 停在 %s, 请先 `sudo pdg tx recover %s`"
                            % (pend[0]["txid"], pend[0]["state"], pend[0]["txid"]))
        # 1) 派生候选
        for tgt, fn in self.derivers:
            try:
                data = fn({k: v["data"] for k, v in self.targets.items()})
            except TxRefused:
                raise            # 派生器自己给的拒绝理由是写给用户看的(已脱敏), 原样上报
            except Exception as e:  # noqa: BLE001
                raise TxRefused("生成候选失败(%s): %s" % (tgt, type(e).__name__))
            if data is None:
                raise TxRefused("生成候选失败(%s): 派生器没有产出内容" % tgt)
            self.stage_derived(tgt, data)
        if not self.targets and not self.actions:
            raise TxRefused("这笔事务没有任何目标或服务动作")
        # 冲突动作再拦一次(service() 已拦过): 手工拼 actions 列表的路径也不许溜过去,
        # 而且必须发生在**动生产文件之前**。
        bad_actions = action_conflicts(self.actions)
        if bad_actions:
            self.meta["error_class"] = "ACTION_CONFLICT"
            raise TxRefused("服务动作冲突: %s" % "; ".join(bad_actions))
        services = sorted({s for s in (target_service(t) for t in self.targets) if s} |
                          {a.split(":", 1)[1] for a in self.actions
                           if a.split(":", 1)[0] in ("restart", "start", "stop")})
        self.meta["services"] = services
        self.meta["targets"] = sorted(self.targets)
        exp = expected_states(self.actions)
        self.meta["expected_states"] = exp
        # 显式 start/stop 的 unit: 它操作前是 active 还是 inactive 都不该挡住本次操作,
        # 判据换成"操作后是否达到期望终态"(见 _observe)。只放宽这些 unit 的 active 检查。
        relax = tuple(u for u, w in exp.items() if any(
            a in self.actions for a in ("start:" + u, "stop:" + u)))
        # 2) 基线
        base = health_snapshot(services, relax_units=relax)
        if relax:      # 放宽的那几个 unit 操作前什么样, 仍要留档(审计要看得见)
            self.meta["baseline_relaxed"] = {"svc:" + u: _svc_active(u) for u in relax}
        self.meta["baseline"] = base
        if self.mode == "normal":
            bad = [k for k, v in base.items() if not v]
            if bad:
                raise TxRefused("操作前这些硬门就是坏的: %s —— 普通变更拒绝在已损坏的组件上进行"
                                "(先修好, 或用修复类命令)" % ", ".join(bad))
        # 3) 前置检查: 现网内容必须还是 stage 时看到的那份
        for name, t in self.targets.items():
            cur, _ = _read_target(t["path"])
            if (_sha(cur) if cur is not None else None) != t["expect"]:
                self.meta["error_class"] = "PRECONDITION_FAILED"
                raise TxRefused("PRECONDITION_FAILED: 目标 %s 自本次读取之后被其它进程改过, "
                                "本次不覆盖(请重新读取现网内容后重试)" % name)
        # 3b) 只读依赖也要核对: 候选是按它算出来的, 它变了候选就已经过期(例如 model 换了出口,
        #     而本次要落盘的 mihomo 配置还是按旧 model 渲染的)。同样在动生产文件之前。
        for name, w in sorted(self.watches.items()):
            cur, _ = _read_target(w["path"])
            cur_sha = _sha(cur) if cur is not None else None
            if cur_sha != w["sha256"]:
                self.meta["error_class"] = "PRECONDITION_FAILED"
                raise TxRefused("PRECONDITION_FAILED: 只读依赖 %s 自本次读取之后被改过, "
                                "本次候选已过期(请重新读取现网内容后重试)" % name)
        # 4) 校验全部候选
        for name, t in sorted(self.targets.items()):
            if t["data"] is None:
                self.meta["validations"].append({"target": name, "validator": "delete", "ok": True})
                continue
            for vname in t["validators"]:
                fn = VALIDATORS[vname]
                ok, err = fn(t["path"], t["data"], self)
                self.meta["validations"].append({
                    "target": name, "validator": vname, "ok": bool(ok),
                    "scope": "line-format" if vname in LINE_LEVEL_ONLY else "full",
                    "detail": redact(err)[:300]})
                self._save_meta()
                if not ok:
                    raise TxRefused("候选校验未过(%s / %s): %s" % (name, vname, redact(err)[:300]))
        self.meta["diff"] = self._diff()
        atomic_write(os.path.join(self.dir, "diff.txt"),
                     ("\n".join(self.meta["diff"]) + "\n").encode(), 0o600)
        # 5) before-image
        self._set_state(VALIDATED)
        try:
            self._save_before(services)
        except TxRefused:
            raise                     # 已经带着人话原因(如运行态查不到), 别被下面那句盖掉
        except Exception as e:  # noqa: BLE001
            raise TxRefused("保存 before-image 失败(%s) —— 没有回退材料就不动现网" % type(e).__name__)
        # 6) 落盘 + 服务动作 + 观察
        self._set_state(APPLYING)
        applied = []
        try:
            for name, t in sorted(self.targets.items()):
                self._apply_one(name, t)
                applied.append(name)
            self.meta["applied"] = applied
            self._save_meta()
            err = self._do_actions()
            if err:
                raise _ApplyFailed(err)
            self._set_state(OBSERVING)
            err = self._observe(services, base, exp=exp, relax=relax)
            if err:
                raise _ApplyFailed(err)
        except _ApplyFailed as e:
            return self._rollback(str(e))
        except Exception as e:  # noqa: BLE001
            return self._rollback("应用过程异常(%s)" % type(e).__name__)
        self._set_state(COMMITTED)
        self.meta["ended_at"] = time.time()
        self._save_meta()
        self._note_leftovers(self._cleanup_materials())
        _audit(self)
        _gc(self.root)
        return self.result()

    def stage_derived(self, target, data):
        path, mode, secret, validators = resolve_target(target)
        cur, _ = _read_target(path)
        idx = len(self.targets)
        cpath = os.path.join(self.dir, "candidate", "%02d-%s" % (idx, _safe_leaf(target)))
        atomic_write(cpath, data, 0o600)
        self.targets[target] = {
            "path": path, "mode": mode, "secret": secret, "validators": list(validators),
            "data": data, "candidate": cpath,
            "expect": _sha(cur) if cur is not None else None, "existed": cur is not None,
        }

    # ---- before-image ----
    def _save_before(self, services):
        bi = {"files": {}, "services": {}, "sysctl": {}, "nft_loaded": None}
        for name, t in sorted(self.targets.items()):
            cur, st = _read_target(t["path"])
            rec = {"existed": cur is not None}
            if cur is not None:
                bpath = os.path.join(self.dir, "before", _safe_leaf(name))
                atomic_write(bpath, cur, 0o600)
                rec.update({"file": os.path.basename(bpath), "sha256": _sha(cur),
                            "mode": st.st_mode & 0o7777, "uid": st.st_uid, "gid": st.st_gid})
            bi["files"][name] = rec
        for u in services:
            en, en_ok = _svc_prop_ex(u, "UnitFileState")
            nr, nr_ok = _svc_prop_ex(u, "NRestarts")
            # ActiveState 必须**带返回码**取: _svc_active 走 `is-active`, 它把"查询失败"和
            # "确实没在跑"都变成 False —— 那会把本来 active 的服务记成 inactive, 回滚时反而
            # 把它停掉。查不到就在动生产文件之前拒。
            st, st_ok = _svc_prop_ex(u, "ActiveState")
            if not (en_ok and nr_ok and st_ok):
                raise TxRefused("取不到 %s 的运行态(systemctl 查询失败), before-image 不完整 —— "
                                "拒绝在没有完整回退材料的前提下改动现网" % u)
            st = st.strip()
            if not st:
                raise TxRefused("%s 的 ActiveState 是空的, 无法判定操作前状态 —— "
                                "拒绝在没有完整回退材料的前提下改动现网" % u)
            if st in ("activating", "deactivating", "reloading"):
                # 过渡态下拍的快照不代表任何稳定目标: 回滚该把它起来还是停下都说不清。
                raise TxRefused("%s 正处于 %s(过渡状态), 现在无法确定操作前的稳定状态 —— "
                                "请稍后重试" % (u, st))
            # active 布尔继续保留: 旧恢复记录只有它, _restore_runtime 也仍以它为准
            bi["services"][u] = {"active": st == "active", "active_state": st,
                                 "enabled": en, "nrestarts": nr}
        if "sysctl_tfo" in self.targets or "sysctl:apply" in self.actions:
            rc, out = _run(["sysctl", "-n", "net.ipv4.tcp_fastopen"], timeout=10)
            bi["sysctl"]["net.ipv4.tcp_fastopen"] = out.strip() if rc == 0 else ""
        if "nftables_conf" in self.targets or "nft:apply" in self.actions:
            exe = _nft_bin()
            bi["nft_loaded"] = bool(exe) and _run([exe, "list", "table", "inet", "pdg"],
                                                  timeout=15)[0] == 0
        atomic_write(os.path.join(self.dir, "before", "index.json"),
                     json.dumps(bi, ensure_ascii=False, indent=1).encode(), 0o600)
        self._before = bi
        # **打算写入什么**要在动手之前就落进 meta: 崩在 APPLYING 时, recover 靠它判断
        # "现在盘上的内容是本事务写的(可以安全还原)" 还是 "事务之外有人改过(要停手报冲突)"。
        # 崩溃可能发生在任意一次 replace 前后, 所以这份记录必须**先于**全部落盘写好。
        self.meta["intended_sha"] = {n: (_sha(t["data"]) if t["data"] is not None else None)
                                     for n, t in self.targets.items()}
        self._save_meta()

    # ---- 应用 ----
    def _apply_one(self, name, t):
        if t["data"] is None:
            if t["existed"]:
                os.unlink(t["path"])
                _fsync_dir(os.path.dirname(t["path"]))
            return
        st = self._before["files"].get(name, {})
        atomic_write(t["path"], t["data"], st.get("mode", t["mode"]),
                     st.get("uid"), st.get("gid"))
        t["applied_sha"] = _sha(t["data"])

    def _do_actions(self):
        done = self.meta.setdefault("executed_actions", [])
        for a in self.actions:
            if a == "daemon-reload":
                rc, out = _run(["systemctl", "daemon-reload"], timeout=60)
            elif a == "nft:apply":
                exe = _nft_bin()
                if not exe:
                    return "找不到 nft, 无法应用防火墙配置"
                rc, out = _run([exe, "-f", FSROOT + "/etc/nftables.conf"], timeout=60)
            elif a == "sysctl:apply":
                # 文件不在就"什么也不做还报成功"是假绿: 调用方声明了要应用 sysctl, 文件却没有,
                # 那就是这笔事务组装错了。应用完还要**复读**确认内核里真是这个值。
                f = FSROOT + "/etc/sysctl.d/99-pdg-tfo.conf"
                if not os.path.exists(f):
                    return "sysctl:apply 找不到 %s(本次事务没有 stage 它?)" % f
                rc, out = _run(["sysctl", "-p", f], timeout=30)
                if rc == 0:
                    want = {}
                    with open(f, "rb") as fh:
                        for ln in fh.read().decode("utf-8", "replace").splitlines():
                            ln = ln.split("#", 1)[0].strip()
                            if "=" in ln:
                                k, v = ln.split("=", 1)
                                want[k.strip()] = v.strip()
                    for k, v in want.items():
                        rc2, cur = _run(["sysctl", "-n", k], timeout=15)
                        if rc2 != 0 or cur.strip() != v:
                            return "sysctl %s 应用后实际值是 %r(期望 %r)" % (k, cur.strip(), v)
            elif a.startswith("start:"):
                unit = a.split(":", 1)[1]
                _run(["systemctl", "reset-failed", unit], timeout=30)
                rc, out = _run(["systemctl", "start", unit], timeout=120)
            elif a.startswith("stop:"):
                unit = a.split(":", 1)[1]
                rc, out = _run(["systemctl", "stop", unit], timeout=60)
            else:
                unit = a.split(":", 1)[1]
                _run(["systemctl", "reset-failed", unit], timeout=30)
                rc, out = _run(["systemctl", "restart", unit], timeout=120)
            if rc != 0:
                return "%s 失败: %s" % (a, redact(out)[-200:])
            done.append(a)          # 实际执行成功的动作: 审计要能区分"计划了"与"真做了"
        return ""

    def _observe(self, services, base, exp=None, relax=()):
        """观察期判据。

        两类判据要分开:
          · **显式动作**(restart/start/stop)的 unit → 硬门: 本次事务点名要它变成什么样, 没做到
            就是失败, 不因 repair 放宽(否则"启动 pdg-mitm 失败"也能提交成功);
          · 其余硬门(未点名动作的 unit、DNS、DoT、redir 端口)→ 判据是"不得比操作前更差":
            操作前坏、操作后仍坏 = 记 warning 后放行(这才是 repair 的用处);
            **操作前好、操作后坏 = 一律回滚, normal 与 repair 都一样**。
        旧实现在 repair 模式下把后者也降级成 warning, 于是一次"修复"可以把本来好的 DNS / DoT /
        端口弄坏还照样 COMMITTED —— 那是修复模式最不该有的权力。"""
        exp = exp or {}
        obs = {}
        for u in services:
            want = exp.get(u)
            if want == "inactive":
                ok, why = svc_inactive_stable(u)
            else:
                ok, why = svc_stable(u)
            obs["svc:" + u] = ok
            if ok:
                continue
            if want is None and base.get("svc:" + u) is False:
                # 没点名动作、且操作前就没在跑 → 保留原状并告警, 不算本次造成的退化
                self.warn("svc:%s 在操作前就没在跑, 本次未修复(与本事务无关)" % u)
                continue
            self.meta["observed"] = obs
            return why
        after = health_snapshot(services, relax_units=relax)
        obs.update(after)
        self.meta["observed"] = obs
        self._save_meta()
        for k, v in after.items():
            if v:
                continue
            if not base.get(k, True):
                self.warn("%s 在操作前就是坏的, 本次未修复(与本事务无关)" % k)
                continue
            return "关键链路在本次操作后退化: %s(操作前是好的)" % k
        return ""

    # ---- 回滚 ----
    def _rollback(self, why):
        self.meta["error"] = redact(why)
        self.meta["error_class"] = "APPLY_FAILED"
        self._set_state(ROLLING_BACK)
        failed = []
        bi = getattr(self, "_before", None) or {}
        for name in sorted(self.targets):
            rec = bi.get("files", {}).get(name, {})
            path = self.targets[name]["path"]
            try:
                if rec.get("existed"):
                    with open(os.path.join(self.dir, "before", rec["file"]), "rb") as f:
                        data = f.read()
                    atomic_write(path, data, rec.get("mode", 0o600), rec.get("uid"), rec.get("gid"))
                elif os.path.exists(path):
                    os.unlink(path)                 # 本次新建的文件: 还原 = 删掉
                    _fsync_dir(os.path.dirname(path))
            except Exception as e:  # noqa: BLE001
                failed.append("%s(%s)" % (name, type(e).__name__))
        failed += _restore_runtime(bi)     # 运行时: sysctl / nft / 服务, 逐项验证过才算数
        # 回滚后必须**验证**: 文件逐个比对 + 服务回到原状态
        for name in sorted(self.targets):
            rec = bi.get("files", {}).get(name, {})
            cur, _ = _read_target(self.targets[name]["path"])
            if rec.get("existed"):
                if cur is None or _sha(cur) != rec.get("sha256"):
                    failed.append("%s 内容未还原" % name)
            elif cur is not None:
                failed.append("%s 应删除但仍存在" % name)
        self.meta["rollback_complete"] = not failed
        self.meta["ended_at"] = time.time()
        if failed:
            self.meta["rollback_failed_items"] = [redact(x) for x in failed]
            self._set_state(ROLLBACK_FAILED)
            _audit(self)
            return self.result()
        self._set_state(ROLLED_BACK)
        self._note_leftovers(self._cleanup_materials())
        _audit(self)
        _gc(self.root)
        return self.result()

    # ---- 收尾 ----
    def _cleanup_materials(self):
        """COMMITTED / 已验证的 ROLLED_BACK / ABORTED: 删掉候选与 before 材料。
        **返回没能删掉的材料逻辑名列表**(空 = 干净)。

        它们可能含出口密码、UUID、证书私钥 —— 留在盘上没有意义, 恢复也用不到了。只保留脱敏
        的 meta.json / diff.txt。注意: 这里只是 unlink, **不承诺安全擦除** —— 底层是 SSD/日志
        文件系统时, 数据块可能仍残留在介质上, 这一点不做任何夸大。"""
        if self.state not in (COMMITTED, ROLLED_BACK, ABORTED):
            return []
        left = []
        for sub in ("candidate", "before"):
            p = os.path.join(self.dir, sub)
            try:
                shutil.rmtree(p)          # 不再 ignore_errors: 删不掉必须看得见
            except FileNotFoundError:
                continue
            except Exception:  # noqa: BLE001  只记逻辑名, 不带异常正文(免得漏出路径/内容)
                left.append(sub)
                continue
            if os.path.exists(p):         # 删除"成功"了也要复核: 真没了才算干净
                left.append(sub)
        if left:
            self.meta["leftover_materials"] = left
        return left

    def _note_leftovers(self, left):
        """材料没删干净: 记一条脱敏 warning(内存结果里一定有, 盘上尽力写)。

        绝不改变事务的业务结果 —— 已经 COMMITTED 的操作确实成功了; 但"敏感材料还在盘上"必须
        可观测, 否则就是静默残留(doctor 也会据此点名)。"""
        if not left:
            return
        self.warnings.append("事务材料未能清理: %s —— 请人工删除该事务目录下的对应子目录"
                             % "、".join(left))
        self.meta["warnings"] = [redact(w) for w in self.warnings]
        try:
            self._save_meta()
        except Exception:  # noqa: BLE001  二次落盘失败也不能影响调用方的结果
            pass

    def result(self):
        return {"txid": self.txid, "state": self.state, "op": self.op, "source": self.source,
                "warnings": list(self.meta["warnings"]), "error": self.meta.get("error", ""),
                "targets": sorted(self.targets), "diff": self.meta.get("diff", []),
                "rollback_complete": self.meta.get("rollback_complete"),
                "rollback_failed_items": self.meta.get("rollback_failed_items", []),
                "dir": self.dir}

    def _diff(self):
        """脱敏差异: 只讲"哪个目标、什么动作、大小/行数怎么变、哪些顶层键变了"。
        绝不含值 —— 出口密码、UUID、secret 一律不出现。"""
        out = []
        for name, t in sorted(self.targets.items()):
            cur, _ = _read_target(t["path"])
            if t["data"] is None:
                out.append("删除 %s" % name)
                continue
            if cur is None:
                out.append("新建 %s (%d 字节)" % (name, len(t["data"])))
                continue
            if cur == t["data"]:
                out.append("%s 无变化" % name)
                continue
            d = "%s 修改 (%d→%d 字节, 行 %d→%d)" % (
                name, len(cur), len(t["data"]),
                cur.count(b"\n"), t["data"].count(b"\n"))
            keys = _changed_json_keys(cur, t["data"])
            if keys:
                d += " 顶层键变化: " + ", ".join(keys[:8])
            out.append(d)
        for a in self.actions:
            out.append("服务动作 " + a)
        return [redact(x) for x in out]


class _ApplyFailed(Exception):
    pass


def _changed_json_keys(a, b):
    try:
        da, db = json.loads(a.decode("utf-8")), json.loads(b.decode("utf-8"))
    except Exception:  # noqa: BLE001
        return []
    if not isinstance(da, dict) or not isinstance(db, dict):
        return []
    return sorted({k for k in set(da) | set(db) if da.get(k) != db.get(k)})


def _safe_leaf(name):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name)


# ── 审计 / 清理 / 恢复 ────────────────────────────────────────────────────────
def _audit_rec(rec):
    """把一条已经组装好的脱敏记录写进审计(recover 等非 Tx 路径共用)。"""
    try:
        _ensure_root(os.path.dirname(AUDIT))
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        _rotate_audit()
    except OSError:
        pass


def _audit_write(rec):
    """把一条审计记录追加进审计日志并按需轮转。**审计日志只有这一个写入口**。"""
    line = json.dumps(rec, ensure_ascii=False) + "\n"
    os.makedirs(os.path.dirname(AUDIT), mode=0o700, exist_ok=True)
    with open(AUDIT, "a", encoding="utf-8") as f:
        f.write(line)
    _rotate_audit()


def audit_event(source, op, result, extra=None):
    """给"不是一笔完整事务"的受控写路径留的审计入口(如 WLOC 热切换)。

    格式与事务记录同源(同一个 _audit_write / 同一份日志 / 同样会轮转), 只是没有 txid。
    **extra 只允许放非敏感的结构化标量**(计数、代号、布尔) —— 位置名、经纬度、chat id、token
    一类一律不许进来; 调用方自己负责, 这里再脱敏一次兜底。
    调用方必须已经持有全局配置锁: 审计写入与事务的写入共用同一个文件与轮转逻辑。"""
    rec = {"ts": time.time(), "txid": None, "source": source, "op": op,
           "mode": "hotpath", "state": result, "targets": [], "services": [],
           "error": "", "error_class": "", "rollback_complete": None,
           "warnings": [], "schema_version": SCHEMA_VERSION}
    for k, v in sorted((extra or {}).items()):
        if isinstance(v, (int, float, bool)) or v is None:
            rec[k] = v
        else:
            rec[k] = redact(str(v))[:120]
    _audit_write(rec)


# 一笔事务只写**一条**审计。调用方需要补充维度(如"这次恢复用的是哪份快照")时, 通过
# Tx.audit_extra 挂进来 —— 而不是自己再写一条: 同一次操作在日志里出现两条口径不同的记录,
# 事后没人说得清以哪条为准。
_AUDIT_EXTRA_OK = re.compile(r"^[A-Za-z0-9_]{1,32}$")


def _sanitize_extra(extra):
    """只收**非敏感的结构化标量**: 布尔、整数、短字符串(过脱敏)。列表只收字符串元素并截断。
    键名限定 [A-Za-z0-9_] —— 调用方可控的自由结构不许原样进审计。"""
    out = {}
    for k, v in (extra or {}).items():
        if not isinstance(k, str) or not _AUDIT_EXTRA_OK.match(k):
            continue
        if isinstance(v, bool) or isinstance(v, int):
            out[k] = v
        elif isinstance(v, str):
            out[k] = redact(v)[:120]
        elif isinstance(v, (list, tuple)):
            out[k] = [redact(str(x))[:60] for x in list(v)[:10]]
    return out


def _audit(tx):
    rec = {"ts": time.time(), "txid": tx.txid, "source": tx.source, "op": tx.op,
           "mode": tx.mode, "state": tx.state, "targets": sorted(tx.targets),
           "services": tx.meta.get("services", []), "error": tx.meta.get("error", ""),
           "error_class": tx.meta.get("error_class", ""),
           "rollback_complete": tx.meta.get("rollback_complete"),
           "executed_actions": tx.meta.get("executed_actions", []),
           "warnings": tx.meta.get("warnings", []), "schema_version": SCHEMA_VERSION}
    rec.update(_sanitize_extra(getattr(tx, "audit_extra", None)))
    try:
        _audit_write(rec)
    except OSError:
        pass


def _rotate_audit():
    try:
        if os.path.getsize(AUDIT) <= AUDIT_MAX_BYTES:
            with open(AUDIT, encoding="utf-8") as f:
                lines = f.readlines()
            if len(lines) <= AUDIT_MAX_LINES:
                return
        else:
            with open(AUDIT, encoding="utf-8") as f:
                lines = f.readlines()
        atomic_write(AUDIT, "".join(lines[-AUDIT_MAX_LINES:]).encode(), 0o600)
    except OSError:
        pass


def load_meta(txdir):
    try:
        with open(os.path.join(txdir, "meta.json"), encoding="utf-8") as f:
            return json.load(f)
    except Exception:  # noqa: BLE001
        return None


def list_tx(root=None, limit=20):
    """limit=None = 全部(pending 扫描用)。"""
    root = root or TX_ROOT
    out = []
    try:
        names = sorted(os.listdir(root), reverse=True)
    except OSError:
        return out
    for n in names:
        p = os.path.join(root, n)
        if not os.path.isdir(p):
            continue
        m = load_meta(p)
        if m:
            out.append(m)
        if limit is not None and len(out) >= limit:
            break
    return out


def pending_recovery(root=None, exclude=None):
    """需要人工处理的未完成事务。**扫全部事务目录**, 不设条数上限 ——
    只看最近 N 笔的话, 一台机器攒够 N 笔新事务之后, 那笔真正卡住的就再也不会被报出来了。"""
    return [m for m in list_tx(root, limit=None)
            if m.get("state") in NEEDS_RECOVERY and m.get("txid") != exclude]


def leftover_materials(root=None):
    """已经是终态、却仍留着 candidate/before 的事务。

    这些目录里可能有出口密码、UUID、证书私钥 —— 清理失败时事务本身已经收尾, pending/stale 都
    不会再提它, 所以要单独报出来。只回 txid 与材料类型, 不碰内容。"""
    root = root or TX_ROOT
    out = []
    for m in list_tx(root, limit=None):
        if m.get("state") not in TERMINAL:
            continue
        d = os.path.join(root, m.get("txid") or "")
        left = [sub for sub in ("candidate", "before")
                if m.get("txid") and os.path.isdir(os.path.join(d, sub))]
        if left:
            out.append({"txid": m.get("txid"), "state": m.get("state"), "materials": left})
    return out


def stale_unstarted(root=None, older_than=86400):
    """长期遗留的 PREPARING / VALIDATED: 现网没被碰过, 但目录一直占着。
    只**报告**, 由 `pdg tx abort <id>` 显式收掉 —— 普通 GC 不许静默删。"""
    now = time.time()
    return [m for m in list_tx(root, limit=None)
            if m.get("state") in (PREPARING, VALIDATED)
            and now - float(m.get("started_at") or 0) > older_than]


def _gc(root=None):
    """只回收**明确终态**(COMMITTED / ROLLED_BACK / ABORTED)且超出 TX_KEEP 的目录。

    其余状态一律保留: APPLYING/OBSERVING/ROLLING_BACK/ROLLBACK_FAILED 是恢复材料,
    PREPARING/VALIDATED 是"还没动过现网但没收尾"的证据 —— 静默删掉它们等于毁掉排障线索,
    所以只由 `pdg tx abort` 显式收。"""
    root = root or TX_ROOT
    try:
        dirs = sorted((d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))),
                      reverse=True)
    except OSError:
        return
    kept = 0
    for d in dirs:
        p = os.path.join(root, d)
        m = load_meta(p) or {}
        if m.get("state") not in GC_TERMINAL:
            continue                      # 未完成 / 回滚失败: 一律保留
        kept += 1
        if kept > TX_KEEP:
            shutil.rmtree(p, ignore_errors=True)


# 恢复的**触发来源**(谁按下的恢复), 与事务的 source(谁最初创建了这笔事务)是两回事:
#   source        = bot / cli / scheduler …  —— 这笔事务当初由谁发起, 事后不许被改写;
#   trigger_source= cli / rescue / legacy —— 这次恢复由谁触发。
# 分开记的理由很实际: 出事后要能回答"这台机器上那次恢复是人在救援页点的, 还是 SSH 上敲的"。
# 只列**真有调用方**的来源: 不给还不存在的自动恢复入口预留名字 —— 预留出来的枚举值
# 迟早会被当成"已经支持自动恢复"来引用。将来真加了自动路径, 那时再加。
TRIGGERS = ("cli", "rescue", "legacy")


def _norm_trigger(v):
    """None(旧调用)→ legacy; 不在枚举里的 → unknown。**绝不回落成 cli** —— 那等于让来路不明
    的调用冒充人在终端上的操作。"""
    if v is None:
        return "legacy"
    return v if v in TRIGGERS else "unknown"


def recover(txid, root=None, force=False, *, trigger_source=None):
    """把一笔中断的事务还原回 before-image。

    漂移保护: 逐个目标比对"当前内容"与"本事务应用过的内容 / before-image"。两者都不是 →
    说明事务之外有人动过这个文件(很可能是运维手工救过场), 默认**停手并报告冲突** —— 拿旧
    备份盖掉别人的修复, 比不恢复更糟。force 只在命令行显式二次确认时可用, 不给 Telegram。"""
    root = root or TX_ROOT
    trig = _norm_trigger(trigger_source)
    t_start = time.time()
    d = os.path.join(root, txid)
    m = load_meta(d)
    if not m:
        return {"ok": False, "error": "找不到事务 %s" % txid}
    if m.get("schema_version") != SCHEMA_VERSION:
        return {"ok": False, "error": "事务 schema 版本不兼容(记录 %s, 当前 %s), 拒绝自动恢复"
                                      % (m.get("schema_version"), SCHEMA_VERSION)}
    if m.get("state") not in NEEDS_RECOVERY:
        return {"ok": True, "state": m.get("state"), "note": "该事务已是终态, 无需恢复"}
    try:
        with open(os.path.join(d, "before", "index.json"), encoding="utf-8") as f:
            bi = json.load(f)
    except Exception:  # noqa: BLE001
        return {"ok": False, "error": "before-image 缺失或损坏, 无法自动恢复(材料保留在 %s)" % d}
    with _Lock():
        # 两阶段: **先全量预检, 再动手**。边扫边恢复的话, 前一个目标已经被还原、后一个才发现
        # 有人工漂移 —— 于是既没恢复干净, 也没保住现场, 留下一个谁也说不清的混合状态。
        conflicts, material_err, plan = [], [], []
        for name in m.get("targets", []):
            try:
                path, mode, _s, _v = resolve_target(name)
            except TxError as e:
                material_err.append(str(e)); continue
            # 用事务**创建时**记下的路径: 证书目录这类可配置目标, 配置后来改了也不能把旧内容
            # 还到新目录去(那等于往另一份现网里写陈旧数据)。
            path = (m.get("target_paths") or {}).get(name, path)
            rec = bi.get("files", {}).get(name, {})
            cur, _ = _read_target(path)
            cur_sha = _sha(cur) if cur is not None else None
            before_sha = rec.get("sha256") if rec.get("existed") else None
            if cur_sha == before_sha:
                continue                                   # 已经是 before 的样子: 幂等, 无需动
            if not force and cur_sha != m.get("intended_sha", {}).get(name):
                conflicts.append(name)                     # 事务之外有人改过 → 不覆盖人工修复
                continue
            data = None
            if rec.get("existed"):                         # 恢复材料必须**先确认读得到**
                try:                                       # (含 --force: 读不到就别开始)
                    with open(os.path.join(d, "before", rec["file"]), "rb") as f:
                        data = f.read()
                except Exception as e:  # noqa: BLE001
                    material_err.append("%s(before-image 读不到: %s)" % (name, type(e).__name__))
                    continue
                if _sha(data) != before_sha:
                    material_err.append("%s(before-image 已损坏)" % name)
                    continue
            plan.append((name, path, rec, data, cur is not None))
        if material_err:
            return {"ok": False, "state": m.get("state"), "error":
                    "恢复材料有问题, 未做任何改动: %s" % "、".join(redact(x) for x in material_err),
                    "dir": d}
        restored, failed = [], []
        if conflicts and not force:
            # 预检阶段发现冲突 → **一个目标都没动过**, 现网逐字节保持原样
            return {"ok": False, "state": m.get("state"), "conflicts": conflicts,
                    "error": "这些目标在事务之外被改过, 默认不覆盖: %s" % ", ".join(conflicts),
                    "hint": "确认要用 before-image 盖掉现有内容时, 用 `pdg tx recover %s --force`"
                            % txid, "dir": d}
        for name, path, rec, data, exists in plan:         # 预检全过, 才进入恢复阶段
            try:
                if rec.get("existed"):
                    atomic_write(path, data, rec.get("mode", 0o600), rec.get("uid"), rec.get("gid"))
                elif exists:
                    os.unlink(path)
                    _fsync_dir(os.path.dirname(path))
                restored.append(name)
            except Exception as e:  # noqa: BLE001
                failed.append("%s(%s)" % (name, type(e).__name__))
        failed += _restore_runtime(bi)     # 与普通回滚同一份判据(不再各说各话)
        m["state"] = ROLLBACK_FAILED if failed else ROLLED_BACK
        m["recovered_at"] = time.time()
        m["rollback_complete"] = not failed
        if failed:
            m["rollback_failed_items"] = [redact(x) for x in failed]
        atomic_write(os.path.join(d, "meta.json"),
                     json.dumps(m, ensure_ascii=False, indent=1).encode(), 0o600)
        if not failed:
            for sub in ("candidate", "before"):
                shutil.rmtree(os.path.join(d, sub), ignore_errors=True)
        # 审计由**核心统一写**: 调用方(救援页/CLI)不再各写一条, 免得同一次恢复在日志里
        # 出现两条口径不同的记录。只记结构化标量与逻辑名, 不记文件内容、before-image 内容、
        # 凭据、异常正文, 也不记任何调用方可控的自由字符串。
        audit_warning = ""
        try:
            _audit_rec({"ts": time.time(), "event": "recover", "txid": txid,
                        "source": m.get("source"),          # 原事务由谁创建(不被覆盖)
                        "trigger_source": trig,             # 这次恢复由谁触发
                        "op": "recover:" + str(m.get("op")), "mode": "repair",
                        "state": m["state"], "started_at": t_start, "ended_at": time.time(),
                        "targets": m.get("targets", []), "services": m.get("services", []),
                        "error": "", "error_class": m.get("error_class", "") or "",
                        "rollback_complete": not failed,
                        "restored_count": len(restored), "failed_count": len(failed),
                        "restored": restored, "failed": [redact(x) for x in failed],
                        "schema_version": SCHEMA_VERSION})
        except Exception as e:  # noqa: BLE001
            # 恢复本身已经做完了 —— 审计写不进去不能反过来把它判成失败, 但必须让调用方看见
            audit_warning = "审计写入失败(%s): 本次恢复的结果未能落进审计日志" % type(e).__name__
        _gc(root)
        out = {"ok": not failed, "state": m["state"], "restored": restored,
               "failed": [redact(x) for x in failed], "trigger_source": trig, "dir": d}
        if audit_warning:
            out["audit_warning"] = audit_warning
        return out


# ── CLI(供 Bash 侧调用; 一笔事务 = 一次 apply 进程, 锁在其内全程持有)────────────
def _cli_new(a):
    tx = Tx(source=a.source, op=a.op, mode=a.mode)
    print(tx.txid)
    return 0


def _cli_stage(a):
    d = os.path.join(TX_ROOT, a.tx)
    m = load_meta(d)
    if not m or m.get("state") != PREPARING:
        print("事务不存在或不在 PREPARING: %s" % a.tx, file=sys.stderr); return 2
    path, mode, secret, validators = resolve_target(a.target)
    if a.delete:
        data = None
    else:
        with open(a.file, "rb") as f:
            data = f.read()
    cur, _ = _read_target(path)
    exp = a.expect if getattr(a, "expect", None) else (_sha(cur) if cur is not None else None)
    if getattr(a, "expect", None) == "-":          # "-" = 显式声明"生成候选时它不存在"
        exp = None
    idx = len(m.get("staged", []))
    cpath = os.path.join(d, "candidate", "%02d-%s" % (idx, _safe_leaf(a.target)))
    if data is not None:
        atomic_write(cpath, data, 0o600)
    m.setdefault("staged", []).append({
        "target": a.target, "candidate": os.path.basename(cpath) if data is not None else None,
        "expect": exp, "delete": data is None})
    atomic_write(os.path.join(d, "meta.json"),
                 json.dumps(m, ensure_ascii=False, indent=1).encode(), 0o600)
    return 0


def _cli_read(a):
    """读目标当前内容与 sha —— Bash 侧的 read-for-update: 先 read 拿 sha, 生成候选后
    stage --expect <sha>, 前置条件才对应"候选所依据的那一份"。"""
    path, _m, _s, _v = resolve_target(a.target)
    cur, _st = _read_target(path)
    print(_sha(cur) if cur is not None else "-")
    if cur is not None:
        sys.stdout.flush()
        os.write(1, cur)
    return 0


def _cli_service(a):
    d = os.path.join(TX_ROOT, a.tx)
    m = load_meta(d)
    if not m:
        print("事务不存在: %s" % a.tx, file=sys.stderr); return 2
    if a.action not in _ACTIONS:
        print("不在白名单里的服务动作: %s" % a.action, file=sys.stderr); return 2
    m.setdefault("staged_actions", [])
    if a.action not in m["staged_actions"]:
        m["staged_actions"].append(a.action)
    atomic_write(os.path.join(d, "meta.json"),
                 json.dumps(m, ensure_ascii=False, indent=1).encode(), 0o600)
    return 0


def _cli_apply(a):
    d = os.path.join(TX_ROOT, a.tx)
    m = load_meta(d)
    if not m:
        print("事务不存在: %s" % a.tx, file=sys.stderr); return 2
    # runner 固定: 一笔事务从头到尾必须由同一份事务核心执行。pdg update 会覆盖 pdgtx.py 本身,
    # 中途换版本等于用新语义去回滚旧语义写下的东西。
    if m.get("runner_sha256") and m["runner_sha256"] != _runner_sha() and not a.allow_runner_drift:
        print("事务由另一版本的事务核心创建(runner 不一致), 拒绝继续。"
              "更新流程应使用事务私有 runner 副本。", file=sys.stderr)
        return 3
    if m.get("schema_version") != SCHEMA_VERSION:
        print("事务 schema 版本不兼容(记录 %s, 当前 %s)" % (m.get("schema_version"), SCHEMA_VERSION),
              file=sys.stderr)
        return 3
    tx = Tx.__new__(Tx)
    tx.root, tx.txid, tx.dir = TX_ROOT, a.tx, d
    tx.source, tx.op, tx.mode = m["source"], m["op"], m.get("mode", "normal")
    tx.state, tx.meta = PREPARING, m
    tx.derivers, tx.warnings = [], list(m.get("warnings", []))
    tx.actions = list(m.get("staged_actions", []))
    # 只读依赖: CLI 侧的 stage 不记录 watch(bash 调用方一次只 stage 具体文件, 没有派生依赖),
    # 但落盘前的前置条件复核会遍历它 —— 不初始化就是 AttributeError, 整笔事务在**已经写完
    # before-image、正要动生产文件**的位置炸掉。meta 里有就按 meta 恢复, 没有就是空。
    tx.watches = dict(m.get("watches", {}))
    tx.audit_extra = {}
    tx._read_sha = {}
    tx.targets = {}
    for s in m.get("staged", []):
        path, mode, secret, validators = resolve_target(s["target"])
        data = None
        if s.get("candidate"):
            with open(os.path.join(d, "candidate", s["candidate"]), "rb") as f:
                data = f.read()
        cur, _ = _read_target(path)
        tx.targets[s["target"]] = {
            "path": path, "mode": mode, "secret": secret, "validators": list(validators),
            "data": data, "candidate": s.get("candidate"), "expect": s.get("expect"),
            "existed": cur is not None}
    try:
        res = tx.commit()
    except TxBusy as e:
        print("BUSY: %s" % e, file=sys.stderr); return 4
    except TxRefused as e:
        print("REFUSED: %s" % redact(str(e)), file=sys.stderr); return 5
    except TxError as e:
        print("ERROR: %s" % redact(str(e)), file=sys.stderr); return 2
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["state"] == COMMITTED else 1


def _cli_list(a):
    for m in list_tx(limit=a.limit):
        print("%-28s %-16s %-10s %-22s %s" % (
            m.get("txid"), m.get("state"), m.get("source"), m.get("op"),
            redact(m.get("error", ""))[:60]))
    return 0


def _cli_show(a):
    m = load_meta(os.path.join(TX_ROOT, a.tx))
    if not m:
        print("找不到事务", file=sys.stderr); return 2
    print(json.dumps(m, ensure_ascii=False, indent=2))
    return 0


def _cli_recover(a):
    r = recover(a.tx, force=a.force, trigger_source="cli")
    print(json.dumps(r, ensure_ascii=False))
    return 0 if r.get("ok") else 1


def _cli_abort(a):
    """把一笔**还没碰过现网**的事务(PREPARING/VALIDATED)显式收掉。
    动过现网的状态一律拒绝 —— 那种要走 recover, 不能一 abort 了之。"""
    d = os.path.join(TX_ROOT, a.tx)
    m = load_meta(d)
    if not m:
        print("找不到事务", file=sys.stderr); return 2
    if m.get("state") not in (PREPARING, VALIDATED):
        print("事务处于 %s: 现网可能已被改动, 请用 `pdg tx recover %s`" % (m.get("state"), a.tx),
              file=sys.stderr)
        return 2
    m["state"] = ABORTED
    m["ended_at"] = time.time()
    m["error"] = m.get("error") or "人工 abort(未开始应用)"
    atomic_write(os.path.join(d, "meta.json"),
                 json.dumps(m, ensure_ascii=False, indent=1).encode(), 0o600)
    for sub in ("candidate", "before"):
        shutil.rmtree(os.path.join(d, sub), ignore_errors=True)
    _audit_rec({"ts": time.time(), "txid": a.tx, "source": m.get("source"),
                "op": "abort:" + str(m.get("op")), "mode": m.get("mode", "normal"),
                "state": ABORTED, "targets": m.get("targets", []), "services": [],
                "error": "", "schema_version": SCHEMA_VERSION})
    print(json.dumps({"ok": True, "txid": a.tx, "state": ABORTED}, ensure_ascii=False))
    return 0


def _cli_pending(a):
    p = pending_recovery()
    for m in p:
        print("%s %s %s" % (m.get("txid"), m.get("state"), m.get("op")))
    for m in stale_unstarted():          # 只报告, 不动手(要收得显式 abort)
        print("%s %s %s (未开始应用, 可 `pdg tx abort` 收掉)"
              % (m.get("txid"), m.get("state"), m.get("op")))
    return 1 if p else 0


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="PrivDNS Gateway 配置事务")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new"); p.add_argument("--source", required=True)
    p.add_argument("--op", required=True); p.add_argument("--mode", default="normal")
    p.set_defaults(fn=_cli_new)
    p = sub.add_parser("stage"); p.add_argument("--tx", required=True)
    p.add_argument("--target", required=True); p.add_argument("--file")
    p.add_argument("--delete", action="store_true")
    p.add_argument("--expect", help="生成候选时所依据的源内容 sha256; '-' 表示当时不存在")
    p.set_defaults(fn=_cli_stage)
    p = sub.add_parser("read"); p.add_argument("--target", required=True)
    p.set_defaults(fn=_cli_read)
    p = sub.add_parser("service"); p.add_argument("--tx", required=True)
    p.add_argument("--action", required=True); p.set_defaults(fn=_cli_service)
    p = sub.add_parser("apply"); p.add_argument("--tx", required=True)
    p.add_argument("--allow-runner-drift", action="store_true"); p.set_defaults(fn=_cli_apply)
    p = sub.add_parser("list"); p.add_argument("--limit", type=int, default=20)
    p.set_defaults(fn=_cli_list)
    p = sub.add_parser("show"); p.add_argument("tx"); p.set_defaults(fn=_cli_show)
    p = sub.add_parser("recover"); p.add_argument("tx")
    p.add_argument("--force", action="store_true"); p.set_defaults(fn=_cli_recover)
    p = sub.add_parser("pending"); p.set_defaults(fn=_cli_pending)
    p = sub.add_parser("abort"); p.add_argument("tx"); p.set_defaults(fn=_cli_abort)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
