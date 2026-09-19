#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 桥接 × 退役**整合后**的接缝契约。
#
# 两条产品线在 v1.11.15 分叉后各自实现过一版"服务前像": 桥接线最终定案成**方案1**
# (cmd_snapshot 在打包之后保存并校验, update/platform/migrate 只确认); 退役线停在更早的
# "各消费者自己存"那一版。普通合并会把两套同名实现**同时**带进来 —— 那时 bash 用最后一个
# 定义, 于是"碰巧是哪一版"决定了产品行为, 而任何只抽第一份的测试都看不见这件事。
#
# 这一支就盯这道接缝, 只问结构与接线, 不重复各自线上已有的行为覆盖:
#   ① 前像那一组函数在文件里**只有一份**定义(逐个数, 不是抽一份看看能不能跑);
#   ② 保存责任**只有 cmd_snapshot 一处**; 三个消费者一次也不重新采样;
#   ③ 三个消费者的"确认"都排在各自第一处破坏性动作之前;
#   ④ 桥接侧带来的行为(分阶段重新校验 / 路径归一 / --to 贯穿 / dry-run 持锁)与
#      退役侧带来的行为(调用方门 / schema 迁移 / 平台失败恢复)都还在;
#   ⑤ 调用方门的 holder 判据**没有**为了迁就合并被改宽。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { echo "[未执行] 找不到 $PDG"; exit 1; }
fnline(){ grep -n "^$1(){" "$PDG" | cut -d: -f1; }   # 打印**全部**定义行号
fnbody(){ awk -v f="^$1\\\\(\\\\)\\\\{" '$0~f,/^\}/' "$PDG"; }

echo "══ 一. 前像函数只有一份定义 ══"
PRE_FNS=(_pdg_svcstate_units _pdg_svc_known _pdg_svc_q _pdg_save_svcstate _pdg_svcstate_valid
         _pdg_svcstate_plan _pdg_now_ac _pdg_now_en _pdg_set_enable_state _pdg_kernel_converge
         _pdg_restore_svcstate)
_dupn=0
for f in "${PRE_FNS[@]}"; do
  n="$(fnline "$f" | grep -c .)"
  if [[ "$n" == 1 ]]; then :; else
    bad "1: $f 有 $n 份定义(行: $(fnline "$f" | tr '\n' ' ')) —— bash 只认最后一份"; _dupn=$((_dupn+1))
  fi
done
[[ "$_dupn" == 0 ]] && ok "1: ${#PRE_FNS[@]} 个前像函数各自只有 1 份定义(逐个数过, 不靠'最后一个碰巧对')"
# 全文件层面再兜一次: 任何重复定义都不许有
_alldup="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$PDG" | sort | uniq -d)"
[[ -z "$_alldup" ]] && ok "1b: 整个 pdg.sh 没有任何重复函数定义" \
  || { bad "1b: 仍有重复定义"; sed 's/^/      /' <<<"$_alldup"; }
# 全局初始化也只该有一套
for g in 'declare -A _PDG_WANT_EN' '^_PDG_SVC_MODE=' '^_PDG_SVC_WHY=' '^_PDG_SVC_SRC='; do
  n="$(grep -cE "$g" "$PDG")"
  [[ "$n" == 1 ]] && ok "1c: 全局 ${g#^} 只初始化 1 次" || bad "1c: ${g#^} 初始化了 $n 次"
done

echo; echo "══ 二. 保存责任只有 cmd_snapshot 一处; 消费者不重新采样 ══"
_savecalls="$(grep -n '_pdg_save_svcstate' "$PDG" | grep -vE ':\s*#|^[0-9]+:_pdg_save_svcstate\(\)\{|c_y|echo' || true)"
_n="$(grep -c . <<<"${_savecalls:-}")"; [[ -z "$_savecalls" ]] && _n=0
[[ "$_n" == 1 ]] \
  && ok "2: 全文件只有 1 处调用 _pdg_save_svcstate($(cut -d: -f1 <<<"$_savecalls") 行)" \
  || { bad "2: 调用点有 $_n 处 —— 保存责任不唯一"; sed 's/^/      /' <<<"$_savecalls"; }
grep -q '_pdg_save_svcstate' <<<"$(fnbody cmd_snapshot)" \
  && ok "2a: 那一处就在 cmd_snapshot 里" || bad "2a: 保存不在 cmd_snapshot 里"
for c in cmd_update cmd_platform cmd_migrate; do
  if grep -q '_pdg_save_svcstate' <<<"$(fnbody "$c")"; then
    bad "2b: $c 里仍有 _pdg_save_svcstate —— 会覆盖掉动手之前那一刻的记录"
  else
    ok "2b: $c 里没有二次采样"
  fi
  grep -q '_pdg_svcstate_plan' <<<"$(fnbody "$c")" \
    && ok "2c: $c 确实**确认**了前像" || bad "2c: $c 没有确认前像"
done

echo; echo "══ 三. 确认排在各自第一处破坏性动作之前 ══"
# 顺序判据比**第一处**: 用最后一处的话, 在确认之前塞一处动作、把原来那处留在后面,
# 判据照样绿 —— 实测过, 三条顺序判据都能被这样绕过去。
# 另外"抽不到函数体"与"找不到目标动作"一律判红, 不许因为找不到而默认通过。
_before(){   # $1=函数 $2=破坏性动作的正则 $3=说明
  local b; b="$(fnbody "$1")"
  if [[ -z "$b" ]]; then bad "3: 抽不到 $1 的函数体 —— 这一条判据无效"; return; fi
  local pfirst dfirst
  pfirst="$(awk '/_pdg_svcstate_plan/{print NR; exit}' <<<"$b")"
  dfirst="$(awk -v pat="$2" '$0~pat{print NR; exit}' <<<"$b")"
  if [[ -z "$pfirst" ]]; then bad "3: $1 里根本没有前像确认 —— 判据无效"; return; fi
  if [[ -z "$dfirst" ]]; then bad "3: $1 里找不到目标动作($3) —— 判据失去依据, 不按通过记"; return; fi
  [[ "$pfirst" -lt "$dfirst" ]] \
    && ok "3: $1 的确认(第 $pfirst 行)排在**第一处** $3(第 $dfirst 行)之前" \
    || bad "3: $1 的确认在第 $pfirst 行, 而**第一处** $3 在第 $dfirst 行 —— 顺序不对"
}
_before cmd_update   'bash /usr/local/bin/pdg __migrate' '迁移子进程'
_before cmd_update   'install -m755'                      '第一处 install'
_before cmd_platform 'mktemp -d'                         '建工作区(第一处改动)'
_before cmd_migrate  'run_all_migrations'                'run_all_migrations'

echo; echo "══ 四. 两侧各自的修复都还在 ══"
_has(){ grep -qF -- "$2" "$PDG" && ok "4: $1" || bad "4: $1 —— 合并把它丢了"; }
# 限定到 cmd_rollback **内部**并核顺序: 全文件 grep 会被别处的同名赋值顶掉 ——
# 实测把 cmd_rollback 入口那处清缓存撤掉, 全文件判据照样绿。
_RB="$(fnbody cmd_rollback)"
if [[ -z "$_RB" ]]; then
  bad "4: 抽不到 cmd_rollback 的函数体 —— 这一条判据无效"
else
  _rb_clr="$(awk '/_PDG_SVC_SRC=""/{print NR; exit}' <<<"$_RB")"
  _rb_plan="$(awk '/_pdg_svcstate_plan "\$target"/{print NR; exit}' <<<"$_RB")"
  if [[ -z "$_rb_plan" ]]; then bad "4: cmd_rollback 里找不到 _pdg_svcstate_plan \"\$target\" —— 判据失去依据"
  elif [[ -z "$_rb_clr" ]]; then bad "4: 桥接: 回滚是独立校验阶段(强制重读前像)—— cmd_rollback 里没有清缓存那一句"
  elif [[ "$_rb_clr" -lt "$_rb_plan" ]]; then
    ok "4: 桥接: 回滚是独立校验阶段 —— cmd_rollback 在解析前像(第 $_rb_plan 行)之前先清了缓存(第 $_rb_clr 行)"
  else bad "4: 清缓存在第 $_rb_clr 行, 却排在解析(第 $_rb_plan 行)之后 —— 等于没清"; fi
fi
_has "桥接: 回滚目录路径表示归一(去尾斜杠)" 'while [[ "$target" == */ && "$target" != / ]]'
_has "桥接: 钉版目标贯穿到实际安装" '钉版目标已贯穿到实际安装'
_has "桥接: 快照缺前像的措辞只陈述事实" '这份快照没有服务前像(目录里缺 svcstate.tsv'
for f in _update_pin_resolve _update_pin_still _pdg_entry_src; do
  [[ "$(fnline "$f" | grep -c .)" == 1 ]] && ok "4: 桥接: $f 在(--to 整条能力)" || bad "4: 桥接: $f 缺失或重复"
done
for f in _retire_caller_gate migrate_wloc_retire _retire_ios_schema _plat_purge_retired; do
  [[ "$(fnline "$f" | grep -c .)" == 1 ]] && ok "4: 退役: $f 在" || bad "4: 退役: $f 缺失或重复"
done
# dry-run 仍持锁: 预览不是"只读看看", 它会写现役仓库的 FETCH_HEAD 与 refs/tags。
# 判据必须落在**那条分支内**、且锁排在**第一次取件之前** —— 只在整个 cmd_update 里
# grep 一个 _lock 的话, 执行路径那把锁会替 dry-run 顶包(实测撤掉 dry-run 的锁仍全绿)。
_UP="$(fnbody cmd_update)"
if [[ -z "$_UP" ]]; then
  bad "4: 抽不到 cmd_update 的函数体 —— dry-run 持锁判据无效"
else
  _dr="$(awk '/if \[\[ "\$\{1:-\}" == "--dry-run" \]\]; then/{print NR; exit}' <<<"$_UP")"
  if [[ -z "$_dr" ]]; then bad "4: cmd_update 里找不到 --dry-run 分支 —— 判据失去依据"
  else
    # 只认**真正的调用**: 注释里也提到 pdg_fetch_release_tags(解释为什么要上锁),
    # 把注释算进去的话锁永远"排在取件之后"。
    _fetch="$(awk -v s="$_dr" 'NR>s && $0 !~ /^ *#/ && /pdg_fetch_release_tags/{print NR; exit}' <<<"$_UP")"
    _lk="$(awk -v s="$_dr" 'NR>s && /^ *_lock *$/{print NR; exit}' <<<"$_UP")"
    if [[ -z "$_fetch" ]]; then bad "4: --dry-run 分支里找不到取件调用 —— 判据失去依据"
    elif [[ -z "$_lk" ]]; then bad "4: --dry-run 分支里没有 _lock —— 预览会在无锁状态下写现役仓库的 git 元数据"
    elif [[ "$_lk" -lt "$_fetch" ]]; then
      ok "4: 桥接: --dry-run 分支自己持锁(第 $_lk 行), 且排在第一次取件(第 $_fetch 行)之前"
    else bad "4: --dry-run 的锁在第 $_lk 行, 排在取件(第 $_fetch 行)之后 —— 取件那一刻还没上锁"; fi
  fi
fi

echo; echo "══ 五. 调用方门的 holder 判据没有被改宽 ══"
G="$(fnbody _retire_caller_gate)"
grep -q 'for cand in "\$\$" "\$PPID"' <<<"$G" \
  && ok "5: 门仍然只认**自己或直接调用方**($$ / \$PPID 两种真实调用形态)" \
  || bad "5: holder 判据被改了 —— 不许为了迁就合并放宽它"
grep -q 'holder_start' <<<"$G" && ok "5a: 仍然 pid + starttime 一起比(pid 会复用)" || bad "5a: starttime 判据没了"
grep -qiE 'FORCE|SKIP_|BYPASS|NOCHECK|UNSAFE' <<<"$G" \
  && { bad "5b: 门里出现了疑似旁路开关"; } || ok "5b: 门里没有 FORCE/SKIP/BYPASS 一类的旁路"
grep -q 'boot_id' <<<"$G" && ok "5c: 仍然核 boot_id(上次开机的残留记录不算数)" || bad "5c: boot_id 判据没了"

echo "────────────────────────────────────────"
echo "test-retire-bridge-integration.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
