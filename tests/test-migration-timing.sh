#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 迁移时机回归(5.1 P0): 迁移不得发生在"用户没要求"或"快照之前"。
#
# 旧实现在命令分派**之前**对所有管理类命令跑一遍 run_all_migrations —— 那时既没上锁, 也在
# cmd_update 打快照之前。于是: 点个菜单就悄悄改了 unit/nft/mosdns; 更新失败回滚只能回到
# "已被迁移改过"的现网, 而用户以为回到了操作前。
#
# 本用例抽真身执行(不是 grep 源码): 用假的 run_all_migrations 记录调用次序, 跑真实的分派逻辑。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# ── 1. 分派前不再有隐藏迁移 ──
# 取 pdg.sh 里"分派段"的真实代码(case 之前到 case 之间), 确认它不再调用 run_all_migrations。
disp="$(sed -n '/^# 5.1: \*\*取消命令分派前的隐藏迁移/,/^case "\${1:-menu}" in/p' "$ROOT/deploy/bot/pdg.sh")"
[[ -n "$disp" ]] || bad "找不到分派段(pdg.sh 结构变了?)"
# 只看**可执行行**(注释里会提到这个函数名, 那是说明为什么取消了它)
grep -vE '^\s*#' <<<"$disp" | grep -q 'run_all_migrations' \
  && bad "分派前仍然会跑 run_all_migrations" \
  || ok "命令分派前不再有隐藏迁移(菜单/restart 等不会暗中改配置)"

# ── 2. 真跑一遍: 普通命令不触发迁移 ──
# 造一个只保留"函数定义 + 分派"的可执行副本, 把会真动系统的函数打桩。
build(){
  {
    echo 'run_all_migrations(){ echo "MIGRATE" >> "$WORK/order"; }'
    echo 'cmd_status(){ echo "STATUS" >> "$WORK/order"; }'
    echo 'cmd_restart(){ echo "RESTART" >> "$WORK/order"; }'
    echo 'menu(){ echo "MENU" >> "$WORK/order"; }'
    # 快照替身按**当前契约**接齐: 方案1 里前像由 cmd_snapshot 在打包之后保存并校验,
    # cmd_migrate 只确认。所以这里的替身必须真的产出 svcstate.tsv, 否则 cmd_migrate 会在
    # 确认那一步按契约拒绝 —— 那不是"顺序不对", 是现场没搭对。
    # 两个旋钮都**可控**, 不用恒真把安全门消掉:
    #   SNAP_RC=1   快照自己失败
    #   SNAP_NOPRE=1 快照成功但**不产出前像**(模拟前像缺失)
    #   PLAN_RC=1   前像在, 但确认不过
    echo 'cmd_snapshot(){ echo "SNAPSHOT" >> "$WORK/order"'
    echo '  [[ "${SNAP_RC:-0}" == 0 ]] || return "$SNAP_RC"'
    echo '  _PDG_SNAP_CREATED="$WORK/snap"; mkdir -p "$WORK/snap"'
    echo '  [[ "${SNAP_NOPRE:-0}" == 1 ]] || printf "modeled\n" > "$WORK/snap/svcstate.tsv"'
    echo '  return 0; }'
    # 确认替身: 产品调的就是它。**不是恒真** —— PLAN_RC 非 0 时如实失败并给出原因。
    echo '_pdg_svcstate_plan(){ echo "PLAN" >> "$WORK/order"'
    echo '  if [[ "${PLAN_RC:-0}" != 0 ]]; then _PDG_SVC_WHY="注入: 确认不过"; return "$PLAN_RC"; fi'
    echo '  return 0; }'
    echo 'need_root(){ :; }'
    echo '_lock(){ echo "LOCK" >> "$WORK/order"; }'
    echo 'c_g(){ :; }; c_y(){ :; }'
    echo '_tx_audit(){ echo "AUDIT:$3" >> "$WORK/order"; }'
    sed -n '/^# 5.1: \*\*取消命令分派前的隐藏迁移/,$p' "$ROOT/deploy/bot/pdg.sh" \
      | grep -v '^cmd_migrate(){' > /dev/null   # 分派段本身在下面整体取
    sed -n '/^cmd_migrate(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh"
    sed -n '/^case "\${1:-menu}" in/,/^esac/p' "$ROOT/deploy/bot/pdg.sh"
  } > "$WORK/disp.sh"
}
build
export WORK
# 退出码与执行有效性都要看得见: 只回顺序串的话, "壳自己炸了"与"产品按契约拒绝"没法区分。
# RUN_RC=被测退出码; RUN_ERR=stderr 落点。
RUN_ERR="$WORK/run.err"; RUN_RCF="$WORK/run.rc"
# 注意: 调用方都写成 out="$(run …)", 那是**命令替换子壳** —— 在里面给变量赋值,
# 外面读到的还是上一次的值(实测: 三个失败格都报 rc=0, 其实是健康那次留下的)。
# 所以退出码落盘, 由 rc() 从文件读。
run(){ : > "$WORK/order"; : > "$RUN_ERR"; rm -rf "$WORK/snap"
       local _rc=0; bash "$WORK/disp.sh" "$@" >/dev/null 2>"$RUN_ERR" || _rc=$?
       printf '%s' "$_rc" > "$RUN_RCF"
       tr '\n' ' ' < "$WORK/order" 2>/dev/null; }
rc(){ cat "$RUN_RCF" 2>/dev/null || echo "<未取得>"; }
# 执行有效性: 这三类症状一出现, 本格结论无效 —— 不许拿它们充当"预期拒绝"。
# (退役冻结点 18a8af0e 上这支就是这么"红"的: _pdg_save_svcstate 未定义 → 127,
#  产品照样打印"服务前像保存失败", 判据看上去在拒绝, 其实是壳没接线。)
_exec_ok(){ ! grep -qE 'command not found|未找到命令|unbound variable|syntax error' "$RUN_ERR"; }
_exec_why(){ grep -m1 -E 'command not found|未找到命令|unbound variable|syntax error' "$RUN_ERR" || echo "(无)"; }

out="$(run status)"
grep -q MIGRATE <<<"$out" && bad "status 触发了迁移: $out" || ok "pdg status 不触发迁移(只读语义)"
out="$(run restart)"
grep -q MIGRATE <<<"$out" && bad "restart 触发了迁移: $out" || ok "pdg restart 不触发迁移"
out="$(run menu)"
grep -q MIGRATE <<<"$out" && bad "menu 触发了迁移: $out" || ok "pdg 菜单不触发迁移"

# ── 3. 显式迁移: 锁 → 快照 → **前像确认** → 迁移 → 成功审计 ──
# 当前契约比旧版多了"确认"这一步(前像由快照保存, 迁移只确认)。四种现场分开验,
# 每一格都分别核: 被测退出码 / 事件顺序 / 执行有效性。
out="$(run migrate)"
if ! _exec_ok; then
  bad "3-健康: 壳自身出错, 本格无效: $(_exec_why)"
elif [[ "$out" == *"LOCK"*"SNAPSHOT"*"PLAN"*"MIGRATE"* ]]; then
  ok "pdg migrate: 锁 → 快照 → 前像确认 → 迁移(顺序正确; rc=$(rc))"
else
  bad "pdg migrate 顺序不对: $out(rc=$(rc))"
fi
[[ "$(rc)" == 0 ]] && ok "3-健康: 被测退出码 0" || bad "3-健康: 退出码 $(rc)"
grep -q 'AUDIT:COMMITTED' <<<"$out" && ok "pdg migrate 成功后写入审计" || bad "迁移没记审计: $out"

# 3a 快照自己失败 ⇒ 不进迁移、不记成功审计
out="$(SNAP_RC=1 run migrate)"
{ _exec_ok && [[ "$(rc)" != 0 ]] && ! grep -q MIGRATE <<<"$out" && ! grep -q 'AUDIT:COMMITTED' <<<"$out"; } \
  && ok "3a: 快照失败 ⇒ 退出码 $(rc), 不进迁移、不记成功审计($out)" \
  || bad "3a: 实得 rc=$(rc) order=[$out] 执行有效=$(_exec_ok && echo 是 || echo "否: $(_exec_why)")"
# 3b 快照成功但**前像缺失** ⇒ 同样拒绝
out="$(SNAP_NOPRE=1 run migrate)"
{ _exec_ok && [[ "$(rc)" != 0 ]] && ! grep -q MIGRATE <<<"$out" && ! grep -q 'AUDIT:COMMITTED' <<<"$out"; } \
  && ok "3b: 前像缺失 ⇒ 退出码 $(rc), 不进迁移、不记成功审计($out)" \
  || bad "3b: 实得 rc=$(rc) order=[$out] 执行有效=$(_exec_ok && echo 是 || echo "否: $(_exec_why)")"
# 3c 前像在但**确认不过** ⇒ 同样拒绝, 且确认这一步确实被调到
out="$(PLAN_RC=1 run migrate)"
{ _exec_ok && [[ "$(rc)" != 0 ]] && grep -q PLAN <<<"$out" \
  && ! grep -q MIGRATE <<<"$out" && ! grep -q 'AUDIT:COMMITTED' <<<"$out"; } \
  && ok "3c: 确认不过 ⇒ 退出码 $(rc), 确认被调到但不进迁移、不记成功审计($out)" \
  || bad "3c: 实得 rc=$(rc) order=[$out] 执行有效=$(_exec_ok && echo 是 || echo "否: $(_exec_why)")"

# ── 4. 内部入口 __migrate 仍然可用(cmd_update 装好新脚本后靠它跑新版迁移)──
out="$(run __migrate)"
{ _exec_ok && grep -q MIGRATE <<<"$out"; } \
  && ok "pdg __migrate 仍执行迁移(更新流程的内部入口)" \
  || bad "__migrate 不迁移了: [$out] 执行有效=$(_exec_ok && echo 是 || echo "否: $(_exec_why)")"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
