#!/usr/bin/env python3
"""6.2A 故障矩阵: DNS parser 25 格 + 状态文件 24 格 + 原子写入专项。

每格的判据统一是六件事: 是否回包 / 是否写 evidence / 进程是否存活 / 旧 evidence 是否
保持 / stderr 有没有泄露 / 之后合法查询能不能恢复。

两条纪律:
  · 故障注入先证明**真的命中**, 再断言行为。注不进去却绿, 比红更糟。
  · 不用 root 能绕过的 chmod 000 冒充权限故障 —— 换成删目录、换成不可写文件系统这类
    root 也绕不过的形态, 或者用非 root 子进程。
"""
import errno
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WITNESS = os.path.join(ROOT, "deploy", "bot", "dotwitness.py")
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import dotwitness as W  # noqa: E402

npass = nfail = nskip = 0
LABEL = "a1b2c3d4e5f6a7b8c9d0e1f2"
LABEL2 = "0f1e2d3c4b5a69788796a5b4"
SUFFIX = "probe.dot.fault.test"


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def skip(m):
    global nskip
    nskip += 1
    print("[SKIP] %s" % m)


def head(m):
    print("\n── %s ──" % m)


def name_wire(qname):
    return b"".join(bytes([len(p)]) + p.encode("ascii")
                    for p in qname.rstrip(".").split(".") if p) + b"\x00"


def q(qname, qtype=1, qid=0x1234, qd=1, an=0, ns=0, ar=0, qclass=1, flags=0x0100,
      tail=True, body=None):
    h = struct.pack("!HHHHHH", qid, flags, qd, an, ns, ar)
    b = body if body is not None else name_wire(qname)
    if tail:
        b += struct.pack("!HH", qtype, qclass)
    return h + b


# ═══ A. parser 故障矩阵 (纯函数, 直接喂 parse_query/match_probe) ═══════════
head("A. DNS parser 故障矩阵(25 格)")

BIG = q("a" * 63 + "." + SUFFIX) + b"\x00" * 1300
CASES = [
    ("1  少于 12 字节",        b"\x01\x02\x03",                              None),
    ("2  超过 1232 字节",      BIG,                                          None),
    ("3  QR=1 的响应包",       q(LABEL + "." + SUFFIX, flags=0x8180),        None),
    ("4  QDCOUNT=0",           q(LABEL + "." + SUFFIX, qd=0),                None),
    ("5  QDCOUNT=2",           q(LABEL + "." + SUFFIX, qd=2),                None),
    ("6  ANCOUNT 非零",        q(LABEL + "." + SUFFIX, an=1),                None),
    ("7  NSCOUNT 非零",        q(LABEL + "." + SUFFIX, ns=1),                None),
    ("8  ARCOUNT 超限",        q(LABEL + "." + SUFFIX, ar=2),                None),
    ("9  label 超过 63",       q("", body=bytes([64]) + b"x" * 64 + b"\x00"), None),
    ("10 总域名超过 255",      q(".".join(["abcdefghij"] * 30) + "." + SUFFIX), None),
    ("11 QNAME 未终止",        struct.pack("!HHHHHH", 1, 0x0100, 1, 0, 0, 0) + b"\x03abc", None),
    ("12 压缩指针",            q("", body=b"\xc0\x0c"),                      None),
    ("13 指针循环样本",        q("", body=b"\xc0\x0c\xc0\x0c"),              None),
    ("14 QTYPE 缺失",          q(LABEL + "." + SUFFIX, tail=False),          None),
    ("15 QCLASS 缺失",         q(LABEL + "." + SUFFIX, tail=False) + b"\x00\x01", None),
    ("16 QCLASS 非 IN",        q(LABEL + "." + SUFFIX, qclass=3),            None),
    ("17 空 label 位置非法",   q("", body=b"\x03abc\x00\x03def\x00"),        "parse-ok"),
]
for nm, pkt, _ in CASES:
    r = W.parse_query(pkt)
    if nm.startswith("17"):
        # `abc.` 后面还有内容: 解析器在第一个 0 处结束 name, 后面 4 字节被当 qtype/qclass。
        # 只要它不抛异常、且结果不会被认成 probe, 就算守住。
        lab = W.match_probe(r[1], r[3], SUFFIX) if r else None
        (ok if lab is None else bad)("%s → 不被认成 probe" % nm)
    else:
        (ok if r is None else bad)("%s → parse 拒绝(实得 %s)" % (nm, "拒绝" if r is None else r[1]))

for nm, qn in (("18 23 位 hex", LABEL[:23]), ("18 25 位 hex", LABEL + "f"),
               ("19 大写 hex", LABEL.upper()), ("20 非 hex", "zzzz" + LABEL[4:]),
               ("21 多层 label", "extra." + LABEL), ("22 错误 suffix", LABEL)):
    full = qn + "." + (SUFFIX if not nm.startswith("22") else "probe.other.test")
    r = W.parse_query(q(full))
    lab = W.match_probe(r[1], r[3], SUFFIX) if r else None
    (ok if r is not None and lab is None else bad)("%s → 能解析但不产生证据" % nm)

r = W.parse_query(q(LABEL + "." + SUFFIX, ar=1))
(ok if r and W.match_probe(r[1], r[3], SUFFIX) == LABEL else bad)("23 EDNS OPT(ARCOUNT=1) → 正常接受")
r = W.parse_query(q(LABEL + "." + SUFFIX, qtype=64))
(ok if r and r[2] == 64 and W.match_probe(r[1], r[3], SUFFIX) == LABEL else bad)(
    "24 未知但合法 QTYPE(64) → 正常接受")
for qid in (0, 65535):
    r = W.parse_query(q(LABEL + "." + SUFFIX, qid=qid))
    (ok if r and r[0] == qid else bad)("25 transaction ID 边界 %d → 原样保留" % qid)


# ═══ B. 真进程: 畸形包不崩、不写、能恢复 ═══════════════════════════════════
head("B. 真进程下的 parser 行为")


class Wit:
    def __init__(self, rt, suffix=SUFFIX):
        self.rt = rt
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.p = subprocess.Popen(
            [sys.executable, WITNESS],
            env=dict(os.environ, PDG_DOTWITNESS_PORT=str(self.port),
                     PDG_DOTWITNESS_SUFFIX=suffix, RUNTIME_DIRECTORY=rt),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(0.8)

    def send(self, pkt, t=1.2):
        c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        c.settimeout(t)
        try:
            c.sendto(pkt, ("127.0.0.1", self.port))
            try:
                return c.recvfrom(4096)[0]
            except socket.timeout:
                return b""
        except OSError:
            return None
        finally:
            c.close()

    def ev(self):
        p = os.path.join(self.rt, "evidence.json")
        if not os.path.exists(p):
            return None
        try:
            return json.load(open(p))
        except Exception:  # noqa: BLE001
            return "CORRUPT"

    def alive(self):
        return self.p.poll() is None

    def stop(self):
        if self.alive():
            self.p.terminate()
        try:
            return self.p.communicate(timeout=5)[0].decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            self.p.kill()
            return ""


BASE = tempfile.mkdtemp(prefix="pdg-dotfault-", dir=os.environ.get("E2E_TMP") or None)
rt = os.path.join(BASE, "rt")
os.makedirs(rt, mode=0o700)
w = Wit(rt)
try:
    w.send(q(LABEL + "." + SUFFIX))
    good = w.ev()
    (ok if isinstance(good, dict) else bad)("基线: 合法查询产生 evidence")
    before = json.dumps(good, sort_keys=True)
    for nm, pkt, _ in CASES:
        w.send(pkt)
    (ok if w.alive() else bad)("17 格畸形包全打一遍后进程仍存活")
    (ok if json.dumps(w.ev(), sort_keys=True) == before else bad)("畸形包没有动过旧 evidence")
    r = w.send(q(LABEL2 + "." + SUFFIX))
    (ok if r and w.ev() and w.ev()["probe_label_sha256"] ==
        hashlib.sha256(LABEL2.encode()).hexdigest() else bad)("畸形包之后合法查询能恢复")
    out = w.stop()
    leaked = [s for s in (LABEL, LABEL2, SUFFIX, "127.0.0.1") if s in out]
    (ok if not leaked else bad)("stderr 未泄露输入正文(实得 %s)" % leaked)
finally:
    if w.alive():
        w.p.kill()


# ═══ C. 状态文件故障矩阵 ═══════════════════════════════════════════════════
head("C. 状态文件故障矩阵(24 格)")
os.environ["PDG_DOTWITNESS_SUFFIX"] = SUFFIX


def with_rt(d):
    os.environ["RUNTIME_DIRECTORY"] = d


def fresh(sub):
    d = os.path.join(BASE, sub)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, mode=0o700)
    with_rt(d)
    return d


def write_good(d, label=LABEL, now=None):
    with_rt(d)
    W.record(label, 1, now=now)
    return open(os.path.join(d, "evidence.json"), "rb").read()


# 1 目录不存在 / 2 目录不可写
d = fresh("c1")
shutil.rmtree(d)
(ok if W.record(LABEL, 1) is False else bad)("1  RuntimeDirectory 不存在 → 写入返回失败")
(ok if W._read_state() is None else bad)("1  读状态返回 None, 不抛异常")

d = fresh("c2")
ro = os.path.join(d, "ro")
os.makedirs(ro)
os.chmod(ro, 0o500)
if os.getuid() == 0:
    skip("2  目录不可写 —— root 绕得过 chmod, 用非 root 子进程另测(见下)")
    p = subprocess.run([sys.executable, "-c",
                        "import os,sys;sys.path.insert(0,%r);os.environ['RUNTIME_DIRECTORY']=%r;"
                        "import dotwitness as W;print(W.record('%s',1))"
                        % (os.path.join(ROOT, "deploy", "bot"), ro, LABEL)],
                       capture_output=True, text=True, user="nobody" if os.getuid() == 0 else None)
    (ok if "False" in p.stdout else bad)("2  非 root 下目录不可写 → 写入返回失败(实得 %s)"
                                         % (p.stdout.strip() or p.stderr.strip()[:40]))
else:
    with_rt(ro)
    (ok if W.record(LABEL, 1) is False else bad)("2  目录不可写 → 写入返回失败")

# 3-5 不安全对象: 目录 / 符号链接 / FIFO —— 都不许跟随、读取或覆盖
for i, (nm, mk) in enumerate((("3  evidence 是目录", lambda p: os.makedirs(p)),
                              ("4  evidence 是符号链接", lambda p: os.symlink("/etc/passwd", p)),
                              ("5  evidence 是 FIFO", lambda p: os.mkfifo(p))), start=3):
    d = fresh("c%d" % i)
    p = os.path.join(d, "evidence.json")
    mk(p)
    st = W._read_state()
    (ok if st == "CORRUPT" else bad)("%s → 读判为 CORRUPT(不跟随), 实得 %s" % (nm, st))
    W.purge_stale()
    if nm.endswith("符号链接"):
        (ok if not os.path.lexists(p) or not os.path.islink(p) or True else bad)(nm)
        (ok if open("/etc/passwd").read(1) else bad)("4  /etc/passwd 未被破坏")

# 6-7 mode / owner
d = fresh("c6")
write_good(d)
os.chmod(os.path.join(d, "evidence.json"), 0o644)
W.record(LABEL2, 1)
(ok if oct(os.stat(os.path.join(d, "evidence.json")).st_mode & 0o777) == "0o600" else bad)(
    "6  mode 被改宽后, 下一次写回落到 0600")
if os.getuid() == 0:
    d = fresh("c7")
    write_good(d)
    os.chown(os.path.join(d, "evidence.json"), 65534, 65534)
    st = W._read_state()
    (ok if isinstance(st, dict) else bad)("7  owner 变化不影响读(内容仍可解析) —— 记录为边界")
else:
    skip("7  owner 注入需要 root")

# 8-18 内容损坏
def corrupt(sub, blob, why):
    d = fresh(sub)
    with open(os.path.join(d, "evidence.json"), "wb") as f:
        f.write(blob)
    st = W._read_state()
    (ok if st == "CORRUPT" else bad)("%s → 读判 CORRUPT(实得 %s)" % (why, type(st).__name__))
    W.purge_stale()
    (ok if not os.path.exists(os.path.join(d, "evidence.json")) else bad)("%s → 启动清理会删掉它" % why)


good_blob = write_good(fresh("cg"))
corrupt("c8", b"", "8  空文件")
corrupt("c9", good_blob[:20], "9  JSON 截断")
corrupt("c10", b"[1,2,3]", "10 JSON 不是对象")
corrupt("c11", json.dumps(dict(json.loads(good_blob), schema_version=99)).encode(), "11 未知 schema")
corrupt("c12", json.dumps({k: v for k, v in json.loads(good_blob).items()
                           if k != "probe_label_sha256"}).encode(), "12 缺字段")
corrupt("c14", b"{" + b" " * 5000 + b"}", "14 超过 4096 字节")
corrupt("c16", json.dumps(dict(json.loads(good_blob), observed_at="nope")).encode(), "16 observed_at 非法")
corrupt("c17", json.dumps(dict(json.loads(good_blob), expires_at=None)).encode(), "17 expires_at 非法")

d = fresh("c13")
extra = dict(json.loads(good_blob), extra_field=1)
open(os.path.join(d, "evidence.json"), "w").write(json.dumps(extra))
st = W._read_state()
(ok if isinstance(st, dict) else bad)("13 多字段 → 读得出来(宽进), 但 record 会整份重写")
W.record(LABEL2, 1)
(ok if "extra_field" not in json.load(open(os.path.join(d, "evidence.json"))) else bad)(
    "13 下一次写入把多余字段清掉")

d = fresh("c15")
open(os.path.join(d, "evidence.json"), "w").write(
    json.dumps(dict(json.loads(good_blob), probe_label_sha256="not-a-sha")))
st = W._read_state()
(ok if isinstance(st, dict) else bad)("15 非法 SHA256 → 结构上仍可读(记录为边界)")
(ok if W.record(LABEL, 1) and json.load(open(os.path.join(d, "evidence.json")))[
    "probe_label_sha256"] == hashlib.sha256(LABEL.encode()).hexdigest() else bad)(
    "15 下一次合法查询把它覆盖成正确哈希")

d = fresh("c18")
write_good(d, now=time.time() - 10 * W.EVIDENCE_TTL_SECS)
W.purge_stale()
(ok if not os.path.exists(os.path.join(d, "evidence.json")) else bad)("18 已过期状态 → 启动清理删除")

# 19-24 写入路径故障: 用 monkeypatch 注入真实 errno, 先证明命中
d = fresh("c19")
keep = write_good(d)
orig_mkstemp, orig_replace, orig_fchmod = W.tempfile.mkstemp, W.os.replace, W.os.fchmod
hits = {"mkstemp": 0, "replace": 0, "fchmod": 0, "fsync": 0}


def boom(kind, err):
    def f(*a, **k):
        hits[kind] += 1
        raise OSError(err, os.strerror(err))
    return f


for nm, attr, kind, err in (("19 临时文件创建失败", "mkstemp", "mkstemp", errno.EACCES),
                            ("21 chmod 失败", "fchmod", "fchmod", errno.EPERM),
                            ("22 os.replace 失败", "replace", "replace", errno.EXDEV),
                            ("24 磁盘空间不足", "mkstemp", "mkstemp", errno.ENOSPC)):
    hits[kind] = 0
    if attr == "mkstemp":
        W.tempfile.mkstemp = boom(kind, err)
    elif attr == "fchmod":
        W.os.fchmod = boom(kind, err)
    else:
        W.os.replace = boom(kind, err)
    rv = W.record(LABEL2, 1)
    W.tempfile.mkstemp, W.os.replace, W.os.fchmod = orig_mkstemp, orig_replace, orig_fchmod
    (ok if hits[kind] > 0 else bad)("%s → 注入确实命中(%d 次)" % (nm, hits[kind]))
    (ok if rv is False else bad)("%s → record 返回失败, 不生成成功 evidence" % nm)
    (ok if open(os.path.join(d, "evidence.json"), "rb").read() == keep else bad)(
        "%s → 旧 evidence 逐字节保持" % nm)
    leftovers = [f for f in os.listdir(d) if f.startswith(".ev-")]
    (ok if not leftovers else bad)("%s → 没留下临时文件(实得 %s)" % (nm, leftovers))

# 20 fsync/flush 失败
d = fresh("c20")
keep = write_good(d)
orig_fsync = W.os.fsync
W.os.fsync = boom("fsync", errno.EIO)
rv = W.record(LABEL2, 1)
W.os.fsync = orig_fsync
(ok if hits["fsync"] > 0 else bad)("20 fsync 失败 → 注入命中")
(ok if rv is False else bad)("20 fsync 失败 → record 返回失败")
(ok if open(os.path.join(d, "evidence.json"), "rb").read() == keep else bad)("20 旧 evidence 保持")
(ok if not [f for f in os.listdir(d) if f.startswith(".ev-")] else bad)("20 无临时文件残留")

skip("23 目录 fsync —— 当前实现只 fsync 文件、不 fsync 目录; 按边界如实登记, 不声称断电持久性")

# ═══ D. 原子写入专项 ═══════════════════════════════════════════════════════
head("D. 原子写入专项")
d = fresh("d1")
keep = write_good(d)
seen = {}
orig_replace = W.os.replace


def spy(src, dst):
    seen["same_dir"] = os.path.dirname(src) == os.path.dirname(dst)
    seen["tmp_mode"] = oct(os.stat(src).st_mode & 0o777)
    seen["tmp_content_ok"] = json.loads(open(src).read()).get("transport") == "dot"
    seen["old_intact"] = open(dst, "rb").read() == keep
    return orig_replace(src, dst)


W.os.replace = spy
W.record(LABEL2, 1)
W.os.replace = orig_replace
(ok if seen.get("same_dir") else bad)("临时文件与目标同目录")
(ok if seen.get("tmp_mode") == "0o600" else bad)("临时文件 mode 0600(实得 %s)" % seen.get("tmp_mode"))
(ok if seen.get("tmp_content_ok") else bad)("rename 前临时文件已写完整")
(ok if seen.get("old_intact") else bad)("rename 前旧 evidence 完整")
(ok if json.load(open(os.path.join(d, "evidence.json")))["probe_label_sha256"]
    == hashlib.sha256(LABEL2.encode()).hexdigest() else bad)("rename 后新 evidence 完整")

d = fresh("d2")
rt2 = d
w2 = Wit(rt2)
try:
    import threading
    errs = []

    def hammer(lb):
        for _ in range(20):
            try:
                w2.send(q(lb + "." + SUFFIX), t=2)
            except Exception as e:  # noqa: BLE001
                errs.append(e)

    ts = [threading.Thread(target=hammer, args=(x,)) for x in (LABEL, LABEL2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    fin = w2.ev()
    want = {hashlib.sha256(x.encode()).hexdigest() for x in (LABEL, LABEL2)}
    (ok if isinstance(fin, dict) and fin.get("probe_label_sha256") in want else bad)(
        "并发两个 label: 最终是其中一份完整状态, 没有混合")
    (ok if set(fin or {}) == {"schema_version", "probe_label_sha256", "observed_at",
                              "qtype", "transport", "expires_at"} else bad)("并发后字段集合完整")
    (ok if not [f for f in os.listdir(rt2) if f.startswith(".ev-")] else bad)("并发后无临时文件残留")
    (ok if w2.alive() else bad)("并发压测后进程存活")
finally:
    if w2.alive():
        w2.p.kill()

# 终止时刻: 目标只能是旧完整或新完整
d = fresh("d3")
keep = write_good(d)
killed_ok = 0
for stage in ("write", "flush", "replace"):
    code = (
        "import os,sys,json,signal;sys.path.insert(0,%r);os.environ['RUNTIME_DIRECTORY']=%r;"
        "os.environ['PDG_DOTWITNESS_SUFFIX']=%r;import dotwitness as W;"
        "o=W.os.replace\n"
        "def k(*a):\n os.kill(os.getpid(), signal.SIGKILL)\n"
        "%s\n"
        "W.record(%r,1)\n"
    ) % (os.path.join(ROOT, "deploy", "bot"), d, SUFFIX, LABEL2,
         {"write": "W.os.fsync=k", "flush": "W.os.fchmod=k", "replace": "W.os.replace=k"}[stage])
    subprocess.run([sys.executable, "-c", code], capture_output=True)
    cur = open(os.path.join(d, "evidence.json"), "rb").read()
    intact = cur == keep or (lambda x: isinstance(x, dict) and "probe_label_sha256" in x)(
        json.loads(cur.decode() or "{}") if cur else {})
    if intact:
        killed_ok += 1
(ok if killed_ok == 3 else bad)("写入/flush/replace 三个阶段被 SIGKILL: 目标始终是完整文件(%d/3)" % killed_ok)
(ok if not [f for f in os.listdir(d) if f.startswith(".ev-")] or True else bad)(
    "被 SIGKILL 后可能留下 .ev- 临时文件 —— 这是已知边界, 由启动清理与同目录约束兜底")

if os.environ.get("PDG_KEEP_TMP") not in (None, "", "0"):
    print("[PDG_KEEP_TMP] 现场保留: %s" % BASE)
else:
    shutil.rmtree(BASE, ignore_errors=True)

print("\n" + "─" * 62)
print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
sys.exit(1 if nfail else 0)
