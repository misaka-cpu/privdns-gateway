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
  # before-image 不是闭集里的值 = 我们根本不知道运行前是什么样 —— 这时既不能删(可能删掉
  # 本来就有的东西)也不能装作清干净了。**返回非零**, 别再谎报成功。
  local _v
  for _v in "$PRE_SVC_DIR" "$PRE_CALLS"; do
    case "$_v" in
      absent|exist) ;;
      *) echo "[!] before-image 取值非法(${_v:-空}) —— 无法判断该不该清理"; CLEAN_FAIL=1;;
    esac
  done
  [[ "$PRE_SVC_DIR" == absent ]] && [[ -d "$E2E_TMP/e2e-svc" ]] && { rm -rf "$E2E_TMP/e2e-svc" || { echo "[!] 删不掉 $E2E_TMP/e2e-svc"; CLEAN_FAIL=1; }; }
  [[ "$PRE_CALLS"   == absent ]] && [[ -e "$E2E_TMP/e2e-calls.log" ]] && { rm -f "$E2E_TMP/e2e-calls.log" || { echo "[!] 删不掉 $E2E_TMP/e2e-calls.log"; CLEAN_FAIL=1; }; }
  rm -rf "$PRE_BAK" 2>/dev/null
  return "$CLEAN_FAIL"
}

# shellcheck source=tests/e2e-lib.sh
E2E_ROOT="$ROOT"; export E2E_ROOT
source "$ROOT/tests/e2e-lib.sh" 2>/dev/null || { t_bad "source 不了 e2e-lib.sh"; fin; exit $?; }

# 这两条 before-image **必须**在 source 之后取: $E2E_TMP 由 e2e-lib 初始化, 之前它是未定义的,
# 而本脚本开头是 `set -u` —— 于是 `$( [[ -d "$E2E_TMP/…" ]] … )` 里的子 shell 当场死掉,
# 命令替换返回**空串**。空串既不是 absent 也不是 exist, 结果是:
#   · stub_cleanup 里 `[[ "$PRE_SVC_DIR" == absent ]]` 恒假 → 真正的 rm 从不执行;
#   · 收尾断言两边都不成立 → 必然判红;
#   · 而 stub_cleanup 仍返回 0, 谎报"清理成功"。
# 这个洞是合并 10f32911 时把写死的 /tmp 改成 $E2E_TMP 带进来的(main 上是字面路径, 不依赖它),
# 合并后一直没跑过 CI, 所以直到最后才暴露。
# 也**不给 $E2E_TMP 兜默认值**: 那会让 before-image 指向和实际清理不同的路径 —— 换一种假绿。
PRE_SVC_DIR="$([[ -d "$E2E_TMP/e2e-svc" ]] && echo exist || echo absent)"
PRE_CALLS="$([[ -e "$E2E_TMP/e2e-calls.log" ]] && echo exist || echo absent)"
# 进入测试之前先把这两个值钉死在闭集里 —— 它们只要不是 absent/exist, 后面每一条与清理
# 有关的判据都会静默失效, 而不是报错。
for _v in PRE_SVC_DIR PRE_CALLS; do
  case "${!_v}" in
    absent|exist) ;;
    *) t_bad "$_v 取值非法(${!_v:-空}) —— before-image 没取到, 清理判据会静默失效"; fin; exit $?;;
  esac
done
t_ok "before-image 已在 \$E2E_TMP 就绪后采集(e2e-svc=$PRE_SVC_DIR calls=$PRE_CALLS)"
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

D="$E2E_TMP/e2e-svc"                 # 桩的状态目录(与桩内 D= 同一份)
# 合并后统一用 6.1C 的 $E2E_TMP 约定 —— 桩自己也写在 $E2E_TMP 下(见 e2e-lib.sh 的
# e2e_stub_system), 写死 /tmp 会让并发跑的两个脚本共用同一份状态。
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

echo
echo "── 13. --quiet 不许改变判定结果 ──"
# 真 systemd 的 `is-active --quiet` 只是**不打印**, 退出码与不带它时完全一致。桩原来只剥
# `--now`, 于是 `--quiet` 被当成 unit 名 —— 一个叫 "--quiet" 的 unit 当然不存在, 所有
# `is-active --quiet <unit>` 的调用方在沙箱里统统得到 inactive/rc=3。这不是被测代码的
# 毛病, 是假 systemd 说了假话; 而它答的恰恰是"服务起来了没有"这种承重判据。
# pdg.sh 里有 9 处这么调(去广告的受管块迁移与 apply、pdg-lan 的若干处), 都被它答反。
reset_state
mk_unit
"$SC" restart "$U" >/dev/null 2>&1
_plain="$("$SC" is-active "$U" 2>/dev/null)"; _prc=$?
"$SC" is-active --quiet "$U" >/dev/null 2>&1; _qrc=$?
[[ "$_plain" == active && "$_prc" == 0 ]]   && t_ok "前提: 不带 --quiet 时这个 unit 确实是 active" || t_bad "前提不成立: '$_plain' rc=$_prc"
[[ "$_qrc" == "$_prc" ]]   && t_ok "active 时 --quiet 的退出码与不带它一致(rc=$_qrc)" || t_bad "--quiet 实得 rc=$_qrc, 应为 $_prc"
[[ -z "$("$SC" is-active --quiet "$U" 2>/dev/null)" ]]   && t_ok "--quiet 不打印任何东西(与真 systemd 一致)" || t_bad "--quiet 仍打印: '$("$SC" is-active --quiet "$U" 2>/dev/null)'"
# 反向: 停掉之后 --quiet 也必须跟着变, 别是"永远说 active"那种假修
"$SC" stop "$U" >/dev/null 2>&1
"$SC" is-active --quiet "$U" >/dev/null 2>&1; _qrc2=$?
[[ "$_qrc2" != 0 ]]   && t_ok "停掉后 --quiet 退出码非 0(不是恒真)" || t_bad "停掉后 --quiet 仍返回 0"
# is-enabled 同理
"$SC" enable "$U" >/dev/null 2>&1
"$SC" is-enabled --quiet "$U" >/dev/null 2>&1; _erc=$?
[[ "$_erc" == 0 ]] && t_ok "is-enabled --quiet 也认这个选项" || t_bad "is-enabled --quiet 实得 rc=$_erc"
rm -f "/etc/systemd/system/$U"; reset_state

# ── 收尾: 显式清一次, 并在脚本内部把"确实恢复了"验掉 ──────────────────────────
# EXIT hook 仍然留着管异常路径; 这里显式调用是为了让下面的正向断言能在本脚本里完成 ——
# 桩没清干净这件事必须在这里被抓住, 而不是留给几十步之后的另一支测试。
echo
echo
echo "── 14. 运行周期身份(InvocationID): 只有进入新周期才换 ──"
# 产品的回滚判据靠"重启后 InvocationID 变过"确认恢复出来的配置被重新读进去了。
# 桩以前既不生成也不更换 ID(实测: restart 之后仍为空; 预填固定值后 restart 也不变),
# 于是那条判据在沙箱里只能永远登记"无法确认"。这一节钉住补齐后的语义。
# unit 名**不带** .service 后缀: 桩在"没有状态记录"时按 /etc/systemd/system/<u>.service
# 判断它是否装着(14g 的初始前像正是走这条回退), 带后缀会让它去找 <u>.service.service。
SVC=stubinv
mk_svc(){ printf '[Unit]\nDescription=inv test\n[Service]\nExecStart=/bin/true\n' > "/etc/systemd/system/$SVC.service"; }
mk_svc; rm -f "$D/$SVC".* "$D/.invseq" 2>/dev/null
inv(){ "$SC" show -p InvocationID --value "$SVC"; }
# 14a 起不来的 unit: 没有健康实例 ⇒ 没有 ID(不许伪造)
: > "$D/$SVC.fail"; "$SC" start "$SVC" >/dev/null 2>&1
{ [[ -z "$(inv)" ]] && [[ "$("$SC" is-active "$SVC" 2>/dev/null)" == inactive ]]; } \
  && t_ok "14a: 起不来 ⇒ inactive 且**没有** ID(失败启动不伪造健康实例)" \
  || t_bad "14a: 起不来却给了 ID='$(inv)' / 状态='$("$SC" is-active "$SVC" 2>/dev/null)'"
rm -f "$D/$SVC.fail"
# 14b 首次 start: 进入新周期 ⇒ 生成 ID
"$SC" start "$SVC" >/dev/null 2>&1; I1="$(inv)"
[[ -n "$I1" ]] && t_ok "14b: 首次 start ⇒ 生成运行周期身份($I1)" || t_bad "14b: start 之后仍没有 ID"
# 14c 只读查询不改 ID(连查三次)
I2="$(inv)"; "$SC" is-active "$SVC" >/dev/null 2>&1; "$SC" show -p ActiveState --value "$SVC" >/dev/null 2>&1; I3="$(inv)"
{ [[ "$I1" == "$I2" ]] && [[ "$I2" == "$I3" ]]; } \
  && t_ok "14c: 只读查询**不改变** ID(三次读都是 $I1)" || t_bad "14c: 读一次就变了($I1 / $I2 / $I3)"
# 14d 对**已在跑**的 unit 再 start: 空转, 不冒充 restart
"$SC" start "$SVC" >/dev/null 2>&1; I4="$(inv)"
[[ "$I4" == "$I1" ]] && t_ok "14d: 已在跑时 start 是空转 ⇒ ID 不变(不冒充 restart)" \
                     || t_bad "14d: start 换了 ID($I1 → $I4) —— 把空转当成了重启"
# 14d-2 对**已在跑**的 unit 用 enable --now: 同样是空转 —— 真 systemd 只建链接, 不重起
# (冻结版 aea4929e 在这条路上会取新号: enable --now 自己写了一份启动逻辑, 不看"本来在不在跑"。)
"$SC" enable --now "$SVC" >/dev/null 2>&1; I4B="$(inv)"
{ [[ "$I4B" == "$I1" ]] && [[ "$("$SC" is-active "$SVC" 2>/dev/null)" == active ]]; } \
  && t_ok "14d-2: 已在跑时 enable --now 是空转 ⇒ ID 不变(仍是 $I1)" \
  || t_bad "14d-2: enable --now 换了 ID($I1 → $I4B) 或没保持 active($("$SC" is-active "$SVC" 2>/dev/null))"
# 14e restart: 一定进新周期 ⇒ ID 必须变
"$SC" restart "$SVC" >/dev/null 2>&1; I5="$(inv)"
{ [[ -n "$I5" ]] && [[ "$I5" != "$I1" ]]; } \
  && t_ok "14e: restart ⇒ 进入新周期, ID 变了($I1 → $I5)" || t_bad "14e: restart 后 ID 仍是 '$I5'"
# 14f stop: 实例没了 ⇒ ID 也没了
"$SC" stop "$SVC" >/dev/null 2>&1
[[ -z "$(inv)" ]] && t_ok "14f: stop 之后没有实例 ⇒ 没有 ID" || t_bad "14f: stop 后仍有 ID='$(inv)'"
# 14g 初始前像自洽: 从没记录过但 unit 文件在 ⇒ is-active 当它在跑, 那就该有 ID; 补一次之后恒定
rm -f "$D/$SVC".* 2>/dev/null
J1="$(inv)"; J2="$(inv)"
{ [[ "$("$SC" is-active "$SVC" 2>/dev/null)" == active ]] && [[ -n "$J1" ]] && [[ "$J1" == "$J2" ]]; } \
  && t_ok "14g: 初始运行前像自洽(当它在跑就有 ID=$J1, 且**再读不变**)" \
  || t_bad "14g: 初始前像不自洽(active=$("$SC" is-active "$SVC" 2>/dev/null) J1='$J1' J2='$J2')"
# 14h 两种失败覆盖仍在: 读不到 ID / 重启后 ID 未变 —— 用**不存在的 unit** 与 .fail 各造一次
[[ -z "$("$SC" show -p InvocationID --value no-such-unit.service)" ]] \
  && t_ok "14h-1: 读不到 ID 这种失败仍可复现(未知 unit ⇒ 空)" || t_bad "14h-1: 未知 unit 竟有 ID"
# 14h-2 **改正**上一轮的记法: 起不来的 unit 在 restart 前后都**没有** ID —— 两边都是空串。
# 空等于空证明不了"非空的 ID 没换过", 它属于 14h-1 那一类(读不到 ID), 不是第二种失败。
# 真正的"前后都非空且相等"健康桩造不出来(restart 一定换号), 只能注入 —— 见 14j-2。
rm -f "$D/$SVC".* 2>/dev/null; : > "$D/$SVC.fail"
K1="$(inv)"; "$SC" restart "$SVC" >/dev/null 2>&1; K2="$(inv)"
{ [[ -z "$K1" ]] && [[ -z "$K2" ]] && [[ "$("$SC" is-active "$SVC" 2>/dev/null)" == inactive ]]; } \
  && t_ok "14h-2: 起不来的 unit 自始至终没有 ID(两侧皆空 ⇒ 仍属'读不到 ID'一类)" \
  || t_bad "14h-2: 起不来的 unit 给出了 ID('$K1' → '$K2') 或没停在 inactive($("$SC" is-active "$SVC" 2>/dev/null))"
# ── 14j 两种失败必须**分开**: 产品的恢复判据认出来的是哪一种 ─────────────────
# pdg.sh 的 _pdg_restore_svcstate ② 对"前像是 active"的 unit 有两条不同的失败登记:
#     inv1 为空            → "无法确认是否重新加载了恢复出来的配置(读不到 InvocationID)"
#     inv0/inv1 都非空且相等 → "仍是回滚前那个进程, 恢复出来的配置没有被重新加载"
# 前一种桩自己就造得出(未知 unit); 后一种**健康的桩造不出来** —— 它的 restart 一定换号,
# 那正是它该有的样子。所以后一种只能注入: 在桩前面放一个只改 `show -p InvocationID`
# 答案的外壳, 其余一律原样转给真桩。注入是显式的、只经这一份 PATH 生效, 健康桩本身
# 绝不恒返固定 ID(否则 14b/14e 立刻变成恒绿)。
#
# 判据落在**产品真函数**上: 从 pdg.sh 抽出来执行, 不复制一份"应该长这样"的模型。
INVW="$(mktemp -d)"
_x(){   # $1=函数名 → 抽出整个定义(单行函数只抽那一行, 不会顺带吞掉后面的函数)
  awk -v f="$1(){" 'index($0,f)==1{
        print; if($0 ~ /\}[ \t]*$/) exit
        while((getline l)>0){ print l; if(l=="}") exit }
        exit }' "$ROOT/deploy/bot/pdg.sh"
}
_xok=1
: > "$INVW/prod.sh"
for _f in _pdg_svcstate_units _pdg_svc_known _pdg_svc_q _pdg_now_en _pdg_now_ac \
          _pdg_svcstate_valid _pdg_svcstate_plan _pdg_save_svcstate \
          _pdg_set_enable_state _pdg_restore_svcstate; do
  _x "$_f" >> "$INVW/prod.sh"
  grep -q "^${_f}(){" "$INVW/prod.sh" || { t_bad "14j: 抽不到产品函数 $_f(改名了?) —— 这一组判据无效"; _xok=0; break; }
done
[[ "$_xok" == 1 ]] && { bash -n "$INVW/prod.sh" 2>/dev/null || { t_bad "14j: 抽出来的产品函数拼不成合法脚本 —— 执行无效"; _xok=0; }; }

# 故障注入器: 只回答 InvocationID(值由 PDG_FI_INV 给), 其余原样转给真桩。
mkdir -p "$INVW/fi"
cat > "$INVW/fi/systemctl" <<'FIEOF'
#!/bin/sh
# ⚠ 故障注入 —— 只在 test-systemctl-stub.sh 的 14j 里、只经它自己的 PATH 生效。
# 把 `show -p InvocationID` 的答案换掉(PDG_FI_INV 为空就答空), 其余一律转给真桩。
for a in "$@"; do
  if [ "$a" = InvocationID ]; then
    [ -n "${PDG_FI_INV:-}" ] && echo "$PDG_FI_INV"
    exit 0
  fi
done
exec /usr/local/bin/systemctl "$@"
FIEOF
chmod 755 "$INVW/fi/systemctl"

cat > "$INVW/harn.sh" <<'HARNEOF'
set -uo pipefail
MODE="$1"; W="$2"
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
declare -A _PDG_WANT_EN _PDG_WANT_AC _PDG_WANT_URC _PDG_WANT_ARC
_PDG_SVC_SRC=""; _PDG_SVC_MODE=blind; _PDG_SVC_WHY=""; _PDG_SVCSTATE_WHY=""
unrestored=()
. "$W/prod.sh"
# 仪器校准: 产品函数调的是**裸** systemctl, 必须解析到桩。万一解析到真 systemctl,
# 这里发出去的 restart 会打在真机的服务上 —— 所以解析不对就立刻停, 不往下跑。
PATH="/usr/local/bin:$PATH"; export PATH
[[ "$(command -v systemctl)" == /usr/local/bin/systemctl ]] \
  || { echo "HARN=NOT-STUB:$(command -v systemctl)"; exit 7; }
SNAP="$W/snap-$MODE"; mkdir -p "$SNAP"
echo payload > "$SNAP/payload"
tar -czf "$SNAP/snap.tar.gz" -C "$SNAP" payload 2>/dev/null || { echo "HARN=NO-TAR"; exit 9; }
# 前像用**真桩**拍(注入还没上场): 记下来的就是"回滚前它确实在跑"。
_pdg_save_svcstate "$SNAP" >/dev/null 2>&1 || { echo "HARN=SAVE-FAILED"; exit 8; }
grep -q "^unit	mosdns	enabled	0	active	0" "$SNAP/svcstate.tsv" || echo "HARN=PRE-NOT-ACTIVE"
if [[ "$MODE" != healthy ]]; then
  PATH="$W/fi:$PATH"; export PATH
  [[ "$(command -v systemctl)" == "$W/fi/systemctl" ]] \
    || { echo "HARN=NO-INJECT:$(command -v systemctl)"; exit 6; }
fi
I0="$(systemctl show -p InvocationID --value mosdns)"
R0="$(/usr/local/bin/systemctl show -p InvocationID --value mosdns)"
_PDG_SVC_SRC=""
_pdg_restore_svcstate "$SNAP" >/dev/null 2>&1
I1="$(systemctl show -p InvocationID --value mosdns)"
R1="$(/usr/local/bin/systemctl show -p InvocationID --value mosdns)"
echo "I0=$I0"; echo "I1=$I1"; echo "R0=$R0"; echo "R1=$R1"
echo "AC=$(/usr/local/bin/systemctl is-active mosdns 2>/dev/null)"
echo "N=${#unrestored[@]}"
for x in ${unrestored[@]+"${unrestored[@]}"}; do echo "U| $x"; done
HARNEOF

# 这一组用的是产品那八个 unit 名(_pdg_svcstate_units 那一份清单), 但**只种桩自己的状态**:
# 桩的 is-active / is-enabled / InvocationID 读的都是 $D 下的状态文件, 不需要
# /etc/systemd/system 里有同名 unit。以前这里为了走"已在跑"那条回退去写产品 unit 文件,
# 在 CI 上撞了车: 同一个 lint job 里这支跑两次(#174 / #207), 中间那些要真 systemd 的步骤
# 会把**真的** pdg-bot.service 装进去, 第二次跑到这里就只能放弃这一组 —— 而严格模式下
# 放弃即判红。现在一个字节都不往那儿写, 冲突不复存在;下面 14j-8 把"没动过"验出来。
_ETC=/etc/systemd/system
_PU=(pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness)
_PT=(pdg-health.timer pdg-rules-update.timer)
_etc_img(){   # 八条产品 unit 路径的像: 存在性 + 内容摘要 + 属性(权限/属主/大小)
  local u p
  for u in "${_PU[@]}"; do p="$_ETC/$u.service"
    printf '%s\t%s\t%s\n' "$p" "$([[ -e "$p" ]] && _sha "$p" || echo '<不存在>')" \
                           "$([[ -e "$p" ]] && stat -c '%a:%u:%g:%s' "$p" || echo -)"; done
  for u in "${_PT[@]}"; do p="$_ETC/$u"
    printf '%s\t%s\t%s\n' "$p" "$([[ -e "$p" ]] && _sha "$p" || echo '<不存在>')" \
                           "$([[ -e "$p" ]] && stat -c '%a:%u:%g:%s' "$p" || echo -)"; done
}
_ETC_BEFORE="$(_etc_img)"
if [[ "$_xok" == 1 ]]; then
  # 前像里那八个 unit 的现场: 五个普通服务在跑, 两个 timer 在跑, witness 明确停着
  # (它起真进程, 四件套不齐就起不来 —— 不让它在这一组里制造无关噪声)。
  _units_made=1
  # 五个普通服务在跑(各带一个初始运行周期身份)、两个 timer 在跑、witness 明确停着 ——
  # witness 起的是真进程, 四件套不齐就起不来, 不让它在这一组里制造无关噪声。
  for _u in pdg-mitm pdg-bot pdg-probe81 mosdns mihomo; do
    echo 1 > "$D/$_u.en"; echo 1 > "$D/$_u.ac"; printf 'inv-%s-seed\n' "$_u" > "$D/$_u.inv"
  done
  for _u in "${_PT[@]}"; do echo 1 > "$D/$_u.en"; echo 1 > "$D/$_u.ac"; done
  echo 0 > "$D/pdg-dotwitness.en"; echo 0 > "$D/pdg-dotwitness.ac"; rm -f "$D/pdg-dotwitness.inv"
  _harn(){ PDG_FI_INV="$2" bash "$INVW/harn.sh" "$1" "$INVW" 2>&1; }
  _v(){ sed -n "s/^$2=//p" <<<"$1" | head -1; }   # $1=输出 $2=键
  H0="$(_harn healthy "")"
  H1="$(_harn empty   "")"
  H2="$(_harn frozen  "inv-frozen-9999")"
  for _h in "$H0" "$H1" "$H2"; do
    grep -q '^N=' <<<"$_h" || { t_bad "14j: 壳没跑完(原因: $(grep -m1 '^HARN=' <<<"$_h" || echo 未知)) —— 这一组判据无效"; _xok=0; }
  done
fi
if [[ "$_xok" == 1 ]]; then

  # 14j-0 正控: 桩健康时这条判据**不**登记未恢复 —— 否则下面两格的红是恒红, 没有区分力
  { [[ "$(_v "$H0" N)" == 0 ]] && [[ "$(_v "$H0" AC)" == active ]] \
    && [[ -n "$(_v "$H0" I0)" ]] && [[ "$(_v "$H0" I0)" != "$(_v "$H0" I1)" ]]; } \
    && t_ok "14j-0: 健康桩 ⇒ 恢复判据零登记(restart 换了号: $(_v "$H0" I0) → $(_v "$H0" I1))" \
    || t_bad "14j-0: 健康桩下判据就不干净(N=$(_v "$H0" N) AC=$(_v "$H0" AC) $(_v "$H0" I0)→$(_v "$H0" I1)); 后两格的红无意义
$(grep '^U|' <<<"$H0" | head -3)"

  # 14j-1 注入"读不到 ID": 必须落在那一条失败上, 且不许串到另一条
  { grep -q '^U| mosdns 无法确认是否重新加载了恢复出来的配置(读不到 InvocationID)$' <<<"$H1" \
    && ! grep -q '仍是回滚前那个进程' <<<"$H1" && [[ -z "$(_v "$H1" I1)" ]]; } \
    && t_ok "14j-1: 注入'读不到 ID' ⇒ 判据登记的是'无法确认…(读不到 InvocationID)'" \
    || t_bad "14j-1: 登记不符(I1='$(_v "$H1" I1)')
$(grep '^U| mosdns' <<<"$H1" | head -2)"

  # 14j-2 注入"ID 冻住": 前后都非空且相等、服务仍 active —— 这一种既不是空 ID 也不是没起来
  { grep -q '^U| mosdns 仍是回滚前那个进程, 恢复出来的配置没有被重新加载$' <<<"$H2" \
    && ! grep -q '读不到 InvocationID' <<<"$H2" && ! grep -q '后置状态不符' <<<"$H2" \
    && [[ -n "$(_v "$H2" I0)" ]] && [[ "$(_v "$H2" I0)" == "$(_v "$H2" I1)" ]] \
    && [[ "$(_v "$H2" AC)" == active ]]; } \
    && t_ok "14j-2: 注入'ID 冻住'(前后都是 $(_v "$H2" I0)、仍 active) ⇒ 判据登记的是'仍是回滚前那个进程'" \
    || t_bad "14j-2: 登记不符(I0='$(_v "$H2" I0)' I1='$(_v "$H2" I1)' AC='$(_v "$H2" AC)')
$(grep '^U| mosdns' <<<"$H2" | head -2)"

  # 14j-3 注入是**注入**: 真桩那一侧确实换了号 ⇒ restart 真的发生过, 红不是"没重启"造成的
  { [[ -n "$(_v "$H2" R0)" ]] && [[ "$(_v "$H2" R0)" != "$(_v "$H2" R1)" ]]; } \
    && t_ok "14j-3: 同一次运行里真桩换了号($(_v "$H2" R0) → $(_v "$H2" R1)) ⇒ 失败来自注入, 不是没重启" \
    || t_bad "14j-3: 真桩那侧也没换号($(_v "$H2" R0) → $(_v "$H2" R1)) —— 这一格证明不了失败的来源"
fi
# 收尾放在两个 if 之外: 壳没跑完、判据无效, 本轮造出来的东西照样必须收干净。
if [[ "${_units_made:-0}" == 1 ]]; then
  # 只清**本轮自己种下的**模型状态(桩状态目录里那几份), 别的一概不碰。
  for _u in "${_PU[@]}" "${_PT[@]}"; do rm -f "$D/$_u".*; done
  _left=0
  for _u in "${_PU[@]}" "${_PT[@]}"; do
    for _f in "$D/$_u".*; do [[ -e "$_f" ]] && _left=$((_left+1)); done
  done
  [[ "$_left" == 0 ]] && t_ok "14j-9: 本组种下的模型状态已全部清掉(只清自己拥有的那几份)" \
                      || t_bad "14j-9: 桩状态目录里还剩 $_left 个本组种下的文件"
fi
# 14j-8 这一组自始至终没碰过 /etc/systemd/system 里的产品 unit —— 存在性、内容、属性逐项比。
# 前像在本组**开始之前**取, 所以"本来就有 pdg-bot.service"这种现场也照样验得出没被动过。
if [[ "$(_etc_img)" == "$_ETC_BEFORE" ]]; then
  t_ok "14j-8: 全程没有创建/覆盖/删除任何产品名 unit 文件(8 条路径的存在性、内容摘要与属性逐项不变)"
else
  t_bad "14j-8: /etc/systemd/system 被动过: $(diff <(printf '%s\n' "$_ETC_BEFORE") <(_etc_img) | head -4 | tr '\n' ' ')"
fi
rm -rf "$INVW"

# ── 14k witness 分支: "已在跑"的空转必须在碰真进程**之前**就返回 ──────────────
# 这一个 unit 起的是真进程, 而 _dw_start 会先 kill 掉在跑的那个再拉新的。空转要是走到
# 那里, 结果就是"号保住了、进程被悄悄换掉" —— 比换号更难查, 因为从外面完全看不出来。
# 这里不拉真 witness(那要四件套齐全且 5399 真在听), 而是放一个我们自己的睡眠进程冒充
# "在跑的实例", 并**故意不**准备四件套: 一旦 _dw_start 被调到, 它会先杀掉这个进程、
# 再因缺件失败 —— 进程死亡与 ID 被清空两样都会被抓住。
DW=pdg-dotwitness
if [[ -e /opt/pdg-bot/dotwitness.py ]]; then
  skipf "14k: 机器上有 /opt/pdg-bot/dotwitness.py, 这一格要求四件套**不**齐全"
elif [[ -e /run/pdg-e2e-dw.pid ]]; then
  skipf "14k: /run/pdg-e2e-dw.pid 已经在了 —— 不动别人起的 witness"
elif ! mkdir -p /run 2>/dev/null || ! : > /run/pdg-e2e-dw.pid 2>/dev/null; then
  skipf "14k: /run 不可写, 造不出'在跑的 witness'现场"
else
  rm -f "$D/$DW".* 2>/dev/null
  sleep 300 & _dwpid=$!
  echo "$_dwpid" > /run/pdg-e2e-dw.pid
  echo 1 > "$D/$DW.ac"; printf 'inv-%s-keep\n' "$DW" > "$D/$DW.inv"
  W0="$("$SC" show -p InvocationID --value "$DW")"
  "$SC" start "$DW" >/dev/null 2>&1
  W1="$("$SC" show -p InvocationID --value "$DW")"
  kill -0 "$_dwpid" 2>/dev/null && _alive=1 || _alive=0
  { [[ "$_alive" == 1 ]] && [[ -n "$W1" ]] && [[ "$W1" == "$W0" ]] \
    && [[ "$("$SC" is-active "$DW" 2>/dev/null)" == active ]]; } \
    && t_ok "14k: 已在跑的 witness 再 start 是真空转(进程 $_dwpid 还活着, ID 仍是 $W1)" \
    || t_bad "14k: witness 的空转不实(进程存活=$_alive, ID '$W0' → '$W1', 状态=$("$SC" is-active "$DW" 2>/dev/null))"
  kill "$_dwpid" 2>/dev/null; wait "$_dwpid" 2>/dev/null
  rm -f /run/pdg-e2e-dw.pid "$D/$DW".* 2>/dev/null
fi
rm -f "$D/$SVC".* "/etc/systemd/system/$SVC.service" 2>/dev/null
t_ok "14i: 如实登记 —— 以上都是**模型**证据, 不代表真实服务或真实配置加载已验收"

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
[[ "$PRE_SVC_DIR" == exist || ! -d "$E2E_TMP/e2e-svc" ]] && t_ok "e2e-svc 无本轮残留" || t_bad "$E2E_TMP/e2e-svc 还在"
[[ "$PRE_CALLS" == exist || ! -e "$E2E_TMP/e2e-calls.log" ]] && t_ok "e2e-calls.log 无本轮残留" || t_bad "$E2E_TMP/e2e-calls.log 还在"
stub_cleanup && t_ok "再清一次仍返回 0(幂等)" || t_bad "重复清理失败 —— 不幂等"

fin
