#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 门接进来之后, **其它调用方与幂等路径还成不成立**。
#
# run_all_migrations 有三个调用方, 各自的锁/快照/失败善后责任完全不同:
#   · cmd_platform  —— 平台切换, `|| true` 吞掉失败, 自己没有快照(自己的材料已经 rm -rf);
#   · cmd_migrate   —— 用户显式迁移, 自己建快照, 失败给手工回滚提示;
#   · __migrate 派发 —— 升级子进程, 锁从父进程继承, 失败由父进程回滚。
# 所以"总入口第一句无条件拒绝无句柄调用"会把前两个直接弄坏。本支就是把这条边界钉住:
# 入口契约一个字都不能变, 门只挂在真正要动手的那一处。
#
# 这一支比对的是**产品源码**(候选 vs 冻结基线), 断言都写成"哪一条契约没有被动过"。
# 需要行为证据的那一条(前像存不下就中止, 且中止在装任何文件之前)单独跑一段真代码。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
BASE="${PDG_BASELINE:-}"
# 没显式给基线就从仓库里取冻结基线那一版。取不到(浅克隆 / 对象被裁掉)就如实跳过对比项,
# 不拿"文件不在"冒充"没改过"。
if [[ -z "$BASE" ]]; then
  _b="$BOX/baseline.sh"
  if git -C "$ROOT" show 037d32f08301b382972605587efe9e075ad6625b:deploy/bot/pdg.sh > "$_b" 2>/dev/null && [[ -s "$_b" ]]; then
    BASE="$_b"
  fi
fi
pass=0; nfail=0; skip=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
na(){ echo "[SKIP] $1"; skip=$((skip+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

# 注意: 不要写成 `fnbody … | grep -q`。grep -q 命中就提前退出, 上游 sed 吃到 SIGPIPE,
# 在 `set -o pipefail` 下整条管线返回非 0 —— 会把"找到了"读成"没找到"。一律先落盘再查。
fnbody(){ sed -n "/^$2(){/,/^}/p" "$1"; }
fnfile(){ local o="$BOX/fn-$2.sh"; fnbody "$1" "$2" > "$o"; echo "$o"; }
lineno(){ grep -n -- "$2" "$1" | head -1 | cut -d: -f1; }

echo "══ 一. 总入口与派发块的契约 ══"
if [[ -n "$BASE" && -f "$BASE" ]]; then
  # A1 **本轮按批准的「有条件提前拒绝」精确更新**(原文: 与基线逐字节相同)。
  # 改后的契约: run_all_migrations 相对基线**只允许多出这一处有条件前置**, 一行都不许少。
  # 「无条件拒绝」仍然禁止 —— 下面 A1b 正着钉住它是有条件的。
  _d="$BOX/a1.diff"; diff <(fnbody "$BASE" run_all_migrations) <(fnbody "$PDG" run_all_migrations) > "$_d"
  _del="$(grep -c '^<' "$_d" || true)"; _add="$(grep -c '^>' "$_d" || true)"
  # 275 按裁决再精确放宽**一处**: 标记迁移那一句由 `|| true` 改为"只在平台观测失败(返回 2)时停链"。
  # 282 按裁决再精确放宽**一处**: 自定义放行那一句由 `|| true` 改为"只把返回 3(受管落点准备失败)
  # 记进最终失败"。允许删掉的只有这两句原文; 允许新增的只有: 有条件前置、注释、改后的这两句。
  _delok="$(grep '^<' "$_d" | grep -cE '^< +migrate_platform_marker \|\| true( |$)|^< +migrate_nft_extra \|\| true$' || true)"
  _addok="$(grep '^>' "$_d" | grep -cE '_retire_precheck \|\| return 1|^> *#|^> +migrate_platform_marker \|\| \{ \[\[ \$\? == 2 \]\] && \{ c_r .*; return 1; \}; \}$|^> +migrate_nft_extra \|\| \{ \[\[ \$\? == 3 \]\] && rc=1; \}$' || true)"
  if [[ "${_del:-0}" == "${_delok:-0}" && "${_del:-0}" -le 2 && "${_add:-0}" == "${_addok:-0}" && "${_add:-0}" -ge 1 ]] \
     && grep -q '_retire_precheck || return 1' "$_d"; then
    ok "A1: run_all_migrations 相对基线只多那一处有条件前置, 只把标记迁移那一句换成「平台观测失败才停链」、自定义放行那一句换成「只把返回 3 记进失败」(新增 ${_add} / 删除 ${_del})"
  else
    bad "A1: run_all_migrations 的改动超出批准范围(新增 ${_add:-?} / 其中合规 ${_addok:-?} / 删除 ${_del:-?} / 其中合规 ${_delok:-?})"
    head -14 "$_d"
  fi
  if diff -q <(grep -A3 '^    __migrate)' "$BASE") <(grep -A3 '^    __migrate)' "$PDG") >/dev/null; then
    ok "A2: __migrate 派发块与基线逐字节相同"
  else bad "A2: __migrate 派发块被改过"; fi
else
  na "A: 没给 PDG_BASELINE, 跳过与冻结基线的逐字节对比"
fi
# A1c(不依赖基线): 标记迁移那一句只在返回 2(平台证据读不出来)时停链, 其余返回照旧 best-effort
_ram0="$(fnfile "$PDG" run_all_migrations)"
if grep -qE '^  migrate_platform_marker \|\| \{ \[\[ \$\? == 2 \]\] && \{ c_r .*; return 1; \}; \}$' "$_ram0" \
   && ! grep -qE '^  migrate_platform_marker \|\| true' "$_ram0"; then
  ok "A1c: 迁移链不再吞掉平台观测失败(只对返回 2 停链, 其余仍 best-effort)"
else
  bad "A1c: 迁移链对平台观测失败的处理不是「只对返回 2 停链」"
fi
# A1d(不依赖基线): 自定义放行那一句只把返回 3(受管落点准备失败)记进最终失败, 其余返回照旧 best-effort
if grep -qE '^  migrate_nft_extra \|\| \{ \[\[ \$\? == 3 \]\] && rc=1; \}$' "$_ram0" \
   && ! grep -qE '^  migrate_nft_extra \|\| true' "$_ram0"; then
  ok "A1d: 迁移链只把自定义放行的落点准备失败(返回 3)记进最终失败, 其余返回仍 best-effort"
else
  bad "A1d: 迁移链对自定义放行落点准备失败的结算不是「只把返回 3 记进失败」"
fi

echo
echo "══ 二. cmd_platform: 契约变了, 变在哪里(行为判据, 不是逐字节) ══"
# 本轮明确改了这个入口: 它自己就会做退役类的不可逆动作(切 iOS 经 _plat_purge_retired,
# 切 Android 经 migrate_android_cleanup), 所以它必须**在动第一样东西之前**具备回滚能力,
# 并且不能把"退役没做成"吞掉当成切换成功。
pl="$(fnfile "$PDG" cmd_platform)"
grep -q 'run_all_migrations || true' "$pl" \
  && ok "B1: 总迁移那一句仍是 \`run_all_migrations || true\`(与退役无关的幂等迁移照旧不拖垮切换)" \
  || bad "B1: 总迁移的失败善后被改了"
# 方案1 之后: 前像由 cmd_snapshot 存, 平台切换**只确认**同一份 —— 不再二次采样覆盖。
grep -q '_pdg_svcstate_plan "\$_psnap"' "$pl" \
  && ok "B2: 建完快照就**确认**同一份服务前像(它自己成为有能力的调用方; 不再二次采样)" || bad "B2: 没确认前像"
grep -q '_pdg_save_svcstate' "$pl" \
  && bad "B2b: cmd_platform 里仍有二次采样(_pdg_save_svcstate) —— 会覆盖动手前那一刻的记录" \
  || ok "B2b: cmd_platform 里**没有**二次采样(保存责任只在 cmd_snapshot)"
awk '/cmd_snapshot --source cli --op platform/{s=NR}
     /_pdg_svcstate_plan "\$_psnap"/{v=NR}
     /mktemp -d/{m=NR}
     END{exit !(s&&v&&m&&s<v&&v<m)}' "$pl" \
  && ok "B3: 确认前像排在快照之后、\`mktemp -d\` 建工作区之前 —— 拒绝发生在任何改动之前" \
  || bad "B3: 顺序不对"
grep -q '中止切换(未改动任何东西)' "$pl" && ok "B4: 确认不过就中止, 并明说此刻未改动任何东西" || bad "B4"
grep -q 'export PDG_UPDATE_SVCSTATE="\$_psnap/svcstate.tsv"' "$pl" && ok "B5: 句柄交给后续所有退役类动作" || bad "B5"
awk '/if ! migrate_android_cleanup; then/{a=NR} /_plat_fail_restore; return 1/{if(a&&NR>a&&!done){done=NR}} END{exit !(a&&done)}' "$pl" \
  && ok "B6: migrate_android_cleanup 的返回值被检查, 失败即回退切换(不会「退役失败但成功」)" \
  || bad "B6: 仍然吞掉了 Android 清理的返回值"

echo
echo "══ 二之二. 失败善后: 撤除过退役件就必须用快照整体恢复 ══"
n_old="$(grep -c '_plat_rollback; rm -rf "\$wd"; return 1' "$PDG")"
[[ "$n_old" == 0 ]] && ok "B7: 没有任何失败点再直接走局部还原(统一经 _plat_fail_restore 分岔)" || bad "B7: 还有 $n_old 处直接走 _plat_rollback"
n_new="$(grep -c '_plat_fail_restore; return 1' "$PDG")"
[[ "$n_new" -ge 10 ]] && ok "B8: $n_new 处失败点统一走 _plat_fail_restore" || bad "B8: 只有 $n_new 处"
n_rm="$(grep -c '_plat_fail_restore; rm -rf "\$wd"' "$PDG")"
[[ "$n_rm" == 0 ]] && ok "B8b: 失败点不再自己删材料 —— 删不删由 _plat_fail_restore 按恢复结果决定" || bad "B8b: 还有 $n_rm 处"
grep -q '_plat_fail_restore(){' "$pl" && ok "B9: 分岔入口就在 cmd_platform 里(看得到 \$wd/\$_psnap)" || bad "B9"
grep -q 'cmd_rollback --dir "\$_psnap" --no-git' "$pl" \
  && ok "B10: 撤除过退役件时接的是**已经修好的快照恢复**, 不是另造一套" || bad "B10"
grep -q '不声称已恢复原平台与服务状态' "$pl" && ok "B11: 恢复没完成时明确不声称已恢复" || bad "B11"
grep -q '新增文件清单: \$wd/newfiles' "$pl" && ok "B11b: 恢复不完整时打出新增文件清单的可定位路径" || bad "B11b"
awk '/left\+=\("\$nf"\)/{a=1} /cmd_rollback --dir "\$_psnap"/{if(a)b=1} END{exit !(a&&b)}' "$pl" \
  && ok "B11c: 删除失败先具名累计, 之后**照样**继续做快照恢复(不因第一项失败就放弃其余)" || bad "B11c"

echo
echo "══ 二之三. WLOC/schema 的提交点 ══"
awk '/if ! migrate_wloc_retire; then/{w=NR} /^  rm -rf "\$wd"$/{r=NR} /run_all_migrations \|\| true/{m=NR} /平台已确认/{c=NR}
     END{exit !(w&&r&&m&&c&&w<r&&r<m&&m<c)}' "$pl" \
  && ok "B13: WLOC 退役排在 \`rm -rf \$wd\` **之前**, 而 run_all_migrations 与「平台已确认」都在其后" \
  || bad "B13: 提交顺序不对"
awk '/if ! migrate_wloc_retire; then/{w=NR} /_plat_fail_restore; return 1/{if(w&&NR>w&&!d)d=NR} END{exit !(w&&d&&d-w<4)}' "$pl" \
  && ok "B14: 它失败就走失败善后(不是 || true 吞掉)" || bad "B14"
grep -q '_PDG_RETIRE_DONE=1' "$(fnfile "$PDG" _retire_ios_schema)" \
  && ok "B15: 记录格式真的推进过也会立「撤除过」记号 —— 后续失败走整体恢复" || bad "B15: schema 路径没立记号"
for fn in migrate_android_cleanup _plat_purge_retired; do
  grep -q '_PDG_RETIRE_DONE=1' "$(fnfile "$PDG" "$fn")" \
    && ok "B12: $fn 真的动手之后会立下「撤除过」的记号" || bad "B12: $fn 没立记号"
done

echo
echo "══ 三. 拦截点: 每一处真正要动手的地方都自己问一次, 且答案一致 ══"
n_def="$(grep -c '^_retire_allowed(){' "$PDG")"
[[ "$n_def" == 1 ]] && ok "C1: 判定只有一处实现(_retire_allowed), 全进程记住同一个答案" || bad "C1: 有 $n_def 处实现"
n_call="$(grep -c '_retire_allowed || return 1' "$PDG")"
[[ "$n_call" == 3 ]] && ok "C2: 拦截点正好 3 处" || bad "C2: 拦截点有 $n_call 处(期望 3)"
for fn in migrate_wloc_retire migrate_android_cleanup _plat_purge_retired; do
  grep -q '_retire_allowed || return 1' "$(fnfile "$PDG" "$fn")" \
    && ok "C3: $fn 里有拦截点" || bad "C3: $fn 里没有拦截点"
done
# C4 **本轮精确更新**: cmd_update / cmd_rollback 仍然一处都不许有;
# run_all_migrations 改为"不许有 _retire_allowed 拦截, 只允许那一处**有条件**前置"。
for fn in cmd_update cmd_rollback; do
  grep -qE '_retire_allowed|_retire_precheck' "$(fnfile "$PDG" "$fn")" \
    && bad "C4: $fn 里也有门(会波及与退役无关的路径)" || ok "C4: $fn 里没有门"
done
_ram="$(fnfile "$PDG" run_all_migrations)"
grep -q '_retire_allowed' "$_ram" \
  && bad "C4: run_all_migrations 里出现了 _retire_allowed 拦截(那是无条件的口径)" \
  || ok "C4: run_all_migrations 里没有 _retire_allowed 拦截"
_np="$(grep -c '_retire_precheck || return 1' "$_ram" || true)"
[[ "${_np:-0}" == 1 ]] && ok "C5: run_all_migrations 里有且只有 1 处有条件前置" \
                       || bad "C5: 有条件前置有 ${_np:-0} 处(期望 1)"
_first="$(grep -nE '^[[:space:]]*[a-z_]+' "$_ram" | grep -vE 'run_all_migrations\(\)|local rc=0' | head -1)"
grep -q '_retire_precheck' <<<"$_first" \
  && ok "C6: 前置是链子里**第一句可执行语句**(排在 migrate_* 全部之前): $(sed 's/^ *//' <<<"${_first#*:}")" \
  || bad "C6: 前置不是第一句, 第一句是: $_first"
_pc="$(fnfile "$PDG" _retire_precheck)"
# 前置是**有条件**的, 并且条件是三态里的"**确认**没有"那一态 —— 不是"非 0 就放行"。
awk '/_retire_work_pending; w=\$\?/{f=1} f&&/1\) return 0;;/{print; exit}' "$_pc" | grep -q 'return 0' \
  && ok "A1b: 前置有条件放行, 且只在「**确认**没有退役工作」(w==1)那一态放行" \
  || bad "A1b: 前置里找不到「只在确认没有时放行」那一句"
grep -qE '\*\) *kind=.*无法确认' "$_pc" \
  && ok "C13: 「无法确认」单列一态, 与「确有待办」分开说, 且**不**走放行" \
  || bad "C13: 无法确认没有单列"
# 三态必须真的是三态: 只读查询要能返回 2
for fn in _retire_work_pending _retire_core_has_mitm _retire_has_irreversible_work; do
  grep -q 'return 2' "$(fnfile "$PDG" "$fn")" \
    && ok "C14: $fn 有「无法确认」这一态(return 2)" || bad "C14: $fn 还是两态"
done
# 观测失败不能被读成一种状态: 运行态要退出码与状态词成对判
grep -q 'srv_rc' "$(fnfile "$PDG" _retire_work_pending)" \
  && ok "C15: 运行态查询把**退出码**单独留下来判(不是只看输出那半截)" \
  || bad "C15: 运行态查询仍然丢掉了退出码"
# 只读必须包含传递调用: schema 那一维不许生成字节码
_ir="$(fnfile "$PDG" _retire_has_irreversible_work)"
{ grep -q 'python3 -B' "$_ir" && grep -q 'PYTHONDONTWRITEBYTECODE=1' "$_ir"; } \
  && ok "C16: schema 查询走 -B + PYTHONDONTWRITEBYTECODE(不在现场留 __pycache__)" \
  || bad "C16: schema 查询仍可能写出字节码"
# 覆盖面与后续保护点对齐: 按 migrate_android_cleanup 自己的条件问它自己的判据
_wp2="$(fnfile "$PDG" _retire_work_pending)"
# C17 改后形态: 扫描器排在标记迁移之前, 不能读此刻盘面上还没写出来的 platform / platform.guessed;
# 它经 _pdg_platform_plan(标记迁移与前置共用的那一份判定)问"标记迁移将会定出什么",
# 只对**确认的** android(非推测)才去问 migrate_android_cleanup 用的同一个判据。
{ grep -q '_pdg_platform_plan' "$_wp2" && grep -q '_retire_android_pending' "$_wp2" \
  && grep -qF '"$_PDG_PLAN_PLAT" == android && "$_PDG_PLAN_GUESSED" == 0' "$_wp2"; } \
  && ok "C17: 扫描器按标记迁移**将会**定出的平台判 Android 那一支(确认 android 才问 _retire_android_pending)" \
  || bad "C17: 扫描器与 Android 那一支的范围没对齐"
{ ! grep -qE '\$\(_pdg_platform\)|platform\.guessed' "$_wp2"; } \
  && ok "C17b: 扫描器不再直接读盘面上的平台标记 / .guessed(前置时它们可能还不存在)" \
  || bad "C17b: 扫描器仍在读此刻盘面的平台标记 —— 标记迁移之前那是不作数的"
_pp="$(fnfile "$PDG" _pdg_platform_plan)"; _pm="$(fnfile "$PDG" migrate_platform_marker)"
{ grep -q '_pdg_platform_plan' "$_pm" && [[ "$(grep -c "s/^PDG_PLATFORM=//p" "$PDG")" == 1 ]] \
  && grep -q "s/^PDG_PLATFORM=//p" "$_pp"; } \
  && ok "C17c: 标记迁移与前置共用 _pdg_platform_plan, 平台判定规则全文件只有一份" \
  || bad "C17c: 平台判定规则不止一处, 或标记迁移没有用共享判定"
{ grep -q 'return 2' "$_pp" && grep -qE 'prc.*!= 0|prc" != 0' "$_wp2"; } \
  && ok "C17d: 平台判定读不出来是单独一态(return 2), 扫描器据此判**无法确认**" \
  || bad "C17d: 平台判定的读失败没有单列"
# 只读必须包含传递调用: 扫描器经 _pdg_platform_plan 取平台, 它也不许有任何写动作
grep -qE 'systemctl (start|stop|enable|disable|restart|daemon-reload)|rm -|mv |install -|mktemp|> *"\$|: *> ' "$_pp" \
  && bad "C9b: 扫描器传递调用的 _pdg_platform_plan 里出现了写动作" \
  || ok "C9b: 扫描器传递调用的 _pdg_platform_plan 没有任何写动作"
grep -q '_retire_allowed && return 0' "$_pc" \
  && ok "C7: 能力判定**复用** _retire_allowed(没有另立一套判据)" \
  || bad "C7: 前置没有复用 _retire_allowed"
grep -qE 'PDG_UPDATE_SVCSTATE|holder_pid|boot_id|flock' "$_pc" \
  && bad "C8: 前置里自己动手判句柄/持锁 —— 那是另立一套, 会绕开 _retire_caller_gate" \
  || ok "C8: 前置不自己判句柄/快照绑定/持锁, 一律交给 _retire_caller_gate"
# 只读: 扫描器不许写盘、不许调 systemctl 的写动作
_wp="$(fnfile "$PDG" _retire_work_pending)"
grep -qE 'systemctl (start|stop|enable|disable|restart|daemon-reload)|rm -|mv |install -|> *"\$' "$_wp" \
  && bad "C9: 只读扫描器里出现了写动作" || ok "C9: 只读扫描器没有任何写动作"
grep -q '_retire_has_irreversible_work' "$_wp" \
  && ok "C10: 「什么算退役工作」仍由既有的 _retire_has_irreversible_work 裁决(不另立定义)" \
  || bad "C10: 扫描器没有复用既有的退役工作定义"
# 措辞: 只能承诺迁移链没动手, 不能宣称整个 update 零写入
grep -q '迁移链动第一样东西' "$_pc" && ok "C11: 拒绝文案承诺的是「迁移链」未动手" || bad "C11: 文案没说清范围"
grep -qE '取件、切版本与装文件' "$_pc" \
  && ok "C12: 文案明确把取件/切版本/装文件排除在外(不宣称整次 update 零写入)" \
  || bad "C12: 文案没有把此前已发生的写入排除在外"

echo
echo "══ 三之二. 拦截点排在各自的第一个不可逆动作之前 ══"
body="$(fnfile "$PDG" migrate_wloc_retire)"
g="$(lineno "$body" '_retire_allowed || return 1')"
r1="$(lineno "$body" '归属不清就不能一把清空')"
r2="$(lineno "$body" '可还原的只有 enabled / enabled-runtime / disabled 三种')"
s1="$(lineno "$body" '_retire_ios_schema || return 1')"
s2="$(lineno "$body" '_RETIRE_TMP="$(mktemp -d)"')"
s3="$(grep -n 'systemctl disable\|systemctl stop\|rm -f "\$R/opt/pdg-bot/mitm' "$body" | head -1 | cut -d: -f1)"
[[ -n "$g" && -n "$r1" && "$r1" -lt "$g" ]] && ok "D1: 排在既有的「劫持表有外来行」拒绝之后" || bad "D1(gate=$g, 既有拒绝=$r1)"
[[ -n "$r2" && "$r2" -lt "$g" ]] && ok "D2: 排在既有的「自启状态不支持」拒绝之后" || bad "D2(gate=$g, 既有拒绝=$r2)"
[[ -n "$s1" && "$g" -lt "$s1" ]] && ok "D3: 排在 _retire_ios_schema(推进记录格式)之前" || bad "D3(gate=$g, schema=$s1)"
[[ -n "$s2" && "$g" -lt "$s2" ]] && ok "D4: 排在 mktemp -d(开始动手)之前" || bad "D4(gate=$g, mktemp=$s2)"
[[ -n "$s3" && "$g" -lt "$s3" ]] && ok "D5: 排在第一处停服务/删文件之前" || bad "D5(gate=$g, 首个副作用=$s3)"
body="$(fnfile "$PDG" migrate_android_cleanup)"
g="$(lineno "$body" '_retire_allowed || return 1')"
f1="$(grep -n 'mitm_hijack.txt\|systemctl disable --now pdg-mitm\|rm -f "\$R' "$body" | head -1 | cut -d: -f1)"
[[ -n "$g" && -n "$f1" && "$g" -lt "$f1" ]] && ok "D6: Android 清理的拦截点排在第一处改动之前(第 $g 行 vs 第 $f1 行)" || bad "D6(gate=$g, 首个副作用=$f1)"
body="$(fnfile "$PDG" _plat_purge_retired)"
g="$(lineno "$body" '_retire_allowed || return 1')"
f1="$(grep -n 'systemctl disable --now pdg-mitm\|rm -f "\$R' "$body" | head -1 | cut -d: -f1)"
[[ -n "$g" && -n "$f1" && "$g" -lt "$f1" ]] && ok "D7: 平台清理的拦截点排在第一处改动之前(第 $g 行 vs 第 $f1 行)" || bad "D7(gate=$g, 首个副作用=$f1)"

echo
echo "══ 四. 放行判据不是「某个文件缺不缺」也不是单一环境变量 ══"
gate="$(fnfile "$PDG" _retire_caller_gate)"
irr="$(fnfile "$PDG" _retire_has_irreversible_work)"
grep -q 'PDG_UPDATE_SVCSTATE' "$irr" \
  && bad "D1: 「有没有不可逆的事要做」竟然看句柄环境变量(那就成了可以随手关掉的开关)" \
  || ok "D1: 「有没有不可逆的事要做」只看待办本身(五个 need_* 与记录 schema)"
newenv="$(grep -oE '\$\{?PDG_[A-Z_]+' "$gate" "$irr" | sed 's/.*\${\?//' | sort -u | tr '\n' ' ')"
[[ "$newenv" == "PDG_RETIRE_ROOT PDG_UPDATE_SVCSTATE " || "$newenv" == "PDG_UPDATE_SVCSTATE PDG_RETIRE_ROOT " ]] \
  && ok "D2: 新代码只读这两个环境变量: $newenv(PDG_RETIRE_ROOT 是仓库既有的测试前缀)" \
  || bad "D2: 出现了预期之外的环境变量: $newenv"
grep -qiE 'FORCE|SKIP_|BYPASS|NOCHECK|UNSAFE' "$gate" "$irr" \
  && { bad "D3: 门里出现了疑似旁路开关"; grep -niE 'FORCE|SKIP_|BYPASS|NOCHECK|UNSAFE' "$gate" "$irr"; } \
  || ok "D3: 没有 FORCE/SKIP/BYPASS 一类的旁路开关"
# 基线是**退役单线**那一版。整合进桥接的 `--to` 之后, "强制重装同一版本"这条提示与它的守卫
# 在 --to 那一路各多一份 —— 同一语义的合法复制, 不是新开的口子。判据改成两条:
#   ① 一处都不许少(没有被删掉或放宽); ② 每一处都必须是已知的三种形态。
_FN="$(grep -c 'PDG_UPDATE_FORCE' "$PDG")"; _FB="$(grep -c 'PDG_UPDATE_FORCE' "${BASE:-$PDG}")"
[[ "$_FN" -ge "$_FB" ]] \
  && ok "D4a: PDG_UPDATE_FORCE 一处都没少(基线 $_FB → 现在 $_FN)" \
  || bad "D4a: 比基线少了(基线 $_FB → 现在 $_FN) —— 守卫被删或被放宽"
_FBAD="$(grep -n 'PDG_UPDATE_FORCE' "$PDG" | grep -vE ':\s*#' \
  | grep -vE '\[\[ -z "\$\{PDG_UPDATE_FORCE:-\}" && ' \
  | grep -vE 'PDG_UPDATE_FORCE=1 pdg update')"
[[ -z "$_FBAD" ]] \
  && ok "D4b: $_FN 处 PDG_UPDATE_FORCE 全部是已知形态(注释 / same 守卫 / 强制重装提示), 没有新开的旁路" \
  || { bad "D4b: 出现了形态不明的 PDG_UPDATE_FORCE 用法"; sed 's/^/      /' <<<"$_FBAD"; }

echo
echo "══ 五. 恢复动作没有被塞进别的地方 ══"
for f in $(cd "$ROOT" && ls lib/*.sh 2>/dev/null) ; do
  grep -qE '_pdg_restore_svcstate|_retire_caller_gate|systemctl (enable|disable) ' "$ROOT/$f" \
    && bad "E1: 被 source 的 $f 里出现了恢复/门动作" || true
done
ok "E1: lib/*.sh 里没有恢复动作或门(恢复只发生在 cmd_rollback 显式调用处)"
if compgen -G "$ROOT/deploy/bot/*.service" >/dev/null || compgen -G "$ROOT/deploy/bot/*.timer" >/dev/null; then
  grep -lE '_pdg_restore_svcstate|svcstate' "$ROOT"/deploy/bot/*.service "$ROOT"/deploy/bot/*.timer 2>/dev/null \
    | grep -q . && bad "E2: unit/timer 里出现了前像恢复" || ok "E2: unit/timer 里没有前像恢复(不是后台守护, 也不是隐式救援钩子)"
else na "E2: 这个副本里没有 unit 模板"; fi
n_restore="$(grep -c '_pdg_restore_svcstate "' "$PDG")"
[[ "$n_restore" == 1 ]] && ok "E3: 恢复只有 1 处调用点" || bad "E3: 恢复被调用了 $n_restore 次"
grep -q '_pdg_restore_svcstate' "$(fnfile "$PDG" cmd_rollback)" \
  && ok "E4: 那一处就在 cmd_rollback 里" || bad "E4: 恢复不在 cmd_rollback 里"

echo
echo "══ 六. 前像存不下就中止, 且中止在装任何文件之前 ══"
# 方案1: cmd_update 不再保存, 改为确认。判据跟着换到确认那一行。
ln_save="$(grep -n 'if \[\[ ! -f "\$snap_dir/svcstate.tsv" \]\] || ! _pdg_svcstate_plan "\$snap_dir"; then' "$PDG" | head -1 | cut -d: -f1)"
ln_mig="$(grep -n '^\s*if ! .*bash /usr/local/bin/pdg __migrate' "$PDG" | head -1 | cut -d: -f1)"
ln_inst="$(grep -n 'install -m755 "$REPO_DIR"\|install -m644 "$REPO_DIR"' "$PDG" | head -1 | cut -d: -f1)"
[[ -n "$ln_save" && -n "$ln_mig" && "$ln_save" -lt "$ln_mig" ]] && ok "F1: 确认前像排在 __migrate 子进程之前" || bad "F1: 顺序不对($ln_save vs $ln_mig)"
[[ -n "$ln_inst" && "$ln_save" -lt "$ln_inst" ]] && ok "F2: 确认前像排在第一处 install 之前(动手之前就已经拒绝)" || bad "F2: 顺序不对($ln_save vs $ln_inst)"
# 行为证据: 把产品那四行原样拿出来跑, 存前像失败必须 return 1
{ echo 'set -uo pipefail'
  echo 'c_y(){ echo "$*"; }'
  echo '_pdg_svcstate_plan(){ _PDG_SVC_WHY="注入: 确认不过"; return 1; }'
  echo 'launched=0'
  echo 'bash(){ launched=1; }'
  echo 'guard(){'
  echo "  local snap_dir=\"$BOX/snap\""   # 用本用例的一次性目录, 不写死 /tmp 路径
  # 方案1 的确认块是 4 行(if / c_y / return 1 / fi) —— 少取一行 fi 就被切掉, 生成的壳语法不过,
  # "没有中止"会被读成产品没拦。按 fi 收尾动态取, 不写死行数。
  awk -v s="$ln_save" 'NR>=s{print; if($0 ~ /^  fi$/) exit}' "$PDG"
  echo '  bash /usr/local/bin/pdg __migrate'
  echo '  return 0'
  echo '}'
  echo 'guard; echo "RC=$?"; echo "LAUNCHED=$launched"'
} > "$BOX/guard.sh"
o="$(bash "$BOX/guard.sh" 2>&1)"
grep -q 'RC=1' <<<"$o" && ok "F3: 前像确认失败 → 中止(return 1)" || { bad "F3: 没有中止"; echo "$o" | sed 's/^/      /'; }
grep -q 'LAUNCHED=0' <<<"$o" && ok "F4: 且**没有**启动迁移子进程" || bad "F4: 仍然启动了迁移子进程"

echo
echo "══ 七. cmd_migrate 变成了「有能力的调用方」而不是被挡住 ══"
mg="$(fnfile "$PDG" cmd_migrate)"
grep -q '_pdg_svcstate_plan "$snap"' "$mg" && ok "G1: 显式迁移也在动手前**确认**前像" || bad "G1: 没确认"
grep -q '_pdg_save_svcstate' "$mg" \
  && bad "G1b: cmd_migrate 里仍有二次采样" || ok "G1b: cmd_migrate 里**没有**二次采样"
grep -q 'PDG_UPDATE_SVCSTATE="$snap/svcstate.tsv" run_all_migrations' "$mg" && ok "G2: 并把本次句柄交给迁移" || bad "G2: 没交句柄"
awk '/_pdg_svcstate_plan "\$snap"/{s=NR} /run_all_migrations/{m=NR} END{exit !(s&&m&&s<m)}' "$mg" \
  && ok "G3: 确认前像排在 run_all_migrations 之前" || bad "G3: 顺序不对"
grep -q '拒绝在无法完整回滚的前提下迁移' "$mg" && ok "G4: 确认不过就拒绝(不是确认不过也照跑)" || bad "G4"

echo
echo "══ 八. 三个调用方各自的失败善后责任(行为) ══"
# 把**真的** run_all_migrations 拿出来跑: 其余 migrate_* 一律打桩返回 0, 只让
# migrate_wloc_retire 按门的判定返回。验的是"门拒绝了之后, 这条失败到底传不传得出去"。
# $2 是本轮新增的那一处有条件前置的返回码。这里把它打桩, 是因为 H1/H2 验的是
# **失败传播**(门拒了传不传得出去), 不是前置本身; 前置自己的判定由
# tests/test-migrate-caller-gate.sh 第十五/十六节用产品原文驱动。
# 打桩必须显式写出来 —— 不定义它的话 `_retire_precheck || return 1` 会 127, 于是每一格
# 都返回 1, H2 那条反向对照就永远"成立", 等于没验。
runall(){ # $1 = migrate_wloc_retire 的返回码  $2 = _retire_precheck 的返回码  $3 = migrate_nft_extra 的返回码(缺省 0)
  local d="$BOX/runall-$1-$2-${3:-0}"; mkdir -p "$d"; : > "$d/calls.log"
  { echo 'set -uo pipefail'
    echo "CALLS=\"$d/calls.log\""
    echo 'for f in $(grep -oE "migrate_[a-z0-9_]+" "'"$PDG"'" | sort -u); do'
    echo '  eval "$f(){ echo \"$f\" >> \"$CALLS\"; return 0; }"'
    echo 'done'
    echo "migrate_wloc_retire(){ echo migrate_wloc_retire >> \"\$CALLS\"; return $1; }"
    echo "migrate_nft_extra(){ echo migrate_nft_extra >> \"\$CALLS\"; return ${3:-0}; }"
    echo "_retire_precheck(){ return $2; }"
    sed -n "/^run_all_migrations(){/,/^}/p" "$PDG"
    echo 'run_all_migrations; echo "RC=$?"'
  } > "$d/run.sh"
  RUNALL_OUT="$(bash "$d/run.sh" 2>&1 | tail -1)"
  local _n _rc=0
  _n="$(wc -l < "$d/calls.log")" || _rc=$?
  (( _rc == 0 )) && RUNALL_N="${_n//[[:space:]]/}" || RUNALL_N=ERR
}
RUNALL_N=0; RUNALL_OUT=""
runall 1 0; [[ "$RUNALL_OUT" == "RC=1" ]] && ok "H1: 门拒绝 → migrate_wloc_retire 返回 1 → run_all_migrations 返回非 0(半截现场不会被吞成成功)" || bad "H1: 实得 $RUNALL_OUT"
runall 0 0; _r="$RUNALL_OUT"
[[ "$_r" == "RC=0" ]] && ok "H2: 反向对照 —— 只有这一格返回 0 时整体就是 0(H1 不是别的迁移造成的)" || bad "H2: 实得 $_r"
_n_ok="$RUNALL_N"
runall 0 1; _r2="$RUNALL_OUT"
[[ "$_r2" == "RC=1" ]] \
  && ok "H2b: 有条件前置拒绝 ⇒ run_all_migrations 直接返回非 0(不靠后面任何一个迁移)" \
  || bad "H2b: 前置拒了却返回 $_r2"
[[ "${RUNALL_N:-0}" == 0 && "${_n_ok:-0}" -gt 0 ]] \
  && ok "H2c: 前置拒绝时**一个 migrate_* 都没被调用**(健康那一格调了 $_n_ok 个作对照)" \
  || bad "H2c: 前置拒了仍调了 ${RUNALL_N:-?} 个迁移(健康对照 ${_n_ok:-?} 个)"
grep -q 'run_all_migrations || true' "$(fnfile "$PDG" cmd_platform)" \
  && ok "H3: cmd_platform 仍是 \`run_all_migrations || true\` —— 退役被拒不会让平台切换失败(那一步顺延到下次 update/migrate)" \
  || bad "H3: cmd_platform 的失败善后被改了"
grep -q '__migrate)     need_root __migrate; _lock; run_all_migrations;;' "$PDG" \
  && ok "H4: __migrate 派发仍是 need_root + _lock + run_all_migrations —— 失败照旧传回父进程由它回滚" \
  || bad "H4: __migrate 派发被改了"
awk '/_pdg_svcstate_plan "\$snap"/{s=1} /run_all_migrations/{if(s)m=1} END{exit !m}' "$(fnfile "$PDG" cmd_migrate)" \
  && ok "H5: cmd_migrate 自建快照 + 确认同一份前像 + 自带句柄 —— 它是有能力的调用方, 不会被自己的门挡住" \
  || bad "H5"
runall 0 0 3; _r3="$RUNALL_OUT"; _n3="$RUNALL_N"
[[ "$_r3" == "RC=1" ]] \
  && ok "H6: migrate_nft_extra 返回 3(受管落点准备失败)⇒ run_all_migrations 最终非 0(其后各迁移都返回 0 也冲不掉)" \
  || bad "H6: 返回 3 却得到 $_r3"
[[ "${_n3:-x}" == "${_n_ok:-y}" ]] \
  && ok "H6b: 这一类失败不截断后面的迁移(调用数 $_n3 = 健康对照 $_n_ok)" \
  || bad "H6b: 调用数 ${_n3:-?} ≠ 健康对照 ${_n_ok:-?}"
runall 0 0 1; _r4="$RUNALL_OUT"
[[ "$_r4" == "RC=0" ]] \
  && ok "H7: migrate_nft_extra 的其它非零(如 1)仍 best-effort, 不升级为失败(口径没有扩大)" \
  || bad "H7: 返回 1 却得到 $_r4 —— 口径被扩大了"

echo
echo "══ 九. 自定义放行落点: 准备失败不许被吞(驱动产品原文 migrate_nft_extra; 模型) ══"
# 这一节是**模型**验证: 取产品原文 migrate_nft_extra, 只把第一行两个落点路径整行换成本用例自己的临时树;
# install 用 shell 函数注入(真 install 或注入失败), nftscan / nft 是桩(nft 只记调用, 不碰宿主),
# mktemp 落在本用例目录。验的是本函数的判定与返回码, 不是真实挂载/真实 nft 的行为。
NX_L1='  local f=/etc/nftables.conf d=/etc/privdns-gateway/nft-input.d'
# 下面四个小工具都先看执行状态、再用内容; 失败时什么都不打印并返回 2, 调用方记观测无效。
# 摘要: 文件确实不存在 → ABSENT(合法, N6 就是); 存在就必须读成功且是 64 位十六进制 —— 读失败不改写成"无文件"。
nxsha(){ [[ -e "$1" || -L "$1" ]] || { [[ -d "${1%/*}" ]] && { printf 'ABSENT'; return 0; }; return 2; }
         local o; o="$(sha256sum < "$1")" || return 2; o="${o%% *}"; [[ "$o" =~ ^[0-9a-f]{64}$ ]] || return 2; printf '%s' "$o"; }
# 计数: grep -c 回 0/1 都是结果(1 = 正常零匹配), ≥2 是执行错误; 输出也必须是数字。
nxcnt(){ local n r; n="$(grep -c -- "$1" "$2")"; r=$?; (( r <= 1 )) && [[ "$n" =~ ^[0-9]+$ ]] || return 2; printf '%s' "$n"; }
# 生成脚本里被测函数 / 链的返回码: 输出里必须**恰好一行** RC=<数字>, 否则不采信。
nxrc(){ local l n; l="$(grep -E '^RC=' "$1")" || return 2; n="$(grep -cE '^RC=' "$1")" || return 2
        [[ "$n" == 1 && "$l" =~ ^RC=([0-9]+)$ ]] || return 2; printf '%s' "${BASH_REMATCH[1]}"; }
# 在本格输出(落盘的 out.txt)里找产品原话: 0 有 / 1 确认没有; grep 自己出错就置 NX_GERR, 本格不下结论。
hasout(){ grep -qF -- "$1" "$NX_D/out.txt"; local r=$?; (( r >= 2 )) && NX_GERR=1; return "$r"; }
nx(){ # $1=案例名 $2=install 注入(real|fail-nodir|fail-leavedir|ok-nodir) $3=配置形态(none|fresh|withinc|nonpdg|weird) $4=nftscan 回码(缺省 1)
  local d="$BOX/nx-$1" t; t="$d/t"; mkdir -p "$t" "$d/tmp"; : > "$d/calls.log"
  NX_D="$d"; NX_T="$t"; NX_OBS=""; NX_PRC=""; NX_RC=""; NX_SUBST=""; NX_NFT=""; NX_INST=""; NX_SHA0=""; NX_SHA1=""; NX_DIR=""
  local pdgconf='#!/usr/sbin/nft -f
table inet pdg
delete table inet pdg
table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        tcp dport { 22 } accept
    }
}'
  case "$3" in
    none)    : ;;
    fresh)   printf '%s\n' "$pdgconf" > "$t/nftables.conf" ;;
    withinc) printf '%s\n' "$pdgconf" | sed 's#^    }$#        include "/etc/privdns-gateway/nft-input.d/*.conf"\n    }#' > "$t/nftables.conf" ;;
    nonpdg)  printf 'table inet filter {\n    chain input {\n        type filter hook input priority 0;\n    }\n}\n' > "$t/nftables.conf" ;;
    weird)   printf '#!/usr/sbin/nft -f\ntable inet pdg {\n  chain weird {\n    type filter hook forward priority 0;\n  }\n}\n' > "$t/nftables.conf" ;;
  esac
  NX_SHA0="$(nxsha "$t/nftables.conf")" || NX_OBS="$NX_OBS 调用前配置摘要"
  printf 'import sys\nsys.exit(%s)\n' "${4:-1}" > "$d/nftscan.py"
  printf '#!/bin/bash\necho "nft $*" >> "%s"\nexit 0\n' "$d/calls.log" > "$d/nft"; chmod +x "$d/nft"
  # 执行前提(抽取原文、替换计数、写出替换后的原文)任何一步不成立都**立即返回、不执行**: 否则半截原文
  # 或没替换到的产品原文会拿 /etc 下的真实路径去跑(模型只许落在本用例临时树)。错误记进 NX_OBS, 由 nxchk 记失败。
  fnbody "$PDG" migrate_nft_extra > "$d/fn.raw" || { NX_OBS="$NX_OBS 抽取产品原文失败(rc=$?; 未执行)"; return 0; }
  local src; NX_SUBST="$(grep -cxF -- "$NX_L1" "$d/fn.raw")"; src=$?
  # 放行只有一种情形: 计数查询成功(rc 0)且结果恰好是 1。零份 / 多份 / 无输出 / 查询失败 / 半截输出一律阻断。
  if (( src != 0 )) || [[ "$NX_SUBST" != 1 ]]; then NX_OBS="$NX_OBS 落点替换计数不成立(rc=$src 结果=${NX_SUBST:-空}; 未执行)"; return 0; fi
  awk -v a="$NX_L1" -v b="  local f=\"$t/nftables.conf\" d=\"$t/nft-input.d\"" '$0==a{print b; next} {print}' "$d/fn.raw" > "$d/fn.sh" \
    || { NX_OBS="$NX_OBS 写出替换后的原文"; return 0; }
  { echo 'set -uo pipefail'
    echo "export TMPDIR=\"$d/tmp\""
    echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; c_r(){ echo "$*"; }'
    echo "_pdg_module(){ echo \"$d/nftscan.py\"; }"
    echo "_pdg_nft_bin(){ echo \"$d/nft\"; }"
    case "$2" in
      real)          echo "install(){ echo \"install \$*\" >> \"$d/calls.log\"; command install \"\$@\"; }" ;;
      fail-nodir)    echo "install(){ echo \"install \$*\" >> \"$d/calls.log\"; echo 'install: 注入: cannot create directory' >&2; return 1; }" ;;
      fail-leavedir) echo "install(){ echo \"install \$*\" >> \"$d/calls.log\"; mkdir -p \"\${*: -1}\"; echo 'install: 注入: 建了目录但随后失败' >&2; return 1; }" ;;
      ok-nodir)      echo "install(){ echo \"install \$*\" >> \"$d/calls.log\"; return 0; }" ;;
    esac
    cat "$d/fn.sh"
    echo 'migrate_nft_extra; echo "RC=$?"'
  } > "$d/run.sh"
  # 生成脚本的**进程**退出码(正常是 0: 最后一句是 echo)与其中被测函数的返回码(RC=, 可能正当地是 3)分开记。
  bash "$d/run.sh" > "$d/out.txt" 2>&1; NX_PRC=$?
  NX_RC="$(nxrc "$d/out.txt")" || NX_OBS="$NX_OBS 返回码解析"
  NX_SHA1="$(nxsha "$t/nftables.conf")" || NX_OBS="$NX_OBS 调用后配置摘要"
  NX_NFT="$(nxcnt '^nft ' "$d/calls.log")" || NX_OBS="$NX_OBS nft调用计数"
  NX_INST="$(nxcnt '^install ' "$d/calls.log")" || NX_OBS="$NX_OBS install调用计数"
  NX_DIR=no; [[ -d "$t/nft-input.d" ]] && NX_DIR=yes
}
nxchk(){ # $1=编号 $2=说明 $3=条件表达式(bash) —— 执行无效 / 观测无效都记失败, 不下业务结论
  if [[ -n "$NX_PRC" && "$NX_PRC" != 0 ]]; then
    bad "$1: **执行无效** —— 生成脚本进程退出码 $NX_PRC(被测函数返回码 ${NX_RC:-未取得} 另记), 不判定: $2"; return; fi
  if [[ -n "$NX_OBS" ]]; then bad "$1: **观测无效** ——${NX_OBS}, 不判定: $2"; return; fi
  NX_GERR=0; local r=0; eval "$3" || r=1
  if (( NX_GERR )); then bad "$1: **观测无效** —— 在本格输出里查找产品原话时 grep 出错, 不判定: $2"; return; fi
  if (( r == 0 )); then ok "$1: $2"; else bad "$1: $2 —— 实得 RC=$NX_RC 配置变=$([[ $NX_SHA0 == "$NX_SHA1" ]] && echo 否 || echo 是) nft调用=$NX_NFT install调用=$NX_INST 目录=$NX_DIR"; head -6 "$NX_D/out.txt" 2>/dev/null | sed 's/^/      /'; fi
}
same(){ [[ "$NX_SHA0" == "$NX_SHA1" ]]; }
named(){ hasout "$NX_T/nft-input.d" && hasout "$1"; }
nx N1 real fresh 1
nxchk N1 "健康创建: 目录建成、include 写入、校验与加载各一次、返回 0" \
  '[[ $NX_RC == 0 && $NX_DIR == yes && $NX_NFT == 2 ]] && ! same && hasout "已加自定义放行 include 点"'
nx N2 fail-nodir fresh 1
nxchk N2 "install 失败且目录不存在: 不改配置、不进校验/加载, 返回 3, 具名报出目录/退出码/错误" \
  '[[ $NX_RC == 3 && $NX_NFT == 0 && $NX_DIR == no ]] && same && named "退出码 1" && hasout "注入: cannot create directory" && ! hasout "已加自定义放行"'
nx N3 fail-leavedir fresh 1
nxchk N3 "install 失败但留下了目录: 仍按真实退出码判失败(返回 3), 不改配置" \
  '[[ $NX_RC == 3 && $NX_NFT == 0 && $NX_DIR == yes ]] && same && named "退出码 1"'
nx N4 ok-nodir fresh 1
nxchk N4 "install 返回 0 却没有目录: 后置检查拒绝(返回 3), 不改配置" \
  '[[ $NX_RC == 3 && $NX_NFT == 0 && $NX_DIR == no ]] && same && named "返回 0"'
nx N5 fail-nodir withinc 1
nxchk N5 "已有 include、目录缺失: 不被幂等短路掩盖(返回 3), 不改配置" \
  '[[ $NX_RC == 3 && $NX_NFT == 0 ]] && same && named "退出码 1"'
nx N5h real withinc 1
nxchk N5h "已有 include、目录正常(健康对照): 幂等返回 0, 不改配置" '[[ $NX_RC == 0 && $NX_NFT == 0 && $NX_DIR == yes ]] && same'
nx N6 fail-nodir none 1
nxchk N6 "没有 nftables.conf(不适用): 返回 0, 连 install 都不调" '[[ $NX_RC == 0 && $NX_INST == 0 ]]'
nx N7 fail-nodir nonpdg 1
nxchk N7 "非 pdg 配置(不适用): 落点失败也不判, 返回 0, 不改配置" '[[ $NX_RC == 0 && $NX_NFT == 0 ]] && same && ! hasout "落点"'
nx N8a fail-nodir fresh 0
nxchk N8a "nftscan 回 0(有冲突, 安全跳过): 落点失败也不判, 返回 0, 不改配置" '[[ $NX_RC == 0 && $NX_NFT == 0 ]] && same && ! hasout "落点"'
nx N8b fail-nodir fresh 2
nxchk N8b "nftscan 回 2(读不到, 观测不足而安全跳过): 同上" '[[ $NX_RC == 0 && $NX_NFT == 0 ]] && same && ! hasout "落点"'
nx N9 fail-nodir weird 1
nxchk N9 "认不出的形态: 仍按原契约报「自定义形态」、返回 0、不改配置, 落点失败不判" \
  '[[ $NX_RC == 0 && $NX_NFT == 0 ]] && same && hasout "防火墙是自定义形态" && ! hasout "落点"'

# 链上: **真实** run_all_migrations 原文 + **真实** migrate_nft_extra 原文(同上替换落点), 其余迁移打桩返回 0
nxchain(){ # $1=install 注入  → NXC_RC / NXC_AFTER(排在它后面的迁移是否被调用)
  local d="$BOX/nxc-$1" t; t="$d/t"; mkdir -p "$t" "$d/tmp"; : > "$d/calls.log"
  printf '%s\n' '#!/usr/sbin/nft -f' 'table inet pdg {' '    chain input {' '        type filter hook input priority 0; policy drop;' '    }' '}' > "$t/nftables.conf"
  printf 'import sys\nsys.exit(1)\n' > "$d/nftscan.py"
  printf '#!/bin/bash\nexit 0\n' > "$d/nft"; chmod +x "$d/nft"
  NXC_PRC=""; NXC_RC=""; NXC_AFTER=""; NXC_OBS=""
  # 与 nx 同一条执行前提: 抽取失败立即返回; 替换计数只有"查询成功且恰好 1"才放行。
  fnbody "$PDG" migrate_nft_extra > "$d/fn.raw" || { NXC_OBS="$NXC_OBS 抽取产品原文失败(rc=$?; 未执行)"; return 0; }
  local ns src; ns="$(grep -cxF -- "$NX_L1" "$d/fn.raw")"; src=$?
  if (( src != 0 )) || [[ "$ns" != 1 ]]; then NXC_OBS="$NXC_OBS 落点替换计数不成立(rc=$src 结果=${ns:-空}; 未执行)"; return 0; fi
  awk -v a="$NX_L1" -v b="  local f=\"$t/nftables.conf\" d=\"$t/nft-input.d\"" '$0==a{print b; next} {print}' "$d/fn.raw" > "$d/fn.sh" \
    || { NXC_OBS="$NXC_OBS 写出替换后的原文"; return 0; }
  { echo 'set -uo pipefail'
    echo "export TMPDIR=\"$d/tmp\"; CALLS=\"$d/calls.log\""
    echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; c_r(){ echo "$*"; }'
    echo 'for f in $(grep -oE "migrate_[a-z0-9_]+" "'"$PDG"'" | sort -u); do'
    echo '  eval "$f(){ echo \"$f\" >> \"$CALLS\"; return 0; }"'
    echo 'done'
    echo '_retire_precheck(){ return 0; }'
    echo "_pdg_module(){ echo \"$d/nftscan.py\"; }"
    echo "_pdg_nft_bin(){ echo \"$d/nft\"; }"
    case "$1" in
      real)       echo 'install(){ command install "$@"; }' ;;
      fail-nodir) echo "install(){ echo 'install: 注入: cannot create directory' >&2; return 1; }" ;;
    esac
    cat "$d/fn.sh"                                   # 覆盖上面给 migrate_nft_extra 的桩
    sed -n "/^run_all_migrations(){/,/^}/p" "$PDG"
    echo 'run_all_migrations; echo "RC=$?"'
  } > "$d/run.sh"
  bash "$d/run.sh" > "$d/out.txt" 2>&1; NXC_PRC=$?          # 进程退出码; 链返回码在 RC= 里, 二者分开记
  NXC_RC="$(nxrc "$d/out.txt")" || NXC_OBS="$NXC_OBS 返回码解析"
  grep -qx 'migrate_custom_hijack' "$d/calls.log"
  case $? in 0) NXC_AFTER=yes ;; 1) NXC_AFTER=no ;; *) NXC_OBS="$NXC_OBS 调用记录查询" ;; esac
}
nxcchk(){ # $1=编号 $2=期望链返回码 $3=说明 [$4=yes: 还要求其后的迁移被调用]
  if [[ -z "$NXC_PRC" ]]; then bad "$1: **观测无效** ——${NXC_OBS}, 不判定: $3"
  elif [[ "$NXC_PRC" != 0 ]]; then bad "$1: **执行无效** —— 生成脚本进程退出码 $NXC_PRC(链返回码 ${NXC_RC:-未取得} 另记), 不判定: $3"
  elif [[ -n "$NXC_OBS" ]]; then bad "$1: **观测无效** ——${NXC_OBS}, 不判定: $3"
  elif [[ "$NXC_RC" == "$2" && ( "${4:-}" != yes || "$NXC_AFTER" == yes ) ]]; then ok "$1: $3"
  else bad "$1: $3 —— 实得 RC=$NXC_RC 其后迁移被调用=$NXC_AFTER"; fi
}
nxchain fail-nodir
nxcchk N10 1 "真实链 + 真实 migrate_nft_extra: 落点准备失败 ⇒ 链最终返回非 0, 且其后的迁移照常执行后也没把它冲成成功" yes
nxchain real
nxcchk N10h 0 "同一条链, 落点正常(健康对照)⇒ 返回 0"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail, 跳过 $skip"
[[ "$nfail" == 0 ]]
