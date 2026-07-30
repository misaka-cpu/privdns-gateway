#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 把一台"v1.4.x 时代的老机器"升到当前版本, 跑**真正的** pdg __migrate。
#
# 这条路线单测覆盖不到 —— 它是十几个迁移按顺序作用在同一份真实现场上的**累积结果**,
# 接缝正是出 bug 的地方(实践中查出的 GMS 重复插入、backend 标记从不落地, 都是这么发现的)。
#
# 老机器的特征: 无平台标记 / 无内核标记 / mosdns 是排除式老形态(无 hijack_set) /
# sing-box model 带 GMS 入站 / 用户加过显式出口规则 / iOS 组件装给了所有机器
# (v1.4.x 无平台概念, 所以它们的存在**证明不了**平台)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

e2e_stub_system
e2e_seed_install

seed_old_box(){   # $1=平台标记(留空=老机器原样, 无标记)
  rm -f /etc/privdns-gateway/platform /etc/privdns-gateway/platform.guessed /etc/privdns-gateway/backend
  e2e_seed_mosdns all
  # 退回"老形态": 去掉 hijack_set 插件(那时还没有这机制)
  python3 - /etc/mosdns/config.yaml <<'PY'
import re, sys
f = sys.argv[1]; s = open(f, encoding="utf-8").read()
s = re.sub(r"  # custom_hijack[\s\S]*?(?=  - tag: force_hijack)", "", s)
s = re.sub(r"  - tag: hijack_set\n    type: domain_set\n    args: \{[^\n]*\n", "", s)
open(f, "w", encoding="utf-8").write(s)
PY
  # v1.4.x 的 model: GMS 入站 + 用户加过的显式出口规则
  cat > /etc/sing-box/config.json <<'J'
{"log":{"level":"warn"},
 "inbounds":[{"type":"direct","tag":"in-http","listen":"0.0.0.0","listen_port":80,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-https","listen":"0.0.0.0","listen_port":443,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-gms-5228","listen":"0.0.0.0","listen_port":5228,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-gms-5229","listen":"0.0.0.0","listen_port":5229,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-gms-5230","listen":"0.0.0.0","listen_port":5230,"sniff":true,"sniff_override_destination":true}],
 "outbounds":[{"type":"direct","tag":"direct"},
              {"type":"shadowsocks","tag":"jp","server":"198.51.100.7","server_port":8388,"method":"aes-128-gcm","password":"x"}],
 "route":{"rules":[{"action":"reject","ip_cidr":["203.0.113.1/32"]},
                   {"domain_suffix":["ip.skk.moe","example.test"],"outbound":"jp"}],
          "final":"direct"}}
J
  # v1.4.x 把 iOS 组件装给所有机器 → 它们证明不了平台
  install -m644 "$E2E_ROOT/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl" /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
  install -m755 "$E2E_ROOT/deploy/ios/probe81.py" /opt/pdg-bot/probe81.py
  : > /etc/systemd/system/pdg-probe81.service
  [[ -n "${1:-}" ]] && printf '%s\n' "$1" > /etc/privdns-gateway/platform
  return 0
}
gms(){ grep -c 'in-gms-52' /etc/sing-box/config.json; }
plug(){ grep -c 'tag: hijack_set' /etc/mosdns/config.yaml; }
gate(){ grep -c '!qname \$hijack_set' /etc/mosdns/config.yaml; }

# ══ 场景一: 老机器原样(无任何平台证据) ══════════════════════════════════════
echo "── 场景一: v1.4.x 老机器, 无平台/内核标记 ──"
seed_old_box
[[ "$(plug)" == 0 && "$(gms)" == 3 ]] || bad "前置: 老形态没造对"
bash /usr/local/bin/pdg __migrate >/tmp/mig1.log 2>&1
rc=$?
[[ "$rc" == 0 ]] && ok "迁移整体成功(exit 0)" || bad "迁移退出码 $rc: $(tail -3 /tmp/mig1.log)"

# 平台: 无证据 → 推测 android, 且**不做破坏性清理**
{ [[ "$(cat /etc/privdns-gateway/platform)" == android ]] && [[ -e /etc/privdns-gateway/platform.guessed ]]; } \
  && ok "无证据 → 平台回退 android 且标记为推测" || bad "平台推测标记缺失"
{ [[ -e /opt/pdg-bot/probe81.py ]] && [[ -e /etc/systemd/system/pdg-probe81.service ]] \
  && [[ -e /opt/pdg-bot/pdg-dot.mobileconfig.tmpl ]]; } \
  && ok "推测态: iOS 组件一个没删(万一这台其实服务 iPhone)" || bad "推测态下 iOS 组件被删了"
grep -q '跳过 iOS 组件清理' /tmp/mig1.log && ok "推测态: 明确说明跳过了清理" || bad "未提示跳过清理"

# v1.6.0: 老装(sing-box)迁移后内核标记必须落定 mihomo, 且 sing-box 运行时被清干净
[[ "$(cat /etc/privdns-gateway/backend 2>/dev/null)" == mihomo ]] \
  && ok "老装迁移: 内核标记落定 mihomo" || bad "backend=$(cat /etc/privdns-gateway/backend 2>/dev/null)"
{ [[ ! -e /etc/systemd/system/sing-box.service ]] && [[ ! -e /usr/local/bin/sing-box ]]; } \
  && ok "老装迁移: sing-box unit 与二进制已移除" || bad "sing-box 运行时仍有残留"
grep -q 'sing-box 运行时已移除' /tmp/mig1.log \
  && ok "老装迁移: 迁移过程有明确告知" || bad "迁移日志未提到移除 sing-box"

# mosdns: 补 hijack_set 插件, all 模式不装劫持门
{ [[ "$(plug)" == 1 ]] && [[ "$(gate)" == 0 ]]; } \
  && ok "mosdns: 补上 hijack_set 插件, all 仍是排除式(不装劫持门)" || bad "劫持形态错: 插件=$(plug) 门=$(gate)"

# 用户此前加过的显式出口域名必须被回填进劫持表(否则那些规则一直是死的)
hj=$(grep -c '^domain:' /etc/mosdns/rules/custom_hijack.txt 2>/dev/null || echo 0)
{ [[ "$hj" == 2 ]] && grep -q 'ip.skk.moe' /etc/mosdns/rules/custom_hijack.txt; } \
  && ok "回填: 已有的显式出口域名进了劫持表(用户无需重加)" || bad "回填数=$hj"

# GMS: android 平台该保留, 且不得重复插入
[[ "$(gms)" == 3 ]] && ok "GMS 入站保持 3 条(android 需要, 且未重复插入)" || bad "GMS 入站变成 $(gms) 条"

# 幂等
cp /etc/mosdns/config.yaml /tmp/m1; cp /etc/sing-box/config.json /tmp/s1
bash /usr/local/bin/pdg __migrate >/tmp/mig2.log 2>&1
{ cmp -s /tmp/m1 /etc/mosdns/config.yaml && cmp -s /tmp/s1 /etc/sing-box/config.json; } \
  && ok "二跑幂等(mosdns 与 model 均无变化)" || bad "二跑改动了配置"

# ══ 场景二: 平台已确认 ios ══════════════════════════════════════════════════
echo; echo "── 场景二: 同样的老机器, 但平台已确认 ios ──"
seed_old_box ios
bash /usr/local/bin/pdg __migrate >/tmp/mig3.log 2>&1
[[ "$(gms)" == 0 ]] && ok "iOS: GMS 入站被清理干净(iOS 走 APNs 用不到)" || bad "iOS 仍有 $(gms) 条 GMS 入站"
{ [[ -e /opt/pdg-bot/probe81.py ]] && [[ -e /etc/systemd/system/pdg-probe81.service ]]; } \
  && ok "iOS: iOS 组件保留" || bad "iOS 组件被误删"
[[ ! -e /etc/privdns-gateway/platform.guessed ]] && ok "iOS: 已确认平台不打推测标记" || bad "已确认平台仍被当成推测"
[[ -e /etc/systemd/system/pdg-mitm.service ]] && ok "iOS: 补上 pdg-mitm 服务(MITM 插件宿主)" || bad "缺 pdg-mitm unit"
cp /etc/sing-box/config.json /tmp/s2
bash /usr/local/bin/pdg __migrate >/dev/null 2>&1
cmp -s /tmp/s2 /etc/sing-box/config.json && ok "iOS: 二跑幂等" || bad "iOS 二跑改动了 model"

# ══ 场景三: 已是新形态 + gfw 模式 → 劫持门必须保留 ═══════════════════════════
echo; echo "── 场景三: 新形态 + gfw 模式 ──"
rm -f /etc/privdns-gateway/platform.guessed
printf 'android\n' > /etc/privdns-gateway/platform
e2e_seed_mosdns gfw
bash /usr/local/bin/pdg __migrate >/dev/null 2>&1
{ [[ "$(gate)" == 2 ]] && grep -q 'geosite_gfw.txt' /etc/mosdns/config.yaml; } \
  && ok "gfw 模式: 劫持门保留且指向 gfw 劫持集(迁移不把它当 all 拆掉)" || bad "gfw 门=$(gate)"


# ══ 场景四: v1.7.0 机器 → 明确代理必须先于 geosite_cn 判断 ═══════════════════
# v1.7.0 及更早, 用户在 bot 里点名指到出口的域名只在 hijack_set 那道门被查, 而那道门排在
# geosite_cn **之后**。上游 geosite 一旦把某域名归进 CN, DNS 就先返真实地址, 流量根本不进
# 内核 —— 规则在、doctor 绿、就是不生效。这里跑真的 `pdg __migrate`, 验的是"老机器升上来
# 之后这件事被修好了, 而用户自己的东西一样没动"。
echo; echo "── 场景四: v1.7.0 机器升级(明确代理优先级)──"
# 迁移走 pdgtx: 候选要过 mosdns 强校验(**真启动 mosdns**)。拿不到二进制这条就没得验。
e2e_fetch_mosdns || e2e_skip "取不到 mosdns 二进制(明确代理迁移的候选校验要真启动它)"

seed_v170_box(){
  e2e_seed_mosdns all
  # 退回 v1.7.0 形态: 摘掉本次新增的域名集 / 序列 / 判断
  python3 "$E2E_ROOT/tests/helpers/strip-explicit-proxy.py" /etc/mosdns/config.yaml \
    || bad "退回 v1.7.0 形态失败"
  # 用户自己改过的 DNS 上游(bot『🌐 DNS 上游』写的)—— 迁移必须原样保留
  sed -i 's#udp://223.5.5.5:53#udp://180.76.76.76:53#' /etc/mosdns/config.yaml
  # 用户自己的规则/劫持表; 老机器上**没有** ruleset_hijack.txt(迁移要负责补出来)
  printf '# pdg-bot 显式出口域名劫持表\ndomain:perfops2.byte-test.example\n' > /etc/mosdns/rules/custom_hijack.txt
  printf 'domain:direct.example\n' > /etc/mosdns/rules/custom_direct.txt
  rm -f /etc/mosdns/rules/ruleset_hijack.txt
  printf 'android\n' > /etc/privdns-gateway/platform
  printf 'mihomo\n'  > /etc/privdns-gateway/backend
  rm -f /etc/privdns-gateway/platform.guessed
}
epline(){ grep -n 'qname \$explicit_proxy' /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }
cnline(){ grep -n 'qname \$geosite_cn'     /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }
fhline(){ grep -n 'qname \$force_hijack'   /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }

seed_v170_box
grep -q explicit_proxy /etc/mosdns/config.yaml && bad "前置: 没退回 v1.7.0 形态"
bash /usr/local/bin/pdg __migrate >/tmp/mig4.log 2>&1
rc=$?
[[ "$rc" == 0 ]] && ok "v1.7.0 迁移整体成功(exit 0)" || bad "迁移退出码 $rc: $(tail -5 /tmp/mig4.log)"

{ grep -q '^  - tag: explicit_proxy$' /etc/mosdns/config.yaml \
  && grep -q '^  - tag: explicit_proxy_seq$' /etc/mosdns/config.yaml \
  && [[ -n "$(epline)" ]]; } \
  && ok "补齐: 明确代理域名集 + 劫持序列 + internal_sequence 判断" \
  || bad "补齐失败: $(tail -5 /tmp/mig4.log)"
EP="$(epline)"; CN="$(cnline)"; FH="$(fhline)"
{ [[ -n "$EP" && -n "$CN" && -n "$FH" ]] && [[ "$FH" -lt "$EP" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "执行顺序: force_hijack($FH) → explicit_proxy($EP) → geosite_cn($CN)" \
  || bad "顺序不对: force_hijack=$FH explicit_proxy=$EP geosite_cn=$CN"
[[ -f /etc/mosdns/rules/ruleset_hijack.txt ]] \
  && ok "补出 ruleset_hijack.txt(域名集要求文件存在, 缺了 mosdns 起不来)" \
  || bad "没补 ruleset_hijack.txt"
sed -n '/- tag: explicit_proxy$/,/^  - tag: /p' /etc/mosdns/config.yaml > /tmp/ep_set.txt
{ grep -q 'custom_hijack.txt' /tmp/ep_set.txt && grep -q 'ruleset_hijack.txt' /tmp/ep_set.txt; } \
  && ok "明确代理集含 custom_hijack.txt + ruleset_hijack.txt" || bad "明确代理集文件不全"
sed -n '/- tag: explicit_proxy_seq$/,/^  - tag: /p' /etc/mosdns/config.yaml > /tmp/ep_seq.txt
grep -q "black_hole $E2E_SIP" /tmp/ep_seq.txt \
  && ok "A 记录劫持到本机网关地址 $E2E_SIP" || bad "劫持目标不是 $E2E_SIP"
{ grep -q 'qtype 28' /tmp/ep_seq.txt && grep -q 'qtype 65' /tmp/ep_seq.txt; } \
  && ok "AAAA / HTTPS(65) 抑制就位" || bad "序列缺 AAAA/HTTPS 抑制"
# 普通代理域名不得被送进 MITM: 两条劫持序列必须分开, 且 mitm_hijack.txt 仍是空的
{ grep -q 'goto force_hijack_seq' /etc/mosdns/config.yaml && ! grep -q 'mitm_hijack' /tmp/ep_set.txt; } \
  && ok "明确代理集不含 mitm_hijack.txt(不会误送 pdg-mitm)" || bad "明确代理与 MITM 接管混在一起了"
[[ ! -s /etc/mosdns/rules/mitm_hijack.txt ]] \
  && ok "mitm_hijack.txt 仍为空(迁移没往里写普通代理域名)" || bad "mitm_hijack.txt 被写入了内容"

# 用户自己的东西一样都不能动
grep -q 'udp://180.76.76.76:53' /etc/mosdns/config.yaml \
  && ok "保留: 用户自己改过的 DNS 上游" || bad "用户 DNS 上游被覆盖了"
grep -q 'perfops2.byte-test.example' /etc/mosdns/rules/custom_hijack.txt \
  && ok "保留: 用户的出口劫持表" || bad "custom_hijack.txt 被动了"
grep -q 'direct.example' /etc/mosdns/rules/custom_direct.txt \
  && ok "保留: 用户的直连表" || bad "custom_direct.txt 被动了"
{ grep -q 'client_limiter' /etc/mosdns/config.yaml && grep -q 'unlock.txt' /etc/mosdns/config.yaml \
  && grep -q 'geosite_geolocation-!cn.txt' /etc/mosdns/config.yaml; } \
  && ok "保留: 限流 / 解锁支 / 劫持集(all 模式形态未退化)" || bad "既有形态被改坏"
[[ "$(grep -c '!qname \$hijack_set' /etc/mosdns/config.yaml)" == 0 ]] \
  && ok "all 模式仍是排除式(没有被顺手装上劫持门)" || bad "all 模式被装了劫持门"

# 幂等 + 没有留下未完事务
cp /etc/mosdns/config.yaml /tmp/m4
bash /usr/local/bin/pdg __migrate >/tmp/mig5.log 2>&1
cmp -s /tmp/m4 /etc/mosdns/config.yaml && ok "二跑幂等(mosdns 配置逐字节不变)" || bad "二跑改动了 mosdns 配置"
[[ -z "$(python3 /opt/pdg-bot/pdgtx.py pending 2>/dev/null)" ]] \
  && ok "没有遗留未完成事务" || bad "留下了 pending 事务"

# doctor 要认这台机器已经修好了
python3 /opt/pdg-bot/doctor.py --json > /tmp/doc4.json 2>/dev/null
python3 "$E2E_ROOT/tests/helpers/doctor-explicit-proxy.py" /tmp/doc4.json ok \
  && ok "doctor: 明确代理优先级判 ok" || bad "doctor 没判 ok: $(cat /tmp/doc4.json 2>/dev/null | head -c 200)"

# ══ 场景五: 自定义形态 → fail-closed, 现网不动, doctor 点名 ═══════════════════
echo; echo "── 场景五: 认不出的自定义 mosdns 形态 ──"
seed_v170_box
# 把迁移赖以定位的锚点拆掉 = "高度自定义、无法安全识别"
python3 "$E2E_ROOT/tests/helpers/break-mosdns-anchor.py" /etc/mosdns/config.yaml || bad "构造自定义形态失败"
# 先跑一遍让**与本次无关**的迁移(如内存模式决定的 cache size)各自落定 —— 否则"配置有没有
# 被改"会被别人的正常改动淹掉, 断言就成了对整条迁移链的模糊判断。
bash /usr/local/bin/pdg __migrate >/tmp/mig6a.log 2>&1
grep -q explicit_proxy /etc/mosdns/config.yaml \
  && bad "自定义形态: 竟然把明确代理插进去了(该 fail-closed)" \
  || ok "自定义形态: 一次都没往认不出的配置里插东西(fail-closed)"
cp /etc/mosdns/config.yaml /tmp/m5
bash /usr/local/bin/pdg __migrate >/tmp/mig6.log 2>&1
cmp -s /tmp/m5 /etc/mosdns/config.yaml \
  && ok "自定义形态: 现网配置逐字节未被改(不猜着改)" \
  || bad "自定义形态下配置被改了: $(diff -u /tmp/m5 /etc/mosdns/config.yaml | head -20 | tr '\n' '|')"
grep -q '自定义形态' /tmp/mig6.log && ok "自定义形态: 迁移明确说明未迁移" || bad "迁移日志没说明"
[[ -z "$(python3 /opt/pdg-bot/pdgtx.py pending 2>/dev/null)" ]] \
  && ok "自定义形态: 没开事务, 也没留 pending" || bad "自定义形态下留了 pending 事务"
python3 /opt/pdg-bot/doctor.py --json > /tmp/doc5.json 2>/dev/null
python3 "$E2E_ROOT/tests/helpers/doctor-explicit-proxy.py" /tmp/doc5.json warn \
  && ok "doctor: 点名这台机器未迁移(warn)" || bad "doctor 没点名: $(cat /tmp/doc5.json 2>/dev/null | head -c 200)"


# ══ 场景六: 未完成事务 —— 该挡的挡, 不该挡的不许挡 ══════════════════════════
# 线上两台机器上都躺着几笔定时 geosite 更新留下的 PREPARING(开了但从没应用过)。它们不改现网、
# 也不挡任何写入, 但 `pdgtx pending` 会把它们打印出来。迁移若拿"输出非空"当判据, 就会在**恰恰
# 最需要修的那些机器上**静默跳过: update 照样报成功, 分流照样不生效, 没有任何一处会报错。
echo; echo "── 场景六: 陈旧 PREPARING 不挡迁移 / 真需收尾的事务要挡 ──"
TXROOT=/var/lib/privdns-gateway/tx

# 6a. 陈旧 PREPARING(3 天前, 从没应用过)→ 迁移照常进行
seed_v170_box
rm -rf "$TXROOT"; mkdir -p "$TXROOT"
stale="$(python3 "$E2E_ROOT/tests/helpers/seed-stale-tx.py" "$TXROOT" PREPARING 3)"
python3 /opt/pdg-bot/pdgtx.py pending 2>/dev/null | grep -q "$stale" \
  && ok "前置: 陈旧 PREPARING 确实会出现在 pending 输出里(判据不能只看输出)" \
  || bad "前置: 没造出陈旧 PREPARING"
bash /usr/local/bin/pdg __migrate >/tmp/mig7.log 2>&1
grep -q 'qname \$explicit_proxy' /etc/mosdns/config.yaml \
  && ok "陈旧 PREPARING 在场: 迁移照常完成(没被无关事务挡住)" \
  || bad "被陈旧 PREPARING 挡住了: $(grep -i 事务 /tmp/mig7.log | head -2)"

# 6b. 真正需要收尾的事务(APPLYING)→ 必须挡住, 且现网一个字节不动
seed_v170_box
rm -rf "$TXROOT"; mkdir -p "$TXROOT"
bash /usr/local/bin/pdg __migrate >/tmp/mig8a.log 2>&1   # 先让无关迁移落定
python3 "$E2E_ROOT/tests/helpers/strip-explicit-proxy.py" /etc/mosdns/config.yaml || bad "6b 前置失败"
applying="$(python3 "$E2E_ROOT/tests/helpers/seed-stale-tx.py" "$TXROOT" APPLYING 0)"
cp /etc/mosdns/config.yaml /tmp/m6b
bash /usr/local/bin/pdg __migrate >/tmp/mig8.log 2>&1
grep -q 'qname \$explicit_proxy' /etc/mosdns/config.yaml \
  && bad "APPLYING 事务在场却照样迁移了(该挡没挡)" \
  || ok "APPLYING 事务在场: 迁移拒绝执行"
cmp -s /tmp/m6b /etc/mosdns/config.yaml && ok "拒绝时现网配置逐字节未动" || bad "拒绝了却改了配置"
grep -q "$applying" /tmp/mig8.log && ok "迁移日志点名了挡路的事务 id" || bad "没说明是哪笔事务挡的"
rm -rf "$TXROOT"; mkdir -p "$TXROOT"


# ══ 场景七: 迁移必须能在**持锁的父进程**下完成 ═══════════════════════════════
# 真实调用链是 cmd_update(持着 /run/privdns-gateway.lock)→ 子进程 `pdg __migrate` → 各迁移。
# `__migrate` 自己不取锁, 所以迁移照跑; 但迁移里若去开 Python pdgtx 事务, 抢的是**同一把
# flock**, 必然拿到 "BUSY: 已有配置操作正在执行" —— 事务回滚, update 照样报成功, 只有 doctor
# 那条告警露馅。v1.7.1 发布当天 .200 就是这么被挡掉的。
#
# 上面几个场景都直接跑 `pdg __migrate`, 没有外层锁持有者, 于是全绿也漏掉了它。这里补上:
# 另起一个进程按住锁, 再跑迁移, 结果必须与不持锁时一致。
echo; echo "── 场景七: 有人按着 pdg 锁时, 迁移仍要完成 ──"
seed_v170_box
LOCKF="${PDG_LOCKFILE:-/run/privdns-gateway.lock}"
mkdir -p "$(dirname "$LOCKF")"
# 按住锁的旁观进程: 与 cmd_update 持锁的效果相同
flock "$LOCKF" -c 'sleep 120' &
HOLDER=$!
sleep 1
# 确认锁真的被按住了(否则这一条就是空跑)
if flock -n "$LOCKF" -c true 2>/dev/null; then
  bad "场景七前置: 锁没被按住, 用例失去意义"
else
  ok "前置: 锁确实被占着(等同 cmd_update 持锁时的处境)"
fi
bash /usr/local/bin/pdg __migrate >/tmp/mig9.log 2>&1
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true

grep -q 'qname \$explicit_proxy' /etc/mosdns/config.yaml \
  && ok "持锁时迁移照样完成(没有去抢同一把 flock)" \
  || bad "被锁挡住了: $(grep -iE 'BUSY|事务|锁' /tmp/mig9.log | head -2)"
grep -qi 'BUSY' /tmp/mig9.log && bad "迁移日志里出现了 BUSY(说明还在走 pdgtx 事务)" \
  || ok "迁移日志里没有 BUSY"
EP="$(epline)"; CN="$(cnline)"
{ [[ -n "$EP" && -n "$CN" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "持锁时迁出来的顺序同样正确(explicit_proxy $EP < geosite_cn $CN)" \
  || bad "顺序不对: explicit_proxy=$EP geosite_cn=$CN"
cp /etc/mosdns/config.yaml /tmp/m7
bash /usr/local/bin/pdg __migrate >/dev/null 2>&1
cmp -s /tmp/m7 /etc/mosdns/config.yaml && ok "持锁迁移后仍然幂等" || bad "二跑又改了配置"
ls /etc/mosdns/config.yaml.preexplicit.* >/dev/null 2>&1 \
  && bad "成功后没清掉迁移备份: $(ls /etc/mosdns/config.yaml.preexplicit.* | head -1)" \
  || ok "成功后迁移备份已清理"

e2e_summary
