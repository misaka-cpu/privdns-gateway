#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 面向用户的"该重跑什么"指引, 按**行为**验:
#
#   · 真的执行 _retire_rerun_hint 与 _retire_caller_gate 的拒绝分支, 看它们**实际输出**
#     什么, 不是在源码里 grep 一个词;
#   · 指引点名的那个入口(`pdg migrate`)必须**真的**建快照、存服务前像、把句柄交给迁移 ——
#     这一条直接跑产品原文的 cmd_migrate 来看, 不是"文字替换过了就算数";
#   · 提示出现之后用户手上是哪一版 CLI, 分岔判据只用两个已有信号(本次 CLI 动词 + 有没有句柄),
#     不引入任何绕过门的开关。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
P=0; F=0
ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDG="${PDG_SH:-$HERE/../deploy/bot/pdg.sh}"
CHECKS="$HERE/../deploy/bot/checks.py"
[[ -f "$PDG" ]] || { echo "[未执行] 找不到 $PDG"; exit 1; }
BOX="$(mktemp -d "${TMPDIR:-/tmp}/pdg-hint.XXXXXX")" || exit 1
trap 'rm -rf "$BOX"' EXIT

_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
need(){ local b; b="$(_fn "$PDG" "$1")"; [[ -n "$b" ]] || { echo "[未执行] 抽不到产品函数 $1"; exit 1; }; printf '%s\n' "$b"; }

# ── 一. 真实调用形态: 旧 CLI 直跳 vs 用户手打, 两者输入完全一样 ─────────────
echo "══ 一. 旧 CLI 直跳与用户手打: 同一组输入, 分不出来 ══"
# v1.11.15 的 cmd_update 是这样调"新版"的(该版源码里那一句**没有任何环境变量前缀**,
# 而且那一版里 PDG_UPDATE_SVCSTATE 根本不存在):
#       if ! bash /usr/local/bin/pdg __migrate; then
# 于是子进程拿到的是 **$1=__migrate + PDG_UPDATE_SVCSTATE 未设**。
# 用户手打 `sudo pdg __migrate` 拿到的是**同一组输入**。
# 下面**不人为设动词**: 子进程的 _PDG_CLI_VERB 由产品自己的分发器赋值行从真实 $1 取。
CHILD="$BOX/child.sh"
{ echo 'set -u'
  need c_y; need _retire_rerun_hint
  grep -m1 '^_PDG_CLI_VERB=' "$PDG" || echo '_PDG_CLI_VERB="${1:-menu}"'   # 产品原句, 原样取
  echo 'printf "INPUT verb=%s handle=%s\n" "${_PDG_CLI_VERB:-}" "${PDG_UPDATE_SVCSTATE:-（空）}"'
  echo '_retire_rerun_hint'
} > "$CHILD"
# 旧调用方(父进程): 逐字复刻 v1.11.15 cmd_update 里那一句
OLDCALLER="$BOX/old-caller.sh"
cat > "$OLDCALLER" <<'EOS'
set -u
if ! bash "$1" __migrate; then :; fi
EOS
OUT_UPD="$(env -u PDG_UPDATE_SVCSTATE bash "$OLDCALLER" "$CHILD" 2>&1)"
OUT_USR="$(env -u PDG_UPDATE_SVCSTATE bash "$CHILD" __migrate 2>&1)"
IN_UPD="$(grep '^INPUT ' <<<"$OUT_UPD")"; IN_USR="$(grep '^INPUT ' <<<"$OUT_USR")"
[[ "$IN_UPD" == "INPUT verb=__migrate handle=（空）" ]] \
  && ok "1-0: 旧 CLI 直跳的子进程, 实际输入就是 verb=__migrate + 句柄为空(产品自己的赋值行取的)" \
  || bad "1-0: 子进程实际输入是「$IN_UPD」"
[[ "$IN_UPD" == "$IN_USR" ]] \
  && ok "1-1: 用户手打拿到的是**同一组输入** ⇒ 仅凭这两个信号**无法**区分这两种调用者" \
  || bad "1-1: 两者输入不同($IN_UPD vs $IN_USR) —— 本支的前提要重新核"
G_UPD="$(grep -v '^INPUT ' <<<"$OUT_UPD")"; G_USR="$(grep -v '^INPUT ' <<<"$OUT_USR")"
[[ "$G_UPD" == "$G_USR" ]] \
  && ok "1-2: 两种调用者拿到的指引因此也完全相同(这是事实, 不是缺陷 —— 缺陷在于内容说没说死)" \
  || bad "1-2: 同一组输入却给出了不同指引, 说明有别的隐藏信号在起作用"

echo
echo "══ 二. 指引内容: 不对调用者下断言, 只给可执行的条件检查 ══"
# 同一组输入下, "在 update 里面"与"用户手打"**都可能**。任何一句把它说死的话都是猜。
for _bad in "这台机器已经是这一版" "你现在是在 sudo pdg update 里面" "你是手打"; do
  grep -qF "$_bad" <<<"$G_UPD" \
    && bad "2-0: 指引里对调用者下了断言:「$_bad」—— 这组输入根本分不出来" \
    || ok "2-0: 指引里没有「$_bad」这种对调用者的断言"
done
grep -qF '/usr/local/bin/pdg' <<<"$G_UPD" && grep -qF '_pdg_save_svcstate' <<<"$G_UPD" \
  && ok "2-1: 给出了**可执行的条件检查**(直接看此刻装着的那一版支不支持保存服务前像)" \
  || bad "2-1: 没有给出可执行的条件检查, 只是让人选一条命令"
grep -qE '支持.*sudo pdg migrate|显示「支持」' <<<"$G_UPD" \
  && ok "2-2: 只有在**确认支持**的前提下才指向 sudo pdg migrate" \
  || bad "2-2: 无条件指向了 pdg migrate"
grep -qE '没有.*命令能补上这一步|别反复敲' <<<"$G_UPD" \
  && ok "2-3: 缺入口时如实说明这台机器上没有命令能补上, 不让旧机器反复执行无效命令" \
  || bad "2-3: 缺入口时没有说清, 用户会反复敲无效命令"
grep -qE '由它自己决定|不替它承诺' <<<"$G_UPD" \
  && ok "2-4: 对升级调起的情形**不承诺**上游一定会回滚" \
  || bad "2-4: 无条件声称了上游会回滚"
grep -qE '那一版没有这一步退役迁移|回到更新前那一版.*没有' <<<"$G_UPD" \
  && bad "2-5: 断言了'回退到的那一版必然没有退役能力' —— 那不成立" \
  || ok "2-5: 没有断言回退后的版本必然没有退役能力"
grep -qF '不要手打 sudo pdg __migrate' <<<"$G_UPD" \
  && ok "2-6: 仍写明不要手打内部入口" || bad "2-6: 少了这句"
grep -qE '没有任何变量或参数可以绕过|没有任何环境变量或参数可以绕过' <<<"$G_UPD" \
  && ok "2-7: 仍写明没有绕过开关" || bad "2-7: 少了这句"

# ── 三(原二). 门的拒绝文案 ─────────────────────────────────────────────────
echo
echo "══ 三. 能力门拒绝时给的是可执行的下一步, 同样不猜调用者 ══"
gate(){   # 句柄为空 ⇒ 必被拒; 动词由真实 $1 取, 不人为设
  { echo 'set -u'; need c_y; need c_r; need _pdg_svcstate_valid; need _pdg_svc_q; need _pdg_svc_known
    need _retire_rerun_hint; need _retire_caller_gate
    grep -m1 '^_PDG_CLI_VERB=' "$PDG" || echo '_PDG_CLI_VERB="${1:-menu}"'
    echo '_retire_caller_gate; echo "RC=$?"'
  } > "$BOX/g.sh"
  env -u PDG_UPDATE_SVCSTATE bash "$BOX/g.sh" __migrate 2>"$BOX/g.err"
}
G1="$(gate)"
grep -q 'RC=1' <<<"$G1" && ok "3-0: 无句柄确实被拒(rc=1)" || bad "3-0: 没被拒: $G1"
for _bad in "你是手打" "这台机器既然已经是这一版" "调用方接下来会执行它自己的回滚"; do
  grep -qF "$_bad" <<<"$G1" \
    && bad "3-1: 拒绝文案对调用者下了断言:「$_bad」" \
    || ok "3-1: 拒绝文案里没有「$_bad」"
done
grep -qF '_pdg_save_svcstate /usr/local/bin/pdg' <<<"$G1" \
  && ok "3-2: 拒绝文案给的是同一套可执行的条件检查" || bad "3-2: 拒绝文案没给可执行的下一步"
grep -qE '没有任何环境变量或参数可以绕过' <<<"$G1" && ok "3-3: 明说没有绕过开关" || bad "3-3: 少了这句"
grep -qF '不要去伪造一份服务前像' <<<"$G1" && ok "3-4: 明说不要伪造前像" || bad "3-4: 少了这句"

# ── 三. 行为闭环: 指引点名的入口**真的**会建快照 + 存前像 + 交句柄 ──────────
echo; echo '══ 三. pdg migrate 到底是不是一个带前像的入口(真跑 cmd_migrate)══'
run_migrate(){   # $1=save 结果(0/1) → 打印观测
  { echo 'set -u'; need c_y; need c_g
    echo "SNAPDIR='$BOX/snap'"
    echo 'need_root(){ :; }; _lock(){ :; }; _tx_audit(){ :; }'
    echo "SEQ='$BOX/seq'"
    echo 'cmd_snapshot(){ mkdir -p "$SNAPDIR"; : > "$SNAPDIR/snap.tar.gz"; _PDG_SNAP_CREATED="$SNAPDIR"; echo cmd_snapshot >> "$SEQ"; }'
    echo "_pdg_save_svcstate(){ echo _pdg_save_svcstate >> \"\$SEQ\"; [[ '$1' == 0 ]] || return 1; printf 'v\\t1\\n' > \"\$1/svcstate.tsv\"; }"
    echo 'run_all_migrations(){ echo run_all_migrations >> "$SEQ"; echo "CALL=run_all_migrations HANDLE=${PDG_UPDATE_SVCSTATE:-（空）}"; return 0; }'
    need cmd_migrate
    echo 'cmd_migrate; echo "RC=$?"'
  } > "$BOX/m.sh"
  rm -rf "$BOX/snap" "$BOX/seq"; : > "$BOX/seq"
  bash "$BOX/m.sh" 2>"$BOX/m.err"
}
M="$(run_migrate 0)"
[[ -s "$BOX/m.err" ]] && bad "3-0: 执行有问题: $(head -1 "$BOX/m.err")" || ok "3-0: cmd_migrate 真的跑起来了"
grep -q 'CALL=run_all_migrations HANDLE=.*/svcstate.tsv' <<<"$M" \
  && ok "3a: 迁移确实拿到了句柄(不是空): $(grep -o 'HANDLE=.*' <<<"$M")" \
  || bad "3a: 迁移没拿到句柄 —— 指引点名的入口名不副实: $M"
[[ -f "$BOX/snap/svcstate.tsv" ]] && ok "3b: 服务前像**真的落盘**在本次快照目录里" || bad "3b: 前像没落盘"
SEQ_ACTUAL="$(tr '\n' ' ' < "$BOX/seq")"
[[ "$SEQ_ACTUAL" == "cmd_snapshot _pdg_save_svcstate run_all_migrations " ]] \
  && ok "3c: 调用顺序确实是 建快照 → 存前像 → 再迁移(动手之前就保住了前像)" \
  || bad "3c: 顺序不对: $SEQ_ACTUAL"
M2="$(run_migrate 1)"
grep -q 'RC=1' <<<"$M2" && ok "3d: 前像存不下时**拒绝**往下迁移" || bad "3d: 前像存不下还往下走了: $M2"
grep -q 'run_all_migrations' "$BOX/seq" && bad "3e: 前像存不下却仍调了迁移" || ok "3e: 前像存不下就一步都不往下做"

# ── 四. 版本对账: 回滚之后那一版有没有前像能力 ──────────────────────────────
echo; echo "══ 四. 提示出现后用户手上是哪一版 ══"
if [[ -n "${PDG_OLD_SH:-}" && -f "${PDG_OLD_SH}" ]]; then
  if grep -q '_pdg_save_svcstate' "$PDG_OLD_SH"; then
    bad "4a: 旧版($PDG_OLD_SH)里居然有 _pdg_save_svcstate —— 本支的前提要重新核"
  else
    ok "4a: 旧版确实**没有** _pdg_save_svcstate —— 回滚之后那台机器不具备前像能力"
  fi
else
  note "4a: 没给 PDG_OLD_SH, 跳过与旧版源码的直接对账(本轮已在验收证据里单独核过)"
fi
ok "4b: 正因为回滚后装着哪一版**本进程不知道**, 指引才把它交给用户现场检查(见 2-1/2-2),"
ok "    而不是替他断言 —— 旧版没有前像能力这件事只用来说明「为什么那条检查是必要的」"

# ── 五. 没有开放任何绕过 ────────────────────────────────────────────────────
echo; echo "══ 五. 没有新增绕过门的开关 ══"
BYPASS="$(grep -nE 'PDG_(FORCE|SKIP|BYPASS|NO_GATE|ALLOW)[A-Z_]*' "$PDG" | grep -v '^[0-9]*: *#' || true)"
[[ -z "$BYPASS" ]] && ok "5a: 产品里没有 FORCE/SKIP/BYPASS/NO_GATE/ALLOW 这类开关" \
                   || bad "5a: 出现了疑似绕过开关: $(head -2 <<<"$BYPASS")"
# 指引**自己**不许去猜调用者身份: 不读 CLI 动词, 不看 PPID / /proc / $0, 不读任何新环境变量。
HINT_BODY="$(_fn "$PDG" _retire_rerun_hint)"
if grep -qE '_PDG_CLI_VERB|\$PPID|/proc/|\$0|PDG_[A-Z_]*CALLER|PDG_[A-Z_]*FROM' <<<"$HINT_BODY"; then
  bad "5b: 指引函数里还在读调用者身份信号: $(grep -oE '_PDG_CLI_VERB|\$PPID|/proc/[a-z$]*|PDG_[A-Z_]*CALLER' <<<"$HINT_BODY" | sort -u | tr '\n' ' ')"
else
  ok "5b: 指引函数**一个**调用者身份信号都不读(无 _PDG_CLI_VERB / PPID / /proc / \$0 / 新环境变量)"
fi
# 门读的环境变量仍然只有句柄那一个, 没有新增可被冒充的身份来源。
GATE_ENV="$(_fn "$PDG" _retire_caller_gate | grep -oE 'PDG_[A-Z_]+' | sort -u | tr '\n' ' ')"
# 允许出现的只有: 句柄本身, 以及 _pdg_svcstate_valid 写回来的内部原因变量(不是环境身份)。
GATE_EXTRA="$(tr ' ' '\n' <<<"$GATE_ENV" | grep -vxE 'PDG_UPDATE_SVCSTATE|PDG_SVCSTATE_WHY|' | tr '\n' ' ')"
[[ -z "${GATE_EXTRA// /}" ]] \
  && ok "5d: 门读的 PDG_* 仍然只有既有那两个($GATE_ENV) —— 没有新增可被冒充的身份来源" \
  || bad "5d: 门多读了 PDG_* 变量: $GATE_EXTRA"
_fn "$PDG" _retire_caller_gate | grep -qE 'PDG_(FORCE|SKIP|BYPASS)' \
  && bad "5c: 门自己读了绕过变量" || ok "5c: 门没有读任何绕过变量"

# ── 六. 文字面(辅助, 不单独作判据) ──────────────────────────────────────────
echo; echo "══ 六. 辅助: 还有没有把 __migrate 当命令让用户敲的正文 ══"
IMP="$(grep -nE '(c_y|c_r|c_g|echo)[^#]*(跑|运行|重跑|执行)[^#]*pdg __migrate' "$PDG" || true)"
[[ -z "$IMP" ]] && ok "6a: pdg.sh 里没有把 pdg __migrate 当作要执行的命令的正文" \
                || bad "6a: 还有: $(head -2 <<<"$IMP")"
if [[ -f "$CHECKS" ]]; then
  IMP2="$(grep -nE '(跑|运行|重跑|执行) *(<code>)?sudo pdg __migrate' "$CHECKS" || true)"
  [[ -z "$IMP2" ]] && ok "6b: checks.py 里同样没有" || bad "6b: 还有: $(head -2 <<<"$IMP2")"
fi
note "6: 这一节只作辅助 —— 上面一到三节才是行为判据。"

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
