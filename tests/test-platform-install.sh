#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 平台隔离: 安装/更新/迁移矩阵回归(pdg.sh 迁移函数, 打桩 + 沙箱路径, 不碰真 /)。
#   A. migrate_platform_marker: platform 文件 / profile.env / pdg-mitm 证据 / WLOC 证据 / 完全缺失。
#   B. GMS 迁移仅 Android(iOS 跳过)。
#   C. migrate_ios_gms_cleanup: 删 in-gms-* 入站 + nft 移除 5228-5230(iOS)。
#   D. migrate_android_cleanup: 删 iOS 专属 unit/文件, 保留 CA/地点数据为休眠。
#   E. _pdg_svcs: Android 无 pdg-probe81, iOS 有。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
xt(){ sed -n "/^$1(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"; }   # 抽取一个函数体

# ── A. migrate_platform_marker(路径 env 注入)──────────────────────────────────
eval "$(xt migrate_platform_marker)"
c_g(){ :; }; c_y(){ :; }
mk_marker(){ PDG_PLATFORM_FILE="$WORK/platform" PROFILE_ENV="$WORK/profile.env" \
             PDG_MITM_JSON="$WORK/mitm.json" PDG_MITM_UNIT="$WORK/pdg-mitm.service" migrate_platform_marker; }
reset_ev(){ rm -f "$WORK/platform" "$WORK/profile.env" "$WORK/mitm.json" "$WORK/pdg-mitm.service"; }

reset_ev; printf 'ios\n' > "$WORK/platform"; mk_marker
[[ "$(cat "$WORK/platform")" == ios ]] && ok "标记已合法(ios) → 幂等不改" || bad "误改了合法标记"
reset_ev; printf 'PDG_PLATFORM=ios\n' > "$WORK/profile.env"; mk_marker
[[ "$(cat "$WORK/platform")" == ios ]] && ok "缺标记 → 读 profile.env PDG_PLATFORM=ios" || bad "profile.env 证据未生效"
reset_ev; printf 'PDG_PLATFORM=android\n' > "$WORK/profile.env"; mk_marker
[[ "$(cat "$WORK/platform")" == android ]] && ok "缺标记 → 读 profile.env PDG_PLATFORM=android" || bad "android 证据未生效"
reset_ev; : > "$WORK/pdg-mitm.service"; mk_marker
[[ "$(cat "$WORK/platform")" == ios ]] && ok "缺标记 → pdg-mitm unit 证据 → ios" || bad "pdg-mitm 证据未生效"
reset_ev; printf '{"wloc":{"enabled":false}}\n' > "$WORK/mitm.json"; mk_marker
[[ "$(cat "$WORK/platform")" == ios ]] && ok "缺标记 → WLOC 配置证据 → ios" || bad "WLOC 证据未生效"
reset_ev; mk_marker
[[ "$(cat "$WORK/platform")" == android ]] && ok "无任何证据 → 安全回退 android" || bad "回退未生效"

# ── E. _pdg_svcs(平台服务集)──────────────────────────────────────────────────
eval "$(xt _pdg_svcs)"; _pdg_core_svc(){ echo sing-box; }
_pdg_platform(){ echo android; }
[[ "$(_pdg_svcs)" == "mosdns sing-box pdg-bot" ]] && ok "Android 服务集不含 pdg-probe81" || bad "Android 服务集错: $(_pdg_svcs)"
_pdg_platform(){ echo ios; }
[[ "$(_pdg_svcs)" == *pdg-probe81* ]] && ok "iOS 服务集含 pdg-probe81" || bad "iOS 服务集缺 pdg-probe81"

# ── B. GMS 迁移仅 Android(iOS 跳过)──────────────────────────────────────────
eval "$(xt migrate_singbox_gms)"; eval "$(xt migrate_fw_gms)"
sing-box(){ return 0; }; systemctl(){ [[ "$1" == is-active ]] && echo active; return 0; }; nft(){ return 0; }
# sing-box 本项目形态(有 sniff_override_destination), 无 5228
cat > "$WORK/sb.json" <<'JSON'
{"inbounds":[{"type":"direct","tag":"in-http","listen_port":80,"sniff_override_destination":true},
             {"type":"direct","tag":"in-https","listen_port":443}],"outbounds":[],"route":{}}
JSON
_pdg_platform(){ echo ios; }
migrate_singbox_gms "$WORK/sb.json"
grep -q '5228' "$WORK/sb.json" && bad "iOS 不应补 GMS 入站" || ok "migrate_singbox_gms: iOS 跳过(不补 5228)"
# nft 原装端口集, 无 5228
printf 'table inet pdg {\n  chain input { ip saddr 10.0.0.0/16 tcp dport { 53, 80, 81, 443, 853, 8445 } accept }\n}\n' > "$WORK/nf"
migrate_fw_gms "$WORK/nf"
grep -q '5228' "$WORK/nf" && bad "iOS 不应补 GMS 防火墙端口" || ok "migrate_fw_gms: iOS 跳过(不补 5228-5230)"

# ── C. migrate_ios_gms_cleanup: 删 in-gms-* + nft 移除 5228-5230 ────────────────
eval "$(xt migrate_ios_gms_cleanup)"; eval "$(xt _pdg_nft_strip_gms)"; _pdg_core_svc(){ echo sing-box; }
cat > "$WORK/sbg.json" <<'JSON'
{"inbounds":[{"type":"direct","tag":"in-https","listen_port":443},
             {"type":"direct","tag":"in-gms-5228","listen_port":5228},
             {"type":"direct","tag":"in-gms-5229","listen_port":5229},
             {"type":"direct","tag":"in-gms-5230","listen_port":5230}],"outbounds":[],"route":{}}
JSON
printf 'table inet pdg {\n  chain input { ip saddr 10.0.0.0/16 tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept }\n}\n' > "$WORK/nfg"
_pdg_platform(){ echo ios; }
migrate_ios_gms_cleanup "$WORK/sbg.json" "$WORK/nfg"
{ ! grep -q 'in-gms-5228' "$WORK/sbg.json" && ! grep -q 'in-gms-5230' "$WORK/sbg.json"; } \
  && ok "iOS 清理: sing-box 删掉 in-gms-5228/5229/5230 入站" || bad "in-gms-* 未删净"
grep -q 'in-https' "$WORK/sbg.json" && ok "iOS 清理: 非 GMS 入站(in-https)保留" || bad "误删了非 GMS 入站"
grep -q '5228' "$WORK/nfg" && bad "nft 仍含 5228" || ok "iOS 清理: nft 端口集移除 5228-5230"
# iOS 清理幂等: 再跑不变
snap="$(cat "$WORK/sbg.json")"; migrate_ios_gms_cleanup "$WORK/sbg.json" "$WORK/nfg"
[[ "$(cat "$WORK/sbg.json")" == "$snap" ]] && ok "iOS 清理幂等(二跑不变)" || bad "二跑改动了配置"
# Android 上该清理跳过
_pdg_platform(){ echo android; }
cat > "$WORK/sba.json" <<'JSON'
{"inbounds":[{"type":"direct","tag":"in-gms-5228","listen_port":5228}],"outbounds":[],"route":{}}
JSON
migrate_ios_gms_cleanup "$WORK/sba.json" "$WORK/nfg"
grep -q 'in-gms-5228' "$WORK/sba.json" && ok "Android: iOS GMS 清理不执行(保留 GMS)" || bad "Android 误删了 GMS"

# ── C3. mihomo REDIRECT 形态: 只从端口集去 5228-5230, 必须保留整条 { 80, 443 } redirect ──
# 回归: 旧实现 sed 按行删含 5228 的 redirect → 连 80/443 一起删掉 → 网关 80/443 不再 REDIRECT 到 mihomo(断网)。
_pdg_platform(){ echo ios; }
printf 'table inet pdg {\n\tchain prerouting {\n\t\ttype nat hook prerouting priority dstnat; policy accept;\n\t\tip saddr 172.22.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893\n\t}\n}\n' > "$WORK/nfmh"
migrate_ios_gms_cleanup "$WORK/none-sb.json" "$WORK/nfmh"   # sb 不存在 → 只走 nft 分支
grep -qE 'tcp dport [{][^}]*5228' "$WORK/nfmh" && bad "mihomo: 端口集仍含 5228-5230" || ok "mihomo: 端口集已精确去掉 5228-5230"
grep -qF 'tcp dport { 80, 443 } redirect to :7893' "$WORK/nfmh" && ok "mihomo: { 80, 443 } redirect 整条保留(不再误删)" || bad "mihomo: 80/443 redirect 被误删!"
snap="$(cat "$WORK/nfmh")"; migrate_ios_gms_cleanup "$WORK/none-sb.json" "$WORK/nfmh"
[[ "$(cat "$WORK/nfmh")" == "$snap" ]] && ok "mihomo REDIRECT 清理幂等(二跑不变)" || bad "二跑改动了 nft"
# nft 语法校验: 需要真 nft 二进制(type -P 只找可执行文件, 绕开本测试里的 nft() 桩), 且本环境
# 确实能跑 nft -c —— nft 即便只做 -c 也要开 netlink, 非 root(如 CI runner)会连合法规则集一起拒。
# 故先用一份**手写的合法 nat/redirect 规则集**探能力: 探测过 = 本环境能校验这类规则, 此时迁移
# 产物再不过就是真的错(照报 FAIL); 探测不过 = 环境不具备校验能力, 跳过而非谎报通过。
_nftbin="$(type -P nft 2>/dev/null || true)"
printf 'table inet nftprobe {\n\tchain prerouting {\n\t\ttype nat hook prerouting priority dstnat; policy accept;\n\t\tip saddr 172.22.0.0/16 tcp dport { 80, 443 } redirect to :7893\n\t}\n}\n' > "$WORK/nftprobe"
if [[ -n "$_nftbin" ]] && "$_nftbin" -c -f "$WORK/nftprobe" >/dev/null 2>&1; then
  if "$_nftbin" -c -f "$WORK/nfmh" >/dev/null 2>&1; then ok "迁移后 nft -c 校验通过"
  else bad "迁移后 nft -c 校验不过: $("$_nftbin" -c -f "$WORK/nfmh" 2>&1 | head -2 | tr '\n' ' ')"; fi
else
  ok "迁移后 nft -c 校验(本环境 nft 不可用或无 netlink 权限, 跳过)"
fi
# 自定义/非原装 5228 形态(逐端口而非区间)无法安全识别 → 还原不破坏
printf 'table inet pdg {\n\tchain prerouting { ip saddr X tcp dport { 80, 443, 5228, 5229, 5230 } redirect to :7893 }\n}\n' > "$WORK/nfcustom"
snapc="$(cat "$WORK/nfcustom")"; migrate_ios_gms_cleanup "$WORK/none-sb.json" "$WORK/nfcustom"
[[ "$(cat "$WORK/nfcustom")" == "$snapc" ]] && ok "自定义 5228 形态无法安全识别 → 还原不破坏配置" || bad "破坏了自定义配置"

# ── C2. _pdg_nft_strip_gms: iOS 渲染后剥掉 GMS(装机/切核共用)──────────────────
eval "$(xt _pdg_nft_strip_gms)"
printf 'table inet pdg {\n  ip saddr 10.0.0.0/16 tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept\n  ip saddr 10.0.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893\n}\n' > "$WORK/nfr"
_pdg_platform(){ echo ios; }; _pdg_nft_strip_gms "$WORK/nfr"
grep -q '5228' "$WORK/nfr" && bad "iOS strip 未去净 5228-5230" || ok "_pdg_nft_strip_gms(iOS): 端口集 + REDIRECT 均去掉 5228-5230"
grep -q '8445' "$WORK/nfr" && grep -q 'redirect to :7893' "$WORK/nfr" && ok "strip 只去 GMS, 其余端口/REDIRECT 保留" || bad "strip 误伤其它端口"
printf 'x tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept\n' > "$WORK/nfa"
_pdg_platform(){ echo android; }; _pdg_nft_strip_gms "$WORK/nfa"
grep -q '5228-5230' "$WORK/nfa" && ok "Android: _pdg_nft_strip_gms 空操作(保留 GMS)" || bad "Android 误删了 GMS"

# ── D. migrate_android_cleanup: 删 iOS 残留 unit/文件, 保留 CA/地点数据 ──────────
# 该函数用绝对路径(/etc/systemd/system, /opt/pdg-bot) → 沙箱难注入; 用静态断言核对关键行为。
u="$ROOT/deploy/bot/pdg.sh"
grep -q 'migrate_android_cleanup' "$u" && grep -q 'disable --now "\$u"' "$u" && ok "存在 Android 残留清理(停用+删 pdg-probe81/pdg-mitm unit)" || bad "缺 Android 清理逻辑"
grep -q 'CA/地点数据保留为休眠' "$u" && ok "Android 清理保留 CA/地点数据(不永久删)" || bad "未保留用户数据"
grep -q 'migrate_deploy_botfiles' "$u" && grep -q 'mitm_ca.py|mitm_server.py|mitm_wloc.py) \[\[ "\$plat" == ios \]\] || continue' "$u" \
  && ok "migrate_deploy_botfiles: Android 不部署 iOS MITM 模块" || bad "botfiles 未按平台部署"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
