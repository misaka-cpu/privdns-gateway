#!/usr/bin/env python3
"""6.2A: 每会话 DoT 证据源的契约测试。

这支在实现之前先落地, 用来复现"证据源缺失"这件事本身。它**不是** grep 将来要写的源码:
每条断言要么真的去跑证据端(收发真 UDP DNS 报文), 要么真的解析 mosdns 配置的结构。
缺实现时应当报出"功能缺失"这一条, 而不是 Traceback / ImportError / 权限错误。

命题(本阶段唯一要证明的那条):
    钉定的 mosdns 能把「查询名属于本次探测命名空间, 且 TLS SNI 等于配置的 DoT 域名」的
    查询转给本地证据端; 明文 UDP/TCP 53、错误 SNI、普通域名, 以及只有 TLS 连接而没有
    DNS 查询, 都不能产生证据。
"""
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WITNESS = os.path.join(ROOT, "deploy", "bot", "dotwitness.py")
UNIT = os.path.join(ROOT, "deploy", "bot", "pdg-dotwitness.service")
MOSDNS = os.path.join(ROOT, "deploy", "mosdns", "config.yaml")

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def head(m):
    print("\n── %s ──" % m)


# ── 工具: 最小 DNS 线格式 ─────────────────────────────────────────────────────
def wire(qname, qtype=1, qid=0x2468):
    parts = [p for p in qname.rstrip(".").split(".") if p]
    q = b"".join(bytes([len(p)]) + p.encode("ascii") for p in parts) + b"\x00"
    return struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0) + q + struct.pack("!HH", qtype, 1)


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Witness:
    """把生产实现当外部进程跑起来。缺实现时 start() 返回 False —— 由调用方判 FAIL,
    不抛异常, 免得红灯变成 Traceback。"""

    def __init__(self, suffix="probe.dot.lab.test"):
        self.port = free_port()
        self.dir = tempfile.mkdtemp(prefix="pdg-dotw-")
        self.suffix = suffix
        self.proc = None

    def start(self):
        if not os.path.isfile(WITNESS):
            return False
        env = dict(os.environ)
        env["PDG_DOTWITNESS_PORT"] = str(self.port)
        env["PDG_DOTWITNESS_SUFFIX"] = self.suffix
        env["RUNTIME_DIRECTORY"] = self.dir
        self.proc = subprocess.Popen([sys.executable, WITNESS], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for _ in range(50):
            if self.query("probe-liveness-check.invalid", expect_reply=False) is not None:
                return True
            if self.proc.poll() is not None:
                return False
            time.sleep(0.1)
        return False

    def query(self, qname, qtype=1, expect_reply=True, raw=None, t=1.0):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(t)
        try:
            s.sendto(raw if raw is not None else wire(qname, qtype), ("127.0.0.1", self.port))
            try:
                return s.recvfrom(4096)[0]
            except socket.timeout:
                return b"" if expect_reply else None
        finally:
            s.close()

    def state(self):
        p = os.path.join(self.dir, "evidence.json")
        if not os.path.isfile(p):
            return None
        try:
            with open(p) as f:
                return json.load(f)
        except Exception:  # noqa: BLE001
            return "CORRUPT"

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                self.proc.kill()


LABEL = "a1b2c3d4e5f6a7b8c9d0e1f2"          # 12 字节 = 24 个小写 hex
SUFFIX = "probe.dot.lab.test"


# ── 1. 生产树是否已有证据端与 unit ───────────────────────────────────────────
head("1. 生产树里的证据源")
(ok if os.path.isfile(WITNESS) else bad)("证据端实现存在: deploy/bot/dotwitness.py")
(ok if os.path.isfile(UNIT) else bad)("证据端 unit 存在: deploy/bot/pdg-dotwitness.service")

# ── 2. mosdns 是否有受守卫的探测分支 ─────────────────────────────────────────
head("2. mosdns 探测分支")
cfg = open(MOSDNS).read() if os.path.isfile(MOSDNS) else ""


def probe_block():
    """把探测分支那一段取出来 —— 按结构定位, 不做全仓脆弱正则。"""
    m = re.search(r"\n(\s+)- matches:\n((?:\1\s+- .*\n)+)\1  exec: goto probe_seq\n", cfg)
    return m.group(2) if m else None


blk = probe_block()
(ok if blk else bad)("main_sequence 里有 `exec: goto probe_seq` 的受守卫分支")
if blk:
    (ok if re.search(r"qname suffix \S*probe\.", blk) else bad)("分支带 qname 探测后缀判据")
    (ok if re.search(r"string_exp server_name eq \S+", blk) else bad)("分支带 TLS server_name 判据")
else:
    bad("分支带 qname 探测后缀判据(分支不存在)")
    bad("分支带 TLS server_name 判据(分支不存在)")

if "probe_seq" in cfg and "lazy_cache" in cfg:
    (ok if cfg.index("goto probe_seq") < cfg.index("$lazy_cache") else bad)(
        "探测分支位于 lazy_cache 之前")
else:
    bad("探测分支位于 lazy_cache 之前(分支或 cache 不存在)")

# ── 3. 证据端行为契约 ────────────────────────────────────────────────────────
head("3. 证据端行为(真收发 UDP DNS 报文)")
w = Witness(SUFFIX)
started = w.start()
if not started:
    for m in ("正确 probe 查询能生成一笔证据",
              "证据只含 label 的 SHA256, 不含明文 label",
              "证据不含完整 qname",
              "证据不含来源 IP 字段",
              "A 与 AAAA 都得到 NOERROR/NODATA",
              "非 24 hex 的 label 不产生证据",
              "多层子域不产生证据",
              "其它后缀不产生证据",
              "畸形 DNS 包不崩溃且不产生证据",
              "同一 label 重复查询幂等",
              "状态文件 mode 为 0600",
              "probe label 契约是 24 个小写 hex"):
        bad("%s —— 证据端未实现或起不来" % m)
else:
    try:
        r = w.query("%s.%s" % (LABEL, SUFFIX))
        st = w.state()
        (ok if isinstance(st, dict) else bad)("正确 probe 查询能生成一笔证据")
        if isinstance(st, dict):
            blob = json.dumps(st, ensure_ascii=False)
            (ok if st.get("probe_label_sha256") and LABEL not in blob else bad)(
                "证据只含 label 的 SHA256, 不含明文 label")
            (ok if SUFFIX not in blob else bad)("证据不含完整 qname")
            (ok if not any(k in st for k in ("source_ipv4_16", "client_ip", "source")) else bad)(
                "证据不含来源 IP 字段")
            (ok if st.get("transport") == "dot" else bad)("transport 固定为 dot")
        else:
            bad("证据只含 label 的 SHA256, 不含明文 label")
            bad("证据不含完整 qname")
            bad("证据不含来源 IP 字段")
            bad("transport 固定为 dot")

        rc_a = (r[3] & 0x0F) if r and len(r) >= 4 else None
        an_a = struct.unpack("!H", r[6:8])[0] if r and len(r) >= 8 else None
        r6 = w.query("%s.%s" % (LABEL, SUFFIX), qtype=28)
        rc_aaaa = (r6[3] & 0x0F) if r6 and len(r6) >= 4 else None
        an_aaaa = struct.unpack("!H", r6[6:8])[0] if r6 and len(r6) >= 8 else None
        (ok if (rc_a, an_a, rc_aaaa, an_aaaa) == (0, 0, 0, 0) else bad)(
            "A 与 AAAA 都得到 NOERROR/NODATA(实得 rcode=%s/%s ancount=%s/%s)"
            % (rc_a, rc_aaaa, an_a, an_aaaa))

        for label, why in (("zz" + LABEL[2:], "非 hex"),
                           (LABEL[:23], "23 位"),
                           (LABEL + "f", "25 位"),
                           (LABEL.upper(), "大写 hex")):
            before = json.dumps(w.state(), sort_keys=True)
            w.query("%s.%s" % (label, SUFFIX))
            after = json.dumps(w.state(), sort_keys=True)
            (ok if before == after else bad)("%s 的 label 不产生新证据" % why)

        before = json.dumps(w.state(), sort_keys=True)
        w.query("extra.%s.%s" % (LABEL, SUFFIX))
        w.query("%s.probe.other.test" % LABEL)
        (ok if json.dumps(w.state(), sort_keys=True) == before else bad)(
            "多层子域与其它后缀不产生证据")

        for raw in (b"", b"\x00", b"\x12\x34", wire("%s.%s" % (LABEL, SUFFIX))[:20],
                    struct.pack("!HHHHHH", 1, 0x0100, 2, 0, 0, 0) + b"\x02aa\x00\x00\x01\x00\x01",
                    struct.pack("!HHHHHH", 1, 0x0100, 1, 0, 0, 0) + b"\xc0\x0c\x00\x01\x00\x01"):
            w.query("", raw=raw, expect_reply=False)
        alive = w.proc.poll() is None
        (ok if alive else bad)("畸形 DNS 包不崩溃")
        (ok if json.dumps(w.state(), sort_keys=True) == before else bad)("畸形 DNS 包不产生证据")

        w.query("%s.%s" % (LABEL, SUFFIX))
        s1 = w.state()
        w.query("%s.%s" % (LABEL, SUFFIX))
        s2 = w.state()
        (ok if s1 and s2 and s1.get("probe_label_sha256") == s2.get("probe_label_sha256")
            and s1.get("observed_at") == s2.get("observed_at") else bad)(
            "同一 label 重复查询幂等")

        p = os.path.join(w.dir, "evidence.json")
        mode = oct(os.stat(p).st_mode & 0o777) if os.path.exists(p) else "(无文件)"
        (ok if mode == "0o600" else bad)("状态文件 mode 为 0600(实得 %s)" % mode)
    finally:
        w.stop()

# ── 4. label 契约的单一真源 ──────────────────────────────────────────────────
head("4. probe label 契约")
src = open(WITNESS).read() if os.path.isfile(WITNESS) else ""
(ok if re.search(r"\[0-9a-f\]\{24\}", src) else bad)(
    "证据端把 label 契约钉成 24 个小写 hex(96 bit)")

# ── 5. 隐私闸门: api / query_summary 仍然禁止 ─────────────────────────────────
head("5. 隐私闸门")
(ok if not re.search(r"^\s*api:", cfg, re.M) else bad)("mosdns 配置没有开 api")
(ok if "query_summary" not in cfg else bad)("mosdns 配置没有引入 query_summary")
(ok if re.search(r"^log:\s*\n\s*level:\s*warn", cfg, re.M) else bad)("mosdns 日志级别仍是 warn")

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)
