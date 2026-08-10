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
import errno
import hashlib
import json
import os
import re
import socket
import stat
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
SHA256_RE = re.compile(r"\A[0-9a-f]{64}\Z")
STATE_FIELDS = frozenset(("schema_version", "probe_label_sha256", "observed_at",
                          "qtype", "transport", "expires_at"))
STATE_MODE = 0o600
TMP_PREFIX = ".ev-"

# 跨 UID 读取的四种结果。必须分得开: 把"没权限读"和"没有证据"混成一个 None, 上层就会
# 把"我看不见"说成"它没发生" —— 那正是 6.2B 最不能犯的错(见 read_evidence)。
READ_OK = "OK"
READ_ABSENT = "ABSENT"       # 观察端在跑, 但还没有证据(或已被清理)
READ_DENIED = "DENIED"       # 读不到 → 无从判断有没有 → 上层必须 UNAVAILABLE
READ_CORRUPT = "CORRUPT"     # 有东西但不合规/对象不安全 → 同样只能 UNAVAILABLE

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
    s = (os.environ.get("PDG_DOTWITNESS_SUFFIX") or "").strip().lower()
    if not s or len(s) > MAX_NAME_LEN:
        return None
    # 不做 strip(".")。以前那样写会把 `.probe.example` 悄悄normalize成 `probe.example`,
    # 等于默默接受了一个**不是配置里那个**的命名空间 —— 配置写错了就该在启动时报出来。
    if s.startswith(".") or s.endswith(".") or ".." in s:
        return None
    if not re.match(r"\A[a-z0-9._-]+\Z", s):
        return None
    if any(not lab or len(lab) > MAX_LABEL_LEN for lab in s.split(".")):
        return None                      # 单个 label 也有 63 字节上限
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
    """读出一份**完全合规**的 evidence, 否则一律 "CORRUPT"。

    这里是宽进严出的分界: 早先只查了几个 key 在不在, 于是多字段、probe_label_sha256
    不是哈希、transport 写成别的值都能被当成有效证据读出去。证据的意义全在"它只可能
    由本服务按这一种形状写出来" —— 判定放宽一点, 上层就可能把别人塞的文件当成观测结果。

    返回 None(没有) / "CORRUPT"(有但不合规或不安全) / 那份 dict。

    这是 witness **自己**读自己写的东西时的形状, 语义与 6.2A 完全一致。跨 UID 的
    消费者请走 read_evidence() —— 差别见那里的说明。
    """
    status, rec = read_evidence(expect_uid=os.geteuid())
    if status == READ_OK:
        return rec
    if status == READ_ABSENT:
        return None
    return "CORRUPT"


def read_evidence(runtime_dir=None, expect_uid=None):
    """唯一的 evidence 读取入口。返回 (READ_*, rec 或 None)。

    为什么需要它, 而不是让消费者直接用 _read_state():

      · **属主判据必须锚在观察端身份上, 不能锚在读者身上。** 原来那句
        `st.st_uid != os.geteuid()` 对 witness 自己是对的(它就是属主), 但换成 root
        消费者时正好是反的 —— 实测: root 读 witness 真写的证据判 CORRUPT, 而 root
        自己写的一份假证据反倒判"有效"。所以属主要显式传进来; 不传就取
        RuntimeDirectory 的属主(linksess 判断动态 UID 用的也是这套)。

      · **"读不到"和"没有"必须分开。** lstat 失败原来一律 return None, ENOENT 和
        EACCES 落到同一个结论上。对 witness 自己无所谓(它读得到自己的目录), 对跨 UID
        消费者就是致命的: 没权限被当成"没有证据", 上层据此说出"手机的查询没有到达",
        而真相是我们根本没看。

    只读: 不创建、不修改、不删除任何东西。
    """
    d = runtime_dir or _runtime_dir()
    p = os.path.join(d, STATE_NAME)
    if expect_uid is None:
        try:
            expect_uid = os.stat(d).st_uid
        except OSError as e:
            # 目录都摸不到: 没启动过(ENOENT) vs 无权进入(EACCES/EPERM), 结论不同
            return (READ_ABSENT if e.errno == errno.ENOENT else READ_DENIED), None
        # 本服务是 DynamicUser=yes, systemd 建的 RuntimeDirectory 永远归那个动态 UID。
        # 目录属主是 root 说明它不是 systemd 按这个 unit 建的(实测: 停服后 root 自己
        # mkdir+chown, 就能让"从目录推导属主"这条判据认下 root 自己写的假证据)。
        # 这种时候没有可信锚点, 直接判损坏 —— 不是"没有证据", 是这套东西现在不作数。
        if expect_uid == 0:
            return READ_CORRUPT, None
    try:
        st = os.lstat(p)
    except OSError as e:
        return (READ_ABSENT if e.errno == errno.ENOENT else READ_DENIED), None
    if not stat.S_ISREG(st.st_mode):          # symlink / FIFO / 目录 / 设备: 不读也不跟随
        return READ_CORRUPT, None
    if stat.S_IMODE(st.st_mode) != STATE_MODE:
        return READ_CORRUPT, None
    if st.st_uid != expect_uid:               # 不是观察端写的, 不信
        return READ_CORRUPT, None
    if st.st_size > STATE_MAX_BYTES:
        return READ_CORRUPT, None
    try:
        with open(p, "rb") as f:
            rec = json.loads(f.read(STATE_MAX_BYTES + 1).decode("utf-8"))
    except OSError as e:
        return (READ_DENIED if e.errno in (errno.EACCES, errno.EPERM)
                else READ_CORRUPT), None
    except Exception:  # noqa: BLE001
        return READ_CORRUPT, None
    return (READ_OK, rec) if _valid(rec) else (READ_CORRUPT, None)


def _finite(x):
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return False
    return x == x and x not in (float("inf"), float("-inf"))


def _valid(rec):
    """evidence 的闭集判据。任何一条不满足都不是有效证据。"""
    if not isinstance(rec, dict) or set(rec) != STATE_FIELDS:
        return False
    if rec["schema_version"] != SCHEMA_VERSION:
        return False
    d = rec["probe_label_sha256"]
    if not isinstance(d, str) or not SHA256_RE.match(d):
        return False
    if rec["transport"] != TRANSPORT:
        return False
    qt = rec["qtype"]
    if isinstance(qt, bool) or not isinstance(qt, int) or not (0 <= qt <= 65535):
        return False
    o, e = rec["observed_at"], rec["expires_at"]
    if not _finite(o) or not _finite(e):
        return False
    if not (o < e <= o + EVIDENCE_TTL_SECS):   # 生命周期不得超过设计上限
        return False
    return True


def _write_state(rec):
    """原子替换 + 0600。直接覆盖写会让读者看到半截 JSON。"""
    d = _runtime_dir()
    blob = json.dumps(rec, ensure_ascii=False, sort_keys=True).encode("utf-8")
    if len(blob) > STATE_MAX_BYTES:
        return False
    # mkstemp 必须在 try **之内**: 目录被删/不可写时它抛的 FileNotFoundError、
    # PermissionError 都是 OSError, 放在外面就会一路冒到 serve() 把进程带走 ——
    # 那不是 fail-closed, 是 fail-crash: 客户端等不到回包, systemd 还会反复重启。
    # 目标位置若不是"本服务自己的普通文件", 就不写 —— os.replace 会把那个目录项换掉,
    # 对 symlink/FIFO 来说算不上跟随, 但也没有理由替别人做主。
    try:
        tst = os.lstat(_state_path())
        if not stat.S_ISREG(tst.st_mode) or tst.st_uid != os.geteuid():
            return False
    except OSError:
        pass
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=TMP_PREFIX)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, _state_path())
        return True
    except OSError:
        if tmp is not None:
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
    """启动清理。只删**本服务自己写的、普通文件**的损坏或过期状态。

    不安全对象(symlink / FIFO / 设备 / 目录)一个都不碰 —— 不读、不跟随、也不删:
    删掉等于替别人做决定, 而 0700 的 RuntimeDirectory 里出现这种东西本身就该由人来看。
    `.ev-*` 临时文件同理: 只清符合本服务约束(普通文件 + 属主是自己 + 0600)的那些,
    绝不按前缀扫着删 —— 那删的可能是别的程序的文件。
    """
    now = time.time() if now is None else now
    d = _runtime_dir()
    p = _state_path()
    try:
        st = os.lstat(p)
    except OSError:
        st = None
    if st is not None and stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid():
        cur = _read_state()
        if cur == "CORRUPT" or (isinstance(cur, dict) and cur["expires_at"] <= now):
            try:
                os.unlink(p)
            except OSError:
                pass
    try:
        names = os.listdir(d)
    except OSError:
        return
    for n in names:
        if not n.startswith(TMP_PREFIX):
            continue
        q = os.path.join(d, n)
        try:
            s2 = os.lstat(q)
        except OSError:
            continue
        if stat.S_ISREG(s2.st_mode) and s2.st_uid == os.geteuid() \
                and stat.S_IMODE(s2.st_mode) == STATE_MODE:
            try:
                os.unlink(q)
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
            # 记不下来也不能把进程带走: 只报一个**固定类别**(不带 qname/label/来源),
            # 然后照常回包 —— "没记上"由上层按"没观察到"处理, 不能变成假证据。
            if not record(label, qtype):
                print("dotwitness: state write failed", file=sys.stderr, flush=True)
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
    if suffix is None:
        # 早先这里只是"起着但谁都不认" —— 那是假健康态: systemd 显示 active, 运维看不出
        # 配置错了, 而任何探测都永远不会有证据。缺配置必须在启动时就暴露。
        print("dotwitness: probe namespace missing or invalid", file=sys.stderr, flush=True)
        return 2
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
    print("dotwitness: listening on loopback", file=sys.stderr, flush=True)
    try:
        serve(s, suffix)
    except KeyboardInterrupt:
        return 0
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
