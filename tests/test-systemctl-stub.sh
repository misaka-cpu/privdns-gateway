#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 共享 systemctl 桩的契约。
#
# 这个桩原先只认单个 `-p`、只答得出 ActiveState, 其余一律 `echo 0`。timer 判据要读
# SubState 与两个 NextElapse, 于是它们全成了 "0" —— doctor 按 fail-closed 判红, 整次
# update 回滚(e2e-update 37/4、e2e-rescue-migration-lock 20/7)。测出来的是桩的病,
# 而排查时最顺手的"修法"恰恰最坏: 把判据放宽。
#
# 所以这支盯两件事:
#   · 桩答得**全**(多个 -p、KEY=VALUE 与 --value 两种形态);
#   · 桩答得**真** —— 状态从当前 unit 状态派生, 绝不无条件回答 active/waiting/finite。
#     后者若失守, timer 死角那组测试会变成恒绿, 比答不出来更糟。
#
# 判据落在**真桩**上: 调 e2e_stub_system 生成它, 再执行它、看它的输出与状态文件,
# 不复制一份模型自测。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T_PASS=0; T_FAIL=0; T_SKIP=0
t_ok(){ echo "[OK]   $1"; T_PASS=$((T_PASS+1)); }
t_bad(){ echo "[FAIL] $1"; T_FAIL=$((T_FAIL+1)); }
skipf(){
  if [[ "${PDG_TEST_STRICT:-}" == 1 ]]; then t_bad "$1 —— 严格模式下不接受丢覆盖"
  else echo "[SKIP] $1 —— 未验收, 不是通过"; T_SKIP=$((T_SKIP+1)); fi
}
fin(){ echo "────────────────────────────────────────"
       echo "通过 $T_PASS, 失败 $T_FAIL, 跳过 $T_SKIP"; [[ "$T_FAIL" == 0 ]]; }

# 桩会往 /usr/local/bin 写、往 /etc/systemd/system 建目录 —— 只在一次性沙箱里跑。
[[ "$(id -u)" == 0 ]] || { skipf "需要 root(桩要装到 /usr/local/bin)"; fin; exit $?; }
if [[ "${PDG_E2E_ISOLATED:-}" != 1 ]]; then
  skipf "需要 PDG_E2E_ISOLATED=1(一次性容器); 不在真机上装桩"
  fin; exit $?
fi

# shellcheck source=tests/e2e-lib.sh
E2E_ROOT="$ROOT"; export E2E_ROOT
source "$ROOT/tests/e2e-lib.sh" 2>/dev/null || { t_bad "source 不了 e2e-lib.sh"; fin; exit $?; }
e2e_stub_system >/dev/null 2>&1 || true
SC=/usr/local/bin/systemctl
[[ -x "$SC" ]] || { t_bad "e2e_stub_system 没有生成 systemctl 桩"; fin; exit $?; }
t_ok "真桩已由 e2e_stub_system 生成($SC)"

D="$E2E_TMP/e2e-svc"                 # 桩的状态目录(与桩内 D= 同一份)
[[ -d "$D" ]] || mkdir -p "$D"
U=stubtest.timer
mk_unit(){ printf '[Unit]\nDescription=stub contract test\n[Timer]\nOnActiveSec=2min\n' \
             > "/etc/systemd/system/$U"; }
mk_unit
reset_state(){ rm -f "$D/$U".* 2>/dev/null; }

get(){ "$SC" show "$U" "$@"; }       # 直接执行真桩

echo
echo "── 1. 多个 -p 默认返回完整 KEY=VALUE ──"
reset_state; echo 1 > "$D/$U.ac"
OUT="$(get -p ActiveState -p SubState -p NextElapseUSecMonotonic -p NextElapseUSecRealtime)"
n="$(grep -c '=' <<<"$OUT")"
[[ "$n" == 4 ]] && t_ok "四个属性都给了 KEY=VALUE(实得 $n 行)" || t_bad "只给了 $n 行: $(tr '\n' ' ' <<<"$OUT")"
for k in ActiveState SubState NextElapseUSecMonotonic NextElapseUSecRealtime; do
  grep -q "^$k=" <<<"$OUT" || t_bad "缺 $k"
done
grep -q "^ActiveState=" <<<"$OUT" && t_ok "键名与值成对(可按键取, 不必按位)" || true

echo
echo "── 2. --value 保持旧调用方兼容 ──"
V="$(get -p ActiveState --value)"
[[ "$V" == active ]] && t_ok "--value 只给值(实得 '$V')" || t_bad "--value 实得 '$V'"
grep -q "=" <<<"$V" && t_bad "--value 不该带键名" || t_ok "--value 不带键名"

echo
echo "── 3. 输出顺序与请求顺序不同 ──"
# 真 systemd 按自己的规范顺序打印。桩有意打乱, 谁按位取值就会翻车 —— 这个坑在真机上栽过。
ORD="$(get -p SubState -p ActiveState | cut -d= -f1 | tr '\n' ' ')"
[[ "$ORD" != "SubState ActiveState " ]] \
  && t_ok "不跟随 -p 顺序(请求 SubState,ActiveState → 实得: $ORD)" \
  || t_bad "输出顺序与请求一致 —— 按位解析的错误将失去暴露条件"

echo
echo "── 4. active + waiting → 至少一个 NextElapse 有限 ──"
reset_state; echo 1 > "$D/$U.ac"
A="$(get -p ActiveState --value)"; S="$(get -p SubState --value)"
M="$(get -p NextElapseUSecMonotonic --value)"
[[ "$A" == active && "$S" == waiting ]] && t_ok "状态 active/waiting" || t_bad "实得 $A/$S"
[[ -n "$M" && "$M" != infinity ]] && t_ok "NextElapseUSecMonotonic 有限(实得 '$M')" || t_bad "实得 '$M'"

echo
echo "── 5. active + running → 有限且不误判失败 ──"
reset_state; echo 1 > "$D/$U.ac"; echo running > "$D/$U.sub"
[[ "$(get -p SubState --value)" == running ]] && t_ok "SubState=running" || t_bad "实得 $(get -p SubState --value)"
M="$(get -p NextElapseUSecMonotonic --value)"
[[ -n "$M" && "$M" != infinity ]] && t_ok "running 时仍有有限的下一次(实得 '$M')" || t_bad "实得 '$M'"
[[ "$(get -p Result --value)" == success ]] && t_ok "Result=success(没被误判成失败)" || t_bad "Result 实得 $(get -p Result --value)"

echo
echo "── 6. active + elapsed → infinity ──"
reset_state; echo 1 > "$D/$U.ac"; echo elapsed > "$D/$U.sub"
[[ "$(get -p SubState --value)" == elapsed ]] && t_ok "SubState=elapsed" || t_bad "实得 $(get -p SubState --value)"
[[ "$(get -p NextElapseUSecMonotonic --value)" == infinity ]] \
  && t_ok "elapsed → infinity(死角能被表达出来)" \
  || t_bad "elapsed 却给了有限值 —— timer 死角测试会变成恒绿"
[[ "$(get -p ActiveState --value)" == active ]] && t_ok "同时仍是 active(正是真机上那个组合)" || t_bad "ActiveState 实得 $(get -p ActiveState --value)"

echo
echo "── 7. inactive + dead → infinity ──"
reset_state; echo 0 > "$D/$U.ac"
[[ "$(get -p ActiveState --value)" == inactive ]] && t_ok "ActiveState=inactive" || t_bad "实得 $(get -p ActiveState --value)"
[[ "$(get -p SubState --value)" == dead ]] && t_ok "SubState=dead" || t_bad "实得 $(get -p SubState --value)"
[[ "$(get -p NextElapseUSecMonotonic --value)" == infinity ]] && t_ok "inactive → infinity" || t_bad "inactive 却给了有限值"

echo
echo "── 8. failed → ActiveState/SubState/Result 都准确 ──"
reset_state; echo 1 > "$D/$U.ac"; : > "$D/$U.failed"
[[ "$(get -p ActiveState --value)" == failed ]] && t_ok "ActiveState=failed" || t_bad "实得 $(get -p ActiveState --value)"
[[ "$(get -p SubState --value)" == failed ]] && t_ok "SubState=failed" || t_bad "实得 $(get -p SubState --value)"
[[ "$(get -p Result --value)" == failed ]] && t_ok "Result=failed" || t_bad "实得 $(get -p Result --value)"
[[ "$(get -p NextElapseUSecMonotonic --value)" == infinity ]] && t_ok "failed → infinity" || t_bad "failed 却给了有限值"

echo
echo "── 9. restart 后重新 active/waiting 并重新排程 ──"
reset_state; echo 0 > "$D/$U.ac"; echo elapsed > "$D/$U.sub"
BEFORE_AC="$(get -p ActiveState --value)"
"$SC" restart "$U" >/dev/null 2>&1
rm -f "$D/$U.sub"                      # restart 后 systemd 会重新武装, 子状态回到默认
AFTER_AC="$(get -p ActiveState --value)"; AFTER_S="$(get -p SubState --value)"
AFTER_M="$(get -p NextElapseUSecMonotonic --value)"
[[ "$BEFORE_AC" == inactive && "$AFTER_AC" == active ]] \
  && t_ok "restart 把状态文件真的改了($BEFORE_AC → $AFTER_AC)" || t_bad "$BEFORE_AC → $AFTER_AC"
[[ "$AFTER_S" == waiting ]] && t_ok "restart 后回到 waiting" || t_bad "实得 $AFTER_S"
[[ -n "$AFTER_M" && "$AFTER_M" != infinity ]] && t_ok "restart 后重新排出有限的下一次" || t_bad "实得 '$AFTER_M'"
[[ -f "$D/$U.ac" && "$(cat "$D/$U.ac")" == 1 ]] && t_ok "状态文件 $U.ac 落到 1(观察的是状态变化, 不是打印)" || t_bad "状态文件没变"

echo
echo "── 10. .fail 故障注入后 restart 不能伪装成功 ──"
reset_state; : > "$D/$U.fail"
"$SC" restart "$U" >/dev/null 2>&1
[[ "$(cat "$D/$U.ac" 2>/dev/null)" == 0 ]] && t_ok "注入 .fail 后 restart 仍留 inactive(原有注入没被我改坏)" \
                                            || t_bad "注入失效: ac=$(cat "$D/$U.ac" 2>/dev/null)"
[[ "$(get -p ActiveState --value)" == inactive ]] && t_ok "show 也如实报 inactive" || t_bad "show 实得 $(get -p ActiveState --value)"
rm -f "$D/$U.fail"

echo
echo "── 11. enabled/disabled 与 UnitFileState 一致 ──"
reset_state
"$SC" enable "$U" >/dev/null 2>&1
[[ "$("$SC" is-enabled "$U")" == enabled ]] && t_ok "is-enabled=enabled" || t_bad "实得 $("$SC" is-enabled "$U")"
[[ "$(get -p UnitFileState --value)" == enabled ]] && t_ok "UnitFileState 与之一致" || t_bad "实得 $(get -p UnitFileState --value)"
"$SC" disable "$U" >/dev/null 2>&1
[[ "$("$SC" is-enabled "$U")" == disabled ]] && t_ok "is-enabled=disabled" || t_bad "实得 $("$SC" is-enabled "$U")"
[[ "$(get -p UnitFileState --value)" == disabled ]] && t_ok "UnitFileState 跟着变" || t_bad "实得 $(get -p UnitFileState --value)"

echo
echo "── 12. 未知 unit / 未知 property 不许伪造健康值 ──"
GHOST=nosuch-unit-xyz.timer
[[ "$("$SC" is-active "$GHOST")" == inactive ]] && t_ok "未知 unit: is-active=inactive" || t_bad "实得 $("$SC" is-active "$GHOST")"
GM="$("$SC" show "$GHOST" -p NextElapseUSecMonotonic --value)"
[[ "$GM" == infinity ]] && t_ok "未知 unit 的 NextElapse=infinity(不编一个有限值)" || t_bad "实得 '$GM'"
GA="$("$SC" show "$GHOST" -p ActiveState --value)"
[[ "$GA" == inactive ]] && t_ok "未知 unit 的 ActiveState=inactive" || t_bad "实得 '$GA'"
UP="$(get -p NoSuchPropertyXyz --value)"
[[ "$UP" != active && "$UP" != waiting && "$UP" != enabled ]] \
  && t_ok "未知属性不返回任何'看着健康'的值(实得 '$UP')" || t_bad "未知属性实得 '$UP'"

rm -f "/etc/systemd/system/$U"; reset_state
fin
