#!/usr/bin/env python3
"""sing-box 混合条件规则的 AND 语义回归。

问题: `_rules_from_route` 遇到带 rule_set 的规则就 continue, 同一条规则里的其它条件被整个
丢掉。而"把混合条件摊平成多条顶层 mihomo 规则"同样不行 —— **顶层规则之间是 OR**, 摊平会把
"A 且 B"变成"A 或 B", **扩大**命中范围。这两种错法一个漏放一个错放, 都比拒绝转换更糟。

sing-box 的规则语义:
  · 同一字段的多个值之间是 **OR**;
  · 不同匹配字段之间是 **AND**。

所以本次的转换规则是:
  · 只有一个条件组 → 沿用原来的扁平输出(同字段多值时顶层多条规则正好是 OR, 语义相同,
    而且现有普通配置逐字节不变);
  · 两个及以上条件组 → 一条 mihomo 逻辑规则, 外层 AND、同字段多值时内层 OR;
  · 认不出的字段一律 fail-closed 并点名。

验证分两层: 结构用一个**只供测试的参考匹配模型**跑真值表(证明 AND/OR 拓扑对), 语法与可加载
性用**项目钉死版本的真 mihomo -t**(参考模型不能代替它)。
"""
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import sb2mihomo  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def eq(label, got, want):
    if got == want:
        ok(label)
    else:
        bad("%s\n        实得: %r\n        期望: %r" % (label, got, want))


BASE_OUT = [{"type": "direct", "tag": "direct"},
            {"type": "shadowsocks", "tag": "ss1", "server": "1.2.3.4", "server_port": 8388,
             "method": "aes-128-gcm", "password": "pw"}]
RULESETS = {
    "rs_a": {"url": "https://ex.test/a.list", "behavior": "classical", "format": "text"},
    "rs_b": {"url": "https://ex.test/b.list", "behavior": "classical", "format": "text"},
}


def convert(rule):
    sb = {"log": {}, "inbounds": [], "outbounds": BASE_OUT,
          "route": {"rules": [rule], "final": "direct"}}
    cfg, meta = sb2mihomo.singbox_to_mihomo(sb, redir_port=7893, rulesets=RULESETS)
    body = [r for r in cfg.get("rules", []) if not r.startswith("MATCH,")]
    return body, (meta or {}).get("dropped") or []


# ══ 1. 单条件组: 扁平输出不变 ══════════════════════════════════════════════
print("── 1. 单条件组(现有行为不得改变)──")
eq("只有 rule_set 字符串", convert({"rule_set": "rs_a", "outbound": "ss1"})[0],
   ["RULE-SET,rs_a,ss1"])
eq("只有 rule_set 数组(同字段多值 = OR, 顶层多条正好是 OR)",
   convert({"rule_set": ["rs_a", "rs_b"], "outbound": "ss1"})[0],
   ["RULE-SET,rs_a,ss1", "RULE-SET,rs_b,ss1"])
eq("只有 domain_suffix 多值",
   convert({"domain_suffix": ["a.test", "b.test"], "outbound": "ss1"})[0],
   ["DOMAIN-SUFFIX,a.test,ss1", "DOMAIN-SUFFIX,b.test,ss1"])

# ══ 2. 两个条件组: AND ═════════════════════════════════════════════════════
print()
print("── 2. 两个条件组 → AND ──")
eq("rule_set 字符串 + domain_suffix",
   convert({"rule_set": "rs_a", "domain_suffix": ["ex.test"], "outbound": "ss1"})[0],
   ["AND,((RULE-SET,rs_a),(DOMAIN-SUFFIX,ex.test)),ss1"])
eq("rule_set 数组 + 多个 domain_suffix(内层各自 OR)",
   convert({"rule_set": ["rs_a", "rs_b"],
            "domain_suffix": ["a.test", "b.test"], "outbound": "ss1"})[0],
   ["AND,((OR,((RULE-SET,rs_a),(RULE-SET,rs_b))),"
    "(OR,((DOMAIN-SUFFIX,a.test),(DOMAIN-SUFFIX,b.test)))),ss1"])
eq("domain + domain_keyword(不含 rule_set 也一样是 AND)",
   convert({"domain": ["x.test"], "domain_keyword": ["kw"], "outbound": "ss1"})[0],
   ["AND,((DOMAIN,x.test),(DOMAIN-KEYWORD,kw)),ss1"])

print()
print("── 3. 三个条件组 + 顺序稳定 ──")
three = {"rule_set": "rs_a", "domain_suffix": ["s.test"], "domain_keyword": ["kw"],
         "outbound": "ss1"}
eq("三个条件组",
   convert(three)[0],
   ["AND,((RULE-SET,rs_a),(DOMAIN-SUFFIX,s.test),(DOMAIN-KEYWORD,kw)),ss1"])
# 字段在 dict 里的书写顺序不影响输出 —— 顺序由固定的字段表决定, 可测
shuffled = {"domain_keyword": ["kw"], "outbound": "ss1", "domain_suffix": ["s.test"],
            "rule_set": "rs_a"}
eq("字段书写顺序不同, 输出仍完全一致(顺序稳定)", convert(shuffled)[0], convert(three)[0])

# ══ 4. 不支持的字段组合: fail-closed ═══════════════════════════════════════
print()
print("── 4. 不支持的组合 fail-closed ──")
# 盘点结论: 本转换器当前**不支持** network / port / ip_cidr(非 reject 分支) / invert /
# 逻辑规则。它们此前会被静默忽略 —— 规则看着加了, 实际一条也没进内核。
UNSUPPORTED = (
    ("network", {"network": ["tcp"], "domain_suffix": ["x.test"], "outbound": "ss1"}),
    ("port", {"port": [443], "rule_set": "rs_a", "outbound": "ss1"}),
    ("ip_cidr(非 reject)", {"ip_cidr": ["1.2.3.0/24"], "outbound": "ss1"}),
    ("invert", {"invert": True, "domain_suffix": ["x.test"], "outbound": "ss1"}),
    ("逻辑规则 type", {"type": "logical", "mode": "and", "rules": [], "outbound": "ss1"}),
    ("source_ip_cidr", {"source_ip_cidr": ["10.0.0.0/8"], "outbound": "ss1"}),
    ("inbound 与域名混用", {"inbound": ["tg-proxy"], "domain_suffix": ["x.test"],
                            "outbound": "ss1"}),
)
for label, rule in UNSUPPORTED:
    body, dropped = convert(rule)
    if body:
        bad("%s: 竟然产出了规则(可能扩大了命中范围): %r" % (label, body))
    elif not dropped:
        bad("%s: 既不产规则也不进 dropped —— 静默忽略" % label)
    elif any(k in str(dropped[0].get("rule_set")) for k in ("不支持", "不合法", "无法表达")):
        ok("%s → 拒绝转换并点名(%s)" % (label, dropped[0]["rule_set"]))
    else:
        bad("%s: dropped 说明不对: %r" % (label, dropped[0]))

# 纯 inbound 规则仍由 _mixed_listeners 负责, 本路径不产规则也不报错(既有行为)
body, dropped = convert({"inbound": ["tg-proxy"], "outbound": "ss1"})
if not body and not dropped:
    ok("纯 inbound 规则: 本路径不产规则也不报错(由 _mixed_listeners 译成 IN-NAME)")
else:
    bad("纯 inbound 规则被误处理: body=%r dropped=%r" % (body, dropped))

# 多条件组里缺规则集 → 整条拒绝(少一个 AND 条件 = 扩大命中, 比不译更危险)
body, dropped = convert({"rule_set": "rs_missing", "domain_suffix": ["x.test"],
                         "outbound": "ss1"})
if not body and dropped and dropped[0].get("rule_set") == "rs_missing":
    ok("多条件组里规则集缺失 → 整条拒绝并点名(不做「少一个条件」的近似)")
else:
    bad("缺规则集处理不对: body=%r dropped=%r" % (body, dropped))

# ══ 4b. action=reject 同样走条件组 ═════════════════════════════════════════
print()
print("── 4b. reject 的 AND/OR ──")


def convert_reject(rule):
    sb = {"log": {}, "inbounds": [], "outbounds": BASE_OUT,
          "route": {"rules": [rule], "final": "direct"}}
    cfg, meta = sb2mihomo.singbox_to_mihomo(sb, redir_port=7893, rulesets=RULESETS)
    return ([r for r in cfg.get("rules", []) if not r.startswith("MATCH,")],
            (meta or {}).get("dropped") or [])


# 现网那条(模板里就是这个形态)必须逐字节不变 —— 含 no-resolve 且跟在 REJECT 之后
eq("reject + 单个 ip_cidr: 与现网逐字节一致",
   convert_reject({"action": "reject", "ip_cidr": ["1.2.3.0/24"]})[0],
   ["IP-CIDR,1.2.3.0/24,REJECT,no-resolve"])
eq("reject + 多个 ip_cidr(同字段 OR → 顶层多条)",
   convert_reject({"action": "reject", "ip_cidr": ["1.2.3.0/24", "10.0.0.0/8"]})[0],
   ["IP-CIDR,1.2.3.0/24,REJECT,no-resolve", "IP-CIDR,10.0.0.0/8,REJECT,no-resolve"])
# 混合条件: 原实现读完 ip_cidr 就 continue, domain_suffix 被丢 → **扩大拒绝范围**
eq("reject + ip_cidr + domain_suffix → AND(不再丢条件, 不再扩大拒绝范围)",
   convert_reject({"action": "reject", "ip_cidr": ["1.2.3.0/24"],
                   "domain_suffix": ["ad.test"]})[0],
   ["AND,((IP-CIDR,1.2.3.0/24,no-resolve),(DOMAIN-SUFFIX,ad.test)),REJECT"])
eq("reject: 同字段多值在 AND 内层是 OR, no-resolve 逐个带上",
   convert_reject({"action": "reject", "ip_cidr": ["1.2.3.0/24", "10.0.0.0/8"],
                   "domain_suffix": ["ad.test"]})[0],
   ["AND,((OR,((IP-CIDR,1.2.3.0/24,no-resolve),(IP-CIDR,10.0.0.0/8,no-resolve))),"
    "(DOMAIN-SUFFIX,ad.test)),REJECT"])
eq("reject + rule_set + domain_keyword(三组)",
   convert_reject({"action": "reject", "ip_cidr": ["1.2.3.0/24"], "rule_set": "rs_a",
                   "domain_keyword": ["kw"]})[0],
   ["AND,((IP-CIDR,1.2.3.0/24,no-resolve),(RULE-SET,rs_a),(DOMAIN-KEYWORD,kw)),REJECT"])
for label, rule in (("network", {"action": "reject", "ip_cidr": ["1.2.3.0/24"],
                                 "network": ["udp"]}),
                    ("invert", {"action": "reject", "ip_cidr": ["1.2.3.0/24"], "invert": True}),
                    ("port", {"action": "reject", "port": [53]}),
                    ("什么条件都没有", {"action": "reject"})):
    body, dropped = convert_reject(rule)
    if body:
        bad("reject/%s: 竟然产出了规则(拒绝范围可能被扩大): %r" % (label, body))
    elif not dropped:
        bad("reject/%s: 静默忽略" % label)
    else:
        ok("reject/%s → 拒绝转换并点名(%s)" % (label, dropped[0]["rule_set"]))
# 没有 outbound 也没有 action 的规则: dropped 里只放安全描述, 不塞整条原始规则
_b, _d = convert({"domain_suffix": ["x.test"], "server": "SECRET-" + "z" * 20})
if _d and "SECRET" not in json.dumps(_d, ensure_ascii=False):
    ok("无目标的规则: dropped 只记安全描述, 不把原始规则倒进去")
else:
    bad("dropped 泄漏了原始规则: %r" % _d)

# ══ 5. 参考匹配模型: 验 AND/OR 拓扑(不代替 mihomo -t)══════════════════════
print()
print("── 5. 参考匹配模型(真值表)──")


def ref_match(rule_text, ctx):
    """**只供测试**的参考匹配器: 解析生成的 mihomo 规则并按 ctx 判定命中与否。
    它验的是 AND/OR 的拓扑对不对 —— 语法与可加载性由真 mihomo -t 负责, 两者不能互相代替。"""
    def atom(kind, val):
        if kind == "RULE-SET":
            return val in ctx.get("rulesets", ())
        if kind == "DOMAIN-SUFFIX":
            return ctx.get("host", "").endswith(val)
        if kind == "DOMAIN":
            return ctx.get("host", "") == val
        if kind == "DOMAIN-KEYWORD":
            return val in ctx.get("host", "")
        raise AssertionError("参考模型不认识 %s" % kind)

    def parse(expr):
        expr = expr.strip()
        m = re.match(r"^\((OR|AND),\((.*)\)\)$", expr, re.S)
        if m:
            return (m.group(1), [parse(x) for x in split_top(m.group(2))])
        m = re.match(r"^\(([A-Z-]+),(.*)\)$", expr, re.S)
        if m:
            return ("ATOM", m.group(1), m.group(2))
        raise AssertionError("参考模型解析不了: %r" % expr)

    def split_top(s):
        out, depth, cur = [], 0, ""
        for ch in s:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            if ch == "," and depth == 0:
                out.append(cur); cur = ""
            else:
                cur += ch
        if cur:
            out.append(cur)
        return out

    def ev(node):
        if node[0] == "ATOM":
            return atom(node[1], node[2])
        vals = [ev(c) for c in node[1]]
        return all(vals) if node[0] == "AND" else any(vals)

    if rule_text.startswith("AND,"):
        inner = rule_text[len("AND,"):rule_text.rindex("),") + 1]
        return ev(("AND", [parse(x) for x in split_top(inner[1:-1])]))
    kind, val, _t = rule_text.split(",", 2)
    return atom(kind, val)


MIXED = convert({"rule_set": ["rs_a", "rs_b"], "domain_suffix": ["a.test", "b.test"],
                 "outbound": "ss1"})[0][0]
truth = []
for rs, host in itertools.product(([], ["rs_a"], ["rs_b"], ["rs_a", "rs_b"]),
                                  ("a.test", "b.test", "c.test")):
    got = ref_match(MIXED, {"rulesets": rs, "host": host})
    want = bool(rs) and host in ("a.test", "b.test")     # (a OR b) AND (x OR y)
    truth.append((rs, host, got, want))
wrong = [t for t in truth if t[2] != t[3]]
if not wrong:
    ok("(rs_a OR rs_b) AND (a.test OR b.test): %d 种组合真值表全对" % len(truth))
else:
    bad("真值表有 %d 处不对: %r" % (len(wrong), wrong[:3]))
# 摊平成两条顶层规则会变成 OR —— 参考模型必须能把这个区别验出来
flat_a = "RULE-SET,rs_a,ss1"
if ref_match(flat_a, {"rulesets": ["rs_a"], "host": "c.test"}) and \
        not ref_match(MIXED, {"rulesets": ["rs_a"], "host": "c.test"}):
    ok("摊平成顶层规则会命中(OR), 而 AND 规则不命中 —— 两者确实不等价")
else:
    bad("参考模型区分不了 AND 与摊平")

# ══ 6. 真 mihomo -t ════════════════════════════════════════════════════════
print()
print("── 6. 钉死版 mihomo -t ──")
MIHOMO = shutil.which("mihomo") or os.environ.get("PDG_TEST_MIHOMO", "")


def mihomo_check(cfg):
    d = tempfile.mkdtemp(prefix="mixedmihomo.")
    try:
        f = os.path.join(d, "config.yaml")
        json.dump(cfg, open(f, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        p = subprocess.run([MIHOMO, "-t", "-d", d, "-f", f],
                           capture_output=True, text=True, timeout=120)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    finally:
        shutil.rmtree(d, ignore_errors=True)


if not MIHOMO:
    bad("找不到 mihomo(装钉死版或设 PDG_TEST_MIHOMO) —— 语法必须由真内核校验, 不接受跳过")
else:
    ver = subprocess.run([MIHOMO, "-v"], capture_output=True, text=True).stdout.strip()
    sys.path.insert(0, os.path.join(ROOT, "tests"))
    pinned = ""
    for line in open(os.path.join(ROOT, "lib", "versions.sh"), encoding="utf-8"):
        m = re.match(r'^MIHOMO_VER="?([^"\n]+)"?', line.strip())
        if m:
            pinned = m.group(1)
    if pinned and pinned.lstrip("v") in ver:
        ok("用的是项目钉死版本 mihomo(%s)" % pinned)
    else:
        bad("mihomo 版本与钉死版不符: %r(钉死 %s)" % (ver, pinned))
    SB = {"log": {}, "inbounds": [], "outbounds": BASE_OUT,
          "route": {"rules": [
              {"rule_set": "rs_a", "domain_suffix": ["ex.test"], "outbound": "ss1"},
              {"rule_set": ["rs_a", "rs_b"], "domain_suffix": ["a.test", "b.test"],
               "outbound": "ss1"},
              {"domain": ["x.test"], "domain_keyword": ["kw"], "outbound": "direct"},
              {"rule_set": ["rs_a", "rs_b"], "outbound": "ss1"},
              {"domain_suffix": ["plain.test"], "outbound": "ss1"},
              {"action": "reject", "ip_cidr": ["9.9.9.0/24"]},
              {"action": "reject", "ip_cidr": ["8.8.8.0/24", "7.7.7.0/24"],
               "domain_suffix": ["ad.test"]},
          ], "final": "direct"}}
    cfg, meta = sb2mihomo.singbox_to_mihomo(SB, redir_port=7893, rulesets=RULESETS)
    rc, out = mihomo_check(cfg)
    if rc == 0:
        ok("含 AND / 嵌套 OR / 扁平规则的完整配置通过真 mihomo -t")
    else:
        bad("mihomo -t 不接受生成的配置: %s" % out[-400:])
    if not ((meta or {}).get("dropped")):
        ok("这些组合全部译得出, 没有进 dropped")
    else:
        bad("有条目被丢: %r" % meta["dropped"])
    logic = [r for r in cfg["rules"] if r.startswith("AND,")]
    if len(logic) == 4:
        ok("生成了 4 条逻辑规则(含一条 reject 的 AND; 其余保持扁平)")
    else:
        bad("逻辑规则条数不对: %r" % logic)
    if "IP-CIDR,9.9.9.0/24,REJECT,no-resolve" in cfg["rules"]:
        ok("单条件 reject 仍是扁平形态且带 no-resolve")
    else:
        bad("单条件 reject 形态变了")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
