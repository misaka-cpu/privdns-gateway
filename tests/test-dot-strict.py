#!/usr/bin/env python3
"""6.2A 收紧: evidence 严格 schema + 配置缺失时启动 fail-closed。

上一轮留下三处"宽进"的判定, 不能带进最终契约:
  · 多字段 evidence 被当成有效;
  · `probe_label_sha256` 不是 64 位 hex 也被读出来;
  · mode / owner 不对的状态文件照读不误。
再加一条更要紧的: 配置缺失或非法时 service 只是"不写证据", 却仍然 **active** ——
那是"看起来健康、其实永远不认任何查询"的假健康态, 比直接起不来更难被发现。

这支把这些钉成闭集: 任何不满足闭集的状态都不算有效 evidence。
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UNIT = os.path.join(ROOT, "deploy", "bot", "pdg-dotwitness.service")
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import dotwitness as W  # noqa: E402

npass = nfail = nskip = 0
LABEL = "a1b2c3d4e5f6a7b8c9d0e1f2"
SUFFIX = "probe.dot.strict.test"


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


BASE = tempfile.mkdtemp(prefix="pdg-dotstrict-", dir=os.environ.get("E2E_TMP") or None)
os.environ["PDG_DOTWITNESS_SUFFIX"] = SUFFIX


def fresh(sub):
    d = os.path.join(BASE, sub)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, mode=0o700)
    os.environ["RUNTIME_DIRECTORY"] = d
    return d


def good_rec(now=None):
    now = time.time() if now is None else now
    return {
        "schema_version": W.SCHEMA_VERSION,
        "probe_label_sha256": hashlib.sha256(LABEL.encode()).hexdigest(),
        "observed_at": now,
        "qtype": 1,
        "transport": "dot",
        "expires_at": now + W.EVIDENCE_TTL_SECS,
    }


def put(d, rec, mode=0o600):
    p = os.path.join(d, "evidence.json")
    with open(p, "w") as f:
        json.dump(rec, f)
    os.chmod(p, mode)
    return p


# ── 1. evidence 校验闭集 ────────────────────────────────────────────────────
head("1. evidence 校验闭集")
d = fresh("s0")
put(d, good_rec())
(ok if isinstance(W._read_state(), dict) else bad)("合法 evidence 被接受")

CASES = [
    ("多字段", lambda r: dict(r, extra=1)),
    ("缺字段", lambda r: {k: v for k, v in r.items() if k != "qtype"}),
    ("sha256 不是 64 位 hex", lambda r: dict(r, probe_label_sha256="not-a-sha")),
    ("sha256 含大写", lambda r: dict(r, probe_label_sha256=r["probe_label_sha256"].upper())),
    ("transport 非 dot", lambda r: dict(r, transport="udp")),
    ("qtype 是 bool", lambda r: dict(r, qtype=True)),
    ("qtype 超范围", lambda r: dict(r, qtype=70000)),
    ("qtype 是字符串", lambda r: dict(r, qtype="1")),
    ("observed_at 是 NaN", lambda r: dict(r, observed_at=float("nan"))),
    ("expires_at 是 inf", lambda r: dict(r, expires_at=float("inf"))),
    ("expires_at <= observed_at", lambda r: dict(r, expires_at=r["observed_at"])),
    ("生命周期超过 TTL 上限", lambda r: dict(r, expires_at=r["observed_at"] + 10 * W.EVIDENCE_TTL_SECS)),
    ("schema_version 不匹配", lambda r: dict(r, schema_version=W.SCHEMA_VERSION + 1)),
]
for i, (why, mut) in enumerate(CASES):
    d = fresh("s1_%d" % i)
    put(d, mut(good_rec()))
    st = W._read_state()
    (ok if st == "CORRUPT" else bad)("%s → 判 CORRUPT(实得 %s)" % (why, st if isinstance(st, str) else type(st).__name__))

# mode / owner
d = fresh("s2")
put(d, good_rec(), mode=0o644)
(ok if W._read_state() == "CORRUPT" else bad)("mode 不是 0600 → 不读取")
d = fresh("s3")
put(d, good_rec(), mode=0o604)
(ok if W._read_state() == "CORRUPT" else bad)("mode 放开 other → 不读取")

if os.getuid() == 0:
    d = fresh("s4")
    p = put(d, good_rec())
    os.chown(p, 65534, 65534)
    (ok if W._read_state() == "CORRUPT" else bad)("owner 不是当前 UID → 不读取")
    (ok if os.stat(p).st_uid == 65534 else bad)("不擅自 chown 回来")
else:
    skip("owner 注入需要 root —— 由真 systemd job 的 0 SKIP 结果补齐")

# ── 2. 启动清理对象矩阵 ─────────────────────────────────────────────────────
head("2. 启动清理对象矩阵")


def purge_case(sub, make, expect_gone, why):
    d = fresh(sub)
    p = os.path.join(d, "evidence.json")
    make(d, p)
    W.purge_stale()
    gone = not os.path.lexists(p)
    (ok if gone == expect_gone else bad)(
        "%s → 期望%s, 实得%s" % (why, "删除" if expect_gone else "保留", "删除" if gone else "保留"))


purge_case("p1", lambda d, p: put(d, good_rec()), False, "合法未过期 owner/mode 正确")
purge_case("p2", lambda d, p: put(d, good_rec(now=time.time() - 10 * W.EVIDENCE_TTL_SECS)),
           True, "已过期合法状态")
purge_case("p3", lambda d, p: open(p, "w").write("{oops"), True, "JSON 损坏")
purge_case("p4", lambda d, p: put(d, dict(good_rec(), extra=1)), True, "字段多")
purge_case("p5", lambda d, p: put(d, dict(good_rec(), probe_label_sha256="x")), True, "SHA 非法")
purge_case("p6", lambda d, p: put(d, good_rec(), mode=0o644), True, "mode 错(钉死为删除)")
purge_case("p7", lambda d, p: os.symlink("/etc/passwd", p), False, "symlink 不跟随不覆盖")
purge_case("p8", lambda d, p: os.mkfifo(p), False, "FIFO 不读不覆盖")
purge_case("p9", lambda d, p: os.makedirs(p), False, "目录 不读不覆盖")
(ok if open("/etc/passwd").read(1) else bad)("清理过程没有动到 symlink 指向的文件")

# .ev-* 临时文件: 只清自己的, 不按宽前缀删别人的
d = fresh("p10")
mine = os.path.join(d, ".ev-mine")
open(mine, "w").write("x")
os.chmod(mine, 0o600)
other = os.path.join(d, "unrelated.txt")
open(other, "w").write("keep me")
alien = os.path.join(d, ".ev-alien")
open(alien, "w").write("x")
os.chmod(alien, 0o644)                      # mode 不符本服务约束 = 不是我们写的
W.purge_stale()
(ok if not os.path.exists(mine) else bad)(".ev-* 符合本服务约束的临时文件被清理")
(ok if os.path.exists(other) else bad)("无关文件未被误删")
(ok if os.path.exists(alien) else bad)("不符合约束的 .ev-* 未被误删(不按宽前缀删)")

# ── 3. 配置缺失/非法时必须启动失败 ──────────────────────────────────────────
head("3. 配置缺失或非法 → 进程必须非零退出且不绑端口")
BAD_SUFFIXES = [
    ("(未设置)", None),
    ("空", ""),
    ("含空格", "a b.example"),
    ("含路径字符", "../etc/passwd"),
    ("前导点", ".probe.example"),
    ("连续双点", "probe..example"),
    ("label 超长", "%s.example" % ("x" * 64)),
    ("总长超过 DNS 上限", ".".join(["abcdefghij"] * 30)),
]
for why, val in BAD_SUFFIXES:
    d = fresh("b_%s" % re.sub(r"\W", "", why) or "b")
    env = dict(os.environ, RUNTIME_DIRECTORY=d)
    env.pop("PDG_DOTWITNESS_SUFFIX", None)
    if val is not None:
        env["PDG_DOTWITNESS_SUFFIX"] = val
    env["PDG_DOTWITNESS_PORT"] = "0"        # 让它自己选; 真起来了会绑上
    p = subprocess.Popen([sys.executable, os.path.join(ROOT, "deploy", "bot", "dotwitness.py")],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        out = p.communicate(timeout=4)[0].decode("utf-8", "replace")
        rc = p.returncode
    except subprocess.TimeoutExpired:
        p.kill()
        out = p.communicate()[0].decode("utf-8", "replace")
        rc = None
    (ok if rc not in (None, 0) else bad)(
        "suffix %s → 非零退出(实得 rc=%s)" % (why, "仍在跑" if rc is None else rc))
    leaked = [s for s in (val or "",) if s and s in out]
    (ok if not leaked else bad)("suffix %s → 错误输出不回显配置正文" % why)

os.environ["PDG_DOTWITNESS_SUFFIX"] = SUFFIX

# ── 4. unit 必须把 env 当必需 ───────────────────────────────────────────────
head("4. unit 的 EnvironmentFile 契约")
usrc = open(UNIT).read()
(ok if re.search(r"^EnvironmentFile=/etc/privdns-gateway/dotwitness\.env\s*$", usrc, re.M) else bad)(
    "EnvironmentFile 是必需形式(没有 `-` 前缀) —— 缺配置要在启动时就暴露")
(ok if not re.search(r"^EnvironmentFile=-", usrc, re.M) else bad)("没有可选形式的 EnvironmentFile")

if os.environ.get("PDG_KEEP_TMP") not in (None, "", "0"):
    print("[PDG_KEEP_TMP] 现场保留: %s" % BASE)
else:
    shutil.rmtree(BASE, ignore_errors=True)

print("\n" + "─" * 62)
print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
sys.exit(1 if nfail else 0)
