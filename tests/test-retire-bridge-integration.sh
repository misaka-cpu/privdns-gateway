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
_before(){   # $1=函数 $2=破坏性动作的正则 $3=说明
  local b; b="$(fnbody "$1")"
  awk -v pat="$2" '/_pdg_svcstate_plan/{p=NR} $0~pat{d=NR} END{exit !(p&&d&&p<d)}' <<<"$b" \
    && ok "3: $1 的确认排在 $3 之前" || bad "3: $1 的确认没有排在 $3 之前"
}
_before cmd_update   'bash /usr/local/bin/pdg __migrate' '迁移子进程'
_before cmd_update   'install -m755'                      '第一处 install'
_before cmd_platform 'mktemp -d'                         '建工作区(第一处改动)'
_before cmd_migrate  'run_all_migrations'                'run_all_migrations'

echo; echo "══ 四. 两侧各自的修复都还在 ══"
_has(){ grep -qF -- "$2" "$PDG" && ok "4: $1" || bad "4: $1 —— 合并把它丢了"; }
_has "桥接: 回滚是独立校验阶段(强制重读前像)" '_PDG_SVC_SRC=""'
_has "桥接: 回滚目录路径表示归一(去尾斜杠)" 'while [[ "$target" == */ && "$target" != / ]]'
_has "桥接: 钉版目标贯穿到实际安装" '钉版目标已贯穿到实际安装'
_has "桥接: 快照缺前像的措辞只陈述事实" '这份快照没有服务前像(目录里缺 svcstate.tsv'
for f in _update_pin_resolve _update_pin_still _pdg_entry_src; do
  [[ "$(fnline "$f" | grep -c .)" == 1 ]] && ok "4: 桥接: $f 在(--to 整条能力)" || bad "4: 桥接: $f 缺失或重复"
done
for f in _retire_caller_gate migrate_wloc_retire _retire_ios_schema _plat_purge_retired; do
  [[ "$(fnline "$f" | grep -c .)" == 1 ]] && ok "4: 退役: $f 在" || bad "4: 退役: $f 缺失或重复"
done
# dry-run 仍持锁: 预览不是"只读看看", 它会取件并动现役仓库的 ref
grep -q '_lock' <<<"$(fnbody cmd_update)" && ok "4: cmd_update(含 --dry-run 预览)仍在锁内" || bad "4: cmd_update 不再持锁"

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
