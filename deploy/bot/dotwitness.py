#!/usr/bin/env python3
"""每会话 DoT 证据端 —— 6.2A 的最小证据源。

它只回答一件事: **网关的 DoT 接收路径上, 出现过某个探测标识对应的 DNS 查询**。

为什么是这个形状:
  · mosdns 那边已经用两个条件守住了入口(qname 落在探测命名空间 + TLS SNI 等于 DoT 域名),
    所以能走到这里的查询, 本身就带着"经过 DoT"这个属性。这里不再重复判 SNI —— 判也判不了,
    转发过来的包没有 TLS 上下文。
  · **转发之后手机的原始地址就没有了**(实测: 源地址恒为 127.0.0.1 的临时端口)。所以证据里
    一个来源字段都不写 —— 来源归属仍然由 HTTP 那一层负责, 在这里编一个只会是假的。
  · 只用标准库、单文件。这个进程以 DynamicUser 跑, 依赖越少, 出问题的面越小。

不做的事: 不递归、不访问公网、不转发上游、不记普通查询、不落任何明文标识。
"""
import binascii
import hashlib
import json
import os
import re
import socket
import struct
import sys
import tempfile
import time

# ── 单一事实源 ───────────────────────────────────────────────────────────────
# 端口与后缀只在这里定义一次。mosdns 模板里的转发地址、unit 里的 Environment、测试的静态门
# 都要回到这两个常量对齐, 不许各写各的字面量。
DOTWITNESS_ADDR = "127.0.0.1"          # 只绑回环。绑 0.0.0.0 等于把证据端暴露给内网。
DOTWITNESS_PORT = 5399
SCHEMA_VERSION = 1
STATE_NAME = "evidence.json"           # 固定文件名: label 绝不参与路径
STATE_MAX_BYTES = 4096
EVIDENCE_TTL_SECS = 300                # 与 HTTP 会话同量级
TRANSPORT = "dot"

# probe label 契约: 12 字节随机 → 24 个小写 hex, 96 bit。
# 大写、23 位、25 位、非 hex 一律不认 —— 放宽这条等于让背景查询有机会冒充证据。
LABEL_RE = re.compile(r"\A[0-9a-f]{24}\Z")

MAX_PACKET = 1232                      # 超过这个长度的 UDP DNS 查询不是我们造的
MAX_LABEL_LEN = 63
MAX_NAME_LEN = 255


def _port():
    v = os.environ.get("PDG_DOTWITNESS_PORT")
    if not v:
        return DOTWITNESS_PORT
    try:
        p = int(v)
    except ValueError:
        return DOTWITNESS_PORT
    return p if 1 <= p <= 65535 else DOTWITNESS_PORT


def _suffix():
    """探测命名空间, 形如 `probe.<DoT域名>`。拿不到就返回 None —— 拿不到就一条都不认,
    而不是退化成"认所有"。"""
    s = (os.environ.get("PDG_DOTWITNESS_SUFFIX") or "").strip().strip(".").lower()
    if not s or len(s) > MAX_NAME_LEN:
        return None
    if not re.match(r"\A[a-z0-9._-]+\Z", s) or ".." in s:
        return None
    return s


def _runtime_dir():
    d = os.environ.get("RUNTIME_DIRECTORY") or "/run/pdg-dotwitness"
    return d.split(":")[0]


def _state_path():
    return os.path.join(_runtime_dir(), STATE_NAME)


# ── DNS 解析: 只认最保守的一种形状 ───────────────────────────────────────────
def parse_query(pkt):
    """返回 (qid, qname_lower, qtype) 或 None。

    任何不合规都返回 None —— 不抛异常、不部分解析。这里宁可漏也不能错: 解析器是
    唯一直面网络输入的地方, 它出问题就等于证据可以被伪造。
    """
    if not (12 < len(pkt) <= MAX_PACKET):
        return None
    qid, flags, qd, an, ns, ar = struct.unpack("!HHHHHH", pkt[:12])
    if flags & 0x8000:                 # QR=1 是响应, 不是查询
        return None
    if qd != 1 or an or ns:            # 只接受恰好一个 question
        return None
    if ar > 1:                         # 最多容忍一个 OPT
        return None
    i, labels, total = 12, [], 0
    while True:
        if i >= len(pkt):
            return None
        n = pkt[i]
        if n == 0:
            i += 1
            break
        if n & 0xC0:                   # 压缩指针: question 段里不该有, 直接拒
            return None
        if n > MAX_LABEL_LEN:
            return None
        i += 1
        if i + n > len(pkt):
            return None
        lab = pkt[i:i + n]
        total += n + 1
        if total > MAX_NAME_LEN:
            return None
        try:
            labels.append(lab.decode("ascii"))
        except UnicodeDecodeError:
            return None
        i += n
    if not labels:
        return None
    if i + 4 > len(pkt):
        return None
    qtype, qclass = struct.unpack("!HH", pkt[i:i + 4])
    if qclass != 1:                    # 只认 IN
        return None
    # DNS 名称大小写不敏感 → 统一小写后再比。但 label 本身的契约是小写 hex,
    # 所以规范化前后不一致的(比如大写 hex)不会因为这一步被放行 —— 见下面的原样校验。
    return qid, ".".join(labels), qtype, ".".join(labels).lower()


def match_probe(qname_raw, qname_lower, suffix):
    """返回 label(原样) 或 None。要求: 恰好 `<label>.<suffix>`, 不多一层也不少一层。"""
    if suffix is None:
        return None
    tail = "." + suffix
    if not qname_lower.endswith(tail):
        return None
    label_raw = qname_raw[:len(qname_raw) - len(tail)]
    if "." in label_raw or not label_raw:
        return None                    # 多层子域 / 空 label
    if not LABEL_RE.match(label_raw):  # 原样校验: 大写 hex 在这里被拒
        return None
    return label_raw


# ── 证据落盘 ────────────────────────────────────────────────────────────────
def _read_state():
    p = _state_path()
    try:
        st = os.lstat(p)
    except OSError:
        return None
    if not (st.st_mode & 0o170000) == 0o100000:   # 必须是普通文件, 不跟随软链
        return "CORRUPT"
    if st.st_size > STATE_MAX_BYTES:
        return "CORRUPT"
    try:
        with open(p, "rb") as f:
            rec = json.loads(f.read(STATE_MAX_BYTES + 1).decode("utf-8"))
    except Exception:  # noqa: BLE001
        return "CORRUPT"
    if not isinstance(rec, dict) or rec.get("schema_version") != SCHEMA_VERSION:
        return "CORRUPT"
    for k in ("probe_label_sha256", "observed_at", "expires_at", "transport", "qtype"):
        if k not in rec:
            return "CORRUPT"
    if not isinstance(rec.get("observed_at"), (int, float)):
        return "CORRUPT"
    if not isinstance(rec.get("expires_at"), (int, float)):
        return "CORRUPT"
    return rec


def _write_state(rec):
    """原子替换 + 0600。直接覆盖写会让读者看到半截 JSON。"""
    d = _runtime_dir()
    blob = json.dumps(rec, ensure_ascii=False, sort_keys=True).encode("utf-8")
    if len(blob) > STATE_MAX_BYTES:
        return False
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ev-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, _state_path())
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def record(label, qtype, now=None):
    """幂等: 同一 label 已记过就原样保留(包括 observed_at), 不刷新时间戳。"""
    now = time.time() if now is None else now
    digest = hashlib.sha256(label.encode("ascii")).hexdigest()
    cur = _read_state()
    if isinstance(cur, dict) and cur.get("probe_label_sha256") == digest \
            and cur.get("expires_at", 0) > now:
        return True
    return _write_state({
        "schema_version": SCHEMA_VERSION,
        "probe_label_sha256": digest,
        "observed_at": now,
        "qtype": int(qtype),
        "transport": TRANSPORT,
        "expires_at": now + EVIDENCE_TTL_SECS,
    })


def purge_stale(now=None):
    """启动时清理: 过期或损坏的状态一律删掉, 不留给下一次会话当假证据。"""
    now = time.time() if now is None else now
    cur = _read_state()
    if cur is None:
        return
    if cur == "CORRUPT" or cur.get("expires_at", 0) <= now:
        try:
            os.unlink(_state_path())
        except OSError:
            pass


def nodata_reply(pkt, qid):
    """同 ID 的 NOERROR/NODATA。不给可连接地址 —— 给了手机就会再发起一次 HTTP,
    那会把"DNS 到达"和"HTTP 到达"两件事混成一件。"""
    body = pkt[12:]
    return struct.pack("!HHHHHH", qid, 0x8180, 1, 0, 0, 0) + body


def serve(sock, suffix):
    while True:
        try:
            pkt, src = sock.recvfrom(4096)
        except OSError:
            continue
        parsed = parse_query(pkt)
        if parsed is None:
            continue                   # 畸形包: 连 ID 都取不到, 无从回起 —— 丢弃, 不回不写
        qid, qname_raw, qtype, qname_lower = parsed
        label = match_probe(qname_raw, qname_lower, suffix)
        if label is not None:
            record(label, qtype)       # 只有合规 label 才留证据
        # 能解析出来的查询**一律给一个有界应答**, 哪怕 label 不合规。
        #
        # 为什么不能像以前那样静默丢弃: 钉定的 mosdns v5.3.4 只能按 qname 后缀 + SNI 路由
        # (它的 qname 匹配器不支持 regexp, domain_set 里的 regexp: 也是 unsupported),
        # 所以 `<任意>.probe.<域名>` 只要走 DoT 就一定会被转到这里。这边一声不吭的话:
        #   · 客户端要等满 mosdns 的上游超时(实测 ~5s)才拿到空结果;
        #   · mosdns 会在 warn 级打出 `upstream error` 与 `entry err`, 两条都带**完整
        #     qname 和客户端 IP** —— 等于每个乱填的探测名都往日志里写一次隐私数据;
        #   · 每个这样的查询都占住一个 worker 到超时, 是白送的资源消耗面。
        # 回一个 NOERROR/NODATA 就把这三样一起消掉, 而证据仍然只认 24 位小写 hex。
        try:
            sock.sendto(nodata_reply(pkt, qid), src)
        except OSError:
            pass


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    suffix = _suffix()
    d = _runtime_dir()
    if not os.path.isdir(d):
        # 日志里只说目录不可用, 不打印路径以外的任何东西
        print("dotwitness: runtime directory unavailable", file=sys.stderr)
        return 3
    purge_stale()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind((DOTWITNESS_ADDR, _port()))
    except OSError as e:
        print("dotwitness: bind failed (%s)" % type(e).__name__, file=sys.stderr)
        return 4
    # 日志里不出现 qname、label、来源地址 —— 只说自己起来了
    print("dotwitness: listening on loopback, namespace %s"
          % ("configured" if suffix else "MISSING"), file=sys.stderr, flush=True)
    if suffix is None:
        # fail-closed: 没有命名空间就谁都不认, 但仍然把进程留着, 免得 mosdns 那边
        # 因为连不上而把探测查询当成别的错误。
        pass
    try:
        serve(s, suffix)
    except KeyboardInterrupt:
        return 0
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
