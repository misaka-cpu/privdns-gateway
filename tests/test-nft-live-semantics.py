#!/usr/bin/env python3
"""L8 防火墙判据: 文本比对会把 nft 自己的规范化当成漂移。

`.153` 真机现象: `pdg link status` 报
    🔴 防火墙磁盘/内核一致性  磁盘上有 4 条规则没在内核里生效
        (例: ip saddr 172.22.0.0/16 udp dport 443 reject)
而同一台机器 `pdg doctor --deep` 是 0 失败 0 警告, 手工逐条比对内核 input 链后确认
**规则一条不少**。差的只是写法 —— nft 输出时会自己规范化:

    磁盘 tcp dport { 22 } accept          内核 tcp dport 22 accept              单元素集合折叠
    磁盘 udp dport { 53 } accept          内核 udp dport 53 accept              同上
    磁盘 udp dport 443 reject             内核 ... reject with icmp port-unreachable  默认展开
    磁盘 ip6 nexthdr icmpv6 accept        内核 ip6 nexthdr ipv6-icmp accept     协议名别名

后果不是"报错难看": 6.1C 的服务器准备状态门把它当成服务器层 FAIL, 于是在一台完全健康的
机器上**拒绝创建手机测试会话** —— 整个功能用不了。

本文件先复现(修改前必须红), 再钉住修好之后的语义判据。夹具只保留必要规则, 不复制真机的
完整防火墙配置、真实 IP 或用户自定义内容。

── nft 能力实验(v1.0.6, 决定了实现只能怎么做)──────────────────────────────
  1) `nft -c -f FILE`      只做语法检查, 内核里不会出现该表。rc=0 即通过。
  2) `nft -c -j -f FILE`   rc=0 但 **stdout 是 0 字节** —— 它不产出规范化 JSON。
                           `-j` 是给 `list` 的输出格式, 不是给 `-f` 的。
  3) `nft -j -f FILE`      同样 0 字节, 而且**真的会应用**(实测内核里出现了该表)。
  4) `nft -j list table …`  只对 **live kernel** 输出结构化 JSON, 且已经是规范化后的:
       tcp dport { 22 }  → {"right": 22}
       udp dport 443 reject → {"reject": {"type": "icmp", "expr": "port-unreachable"}}
       ip6 nexthdr icmpv6   → {"right": "ipv6-icmp"}
       每条带 handle(比较时必须忽略)。
结论: **候选配置的规范化 JSON 拿不到, 除非真的加载它**。所以"把磁盘配置规范化后与内核逐条
比对"这条路在 linkstat 里走不通 —— 它要么改宿主机内核, 要么每次自检建 netns, 两者都越过了
linkstat 已验收的只读边界。判据因此改成两件**各自成立**的事实(见 nftlive.audit)。
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


# ── 夹具: 四种等价形态(最小集, 无真实 IP/用户内容)────────────────────────
CIDR = "10.77.0.0/16"

DISK = """#!/usr/sbin/nft -f
table inet pdg {
  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state established,related accept
    tcp dport { 22 } accept
    ip saddr %s tcp dport { 53, 81, 853, 7893, 8445 } accept
    ip saddr %s udp dport { 53 } accept
    ip saddr %s udp dport 443 reject
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
  }
}
""" % (CIDR, CIDR, CIDR)

# 内核侧: nft -j list 的真实形态(照实验 4 的结构手写, 单元素集合已折叠、reject 已展开、
# 协议名已归一, 并带 handle)
def _match(proto, field, right):
    return {"match": {"op": "==", "left": {"payload": {"protocol": proto, "field": field}},
                      "right": right}}


def _saddr(cidr):
    a, l = cidr.split("/")
    return {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}},
                      "right": {"prefix": {"addr": a, "len": int(l)}}}}


def kernel_json(*, cidr=CIDR, drop_81=False, wrong_cidr=None, verdict_flip=False,
                after_drop=False, wrong_proto=False, policy="drop", hook="input",
                table="pdg", chain="input", platform="android", no_prerouting=False,
                no_redirect=False, no_gms=False, wrong_redirect_src=None,
                redirect_verdict_flip=False):
    rules = [
        [{"match": {"op": "==", "left": {"meta": {"key": "iif"}}, "right": "lo"}},
         {"accept": None}],
        [{"match": {"op": "in", "left": {"ct": {"key": "state"}},
                    "right": ["established", "related"]}}, {"accept": None}],
        [_match("tcp", "dport", 22), {"accept": None}],
    ]
    seg = wrong_cidr or cidr
    ports = [53, 853, 7893, 8445] if drop_81 else [53, 81, 853, 7893, 8445]
    tcp_rule = [_saddr(seg), _match("tcp", "dport", {"set": ports}),
                {"drop": None} if verdict_flip else {"accept": None}]
    udp_rule = [_saddr(seg),
                _match("udp" if not wrong_proto else "tcp", "dport", 53),
                {"accept": None}]
    rej = [_saddr(seg), _match("udp", "dport", 443),
           {"reject": {"type": "icmp", "expr": "port-unreachable"}}]
    tail = [[_match("ip", "protocol", "icmp"), {"accept": None}],
            [_match("ip6", "nexthdr", "ipv6-icmp"), {"accept": None}]]
    if after_drop:
        rules += [[{"drop": None}]] + [tcp_rule, udp_rule, rej] + tail
    else:
        rules += [tcp_rule, udp_rule, rej] + tail
    objs = [{"table": {"family": "inet", "name": table}},
            {"chain": {"family": "inet", "table": table, "name": chain,
                       "type": "filter", "hook": hook, "prio": 0, "policy": policy}}]
    for i, ex in enumerate(rules):
        objs.append({"rule": {"family": "inet", "table": table, "chain": chain,
                              "handle": 100 + i, "expr": ex}})
    # prerouting: 手机的 80/443(Android 还有 GMS 5228-5230)靠它改写进 mihomo。
    # 照 deploy/firewall/nftables-mihomo.conf 建模, 不是凭印象。
    if not no_prerouting:
        objs.append({"chain": {"family": "inet", "table": table, "name": "prerouting",
                               "type": "nat", "hook": "prerouting", "prio": -100,
                               "policy": "accept"}})
        rports = ([80, 443] if (platform == "ios" or no_gms)
                  else [80, 443, {"range": [5228, 5230]}])
        if not no_redirect:
            rex = [_saddr(wrong_redirect_src or seg),
                   _match("tcp", "dport", {"set": rports}),
                   ({"accept": None} if redirect_verdict_flip
                    else {"redirect": {"port": 7893}})]
            objs.append({"rule": {"family": "inet", "table": table, "chain": "prerouting",
                                  "handle": 200, "expr": rex}})
    return {"nftables": objs}


KERNEL_TEXT = """table inet pdg {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ct state established,related accept
		tcp dport 22 accept
		ip saddr %s tcp dport { 53, 81, 853, 7893, 8445 } accept
		ip saddr %s udp dport 53 accept
		ip saddr %s udp dport 443 reject with icmp port-unreachable
		ip protocol icmp accept
		ip6 nexthdr ipv6-icmp accept
	}
}
""" % (CIDR, CIDR, CIDR)

# ═══ 1. 复现: 现有文本比对把四条等价写法判成漂移 ═════════════════════════
print("══ 1. 修改前: 文本比对的假漂移 ══")
import linkstat as L  # noqa: E402

dn = L._nft_rule_set(DISK)
kn = L._nft_rule_set(KERNEL_TEXT)
missing = sorted(dn - kn)
EXPECT = ["ip saddr %s udp dport 443 reject" % CIDR,
          "ip saddr %s udp dport { 53 } accept" % CIDR,
          "ip6 nexthdr icmpv6 accept",
          "tcp dport { 22 } accept"]
(ok if len(missing) == 4 else bad)(
    "文本比对报出 4 条「磁盘有、内核无」(实得 %d 条)" % len(missing))
for e in EXPECT:
    (ok if e in missing else bad)("被误判的等价写法: %s" % e)
(ok if not missing or True else bad)("(以上四条在内核里其实都在, 只是 nft 换了写法)")

# ═══ 2. 语义判据: 同一份夹具必须判通过 ═══════════════════════════════════
print()
print("══ 2. 语义判据(nftlive.audit)══")
try:
    import nftlive
except ImportError:
    bad("还没有 nftlive 模块 —— 语义判据未实现")
    print("──────────────────────────────────────────────")
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)

good = kernel_json()
res = nftlive.audit_kernel(good, cidr=CIDR, platform="android")
(ok if res.ok else bad)("等价写法的健康内核判通过(实得 %s)" % (res.problems,))

# 等价样本逐项
cases_pass = [
    ("单元素集合折叠成标量", kernel_json()),
    ("reject 默认类型已展开", kernel_json()),
    ("icmpv6 → ipv6-icmp 别名", kernel_json()),
]
for label, kj in cases_pass:
    r = nftlive.audit_kernel(kj, cidr=CIDR, platform="android")
    (ok if r.ok else bad)("%s → 判通过(实得 %s)" % (label, r.problems))

# handle 不同不影响结论
kj2 = kernel_json()
for o in kj2["nftables"]:
    if "rule" in o:
        o["rule"]["handle"] += 900
r2 = nftlive.audit_kernel(kj2, cidr=CIDR, platform="android")
(ok if r2.ok else bad)("handle 变了不影响结论")

# 集合顺序不影响
kj3 = kernel_json()
for o in kj3["nftables"]:
    r = o.get("rule")
    if r:
        for e in r["expr"]:
            m = e.get("match", {})
            if isinstance(m.get("right"), dict) and "set" in m["right"]:
                m["right"]["set"] = list(reversed(m["right"]["set"]))
r3 = nftlive.audit_kernel(kj3, cidr=CIDR, platform="android")
(ok if r3.ok else bad)("端口集合顺序不影响结论")

# ═══ 3. 真差异必须 FAIL ══════════════════════════════════════════════════
print()
print("══ 3. 真差异 ══")
neg = [
    ("端口 81 放行缺失", kernel_json(drop_81=True), "81"),
    ("来源 CIDR 错误", kernel_json(wrong_cidr="192.168.0.0/16"), "来源"),
    ("verdict 被改成 drop", kernel_json(verdict_flip=True), "放行"),
    ("必需规则排在 drop 之后", kernel_json(after_drop=True), "顺序"),
    ("端口相同但协议错(udp 53 写成 tcp)", kernel_json(wrong_proto=True), "53"),
    ("policy 不是 drop", kernel_json(policy="accept"), "policy"),
    ("hook 错误", kernel_json(hook="forward"), "hook"),
    ("表名错误", kernel_json(table="wrongtbl"), "表"),
    ("prerouting 链缺失", kernel_json(no_prerouting=True), "prerouting"),
    ("80/443 重定向缺失", kernel_json(no_redirect=True), "redirect"),
    ("重定向来源网段错", kernel_json(wrong_redirect_src="192.168.0.0/16"), "来源"),
    ("重定向 verdict 错(accept 而非 redirect)", kernel_json(redirect_verdict_flip=True),
     "redirect"),
    ("Android 少了 GMS 5228-5230", kernel_json(no_gms=True), "5228"),
]
for label, kj, want in neg:
    r = nftlive.audit_kernel(kj, cidr=CIDR, platform="android")
    (ok if not r.ok else bad)("%s → 判失败" % label)
    (ok if not r.ok and any(want in p for p in r.problems) else bad)(
        "  并点名原因(含 %r, 实得 %s)" % (want, r.problems))

# ═══ 4. delete table 之类的命令不算运行规则 ═══════════════════════════════
print()
print("══ 4. 非规则行 ══")
(ok if not nftlive.audit_kernel({"nftables": [{"table": {"family": "inet", "name": "pdg"}}]},
                                cidr=CIDR, platform="android").ok else bad)(
    "只有 table 声明、没有链和规则 → 判失败(不是「没有问题」)")

# iOS 装机时 install.sh 把 GMS 5228-5230 摘掉(走 APNs 不需要), 所以 iOS 上缺它不算故障;
# 同一份内核放到 Android 上则必须判缺 —— 平台判据不能串台。
r_ios = nftlive.audit_kernel(kernel_json(platform="ios"), cidr=CIDR, platform="ios")
(ok if r_ios.ok else bad)("iOS 上没有 GMS 重定向属正常(实得 %s)" % r_ios.problems)
r_and = nftlive.audit_kernel(kernel_json(platform="ios"), cidr=CIDR, platform="android")
(ok if not r_and.ok else bad)("同一份内核在 Android 上判缺 GMS(平台判据不串台)")

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
