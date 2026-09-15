#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 平台真实验收里"准备动作不要污染被测过程"这一段的**判定契约**。
# 跑的是 tests/e2e-real-platform-fail.sh 里那几个函数的**原文**
# (_j_mark / _j_starts_after / _j_tag_after / _j_interval / _dur2s_real /
#  startlimit_inventory / quiesce_startlimit / phase_report), 不抄一份。
#
# ⚠️ **模型验证**: journalctl / logger / systemctl / date / sleep 是桩, 真 journal 没参与。
#    桩不是"直接给最终条数"的那种 —— 它维护一份**事件簿**并认 --after-cursor / --since /
#    --until / -o json, 所以被测代码真的要自己去取界桩、查询、解析、算区间。
#    真 journal 那一半由一次性 runner 上的真实派发与自有标记核验回答, 两类证据分列。
#
# 为什么有这一支: run 34960827400 两个方向都栽在同一处 —— 边界取 `date +秒`,
# 而 `journalctl --since` 秒级且含边界, 标定末尾的重启落在同一秒里被算进了静置窗口。
# 修法是改用**自有标记自身的 journal 游标**当界桩, 不是放宽判据。
# ─────────────────────────────────────────────────────────────────────────────
# 注: 本支有一批全局变量是给 eval 进来的被测函数读的(SL_INT_S / DIR / EVID …);
# 静态检查器看不到它们的用处, 所以整支关掉 SC2034, 只关这一条。
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/e2e-real-platform-fail.sh"
CI="$HERE/../.github/workflows/ci.yml"
[[ -f "$SRC" ]] || { echo "[未执行] 找不到 $SRC"; exit 1; }
WORK="$(mktemp -d)" || { echo "[未执行] 建不出临时目录"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

P=0; F=0
ok(){  printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }
_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }

for f in _dur2s_real startlimit_inventory quiesce_startlimit phase_report \
         _j_mark _j_starts_after _j_tag_after _j_interval _j_fail _j_why; do
  b="$(_fn "$SRC" "$f")"; [[ -n "$b" ]] || { echo "[未执行] 抽不到 $f"; exit 1; }
done
ok "0: 被测函数全部从平台验收脚本**原文**抽到(不是本支自己写的一份)"
eval "$(grep -m1 '^STARTLIMIT_CAP=' "$SRC")"
[[ "${STARTLIMIT_CAP:-}" =~ ^[1-9][0-9]*$ ]] \
  && ok "0b: 静置上限也取自原文(STARTLIMIT_CAP=${STARTLIMIT_CAP}s, 有限正整数)" \
  || { echo "[未执行] 原文里读不到 STARTLIMIT_CAP"; exit 1; }

# ── 事件簿桩与 runner(内嵌; 运行时落到 $WORK)────────────────────────────────
STUBSH="$WORK/stubs.sh"; RUNSH="$WORK/runner.sh"
cat > "$STUBSH" <<'STUBS_EOF'
# 生成一组**游标感知**的桩到 $BIN, 事件簿在 $FIX(idx<TAB>ts<TAB>ident<TAB>message)
mk_stubs(){
  mkdir -p "$BIN"
  cat > "$BIN/journalctl" <<'EOS'
#!/usr/bin/env bash
# 模型 journalctl: 认 -u/-t/--after-cursor/--since/--until/-n/--show-cursor/-o/--sync
[[ "${J_FAIL:-0}" == 1 ]] && { echo "模型: journalctl 故意失败" >&2; exit 13; }
FIX="${FIXTURE}"; unit=""; tag=""; after=""; since=""; until_=""; n=""; showcur=0; fmt="short"
while (( $# )); do
  case "$1" in
    --sync) exit 0;;
    -u) unit="$2"; shift 2;;
    -t) tag="$2"; shift 2;;
    --after-cursor) after="$2"; shift 2;;
    --since) since="$2"; shift 2;;
    --until) until_="$2"; shift 2;;
    -n) n="$2"; shift 2;;
    --show-cursor) showcur=1; shift;;
    -o) fmt="$2"; shift 2;;
    --output-fields=*) shift;;
    --no-pager) shift;;
    *) shift;;
  esac
done
[[ "${J_FAIL_UNIT:-0}" == 1 && -n "$unit" ]] && { echo "模型: 按 unit 的查询故意失败" >&2; exit 13; }
aidx=0
if [[ -n "$after" ]]; then
  aidx="$(awk -F'\t' -v c="$after" '$1=="" {next} {if ("cur-"$1==c) {print $1; exit}}' "$FIX")"
  [[ -n "$aidx" ]] || aidx=0        # 未知游标: 与真 journalctl 一致, 不报错, 从头给
fi
out="$(awk -F'\t' -v u="$unit" -v t="$tag" -v a="$aidx" -v s="$since" -v e="$until_" '
  NF<4 {next}
  { idx=$1; ts=$2; id=$3; msg=$4 }
  (u!="" && id!=u) {next}
  (t!="" && id!=t) {next}
  (a!="" && idx+0 <= a+0) {next}
  (s!="" && ts < s) {next}
  (e!="" && ts > e) {next}
  { printf "%s|%s|%s|%s\n", idx, ts, id, msg }' "$FIX")"
if [[ "${n:-}" == 0 ]]; then
  [[ "$showcur" == 1 ]] && { echo "-- No entries --"; echo "-- cursor: cur-$(awk -F'\t' 'NF>=4{i=$1} END{print i+0}' "$FIX")"; }
  exit 0
fi
case "$fmt" in
  json)
    [[ "${J_BADJSON:-0}" == 1 ]] && { echo "{这不是 json"; exit 0; }
    while IFS='|' read -r idx ts id msg; do
      [[ -n "$idx" ]] || continue
      python3 -c 'import json,sys; print(json.dumps({"MESSAGE":sys.argv[1],"__CURSOR":"cur-"+sys.argv[2]}))' "$msg" "$idx"
    done <<< "$out";;
  cat)
    while IFS='|' read -r idx ts id msg; do [[ -n "$idx" ]] && printf '%s\n' "$msg"; done <<< "$out";;
  *)
    while IFS='|' read -r idx ts id msg; do [[ -n "$idx" ]] && printf '%s %s: %s\n' "$ts" "$id" "$msg"; done <<< "$out";;
esac
exit 0
EOS
  cat > "$BIN/logger" <<'EOS'
#!/usr/bin/env bash
[[ "${J_NOMARK:-0}" == 1 ]] && exit 0      # 模型: 标记写不进去(或写进去看不见)
tag=""; while (( $# )); do case "$1" in -t) tag="$2"; shift 2;; *) break;; esac; done
i="$(awk -F'\t' 'NF>=4{n=$1} END{print n+0}' "$FIXTURE")"
printf '%s\t%s\t%s\t%s\n' "$((i+1))" "$(cat "$CLOCK")" "$tag" "$*" >> "$FIXTURE"
EOS
  cat > "$BIN/date" <<'EOS'
#!/bin/sh
cat "$CLOCK"
EOS
  cat > "$BIN/systemctl" <<'EOS'
#!/usr/bin/env bash
prop=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prop="$a"; prev="$a"; done
case "$prop" in
  StartLimitIntervalUSec) echo "${ST_INT:-10s}";;
  StartLimitBurst) echo "${ST_BURST:-5}";;
  Restart) echo "${ST_RESTART:-on-failure}";;
  NRestarts)
    [ "${PDG_NR_BAD:-0}" = 1 ] && { echo ""; exit 0; }     # 模型: 读不到合法数值
    if [ -f "$FIXDIR/nr2" ] && [ -f "$FIXDIR/slept" ]; then cat "$FIXDIR/nr2"; else cat "$FIXDIR/nr1"; fi;;
  ActiveState) echo "${ST_ACTIVE:-active}";;
  *) echo "";;
esac
EOS
  chmod +x "$BIN"/*
}
# 往事件簿里加一条 mosdns 启动(同一秒)
ev(){ local i; i="$(awk -F'\t' 'NF>=4{n=$1} END{print n+0}' "$FIXTURE")"
  printf '%s\t%s\t%s\t%s\n' "$((i+1))" "$(cat "$CLOCK")" "mosdns" "Started mosdns.service - mosdns." >> "$FIXTURE"; }
STUBS_EOF
cat > "$RUNSH" <<'RUNNER_EOF'
#!/usr/bin/env bash
# 由测试调起: 从 $SRC 抽被测函数原文, 用事件簿驱动 quiesce_startlimit, 打印 KEY=value。
set -uo pipefail
SRC="$1"
E2E_TMP="$FIXDIR"
JBOUND_TAG="pdg-e2e-jbound"; J_ERR=""
# shellcheck source=/dev/null
source "$STUBSH"
_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
for f in _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after \
         _j_interval _now_j _dur2s_real _unit_starts startlimit_inventory quiesce_startlimit phase_report; do
  b="$(_fn "$SRC" "$f")"; [[ -n "$b" ]] && eval "$b"
done
eval "$(grep -m1 '^STARTLIMIT_CAP=' "$SRC")"
ok(){  printf 'OK|%s\n' "$1"; }
bad(){ printf 'BAD|%s\n' "$1"; }
note(){ printf 'NOTE|%s\n' "$1"; }
_ev(){ cat >/dev/null; }
_evn(){ :; }
wait_stable(){ printf '%s\n' "${ST_ACTIVE:-active}"; }
DIR=a2i; PREIMAGE_OK=1; EVID="$FIXDIR"
if [[ "${NO_INVENTORY:-0}" == 1 ]]; then unset SL_INT SL_INT_S            # 模型: 压根没清点过
else SL_INT="${ST_INT:-10s}"; SL_INT_S="${SL_INT_S_IN:-10}"; fi
# 静置那一觉不真睡: 期间按 DURING 注入若干条 mosdns 启动(_j_mark 的 0.3s 重试不算)
sleep(){ case "${1:-}" in 0.*) return 0;; esac; : > "$FIXDIR/slept"
  local i; for ((i=0; i<${DURING:-0}; i++)); do ev; done; return 0; }
quiesce_startlimit "${PHASE:-测试}" > "$FIXDIR/verdict" 2>"$FIXDIR/verr"; RC=$?
echo "RC=$RC"
echo "PRE=$PREIMAGE_OK"
echo "VERDICT=$(head -1 "$FIXDIR/verdict")"
echo "VERR=$(head -1 "$FIXDIR/verr")"
RUNNER_EOF
chmod +x "$RUNSH"

# q_case: 建一份事件簿 → 跑指定脚本的 quiesce_startlimit → 回显 KEY=value
#   $1=被测脚本  $2=界桩前注入几条  $3=静置期间注入几条  [$4..]=额外环境(K=V)
q_case(){
  local src="$1" before="$2" during="$3"; shift 3
  local T; T="$(mktemp -d "$WORK/case.XXXXXX")"
  ( export FIXDIR="$T" FIXTURE="$T/journal.tsv" CLOCK="$T/clock" BIN="$T/bin" STUBSH="$STUBSH"
    : > "$FIXTURE"; echo "2026-01-01 00:00:00" > "$CLOCK"; echo 0 > "$T/nr1"; echo 0 > "$T/nr2"
    # shellcheck source=/dev/null
    # shellcheck source=/dev/null
  source "$STUBSH"; mk_stubs
    local i; for ((i=0; i<before; i++)); do ev; done
    env PATH="$BIN:$PATH" DURING="$during" SL_INT_S_IN=10 ST_INT=10s "$@" \
      bash "$RUNSH" "$src" )
}
gv(){ grep -m1 "^$1=" <<<"$QOUT" | cut -d= -f2-; }

echo; echo "══ 1. 时长解析: 只认 systemd 真会打出来的那几种写法 ══"
eval "$(_fn "$SRC" _dur2s_real)"
for pair in "10s:10" "5min:300" "1min 30s:90" "2h:7200" "infinity:infinity" "0:0"; do
  in="${pair%:*}"; want="${pair##*:}"; got="$(_dur2s_real "$in")"
  [[ "$got" == "$want" ]] && ok "1: '$in' → $got" || bad "1: '$in' → '$got'(应 $want)"
done
[[ -z "$(_dur2s_real 'abc')" ]] && ok "1: 读不懂的写法回空(由调用方判前置不成立)" || bad "1: 'abc' 居然解析出了值"

echo; echo "══ 2. 清点: 读的是**产品自己**那份 unit 的生效属性 ══"
INV="$WORK/inv.out"
( T="$(mktemp -d "$WORK/inv.XXXXXX")"; export FIXDIR="$T" FIXTURE="$T/j" CLOCK="$T/c" BIN="$T/bin" STUBSH="$STUBSH"
  : > "$FIXTURE"; echo "2026-01-01 00:00:00" > "$CLOCK"; echo 0 > "$T/nr1"; echo 0 > "$T/nr2"
  # shellcheck source=/dev/null
  source "$STUBSH"; mk_stubs
  PATH="$BIN:$PATH" bash -c '
    _fn(){ awk -v f="$2" '"'"'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}'"'"' "$1"; }
    eval "$(_fn "'"$SRC"'" _dur2s_real)"
    eval "$(_fn "'"$SRC"'" startlimit_inventory)"
    note(){ printf "NOTE|%s\n" "$1"; }; _evn(){ :; }; DIR=a2i
    startlimit_inventory' ) > "$INV" 2>&1
grep -q 'StartLimitIntervalUSec=10s(=10s)' "$INV" && ok "2a: 清点打印了实际生效的窗口与 Burst" || { bad "2a"; sed 's/^/      /' "$INV"; }
grep -q '只读不改' "$INV" && ok "2b: 明确写了只读不改产品 unit" || bad "2b"
grep -q '标定 4 次' "$INV" && ok "2c: 把准备阶段计划内的 4 次重启列了出来" || bad "2c"

echo; echo "══ 3. 事件归属: 界桩说了算, 秒级时刻不参与裁决 ══"
# 3a 同一秒内: 界桩之前有 3 条, 之后没有 ⇒ 应通过(这正是 run 34960827400 判错的那一格)
QOUT="$(q_case "$SRC" 3 0)"
{ [[ "$(gv RC)" == 0 ]] && [[ "$(gv PRE)" == 1 ]]; } \
  && ok "3a: 同一秒内界桩**之前** 3 条启动 ⇒ 不算进静置窗口, 前置成立" \
  || { bad "3a: rc=$(gv RC) $(gv VERDICT)"; }
# 3b 同一秒内: 界桩之后确有启动 ⇒ 必须拒绝(即使 active 且 NRestarts 没变)
QOUT="$(q_case "$SRC" 3 1)"
{ [[ "$(gv RC)" != 0 ]] && [[ "$(gv PRE)" == 0 ]] && [[ "$(gv VERDICT)" == BAD* ]]; } \
  && ok "3b: 同一秒内界桩**之后**有 1 条启动 ⇒ 判红(active 与 NRestarts 不变都救不了它)" \
  || bad "3b: rc=$(gv RC) $(gv VERDICT)"
# 3c 相邻阶段共享界桩: 合计不重不漏(直接驱动 _j_interval / _j_starts_after)
IVT="$WORK/interval.out"
( T="$(mktemp -d "$WORK/iv.XXXXXX")"; export FIXDIR="$T" FIXTURE="$T/j" CLOCK="$T/c" BIN="$T/bin"
  : > "$FIXTURE"; echo "2026-01-01 00:00:00" > "$CLOCK"; echo 0 > "$T/nr1"; echo 0 > "$T/nr2"
  # shellcheck source=/dev/null
  source "$STUBSH"; mk_stubs
  export PATH="$BIN:$PATH" E2E_TMP="$T" JBOUND_TAG="pdg-e2e-jbound" J_ERR=""
  for f in _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after _j_interval; do
    eval "$(_fn "$SRC" "$f")"
  done
  ev; ev                      # A 之前 2 条
  A="$(_j_mark ph-a)"; ev; ev; ev            # (A,B] 3 条
  B="$(_j_mark ph-b)"; ev                    # (B,C] 1 条
  C="$(_j_mark ph-c)"
  echo "AB=$(_j_interval mosdns "$A" "$B")"
  echo "BC=$(_j_interval mosdns "$B" "$C")"
  echo "AC=$(_j_interval mosdns "$A" "$C")"
  echo "AFTER_A=$(_j_starts_after mosdns "$A")"
  REV="$(_j_interval mosdns "$B" "$A")"; RREV=$?
  echo "REV=$REV"; echo "REVRC=$RREV"
  echo "REVWHY=$(_j_why)" ) > "$IVT" 2>&1
iv(){ grep -m1 "^$1=" "$IVT" | cut -d= -f2-; }
{ [[ "$(iv AB)" == 3 ]] && [[ "$(iv BC)" == 1 ]] && [[ "$(iv AC)" == 4 ]]; } \
  && ok "3c-1: 相邻区间共享界桩 —— (A,B]=3, (B,C]=1, 合计 == (A,C]=4, 不重不漏" \
  || { bad "3c-1: AB=$(iv AB) BC=$(iv BC) AC=$(iv AC)"; sed 's/^/      /' "$IVT"; }
[[ "$(iv AFTER_A)" == 4 ]] && ok "3c-2: 界桩之后的总条数与分段之和一致(4)" || bad "3c-2: after A=$(iv AFTER_A)"
{ [[ -z "$(iv REV)" ]] && [[ "$(iv REVRC)" != 0 ]]; } \
  && ok "3c-3: 界桩顺序颠倒 ⇒ 判观测无效($(iv REVWHY)), 不产出负数或 0" || bad "3c-3: REV=$(iv REV) rc=$(iv REVRC)"
# 3d 健康零事件
QOUT="$(q_case "$SRC" 0 0)"
{ [[ "$(gv RC)" == 0 ]] && [[ "$(gv VERDICT)" == OK* ]]; } && ok "3d: 干净零事件 ⇒ 正常通过" || bad "3d: $(gv VERDICT)"
# 3e journal 查询失败 ⇒ 观测无效, 且**不**生成"0 次启动"的结论
QOUT="$(q_case "$SRC" 0 0 J_FAIL_UNIT=1)"
{ [[ "$(gv RC)" != 0 ]] && [[ "$(gv PRE)" == 0 ]] && [[ "$(gv VERDICT)" == *观测无效* ]] \
  && [[ "$(gv VERDICT)" != *"0 次启动"* ]]; } \
  && ok "3e: 计数查询失败(界桩仍可用)⇒ 具名报**观测无效**, 没有冒充零启动" || bad "3e: $(gv VERDICT)"
# 3f 界桩写不进/读不回 ⇒ 观测无效
QOUT="$(q_case "$SRC" 0 0 J_NOMARK=1)"
{ [[ "$(gv RC)" != 0 ]] && [[ "$(gv PRE)" == 0 ]] && [[ "$(gv VERDICT)" == *界桩* ]]; } \
  && ok "3f: 界桩写进去却读不回来 ⇒ 观测无效(journal 可见性没确认就不往下走)" || bad "3f: $(gv VERDICT)"
# 3g 解析失败(json 读不懂)⇒ 观测无效
QOUT="$(q_case "$SRC" 0 0 J_BADJSON=1)"
{ [[ "$(gv RC)" != 0 ]] && [[ "$(gv PRE)" == 0 ]]; } \
  && ok "3g: 界桩记录解析不了 ⇒ 观测无效, 前置不成立" || bad "3g: $(gv VERDICT)"
# 3h NRestarts 读不到合法数值 ⇒ 观测无效(两个空串相等不算"没有自动重启")
QOUT="$(q_case "$SRC" 0 0 PDG_NR_BAD=1)"
{ [[ "$(gv RC)" != 0 ]] && [[ "$(gv PRE)" == 0 ]] && [[ "$(gv VERDICT)" == *NRestarts* ]]; } \
  && ok "3h: NRestarts 读不到合法数值 ⇒ 观测无效(空==空 不算没有自动重启)" || bad "3h: $(gv VERDICT)"
note "3: 上面每一格都真的走了取界桩 → 查询 → 解析 → 算区间这条路径(桩维护事件簿, 不是直接给条数)。"

echo; echo '══ 4. 不接受“等于没有限制”的窗口, 也不做无界等待 ══'
for bad_int in "infinity:infinity" "0:0"; do
  QOUT="$(q_case "$SRC" 0 0 SL_INT_S_IN="${bad_int##*:}" ST_INT="${bad_int%:*}")"
  { [[ "$(gv RC)" != 0 ]] && [[ "$(gv PRE)" == 0 ]]; } \
    && ok "4: 生效窗口 '${bad_int%:*}' ⇒ 判前置不成立, 一秒都不等" || bad "4: ${bad_int%:*} $(gv VERDICT)"
done
QOUT="$(q_case "$SRC" 0 0 SL_INT_S_IN=600 ST_INT=10min)"
{ [[ "$(gv RC)" != 0 ]] && [[ "$(gv PRE)" == 0 ]]; } \
  && ok "4: 窗口 600s 超过上限 ${STARTLIMIT_CAP}s ⇒ 不做无界等待" || bad "4: $(gv VERDICT)"
QOUT="$(q_case "$SRC" 0 0 NO_INVENTORY=1)"
[[ "$(gv RC)" != 0 ]] && ok "4: 没清点就静置 ⇒ 拒绝(不拿默认值猜)" || bad "4: 居然放行了"

echo; echo "══ 5. 阶段记账: 产品动作窗口只围住那一次调用 ══"
PHB="$WORK/phase.out"
( T="$(mktemp -d "$WORK/ph.XXXXXX")"; export FIXDIR="$T" FIXTURE="$T/j" CLOCK="$T/c" BIN="$T/bin"
  : > "$FIXTURE"; echo "2026-01-01 00:00:00" > "$CLOCK"; echo 0 > "$T/nr1"; echo 0 > "$T/nr2"
  # shellcheck source=/dev/null
  source "$STUBSH"; mk_stubs
  export PATH="$BIN:$PATH" E2E_TMP="$T" JBOUND_TAG="pdg-e2e-jbound" J_ERR=""
  for f in _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after _j_interval _now_j phase_report; do
    eval "$(_fn "$SRC" "$f")"
  done
  DIR=a2i; _ev(){ cat > "$T/ev"; }; _evn(){ :; }
  PH_T0="T0"; C_PREP0="$(_j_mark prep)"; ev; ev            # 准备 2 条
  T_CAL0="T1"; C_CAL0="$(_j_mark cal0)"; ev; ev; ev; ev    # 标定 4 条
  T_CAL1="T2"; C_CAL1="$(_j_mark cal1)"                    # 静置+采前像 0 条
  T_PROD0="T3"; C_PROD0="$(_j_mark prod0)"; ev             # 产品动作 1 条
  T_PROD1="T4"; C_PROD1="$(_j_mark prod1)"; ev             # 调用之后又 1 条(不该算进产品动作)
  phase_report; echo "--- 证据 ---"; cat "$T/ev" ) > "$PHB" 2>&1
grep -qE '准备阶段.*启动 2 次' "$PHB" && ok "5a: 准备阶段记 2 次" || { bad "5a"; sed 's/^/      /' "$PHB" | head -8; }
grep -qE '标定阶段.*启动 4 次' "$PHB" && ok "5b: 标定阶段记 4 次(准备的没混进来)" || bad "5b"
grep -qE '静置#2 \+ 正式前像采集.*启动 0 次' "$PHB" && ok "5c: 静置+采前像记 0 次" || bad "5c"
grep -qE '产品动作.*启动 1 次' "$PHB" \
  && ok "5d: **产品动作**只记那一次调用窗口内的 1 次 —— 调用之后的那条没被算进来" || bad "5d"
grep -q '前像采集也不算产品动作' "$PHB" && ok "5e: 证据里写明了前像采集不算产品动作" || bad "5e"
grep -q 'StartLimit 一个字没改' "$PHB" && ok "5f: 证据里写明没改产品 unit、没有 reset-failed" || bad "5f"
grep -q '不比大小' "$PHB" && ok "5g: 证据里写明界桩是不透明标识(不比大小判先后)" || bad "5g"

echo; echo "══ 6. 源码面的硬约束 ══"
BODY_Q="$(_fn "$SRC" quiesce_startlimit)$(_fn "$SRC" startlimit_inventory)"
BODY_J="$(_fn "$SRC" _j_starts_after)$(_fn "$SRC" _j_interval)$(_fn "$SRC" _j_tag_after)"
grep -q 'reset-failed' <<<"$BODY_Q$BODY_J" && bad "6a: 用了 reset-failed 清额度" || ok "6a: 没有 reset-failed"
grep -qE 'systemctl (set-property|edit)|\.service\.d|/etc/systemd/system/[^ ]*\.conf|daemon-reload' <<<"$BODY_Q" \
  && bad "6b: 动了 unit 的设置" || ok "6b: 只读属性, 没有改产品 unit 的 StartLimit*"
grep -qE '^\s*(systemctl (restart|start)|mv |rm )' <<<"$BODY_Q" \
  && bad "6c: 静置里夹带了服务动作" || ok "6c: 静置只等待与观测, 不做服务动作"
grep -qE '\-\-since|\-\-until' <<<"$BODY_J" \
  && bad "6d: 事件归属又用回了秒级 --since/--until" || ok "6d: 事件归属只用 --after-cursor(秒级时刻不参与裁决)"
grep -qE '2>/dev/null.*\|\|[[:space:]]*true|\|\|[[:space:]]*true$' <<<"$BODY_J" \
  && bad "6e: journal 查询的错误又被吞掉了" || ok "6e: journal 查询的失败没有被 2>/dev/null + || true 吞掉"
grep -qE '\[\[ "\$[a-z0-9_]+" [<>] "\$[a-z0-9_]+" \]\]' <<<"$BODY_J" \
  && bad "6f: 拿游标字符串比大小判先后" || ok "6f: 没有比较游标字符串大小(游标当不透明标识)"
_pf="$(grep -c 'PREIMAGE_OK=0' <<<"$(_fn "$SRC" quiesce_startlimit)")"
[[ "$_pf" -ge 7 ]] && ok "6g: 七类不成立(窗口读不懂/无限制/超上限/起止界桩/NRestarts 两读/区间无效/期间有动静)都落到前置不成立($_pf 处)" \
  || bad "6g: 只有 $_pf 处"

echo; echo "══ 7. workflow 的范围选择: 显式, 且保留原默认语义 ══"
if [[ -f "$CI" ]]; then
  SEL="$(grep -c "real_scope == 'platform'" "$CI")"; RET="$(grep -c "real_scope == 'retire'" "$CI")"
  ALL="$(grep -c "real_scope == 'all'" "$CI")";      EMP="$(grep -c "real_scope == ''" "$CI")"
  { [[ "$SEL" == 2 ]] && [[ "$RET" == 1 ]] && [[ "$ALL" == 3 ]] && [[ "$EMP" == 3 ]]; } \
    && ok "7a: 三个真实验收 job 都挂了范围条件(platform 2 / retire 1 / all 与空各 3)" \
    || bad "7a: platform=$SEL retire=$RET all=$ALL 空=$EMP"
  # 选项集合可以增加(例如后来加了 bridge), 但必须仍然是**显式枚举**, 且 all/platform/retire 都在。
  _opt="$(grep -m1 'options: \["all"' "$CI")"
  { [[ "$_opt" == *'"all"'* ]] && [[ "$_opt" == *'"platform"'* ]] && [[ "$_opt" == *'"retire"'* ]]; } \
    && ok "7b: real_scope 仍是显式枚举, 且 all/platform/retire 都在($(sed 's/^ *//' <<<"$_opt"))" \
    || bad "7b: 选项不对: $_opt"
  # 新增的范围必须**也**挂在某个 job 的条件上, 不能只加选项却没人用
  for _extra in $(sed -E 's/.*options: \[(.*)\].*/\1/' <<<"$_opt" | tr -d '" ' | tr ',' ' '); do
    case "$_extra" in all) continue;; esac
    grep -q "real_scope == '$_extra'" "$CI" \
      && ok "7b+: 范围 '$_extra' 有 job 真的用它" || bad "7b+: 选项里有 '$_extra' 却没有任何 job 用它"
  done
  awk '/^      real_scope:/{f=1} f&&/default:/{print; exit}' "$CI" | grep -q 'default: "all"' \
    && ok "7c: 默认值仍是 all(老式派发语义逐字保留)" || bad "7c: 默认值不是 all"
  grep -n 'continue-on-error' "$CI" | grep -qE 'real-(platform|retire)' \
    && bad "7d: 真实验收 job 用 continue-on-error 绕过失败" || ok "7d: 没有用 continue-on-error 绕过失败"
  for j in real-retire-refusal real-platform-fail-a2i real-platform-fail-i2a; do
    awk -v j="$j" '$0 ~ "^  "j":" {f=1} f&&/if: /{print; exit}' "$CI" | grep -q "real_acceptance == 'true'" \
      && ok "7e($j): 仍然要求 real_acceptance=true" || bad "7e($j): 条件里没有 real_acceptance"
  done
else bad "7: 找不到 $CI"; fi

echo; echo "══ N. 撤销对照: 把修法撤回去, 对应的格子必须重新转红 ══"
# N1 撤回秒级边界(界桩退回 `date +秒`, 查询退回含边界的 --since)
python3 - "$SRC" "$WORK/rev-sec.sh" <<'PYN1'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
def body(name, text):
    i = text.index(name + "(){"); j = text.index("\n}\n", i) + len("\n}\n"); return text[i:j]
s = s.replace(body("_j_mark", s), '_j_mark(){ date +\'%Y-%m-%d %H:%M:%S\'; }\n')
s = s.replace(body("_j_starts_after", s),
  '_j_starts_after(){ journalctl -u "$1" --since "$2" --no-pager | grep -cE "Started $1(\\\\.service)?[ .]"; }\n')
# 冻结原文的语义: 只拿起点做一次 --since 计数, 根本没有"止边界"
s = s.replace(body("_j_interval", s), '_j_interval(){ _j_starts_after "$1" "$2"; }\n')
open(dst, "w", encoding="utf-8").write(s)
PYN1
QOUT="$(q_case "$WORK/rev-sec.sh" 3 0)"
{ [[ "$(gv RC)" != 0 ]] && [[ "$(gv VERDICT)" == BAD* ]]; } \
  && ok "N1: 撤回秒级边界 ⇒ 3a 那一格重新转红(同一秒里界桩之前的 3 条又被算进来: $(gv VERDICT | head -c 60)…)" \
  || bad "N1: 没重现出来 rc=$(gv RC) $(gv VERDICT)"
# N2 把起点后移一秒(整秒排除)⇒ 边界之后同一秒里的启动被漏掉, 3b 那一格会被放过
python3 - "$SRC" "$WORK/rev-shift.sh" <<'PYN2'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
def body(name, text):
    i = text.index(name + "(){"); j = text.index("\n}\n", i) + len("\n}\n"); return text[i:j]
s = s.replace(body("_j_mark", s), '_j_mark(){ date +\'%Y-%m-%d %H:%M:%S\'; }\n')
# "起点后移一秒" = 把界桩那一整秒排除在外
s = s.replace(body("_j_starts_after", s),
  '_j_starts_after(){ journalctl -u "$1" --since "$2" --no-pager | grep -E "Started $1(\\\\.service)?[ .]" | grep -vc "^$2" ; }\n')
s = s.replace(body("_j_interval", s),
  '_j_interval(){ local a b; a="$(_j_starts_after "$1" "$2")"; b="$(_j_starts_after "$1" "$3")"; echo $(( a - b )); }\n')
open(dst, "w", encoding="utf-8").write(s)
PYN2
QOUT="$(q_case "$WORK/rev-shift.sh" 3 1)"
{ [[ "$(gv RC)" == 0 ]]; } \
  && ok "N2: 改成'起点后移一秒' ⇒ 3b 那一格被放过(同一秒里界桩之后的启动**漏计**) —— 这正是本支能测出来的" \
  || bad "N2: 没暴露漏计 rc=$(gv RC) $(gv VERDICT)"
# N3 恢复吞错逻辑 ⇒ 3e 那一格转红(查询失败被当成零启动)
python3 - "$SRC" "$WORK/rev-swallow.sh" <<'PYN3'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
def body(name, text):
    i = text.index(name + "(){"); j = text.index("\n}\n", i) + len("\n}\n"); return text[i:j]
s = s.replace(body("_j_starts_after", s),
  '_j_starts_after(){ journalctl -u "$1" --after-cursor "$2" --no-pager 2>/dev/null | grep -cE "Started $1(\\\\.service)?[ .]" || true; }\n')
s = s.replace(body("_j_interval", s),
  '_j_interval(){ local a b; a="$(_j_starts_after "$1" "$2")"; b="$(_j_starts_after "$1" "$3")"; echo $(( a - b )); }\n')
open(dst, "w", encoding="utf-8").write(s)
PYN3
QOUT="$(q_case "$WORK/rev-swallow.sh" 0 0 J_FAIL_UNIT=1)"
{ [[ "$(gv RC)" == 0 ]] || [[ "$(gv VERDICT)" != *观测无效* ]]; } \
  && ok "N3: 恢复吞错逻辑 ⇒ 查询失败被当成'零启动'放行, 3e 那一格失守(证明该格确实在测这条路径)" \
  || bad "N3: 吞错版本居然还判无效 rc=$(gv RC) $(gv VERDICT)"
# N4 无关注释对照
sed '0,/^STARTLIMIT_CAP=/s//# 本行仅为无关注释对照\nSTARTLIMIT_CAP=/' "$SRC" > "$WORK/cmt.sh"
R1="$(q_case "$SRC" 3 0)"; R2="$(q_case "$WORK/cmt.sh" 3 0)"
R3="$(q_case "$SRC" 3 1)"; R4="$(q_case "$WORK/cmt.sh" 3 1)"
{ [[ "$(grep -m1 '^RC=' <<<"$R1")" == "$(grep -m1 '^RC=' <<<"$R2")" ]] \
  && [[ "$(grep -m1 '^RC=' <<<"$R3")" == "$(grep -m1 '^RC=' <<<"$R4")" ]]; } \
  && ok "N4: 无关注释对照 —— 两格结论逐一相同, 零新增失败" || bad "N4: 加一行注释改变了结果"

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
