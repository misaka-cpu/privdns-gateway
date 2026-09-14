#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 自启恢复: 持久自启(/etc 的 wants)与运行时自启(/run 的 wants)是**两套独立的链接**。
#
# 被测的是产品原文里的 _pdg_restore_svcstate 自启那一段(连同它调用的
# _pdg_svc_q / _pdg_now_en / _pdg_set_enable_state), 直接执行, 不读源码正文、不看注释。
#
# systemctl 桩**分别**维护两套链接, 不做"目标字符串赋值":
#   is-enabled 的答案由 en-persist/ 与 en-runtime/ 两个目录推出来 ——
#   持久在 → enabled;  只有运行时在 → enabled-runtime;  都不在 → disabled。
# 这套语义是在**真 systemd**(用户作用域一次性 unit)上实测标定过的:
#   enable            → enabled
#   已 enabled 再 enable --runtime      → 仍 **enabled**      ← 缺口在这
#   disable(不带 --runtime)             → enabled-runtime     ← 只撤持久那一层
#   enabled-runtime 上只 disable        → 仍 **enabled-runtime** ← 另一半缺口
#   disable --runtime                   → disabled
# 标定记录见 evidence 的 systemd-enable-semantics 一节。
#
# 本机若没有真 systemd, 这一支仍然能跑 —— 但它验证的是**模型**, 不冒充真实 systemd 验证。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
P=0; F=0
ok(){   printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){  printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${PDG_SH:-$HERE/../deploy/bot/pdg.sh}"
[[ -f "$SRC" ]] || { echo "[未执行] 找不到 $SRC"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-enrt.XXXXXX")" || { echo "[未执行] 建不出临时目录"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
ST="$WORK/state"

# ── 抽产品函数(整函数抽取, 不改一个字) ──────────────────────────────────────
extract(){ awk -v f="$1" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$SRC"; }
FUNCS="$WORK/funcs.sh"; : > "$FUNCS"
MISSING=()
for f in _pdg_svc_known _pdg_svc_q _pdg_now_ac _pdg_now_en \
         _pdg_set_enable_state _pdg_svcstate_units _pdg_svcstate_plan _pdg_restore_svcstate; do
  body="$(extract "$f")"
  if [[ -z "$body" ]]; then MISSING+=("$f"); else printf '%s\n' "$body" >> "$FUNCS"; fi
done
# _pdg_set_enable_state 在**修复之前的版本里不存在** —— 那不是"测试跑不了", 而是
# 被测行为不存在。补一个会当场失败的占位, 让缺口以行为的方式暴露出来, 而不是以语法错。
if printf '%s\n' "${MISSING[@]:-}" | grep -qx '_pdg_set_enable_state'; then
  note "这一版没有 _pdg_set_enable_state(自启恢复还没有拆出独立实现) —— 按缺口继续跑行为判据"
fi
for f in "${MISSING[@]:-}"; do
  [[ -n "$f" && "$f" != _pdg_set_enable_state ]] && { echo "[未执行] 抽不到产品函数 $f"; exit 1; }
done

# ── systemctl 桩: 两套链接分开建模 ──────────────────────────────────────────
sc_reset(){
  rm -rf "$ST"; mkdir -p "$ST/en-persist" "$ST/en-runtime" "$ST/ac" "$ST/special" "$ST/fail" "$ST/noop"
  : > "$ST/calls.log"
}
sc_is_enabled(){   # 由两套链接推出来
  local u="$1"
  [[ -f "$ST/special/$u" ]] && { cat "$ST/special/$u"; return 0; }
  [[ -e "$ST/en-persist/$u" ]] && { echo enabled; return 0; }
  [[ -e "$ST/en-runtime/$u" ]] && { echo enabled-runtime; return 0; }
  echo disabled
}
systemctl(){
  local verb="$1"; shift
  local runtime=0 args=() a rt=""
  for a in "$@"; do case "$a" in --runtime) runtime=1; rt=" --runtime";; *) args+=("$a");; esac; done
  case "$verb" in
    is-enabled)
      local u="${args[0]}"; printf '%s\n' "$(sc_is_enabled "$u")"
      echo "is-enabled $u" >> "$ST/calls.log"; return 0;;
    is-active)
      local u="${args[0]}"; echo "is-active $u" >> "$ST/calls.log"
      if [[ -f "$ST/ac/$u" ]]; then cat "$ST/ac/$u"; else echo inactive; fi; return 0;;
    show)
      local u="${args[-1]}"
      [[ -f "$ST/special/$u" && "$(cat "$ST/special/$u")" == not-found ]] && { echo not-found; return 0; }
      # InvocationID 之类: 给一个稳定值就够, 本支不判运行态重载
      echo loaded; return 0;;
    enable)
      local u="${args[0]}"; echo "enable$rt $u" >> "$ST/calls.log"
      [[ -f "$ST/fail/$u.enable" ]] && return 1
      [[ -f "$ST/noop/$u.enable" ]] && return 0
      [[ -f "$ST/special/$u" ]] && return 1          # static/masked 没有 [Install], enable 不了
      if [[ "$runtime" == 1 ]]; then : > "$ST/en-runtime/$u"; else : > "$ST/en-persist/$u"; fi
      return 0;;
    disable)
      local u="${args[0]}"; echo "disable$rt $u" >> "$ST/calls.log"
      [[ -f "$ST/fail/$u.disable" ]] && return 1
      [[ -f "$ST/noop/$u.disable" ]] && return 0
      # 真 systemd 语义: 不带 --runtime 只撤持久那一层, 运行时那一层原封不动。
      if [[ "$runtime" == 1 ]]; then rm -f "$ST/en-runtime/$u"; else rm -f "$ST/en-persist/$u"; fi
      return 0;;
    start|restart|stop|reset-failed)
      local u="${args[0]}"; echo "$verb $u" >> "$ST/calls.log"
      case "$verb" in
        start|restart) echo active   > "$ST/ac/$u";;
        stop)          echo inactive > "$ST/ac/$u";;
      esac; return 0;;
    *) echo "$verb ${args[*]}" >> "$ST/calls.log"; return 0;;
  esac
}
export -f systemctl sc_is_enabled 2>/dev/null || true
sleep(){ :; }        # 运行态那段的等待不在本支判据里, 不真睡

c_y(){ :; }; c_r(){ :; }; c_g(){ :; }
# shellcheck source=/dev/null
. "$FUNCS"
# 修复前的版本没有这个函数 —— 给一个**什么都不做**的桩, 让"缺口"以行为呈现。
declare -F _pdg_set_enable_state >/dev/null || _pdg_set_enable_state(){ return 127; }

UNITS=(pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer)

# ── 跑一次真实的自启+运行态恢复 ─────────────────────────────────────────────
run_restore(){   # 依赖调用方先 sc_reset 并布好 _PDG_WANT_*
  unrestored=()
  _PDG_SVC_MODE=plan; _PDG_SVC_SRC="$WORK/snap"; _PDG_SVC_WHY=""
  _pdg_restore_svcstate "$WORK/snap" >/dev/null 2>&1
}
setup_want(){    # 默认所有 unit 都是 disabled/inactive, 调用方再改个别的
  declare -gA _PDG_WANT_EN=() _PDG_WANT_AC=() _PDG_WANT_URC=() _PDG_WANT_ARC=()
  local u
  for u in "${UNITS[@]}"; do _PDG_WANT_EN["$u"]=disabled; _PDG_WANT_AC["$u"]=inactive; done
}
has_unrestored(){ printf '%s\n' "${unrestored[@]:-}" | grep -q -- "$1"; }

echo "══ 1. 健康恢复: 前像 enabled-runtime, 现状也是 enabled-runtime ══"
sc_reset; setup_want
: > "$ST/en-runtime/pdg-probe81"; echo active > "$ST/ac/pdg-probe81"
_PDG_WANT_EN[pdg-probe81]=enabled-runtime; _PDG_WANT_AC[pdg-probe81]=active
run_restore
[[ "$(sc_is_enabled pdg-probe81)" == enabled-runtime ]] \
  && ok "1a: 后置仍是 enabled-runtime" || bad "1a: 后置成了 $(sc_is_enabled pdg-probe81)"
has_unrestored 'pdg-probe81 自启' && bad "1b: 健康路径不该产生自启未恢复项" || ok "1b: 没有多余的未恢复项"
grep -q '^disable.*pdg-probe81' "$ST/calls.log" \
  && bad "1c: 没有妨碍项却撤了持久自启(多余动作)" || ok "1c: 没有妨碍项就一层都不撤"

echo
echo "══ 2. 核心反例: 前像 enabled-runtime, 前向操作把它**永久 enable** 了 ══"
sc_reset; setup_want
: > "$ST/en-persist/pdg-probe81"; echo active > "$ST/ac/pdg-probe81"     # 现状 = 持久 enabled
_PDG_WANT_EN[pdg-probe81]=enabled-runtime; _PDG_WANT_AC[pdg-probe81]=active
run_restore
NOW2="$(sc_is_enabled pdg-probe81)"
[[ "$NOW2" == enabled-runtime ]] \
  && ok "2a: 永久自启被按真实语义撤掉, 回到 enabled-runtime" \
  || bad "2a: 仍停在 $NOW2 —— 只调 enable --runtime 撤不掉持久链接"
[[ -e "$ST/en-persist/pdg-probe81" ]] \
  && bad "2b: 持久链接还在(/etc 的那一层没撤)" || ok "2b: 持久链接确实不在了"
[[ -e "$ST/en-runtime/pdg-probe81" ]] \
  && ok "2c: 运行时链接已置上" || bad "2c: 运行时链接没置上"
grep -q '^disable pdg-probe81$' "$ST/calls.log" \
  && ok "2d: 撤销动作是**真的发出去了**(calls.log 里有 disable pdg-probe81), 不是源码里写了句注释" \
  || bad "2d: 没看到撤销动作 —— 判据只认实际调用, 不认注释"

echo
echo "══ 3. 另一半缺口: 前像 disabled, 现状是 enabled-runtime ══"
sc_reset; setup_want
: > "$ST/en-runtime/pdg-bot"
_PDG_WANT_EN[pdg-bot]=disabled; _PDG_WANT_AC[pdg-bot]=inactive
run_restore
NOW3="$(sc_is_enabled pdg-bot)"
[[ "$NOW3" == disabled ]] \
  && ok "3a: 运行时自启也被撤掉, 回到 disabled" \
  || bad "3a: 仍停在 $NOW3 —— disable 不带 --runtime 撤不掉 /run 那一层"

echo
echo "══ 4. 动作失败: systemctl 返回非零 ══"
sc_reset; setup_want
: > "$ST/en-persist/pdg-probe81"; : > "$ST/fail/pdg-probe81.enable"
_PDG_WANT_EN[pdg-probe81]=enabled-runtime
run_restore
has_unrestored 'pdg-probe81 自启恢复动作失败' \
  && ok "4a: 动作失败被具名累计" || bad "4a: 动作失败没有具名累计(unrestored=${unrestored[*]:-空})"

echo
echo "══ 5. 动作返回成功但状态不符 ══"
sc_reset; setup_want
: > "$ST/en-persist/pdg-probe81"; : > "$ST/noop/pdg-probe81.enable"; : > "$ST/noop/pdg-probe81.disable"
_PDG_WANT_EN[pdg-probe81]=enabled-runtime
run_restore
has_unrestored 'pdg-probe81 自启后置状态不符' \
  && ok "5a: 动作说成功但后置不符, 照样具名累计" || bad "5a: 后置不符被放过了(unrestored=${unrestored[*]:-空})"
has_unrestored 'pdg-probe81 自启恢复动作失败' \
  && bad "5b: 动作没失败却记成动作失败(两类混算)" || ok "5b: 动作成功与后置不符**分开**记"

echo
echo "══ 6. 自启恢复不许顺带启动原本停着的服务 ══"
sc_reset; setup_want
: > "$ST/en-persist/pdg-bot"; echo inactive > "$ST/ac/pdg-bot"
_PDG_WANT_EN[pdg-bot]=enabled-runtime; _PDG_WANT_AC[pdg-bot]=inactive
run_restore
[[ "$(sc_is_enabled pdg-bot)" == enabled-runtime ]] \
  && ok "6a: 自启回到 enabled-runtime" || bad "6a: 自启是 $(sc_is_enabled pdg-bot)"
[[ "$(cat "$ST/ac/pdg-bot")" == inactive ]] \
  && ok "6b: 原本 inactive 的服务**没有**被顺带启动" || bad "6b: 它被启动了(现为 $(cat "$ST/ac/pdg-bot"))"
grep -qE '^(start|restart) pdg-bot$' "$ST/calls.log" \
  && bad "6c: calls.log 里出现了对它的 start/restart" || ok "6c: 没有对它发过 start/restart"

echo
echo "══ 7. 前像本来就是永久 enabled ══"
sc_reset; setup_want
_PDG_WANT_EN[mosdns]=enabled; _PDG_WANT_AC[mosdns]=inactive
run_restore
[[ "$(sc_is_enabled mosdns)" == enabled ]] && ok "7a: 回到永久 enabled" || bad "7a: 是 $(sc_is_enabled mosdns)"
[[ -e "$ST/en-persist/mosdns" ]] && ok "7b: 落的是**持久**链接" || bad "7b: 持久链接没落上"
[[ -e "$ST/en-runtime/mosdns" ]] && bad "7c: 顺手落了运行时链接(不该)" || ok "7c: 没有多落运行时链接"

echo
echo "══ 8. 只动本次负责恢复的 unit ══"
sc_reset; setup_want
: > "$ST/en-persist/sshd"; : > "$ST/en-persist/pdg-probe81"
_PDG_WANT_EN[pdg-probe81]=enabled-runtime
run_restore
[[ "$(sc_is_enabled sshd)" == enabled ]] \
  && ok "8a: 前像清单外的 unit(sshd)自启状态一字未动" || bad "8a: sshd 被动了(现为 $(sc_is_enabled sshd))"
grep -q ' sshd$' "$ST/calls.log" && bad "8b: calls.log 里出现了 sshd" || ok "8b: 一次都没点到它"
grep -qE '\*|\.wants' "$ST/calls.log" && bad "8c: 出现了通配或直接动 wants/ 目录" || ok "8c: 没有通配, 也没有直接动 wants/ 目录"

echo
echo "══ 9. static/masked 继续按既有安全契约: 不先改坏再报告 ══"
# 9a/9b —— 前像与现状**都是** static: 无事可做, 既不动手也不该凭空报未恢复。
sc_reset; setup_want
echo static > "$ST/special/pdg-dotwitness"
_PDG_WANT_EN[pdg-dotwitness]=static
run_restore
grep -qE '^(enable|disable)[^ ]* pdg-dotwitness' "$ST/calls.log" \
  && bad "9a: 对 static 的 unit 发了 enable/disable(先改坏再报告)" || ok "9a: 没有对它发任何 enable/disable"
has_unrestored 'pdg-dotwitness 自启' \
  && bad "9b: 现状与前像一致却报了未恢复" || ok "9b: 一致就不报未恢复"
# 9c/9d —— 前像是 static 而现状变了: 仍然不许动手, 但必须如实登记。
sc_reset; setup_want
_PDG_WANT_EN[pdg-dotwitness]=static          # 现状没有 special 文件 ⇒ disabled
run_restore
grep -qE '^(enable|disable)[^ ]* pdg-dotwitness' "$ST/calls.log" \
  && bad "9c: 恢复不了却先动了手" || ok "9c: 恢复不了就一个动作都不发"
has_unrestored 'pdg-dotwitness 自启状态 static' \
  && ok "9d: 如实登记为无法用 enable/disable 恢复" || bad "9d: 没有登记(unrestored=${unrestored[*]:-空})"

echo
echo "══ 10. 注释对照: 源码里那句话不构成任何判据 ══"
if grep -q '不提升成永久' "$SRC"; then
  note "10: 源码里确实有「不提升成永久」这句注释 —— 修复前后都在, 因此它**没有**区分力"
else
  note "10: 源码里没有那句注释"
fi
ok "10: 本支的每一条判据都来自**实际执行**(桩的两套链接 + calls.log), 一条都不读源码正文"

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
