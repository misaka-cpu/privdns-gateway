#!/usr/bin/env python3
"""sing-box route rule 的 `rule_set` 数组形态回归。

sing-box 的合法形态是**字符串或字符串数组**。转换器原来只当标量用, 数组会一路 TypeError ——
本项目的 bot 自己只写字符串, 所以现网碰不到; 但从备份恢复、或用户从别处导入的 model 完全
可能带数组, 那时整份渲染会崩在一个看不出出处的 TypeError 上。

展开等价性(这次改动的核心论据):
  sing-box 里同一字段的多个值是 **OR** —— 命中 A 或 B 都走该 outbound;
  mihomo 是首条命中即止, 连续几条指向**同一 target** 的 RULE-SET 合起来正是这个并集。
  所以按原始顺序逐个展开即等价, 而排序/去重都会破坏它。

另一条纪律: 形态不认识时 fail-closed —— 绝不把 Python 的 list/dict 直接 str() 写进 mihomo
配置, 那会渲染出一条永不命中的规则, 而用户以为分流已经生效。
"""
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import sb2mihomo  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-ruleset-7c1"


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
             "method": "aes-128-gcm", "password": SENTINEL}]
RULESETS = {
    "rs_a": {"url": "https://%s.example/a.list" % SENTINEL, "behavior": "classical",
             "format": "text"},
    "rs_b": {"url": "https://ex.test/b.yaml", "behavior": "classical", "format": "yaml"},
    "rs_ip": {"url": "https://ex.test/c.mrs", "behavior": "ipcidr", "format": "mrs"},
}


def convert(rule, rulesets=RULESETS):
    sb = {"log": {}, "inbounds": [], "outbounds": BASE_OUT,
          "route": {"rules": [rule], "final": "direct"}}
    cfg, meta = sb2mihomo.singbox_to_mihomo(sb, redir_port=7893, rulesets=rulesets)
    return cfg.get("rules", []), (meta or {}).get("dropped") or []


def rs_rules(rules):
    return [r for r in rules if r.startswith("RULE-SET,")]


# ══ 1. 字符串: 现有行为逐字节不变 ═══════════════════════════════════════════
print("── 1. 字符串形态(现有行为不得改变)──")
r_str, d_str = convert({"rule_set": "rs_a", "outbound": "ss1"})
eq("字符串: 产出单条 RULE-SET", rs_rules(r_str), ["RULE-SET,rs_a,ss1"])
eq("字符串: 无 dropped", d_str, [])
r_miss, d_miss = convert({"rule_set": "rs_nope", "outbound": "ss1"})
eq("字符串 + 规则集不存在: 不产出规则", rs_rules(r_miss), [])
eq("字符串 + 规则集不存在: 进 dropped 并点名",
   d_miss, [{"rule_set": "rs_nope", "outbound": "ss1"}])

# ══ 2. 单元素数组 ≡ 字符串 ═════════════════════════════════════════════════
print()
print("── 2. 单元素数组与字符串完全等价 ──")
# 先单独钉住"不再抛裸 TypeError" —— 否则数组支持一被撤掉, 下面每一行都会直接崩在
# 未捕获的异常上, 跑出来是堆栈而不是具名失败, 看不出到底该红哪一条。
try:
    convert({"rule_set": ["rs_a"], "outbound": "ss1"})
    ok("数组形态不再抛裸 TypeError")
except TypeError as e:
    bad("数组形态仍抛裸 TypeError: %s" % e)
    print("─" * 40)
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
r_one, d_one = convert({"rule_set": ["rs_a"], "outbound": "ss1"})
eq("单元素数组: 与字符串产出**完全相同**的规则", r_one, r_str)
eq("单元素数组: dropped 也相同", d_one, d_str)
r_one_m, d_one_m = convert({"rule_set": ["rs_nope"], "outbound": "ss1"})
eq("单元素数组 + 不存在: 与字符串情形一致", (r_one_m, d_one_m), (r_miss, d_miss))

# ══ 3. 多元素数组: 顺序、同 outbound、不去重不排序 ═════════════════════════
print()
print("── 3. 多元素数组 ──")
r_multi, d_multi = convert({"rule_set": ["rs_a", "rs_b", "rs_ip"], "outbound": "ss1"})
eq("多元素: 每个规则集各出一条 RULE-SET, 目标相同",
   rs_rules(r_multi), ["RULE-SET,rs_a,ss1", "RULE-SET,rs_b,ss1", "RULE-SET,rs_ip,ss1"])
eq("多元素: 无 dropped", d_multi, [])
r_rev, _d = convert({"rule_set": ["rs_ip", "rs_a", "rs_b"], "outbound": "ss1"})
eq("多元素: **按原始顺序**展开(不排序)",
   rs_rules(r_rev), ["RULE-SET,rs_ip,ss1", "RULE-SET,rs_a,ss1", "RULE-SET,rs_b,ss1"])
r_dup, _d = convert({"rule_set": ["rs_a", "rs_a"], "outbound": "ss1"})
eq("多元素: 重复项**不去重**(顺序即语义, 擅自去重是猜)",
   rs_rules(r_dup), ["RULE-SET,rs_a,ss1", "RULE-SET,rs_a,ss1"])
r_dir, _d = convert({"rule_set": ["rs_a", "rs_b"], "outbound": "direct"})
eq("多元素: outbound=direct 时两条都映射到 DIRECT",
   rs_rules(r_dir), ["RULE-SET,rs_a,DIRECT", "RULE-SET,rs_b,DIRECT"])
# 不同 behavior 的规则集混在一条规则里也照常展开(behavior 由 rulesets 决定, 不在这里猜)
r_mix, _d = convert({"rule_set": ["rs_a", "rs_ip"], "outbound": "ss1"})
eq("多元素: classical 与 ipcidr 混用照常展开(behavior 不在这里猜)",
   rs_rules(r_mix), ["RULE-SET,rs_a,ss1", "RULE-SET,rs_ip,ss1"])
# 部分缺失: 存在的照常译, 缺的逐个进 dropped(与字符串的逐名语义一致)
r_part, d_part = convert({"rule_set": ["rs_a", "rs_gone", "rs_b"], "outbound": "ss1"})
eq("多元素: 部分缺失 → 存在的照译", rs_rules(r_part),
   ["RULE-SET,rs_a,ss1", "RULE-SET,rs_b,ss1"])
eq("多元素: 缺失的逐个进 dropped 并点名",
   d_part, [{"rule_set": "rs_gone", "outbound": "ss1"}])

# 老 .mrs 且 metadata 缺 behavior: 这类规则集在 rulesets_arg 阶段就被剔除, 于是这里必然
# 落到"找不到" → dropped。数组形态下同样如此, 不会被悄悄跳过。
r_nobh, d_nobh = convert({"rule_set": ["rs_a", "rs_legacy_mrs"], "outbound": "ss1"})
eq("老 .mrs(元数据缺 behavior, 已被剔除): 数组里同样进 dropped",
   (rs_rules(r_nobh), d_nobh),
   (["RULE-SET,rs_a,ss1"], [{"rule_set": "rs_legacy_mrs", "outbound": "ss1"}]))

# ══ 4. 非法形态一律 fail-closed ════════════════════════════════════════════
print()
print("── 4. 非法形态 fail-closed ──")
ILLEGAL = (
    ("空字符串", ""),
    ("空数组", []),
    ("数组里混入整数", ["rs_a", 7]),
    ("数组里混入 None", ["rs_a", None]),
    ("嵌套数组", ["rs_a", ["rs_b"]]),
    ("数组里混入 dict", ["rs_a", {"tag": "rs_b"}]),
    ("整个是 dict", {"tag": "rs_a"}),
    ("整个是 None", None),
    ("整个是整数", 7),
    ("数组里是空白字符串", ["rs_a", "   "]),
)
for label, val in ILLEGAL:
    try:
        rules, dropped = convert({"rule_set": val, "outbound": "ss1"})
    except TypeError as e:
        bad("%s: 抛了裸 TypeError(%s) —— 必须 fail-closed 而不是崩" % (label, e))
        continue
    except Exception as e:  # noqa: BLE001
        bad("%s: 抛了 %s" % (label, type(e).__name__))
        continue
    if rs_rules(rules):
        bad("%s: 竟然产出了规则 %r" % (label, rs_rules(rules)))
    elif not dropped:
        bad("%s: 既没产出规则也没进 dropped —— 静默丢弃" % label)
    else:
        note = str(dropped[0].get("rule_set"))
        # 只允许出现类型名与固定措辞, 不允许把原值放进去
        leaked = any(x in note for x in ("{", "[", SENTINEL, "tag")) and "非法" not in note
        if leaked or SENTINEL in json.dumps(dropped, ensure_ascii=False):
            bad("%s: dropped 里泄漏了原值: %r" % (label, note))
        else:
            ok("%s → 不产规则 + 进 dropped, 说明只含安全标识(%s)" % (label, note))

# ══ 5. 哨兵不得进入任何产物 ════════════════════════════════════════════════
print()
print("── 5. 泄密面 ──")
sb_all = {"log": {}, "inbounds": [], "outbounds": BASE_OUT,
          "route": {"rules": [{"rule_set": ["rs_a", {"x": SENTINEL}], "outbound": "ss1"},
                              {"rule_set": ["rs_a", "rs_b"], "outbound": "ss1"}],
                    "final": "direct"}}
cfg_all, meta_all = sb2mihomo.singbox_to_mihomo(sb_all, redir_port=7893, rulesets=RULESETS)
if SENTINEL not in json.dumps(meta_all, ensure_ascii=False):
    ok("渲染 meta(含 dropped)不含哨兵")
else:
    bad("meta 泄漏哨兵: %r" % meta_all)
# 规则文本里不该出现订阅 URL(它只属于 rule-providers 那一节)
if not any(SENTINEL in r for r in cfg_all.get("rules", [])):
    ok("规则文本里不含订阅 URL 哨兵")
else:
    bad("规则文本泄漏了 URL")

# ══ 6. 字符串路径的既有 SHA256 锚点不变 ════════════════════════════════════
print()
print("── 6. 字符串路径逐字节锚点 ──")
# 锚点值取自**改动前**的 sb2mihomo(git show HEAD 版本单独跑一遍算出来的), 不是拿改完的
# 代码算一遍再比 —— 后者是循环论证。支持数组的
# 改动**不得**动到字符串路径产出的任何一个字节。
ANCHOR_MODEL = {"log": {"level": "warn"}, "inbounds": [], "outbounds": BASE_OUT,
                "route": {"rules": [{"rule_set": "rs_a", "outbound": "ss1"},
                                    {"domain_suffix": ["ex.test"], "outbound": "ss1"}],
                          "final": "direct"}}
cfg_a, _m = sb2mihomo.singbox_to_mihomo(ANCHOR_MODEL, redir_port=7893, rulesets=RULESETS)
sha = hashlib.sha256(json.dumps(cfg_a, ensure_ascii=False, sort_keys=True,
                                indent=2).encode()).hexdigest()
eq("字符串路径渲染结果的字节摘要(改动前后必须一致)",
   sha, "49965d7cf43cbbb87916d82923cac7964cff2d77afe3f85dd052e0b0c60e1ed2")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
