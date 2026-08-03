#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 平台隔离: 安装/更新/迁移矩阵回归(pdg.sh 迁移函数, 打桩 + 沙箱路径, 不碰真 /)。
#   A. migrate_platform_marker: platform 文件 / profile.env / pdg-mitm 证据 / WLOC 证据 / 完全缺失。
#   B. GMS 防火墙端口迁移: Android 补 5228-5230, iOS 跳过(sing-box 侧已随内核退役)。
#   C. migrate_ios_gms_cleanup: 删 in-gms-* 入站 + nft 移除 5228-5230(iOS)。
#   D. migrate_android_cleanup: 删 iOS 专属 unit/文件, 保留 CA/地点数据为休眠。
#   E. _pdg_svcs: 两平台都含 pdg-probe81(6.1B 起它是公共件)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
xt(){ sed -n "/^$1(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"; }   # 抽取一个函数体
skip(){ echo "[SKIP] $1"; }                                  # 不计入 pass: 没断言就别冒充断言
# 抽真身并确认它真的到位了。函数被改名/删除时 xt 只输出空串, eval "" 又是成功的 —— 后面的
# `f x && bad || ok` 就会因为 127(command not found)稳稳落到 ok 分支, 整段变成假绿
# (migrate_singbox_gms 随 sing-box 退役后, 本文件就这么绿了一整轮)。
use_fn(){
  local f body
  for f in "$@"; do
    body="$(xt "$f")"
    [[ -n "$body" ]] || { bad "抽取失败: pdg.sh 里没有 $f()"; return 1; }
    eval "$body" || { bad "eval 函数体失败: $f"; return 1; }
    declare -F "$f" >/dev/null || { bad "eval 后函数仍不存在: $f"; return 1; }
  done
}
# 关键调用: 退出码非 0(127=命令不存在也在内)一律记 FAIL, 不指望后面的 grep 替它兜底
run_ok(){
  local what="$1"; shift; local out rc
  out="$("$@" 2>&1)"; rc=$?
  (( rc == 0 )) && return 0
  bad "$what: 退出码 $rc | $(tr '\n' ' ' <<<"$out" | head -c 200)"
  return 1
}

# ── A. migrate_platform_marker(路径 env 注入)──────────────────────────────────
use_fn migrate_platform_marker
c_g(){ :; }; c_y(){ :; }
mk_marker(){ PDG_PLATFORM_FILE="$WORK/platform" PROFILE_ENV="$WORK/profile.env" \
             PDG_MITM_JSON="$WORK/mitm.json" PDG_MITM_UNIT="$WORK/pdg-mitm.service" \
             migrate_platform_marker || bad "migrate_platform_marker 退出码 $?"; }
reset_ev(){ rm -f "$WORK/platform" "$WORK/profile.env" "$WORK/mitm.json" "$WORK/pdg-mitm.service" "$WORK/platform.guessed"; }

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
use_fn _pdg_svcs; _pdg_core_svc(){ echo sing-box; }
_pdg_platform(){ echo android; }
[[ "$(_pdg_svcs)" == "mosdns sing-box pdg-bot pdg-probe81" ]] && ok "Android 服务集也含 pdg-probe81(公共件)" || bad "Android 服务集错: $(_pdg_svcs)"
_pdg_platform(){ echo ios; }
[[ "$(_pdg_svcs)" == *pdg-probe81* ]] && ok "iOS 服务集含 pdg-probe81" || bad "iOS 服务集缺 pdg-probe81"

# ── A2. 推测出来的 android 必须打 .guessed, 且不做破坏性 iOS 清理(v1.4.x 老装保护) ──
# v1.4.x 无平台概念, 且把 probe81/描述文件装给**所有**机器 —— 它们的存在证明不了平台。
# 之前直接回退 android 并照常清理, 会把真 iPhone 部署的 iOS 组件删光, 而且之后 doctor 全绿。
reset_ev; mk_marker
{ [[ "$(cat "$WORK/platform")" == android ]] && [[ -e "$WORK/platform.guessed" ]]; } \
  && ok "无任何证据 → 回退 android 并打 .guessed(推测)" || bad "A2: 未标记为推测"
reset_ev; printf 'PDG_PLATFORM=android\n' > "$WORK/profile.env"; mk_marker
{ [[ "$(cat "$WORK/platform")" == android ]] && [[ ! -e "$WORK/platform.guessed" ]]; } \
  && ok "有确凿证据(profile.env) → 不打 .guessed" || bad "A2b: 确凿证据也被当成推测"

# 推测状态下 migrate_android_cleanup 必须跳过破坏性清理
use_fn migrate_android_cleanup
c_y(){ echo "$*"; }        # 本段要断言提示文案(文件顶部把 c_y 打桩成静默了)
reset_ev; mk_marker                     # → android + .guessed
mkdir -p "$WORK/optbot"; : > "$WORK/optbot/probe81.py"
_pdg_platform(){ echo android; }
out=$(PDG_PLATFORM_FILE="$WORK/platform" migrate_android_cleanup 2>&1)
{ grep -q '跳过 iOS 组件清理' <<<"$out" && [[ -e "$WORK/optbot/probe81.py" ]]; } \
  && ok "推测的 android → 跳过 iOS 组件清理(不冒删 iPhone 部署的风险)" || bad "A2c: out=$out"
rm -f "$WORK/platform.guessed"
out=$(PDG_PLATFORM_FILE="$WORK/platform" migrate_android_cleanup 2>&1)
grep -q '跳过 iOS 组件清理' <<<"$out" && bad "A2d: 已确认仍跳过清理" || ok "确认后的 android → 正常执行清理"
c_y(){ :; }                # 恢复静默, 不干扰后续用例

# ── A3. migrate_backend_marker: 老装(v1.4.x)从无 backend 标记, 必须据现场证据落地 ──
# 隐患: 一直靠 _pdg_core 的默认值 singbox 兜底; 默认值将来一改就会静默换核, 而机器上
# 可能根本没装那个内核。抽真身 + 绝对路径重定向到沙箱(不给生产代码加接缝)。
BM="$WORK/bm"; mkdir -p "$BM/etc/privdns-gateway" "$BM/etc/systemd/system" "$BM/etc/mihomo"
xt migrate_backend_marker | sed -e "s#/etc/#$BM/etc/#g" > "$WORK/bmfn.sh"
bm_run(){ # $1=额外桩
  rm -f "$BM/etc/privdns-gateway/backend"
  bash -c "set -uo pipefail
c_g(){ echo \"\$*\"; }; c_y(){ :; }
install(){ command install \"\$@\"; }
$1
source '$WORK/bmfn.sh'
migrate_backend_marker >/dev/null 2>&1
cat '$BM/etc/privdns-gateway/backend' 2>/dev/null || echo '(无)'"
}
rm -f "$BM/etc/systemd/system/"*.service "$BM/etc/mihomo/config.yaml"
[[ "$(bm_run 'systemctl(){ echo inactive; return 1; }')" == singbox ]] \
  && ok "backend: 无任何证据 → 兜底 singbox(与历史默认一致)" || bad "A3a"

: > "$BM/etc/systemd/system/mihomo.service"
[[ "$(bm_run 'systemctl(){ [[ "$1" == is-active ]] && echo active; return 0; }')" == mihomo ]] \
  && ok "backend: mihomo unit 存在且 active → mihomo" || bad "A3b"

rm -f "$BM/etc/systemd/system/mihomo.service"; : > "$BM/etc/systemd/system/sing-box.service"
[[ "$(bm_run 'systemctl(){ [[ "$1" == is-active ]] && echo active; return 0; }')" == singbox ]] \
  && ok "backend: sing-box unit 存在且 active → singbox" || bad "A3c"

# unit 文件不存在时, is-active 谎报 active 也不能被采信(正是加 unit 存在性前置的原因)
rm -f "$BM/etc/systemd/system/"*.service
[[ "$(bm_run 'systemctl(){ [[ "$1" == is-active ]] && echo active; return 0; }')" == singbox ]] \
  && ok "backend: unit 不存在时不轻信 is-active(不误判成 mihomo)" || bad "A3d"

# 已有合法标记 → 幂等不改
printf 'mihomo\n' > "$BM/etc/privdns-gateway/backend"
out=$(bash -c "c_g(){ :; }; c_y(){ :; }; install(){ :; }; systemctl(){ echo active; }
source '$WORK/bmfn.sh'; migrate_backend_marker; cat '$BM/etc/privdns-gateway/backend'" 2>/dev/null)
[[ "$out" == mihomo ]] && ok "backend: 已有合法标记 → 幂等不改" || bad "A3e: $out"

# ── B. GMS 防火墙端口迁移: 仅 Android 补 5228-5230, iOS 跳过 ──────────────
# sing-box 侧的 migrate_singbox_gms 已随 sing-box 运行时一并退役, 原用例调的是一个不存在的
# 函数(见文件头 use_fn 注释)。换成**当前仍在跑**的防火墙侧, 并钉住"它确实没了": 哪天再冒
# 出来, 得连同它的平台跳过用例一起补回来, 而不是又静静地假绿。
if grep -q '^migrate_singbox_gms()' "$ROOT/deploy/bot/pdg.sh"; then
  bad "migrate_singbox_gms 又回来了: 需要补回它的 iOS 跳过用例"
else
  ok "migrate_singbox_gms 已随 sing-box 退役(不再有 model 入站迁移)"
fi
use_fn migrate_fw_gms
systemctl(){ [[ "$1" == is-active ]] && echo active; return 0; }
nft(){ return 0; }              # -c 校验与加载都当成功: 本段只验改写判据
nf_orig='table inet pdg {\n  ip saddr 10.0.0.0/16 tcp dport { 53, 80, 81, 443, 853, 8445 } accept\n}\n'
# iOS: 原装形态也不能补 —— GMS/FCM 是 Android 的推送通道
_pdg_platform(){ echo ios; }
printf "$nf_orig" > "$WORK/nf"
run_ok "migrate_fw_gms(iOS)" migrate_fw_gms "$WORK/nf"
grep -q '5228' "$WORK/nf" && bad "iOS 不应补 GMS 防火墙端口" || ok "migrate_fw_gms: iOS 跳过(不补 5228-5230)"
# Android: 原装形态要补上
_pdg_platform(){ echo android; }
printf "$nf_orig" > "$WORK/nf"
run_ok "migrate_fw_gms(Android)" migrate_fw_gms "$WORK/nf"
grep -qF 'tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept' "$WORK/nf" \
  && ok "migrate_fw_gms: Android 原装端口集补上 5228-5230" || bad "Android 未补 GMS 端口: $(cat "$WORK/nf")"
snapb="$(cat "$WORK/nf")"
run_ok "migrate_fw_gms(幂等)" migrate_fw_gms "$WORK/nf"
[[ "$(cat "$WORK/nf")" == "$snapb" ]] && ok "migrate_fw_gms: 已有 5228 → 幂等不再改" || bad "二跑又改了防火墙配置"
# 自定义端口集不认: 宁可提示手动加, 也不猜着改用户的规则
printf 'table inet pdg {\n  ip saddr 10.0.0.0/16 tcp dport { 53, 443, 9443 } accept\n}\n' > "$WORK/nfcust"
snapb="$(cat "$WORK/nfcust")"
run_ok "migrate_fw_gms(自定义)" migrate_fw_gms "$WORK/nfcust"
[[ "$(cat "$WORK/nfcust")" == "$snapb" ]] && ok "migrate_fw_gms: 非原装端口集不自动改写" || bad "改写了自定义端口集"
rm -f "$WORK"/nf.pregms.* "$WORK"/nfcust.pregms.*

# ── C. migrate_ios_gms_cleanup: 删 in-gms-* + nft 移除 5228-5230 ────────────────
use_fn migrate_ios_gms_cleanup _pdg_nft_strip_gms _pdg_nft_bin; _pdg_core_svc(){ echo mihomo; }
# 沙箱化真实现: 内核配置/工作目录/bot 模块都用 env 指进 $WORK, 服务动作与着色输出打桩。
# 被测的是 migrate_ios_gms_cleanup 本身(候选→校验→落盘→回滚), 不是 systemd。
export PDG_MIHOMO_CFG="$WORK/mihomo.yaml" PDG_STATE_DIR="$WORK/state" \
       PDG_BOT_PY="$ROOT/deploy/bot/pdg-bot.py"
c_g(){ echo "  $*"; }; c_y(){ echo "  $*"; }; c_r(){ echo "  $*"; }
GMS_RESTART_FAIL=""; GMS_CORE_UNSTABLE=""; GMS_NFT_F_FAIL=""
systemctl(){
  echo "systemctl $*" >> "$WORK/gms-calls"
  [[ "${GMS_RESTART_FAIL:-}" == 1 && "$1" == restart ]] && return 1
  return 0
}
_core_kernel_stable(){ [[ "${GMS_CORE_UNSTABLE:-}" != 1 ]]; }
# 假 nft **可执行文件**(不是 shell 函数): 迁移现在用 _pdg_nft_bin 解析出的绝对路径调用它,
# 函数桩根本不会被用到 —— 而这正是"PATH 没有 sbin 也不能跳过 nft"那条修复的关键。
# 它同时模拟运行态: 每次 `-f <file>` 都把该文件的 SHA 写进 $WORK/nft-runtime, 于是"回滚有没有
# 用旧配置重放一次"可以被真实断言, 而不是只看磁盘文件。
mkdir -p "$WORK/sbin"
cat > "$WORK/sbin/nft" <<'NFT'
#!/usr/bin/env bash
echo "nft $*" >> "$GMS_NFT_CALLS"
if [[ "$1" == -c ]]; then [[ "${GMS_NFT_C_FAIL:-}" != 1 ]]; exit $?; fi
if [[ "$1" == -f ]]; then
  f="$2"          # 调用形态是 `nft -f <file>`
  n=$(( $(cat "$GMS_NFT_FCOUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GMS_NFT_FCOUNT"
  # 先改"内核运行态"再决定返回码: 模拟"部分生效之后才失败"
  sha256sum "$f" | cut -d" " -f1 > "$GMS_NFT_RUNTIME"
  if [[ "${GMS_NFT_F_FAIL:-}" == 1 && "$n" == 1 ]]; then exit 1; fi
  if [[ "${GMS_NFT_F_FAIL_ALL:-}" == 1 ]]; then exit 1; fi
  exit 0
fi
exit 0
NFT
chmod 755 "$WORK/sbin/nft"
export GMS_NFT_CALLS="$WORK/nft-calls" GMS_NFT_FCOUNT="$WORK/nftf" GMS_NFT_RUNTIME="$WORK/nft-runtime"
export GMS_NFT_C_FAIL="" GMS_NFT_F_FAIL="" GMS_NFT_F_FAIL_ALL=""
# 默认让定位器找到它(单独的用例会换成真 _pdg_nft_bin 去验 PATH 盲区)
_pdg_nft_bin(){ printf '%s\n' "$WORK/sbin/nft"; }
# 内核配置的基线内容 = 用当前 model 渲染出来的那一份 —— 这样"回滚后的内核配置对应回滚后的
# model"才是可验证的, 而不是拿一个手写字符串充数。
_gms_render(){ PDG_BOT_PY="$ROOT/deploy/bot/pdg-bot.py" python3 - "$1" "$2" <<'RPY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("bot", os.environ["PDG_BOT_PY"])
bot = importlib.util.module_from_spec(spec); spec.loader.exec_module(bot)
open(sys.argv[2], "wb").write(bot._mihomo_derive({"model": open(sys.argv[1], "rb").read()}))
RPY
}
cat > "$WORK/sbg.json" <<'JSON'
{"inbounds":[{"type":"direct","tag":"in-https","listen_port":443},
             {"type":"direct","tag":"in-gms-5228","listen_port":5228},
             {"type":"direct","tag":"in-gms-5229","listen_port":5229},
             {"type":"direct","tag":"in-gms-5230","listen_port":5230}],"outbounds":[],"route":{}}
JSON
printf 'table inet pdg {\n  chain input { ip saddr 10.0.0.0/16 tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept }\n}\n' > "$WORK/nfg"
_pdg_platform(){ echo ios; }
_gms_render "$WORK/sbg.json" "$WORK/mihomo.yaml" || bad "渲染基线内核配置失败"
run_ok "migrate_ios_gms_cleanup(iOS)" migrate_ios_gms_cleanup "$WORK/sbg.json" "$WORK/nfg"
{ ! grep -q 'in-gms-5228' "$WORK/sbg.json" && ! grep -q 'in-gms-5230' "$WORK/sbg.json"; } \
  && ok "iOS 清理: sing-box 删掉 in-gms-5228/5229/5230 入站" || bad "in-gms-* 未删净"
grep -q 'in-https' "$WORK/sbg.json" && ok "iOS 清理: 非 GMS 入站(in-https)保留" || bad "误删了非 GMS 入站"
grep -q '5228' "$WORK/nfg" && bad "nft 仍含 5228" || ok "iOS 清理: nft 端口集移除 5228-5230"
# iOS 清理幂等: 再跑不变
snap="$(cat "$WORK/sbg.json")"
run_ok "migrate_ios_gms_cleanup(幂等)" migrate_ios_gms_cleanup "$WORK/sbg.json" "$WORK/nfg"
[[ "$(cat "$WORK/sbg.json")" == "$snap" ]] && ok "iOS 清理幂等(二跑不变)" || bad "二跑改动了配置"
# Android 上该清理跳过
_pdg_platform(){ echo android; }
cat > "$WORK/sba.json" <<'JSON'
{"inbounds":[{"type":"direct","tag":"in-gms-5228","listen_port":5228}],"outbounds":[],"route":{}}
JSON
run_ok "migrate_ios_gms_cleanup(Android)" migrate_ios_gms_cleanup "$WORK/sba.json" "$WORK/nfg"
grep -q 'in-gms-5228' "$WORK/sba.json" && ok "Android: iOS GMS 清理不执行(保留 GMS)" || bad "Android 误删了 GMS"

# ── C3. mihomo REDIRECT 形态: 只从端口集去 5228-5230, 必须保留整条 { 80, 443 } redirect ──
# 回归: 旧实现 sed 按行删含 5228 的 redirect → 连 80/443 一起删掉 → 网关 80/443 不再 REDIRECT 到 mihomo(断网)。
_pdg_platform(){ echo ios; }
printf 'table inet pdg {\n\tchain prerouting {\n\t\ttype nat hook prerouting priority dstnat; policy accept;\n\t\tip saddr 172.22.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893\n\t}\n}\n' > "$WORK/nfmh"
run_ok "migrate_ios_gms_cleanup(mihomo)" migrate_ios_gms_cleanup "$WORK/none-sb.json" "$WORK/nfmh"   # sb 不存在 → 只走 nft 分支
grep -qE 'tcp dport [{][^}]*5228' "$WORK/nfmh" && bad "mihomo: 端口集仍含 5228-5230" || ok "mihomo: 端口集已精确去掉 5228-5230"
grep -qF 'tcp dport { 80, 443 } redirect to :7893' "$WORK/nfmh" && ok "mihomo: { 80, 443 } redirect 整条保留(不再误删)" || bad "mihomo: 80/443 redirect 被误删!"
snap="$(cat "$WORK/nfmh")"
run_ok "migrate_ios_gms_cleanup(mihomo 幂等)" migrate_ios_gms_cleanup "$WORK/none-sb.json" "$WORK/nfmh"
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
  skip "迁移后 nft -c 校验: 本环境 nft 不可用或无 netlink 权限(CI 的容器 E2E 里有真 nft)"
fi
# 自定义/非原装 5228 形态(逐端口而非区间)无法安全识别 → 还原不破坏
printf 'table inet pdg {\n\tchain prerouting { ip saddr X tcp dport { 80, 443, 5228, 5229, 5230 } redirect to :7893 }\n}\n' > "$WORK/nfcustom"
snapc="$(cat "$WORK/nfcustom")"
run_ok "migrate_ios_gms_cleanup(自定义)" migrate_ios_gms_cleanup "$WORK/none-sb.json" "$WORK/nfcustom"
[[ "$(cat "$WORK/nfcustom")" == "$snapc" ]] && ok "自定义 5228 形态无法安全识别 → 还原不破坏配置" || bad "破坏了自定义配置"

# ── C4. 事务性: 候选先行 / 校验不过零改动 / 落盘失败完整回滚 / 失败必须传播 ─────────
# 这一段盯的是"迁移会不会把现网留在半套状态", 以及"失败有没有被上层收到"。
_gms_fixture(){                                   # 造一套干净现场, 返回三个文件的 SHA
  cat > "$WORK/g-sb.json" <<'JSON'
{"inbounds":[{"type":"direct","tag":"in-https","listen_port":443},
             {"type":"direct","tag":"in-gms-5228","listen_port":5228},
             {"type":"direct","tag":"in-gms-5229","listen_port":5229}],
 "outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}
JSON
  printf 'table inet pdg {\n\tchain prerouting { ip saddr 172.22.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893 }\n}\n' > "$WORK/g-nf"
  _gms_render "$WORK/g-sb.json" "$WORK/mihomo.yaml"
  rm -f "$WORK/nftf" "$WORK/gms-calls" "$WORK/nft-calls"
  sha256sum "$WORK/g-nf" | cut -d" " -f1 > "$WORK/nft-runtime"   # 运行态 = 当前(旧)配置
  GMS_RESTART_FAIL=""; GMS_CORE_UNSTABLE=""; GMS_NFT_F_FAIL=""; GMS_NFT_C_FAIL=""
  GMS_NFT_F_FAIL_ALL=""
  export PDG_MIHOMO_CFG="$WORK/mihomo.yaml" PDG_BOT_PY="$ROOT/deploy/bot/pdg-bot.py"
  _G_SB="$(sha256sum "$WORK/g-sb.json" | cut -d" " -f1)"
  _G_MH="$(sha256sum "$WORK/mihomo.yaml" | cut -d" " -f1)"
  _G_NF="$(sha256sum "$WORK/g-nf" | cut -d" " -f1)"
}
_gms_unchanged(){                                 # 三个生产文件必须一个字节都没变
  local what="$1" bad3=()
  [[ "$(sha256sum "$WORK/g-sb.json" | cut -d" " -f1)" == "$_G_SB" ]] || bad3+=(model)
  [[ "$(sha256sum "$WORK/mihomo.yaml" | cut -d" " -f1)" == "$_G_MH" ]] || bad3+=(内核配置)
  [[ "$(sha256sum "$WORK/g-nf" | cut -d" " -f1)" == "$_G_NF" ]] || bad3+=(防火墙)
  [[ ${#bad3[@]} -eq 0 ]] && ok "$what" || bad "$what —— 这些文件被动了: ${bad3[*]}"
}
_pdg_platform(){ echo ios; }

# 1) 候选渲染失败(bot 侧判 dropped/无法转换那一类)→ 三个文件零改动
_gms_fixture
cat > "$WORK/badbot.py" <<'PYB'
def _mihomo_derive(staged):
    raise ValueError("渲染失败(测试注入)")
PYB
PDG_BOT_PY="$WORK/badbot.py" migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "候选渲染失败却返回 0" || ok "候选渲染失败 → 返回非 0"
_gms_unchanged "候选渲染失败: 三个生产文件零修改"

# 2) mihomo -t 校验失败 → 零改动
_gms_fixture
mihomo(){ [[ "$1" == -t ]] && return 1; return 0; }
migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "mihomo -t 失败却返回 0" || ok "候选 mihomo -t 失败 → 返回非 0"
_gms_unchanged "mihomo -t 失败: 三个生产文件零修改"
unset -f mihomo

# 3) nft -c 校验失败 → 零改动
_gms_fixture; GMS_NFT_C_FAIL=1
migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "nft -c 失败却返回 0" || ok "候选 nft -c 失败 → 返回非 0"
_gms_unchanged "nft -c 失败: 三个生产文件零修改"
GMS_NFT_C_FAIL=""

# 4) 第 2 个文件(内核配置)落盘失败 → 第 1 个(model)必须已还原
_gms_fixture
: > "$WORK/blocker"                                  # 父目录是个**文件** → install 必失败
PDG_MIHOMO_CFG="$WORK/blocker/config.yaml" migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "内核配置落盘失败却返回 0" || ok "第 N 个文件落盘失败 → 返回非 0"
[[ "$(sha256sum "$WORK/g-sb.json" | cut -d" " -f1)" == "$_G_SB" ]] \
  && ok "落盘中途失败: 先落的 model 已还原(不留半套)" || bad "model 没还原"

# 5) nft apply 失败(第一次 -f 失败, 回滚时的 -f 成功)→ 配置与运行态都恢复
_gms_fixture; GMS_NFT_F_FAIL=1
out="$(migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" 2>&1)"; rc=$?
[[ $rc != 0 ]] && ok "nft apply 失败 → 返回非 0" || bad "nft apply 失败却返回 0"
grep -q "已回滚" <<<"$out" && ok "nft apply 失败: 明确报告已回滚" || bad "没报告回滚: $out"
_gms_unchanged "nft apply 失败: 三个生产文件都回到清理前"
GMS_NFT_F_FAIL=""

# 6) 内核重启失败 → model 与内核配置必须**一起**还原, 且内核配置对应还原后的 model
_gms_fixture; GMS_RESTART_FAIL=1
migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "内核重启失败却返回 0" || ok "内核重启失败 → 返回非 0"
_gms_unchanged "内核重启失败: model / 内核配置 / 防火墙 全部还原"
_gms_render "$WORK/g-sb.json" "$WORK/expect-mh.yaml"
cmp -s "$WORK/expect-mh.yaml" "$WORK/mihomo.yaml" \
  && ok "还原后的内核配置确实对应还原后的 model(不是旧的错位副本)" \
  || bad "内核配置与 model 不对应"
GMS_RESTART_FAIL=""

# 7) 回滚里的服务也起不来 → 必须明确报"回滚不完整"并保留材料, 不许打印"已还原"
_gms_fixture; GMS_RESTART_FAIL=1; GMS_CORE_UNSTABLE=1
out="$(migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" 2>&1)"; rc=$?
{ [[ $rc != 0 ]] && grep -q "回滚不完整" <<<"$out" && ! grep -q "已回滚:" <<<"$out"; } \
  && ok "回滚阶段服务失败 → 返回非 0 且明说回滚不完整(不谎称已还原)" \
  || bad "回滚失败的报告不对: rc=$rc | $(tr '\n' ' ' <<<"$out" | head -c 120)"
grep -q "$WORK/state" <<<"$out" && ok "回滚不完整时给出保留的材料目录路径" || bad "没给材料路径"
rm -rf "$WORK/state"/iosgms.* 2>/dev/null
GMS_RESTART_FAIL=""; GMS_CORE_UNSTABLE=""

# 8) 失败必须被这些调用方收到 —— 用真函数体 + 注入一个必失败的迁移
_rams="$(xt run_all_migrations)"
[[ -n "$_rams" ]] || bad "抽不到 run_all_migrations"
( eval "$_rams"
  for f in migrate_platform_marker migrate_backend_marker migrate_botenv migrate_firewall_to_pdg \
           migrate_mosdns_concurrent migrate_mosdns_unlock migrate_fw_gms migrate_mosdns_ratelimit \
           migrate_lowmem migrate_mihomo_safepaths migrate_deploy_botfiles migrate_deploy_units \
           migrate_mosdns_hijack_shape migrate_custom_hijack migrate_mosdns_mitm \
           migrate_pdg_mitm_service migrate_android_cleanup migrate_drop_singbox; do
    eval "$f(){ return 0; }"
  done
  migrate_ios_gms_cleanup(){ return 1; }
  run_all_migrations >/dev/null 2>&1 ) \
  && bad "run_all_migrations 吞掉了 iOS GMS 清理的失败" \
  || ok "run_all_migrations 把 iOS GMS 清理的失败传出(cmd_update/cmd_migrate 据此回滚/点名快照)"
grep -q 'migrate_ios_gms_cleanup || true' "$ROOT/deploy/bot/pdg.sh" \
  && bad "pdg.sh 里还有 `migrate_ios_gms_cleanup || true`" \
  || ok "pdg.sh 里不再用 || true 吞掉这条关键迁移"
_cp="$(xt cmd_platform)"
grep -q 'migrate_ios_gms_cleanup' <<<"$_cp" && grep -q '_plat_rollback' <<<"$_cp" \
  && ok "cmd_platform 会跑这条关键迁移, 失败走 _plat_rollback" || bad "cmd_platform 没接这条迁移"
awk '/migrate_ios_gms_cleanup/{m=NR} /rm -rf "\$wd"/{if(m && NR>m){print "AFTER"; exit}}' <<<"$_cp" \
  | grep -q AFTER && ok "cmd_platform 里这条迁移排在删除回滚材料之前" \
  || bad "迁移跑在 rm -rf \$wd 之后(那时已经没有回滚材料了)"

# ── C5. nft 部分生效后失败 → 必须用旧配置重放一次, 把运行态也拉回去 ──────────────
_gms_fixture
_before_nf_sha="$(sha256sum "$WORK/g-nf" | cut -d" " -f1)"
GMS_NFT_F_FAIL=1
out="$(migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" 2>&1)"; rc=$?
[[ $rc != 0 ]] && ok "nft apply 部分生效后失败 → 返回非 0" || bad "nft apply 失败却返回 0"
_nf_loads="$(grep -c '^nft -f' "$WORK/nft-calls" 2>/dev/null || echo 0)"
[[ "$_nf_loads" == 2 ]] \
  && ok "回滚**又调了一次 nft -f**(第 1 次应用 + 第 2 次用旧配置恢复运行态), 共 2 次" \
  || bad "nft -f 调用次数是 $_nf_loads(期望 2: 应用 + 回滚重放)"
[[ "$(cat "$WORK/nft-runtime")" == "$_before_nf_sha" ]] \
  && ok "模拟的内核运行态已回到操作前那份配置(不是只还原了磁盘文件)" \
  || bad "运行态没回到旧配置: $(cat "$WORK/nft-runtime") != $_before_nf_sha"
_second="$(grep '^nft -f' "$WORK/nft-calls" | sed -n '2p' | awk '{print $NF}')"
[[ "$(sha256sum "$_second" | cut -d" " -f1)" == "$_before_nf_sha" ]] \
  && ok "第 2 次加载的确实是**旧配置文件**" || bad "第 2 次加载的不是旧配置: $_second"
_gms_unchanged "nft apply 失败后: 三个生产文件回到清理前"
GMS_NFT_F_FAIL=""

# 回滚里的 nft -f 也失败 → 必须明说回滚不完整, 不许报"已回滚"
_gms_fixture; GMS_NFT_F_FAIL_ALL=1
out="$(migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" 2>&1)"; rc=$?
{ [[ $rc != 0 ]] && grep -q "回滚不完整" <<<"$out" && grep -q "运行态未还原" <<<"$out"; } \
  && ok "回滚重放 nft -f 也失败 → 明确报「回滚不完整 + 运行态未还原」" \
  || bad "回滚失败没被如实报告: rc=$rc | $(tr '\n' ' ' <<<"$out" | head -c 140)"
GMS_NFT_F_FAIL_ALL=""; rm -rf "$WORK/state"/iosgms.* 2>/dev/null

# ── C6. nft 定位: PATH 里没有 sbin 也必须找到(不许跳过校验/应用) ────────────────
_gms_fixture
mkdir -p "$WORK/fakerepo/deploy/bot"
cat > "$WORK/fakerepo/deploy/bot/nftscan.py" <<'SCAN'
import sys
NFT_CANDIDATES = ("/does/not/matter",)
if "--nft-path" in sys.argv:
    import os
    print(os.environ.get("GMS_FAKE_NFT", ""))
SCAN
cp "$ROOT/lib/nftbin.sh" "$WORK/fakerepo/lib.sh" 2>/dev/null || mkdir -p "$WORK/fakerepo/lib"
mkdir -p "$WORK/fakerepo/lib"; cp "$ROOT/lib/nftbin.sh" "$WORK/fakerepo/lib/nftbin.sh"
unset -f _pdg_nft_bin; use_fn _pdg_nft_bin || bad "抽不到 _pdg_nft_bin"
( export REPO_DIR="$WORK/fakerepo" GMS_FAKE_NFT="$WORK/sbin/nft" PATH="/usr/bin:/bin"
  _found="$(_pdg_nft_bin)"
  [[ "$_found" == "$WORK/sbin/nft" ]] ) \
  && ok "PATH 不含 sbin 时, _pdg_nft_bin 仍能定位到 nft(GMS 迁移复用同一判据)" \
  || bad "PATH 不含 sbin 时定位失败"
_pdg_nft_bin(){ printf ''; }                      # 完全找不到 nft
_gms_fixture
migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "找不到 nft 却返回 0" || ok "完全找不到 nft → 返回非 0(fail-closed)"
_gms_unchanged "找不到 nft: 三个生产文件零改动"
_pdg_nft_bin(){ printf '%s\n' "$WORK/sbin/nft"; }

# ── C7. before-image 连 mode/uid/gid 一起复核 ────────────────────────────────
_gms_fixture
chmod 640 "$WORK/g-sb.json"
GMS_RESTART_FAIL=1
migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "重启失败却返回 0" || ok "重启失败 → 返回非 0"
[[ "$(stat -c '%a' "$WORK/g-sb.json")" == 640 ]] \
  && ok "回滚把权限也还原成 640(不是默认 600)" || bad "权限没还原: $(stat -c '%a' "$WORK/g-sb.json")"
[[ "$(stat -c '%u:%g' "$WORK/g-sb.json")" == "$(id -u):$(id -g)" ]] \
  && ok "回滚后归属(uid:gid)与操作前一致" || bad "归属变了"
GMS_RESTART_FAIL=""
skip "chown 到别的 uid 需要 root: 本环境只验「归属未被改变」, 复核逻辑本身由上面的断言覆盖"

# ── C8. 形态守卫: 软链/硬链目标必须在候选阶段之前就被拒(不能经链接写穿现网) ────────
# 回归: `cp -a` 会把源符号链接原样搬进候选目录, 于是 chmod / python 写入 / sed -i 直接改到
# 现网(甚至改到链接指向的别处), before-image 也不再是旧内容。
_gms_symlink_case(){                       # $1=哪个目标做成软链(config.json/config.yaml/nftables.conf)
  _gms_fixture
  rm -f "$WORK/gms-calls" "$WORK/nft-calls"
  printf 'SENTINEL-CONTENT\n' > "$WORK/sentinel"
  chmod 640 "$WORK/sentinel"
  local _sent_sha _sent_mode target
  _sent_sha="$(sha256sum "$WORK/sentinel" | cut -d" " -f1)"; _sent_mode="$(stat -c '%a' "$WORK/sentinel")"
  case "$1" in
    config.json)    target="$WORK/g-sb.json";;
    config.yaml)    target="$WORK/mihomo.yaml";;
    nftables.conf)  target="$WORK/g-nf";;
  esac
  rm -f "$target"; ln -s "$WORK/sentinel" "$target"
  migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
    && bad "$1 是软链却返回 0(可能已经写穿到 sentinel)" || ok "$1 是软链 → 返回非 0"
  [[ "$(sha256sum "$WORK/sentinel" | cut -d" " -f1)" == "$_sent_sha" ]] \
    && ok "$1 软链: sentinel 内容一个字节都没变" || bad "$1 软链: sentinel 被改了!"
  [[ "$(stat -c '%a' "$WORK/sentinel")" == "$_sent_mode" ]] \
    && ok "$1 软链: sentinel 权限没被改" || bad "$1 软链: sentinel 权限被改成 $(stat -c '%a' "$WORK/sentinel")"
  [[ -L "$target" ]] && ok "$1 软链: 链接本身仍在(没被替换成普通文件)" || bad "$1 软链被替换掉了"
  [[ ! -s "$WORK/gms-calls" && ! -s "$WORK/nft-calls" ]] \
    && ok "$1 软链: systemctl / nft 零调用(拒绝发生在任何服务动作之前)" \
    || bad "$1 软链却动了服务: $(cat "$WORK/gms-calls" "$WORK/nft-calls" 2>/dev/null | tr '\n' ' ')"
  rm -f "$target"
}
_gms_symlink_case config.json
_gms_symlink_case nftables.conf
_gms_symlink_case config.yaml

# 硬链接目标: 改它会波及另一个名字 → 落盘前拒, 两个名字内容都不变
_gms_fixture
ln -f "$WORK/g-sb.json" "$WORK/g-sb.hard"
_hard_sha="$(sha256sum "$WORK/g-sb.json" | cut -d" " -f1)"
migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 \
  && bad "硬链接目标却返回 0" || ok "目标是硬链接(nlink>1) → 返回非 0"
{ [[ "$(sha256sum "$WORK/g-sb.json" | cut -d" " -f1)" == "$_hard_sha" ]] \
  && [[ "$(sha256sum "$WORK/g-sb.hard" | cut -d" " -f1)" == "$_hard_sha" ]]; } \
  && ok "硬链接: 两个名字的内容都没变" || bad "硬链接目标被改了"
rm -f "$WORK/g-sb.hard"

# 正常文件: before / candidate 必须是工作目录里的独立普通文件(不是软链, nlink=1)
_gms_fixture
GMS_RESTART_FAIL=1                          # 让它在落盘后失败 → 工作目录保留下来可供检查
migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1
GMS_RESTART_FAIL=""
_wdir="$(find "$WORK/state" -maxdepth 1 -name 'iosgms.*' -type d | head -1)"
if [[ -n "$_wdir" ]]; then
  _bad_mat=()
  for _m in "$_wdir"/before-* "$_wdir"/cand-*; do
    [[ -e "$_m" ]] || continue
    [[ -L "$_m" ]] && _bad_mat+=("$(basename "$_m"):软链")
    [[ "$(stat -c '%h' "$_m")" == 1 ]] || _bad_mat+=("$(basename "$_m"):nlink>1")
  done
  [[ ${#_bad_mat[@]} -eq 0 ]] \
    && ok "before/candidate 都是独立普通文件(非软链, nlink=1)" \
    || bad "材料形态不对: ${_bad_mat[*]}"
  [[ "$(stat -c '%a' "$_wdir/cand-config.json" 2>/dev/null)" == 600 ]] \
    && ok "候选文件固定 0600" || bad "候选权限是 $(stat -c '%a' "$_wdir/cand-config.json" 2>/dev/null)"
else
  bad "没找到工作目录, 无法检查材料形态"
fi
rm -rf "$WORK/state"/iosgms.* 2>/dev/null

# ── C9. 成功提交也要保住 mode/uid/gid ────────────────────────────────────────
_gms_fixture
chmod 640 "$WORK/g-sb.json"; chmod 600 "$WORK/mihomo.yaml"; chmod 644 "$WORK/g-nf"
_own_before="$(stat -c '%u:%g' "$WORK/g-sb.json")"
run_ok "migrate_ios_gms_cleanup(成功路径)" migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf"
grep -q 'in-gms-5228' "$WORK/g-sb.json" && bad "成功路径没清掉 GMS 入站" || ok "成功路径: GMS 入站已清掉"
[[ "$(stat -c '%a' "$WORK/g-sb.json")" == 640 ]] \
  && ok "成功提交后 model 的 mode 仍是 640(不是默认 600)" \
  || bad "成功提交改了 mode: $(stat -c '%a' "$WORK/g-sb.json")"
[[ "$(stat -c '%u:%g' "$WORK/g-sb.json")" == "$_own_before" ]] \
  && ok "成功提交后 model 的 uid:gid 未变" || bad "成功提交改了属主"
[[ "$(stat -c '%a' "$WORK/g-nf")" == 644 ]] \
  && ok "成功提交后 nftables.conf 的 mode 仍是 644" || bad "nft 配置 mode 被改成 $(stat -c '%a' "$WORK/g-nf")"
# 用受控 chown/stat 桩验证"mv 之前就把旧 uid:gid 设上去了"(本机没法真切到别的 uid)
_gms_fixture
printf '%s\n' "4242:4243" > /dev/null    # 期望值由桩注入
cat > "$WORK/sbin/chown" <<'CH'
#!/usr/bin/env bash
echo "chown $*" >> "$GMS_CHOWN_CALLS"
exit 0
CH
chmod 755 "$WORK/sbin/chown"
export GMS_CHOWN_CALLS="$WORK/chown-calls"; : > "$GMS_CHOWN_CALLS"
( PATH="$WORK/sbin:$PATH"; migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf" >/dev/null 2>&1 )
if grep -qE "chown $(stat -c '%u:%g' "$WORK/g-sb.json") .*\.pdg-iosgms\." "$GMS_CHOWN_CALLS"; then
  ok "落盘前对**临时文件**执行了 chown <原 uid:gid>(mv 之后才成为生产文件)"
else
  bad "没看到对临时文件的 chown: $(tr '\n' ' ' < "$GMS_CHOWN_CALLS" | head -c 160)"
fi
rm -f "$WORK/sbin/chown"
skip "切换到另一个 uid/gid 需要 root: 已用受控 chown 桩验证「mv 前设置旧属主」这一步, 未伪造成功"

# ── C10. nftables.conf 不存在: 只清 model, 唯一预期(不再"成功或失败都算 OK") ────────
_gms_fixture
rm -f "$WORK/g-nf" "$WORK/nft-calls"
_mh_before="$(sha256sum "$WORK/mihomo.yaml" | cut -d" " -f1)"
run_ok "migrate_ios_gms_cleanup(无 nftables.conf)" migrate_ios_gms_cleanup "$WORK/g-sb.json" "$WORK/g-nf"
grep -q 'in-gms-5228' "$WORK/g-sb.json" && bad "无 nft 配置时没清 model" || ok "无 nftables.conf: model 里的 GMS 入站已清掉"
[[ ! -e "$WORK/g-nf" ]] && ok "无 nftables.conf: 没有被凭空创建" || bad "凭空创建了 nftables.conf"
[[ ! -s "$WORK/nft-calls" ]] && ok "无 nftables.conf: nft 一次都没被调用" || bad "还是调了 nft: $(cat "$WORK/nft-calls")"
_gms_render "$WORK/g-sb.json" "$WORK/expect-mh2.yaml"
cmp -s "$WORK/expect-mh2.yaml" "$WORK/mihomo.yaml" \
  && ok "无 nftables.conf: 内核配置与清理后的 model 同步" || bad "内核配置与 model 不同步"
# 注: iOS 的 GMS 入站不进 mihomo 渲染产物, 所以"渲染结果字节变了"不是可靠判据; 真正要保证的是
# **落盘的内核配置对应清理后的 model**(上一条已逐字节断言), 外加 model 自身确实被改过。
[[ "$(sha256sum "$WORK/g-sb.json" | cut -d" " -f1)" != "$_G_SB" ]] \
  && ok "无 nftables.conf: model 确实被改过(GMS 入站已移除)" || bad "model 没被改"
grep -q "restart mihomo" "$WORK/gms-calls" \
  && ok "无 nftables.conf: 仍重启内核并做稳定性验证" || bad "没重启内核: $(cat "$WORK/gms-calls" 2>/dev/null)"

# ── C2. _pdg_nft_strip_gms: iOS 渲染后剥掉 GMS(装机/切核共用)──────────────────
printf 'table inet pdg {\n  ip saddr 10.0.0.0/16 tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept\n  ip saddr 10.0.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893\n}\n' > "$WORK/nfr"
_pdg_platform(){ echo ios; }
run_ok "_pdg_nft_strip_gms(iOS)" _pdg_nft_strip_gms "$WORK/nfr"
grep -q '5228' "$WORK/nfr" && bad "iOS strip 未去净 5228-5230" || ok "_pdg_nft_strip_gms(iOS): 端口集 + REDIRECT 均去掉 5228-5230"
grep -q '8445' "$WORK/nfr" && grep -q 'redirect to :7893' "$WORK/nfr" && ok "strip 只去 GMS, 其余端口/REDIRECT 保留" || bad "strip 误伤其它端口"
printf 'x tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept\n' > "$WORK/nfa"
_pdg_platform(){ echo android; }
run_ok "_pdg_nft_strip_gms(Android)" _pdg_nft_strip_gms "$WORK/nfa"
grep -q '5228-5230' "$WORK/nfa" && ok "Android: _pdg_nft_strip_gms 空操作(保留 GMS)" || bad "Android 误删了 GMS"

# ── D. migrate_android_cleanup: 删 iOS 残留 unit/文件, 保留 CA/地点数据 ──────────
# 该函数用绝对路径(/etc/systemd/system, /opt/pdg-bot) → 沙箱难注入; 用静态断言核对关键行为。
u="$ROOT/deploy/bot/pdg.sh"
grep -q 'migrate_android_cleanup' "$u" && grep -q 'disable --now pdg-mitm' "$u" && ok "存在 Android 残留清理(停用+删 pdg-mitm unit; probe81 已是公共件不在此列)" || bad "缺 Android 清理逻辑"
grep -q 'CA/地点数据保留为休眠' "$u" && ok "Android 清理保留 CA/地点数据(不永久删)" || bad "未保留用户数据"
# ── D2. 按平台部署: 真跑一次部署, 不再用"源码里出现某一行"当证据 ──────────────
# 原先这条 grep 的是 pdg.sh 里一行具体的 case 分支。判据一旦长在源码字面上, 换个等价写法
# 就红, 而真把 iOS 组件装到 Android 上却不一定被发现 —— 证明力和脆弱度正好反着。
# shellcheck source=lib/modules.sh
source "$ROOT/lib/modules.sh"
_pi_tmp="$(mktemp -d)"
for _plat in android ios; do
  rm -rf "${_pi_tmp:?}/$_plat"; mkdir -p "$_pi_tmp/$_plat"
  if pdg_install_runtime_modules "$ROOT" "$_pi_tmp/$_plat" "$_plat" >/dev/null 2>&1; then
    ok "按平台部署($_plat): 部署函数返回 0"
  else
    bad "按平台部署($_plat): 部署函数失败"
  fi
done
_ios_only="$(comm -13 <(ls "$_pi_tmp/android" | sort) <(ls "$_pi_tmp/ios" | sort) | tr '\n' ' ')"
_leaked=""
# 6.1B: probe81.py 已从"iOS 五件套"里挪出去 —— 它现在两平台都装, 所以既要确认它
# 不在 iOS 专属清单里, 也要确认**两边都有**(否则 Android 会缺掉公共件)。
for _f in mitm_ca.py mitm_server.py mitm_wloc.py pdg-dot.mobileconfig.tmpl; do
  [[ -e "$_pi_tmp/android/$_f" ]] && _leaked="$_leaked $_f"
  [[ -e "$_pi_tmp/ios/$_f" ]] || _leaked="$_leaked 缺:$_f"
done
for _p in android ios; do
  [[ -e "$_pi_tmp/$_p/probe81.py" ]] || _leaked="$_leaked 缺公共件:$_p/probe81.py"
done
[[ -z "$_leaked" ]] \
  && ok "Android 不装 iOS 四件套, iOS 齐全, probe81 两平台都有(仅 iOS: $_ios_only)" \
  || bad "平台部署有偏差:$_leaked"
# 内容与 mode 都要对 —— 只看"文件在不在"挡不住装了个旧版或权限错的。
_bad=0
while read -r _src _name _mode; do
  [[ -n "$_src" ]] || continue
  cmp -s "$ROOT/$_src" "$_pi_tmp/ios/$_name" || { _bad=$((_bad+1)); echo "    内容不符: $_name"; }
  [[ "$(stat -c%a "$_pi_tmp/ios/$_name")" == "$_mode" ]] || { _bad=$((_bad+1)); echo "    mode 不符: $_name"; }
done < <(pdg_platform_modules ios)
[[ "$_bad" == 0 ]] && ok "部署内容逐字节等于仓库源, mode 与 manifest 一致" || bad "$_bad 处内容/mode 不符"
# 幂等: 再跑一遍不该有任何变化
_h1="$(find "$_pi_tmp/ios" -type f -exec sha256sum {} + | sed "s|$_pi_tmp||" | sort | sha256sum)"
pdg_install_runtime_modules "$ROOT" "$_pi_tmp/ios" ios >/dev/null 2>&1
_h2="$(find "$_pi_tmp/ios" -type f -exec sha256sum {} + | sed "s|$_pi_tmp||" | sort | sha256sum)"
[[ "$_h1" == "$_h2" ]] && ok "重复部署幂等(内容与 mode 均不变)" || bad "重复部署产生了变化"
# 用户持久数据不能被静态部署覆盖
printf '{"mine":1}\n' > "$_pi_tmp/ios/rulesets.json"
printf 'user.example\n' > "$_pi_tmp/ios/dot-domain"
pdg_install_runtime_modules "$ROOT" "$_pi_tmp/ios" ios >/dev/null 2>&1
{ grep -q '"mine"' "$_pi_tmp/ios/rulesets.json" && grep -q user.example "$_pi_tmp/ios/dot-domain"; } \
  && ok "用户持久数据(rulesets.json / dot-domain)不被静态部署覆盖" || bad "用户数据被覆盖了"
rm -rf "${_pi_tmp:?}"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
