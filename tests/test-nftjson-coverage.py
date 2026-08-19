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

# 清单来自**真实来源**, 不是想象出来的:
#   · deploy/firewall/nftables-mihomo.conf 的每一种规则行(模板是渲染出来的, 形态有限);
#   · 真机上两种注入形态 —— 救援放行(带 ip daddr + pdg-rescue 标记, 见交接文档第 15 节)、
#     证书 standalone 钩子(带 pdg-cert-http 标记, 第 16 节);
#   · tests/e2e-custom-nft.sh 喂进来的用户自定义规则。
# 新增一种在机形态时, 这里要跟着加一行 —— 否则它会被 UnknownSyntax 挡下(那是有意的)。
CASES = [
    ('iifname "tailscale0" return', 2, "iifname 匹配 + return 裁决"),
    ('iif "lo" accept', 2, "iif 匹配 + accept"),
    ('ip saddr 172.22.0.0/16 tcp dport 53 accept', 3, "saddr + dport + accept"),
    ('ip protocol icmp accept', 2, "protocol + accept"),
    ('ip6 nexthdr icmpv6 accept', 2, "ip6 nexthdr(icmpv6 归一为 ipv6-icmp)"),
    ('ct state established,related accept', 2, "ct state 集合 + accept"),
    ('ip saddr 172.22.0.0/16 tcp dport { 53, 81, 853 } accept', 3, "dport 集合"),
    ('ip saddr 172.22.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893',
     3, "dport 含区间 + redirect"),
    ('ip saddr 172.22.0.0/16 udp dport 443 reject', 3, "reject(补默认 icmp 类型)"),
    ('tcp dport { 22 } accept', 2, "单元素集合(不折叠成标量)"),
    ('udp dport 51820 accept', 2, "裸 udp dport"),
    ('ip saddr 172.22.0.0/16 ip daddr 10.0.0.5 tcp dport 8446 accept comment "pdg-rescue"',
     5, "救援注入形态: saddr + daddr + dport + accept + 标记"),
    ('tcp dport 80 accept comment "pdg-cert-http"', 3, "证书钩子形态: dport + accept + 标记"),
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

print("\n── 认不出来时必须出声, 不许丢半条 ──")
# 这是这支判据真正要守的东西。以前的行为是"能认多少认多少, 剩下的丢掉":
# `iifname "tailscale0" return` 变成裸 `return`, 规则还在、接口条件没了, 判据按接口名
# 永远找不到。丢一整条至少会让 audit_kernel 说"缺规则"; 丢半条给出的是一个看着正常的
# 错答案 —— 排查方向会被带偏好几轮(真 nft 环境同一份规则 12/12 全绿, 因为它自己出 JSON)。


def raw(rule_line):
    src = ("table inet pdg {\n  chain input {\n"
           "    type filter hook input priority 0; policy drop;\n"
           "    %s\n  }\n}\n" % rule_line)
    return subprocess.run([sys.executable, os.path.join(HERE, "nftjson.py"), "inet", "pdg"],
                          input=src, capture_output=True, text=True)


for line, why in (("meta mark 0x1 accept", "meta 匹配"),
                  ("ip saddr @allowlist accept", "命名集合"),
                  ("tcp flags syn counter accept", "flags/counter")):
    r = raw(line)
    if r.returncode == 0:
        bad("%-16s 未被察觉 —— 转换器丢掉了它却照常输出(这正是 iifname 那次的形态)" % why)
    elif r.returncode != 2 or "不认识这段语法" not in r.stderr:
        bad("%-16s 退了 %d 但没说清是桩看不懂: %s" % (why, r.returncode, r.stderr.strip()[:60]))
    else:
        ok("%-16s → 退 2 并点名是桩的覆盖不足(不是防火墙的问题)" % why)

# 反向: 不是规则的行(include / 括号)照旧安静跳过, 不许因为"有残渣"就误报
r = raw('include "/etc/privdns-gateway/nft-input.d/*.conf"')
if r.returncode != 0:
    bad("include 行触发了 rc=%d —— 它不是规则, 不该被当成看不懂的规则: %s"
        % (r.returncode, r.stderr.strip()[:60]))
elif [x for x in json.loads(r.stdout)["nftables"] if "rule" in x]:
    bad("include 行被造成了一条规则 —— 那是凭空捏造, 内核里没有这条")
else:
    ok("include 行安静跳过: rc=0、表与链照常输出、不造规则、不触发 UnknownSyntax")

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)
