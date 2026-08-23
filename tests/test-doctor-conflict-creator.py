#!/usr/bin/env python3
"""doctor 的两处补强: 报防火墙冲突时点名可能的制造者, 以及 Tailscale 卸载残留。

**为什么值得一支测试**

一、"是谁建的"。判据说"有冲突"一直是对的, 但只说这一句, 排查得从头做起。本轮在生产机
上定位一条 80 放行花了七八步, 卡点是: `nft list` **显示不出 iptables 的 comment 匹配**。
那条规则在 nft 眼里只是 `tcp dport 80 counter accept` —— 看不出来历也看不出归属; 换
`iptables -S` 一看就是 `-m comment --comment proxy-gateway-cert-http`, 名字直接写在
上面。所以这里要验的不是"提示文案还在", 而是**真的用 iptables 视角看了一遍并把
comment 带了出来**。桩就是一个假的 iptables。

二、卸载残留。`src_valid_mark` 与 `/usr/bin/tailscale` 都是 Tailscale 自己的行为, 不是
本项目造成的 —— 但只有本项目的 doctor 会去看。这一项的要害是**判据只在卸载之后成立**:
装着的时候 src_valid_mark=1 完全正常, 那时报警等于每台装了 Tailscale 的机器平白多一条
黄灯, 而黄灯多了就没人看了。所以"装着不报"这一格与"卸了要报"同等重要。
"""
import os
import stat
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard                                                  # noqa: E402
import checks                                                    # noqa: E402
import nftscan                                                   # noqa: E402

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


# ══ 一、creator_hints: 真的换 iptables 视角看了一遍 ═══════════════════════════
IPT_RULES = """-P INPUT ACCEPT
-N ts-input
-A INPUT -p tcp -m tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT
-A INPUT -j ts-input
-A ts-input -s 100.115.92.0/23 -i tailscale0 -j ACCEPT
"""


def stub_ipt(body, rc=0):
    """把一个假的 iptables 放到 PATH 最前面, 返回该目录。"""
    d = tmpguard.mkdtemp(prefix="pdg-ipt-")
    p = os.path.join(d, "iptables")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\ncat <<'PDGEOF'\n%s\nPDGEOF\nexit %d\n" % (body, rc))
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    # ip6tables 也要有, 否则那一半会静默跳过 —— 跳过与"看了但没有"不是一回事。
    with open(os.path.join(d, "ip6tables"), "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\nexit 1\n")
    os.chmod(os.path.join(d, "ip6tables"),
             os.stat(os.path.join(d, "ip6tables")).st_mode | stat.S_IEXEC)
    return d


_orig_path = os.environ.get("PATH", "")
os.environ["PATH"] = stub_ipt(IPT_RULES) + os.pathsep + _orig_path
hints = nftscan.creator_hints()
txt = "\n".join(hints)

if "证书 HTTP 放行钩子" in txt:
    ok("命中已知签名 proxy-gateway-cert-http → 点名了证书续期钩子")
else:
    bad("没认出 proxy-gateway-cert-http: %r" % txt[:160])
if "Tailscale" in txt:
    ok("命中 ts-input → 点名了 Tailscale")
else:
    bad("没认出 ts-input")
if "--comment proxy-gateway-cert-http" in txt:
    ok("把带 comment 的规则原文列了出来(这正是 nft list 看不到的东西)")
else:
    bad("没有列出 comment 原文 —— 只报个数字, 排查照样得从头做")
if "iptables -S" in txt and "看不到" in txt:
    ok("明说了 comment 在 nft list 里看不到, 要换 iptables -S")
else:
    bad("没告诉用户该换工具 —— 那正是本轮花掉七八步的卡点")

# ── 反向对照: 表是空的(只有 -P 策略行)时不许硬凑提示 ──
# 少这一格的话, 把 creator_hints 写成"永远返回一句套话"也能全绿, 而那种提示只会误导。
os.environ["PATH"] = stub_ipt("-P INPUT ACCEPT\n-P FORWARD ACCEPT\n") + os.pathsep + _orig_path
empty = nftscan.creator_hints()
if not empty:
    ok("反向对照: iptables 表里只有策略行 → 不给任何提示(不硬凑)")
else:
    bad("反向对照: 空表也编出了提示 %r —— 那会把排查引向错误方向" % empty[:2])

# ── 反向对照: 拿不到 iptables 时安静退场, 不能报错 ──
# 判据本身绝不依赖这些提示 —— 拿不到就少几行, 不能影响"有没有冲突"的结论。
os.environ["PATH"] = tmpguard.mkdtemp(prefix="pdg-noipt-")
try:
    none = nftscan.creator_hints()
    ok("PATH 里没有 iptables → 安静返回 %d 条, 不抛异常" % len(none))
except Exception as e:                                           # noqa: BLE001
    bad("拿不到 iptables 时抛了 %s —— 会把 doctor 整项带崩" % type(e).__name__)
os.environ["PATH"] = _orig_path

# ══ 二、check_tailscale_residue ══════════════════════════════════════════════
def scene(has_iface, svm, has_bin, installed=False):
    """造一个现场, 返回 (level, name, detail)。

    `installed` = Tailscale 这个**包**还在不在。判据里它是"能不能谈残留"的前提, 与接口
    在不在是两回事 —— `tailscale down` 之后接口没了包还在, 那时报残留是误诊
    (见 tests/negctl/tailscale-residue-misdiagnosis.py)。所以这里必须能分别摆布。
    """
    d = tmpguard.mkdtemp(prefix="pdg-tsres-")
    dev = os.path.join(d, "net_dev")
    with open(dev, "w", encoding="utf-8") as fh:
        fh.write("Inter-|   Receive\n face |bytes\n    lo:  0 0\n  eth0:  0 0\n")
        if has_iface:
            fh.write("tailscale0:  0 0\n")
    checks.PROC_NET_DEV = dev
    if svm is None:
        checks.SRC_VALID_MARK = os.path.join(d, "absent")
    else:
        m = os.path.join(d, "svm")
        with open(m, "w", encoding="utf-8") as fh:
            fh.write("%s\n" % svm)
        checks.SRC_VALID_MARK = m
    b = os.path.join(d, "tailscale")
    if has_bin:
        open(b, "w").close()
    checks.TAILSCALE_BIN = b
    # 包的两个凭据: dpkg 认领、unit 文件在。测试机自己可能装着 tailscale, 所以两个都得
    # 按场景摆，不能让真实环境漏进来。
    checks.TAILSCALED_UNIT = os.path.join(d, "tailscaled.service")
    if installed:
        open(checks.TAILSCALED_UNIT, "w").close()
    old_run = checks._run
    checks._run = lambda cmd, t=10: (
        (0, "tailscale: /usr/bin/tailscale\n", "") if installed
        else (1, "", "no path found")) if cmd and cmd[0] == "dpkg-query" else old_run(cmd, t)
    try:
        return checks.check_tailscale_residue()
    finally:
        checks._run = old_run


lvl, _, det = scene(has_iface=True, svm=1, has_bin=True, installed=True)
if lvl == "ok":
    ok("tailscale0 还在 → 判 ok(装着的时候 src_valid_mark=1 本来就是正常的)")
else:
    bad("装着 Tailscale 也报警(%s) —— 每台用 Tailscale 的机器都会平白多一条黄灯" % lvl)

lvl, _, det = scene(has_iface=False, svm=1, has_bin=False, installed=False)
if lvl == "warn" and "src_valid_mark" in det:
    ok("卸了但 src_valid_mark 仍是 1 → 报警并点名那个参数")
else:
    bad("卸载残留没报出来: lvl=%s det=%r" % (lvl, det[:120]))
if "sysctl -w" in det:
    ok("给出了可直接执行的还原命令")
else:
    bad("只报问题不给处置动作")
if "重启" in det:
    ok("说明了它重启后会自己变回去(否则「重启前后行为不一致」无从解释)")
else:
    bad("没说重启会还原 —— 那是这条最难查的后果")

lvl, _, det = scene(has_iface=False, svm=0, has_bin=True, installed=False)
if lvl == "warn" and "tailscale" in det and "rm -f" in det:
    ok("残留二进制被报出来并给了删除命令")
else:
    bad("残留二进制没报: lvl=%s det=%r" % (lvl, det[:120]))

lvl, _, det = scene(has_iface=False, svm=0, has_bin=False, installed=False)
if lvl == "ok":
    ok("卸干净了 → 判 ok")
else:
    bad("干净现场也报警(%s): %r" % (lvl, det[:120]))

# 内核没有这个参数(旧内核 / 容器)不是问题, 不该报
lvl, _, det = scene(has_iface=False, svm=None, has_bin=False)
if lvl == "ok":
    ok("内核没有 src_valid_mark 这个参数 → 判 ok(不是问题)")
else:
    bad("参数不存在也报警(%s) —— 容器里会满屏黄灯: %r" % (lvl, det[:120]))

# ══ 三、这一项真的进了 doctor 的检查表 ═══════════════════════════════════════
# 写了函数没接线 = 永远不会跑。这条便宜, 但漏了就整支测试都在验一个死代码。
if checks.check_tailscale_residue in checks.ALL:
    ok("check_tailscale_residue 已接进 checks.ALL(doctor 会真的跑它)")
else:
    bad("函数写了却没进 checks.ALL —— 永远不会被执行")

print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)
