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

# ── 一. 指引按入口分岔(真的跑那个函数) ──────────────────────────────────────
echo "══ 一. 重跑指引按用户实际入口分岔 ══"
hint(){   # $1=CLI 动词 $2=句柄(空=没有) → 打印实际输出
  { echo 'set -u'; need c_y; need _retire_rerun_hint
    echo "_PDG_CLI_VERB='$1'"
    [[ -n "$2" ]] && echo "PDG_UPDATE_SVCSTATE='$2'" || echo "unset PDG_UPDATE_SVCSTATE 2>/dev/null || true"
    echo '_retire_rerun_hint'
  } > "$BOX/h.sh"
  bash "$BOX/h.sh" 2>"$BOX/h.err"
}

OUT="$(hint __migrate /var/lib/privdns-gateway/backups/x/svcstate.tsv)"
[[ -s "$BOX/h.err" ]] && bad "1-0: 执行有问题: $(head -1 "$BOX/h.err")" || ok "1-0: 指引函数真的跑起来了(无未定义调用)"
grep -q 'sudo pdg update' <<<"$OUT" \
  && ok "1a(update 内): 指向重新跑 sudo pdg update" || bad "1a: 没有指向 sudo pdg update — 实得: $OUT"
grep -q '回到更新前那一版' <<<"$OUT" \
  && ok "1b(update 内): 说清了回滚之后机器停在哪一版" || bad "1b: 没有说明回滚后停在哪一版"
grep -qE '跑 \*\*sudo pdg migrate\*\*|处理掉上面的原因之后跑 \*\*sudo pdg migrate' <<<"$OUT" \
  && bad "1c(update 内): 让一台**即将回滚回旧版**的机器去跑只有新版才有的 pdg migrate" \
  || ok "1c(update 内): **没有**让用户依赖仅新版才具有的能力"

for v in migrate platform; do
  OUT="$(hint "$v" /var/lib/privdns-gateway/backups/x/svcstate.tsv)"
  grep -q 'sudo pdg migrate' <<<"$OUT" \
    && ok "1d($v): 指向受支持的公开入口 sudo pdg migrate" || bad "1d($v): 没指向 sudo pdg migrate"
  grep -q '重新跑 sudo pdg update' <<<"$OUT" \
    && bad "1e($v): 机器已经是这一版, 却让他重新 update" || ok "1e($v): 没有错指成 update"
done

OUT="$(hint __migrate "")"
grep -q 'sudo pdg migrate' <<<"$OUT" \
  && ok "1f(手打 __migrate): 指向 sudo pdg migrate" || bad "1f: 没指向 sudo pdg migrate"

for c in "__migrate|/x/svcstate.tsv" "migrate|" "platform|" "__migrate|"; do
  v="${c%%|*}"; h="${c##*|}"
  grep -q '不要手打 sudo pdg __migrate' <<<"$(hint "$v" "$h")" \
    || { bad "1g($v): 少了「不要手打 __migrate」的说明"; continue; }
done
ok "1g: 四种入口的指引里都写明了不要手打 sudo pdg __migrate"

# ── 二. 门的拒绝文案 ────────────────────────────────────────────────────────
echo; echo "══ 二. 能力门拒绝时给的是可执行的下一步 ══"
gate(){   # $1=CLI 动词 → 打印拒绝输出(句柄为空 ⇒ 必被拒)
  { echo 'set -u'; need c_y; need c_r; need _pdg_svcstate_valid; need _pdg_svc_q; need _pdg_svc_known
    need _retire_caller_gate
    echo "_PDG_CLI_VERB='$1'"; echo 'unset PDG_UPDATE_SVCSTATE 2>/dev/null || true'
    echo '_retire_caller_gate; echo "RC=$?"'
  } > "$BOX/g.sh"
  bash "$BOX/g.sh" 2>"$BOX/g.err"
}
G1="$(gate __migrate)"
grep -q 'RC=1' <<<"$G1" && ok "2-0: 无句柄确实被拒(rc=1)" || bad "2-0: 没被拒: $G1"
grep -q 'sudo pdg migrate' <<<"$G1" \
  && ok "2a(手打 __migrate): 拒绝文案给出了受支持的入口" || bad "2a: 拒绝文案没给可执行的下一步"
G2="$(gate update)"
grep -q '回到调用方原来那一版' <<<"$G2" \
  && ok "2b(旧 CLI 直跳): 说清回滚之后机器回到哪一版" || bad "2b: 没说明回滚后停在哪一版"
grep -q '当前安装路径上还没有它' <<<"$G2" \
  && ok "2c(旧 CLI 直跳): 如实说明所需入口**尚不可用**, 没有宣称安装路径已经能用" \
  || bad "2c: 没有如实说明所需入口尚不可用"
grep -qE '没有任何环境变量或参数可以绕过' <<<"$G1$G2" \
  && ok "2d: 明说没有绕过开关" || bad "2d: 没有这句说明"
grep -q '不要去伪造一份服务前像' <<<"$G1$G2" \
  && ok "2e: 明说不要伪造前像(并说明门验的是归属而不是存在)" || bad "2e: 没有这句说明"

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
ok "4b: 因此 update 内那一支只指向 sudo pdg update(见 1c), 不指望回滚后的机器有新版能力"

# ── 五. 没有开放任何绕过 ────────────────────────────────────────────────────
echo; echo "══ 五. 没有新增绕过门的开关 ══"
BYPASS="$(grep -nE 'PDG_(FORCE|SKIP|BYPASS|NO_GATE|ALLOW)[A-Z_]*' "$PDG" | grep -v '^[0-9]*: *#' || true)"
[[ -z "$BYPASS" ]] && ok "5a: 产品里没有 FORCE/SKIP/BYPASS/NO_GATE/ALLOW 这类开关" \
                   || bad "5a: 出现了疑似绕过开关: $(head -2 <<<"$BYPASS")"
GATE_BODY="$(_fn "$PDG" _retire_caller_gate | grep -vE '^\s*c_[yrg] ' | sha256sum | cut -c1-16)"
note "5b: _retire_caller_gate 去掉文案行之后的判据指纹 = $GATE_BODY (本轮只改文案, 判据未动)"
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
