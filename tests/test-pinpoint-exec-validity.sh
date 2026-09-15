#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 定点验收脚本**自身的执行有效性**: 计数、汇总、退出码必须一致。
# 不需要 root, 不需要 systemd —— 它驱动的是真实的加载顺序与收尾骨架, 不是复刻一份。
#
# 要堵的洞是实打实发生过的(run 34927398571): 脚本先自定义 ok/bad(记 P/F), **之后**才
# source e2e-lib.sh, 而后者重定义 ok/bad 改记 E2E_PASS/E2E_FAIL。于是 source 之后的每一条
# 断言都不进 P/F, 末尾 `[[ "$F" == 0 ]]` 只看见 source 之前那两条 → 日志里 6 条 [FAIL],
# GitHub 上却是 success。
#
# 判据全部落在**真跑**上: 用被测脚本自己的骨架(ok/bad 定义、source 那一行、汇总与退出码)
# 拼出小脚本执行, 看最终失败数与退出码。不检查"源文件里用了哪个变量名"。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
P=0; F=0
ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TGT="${PDG_PINPOINT_SH:-$HERE/e2e-dns-instrument-systemd.sh}"
[[ -f "$TGT" ]] || { echo "[未执行] 找不到 $TGT"; exit 1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/pexec.XXXXXX")"; trap 'rm -rf "$W"' EXIT

_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }

# ── 骨架取自**被测脚本原文** ────────────────────────────────────────────────
# 计数来源那几行: 它自己怎么定义 ok/bad(有就取)、怎么 source 夹具、怎么汇总。
SRC_OKBAD="$(grep -E '^(ok|bad)\(\)\{' "$TGT" || true)"
SRC_PF="$(grep -E '^P=0; F=0$' "$TGT" || true)"
# 取它**加载夹具那一行**的原文; 后面的 `|| _hard …` 之类去掉(小脚本里没有那些函数)。
SRC_SOURCE="$(grep -E '^(source|\. )' "$TGT" | grep e2e-lib | head -1 | sed 's/ *|| .*$//' || true)"
SRC_TAIL="$(grep -E '^echo "通过 \$|^\[\[ "\$F" == 0 \]\]$' "$TGT" || true)"
VERDICT="$(_fn "$TGT" _final_verdict)"
ONEXIT="$(_fn "$TGT" on_exit)"
TRAPLINE="$(grep -E '^trap .*on_exit.* EXIT' "$TGT" | head -1 || true)"
[[ -n "$SRC_SOURCE" ]] || { echo "[未执行] 在 $TGT 里找不到 source e2e-lib.sh 那一行"; exit 1; }
note "被测脚本的 source 行: $SRC_SOURCE"
[[ -n "$VERDICT" ]] && note "被测脚本有 _final_verdict(新骨架)" || note "被测脚本没有 _final_verdict(旧骨架: 直接 echo 通过/失败)"

# 拼一个小脚本: 严格按被测脚本的顺序装配 —— 自定义计数器(若有) → source 夹具 → 断言 → 汇总。
build(){   # $1=输出路径 $2=source 之后要跑的断言片段 [$3=source 之前的断言片段]
  {
    echo 'set -uo pipefail'
    echo "HERE='$ROOT/tests'; E2E_ROOT='$ROOT'"
    [[ -n "$SRC_PF" ]] && echo "$SRC_PF"
    [[ -n "$SRC_OKBAD" ]] && printf '%s\n' "$SRC_OKBAD"
    printf '%s\n' "${3:-}"
    printf '%s\n' "$SRC_SOURCE"
    if [[ -n "$VERDICT" ]]; then
      # 收尾这一段整体取自被测脚本: _final_verdict + on_exit + 那一行 trap。
      # 少了 trap, "中途退出"这一格就测不到真东西(小脚本会直接跑掉)。
      echo 'CLEANUP_RC=-1; REACHED_END=0'
      echo '_cleanup(){ CLEANUP_RC=0; return 0; }'
      printf '%s\n' "$VERDICT"
      printf '%s\n' "$ONEXIT"
      printf '%s\n' "$TRAPLINE"
    fi
    printf '%s\n' "$2"
    if [[ -n "$VERDICT" ]]; then echo 'REACHED_END=1'
    else printf '%s\n' "$SRC_TAIL"; fi
  } > "$1"
}
run(){ bash "$1" > "$W/out" 2>&1; echo $?; }
tally(){ grep -oE '通过 [0-9]+, 失败 [0-9]+' "$W/out" | tail -1; }
seen_fail(){ grep -c '^\[FAIL\]' "$W/out"; }

echo "══ 1. 加载夹具**之后**产生一条具名失败 → 失败数非零 + 退出码非零 ══"
build "$W/c1.sh" 'bad "夹具加载之后的一条真失败"'
RC="$(run "$W/c1.sh")"
T="$(tally)"; SF="$(seen_fail)"
{ [[ "$RC" != 0 ]] && [[ "$T" != *"失败 0"* ]]; } \
  && ok "1a: 退出码非零($RC)且汇总里失败数非零($T)" \
  || { bad "1a: 退出码=$RC 汇总=$T —— 日志里有 $SF 条 [FAIL] 却没进汇总"; sed 's/^/      /' "$W/out"; }
[[ "$SF" -ge 1 ]] && ok "1b: 日志里确实打出了 $SF 条 [FAIL](不是没发生)" || bad "1b: 一条 [FAIL] 都没打"

echo; echo "══ 2. 前段已有失败, 后段健康执行不能把它清掉 ══"
build "$W/c2.sh" 'bad "先失败一条"
ok "后面一切正常"
ok "再来一条正常"' 
RC="$(run "$W/c2.sh")"; T="$(tally)"
{ [[ "$RC" != 0 ]] && [[ "$T" != *"失败 0"* ]]; } \
  && ok "2a: 后面的健康断言没有把前面的失败洗掉($T, 退出码 $RC)" \
  || { bad "2a: 失败被清掉了 —— 汇总=$T 退出码=$RC"; sed 's/^/      /' "$W/out"; }

echo; echo "══ 3. 健康路径: 有实际断言 + 有效汇总 + 返回零 ══"
build "$W/c3.sh" 'ok "健康断言一"
ok "健康断言二"'
RC="$(run "$W/c3.sh")"; T="$(tally)"
{ [[ "$RC" == 0 ]] && [[ "$T" == *"失败 0"* ]] && [[ "$T" != "通过 0, 失败 0" ]]; } \
  && ok "3a: 健康路径返回 0 且汇总有实际断言($T)" || { bad "3a: 退出码=$RC 汇总=$T"; sed 's/^/      /' "$W/out"; }

echo; echo "══ 4. 执行异常 / 缺失汇总 / 零断言都不能冒充通过 ══"
# 4a 零断言
build "$W/c4a.sh" ':'
RC="$(run "$W/c4a.sh")"; T="$(tally)"
[[ "$RC" != 0 ]] && ok "4a: 零断言判非零($T)" || { bad "4a: 零断言居然返回 0($T)"; sed 's/^/      /' "$W/out"; }
# 4b 执行异常: 断言跑到一半进程退出
build "$W/c4b.sh" 'ok "跑了一条"
exit 0'
RC="$(run "$W/c4b.sh")"
[[ "$RC" != 0 ]] && ok "4b: 中途 exit 0(没走到收尾)判非零" || { bad "4b: 中途退出被当成通过"; sed 's/^/      /' "$W/out"; }
# 4c 缺失汇总: 把收尾整段拿掉
{ echo 'set -uo pipefail'; echo "HERE='$ROOT/tests'; E2E_ROOT='$ROOT'"
  [[ -n "$SRC_PF" ]] && echo "$SRC_PF"; [[ -n "$SRC_OKBAD" ]] && printf '%s\n' "$SRC_OKBAD"
  printf '%s\n' "$SRC_SOURCE"; echo 'bad "有一条真失败, 但下面不打汇总"'; } > "$W/c4c.sh"
RC="$(run "$W/c4c.sh")"; T="$(tally)"
{ [[ -z "$T" ]] && [[ "$RC" == 0 ]]; } \
  && ok "4c: 复现了'缺汇总 ⇒ 退出码 0'这种假绿形态(所以汇总不能少 —— 被测脚本用 EXIT trap 保证它一定跑)" \
  || note "4c: 缺汇总时退出码=$RC 汇总=${T:-无}"
# 被测脚本必须靠 trap 保证汇总一定发生
grep -qE '^trap .*on_exit.* EXIT' "$TGT" \
  && ok "4d: 被测脚本用 EXIT trap 兜住收尾与汇总(中途退出也会算账)" \
  || bad "4d: 被测脚本没有用 EXIT trap 兜住汇总"

echo; echo "══ 5. 预期失败的负控独立计账, 不清零也不覆盖之前的真实失败 ══"
build "$W/c5.sh" 'bad "一条**真**失败"
# 负控: 在子 shell 里跑一段"预期会失败"的东西 —— 它的 ok/bad 不该影响主计数
( bad "负控里的预期失败"; bad "负控里的第二条" ) > /dev/null 2>&1
ok "负控之后继续"'
RC="$(run "$W/c5.sh")"; T="$(tally)"
{ [[ "$RC" != 0 ]] && [[ "$T" == *"失败 1"* ]]; } \
  && ok "5a: 负控的两条预期失败没有进主计数, 而之前那条真失败还在($T)" \
  || { bad "5a: 汇总=$T 退出码=$RC —— 负控污染了主计数或把真失败洗掉了"; sed 's/^/      /' "$W/out"; }
grep -qE '^\s*\(\s*dns_verdict|negctl\(\)\{' "$TGT" \
  && ok "5b: 被测脚本里的负控确实跑在子 shell 里" || bad "5b: 被测脚本的负控没有隔离"

echo; echo "══ 6. 收尾失败必须影响最终退出状态(不能先打印全通过再由 trap 静默失败)══"
# 让 _cleanup 返回 1, 其余一切健康 —— 最终必须非零, 且汇总里能看出是收尾的问题。
{ echo 'set -uo pipefail'; echo "HERE='$ROOT/tests'; E2E_ROOT='$ROOT'"
  [[ -n "$SRC_PF" ]] && echo "$SRC_PF"; [[ -n "$SRC_OKBAD" ]] && printf '%s\n' "$SRC_OKBAD"
  printf '%s\n' "$SRC_SOURCE"
  echo 'CLEANUP_RC=-1; REACHED_END=0'
  echo '_cleanup(){ echo "[FAIL] 收尾: 造出来的收尾失败"; CLEANUP_RC=1; return 1; }'
  printf '%s\n' "$VERDICT"; printf '%s\n' "$ONEXIT"; printf '%s\n' "$TRAPLINE"
  echo 'ok "正常断言一"'; echo 'ok "正常断言二"'; echo 'REACHED_END=1'
} > "$W/c6.sh"
RC="$(run "$W/c6.sh")"; T="$(tally)"
if [[ -n "$VERDICT" ]]; then
  { [[ "$RC" != 0 ]] && [[ "$T" != *"失败 0"* ]]; } \
    && ok "6a: 断言全绿但收尾失败 ⇒ 最终仍判非零($T, 退出码 $RC)" \
    || { bad "6a: 收尾失败被吞了 —— 汇总=$T 退出码=$RC"; sed 's/^/      /' "$W/out"; }
  grep -q '收尾' "$W/out" && ok "6b: 汇总里能看出是收尾的问题" || bad "6b: 汇总没提收尾"
else
  note "6: 旧骨架没有 _final_verdict, 这一格无从谈起(它本来就不把收尾计入)"
  bad "6a: 旧骨架不把收尾结果计入最终判定"
fi

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
