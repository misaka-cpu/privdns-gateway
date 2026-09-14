#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 「拒绝之后不许再动手」。
#
# migrate_wloc_retire 返回非零只会让 run_all_migrations 记一个 rc=1, 它**不会**中断后面的
# migrate_android_cleanup —— 而那一支照样 disable --now pdg-mitm、删 unit、删模块。
# cmd_platform 更早: 它在总迁移之前就经 _plat_deploy_ios → _plat_purge_retired(切 iOS)
# 或 migrate_android_cleanup(切 Android)执行同类动作。
# 所以"最终返回非零"不等于"危险动作被挡住了"。这一支就盯这件事。
#
# 跑的是**产品原文**的 migrate_android_cleanup / _plat_purge_retired / 门, 一个都没打桩。
# 打桩的只有外部系统边界: systemctl。文件系统是真的(沙箱根 $PDG_RETIRE_ROOT), rm 是真的。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }
_arr(){ sed -n "/^$2=(/,/^)/p" "$1"; }

STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}"
  case "$1" in
    is-enabled) cat "$SC_DIR/$u.en" 2>/dev/null || { echo not-found; return 1; }; return 0;;
    is-active)  cat "$SC_DIR/$u.ac" 2>/dev/null || { echo inactive; return 3; }; return 0;;
    show) case "$3" in
            LoadState) [[ -e "$SC_DIR/$u.en" ]] && echo loaded || echo not-found;;
            SubState)  cat "$SC_DIR/$u.sub" 2>/dev/null || echo dead;;
            InvocationID) cat "$SC_DIR/$u.inv" 2>/dev/null || echo "";;
            *) echo "";;
          esac; return 0;;
    enable) [[ "$2" == --runtime ]] && echo enabled-runtime > "$SC_DIR/$u.en" || echo enabled > "$SC_DIR/$u.en";;
    disable) echo disabled > "$SC_DIR/$u.en"; [[ "${2:-}" == --now ]] && echo inactive > "$SC_DIR/$u.ac";;
    start) echo active > "$SC_DIR/$u.ac";;
    stop)  echo inactive > "$SC_DIR/$u.ac";;
  esac
  return 0
}'
U="pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer"

# 造一台「还开着 WLOC 的机器」: 沙箱根里有 unit、有模块、mitm.json enabled=true
mkroot(){  # $1=场景名 → 打印沙箱根
  local d="$BOX/$1"
  mkdir -p "$d/root/etc/privdns-gateway" "$d/root/etc/systemd/system" \
           "$d/root/etc/mosdns/rules" "$d/root/opt/pdg-bot" "$d/sc"
  printf 'android\n' > "$d/root/etc/privdns-gateway/platform"
  printf '{"wloc": {"enabled": true, "lat": 1, "lon": 2}}\n' > "$d/root/etc/privdns-gateway/mitm.json"
  printf 'wloc.example\n' > "$d/root/etc/mosdns/rules/mitm_hijack.txt"
  printf '[Unit]\nDescription=pdg-mitm\n' > "$d/root/etc/systemd/system/pdg-mitm.service"
  local f
  for f in mitm_ca.py mitm_server.py mitm_wloc.py iosprofile.py iosstate.py \
           pdg-dot.mobileconfig.tmpl pdg-mitm.mobileconfig.tmpl; do printf 'x\n' > "$d/root/opt/pdg-bot/$f"; done
  local u
  for u in $U; do echo enabled > "$d/sc/$u.en"; echo active > "$d/sc/$u.ac"; echo running > "$d/sc/$u.sub"; echo "INV-$u-0" > "$d/sc/$u.inv"; done
  echo "$d"
}

# 现场还剩什么(用来断言"没动手"/"动了手")
survey(){ # $1=场景目录
  local d="$1" n=0
  [[ -f "$d/root/etc/systemd/system/pdg-mitm.service" ]] && n=$((n+1))
  local f
  for f in mitm_ca.py mitm_server.py mitm_wloc.py iosprofile.py iosstate.py \
           pdg-dot.mobileconfig.tmpl pdg-mitm.mobileconfig.tmpl; do
    [[ -f "$d/root/opt/pdg-bot/$f" ]] && n=$((n+1))
  done
  grep -q '"enabled": *true' "$d/root/etc/privdns-gateway/mitm.json" 2>/dev/null && n=$((n+1))
  [[ -s "$d/root/etc/mosdns/rules/mitm_hijack.txt" ]] && n=$((n+1))
  echo "$n"      # 满分 10 = 一样没动
}
svcacts(){ local n; n="$(grep -cE "^(stop|disable|start|enable|mask) " "$1/sc.log" 2>/dev/null)" || n=0; echo "${n:-0}"; }

# 跑真实函数。$1=场景目录 $2=函数名 $3=handle(real|none) [$4=被测 pdg.sh, 默认 $PDG]
drive(){
  local d="$1" fn="$2" hmode="$3" src="${4:-$PDG}"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\"; LOCK=\"$d/lock\""
    echo "$STUB"
    _fn1 "$src" c_g; _fn1 "$src" c_y; _fn1 "$src" c_r
    echo '_pdg_platform(){ echo android; }'          # 外部事实, 非本轮被修函数
    echo "_pdg_module(){ printf '%s\\n' \"$ROOT/deploy/bot/\$1\"; }"
    _fnN "$src" _pdg_svcstate_units; _fnN "$src" _pdg_svc_known; _fnN "$src" _pdg_svc_q
    _fnN "$src" _pdg_save_svcstate; _fnN "$src" _pdg_svcstate_valid
    grep -q '^_pdg_lock_proof(){' "$src" && _fnN "$src" _pdg_lock_proof
    grep -q '^_lock_inherited(){' "$src" && _fnN "$src" _lock_inherited
    _fnN "$src" _retire_caller_gate
    grep -q '^_retire_allowed(){' "$src" && { echo '_PDG_RETIRE_OK=""'; _fnN "$src" _retire_allowed; }
    grep -q '^_retire_android_pending(){' "$src" && _fnN "$src" _retire_android_pending
    grep -q '^_retire_plat_pending(){'    "$src" && _fnN "$src" _retire_plat_pending
    _arr "$src" _PLAT_RETIRED
    _fnN "$src" migrate_android_cleanup
    _fnN "$src" _plat_purge_retired
    echo "exec 9>\"$d/lock\"; flock -n 9"
    echo "printf 'snapshot-bytes' > \"$d/snap.tar.gz\""
    if [[ "$hmode" == real ]]; then
      echo "mkdir -p \"$d/snap\"; mv -f \"$d/snap.tar.gz\" \"$d/snap/snap.tar.gz\""
      echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
      echo "export PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\""
    fi
    echo "PDG_RETIRE_ROOT=\"$d/root\" PDG_PLATFORM_FILE=\"$d/root/etc/privdns-gateway/platform\" $fn"
    echo 'echo "FN_RC=$?"'
  } > "$d/drive-$fn.sh"
  bash "$d/drive-$fn.sh" 2>&1
}

echo "══ 一. 门拒绝之后, Android 清理不得动手 ══"
d="$(mkroot A)"; o="$(drive "$d" migrate_android_cleanup none)"
n="$(survey "$d")"; a="$(svcacts "$d")"
[[ "$n" == 10 ]] && ok "A1: 十样受保护的东西一样没动(unit/7 个模块/mitm.json/劫持表)" \
  || { bad "A1: 只剩 $n/10 —— 拒绝之后仍然动了手"; echo "$o" | sed 's/^/      /' | head -6; }
[[ "$a" == 0 ]] && ok "A2: 没有任何 stop/disable/start/enable/mask" || bad "A2: 有 $a 个服务动作: $(grep -E '^(stop|disable|start|enable) ' "$d/sc.log" | head -3 | tr '\n' ';')"
grep -q 'FN_RC=1' <<<"$o" && ok "A3: 函数以非 0 返回(不把'没做'报成'做完了')" || bad "A3: 返回码是 $(grep -o 'FN_RC=.*' <<<"$o")"

echo
echo "══ 二. 门拒绝之后, 平台切换的退役清理也不得动手 ══"
d="$(mkroot B)"; o="$(drive "$d" _plat_purge_retired none)"
[[ -f "$d/root/etc/systemd/system/pdg-mitm.service" ]] && ok "B1: pdg-mitm.service 还在" || bad "B1: unit 被删了"
[[ -f "$d/root/opt/pdg-bot/mitm_server.py" && -f "$d/root/opt/pdg-bot/mitm_wloc.py" ]] && ok "B2: MITM 宿主模块还在" || bad "B2: 模块被删了"
[[ "$(svcacts "$d")" == 0 ]] && ok "B3: 没有任何服务动作" || bad "B3: 有 $(svcacts "$d") 个服务动作"
grep -q 'FN_RC=1' <<<"$o" && ok "B4: 以非 0 返回" || bad "B4: 返回码是 $(grep -o 'FN_RC=.*' <<<"$o")"

echo
echo "══ 三. 有能力的调用方照常干活(门不是一律拒绝) ══"
d="$(mkroot C)"; o="$(drive "$d" migrate_android_cleanup real)"
n="$(survey "$d")"
[[ "$n" == 0 ]] && ok "C1: 十样全部清理到位(有前像 ⇒ 放行)" || { bad "C1: 还剩 $n/10 没清"; echo "$o" | sed 's/^/      /' | head -6; }
grep -q 'disable --now pdg-mitm' "$d/sc.log" && ok "C2: 真的执行了 disable --now pdg-mitm" || bad "C2: 没执行"
grep -q 'FN_RC=0' <<<"$o" && ok "C3: 返回 0" || bad "C3: 返回码是 $(grep -o 'FN_RC=.*' <<<"$o")"

echo
echo "══ 四. 已经清干净的机器: 幂等复跑不要求能力证明 ══"
d="$BOX/D"; mkdir -p "$d/root/etc/privdns-gateway" "$d/root/opt/pdg-bot" "$d/sc"
printf 'android\n' > "$d/root/etc/privdns-gateway/platform"
for u in $U; do echo enabled > "$d/sc/$u.en"; echo active > "$d/sc/$u.ac"; done
o="$(drive "$d" migrate_android_cleanup none)"
grep -q 'FN_RC=0' <<<"$o" && ok "D1: 没有待办 ⇒ 不要求句柄, 直接返回 0(新装/已退役/幂等复跑照常)" \
  || { bad "D1: 干净机器也被拒了"; echo "$o" | sed 's/^/      /' | head -5; }
[[ "$(svcacts "$d")" == 0 ]] && ok "D2: 且没有任何服务动作" || bad "D2"
d="$BOX/D2"; mkdir -p "$d/root/etc/systemd/system" "$d/root/opt/pdg-bot" "$d/sc"
o="$(drive "$d" _plat_purge_retired none)"
grep -q 'FN_RC=0' <<<"$o" && ok "D3: 平台清理在没有残留时同样返回 0" || bad "D3: $(grep -o 'FN_RC=.*' <<<"$o")"

echo
echo "══ 五. 撤销对照: 只撤掉拦截那一行, 真实函数就会动手 ══"
# 撤法: 把 _retire_allowed 换成恒真 —— 这就是"把门撤掉", 调用点一行不动(拆调用点会让
# `if …; then` 空出来变成语法错, 那样函数根本跑不起来, 对照就成了假的)。
NOBAR="$BOX/pdg-nobarrier.sh"
awk '/^_retire_allowed\(\)\{/{print "_retire_allowed(){ return 0; }"; skip=1; next}
     skip && /^\}/{skip=0; next}
     !skip{print}' "$PDG" > "$NOBAR"
if cmp -s "$PDG" "$NOBAR" || ! grep -q '^_retire_allowed(){ return 0; }$' "$NOBAR"; then
  bad "E1: 没造出反向副本(拦截锚点不存在或改名了) —— 本格记无效"
elif ! bash -n "$NOBAR" 2>/dev/null; then
  bad "E1: 反向副本语法不通 —— 本格记无效(不能拿跑不起来的副本冒充对照)"
else
  ok "E1: 反向副本就位(只把 _retire_allowed 换成恒真, 调用点与其余代码一字不动)"
  d="$(mkroot E)"; o="$(drive "$d" migrate_android_cleanup none "$NOBAR")"
  n="$(survey "$d")"
  [[ "$n" == 0 ]] && ok "E2: 撤掉拦截后, **真实的** migrate_android_cleanup 把十样全清了" \
    || bad "E2: 反向对照没触到副作用路径(还剩 $n/10) —— 本格记无效"
  grep -q 'disable --now pdg-mitm' "$d/sc.log" && ok "E3: 且真的执行了 disable --now pdg-mitm" || bad "E3: 反向对照无效"
  d="$(mkroot E2)"; drive "$d" _plat_purge_retired none "$NOBAR" >/dev/null
  [[ ! -f "$d/root/etc/systemd/system/pdg-mitm.service" ]] && ok "E4: 平台清理那一路同样会真的删掉 unit" || bad "E4: 反向对照无效"
  # 无关注释对照: 只删一行注释, 不该有任何新增失败
  NOCOM="$BOX/pdg-nocomment.sh"
  grep -vn '^# 清掉已退役的 MITM 残留(服务 + 文件)。两平台通用, 幂等。$' "$PDG" | sed 's/^[0-9]*://' > "$NOCOM"
  if cmp -s "$PDG" "$NOCOM"; then bad "E5: 无关注释对照没造出来"; else
    d="$(mkroot E3)"; o="$(drive "$d" migrate_android_cleanup none "$NOCOM")"
    [[ "$(survey "$d")" == 10 && "$(svcacts "$d")" == 0 ]] \
      && ok "E5: 无关注释对照零新增失败(判据盯的是行为, 不是文本)" || bad "E5: 注释对照也红了, 判据不干净"
  fi
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
