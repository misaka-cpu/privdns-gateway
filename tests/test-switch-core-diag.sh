#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# issue #1 回归: `pdg switch-core` 失败时必须说清**为什么**。
#
# 用户现场只说"不能用命令切换 sing-box/mihomo, 会直接报错然后回退" —— 拿不到任何线索,
# 因为旧实现把三种完全不同的失败挤成一句"渲染/校验 mihomo 配置失败(或有出口 mihomo
# 无法转换)", 而且 python 的 stderr 被 2>/dev/null 直接丢掉。sing-box 方向同理。
# bot 的 _core_apply() 本来就会分别报出异常类型 / 转不了的出口名 / 内核真实报错,
# switch-core 却另写了一套瞎的。
#
# 沙箱化: 抽出真实 cmd_switch_core, 只把绝对路径字面量重定向到临时根, 其余打桩。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

sed -n '/^cmd_switch_core(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" > "$WORK/fn.sh"
grep -q '^cmd_switch_core(){' "$WORK/fn.sh" || { echo "抽取失败"; exit 1; }
# 绝对路径 → 沙箱(控制流与变量引用一字未改)
sed -i -e 's#/etc/#$SB/etc/#g' -e 's#/opt/pdg-bot#$SB/opt/pdg-bot#g' \
       -e 's#/usr/local/bin/#$SB/usr/local/bin/#g' "$WORK/fn.sh"

mk(){   # $1=当前内核
  SB="$WORK/root"; rm -rf "$SB"
  mkdir -p "$SB/etc/privdns-gateway" "$SB/etc/mihomo" "$SB/etc/sing-box" \
           "$SB/opt/pdg-bot" "$SB/usr/local/bin"
  printf '%s\n' "$1" > "$SB/etc/privdns-gateway/backend"
  printf '{}\n' > "$SB/etc/privdns-gateway/mitm.json"
  printf 'x\n'  > "$SB/etc/nftables.conf"
  printf 'y\n'  > "$SB/etc/mihomo/config.yaml"
  printf '{}\n' > "$SB/etc/sing-box/config.json"
  export SB
}

harness(){ cat <<'EOF'
need_root(){ :; }; _lock(){ :; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
cmd_snapshot(){ :; }
dpkg(){ echo amd64; }
pdg_write_unit(){ :; }
systemctl(){ :; }
journalctl(){ echo "(stub journal)"; }
_switchcore_nft(){ return 0; }
_core_kernel_activate(){ return "${ACTIVATE_RC:-0}"; }
_core_kernel_restore(){ :; }
_pdg_core(){ cat "$SB/etc/privdns-gateway/backend"; }
_pdg_platform(){ echo android; }
pdg_verify_sha256(){ return 0; }
cp(){ command cp "$@" 2>/dev/null || true; }
mihomo(){
  case "${1:-}" in
    -v) echo "Mihomo Meta $MIHOMO_VER";;             # 已是钉死版本, 跳过下载
    -t) [[ -n "${MIHOMO_T_FAIL:-}" ]] && { echo "$MIHOMO_T_ERR" >&2; return 1; }; return 0;;
  esac
  return 0
}
sing-box(){
  case "${1:-}" in
    version) echo "sing-box version $SINGBOX_VER";;
    check)   [[ -n "${SB_CHECK_FAIL:-}" ]] && { echo "$SB_CHECK_ERR" >&2; return 1; }; return 0;;
  esac
  return 0
}
# 渲染预检: 由 RENDER_MODE 决定 python 的行为
python3(){
  case "$*" in
    *json*mitm.json*) echo False; return 0;;        # WLOC 门控查询
    *) case "${RENDER_MODE:-ok}" in
         ok)      return 0;;
         raise)   echo "渲染 mihomo 配置失败: ValueError: 出口 xyz 缺 server 字段" >&2; return 1;;
         unknown) echo "这些出口 mihomo 无法转换(切过去会凭空丢失): hy1-jp, ssr-tw" >&2; return 1;;
       esac;;
  esac
}
EOF
}

run(){  # $1=env $2=target
  # shellcheck disable=SC2086
  env SB="$SB" $1 bash -c "set -uo pipefail
REPO_DIR='$ROOT'
$(harness)
source '$ROOT/lib/versions.sh' 2>/dev/null
source '$WORK/fn.sh'
cmd_switch_core $2" 2>&1
}

# ── 1. 有出口无法转换 → 必须列出是哪几个出口 ──
mk singbox
out=$(run "RENDER_MODE=unknown" mihomo)
{ grep -q 'hy1-jp' <<<"$out" && grep -q 'ssr-tw' <<<"$out" && grep -q '未切换' <<<"$out"; } \
  && ok "转换失败: 逐个列出无法转换的出口名(不再只说'渲染/校验失败')" || bad "1: out=$out"
[[ "$(cat "$SB/etc/privdns-gateway/backend")" == singbox ]] \
  && ok "转换失败: backend 标记已回滚" || bad "1b: backend=$(cat "$SB/etc/privdns-gateway/backend")"

# ── 2. 渲染抛异常 → 必须带出异常类型与信息 ──
mk singbox
out=$(run "RENDER_MODE=raise" mihomo)
{ grep -q 'ValueError' <<<"$out" && grep -q '缺 server 字段' <<<"$out"; } \
  && ok "渲染异常: 带出异常类型与原始信息" || bad "2: out=$out"

# ── 3. mihomo -t 不过 → 必须带出 mihomo 自己的报错 ──
mk singbox
out=$(run "RENDER_MODE=ok MIHOMO_T_FAIL=1 MIHOMO_T_ERR=rule_9_is_invalid_xyz" mihomo)
{ grep -q 'rule_9_is_invalid_xyz' <<<"$out" && grep -q 'mihomo 配置校验失败' <<<"$out"; } \
  && ok "mihomo -t 失败: 带出内核真实报错" || bad "3: out=$out"

# ── 4. sing-box check 不过 → 必须带出 sing-box 自己的报错 ──
mk mihomo
out=$(run "SB_CHECK_FAIL=1 SB_CHECK_ERR=outbound_tag_dup_zzz" singbox)
{ grep -q 'outbound_tag_dup_zzz' <<<"$out" && grep -q 'sing-box 配置校验失败' <<<"$out"; } \
  && ok "sing-box check 失败: 带出内核真实报错" || bad "4: out=$out"
[[ "$(cat "$SB/etc/privdns-gateway/backend")" == mihomo ]] \
  && ok "sing-box check 失败: backend 标记已回滚" || bad "4b"

# ── 5. 内核起不来 → 回滚并附上日志线索 ──
mk singbox
out=$(run "RENDER_MODE=ok ACTIVATE_RC=1" mihomo)
{ grep -q '已回滚到 sing-box 内核' <<<"$out" && grep -q '最近日志' <<<"$out"; } \
  && ok "内核起不来: 回滚 + 附内核日志线索" || bad "5: out=$out"

# ── 6. 一切正常 → 成功且不误报 ──
mk singbox
out=$(run "RENDER_MODE=ok" mihomo)
grep -q '✅ 已切换到 mihomo 内核' <<<"$out" && ok "正常路径: 切换成功(诊断改造未误伤)" || bad "6: out=$out"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
