#!/usr/bin/env python3
"""PrivDNS Gateway 6.1B — 手机协助链路会话(一次性 token)。

这个模块被两个**不同身份**的进程共用:
  · root 的 `pdg link session ...` CLI —— 建会话、读状态、停会话;
  · DynamicUser 身份的 pdg-probe81 服务 —— 手机访问 :81 时消费 token。

所以文件所有权是这里最容易出错的地方, 单独说明:
  RuntimeDirectory=pdg-probe81 让 systemd 把 /run/pdg-probe81 建成 0700、属主是
  那个动态 UID。root 往里写没问题(root 绕过权限), 但**写出来的文件是 root:root
  0600** —— 动态 UID 读不到, 会话当场作废。所以 root 侧写完必须把文件 chown 成
  目录属主。反过来动态 UID 写时不 chown(它也没权限), 直接原子替换即可: 替换靠的
  是对**目录**的写权限, 而目录本来就是它的。
  绝不靠 0666/0777 或放宽 RuntimeDirectoryMode 绕过 —— 那等于把 token 摘要摊开
  给机器上任何一个本地用户。

隐私边界(6.1B 已拍板, 不得放宽):
  · 不存 token 原文, 只存 sha256;
  · 不存完整来源 IP, 只存 IPv4 /16 前缀与 inside_internal_cidr 布尔;
  · 不存 URL / Cookie / 请求体 / User-Agent / 普通查询域名。

会话状态**不进 pdgtx、不占全局配置写锁** —— 它是运行时数据, 跟受管配置无关。
"""
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import sys
import time

SCHEMA_VERSION = 1
RUNTIME_DIR = "/run/pdg-probe81"
STATE_NAME = "session.json"
STATE_MAX_BYTES = 4096

TTL_SECS = 300                 # 5 分钟
TOKEN_BYTES = 32               # secrets.token_urlsafe(32) → 256 bit
TOKEN_RE = re.compile(r"\A[A-Za-z0-9_-]{43}\Z")   # token_urlsafe(32) 的确定长度
MAX_INVALID_ATTEMPTS = 3

PROFILE_ENV = "/etc/privdns-gateway/profile.env"

# 稳定 reason code —— 对外契约, 改动等于破坏调用方
R_OK = "OK"
R_NO_SESSION = "NO_SESSION"
R_SESSION_EXPIRED = "SESSION_EXPIRED"
R_TOKEN_REUSED = "TOKEN_REUSED"
R_RATE_LIMITED = "RATE_LIMITED"
R_TOKEN_INVALID = "TOKEN_INVALID"
R_STATE_CORRUPT = "STATE_CORRUPT"
R_STATE_UNWRITABLE = "STATE_UNWRITABLE"

REASONS = (R_OK, R_NO_SESSION, R_SESSION_EXPIRED, R_TOKEN_REUSED, R_RATE_LIMITED,
           R_TOKEN_INVALID, R_STATE_CORRUPT, R_STATE_UNWRITABLE)


def _runtime_dir():
    return os.environ.get("PDG_PROBE81_RUNTIME_DIR", RUNTIME_DIR)


def _state_path():
    return os.path.join(_runtime_dir(), STATE_NAME)


def _profile(key):
    """从 profile.env 读一个键(唯一真源)。读不到返回空串。"""
    try:
        with open(os.environ.get("PDG_PROFILE_ENV", PROFILE_ENV), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


# ── 隐私: 来源地址的处理 ──────────────────────────────────────────────────
def ipv4_16(addr):
    """只保留 IPv4 的 /16 前缀。IPv6 与非法输入一律返回 None ——
    宁可没有这条证据, 也不把一个没想清楚怎么脱敏的地址写进状态。"""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return None
    if ip.version != 4:
        return None
    a, b = str(ip).split(".")[:2]
    return "%s.%s.0.0/16" % (a, b)


def inside_internal_cidr(addr, cidr=None):
    cidr = cidr if cidr is not None else _profile("PDG_INTERNAL_CIDR")
    if not cidr:
        return None
    try:
        return ipaddress.ip_address(addr) in ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return None


# ── 状态读写 ─────────────────────────────────────────────────────────────
def _dir_owner():
    """RuntimeDirectory 的属主 —— 也就是 pdg-probe81 那个动态 UID。"""
    try:
        st = os.stat(_runtime_dir())
        return st.st_uid, st.st_gid
    except OSError:
        return None, None


def write_state(rec):
    """原子替换。root 写完 chown 给目录属主, 否则动态 UID 读不到。

    失败**不抛**, 返回 False —— 调用方(尤其 probe81)必须能在状态写不了的时候
    继续把普通探测的 200 返回出去。
    """
    d = _runtime_dir()
    blob = json.dumps(rec, ensure_ascii=False, sort_keys=True).encode("utf-8")
    if len(blob) > STATE_MAX_BYTES:
        return False
    tmp = os.path.join(d, ".%s.%d.tmp" % (STATE_NAME, os.getpid()))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, blob)
            os.fsync(fd)
        finally:
            os.close(fd)
        uid, gid = _dir_owner()
        if uid is not None and os.geteuid() == 0 and uid != 0:
            # 只有 root 能 chown; 动态 UID 自己写时这一步跳过(它本来就是属主)。
            os.chown(tmp, uid, gid)
        os.replace(tmp, _state_path())
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def read_state():
    """返回 (rec, reason)。损坏一律 fail-closed —— 宁可当没有会话。"""
    p = _state_path()
    try:
        st = os.lstat(p)
    except OSError:
        return None, R_NO_SESSION
    # 必须是普通文件、单链接: 符号链接穿透或硬链接都可能把状态指到别处
    if not os.path.isfile(p) or os.path.islink(p) or st.st_nlink != 1:
        return None, R_STATE_CORRUPT
    if st.st_size > STATE_MAX_BYTES:
        return None, R_STATE_CORRUPT
    try:
        with open(p, encoding="utf-8") as f:
            rec = json.load(f)
    except (OSError, ValueError):
        return None, R_STATE_CORRUPT
    if not isinstance(rec, dict) or rec.get("schema_version") != SCHEMA_VERSION:
        return None, R_STATE_CORRUPT
    for k in ("session_id", "token_sha256", "created_at", "expires_at", "state"):
        if k not in rec:
            return None, R_STATE_CORRUPT
    # 动态 UID 换过之后不许误读上一任留下的会话。RuntimeDirectory 停服即销毁, 正常
    # 情况下读不到旧文件; 这一层是兜底(比如目录被手工重建过)。
    uid, _g = _dir_owner()
    if rec.get("owner_uid") is not None and uid is not None and rec["owner_uid"] != uid:
        return None, R_STATE_CORRUPT
    return rec, R_OK


def clear_state():
    try:
        os.unlink(_state_path())
        return True
    except OSError:
        return False


# ── 会话生命周期 ─────────────────────────────────────────────────────────
def _now():
    return time.time()


def _expired(rec, now=None):
    return (now if now is not None else _now()) >= rec.get("expires_at", 0)


def new_session(probe_domain=None, metrics_baseline=None):
    """建一次新会话。同时最多 1 个 —— 直接覆盖旧的, 旧 token 当场失效。

    返回 (token, rec)。token **只在这里**以原文形式存在, 之后一律只留 sha256。
    """
    token = secrets.token_urlsafe(TOKEN_BYTES)
    now = _now()
    uid, _g = _dir_owner()
    rec = {
        "schema_version": SCHEMA_VERSION,
        "session_id": secrets.token_hex(4),
        "token_sha256": hashlib.sha256(token.encode("ascii")).hexdigest(),
        "created_at": now,
        "expires_at": now + TTL_SECS,
        "ttl_secs": TTL_SECS,
        "state": "waiting",
        "http_consumed_at": None,
        "invalid_attempts": 0,
        "max_invalid_attempts": MAX_INVALID_ATTEMPTS,
        "probe_domain": probe_domain,
        "source": None,
        "metrics_baseline": metrics_baseline,
        "owner_uid": uid,
    }
    return token, rec


def consume(token, client_ip, now=None):
    """probe81 侧: 消费一次 token。返回 (accepted, reason, rec_or_None)。

    这是唯一会被外部输入驱动的入口, 判定顺序是刻意的:
      1) token 形状不合法 → 连读状态都不必, 也不计入尝试次数(挡扫描噪声);
      2) 没有会话 / 状态损坏 → fail-closed;
      3) 已过期 → SESSION_EXPIRED(不再接受, 但也不当成"尝试");
      4) 尝试次数已满 → RATE_LIMITED;
      5) 已消费过 → TOKEN_REUSED;
      6) 比对失败 → 计一次尝试, TOKEN_INVALID;
      7) 通过 → 记录成功事件。
    """
    now = now if now is not None else _now()
    if not isinstance(token, str) or not TOKEN_RE.match(token):
        return False, R_TOKEN_INVALID, None
    rec, why = read_state()
    if rec is None:
        return False, why, None
    if _expired(rec, now):
        return False, R_SESSION_EXPIRED, rec
    if rec.get("invalid_attempts", 0) >= rec.get("max_invalid_attempts", MAX_INVALID_ATTEMPTS):
        return False, R_RATE_LIMITED, rec
    if rec.get("http_consumed_at") is not None:
        return False, R_TOKEN_REUSED, rec
    digest = hashlib.sha256(token.encode("ascii")).hexdigest()
    if not hmac.compare_digest(digest, rec.get("token_sha256", "")):
        rec["invalid_attempts"] = rec.get("invalid_attempts", 0) + 1
        if rec["invalid_attempts"] >= rec.get("max_invalid_attempts", MAX_INVALID_ATTEMPTS):
            rec["state"] = "rate_limited"
        write_state(rec)
        return False, R_TOKEN_INVALID, rec
    # 成功。**不删整场会话** —— DNS 那半边还没观测完, 要留到 TTL 到期或显式 stop。
    rec["http_consumed_at"] = now
    rec["state"] = "http_seen"
    rec["source"] = {
        "ipv4_16": ipv4_16(client_ip),
        "inside_internal_cidr": inside_internal_cidr(client_ip),
    }
    if not write_state(rec):
        # 状态写不下去: 会话功能降级, 但**不能**把这当成失败往上抛 ——
        # probe81 的调用方仍要返回 200, 否则 iOS OnDemand 会判定探测失败。
        return True, R_STATE_UNWRITABLE, rec
    return True, R_OK, rec


def status(now=None):
    """CLI 侧: 当前会话的稳定 schema。没有会话时 reason=NO_SESSION。"""
    now = now if now is not None else _now()
    rec, why = read_state()
    if rec is None:
        return {"schema_version": SCHEMA_VERSION, "active": False, "reason": why,
                "session": None}
    expired = _expired(rec, now)
    return {
        "schema_version": SCHEMA_VERSION,
        "active": not expired,
        "reason": R_SESSION_EXPIRED if expired else R_OK,
        "session": {
            "session_id": rec["session_id"],
            "state": "expired" if expired else rec.get("state"),
            "created_at": rec["created_at"],
            "expires_at": rec["expires_at"],
            "remaining_secs": max(0, int(rec["expires_at"] - now)),
            "http_consumed": rec.get("http_consumed_at") is not None,
            "http_consumed_at": rec.get("http_consumed_at"),
            "invalid_attempts": rec.get("invalid_attempts", 0),
            "max_invalid_attempts": rec.get("max_invalid_attempts", MAX_INVALID_ATTEMPTS),
            "probe_domain": rec.get("probe_domain"),
            "source": rec.get("source"),
            "metrics_baseline": rec.get("metrics_baseline"),
        },
    }


# ── CLI ──────────────────────────────────────────────────────────────────
# 这里可以 import checks(与 linkstat / doctor / report 同风格), 但**只在函数内**:
# 模块顶层保持纯标准库, 否则 pdg-probe81 那个 DynamicUser 进程也会被拖着一起加载。
def _dot_domain():
    try:
        import checks
        return checks._dot_file() or ""
    except Exception:  # noqa: BLE001
        return ""


def _server_ip():
    return _profile("PDG_SERVER_IP")


def make_probe_domain():
    """`<随机>.probe.<DoT域名>` —— 随机前缀是为了**绕开本机与手机侧的 DNS 缓存**:
    固定域名第二次查就可能直接命中缓存, 根本不会产生到达 mosdns 的查询。"""
    dot = _dot_domain()
    if not dot:
        return None
    return "%s.probe.%s" % (secrets.token_hex(6), dot)


_TWO_STEP = """请在**手机上**依次做两步(用要诊断的那张 SIM 卡, 关掉 Wi-Fi):

  第 1 步 打开这个数字地址的链接 —— 让服务器观察到一次来自手机的 HTTP 请求:
      %s

  第 2 步 再打开这个随机子域 —— 触发一次不会命中缓存的 DNS 查询:
      %s

说明:
  · 第 1 步是本次唯一会被记录下来的证据; 做完回来看 `pdg link session status`。
    它只说明"服务器观察到本次会话的 HTTP 请求", 不代表 SIM/APN、DoT 或手机整体
    联网正常。
  · 第 2 步的网页**最终打不开是预期结果** —— 它要的是那一次 DNS 查询本身,
    不是网页内容。
  · **当前版本暂不采集第 2 步的证据**, 因此无法判断手机的 DoT 查询是否到达;
    这不代表正常, 也不代表故障。DNS 实时证据将在后续版本重新设计, 技术原因
    见项目路线图(docs/ROADMAP.md)。现在做第 2 步只是为了顺手排除缓存干扰,
    不会产生诊断结论。
  · 两步都没有证据, 不等于手机故障; 只说明这次没观察到。
  · 只有第 1 步有证据而第 2 步没有, 优先检查 Private DNS / 描述文件是否启用 ——
    但这不能断言它一定关着。

做完后回来跑: pdg link session status"""


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv
    argv = [a for a in argv if a != "--json"]
    sub = argv[0] if argv else "status"

    if sub == "start":
        baseline = None
        try:
            import linkmetrics
            baseline = linkmetrics.snapshot()
        except Exception:  # noqa: BLE001
            baseline = None
        domain = make_probe_domain()
        token, rec = new_session(probe_domain=domain, metrics_baseline=baseline)
        if not write_state(rec):
            print("会话状态写不下去(%s 不可写?) —— 会话未建立。" % _runtime_dir(),
                  file=sys.stderr)
            print("普通的 :81 探测与 DoT 都不受影响。", file=sys.stderr)
            return 1
        ip = _server_ip() or "<网关IP>"
        url1 = "http://%s:81/probe?t=%s" % (ip, token)
        url2 = "http://%s/" % domain if domain else "(DoT 域名未配置, 第 2 步不可用)"
        if as_json:
            print(json.dumps({"schema_version": SCHEMA_VERSION, "ok": True,
                              "session_id": rec["session_id"],
                              "expires_at": rec["expires_at"],
                              "ttl_secs": rec["ttl_secs"],
                              "step1_url": url1, "step2_url": url2,
                              "probe_domain": domain},
                             ensure_ascii=False, indent=1))
        else:
            print("已建立链路诊断会话 %s(%d 秒内有效, 同时只允许一个)。\n"
                  % (rec["session_id"], rec["ttl_secs"]))
            print(_TWO_STEP % (url1, url2))
        return 0

    if sub == "stop":
        had, _ = read_state()
        clear_state()
        if as_json:
            print(json.dumps({"schema_version": SCHEMA_VERSION, "ok": True,
                              "stopped": had is not None}, ensure_ascii=False))
        else:
            print("会话已停止。" if had is not None else "当前没有会话。")
        return 0

    if sub in ("status", ""):
        st = status()
        if as_json:
            print(json.dumps(st, ensure_ascii=False, indent=1))
            return 0
        if st["session"] is None:
            print("当前没有链路诊断会话(%s)。用 `pdg link session start` 建一个。"
                  % st["reason"])
            return 0
        s = st["session"]
        print("会话 %s  状态=%s  剩余 %ds" % (s["session_id"], s["state"],
                                             s["remaining_secs"]))
        print("  HTTP 探测: %s" % ("已观察到" if s["http_consumed"] else "尚未观察到"))
        if s["source"]:
            print("    来源网段 %s, 命中内网卡段: %s"
                  % (s["source"].get("ipv4_16"), s["source"].get("inside_internal_cidr")))
        print("  无效尝试: %d/%d" % (s["invalid_attempts"], s["max_invalid_attempts"]))
        if s["probe_domain"]:
            print("  探测子域: %s" % s["probe_domain"])
        return 0

    print("用法: pdg link session <start|status|stop> [--json]", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
