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
  # 另一台机器上管理员自己往 ruleset_hijack.txt 里写了 174 条 —— 迁移只该在它**不存在**时
  # 建空文件。第一版写成了无条件 `: > file`, 于是 .200 更新时那 174 条被清成 0 字节
  # (而且是在事务失败回滚**之前**清的, 回滚也救不回来)。ADMIN_RS 用例覆盖这条。
  printf 'android\n' > /etc/privdns-gateway/platform
  printf 'mihomo\n'  > /etc/privdns-gateway/backend
  rm -f /etc/privdns-gateway/platform.guessed
  # 真机上 mosdns 是有 unit 的 —— 迁移正是靠它决定"要不要真起一遍校验新配置"。沙箱缺了这个
  # 文件, 迁移就走"本机无 mosdns 服务"那条分支, 于是校验那段代码在 e2e 里从没被跑到过。
  [[ -e /etc/systemd/system/mosdns.service ]] || \
    printf '[Unit]\nDescription=mosdns (e2e)\n[Service]\nExecStart=/usr/local/bin/mosdns start\n' \
      > /etc/systemd/system/mosdns.service
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
# 机器上装着 mosdns 服务时, 迁移必须**真起一遍**确认新配置能加载 —— 不能只写文件就报成功。
# v1.7.2 在 .200 上正是打出"未起 mosdns 校验: 本机无 mosdns 服务"然后直接报成功的: 判据
# 写成了 `systemctl list-units --all | grep -q`, 在 set -o pipefail 下是个按 unit 数量
# 决定成败的竞态。
grep -q '未起 mosdns 校验' /tmp/mig4.log \
  && bad "装着 mosdns 服务却跳过了校验(判据又变成竞态了?)" \
  || ok "有 mosdns 服务时确实做了启动校验, 没走「本机无 mosdns 服务」那条"
# 管理员已经写过内容的机器: 迁移一个字节都不许动
seed_v170_box
printf 'domain:admin-kept.example\ndomain:admin-kept2.example\n' > /etc/mosdns/rules/ruleset_hijack.txt
RSH_BEFORE="$(sha256sum /etc/mosdns/rules/ruleset_hijack.txt | cut -d" " -f1)"
bash /usr/local/bin/pdg __migrate >/tmp/mig4b.log 2>&1
[[ "$(sha256sum /etc/mosdns/rules/ruleset_hijack.txt | cut -d" " -f1)" == "$RSH_BEFORE" ]] \
  && ok "已有内容的 ruleset_hijack.txt 逐字节保留(不许无条件清空)" \
  || bad "管理员写的 ruleset_hijack.txt 被迁移清掉了($(wc -l < /etc/mosdns/rules/ruleset_hijack.txt) 行)"
grep -q 'qname \$explicit_proxy' /etc/mosdns/config.yaml \
  && ok "保留内容的同时迁移照常完成" || bad "这次迁移没完成"
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


# ══ 场景七: 迁移在**持锁的父进程**下完成; 与旁人持锁时被挡住 ═════════════════
# 真实调用链是 cmd_update(持着 /run/privdns-gateway.lock)→ 子进程 `pdg __migrate` → 各迁移。
# 迁移里若去开 Python pdgtx 事务, 抢的是**同一把 flock**, 必然拿到 "BUSY: 已有配置操作正在
# 执行" —— 事务回滚, update 照样报成功, 只有 doctor 那条告警露馅。v1.7.1 发布当天 .200 就是
# 这么被挡掉的。
#
# 这个场景原来用"另起一个进程按住锁"来近似 cmd_update 的处境。那时 `__migrate` 自己完全
# 不取锁, 两者看起来等价 —— 但它们从来就不是一回事:
#   · cmd_update 的子进程**继承**父进程那个已经持锁的 fd, 用的是同一把锁;
#   · 旁人按住锁时, `__migrate` 是个**毫无关系的第三方**, 它去改 unit/nft/mosdns/profile
#     恰恰是全局锁要拦的那种并发写。
# v1.8.1 把这件事分清楚了(_lock 认继承来的 fd, 认不出就老实去抢), 所以这里也分成两格:
# 7a 按真实形态构造(父进程持锁并把 fd 传下去), 7b 验反面。
echo; echo "── 场景七a: cmd_update 那样持锁并传下 fd 时, 迁移照常完成 ──"
seed_v170_box
LOCKF="${PDG_LOCKFILE:-/run/privdns-gateway.lock}"
mkdir -p "$(dirname "$LOCKF")"
cat > /tmp/mig9-parent.sh <<'MP'
set -u
exec 9>"${LOCKF}"
flock -n 9 || { echo "PARENT-LOCK-FAILED"; exit 9; }
bash /usr/local/bin/pdg __migrate; echo "CHILD-RC=$?"
MP
LOCKF="$LOCKF" bash /tmp/mig9-parent.sh >/tmp/mig9.log 2>&1
grep -q 'PARENT-LOCK-FAILED' /tmp/mig9.log \
  && bad "场景七a 前置: 父进程没拿到锁, 用例失去意义" \
  || ok "前置: 父进程持锁并把 fd 9 传给了子迁移(与 cmd_update 同形)"
grep -q 'CHILD-RC=0' /tmp/mig9.log \
  && ok "子迁移复用了继承来的那把锁, 返回 0" \
  || bad "子迁移没跑通: $(grep -iE 'BUSY|锁|CHILD-RC' /tmp/mig9.log | head -2)"

grep -q 'qname \$explicit_proxy' /etc/mosdns/config.yaml \
  && ok "持锁时迁移照样完成(复用同一把锁, 没有去抢第二把)" \
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

echo; echo "── 场景七b: 与迁移毫无关系的第三方按着锁时, 迁移必须被挡住且一字未改 ──"
# 这一格是七a 的反面, 也是全局锁存在的理由: 别人正在写配置时, 迁移去改 unit/nft/mosdns/
# profile 就是并发写。它必须报 BUSY 并**一个字节都不动**, 而不是"反正我是迁移我先上"。
seed_v170_box
cp /etc/mosdns/config.yaml /tmp/m7b
: > "$LOCKF"
( exec 9>"$LOCKF"; flock -n 9 || exit 1; : > /tmp/mig9b.held
  while [[ -e /tmp/mig9b.holding ]]; do sleep 0.05; done ) &
HOLDER=$!
: > /tmp/mig9b.holding
# 上面两句顺序反了会立刻松手 —— 先建标记再起后台会有竞态, 所以这里等它报到
for _i in $(seq 1 60); do [[ -e /tmp/mig9b.held ]] && break; sleep 0.05; done
if [[ -e /tmp/mig9b.held ]] && ! flock -n "$LOCKF" -c true 2>/dev/null; then
  ok "前置: 第三方确实按住了锁"
else
  bad "场景七b 前置: 锁没被按住, 用例失去意义"
fi
setsid bash -c 'exec 9<&-; bash /usr/local/bin/pdg __migrate' >/tmp/mig9b.log 2>&1; RC9B=$?
rm -f /tmp/mig9b.holding; wait "$HOLDER" 2>/dev/null || true; rm -f /tmp/mig9b.held
[[ "$RC9B" != 0 ]] && ok "第三方持锁时独立迁移返回非零(rc=$RC9B)" \
  || bad "竟然拿到了锁并跑完了(rc=$RC9B)"
grep -q '已有 pdg 操作在运行' /tmp/mig9b.log \
  && ok "明确告知有别的 pdg 操作在跑" || bad "没说清为什么退出: $(head -2 /tmp/mig9b.log)"
cmp -s /tmp/m7b /etc/mosdns/config.yaml \
  && ok "被挡住时现网配置逐字节未动" || bad "挡住了却还是改了配置"


# ══ 场景八: 老机器上按现有规则集补出派生劫持表 ═════════════════════════════════
# 规则集此前只写 mihomo 那一侧。all 模式下"不是国内就劫持"顺带兜住了, gfw 模式下劫持集只有
# 被墙域名 —— 规则集里的域名拿真实 IP、手机直连, 那条 RULE-SET 规则永远匹配不到。老机器上
# ruleset_hijack.txt 是空的, 更新时要按现有规则集重算一次。
echo; echo "── 场景八: 规则集派生劫持表 ──"
seed_v170_box
mkdir -p /etc/sing-box/rs
cat > /etc/sing-box/rs/rs_demo.json <<'RSJSON'
{"version": 1, "rules": [{"domain_suffix": ["derived.example", "derived2.example"],
                          "domain": ["exact.example"], "ip_cidr": ["203.0.113.0/24"]}]}
RSJSON
cat > /opt/pdg-bot/rulesets.json <<'RSMETA'
{"rs_demo": {"url": "http://example.invalid/demo.list", "outbound": "jp",
             "format": "source", "path": "/etc/sing-box/rs/rs_demo.json", "label": "演示集"}}
RSMETA
: > /etc/mosdns/rules/ruleset_hijack.txt
bash /usr/local/bin/pdg __migrate >/tmp/mig10.log 2>&1

grep -q '^domain:derived.example$'  /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "按规则集派生: domain_suffix → domain:" || bad "缺 domain:derived.example"
grep -q '^domain:derived2.example$' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "同一规则集的多个域名都派生了" || bad "缺第二个域名"
grep -q '^full:exact.example$' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "domain → full:(精确匹配)" || bad "缺 full:exact.example"
grep -q '203.0.113' /etc/mosdns/rules/ruleset_hijack.txt \
  && bad "IP 段被写进了域名表(DNS 这一层劫不了 IP)" || ok "ip_cidr 被正确跳过"
grep -q '规则集派生劫持表' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "带表头说明(手改会被覆盖)" || bad "没有表头"

# 幂等: 二跑内容一字不变
cp /etc/mosdns/rules/ruleset_hijack.txt /tmp/rsh1
bash /usr/local/bin/pdg __migrate >/dev/null 2>&1
cmp -s /tmp/rsh1 /etc/mosdns/rules/ruleset_hijack.txt && ok "二跑幂等(派生表逐字节不变)" || bad "二跑改了派生表"

# 管理员手填过的不许覆盖 —— 那是他自己维护的数据
printf 'domain:handwritten.example\n' > /etc/mosdns/rules/ruleset_hijack.txt
bash /usr/local/bin/pdg __migrate >/tmp/mig11.log 2>&1
grep -q '^domain:handwritten.example$' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "手填的内容没被覆盖" || bad "把管理员手填的内容冲掉了"
grep -q '手填的, 未覆盖' /tmp/mig11.log && ok "并且明确告诉了用户为什么没动" || bad "没说明"

# .mrs: 用内核自己反向导出域名清单 —— 造一份**真的** .mrs(由 mihomo 从文本转出来)
printf 'mrsdomain.example\n+.mrssuffix.example\n' > /tmp/mrssrc.txt
if mihomo convert-ruleset domain text /tmp/mrssrc.txt /etc/sing-box/rs/rs_bin.mrs >/dev/null 2>&1 \
   && [[ -s /etc/sing-box/rs/rs_bin.mrs ]]; then
  ok "造出一份真 .mrs(内核 convert-ruleset 生成)"
  cat > /opt/pdg-bot/rulesets.json <<'RSMETA2'
{"rs_bin": {"url": "http://example.invalid/geo.mrs", "outbound": "jp",
            "format": "mrs", "behavior": "domain",
            "path": "/etc/sing-box/rs/rs_bin.mrs", "label": "二进制集"}}
RSMETA2
  : > /etc/mosdns/rules/ruleset_hijack.txt
  bash /usr/local/bin/pdg __migrate >/tmp/mig12.log 2>&1
  grep -q '^full:mrsdomain.example$' /etc/mosdns/rules/ruleset_hijack.txt \
    && ok ".mrs: 精确域名派生成 full:" || bad ".mrs 没派生出 full:mrsdomain.example"
  grep -q '^domain:mrssuffix.example$' /etc/mosdns/rules/ruleset_hijack.txt \
    && ok ".mrs: +. 后缀域名派生成 domain:" || bad ".mrs 没派生出 domain:mrssuffix.example"
  python3 /opt/pdg-bot/doctor.py --json > /tmp/doc8.json 2>/dev/null
  python3 - <<'PY' && ok "doctor: .mrs 也判已同步" || bad "doctor: $(head -c 200 /tmp/doc8.json)"
import json, sys
d = json.load(open("/tmp/doc8.json"))
hit = [x for x in d if x.get("check") == "规则集劫持表"]
sys.exit(0 if hit and hit[0]["level"] == "ok" else 1)
PY
else
  bad "造不出 .mrs(内核不支持 convert-ruleset?), .mrs 派生这条没验到"
fi
# 坏档 / 类型认不出的 .mrs → 必须点名, 不能装作派生成功
printf 'not an mrs at all\n' > /etc/sing-box/rs/rs_bin.mrs
python3 - <<'PY' > /tmp/rsmeta-bad.json
import json
json.dump({"rs_bin": {"url": "http://example.invalid/geo.mrs", "outbound": "jp",
                      "format": "mrs", "path": "/etc/sing-box/rs/rs_bin.mrs",
                      "label": "坏档"}}, open("/tmp/rsmeta-bad.json", "w"))
PY
cp /tmp/rsmeta-bad.json /opt/pdg-bot/rulesets.json
: > /etc/mosdns/rules/ruleset_hijack.txt
bash /usr/local/bin/pdg __migrate >/dev/null 2>&1
python3 /opt/pdg-bot/doctor.py --json > /tmp/doc8b.json 2>/dev/null
python3 - <<'PY' && ok "坏 .mrs → doctor 点名读不出域名" || bad "坏 .mrs 没被点名: $(head -c 200 /tmp/doc8b.json)"
import json, sys
d = json.load(open("/tmp/doc8b.json"))
hit = [x for x in d if x.get("check") == "规则集劫持表"]
sys.exit(0 if hit and hit[0]["level"] == "warn" and "读不出域名" in hit[0]["detail"] else 1)
PY
rm -f /opt/pdg-bot/rulesets.json /etc/sing-box/rs/rs_demo.json /etc/sing-box/rs/rs_bin.mrs \
      /tmp/rsh1 /tmp/mrssrc.txt /tmp/rsmeta-bad.json


# ══ 场景九: 老机器补上自定义放行的 include 点 ═════════════════════════════════
# v1.7.6 及更早的 table inet pdg 里没有 include 点。以前 nftscan 撞冲突时让人"并入
# table inet pdg 的 input chain" —— 那张表每次装机/迁移都按模板重建, 手加进去的规则下次就
# 没了, 等于建议本身行不通。迁移要给老机器补上这个不受更新影响的落点。
echo; echo "── 场景九: 自定义放行 include 点 ──"
seed_v170_box
cat > /etc/nftables.conf <<'NFTC'
#!/usr/sbin/nft -f
table inet pdg
delete table inet pdg
table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 22 } accept
        ip protocol icmp accept
    }
}
NFTC
rm -rf /etc/privdns-gateway/nft-input.d
bash /usr/local/bin/pdg __migrate >/tmp/mig13.log 2>&1
[[ -d /etc/privdns-gateway/nft-input.d ]] \
  && ok "补出自定义放行目录" || bad "没建目录"
grep -qF 'include "/etc/privdns-gateway/nft-input.d/*.conf"' /etc/nftables.conf \
  && ok "补上 include 点" || bad "没补 include: $(grep -i include /tmp/mig13.log | head -1)"
python3 - <<'PY' && ok "include 点插在 pdg 的 input chain 内、policy drop 之后的末尾" || bad "位置不对"
import re, sys
lines = open("/etc/nftables.conf", encoding="utf-8").read().split("\n")
i = next((k for k, l in enumerate(lines) if re.match(r"^table\s+inet\s+pdg\s*\{", l)), None)
depth, cs, ce = 0, None, None
for k in range(i, len(lines)):
    depth += lines[k].count("{") - lines[k].count("}")
    if cs is None and re.search(r"^\s*chain\s+input\s*\{", lines[k]): cs, cd = k, depth
    elif cs is not None and depth < cd: ce = k; break
body = lines[cs:ce]
sys.exit(0 if any("nft-input.d" in l for l in body) and "nft-input.d" in body[-1] else 1)
PY
# 幂等
cp /etc/nftables.conf /tmp/nft1
bash /usr/local/bin/pdg __migrate >/dev/null 2>&1
cmp -s /tmp/nft1 /etc/nftables.conf && ok "二跑幂等(不重复插入)" || bad "二跑又插了一遍"
[[ "$(grep -c 'nft-input\.d' /etc/nftables.conf)" == 1 ]] \
  && ok "include 只有一份" || bad "include 重复了 $(grep -c 'nft-input\.d' /etc/nftables.conf) 次"

# 认不出的自定义防火墙形态 → 不猜着改
seed_v170_box
printf '#!/usr/sbin/nft -f\ntable inet pdg {\n  chain weird {\n    type filter hook forward priority 0;\n  }\n}\n' > /etc/nftables.conf
cp /etc/nftables.conf /tmp/nft2
bash /usr/local/bin/pdg __migrate >/tmp/mig14.log 2>&1
cmp -s /tmp/nft2 /etc/nftables.conf \
  && ok "pdg 表里没有 input chain → 不动防火墙(不猜着改)" || bad "改了认不出的配置"
rm -f /tmp/nft1 /tmp/nft2

e2e_summary
