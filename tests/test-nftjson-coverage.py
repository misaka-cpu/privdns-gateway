#!/usr/bin/env python3
"""nftjson.py 必须把规则里的**每个**表达式都转出来, 丢了就是静默失真。

E2E 沙箱里 `nft -j list table` 走的是这个转换器, 而 doctor/nftlive 读的正是它的输出。
转换器认不出某个匹配就把它**丢掉**, 于是内核状态里明明有那条规则, 判据却看不见 ——
`iifname "tailscale0" return` 就这么变成了裸 `return`, 六个升级类 E2E 因此全红,
而真 nft 环境下同一份规则 12/12 全绿(真 nft 自己出 JSON, 认识这些语法)。

难查的地方在于两条路径读的是**不同的 JSON 生成器**: 受控环境验证通过、E2E 被推翻,
反复几轮都指向别处。

判据: 逐条规则比对"转出的表达式个数", 而不是只看规则总数 —— 规则还在但匹配没了,
恰恰是最会骗人的形态。
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
npass = nfail = 0


def ok(m):
    global npass; npass += 1; print("[OK]   %s" % m)


def bad(m):
    global nfail; nfail += 1; print("[FAIL] %s" % m)


def conv(rule_line):
    src = ("table inet pdg {\n  chain input {\n"
           "    type filter hook input priority 0; policy drop;\n"
           "    %s\n  }\n}\n" % rule_line)
    p = subprocess.run([sys.executable, os.path.join(HERE, "nftjson.py"), "inet", "pdg"],
                       input=src, capture_output=True, text=True)
    if p.returncode != 0:
        return None
    rs = [x["rule"] for x in json.loads(p.stdout)["nftables"] if "rule" in x]
    return rs[0]["expr"] if rs else None


print("══ nftjson 表达式覆盖 ══\n")

CASES = [
    ('iifname "tailscale0" return', 2, "iifname 匹配 + return 裁决"),
    ('iif "lo" accept', 2, "iif 匹配 + accept"),
    ('ip saddr 172.22.0.0/16 tcp dport 53 accept', 3, "saddr + dport + accept"),
    ('ip protocol icmp accept', 2, "protocol + accept"),
]

for line, want, desc in CASES:
    expr = conv(line)
    if expr is None:
        bad("%-42s → 整条规则被丢弃" % desc)
        continue
    got = len(expr)
    if got >= want:
        ok("%-42s → %d 个表达式" % (desc, got))
    else:
        bad("%-42s → 只转出 %d 个, 少了 %d(表达式被静默丢弃: %s)"
            % (desc, got, want - got, json.dumps(expr, ensure_ascii=False)[:70]))

print("\n── iifname 必须能被按接口名找到 ──")
expr = conv('iifname "tailscale0" return') or []
found = any(e.get("match", {}).get("left", {}).get("meta", {}).get("key") in ("iifname", "iif")
            and e.get("match", {}).get("right") == "tailscale0" for e in expr)
if found:
    ok("转出的 JSON 里能按 iifname/tailscale0 定位到该规则")
else:
    bad("JSON 里找不到 iifname tailscale0 —— 判据据此判'缺少排除规则'")

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)
