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

# ── 桩污染的前像: 必须在 source/装桩**之前**取 ────────────────────────────────
# 隔离模式(PDG_E2E_ISOLATED=1)没有 user namespace, e2e-lib 的桩直接落在**真实**的
# /usr/local/bin。而 /usr/local/bin 在 PATH 里排在 /usr/sbin 前面 —— 桩不清掉, 同一个
# CI job 里后面每一步按 PATH 解析 nft/systemctl 的测试都会拿到它。
# 实测过一次: 本脚本跑完后 `command -v nft` 从 /usr/sbin/nft(ELF, 26856 字节)翻到
# /usr/local/bin/nft(53 字节 shell, 对任何输入 exit 0), 于是 test-uninstall-firewall.py
# 的 `nft -c` 全部返回 0 —— 好候选"通过"是假绿, 坏候选没被拦才把这件事暴露出来。
STUB_PATHS=(/usr/local/bin/systemctl /usr/local/bin/nft)
declare -A PRE_KIND PRE_SHA PRE_MODE MADE_SHA
PRE_BAK="$(mktemp -d)" || { t_bad "建不了 before-image 目录"; fin; exit $?; }
_sha(){ sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
for _p in "${STUB_PATHS[@]}"; do
  if [[ -e "$_p" ]]; then
    # 运行前就有同名文件: 逐字节留底, 收尾时原样放回去 —— 绝不无条件删别人的东西
    PRE_KIND[$_p]=exist
    PRE_SHA[$_p]="$(_sha "$_p")"
    PRE_MODE[$_p]="$(stat -c%a "$_p" 2>/dev/null)"
    cp -a "$_p" "$PRE_BAK/$(basename "$_p")" \
      || { t_bad "留不了 $_p 的 before-image, 拒绝覆盖(fail-closed)"; fin; exit $?; }
  else
    PRE_KIND[$_p]=absent
  fi
done
# 真命令的运行前解析结果。不写死 /usr/sbin/nft: 不同发行版路径不同, 判据要跟它比。
REAL_NFT_CMD="$(command -v nft 2>/dev/null || true)"
REAL_NFT_RP="$(readlink -f "$REAL_NFT_CMD" 2>/dev/null || true)"
REAL_NFT_SHA="$([[ -n "$REAL_NFT_RP" ]] && _sha "$REAL_NFT_RP" || true)"
REAL_NFT_KIND="$([[ -n "$REAL_NFT_RP" ]] && file -b "$REAL_NFT_RP" 2>/dev/null | cut -c1-24 || true)"
REAL_SCTL_CMD="$(command -v systemctl 2>/dev/null || true)"
REAL_SCTL_RP="$(readlink -f "$REAL_SCTL_CMD" 2>/dev/null || true)"
REAL_SCTL_SHA="$([[ -n "$REAL_SCTL_RP" ]] && _sha "$REAL_SCTL_RP" || true)"
PRE_SVC_DIR="$([[ -d /tmp/e2e-svc ]] && echo exist || echo absent)"
PRE_CALLS="$([[ -e /tmp/e2e-calls.log ]] && echo exist || echo absent)"

CLEAN_FAIL=0
stub_cleanup(){       # 幂等: 重复调用必须仍然成功
  local _p _cur
  for _p in "${STUB_PATHS[@]}"; do
    case "${PRE_KIND[$_p]:-absent}" in
      absent)
        [[ -e "$_p" ]] || continue                       # 已经清过了
        _cur="$(_sha "$_p")"
        if [[ -n "${MADE_SHA[$_p]:-}" && "$_cur" == "${MADE_SHA[$_p]}" ]]; then
          rm -f "$_p" || { echo "[!] 删不掉 $_p"; CLEAN_FAIL=1; }
        else
          # 内容不是我们造的那份 = 运行期间被第三方换过, 不属于本测试, 不许删
          echo "[!] $_p 的内容已被第三方替换(现 ${_cur:0:16}…, 本轮桩 ${MADE_SHA[$_p]:0:16}…), 不删除"
          CLEAN_FAIL=1
        fi;;
      exist)
        cp -a "$PRE_BAK/$(basename "$_p")" "$_p" || { echo "[!] 还原不了 $_p"; CLEAN_FAIL=1; continue; }
        [[ -n "${PRE_MODE[$_p]:-}" ]] && { chmod "${PRE_MODE[$_p]}" "$_p" || CLEAN_FAIL=1; }
        [[ "$(_sha "$_p")" == "${PRE_SHA[$_p]}" ]] || { echo "[!] $_p 还原后与 before-image 不符"; CLEAN_FAIL=1; };;
    esac
  done
  [[ "$PRE_SVC_DIR" == absent ]] && [[ -d /tmp/e2e-svc ]] && { rm -rf /tmp/e2e-svc || { echo "[!] 删不掉 /tmp/e2e-svc"; CLEAN_FAIL=1; }; }
  [[ "$PRE_CALLS"   == absent ]] && [[ -e /tmp/e2e-calls.log ]] && { rm -f /tmp/e2e-calls.log || { echo "[!] 删不掉 /tmp/e2e-calls.log"; CLEAN_FAIL=1; }; }
  rm -rf "$PRE_BAK" 2>/dev/null
  return "$CLEAN_FAIL"
}

# shellcheck source=tests/e2e-lib.sh
E2E_ROOT="$ROOT"; export E2E_ROOT
source "$ROOT/tests/e2e-lib.sh" 2>/dev/null || { t_bad "source 不了 e2e-lib.sh"; fin; exit $?; }
# 用 e2e_add_exit_hook 而不是 trap ... EXIT: e2e-lib 已经把 EXIT 挂给 e2e_run_exit_hooks
# (事务探针靠它收尾), 再设一个裸 trap 会把它顶掉。异常退出走这条路。
e2e_add_exit_hook stub_cleanup || { t_bad "注册不了退出清理"; fin; exit $?; }
e2e_stub_system >/dev/null 2>&1 || true
# 记下我们刚造出来的那份桩的哈希: 收尾只删"还是这份内容"的文件
for _p in "${STUB_PATHS[@]}"; do
  [[ "${PRE_KIND[$_p]}" == absent && -e "$_p" ]] && MADE_SHA[$_p]="$(_sha "$_p")"
done
SC=/usr/local/bin/systemctl
[[ -x "$SC" ]] || { t_bad "e2e_stub_system 没有生成 systemctl 桩"; fin; exit $?; }
t_ok "真桩已由 e2e_stub_system 生成($SC)"

D=/tmp/e2e-svc                       # 桩的状态目录(与桩内 D= 同一份)
# 候选(v1.8.1 线)的桩用的就是 /tmp/e2e-svc; 6.1C 那边改成了 $E2E_TMP 下,
# 但那是全仓临时物改造的一部分, 热修不该把它带进来。
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

# ── 收尾: 显式清一次, 并在脚本内部把"确实恢复了"验掉 ──────────────────────────
# EXIT hook 仍然留着管异常路径; 这里显式调用是为了让下面的正向断言能在本脚本里完成 ——
# 桩没清干净这件事必须在这里被抓住, 而不是留给几十步之后的另一支测试。
echo
echo "── 收尾: 桩清理与命令解析恢复 ──"
stub_cleanup && t_ok "清理返回 0" || t_bad "清理失败(见上面的 [!] 行)"
NOW_NFT_CMD="$(command -v nft 2>/dev/null || true)"
NOW_NFT_RP="$(readlink -f "$NOW_NFT_CMD" 2>/dev/null || true)"
[[ "$NOW_NFT_CMD" == "$REAL_NFT_CMD" && "$NOW_NFT_RP" == "$REAL_NFT_RP" ]] \
  && t_ok "nft 解析回到运行前($NOW_NFT_CMD)" || t_bad "nft 现解析到 '$NOW_NFT_CMD'(运行前 '$REAL_NFT_CMD')"
[[ -n "$NOW_NFT_RP" && "$(_sha "$NOW_NFT_RP")" == "$REAL_NFT_SHA" ]] \
  && t_ok "nft 内容与运行前逐字节一致" || t_bad "nft 内容与运行前不符"
[[ "$(file -b "$NOW_NFT_RP" 2>/dev/null | cut -c1-24)" == "$REAL_NFT_KIND" ]] \
  && t_ok "nft 类型与运行前一致($REAL_NFT_KIND)" || t_bad "nft 类型变了"
NOW_SCTL_CMD="$(command -v systemctl 2>/dev/null || true)"
NOW_SCTL_RP="$(readlink -f "$NOW_SCTL_CMD" 2>/dev/null || true)"
[[ "$NOW_SCTL_CMD" == "$REAL_SCTL_CMD" && "$(_sha "$NOW_SCTL_RP")" == "$REAL_SCTL_SHA" ]] \
  && t_ok "systemctl 解析与内容都回到运行前($NOW_SCTL_CMD)" || t_bad "systemctl 没恢复(现 '$NOW_SCTL_CMD')"
_left=0
for _p in "${STUB_PATHS[@]}"; do [[ "${PRE_KIND[$_p]}" == absent && -e "$_p" ]] && _left=$((_left+1)); done
[[ "$_left" == 0 ]] && t_ok "本轮创建的桩全部消失" || t_bad "还剩 $_left 个本轮创建的桩"
[[ "$PRE_SVC_DIR" == exist || ! -d /tmp/e2e-svc ]] && t_ok "/tmp/e2e-svc 无本轮残留" || t_bad "/tmp/e2e-svc 还在"
[[ "$PRE_CALLS" == exist || ! -e /tmp/e2e-calls.log ]] && t_ok "/tmp/e2e-calls.log 无本轮残留" || t_bad "/tmp/e2e-calls.log 还在"
stub_cleanup && t_ok "再清一次仍返回 0(幂等)" || t_bad "重复清理失败 —— 不幂等"

fin
