#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: `pdg platform <ios|android>` 必须是**完整事务**。
#
# 以前它只写个平台标记就 run_all_migrations, 且恒返回 0:
#   · Android→iOS 之后缺 pdg-probe81.service / probe81.py / pdg-dot.mobileconfig.tmpl,
#     doctor 报 "pdg-probe81 未运行 / :81 无响应";
#   · iOS→Android 之后 nft prerouting 里 GMS 5228-5230 回不来, doctor 报 GMS 缺失;
#   · WLOC 开着时切 Android, mitm.json 关了、hijack 清了, 但 mihomo 配置里 MITM-OUT 还在;
#   · 以上全都照样打印"平台已确认"并返回 0。
#
# 本用例在真实装机现场上跑真实命令, 断言组件、防火墙、内核配置三处都跟着平台走, 失败要回滚,
# 二次执行幂等。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

# 假 systemd 没有真实的重启动力学, 稳定性观察窗口取 1 个采样即可(不是放宽断言: is-active 与
# NRestarts 照常检查, 只是不为一个桩白等 3 秒 × 服务数 × 切换次数)。
export PDG_STABLE_SAMPLES=1

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft
printf 'mihomo\n' > /etc/privdns-gateway/backend
printf 'android\n' > /etc/privdns-gateway/platform
printf 'PDG_PLATFORM=android\n' > /etc/privdns-gateway/profile.env
# 真实装好的机器上这三个 unit 一定在(切平台的校验门会逐个查它们是否稳定运行)
# unit 取真实形态: 幂等迁移按 unit 内容判断要不要补 SAFE_PATHS, 占位 unit 会让它每次重跑
# shellcheck source=lib/units.sh
source "$E2E_ROOT/lib/units.sh"
pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service
for u in pdg-bot mosdns; do
  printf '[Unit]\nDescription=%s\n[Service]\nExecStart=/usr/local/bin/%s\n' "$u" "$u" \
    > "/etc/systemd/system/$u.service"
done
for u in pdg-bot mosdns mihomo; do echo 1 > "/tmp/e2e-svc/$u.ac"; echo 1 > "/tmp/e2e-svc/$u.en"; done
e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制"

# nft 桩: 维护一份"已加载 ruleset", 好验证运行规则真的跟着变
cat > /usr/local/bin/nft <<'S'
#!/bin/sh
STATE=/tmp/e2e-nft-ruleset
case "$1" in
  -c) exit 0 ;;
  -f) [ -f "$2" ] && cat "$2" > "$STATE"; exit 0 ;;
  list) cat "$STATE" 2>/dev/null; exit 0 ;;
  delete) exit 0 ;;
esac
exit 0
S
chmod 755 /usr/local/bin/nft
nft -f /etc/nftables.conf

gms_in_nft(){ grep -qE 'tcp dport [{][^}]*5228' /etc/nftables.conf; }
gms_in_ruleset(){ grep -qE 'tcp dport [{][^}]*5228' /tmp/e2e-nft-ruleset 2>/dev/null; }
mitm_out_in_core(){ grep -q 'MITM-OUT' /etc/mihomo/config.yaml 2>/dev/null; }

# ══ 1. Android → iOS: 组件必须真部署 ═══════════════════════════════════════
echo "── 1. Android → iOS ──"
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "切到 iOS 返回 0" || bad "1: rc=$rc: $(tail -5 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] && ok "platform 标记=ios" || bad "1b: 标记没改"
grep -q '^PDG_PLATFORM=ios$' /etc/privdns-gateway/profile.env \
  && ok "profile.env 的 PDG_PLATFORM 同步为 ios" || bad "1c: profile.env 没同步: $(cat /etc/privdns-gateway/profile.env)"
for f in /etc/systemd/system/pdg-probe81.service /opt/pdg-bot/probe81.py \
         /opt/pdg-bot/pdg-dot.mobileconfig.tmpl /opt/pdg-bot/mitm_server.py; do
  [[ -e "$f" ]] && ok "已部署 $(basename "$f")" || bad "1d: 缺 $f"
done
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "pdg-probe81 已启用并运行" || bad "1e: probe81 未运行"
[[ "$(systemctl is-active pdg-mitm)" == active ]] \
  && ok "pdg-mitm 已启用并运行" || bad "1f: pdg-mitm 未运行"
gms_in_nft && bad "1g: iOS 的防火墙里仍有 GMS 5228-5230" || ok "iOS: 防火墙已无 GMS 5228-5230"

# ══ 2. WLOC 开启后切回 Android: 安全休眠 + 运行时接管彻底撤掉 ═════════════
echo; echo "── 2. WLOC 开启状态下切回 Android ──"
python3 - > /tmp/plat-wloc-on.out 2>&1 <<'PY'
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
w = {"enabled": True, "accuracy": 50, "active": "大阪", "generation": 1,
     "locations": [{"name": "大阪", "lat": 34.6937, "lon": 135.5023}]}
okr, msg = bot._mitm_transact(w)
print(("OK|" if okr else "FAIL|") + (msg or ""))
PY
grep -q '^OK|' /tmp/plat-wloc-on.out && ok "先把 WLOC 开起来(真实事务)" || bad "2: 开 WLOC 失败: $(cat /tmp/plat-wloc-on.out)"
mitm_out_in_core && ok "开启后 mihomo 配置里有 MITM-OUT(切换前的现场)" || bad "2b: MITM-OUT 没进内核配置"

out=$(pdg platform android 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "切回 Android 返回 0" || bad "2c: rc=$rc: $(tail -5 <<<"$out")"
python3 -c "
import json,sys
c=json.load(open('/etc/privdns-gateway/mitm.json'))
sys.exit(0 if c.get('wloc',{}).get('enabled') is False else 1)" \
  && ok "WLOC 已安全休眠(enabled=false)" || bad "2d: WLOC 仍开着"
python3 -c "
import json,sys
c=json.load(open('/etc/privdns-gateway/mitm.json'))
locs=[l['name'] for l in c.get('wloc',{}).get('locations',[])]
sys.exit(0 if '大阪' in locs else 1)" \
  && ok "地点数据保留(休眠不销毁)" || bad "2e: 地点被删了"
[[ -s /etc/privdns-gateway/ca/ca.crt ]] && ok "MITM CA 保留" || bad "2f: CA 被删"
[[ ! -s /etc/mosdns/rules/mitm_hijack.txt ]] && ok "接管域名已清空" || bad "2g: hijack 表还有内容"
mitm_out_in_core && bad "2h: mihomo 配置里仍残留 MITM-OUT" || ok "mihomo 配置里的 MITM-OUT 已随平台切换清掉"

# ══ 3. Android 侧的防火墙必须把 GMS 5228-5230 加回来 ═══════════════════════
echo; echo "── 3. Android 的 GMS 端口 ──"
gms_in_nft && ok "Android: 防火墙配置里有 GMS 5228-5230" || bad "3: GMS 没恢复: $(grep -n 'dport' /etc/nftables.conf | head -3)"
gms_in_ruleset && ok "Android: 运行中的 ruleset 也有 GMS(真的应用了)" || bad "3b: 运行规则里没有 GMS"
# 6.1B: probe81 已是 Android/iOS 公共件 —— 切到 Android **不许**把它清掉, 否则
# Android 少一个必需服务, 来回切平台也不幂等。只有真正 iOS 专属的才该被清。
for f in /opt/pdg-bot/pdg-dot.mobileconfig.tmpl /opt/pdg-bot/mitm_server.py; do
  [[ -e "$f" ]] && bad "3c: Android 上仍残留 iOS 专属件 $f" || ok "已移除 $(basename "$f")"
done
for f in /etc/systemd/system/pdg-probe81.service /opt/pdg-bot/probe81.py; do
  [[ -e "$f" ]] && ok "公共件 $(basename "$f") 仍在(切平台不该动它)" \
    || bad "3c: 公共件 $f 被平台切换删掉了"
done
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "pdg-probe81 在 Android 上照常运行" || bad "3d: 公共件 probe81 被停了"

# ══ 4. 二次执行幂等 ════════════════════════════════════════════════════════
echo; echo "── 4. 二跑幂等 ──"
SHA_BEFORE="$(sha256sum /etc/nftables.conf /etc/mihomo/config.yaml | sha256sum)"
out=$(pdg platform android 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "重复切到同一平台仍返回 0" || bad "4: rc=$rc: $(tail -5 <<<"$out")"
[[ "$(sha256sum /etc/nftables.conf /etc/mihomo/config.yaml | sha256sum)" == "$SHA_BEFORE" ]] \
  && ok "二跑后防火墙与内核配置逐字节未变(幂等)" || bad "4b: 二跑改了东西"

# ══ 5. 失败必须回滚并返回非 0 ══════════════════════════════════════════════
# 注入: 让防火墙重建这一步失败(nft -c 判否), 现场必须整体回到 Android。
echo; echo "── 5. 失败回滚 ──"
NFT_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
cp /usr/local/bin/nft /usr/local/bin/nft.real
cat > /usr/local/bin/nft <<'S'
#!/bin/sh
[ "$1" = "-c" ] && { echo "Error: 注入的校验失败" >&2; exit 1; }
exec /usr/local/bin/nft.real "$@"
S
chmod 755 /usr/local/bin/nft
out=$(pdg platform ios 2>&1); rc=$?
cp -f /usr/local/bin/nft.real /usr/local/bin/nft
[[ "$rc" != 0 ]] && ok "校验失败 → 返回非 0(不再谎报成功)" || bad "5: 竟然返回 0: $(tail -5 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == android ]] \
  && ok "失败后平台标记回到 android" || bad "5b: 平台标记停在 $(cat /etc/privdns-gateway/platform)"
grep -q '^PDG_PLATFORM=android$' /etc/privdns-gateway/profile.env \
  && ok "失败后 profile.env 也回到 android" || bad "5c: profile.env=$(grep PDG_PLATFORM /etc/privdns-gateway/profile.env)"
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$NFT_SHA" ]] \
  && ok "失败后防火墙配置逐字节未变" || bad "5d: 防火墙被改了"
grep -q '已恢复到原平台' <<<"$out" && ok "回滚有明确提示" || bad "5e: 没有回滚提示: $(tail -3 <<<"$out")"
# 平台专属文件必须一并回去 —— 否则平台标记明明回到 android, 盘上却留着半个 iOS 现场
for f in /opt/pdg-bot/pdg-dot.mobileconfig.tmpl \
         /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py \
         /etc/systemd/system/pdg-mitm.service; do
  [[ -e "$f" ]] && bad "5f: 回滚后仍残留 $f(半个 iOS 现场)" || ok "回滚已清除 $(basename "$f")"
done
# 公共件不参与平台回滚: 它在 android 上本来就该有, 回滚把它删掉才是错的。
for f in /opt/pdg-bot/probe81.py /etc/systemd/system/pdg-probe81.service; do
  [[ -e "$f" ]] && ok "回滚保留了公共件 $(basename "$f")" || bad "5f: 回滚把公共件 $f 删了"
done
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "回滚后 pdg-probe81 仍在运行(公共件)" || bad "5g: 公共件 probe81 被停了"
[[ "$(systemctl is-active pdg-mitm)" != active ]] \
  && ok "回滚后 pdg-mitm 未在运行" || bad "5i: pdg-mitm 还在跑"

# ══ 6. 反向: iOS 上切 Android 失败, 被清掉的 iOS 组件要放回来 ══════════════
echo; echo "── 6. iOS→Android 失败: 组件要恢复 ──"
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "先正常切到 iOS(准备现场)" || bad "6: 切 iOS 失败: $(tail -4 <<<"$out")"
IOS_SHA="$(sha256sum /opt/pdg-bot/mitm_server.py \
                     /etc/systemd/system/pdg-mitm.service | sha256sum)"
cp /usr/local/bin/nft /usr/local/bin/nft.real
cat > /usr/local/bin/nft <<'S'
#!/bin/sh
[ "$1" = "-c" ] && { echo "Error: 注入的校验失败" >&2; exit 1; }
exec /usr/local/bin/nft.real "$@"
S
chmod 755 /usr/local/bin/nft
out=$(pdg platform android 2>&1); rc=$?
cp -f /usr/local/bin/nft.real /usr/local/bin/nft
[[ "$rc" != 0 ]] && ok "切 Android 失败 → 返回非 0" || bad "6b: 竟然成功了"
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] \
  && ok "失败后平台标记回到 ios" || bad "6c: 平台标记停在 $(cat /etc/privdns-gateway/platform)"
[[ "$(sha256sum /opt/pdg-bot/mitm_server.py \
                /etc/systemd/system/pdg-mitm.service | sha256sum)" == "$IOS_SHA" ]] \
  && ok "被清理的 iOS 组件已逐字节放回" || bad "6d: iOS 组件没恢复"
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "回滚后 pdg-probe81 恢复运行" || bad "6e: probe81 没起回来"

# ══ 7. Bot 凭据未配置(合法禁用态): 双向切换都必须成功 ═════════════════════
# bot.env 两项都空 = 这台机器不用 Telegram 管理, pdg-bot 不运行是正常的。以前平台切换的
# 校验门无条件把 pdg-bot 算进必需服务, 于是这种机器 `pdg platform ios` 必然卡在
# "pdg-bot 未稳定运行"并整体回滚 —— 而它本来就没打算起 bot。
echo; echo "── 7. Bot 凭据未配置 ──"
: > /etc/privdns-gateway/bot.env                 # 两项都空
systemctl disable --now pdg-bot >/dev/null 2>&1
e2e_svc_crash pdg-bot                            # 就算被谁启动了也起不来: 它不该被要求运行
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "未配凭据 + pdg-bot 停用 → 切到 iOS 成功" || bad "7: rc=$rc: $(tail -4 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] && ok "平台标记=ios" || bad "7b: 标记没改"
[[ "$(systemctl is-active pdg-probe81)" == active ]] && ok "iOS 组件照常起来" || bad "7c: probe81 没起"
out=$(pdg platform android 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "未配凭据 → 切回 Android 也成功" || bad "7d: rc=$rc: $(tail -4 <<<"$out")"
[[ "$(systemctl is-active pdg-bot)" != active ]] \
  && ok "全程没有强行启动未配置的 pdg-bot" || bad "7e: 竟然把没配凭据的 bot 拉起来了"

# 凭据配齐(ready)时, pdg-bot 起不来就必须失败并回滚
printf 'PDG_BOT_TOKEN=123456:AAaa\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
PLAT_BEFORE="$(cat /etc/privdns-gateway/platform)"
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "凭据 ready 但 pdg-bot 起不来 → 切换失败(非 0)" || bad "7f: 竟然成功了"
grep -q 'pdg-bot' <<<"$out" && ok "点名了未稳定运行的 pdg-bot" || bad "7g: 没点名: $(tail -3 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == "$PLAT_BEFORE" ]] \
  && ok "失败后平台标记已回滚" || bad "7h: 平台停在 $(cat /etc/privdns-gateway/platform)"
# 只配一半 = 配置错误, 要明确点出来
printf 'PDG_BOT_TOKEN=123456:AAaa\n' > /etc/privdns-gateway/bot.env
out=$(pdg platform ios 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q '只配了一项' <<<"$out"; } \
  && ok "凭据只配一半 → 明确报配置错误并回滚" || bad "7i: rc=$rc: $(tail -3 <<<"$out")"
e2e_svc_heal pdg-bot
printf 'PDG_BOT_TOKEN=123456:AAaa\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
echo 1 > /tmp/e2e-svc/pdg-bot.ac; echo 1 > /tmp/e2e-svc/pdg-bot.en
pdg platform android >/dev/null 2>&1

# ══ 8. iOS 组件部署失败必须整体失败并回滚 ══════════════════════════════════
# 以前 _plat_deploy_ios 用 migrate_deploy_botfiles 装 MITM 模块, 那是**幂等迁移**的语义
# (`install … || true`): 装不上就当没这回事。于是注入 mitm_server.py 安装失败后, 命令照样
# RC=0、platform=ios, 而机器上既没有 mitm_server.py 也没有 pdg-mitm.service。
echo; echo "── 8. iOS 组件部署失败 ──"
snapshot_state(){
  { cat /etc/privdns-gateway/platform 2>/dev/null
    grep '^PDG_PLATFORM=' /etc/privdns-gateway/profile.env 2>/dev/null
    sha256sum /etc/nftables.conf /etc/mihomo/config.yaml 2>/dev/null
    for f in /opt/pdg-bot/probe81.py /opt/pdg-bot/pdg-dot.mobileconfig.tmpl \
             /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py \
             /etc/systemd/system/pdg-probe81.service /etc/systemd/system/pdg-mitm.service; do
      printf '%s=%s\n' "$f" "$([[ -e $f ]] && echo yes || echo no)"
    done
    printf 'probe81=%s/%s mitm=%s/%s\n' \
      "$(systemctl is-active pdg-probe81 2>/dev/null)" "$(systemctl is-enabled pdg-probe81 2>/dev/null)" \
      "$(systemctl is-active pdg-mitm 2>/dev/null)" "$(systemctl is-enabled pdg-mitm 2>/dev/null)"
  } | sha256sum | cut -d' ' -f1
}
# 注入: 让指定源文件"装不上"(改成不可读, install 必失败)。真实失败, 不是打桩返回值。
# 只注入**平台专属**件: probe81.py / pdg-probe81.service 自 6.1B 起是公共件, 不归
# 平台切换管(它们装失败要在 install 与 `pdg update` 里拦, 见 test-update-faults 的
# 公共件注入那一组)。放在这里注入只会测出「平台切换不管公共件」这个既定设计。
for target in deploy/bot/mitm_server.py deploy/bot/mitm_ca.py deploy/bot/mitm_wloc.py \
              deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl; do
  BEFORE="$(snapshot_state)"
  mv "/opt/privdns-gateway/$target" "/opt/privdns-gateway/$target.hidden"
  out=$(pdg platform ios 2>&1); rc=$?
  mv "/opt/privdns-gateway/$target.hidden" "/opt/privdns-gateway/$target"
  n="$(basename "$target")"
  [[ "$rc" != 0 ]] && ok "$n 部署失败 → 返回非 0" || bad "8: $n 装不上却 RC=0: $(tail -3 <<<"$out")"
  [[ "$(cat /etc/privdns-gateway/platform)" == android ]] \
    && ok "$n: 平台标记已回滚到 android" || bad "8b: $n 平台停在 $(cat /etc/privdns-gateway/platform)"
  [[ "$(snapshot_state)" == "$BEFORE" ]] \
    && ok "$n: 文件与服务状态完整回滚(逐项比对)" || bad "8c: $n 现场没回滚干净"
done

# 修好之后照常能切过去(证明上面失败不是因为环境坏了)
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "源文件恢复后切 iOS 正常成功" || bad "8d: rc=$rc: $(tail -4 <<<"$out")"
for f in /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py \
         /opt/pdg-bot/probe81.py /opt/pdg-bot/pdg-dot.mobileconfig.tmpl \
         /etc/systemd/system/pdg-probe81.service /etc/systemd/system/pdg-mitm.service; do
  [[ -s "$f" ]] || bad "8e: 成功路径缺 $f"
done
ok "成功路径七个必需文件全部就位"
pdg platform android >/dev/null 2>&1

rm -f /usr/local/bin/nft.real /tmp/e2e-nft-ruleset
e2e_summary
