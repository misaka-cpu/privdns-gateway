#!/usr/bin/env bash
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# mosdns 劫持形态单一事实源(install.sh / pdg hijack-mode / 老装迁移共用, 免漂移)。
# ─────────────────────────────────────────────────────────────────────────────
# mosdns 劫持形态归一化: 让配置与劫持模式一致。是**all/gfw 的唯一事实源**, install /
# hijack-mode / 老装迁移都调它。
#
# all  = 排除式: 不是国内域名就劫持进代理(网关本来的语义)。
# gfw  = 白名单式: 只劫持 hijack_set 里的域名, 其余海外域名返真实 IP 直连。
#
# 之前把 all 也做成白名单(hijack_set=geolocation-!cn), 想当然认为"非CN都在集内" ——
# geolocation-!cn 是**策展分类**, 任意/个人域名根本不在里面, 于是 all 静默退化成一个更窄
# 的 gfw: 用户在 bot 里指到出口的域名照样直连(issue #1)。
#
# 用法: _mosdns_hijack_shape <all|gfw> <config.yaml> [劫持集文件名]
#       输出 changed / nochange; 形态不认识则非 0 且不动文件。
_mosdns_hijack_shape(){
  local mode="$1" mc="$2" setfile="${3:-}"
  python3 - "$mode" "$mc" "$setfile" <<'SHAPEPY'
import re, sys
mode, f, setfile = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f, encoding="utf-8").read()
orig = s

GATE = ('      - matches: "!qname $hijack_set"\n'
        '        exec: $ecs_neutral\n'
        '      - matches: "!qname $hijack_set"\n'
        '        exec: $remote_upstream\n')
PLUGIN = ('  - tag: hijack_set\n'
          '    type: domain_set\n'
          '    args: { files: ["/etc/mosdns/rules/%s","/etc/mosdns/rules/custom_hijack.txt"] }\n')

# 1) 确保 hijack_set 插件存在(老配置没有它 → gfw 模式无从实现)。插在 force_hijack 之前。
if "- tag: hijack_set" not in s:
    setf = setfile or "geosite_geolocation-!cn.txt"
    m = re.search(r"^  - tag: force_hijack\n", s, re.M)
    if not m:
        raise SystemExit("mosdns 配置里找不到 force_hijack, 形态不认识")
    s = s[:m.start()] + (PLUGIN % setf) + s[m.start():]
elif setfile:
    s = re.sub(r"(- tag: hijack_set\b[\s\S]*?files: \[\")[^\"]*(\")",
               lambda m: m.group(1) + "/etc/mosdns/rules/" + setfile + m.group(2), s, count=1)

# 2) 劫持门按模式增删
has_gate = '!qname $hijack_set' in s
if mode == "gfw" and not has_gate:
    m = re.search(r"(- tag: internal_sequence\b[\s\S]*?)(      - matches: qtype 28\n)", s)
    if not m:
        raise SystemExit("internal_sequence 形态不认识, 未改")
    s = s[:m.start(2)] + GATE + s[m.start(2):]
elif mode == "all" and has_gate:
    if GATE not in s:
        raise SystemExit("劫持门是自定义形态, 未改")
    s = s.replace(GATE, "")

if s != orig:
    open(f, "w", encoding="utf-8").write(s)
    print("changed")
else:
    print("nochange")
SHAPEPY
}

# ── 明确代理优先于 geosite_cn ────────────────────────────────────────────────
# 老配置(v1.7.0 及更早)里, 用户点名指到出口的域名只在 hijack_set 那道门被查, 而那道门排在
# geosite_cn **之后** —— 上游 geosite 一旦把域名归进 CN, DNS 就先返真实地址, 流量不进 mihomo,
# 内核里那条 route 规则成了死规则。这里把显式代理集与它的劫持序列补齐, 并把门插到
# force_hijack 之后、geosite_cn 之前。
#
# 幂等: 三样都齐了就什么都不做。形态不认识一律非 0 且**不动文件** —— 高度自定义的配置宁可
# 让 doctor 点名, 也不猜着改。
#
# 用法: _mosdns_explicit_proxy <config.yaml> [SERVER_IP]
#       输出 changed / nochange; 形态不认识则非 0。
_mosdns_explicit_proxy(){
  local mc="$1" sip="${2:-}"
  python3 - "$mc" "$sip" <<'EPPY'
import re, sys
f, sip = sys.argv[1], sys.argv[2]
s = open(f, encoding="utf-8").read()
orig = s

SET = ('  - tag: explicit_proxy\n'
       '    type: domain_set\n'
       '    args: { files: ["/etc/mosdns/rules/custom_hijack.txt",'
       '"/etc/mosdns/rules/ruleset_hijack.txt"] }\n')
GATE = ('      - matches: qname $explicit_proxy\n'
        '        exec: goto explicit_proxy_seq\n')

# 1) 域名集: 插在 force_hijack 之后(它是 MITM 那一套, 位置固定, 拿它当锚)
if "- tag: explicit_proxy\n" not in s:
    m = re.search(r"^  - tag: force_hijack\n(?:.*\n)*?    args: \{ files: \[[^\]]*\] \}\n", s, re.M)
    if not m:
        raise SystemExit("找不到 force_hijack 域名集, mosdns 形态不认识")
    s = s[:m.end()] + SET + s[m.end():]

# 2) 劫持序列: 与 force_hijack_seq 同形, 但独立一条(普通代理域名不该进 mitm_hijack.txt)
if "- tag: explicit_proxy_seq\n" not in s:
    m = re.search(r"^  - tag: force_hijack_seq\n    type: sequence\n    args:\n"
                  r"((?:      - .*\n|        .*\n)+)", s, re.M)
    if not m:
        raise SystemExit("找不到 force_hijack_seq, mosdns 形态不认识")
    body = m.group(1)
    if sip:
        body = re.sub(r"black_hole \S+", "black_hole " + sip, body)
    seq = "  - tag: explicit_proxy_seq\n    type: sequence\n    args:\n" + body
    m2 = re.search(r"^  - tag: internal_sequence\n", s, re.M)
    if not m2:
        raise SystemExit("找不到 internal_sequence, mosdns 形态不认识")
    s = s[:m2.start()] + seq + s[m2.start():]

# 3) 门: 必须在 force_hijack 的 goto 之后、geosite_cn 之前
if GATE not in s:
    m = re.search(r"      - matches: qname \$force_hijack\n        exec: goto force_hijack_seq\n", s)
    if not m:
        raise SystemExit("internal_sequence 里找不到 force_hijack 门, 形态不认识")
    s = s[:m.end()] + GATE + s[m.end():]

# 4) 顺序复核: 显式代理门必须真的排在 geosite_cn 之前 —— 补进去了但位置不对等于没补
gi, ci = s.find("qname $explicit_proxy"), s.find("qname $geosite_cn")
if gi < 0 or ci < 0 or gi > ci:
    raise SystemExit("显式代理门没有排在 geosite_cn 之前, 拒绝写出")

if s != orig:
    open(f, "w", encoding="utf-8").write(s)
    print("changed")
else:
    print("nochange")
EPPY
}
