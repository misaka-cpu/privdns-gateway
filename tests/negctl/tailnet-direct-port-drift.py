#!/usr/bin/env python3
"""负控: 放行的 UDP 端口跟 tailscaled 实际监听的端口对不上时, doctor 必须报出来。

`pdg ssh-source tailnet` 会往 input 链插一条

    udp dport 41641 accept comment "pdg-tailnet-direct"

41641 是 Tailscale 的官方默认端口, 但**它是可配的**。Debian 12 上端口来自
`/etc/default/tailscaled` 的 `PORT=`, unit 经 `EnvironmentFile` 把它传给
`tailscaled --port=${PORT}`。项目里 41641 是**硬编码常量, 从不读那个文件**。

用户改了 `PORT=` 之后, 这条放行就静默地双向失效:

    41641 那条  → 没有监听者, 成了一个永远不会有人应答的陈旧洞;
    真正的端口  → 被 input 链的 policy drop 挡住。

后果是 `pdg ssh-source` 当初要消除的**冷启动窗口原样回来** —— 几小时没用 tailnet,
出事了想连进去, 第一次 SSH 必超时。而配置上完全看不出这两件事有关系: nft 里那条规则
好端端地写着 accept, `/etc/default/tailscaled` 里也好端端地写着另一个端口。

这支负控盯的是"两份配置的一致性", 不是"端口能不能连" —— 后者要发包, 而且**探不到证明
不了任何事**(见 lan-acl-false-green.py 的同类教训)。读文件是确定的, 发包不是。
"""
import importlib.util
import io
import os
import sys
import builtins
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
C = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(C)

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("  ✓ %s" % m)
def bad(m): FAIL[0] += 1; print("  ✗ %s" % m)

_open, _exists = builtins.open, os.path.exists

NFT_WITH = 'table inet pdg {\n chain input {\n  udp dport %d accept comment "pdg-tailnet-direct"\n }\n}\n'
NFT_NONE = 'table inet pdg {\n chain input {\n  tcp dport { 22 } accept\n }\n}\n'


def run(nft, defaults):
    """nft: /etc/nftables.conf 的内容; defaults: /etc/default/tailscaled 的内容(None=不存在)"""
    def fo(p, *a, **k):
        p = str(p)
        if p == C.NFT_CONF:
            if nft is None:
                raise OSError(2, "No such file")
            return io.StringIO(nft)
        if p == getattr(C, "TAILSCALED_DEFAULTS", "/etc/default/tailscaled"):
            if defaults is None:
                raise OSError(2, "No such file")
            return io.StringIO(defaults)
        return _open(p, *a, **k)

    def fe(p):
        p = str(p)
        if p == getattr(C, "TAILSCALED_DEFAULTS", "/etc/default/tailscaled"):
            return defaults is not None
        return _exists(p)

    builtins.open, os.path.exists = fo, fe
    try:
        fn = getattr(C, "check_tailnet_direct_port", None)
        if fn is None:
            return ("__MISSING__", "", "判据函数不存在")
        # 返回 None = "整项不适用"。统一成三元组, 免得每个断言都要先判空。
        return fn() or (None, "", "(不适用)")
    finally:
        builtins.open, os.path.exists = _open, _exists


# ── ① 判据得先存在, 而且接进 doctor ─────────────────────────────────────────
fn = getattr(C, "check_tailnet_direct_port", None)
if fn is None:
    bad("checks.py 里没有 check_tailnet_direct_port —— 整支负控无从谈起")
else:
    ok("判据函数存在")
    if fn in getattr(C, "ALL", []):
        ok("已接进 checks.ALL(doctor 会真的跑它)")
    else:
        bad("没接进 checks.ALL —— 写了也不会被执行")

# ── ② 端口一致 → ok ────────────────────────────────────────────────────────
r = run(NFT_WITH % 41641, 'PORT="41641"\nFLAGS=""\n')
if r[0] == "ok":
    ok("nft 41641 + PORT=41641 → ok")
else:
    bad("两边一致却判成了 %r: %s" % (r[0], r[2][:80]))

# ── ③ 端口漂移 → 必须报出来, 而且要把两个数字都说出来 ──────────────────────
r = run(NFT_WITH % 41641, 'PORT="45678"\n')
if r[0] in ("warn", "fail"):
    ok("nft 41641 + PORT=45678 → %s" % r[0])
else:
    bad("端口对不上却判成了 %r —— 冷启动窗口会静默回来" % (r[0],))
if "41641" in r[2] and "45678" in r[2]:
    ok("文案里两个端口都点了名")
else:
    bad("文案没同时给出两个端口, 用户不知道该改哪个: %r" % r[2][:100])

# ── ④ 没收紧 SSH(nft 里没那条放行) → 整项不适用, 不能报警 ───────────────────
r = run(NFT_NONE, 'PORT="45678"\n')
if r[0] is None or r[0] == "ok":
    ok("没放行 41641(SSH 未收紧) → 不适用/ok, 不平白报警")
else:
    bad("SSH 没收紧却报了 %r —— 每台没用这功能的机器都会多一条灯" % (r[0],))

# ── ⑤ 读不到 /etc/default/tailscaled → 无结论, 不许猜 ──────────────────────
r = run(NFT_WITH % 41641, None)
if r[0] in ("ok", "warn", None):
    ok("读不到 tailscaled 默认值 → %r(不猜)" % (r[0],))
else:
    bad("读不到配置却下了结论: %r" % (r[0],))
if r[0] == "fail":
    bad("读不到就判 fail —— 那会让没装 Tailscale 的机器升级失败")

# ── ⑥ PORT 有空格/单引号等写法也要认 ───────────────────────────────────────
for txt, label in (("PORT=45678\n", "无引号"),
                   ("PORT='45678'\n", "单引号"),
                   ("  PORT = \"45678\"  \n", "带空格")):
    r = run(NFT_WITH % 41641, txt)
    if r[0] in ("warn", "fail"):
        ok("%s 写法也认得出漂移" % label)
    else:
        bad("%s 写法没认出来(判成 %r) —— 解析太脆" % (label, r[0]))

print("─" * 60)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
