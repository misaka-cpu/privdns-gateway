#!/usr/bin/env python3
"""负控: "Tailscale 卸载残留"这一项**不许**只凭 tailscale0 不在就断定它被卸了。

原判据一句话: 没有 tailscale0 接口 = 已卸载, 于是把 src_valid_mark=1 和
/usr/bin/tailscale 都当成残留报出来, 并建议 `rm -f /usr/bin/tailscale`。

接口不在的原因远不止"卸了":

  · `tailscale down`            —— 用户主动断开, 包还在, 二进制归 dpkg 管;
  · tailscaled 临时停/重启中     —— 运维动作, 几秒钟的窗口;
  · 装好了但从没 `tailscale up`  —— 全新机器, 接口根本还没被创建过。

这三种情形下, src_valid_mark=1 是**正常的**(装着就该是 1), /usr/bin/tailscale 也是
**包自己的文件**。照原判据会得到两条错误建议, 其中一条是让用户 `rm -f` 掉一个 dpkg
拥有的文件 —— 那会让包处于破损状态, 而且下次 `apt upgrade` 之前没人看得出来。

这支负控盯三件事: 判"已卸载"要有卸载的凭据; 装着的时候不许报残留; 任何时候都不许
建议删一个包拥有的文件。
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
C = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(C)

PASS_, FAIL_ = [0], [0]
def ok(m):  PASS_[0] += 1; print("  ✓ %s" % m)
def bad(m): FAIL_[0] += 1; print("  ✗ %s" % m)

import builtins
import os

_real_open, _real_exists = builtins.open, os.path.exists


def run(iface, svm, bin_exists, dpkg_owns, unit_exists, netdev_readable=True):
    """把一台机器的状态摆出来, 跑判据。

    iface           tailscale0 在不在
    svm             src_valid_mark 的值(None = 内核没这个参数)
    bin_exists      /usr/bin/tailscale 在不在
    dpkg_owns       那个文件归不归 dpkg 管(= 包还装着)
    unit_exists     tailscaled.service 的 unit 文件在不在(= 包还装着)
    """
    def fake_open(path, *a, **k):
        p = str(path)
        if p == C.PROC_NET_DEV:
            if not netdev_readable:
                raise OSError(13, "Permission denied")
            body = "Inter-|   Receive\n face |bytes\n    lo:  0\n"
            if iface:
                body += " tailscale0:  0\n"
            return _real_open(os.devnull, "r") if False else __import__("io").StringIO(body)
        if p == C.SRC_VALID_MARK:
            if svm is None:
                raise OSError(2, "No such file")
            return __import__("io").StringIO("%s\n" % svm)
        return _real_open(path, *a, **k)

    known = {C.TAILSCALE_BIN: bin_exists}
    for attr in ("TAILSCALED_BIN", "TAILSCALED_UNIT"):
        if hasattr(C, attr):
            known[getattr(C, attr)] = unit_exists

    def fake_exists(path):
        p = str(path)
        if p in known:
            return known[p]
        return _real_exists(path)

    def fake_run(cmd, t=10):
        if cmd and cmd[0] in ("dpkg-query", "dpkg"):
            return (0, "tailscale: /usr/bin/tailscale\n", "") if dpkg_owns \
                else (1, "", "dpkg-query: no path found matching pattern\n")
        return (1, "", "")

    old_run = getattr(C, "_run")
    builtins.open, os.path.exists, C._run = fake_open, fake_exists, fake_run
    try:
        return C.check_tailscale_residue()
    finally:
        builtins.open, os.path.exists, C._run = _real_open, _real_exists, old_run


RM = "rm -f /usr/bin/tailscale"
SVM = "src_valid_mark"

# ── ① tailscale down: 接口没了, 包还在 ─────────────────────────────────────
st, _n, msg = run(iface=False, svm="1", bin_exists=True, dpkg_owns=True, unit_exists=True)
if RM in msg:
    bad("`tailscale down` 之后建议删 dpkg 拥有的 /usr/bin/tailscale —— 会把包弄破")
else:
    ok("`tailscale down` 之后没建议删包里的文件")
if SVM in msg:
    bad("`tailscale down` 之后仍把 src_valid_mark=1 报成残留 —— 装着时它本来就该是 1")
else:
    ok("`tailscale down` 之后不把 src_valid_mark=1 当残留")
if "卸载残留" in msg and "没有" not in msg:
    bad("`tailscale down` 被描述成了卸载残留: %r" % msg)
else:
    ok("`tailscale down` 没有被描述成卸载残留")

# ── ② tailscaled 临时停 ───────────────────────────────────────────────────
st, _n, msg = run(iface=False, svm="1", bin_exists=True, dpkg_owns=True, unit_exists=True)
if st in ("ok", "warn") and RM not in msg and SVM not in msg:
    ok("tailscaled 停着(包还在) → 不报残留")
else:
    bad("tailscaled 停着却报了残留: [%s] %r" % (st, msg))

# ── ③ 装好了但从没 up 过: 没有接口, 没有 unit 之外的任何痕迹 ───────────────
st, _n, msg = run(iface=False, svm=None, bin_exists=True, dpkg_owns=True, unit_exists=True)
if RM in msg:
    bad("全新装好还没 up, 就被建议删掉二进制")
else:
    ok("装好但没 up → 不建议删二进制")

# ── ④ 二进制归 dpkg 管时, 永远不许建议 rm ─────────────────────────────────
for label, kw in (("接口在", dict(iface=True)), ("接口不在", dict(iface=False))):
    st, _n, msg = run(svm="1", bin_exists=True, dpkg_owns=True, unit_exists=True, **kw)
    if RM in msg:
        bad("%s + dpkg 拥有该文件, 却建议 rm -f" % label)
    else:
        ok("%s + dpkg 拥有该文件 → 不建议 rm -f" % label)

# ── ⑤ 真的卸干净了: 没接口、没 unit、dpkg 也不认这个文件 ───────────────────
st, _n, msg = run(iface=False, svm="1", bin_exists=True, dpkg_owns=False, unit_exists=False)
if st == "warn" and RM in msg and SVM in msg:
    ok("真残留(孤儿二进制 + src_valid_mark=1) → warn, 两条建议都给")
else:
    bad("真残留没被报出来: [%s] %r" % (st, msg))

st, _n, msg = run(iface=False, svm="0", bin_exists=False, dpkg_owns=False, unit_exists=False)
if st == "ok":
    ok("卸干净且没留东西 → ok")
else:
    bad("卸干净了却不是 ok: [%s] %r" % (st, msg))

# ── ⑥ 读不到 /proc/net/dev: 无结论, 不许猜 ────────────────────────────────
st, _n, msg = run(iface=False, svm="1", bin_exists=True, dpkg_owns=False,
                  unit_exists=False, netdev_readable=False)
if st == "warn" and RM not in msg:
    ok("读不到 /proc/net/dev → warn 无结论, 不给删除建议")
else:
    bad("读不到 /proc/net/dev 却下了结论: [%s] %r" % (st, msg))

print("─" * 60)
print("通过 %d, 失败 %d" % (PASS_[0], FAIL_[0]))
sys.exit(1 if FAIL_[0] else 0)
