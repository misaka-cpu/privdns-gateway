#!/usr/bin/env python3
"""负控: tailnet Access controls 的 deep 探测**不许**把"探不到"当成"已收紧"。

这条负控存在的理由, 是本项目自己写出来过的一个安全假绿:

    check_deep_lan_acl() 从面板表所在的 /24 里**猜**一个"通常没人用"的地址去连,
    连不上(timeout / EHOSTUNREACH)就判 ok, 文案写"ACL 边界成立"。

问题在于**猜的那个地址本来就可能不存在**。地址不存在时:

    tailnet 是默认 allow-all  → 包发出去, 没人应答 → timeout
    tailnet 收紧成只允许几个  → 包被丢在半路     → timeout

两种情形给出**完全相同的观测**。所以那个绿灯证明不了任何事 —— 它只证明"这个猜出来的
地址没有回应", 而那与 Access controls 配没配根本无关。

能证明什么、不能证明什么, 分界很清楚:

  · 连上了 / 收到 RST  → 包**到达了对端**。这是确凿的越界证据 → FAIL。
  · 超时 / 不可达       → **无结论**。没有一个已知存活的 canary 做对照, 就没有校准,
                          量到的东西不能反推 Access controls 的状态 → WARN。

本文件只跑判据本身(不发真包), 与 tests/test-lan-doctor.py 的区别是: 那支盯正向行为,
这支专门盯"不许把无结论说成安全"。
"""
import importlib.util
import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
C = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(C)

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("  ✓ %s" % m)
def bad(m): FAIL[0] += 1; print("  ✗ %s" % m)

CFG = {"panels": [
    {"name": "p0", "host": "p0.example.test", "target": "http://192.168.50.10:443"},
    {"name": "p1", "host": "p1.example.test", "target": "http://192.168.50.20:8080"},
]}


def run(exc):
    class FakeSock:
        def settimeout(self, t): pass
        def connect(self, addr):
            if exc is not None:
                raise exc
        def close(self): pass

    old = {k: getattr(C, k) for k in ("_lan_cfg", "_lan_on")}
    C._lan_cfg = lambda: CFG
    C._lan_on = lambda: (True, True)
    real = socket.socket
    socket.socket = lambda *a, **k: FakeSock()
    try:
        return C.check_deep_lan_acl()
    finally:
        socket.socket = real
        for k, v in old.items():
            setattr(C, k, v)


# ── 一、探不到 ≠ 已收紧 ─────────────────────────────────────────────────────
for label, exc in (("超时", socket.timeout()),
                   ("EHOSTUNREACH", OSError(113, "No route to host")),
                   ("ENETUNREACH", OSError(101, "Network is unreachable"))):
    st, _n, msg = run(exc)
    if st == "ok":
        bad("%s 被判成 ok —— 猜出来的地址探不到, 证明不了 Access controls 已收紧" % label)
    elif st == "warn":
        ok("%s → warn(无结论), 没有冒充安全证明" % label)
    else:
        bad("%s 判成了 %r, 期望 warn" % (label, st))

# 文案也要说清楚, 不能只是状态对而话还是老话
st, _n, msg = run(socket.timeout())
if any(w in msg for w in ("无法证明", "不能证明", "无结论", "未验证")):
    ok("超时的说明里点明了'不能据此证明已收紧'")
else:
    bad("超时的说明没有点明这一点, 用户仍会当成安全证明: %r" % msg)
for w in ("边界成立", "边界看起来是收紧", "被丢弃 —— ACL 边界"):
    if w in msg:
        bad("超时的说明里仍有旧断言 %r" % w)
        break
else:
    ok("超时的说明里没有旧的'边界成立'式断言")

# ── 二、确凿的越界仍然要 FAIL ───────────────────────────────────────────────
st, _n, msg = run(None)
ok("连上了 → fail") if st == "fail" else bad("连上了却判成 %r —— 那是确凿的越界" % st)

st, _n, msg = run(ConnectionRefusedError(111, "refused"))
ok("收到 RST → fail(包到达了对端)") if st == "fail" else bad("RST 判成了 %r" % st)

# ── 三、没有已知存活的 canary 时, 整项就该是"未验证" ────────────────────────
# 判据不能只看某一次 connect 的结果, 它必须知道"我这次量的东西有没有校准物"。
st, _n, msg = run(socket.timeout())
if st == "warn" and ("canary" in msg or "校准" in msg or "已知存活" in msg or "对照" in msg):
    ok("说明里点出了缺少校准物(canary/对照)这个根因")
else:
    bad("没有说清'为什么无结论' —— 用户不知道要补什么: %r" % msg)

print("─" * 60)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
