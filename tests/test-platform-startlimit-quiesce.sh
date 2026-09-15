#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 平台真实验收里"准备动作不要污染被测过程"这一段的**判定契约**。
# 跑的是 tests/e2e-real-platform-fail.sh 里那几个函数的**原文**
# (_dur2s_real / _unit_starts / startlimit_inventory / quiesce_startlimit / phase_report),
# 不抄一份。systemctl / journalctl / sleep 在这里是桩 —— 这是**模型验证**:
# 它证明"各种观测下判得对不对", 真机那一半只能由真实派发回答, 两类证据分列。
#
# 为什么要有这一支: 平台验收在正式操作前会为标定连着重启 mosdns 四次, 而产品自己的
# mosdns unit 没设 StartLimit*(吃系统默认 10s/5)。准备阶段把额度用光, 产品自己的
# `systemctl restart mosdns` 就会撞 start-limit —— 那是测试准备污染了被测过程。
# 处理只能是"等"(有界静置), 不能改产品 unit、不能 reset-failed、不能关限制。
# ─────────────────────────────────────────────────────────────────────────────
# 注: 本支有一批全局变量是给 eval 进来的被测函数读的(SL_INT_S / DIR / EVID / 阶段时刻…);
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
for f in _now_j _dur2s_real _unit_starts startlimit_inventory quiesce_startlimit phase_report; do
  b="$(_fn "$SRC" "$f")"; [[ -n "$b" ]] || { echo "[未执行] 抽不到 $f"; exit 1; }
  eval "$b"
done
ok "0: 六个函数都从平台验收脚本**原文**抽到(不是本支自己写的一份)"
# 上限常量也从原文取 —— 本支不另起一个数, 免得两边各说各话
eval "$(grep -m1 '^STARTLIMIT_CAP=' "$SRC")"
[[ "${STARTLIMIT_CAP:-}" =~ ^[1-9][0-9]*$ ]] \
  && ok "0b: 静置上限也取自原文(STARTLIMIT_CAP=${STARTLIMIT_CAP}s, 有限正整数)" \
  || { echo "[未执行] 原文里读不到 STARTLIMIT_CAP"; exit 1; }

# ── 桩: systemctl / journalctl / sleep ───────────────────────────────────────
# 桩只回答"生效属性/启动条数/稳定态", 行为全部由环境变量驱动, 判据落在被测函数的判词上。
ST_INT="10s"; ST_BURST=5; ST_RESTART="on-failure"; ST_NR=0; ST_NR2=0; ST_ACTIVE="active"
J_COUNT=0; SLEPT=""
systemctl(){
  case "$1 ${3:-}" in
    "show -p") :;; esac
  local prop="" prev=""
  for a in "$@"; do [[ "$prev" == "-p" ]] && prop="$a"; prev="$a"; done
  case "$prop" in
    StartLimitIntervalUSec) echo "$ST_INT";;
    StartLimitBurst)        echo "$ST_BURST";;
    Restart)                echo "$ST_RESTART";;
    NRestarts)              if [[ -n "$SLEPT" ]]; then echo "$ST_NR2"; else echo "$ST_NR"; fi;;
    ActiveState)            echo "$ST_ACTIVE";;
    *)                      echo "";;
  esac
}
journalctl(){ local i; for ((i=0;i<J_COUNT;i++)); do echo "systemd[1]: Started mosdns.service - mosdns."; done; }
sleep(){ SLEPT="${SLEPT}${SLEPT:+,}$1"; }        # 不真等, 只记下"要等多久"
wait_stable(){ echo "$ST_ACTIVE"; }
_ev(){ cat > /dev/null; }
_evn(){ :; }
DIR=a2i; PREIMAGE_OK=1; EVID="$WORK"
run_q(){   # $1=阶段名 → 回显判词; 副作用: RC_Q / PREIMAGE_OK
  local out; out="$WORK/q.out"
  SLEPT=""; PREIMAGE_OK=1
  { ok(){ printf 'OK|%s\n' "$1"; }; bad(){ printf 'BAD|%s\n' "$1"; }; note(){ printf 'NOTE|%s\n' "$1"; }
    quiesce_startlimit "$1"; echo "RC=$?"; echo "PRE=$PREIMAGE_OK"; echo "SLEPT=$SLEPT"; } > "$out" 2>&1
  ok(){  printf '[OK]   %s\n' "$1"; P=$((P+1)); }
  bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
  note(){ printf '[NOTE] %s\n' "$1"; }
  cat "$out"
}
gq(){ grep -m1 "^$1=" "$WORK/q.out" | cut -d= -f2-; }

echo; echo "══ 1. 时长解析: 只认 systemd 真会打出来的那几种写法 ══"
for pair in "10s:10" "5min:300" "1min 30s:90" "2h:7200" "infinity:infinity" "0:0"; do
  in="${pair%:*}"; want="${pair##*:}"
  got="$(_dur2s_real "$in")"
  [[ "$got" == "$want" ]] && ok "1: '$in' → $got" || bad "1: '$in' → '$got'(应 $want)"
done
[[ -z "$(_dur2s_real 'abc')" ]] && ok "1: 读不懂的写法回空(由调用方判前置不成立)" || bad "1: 'abc' 居然解析出了值"

echo; echo "══ 2. 清点: 读的是**产品自己**那份 unit 的生效属性 ══"
INV="$WORK/inv.out"
{ note(){ printf 'NOTE|%s\n' "$1"; }; startlimit_inventory; } > "$INV" 2>&1
note(){ printf '[NOTE] %s\n' "$1"; }
grep -q 'StartLimitIntervalUSec=10s(=10s)' "$INV" && ok "2a: 清点打印了实际生效的窗口与 Burst" || { bad "2a"; sed 's/^/      /' "$INV"; }
grep -q '只读不改' "$INV" && ok "2b: 明确写了只读不改产品 unit" || bad "2b"
grep -q '标定 4 次' "$INV" && ok "2c: 把准备阶段计划内的 4 次重启列了出来" || bad "2c"

echo; echo "══ 3. 静置: 依生效窗口等, 有界, 且要自证期间什么都没起 ══"
SL_INT="$ST_INT"; SL_INT_S=10
J_COUNT=0; ST_NR=3; ST_NR2=3; ST_ACTIVE=active
run_q "标定前" > /dev/null
{ [[ "$(gq RC)" == 0 ]] && [[ "$(gq SLEPT)" == 13 ]] && [[ "$(gq PRE)" == 1 ]]; } \
  && ok "3a: 窗口 10s ⇒ 静置 13s(窗口+3s 余量), 期间零启动 ⇒ 前置成立" \
  || { bad "3a: rc=$(gq RC) 等了 $(gq SLEPT)s PRE=$(gq PRE)"; sed 's/^/      /' "$WORK/q.out"; }
grep -q 'OK|静置(标定前): 按实际生效窗口' "$WORK/q.out" && ok "3b: 判词里写明了依据(生效窗口)与实测(0 次启动/NRestarts/稳定态)" || bad "3b"

J_COUNT=2
run_q "标定前" > /dev/null
{ [[ "$(gq RC)" != 0 ]] && [[ "$(gq PRE)" == 0 ]]; } \
  && ok "3c: 静置期间**有启动** ⇒ 判红且前置不成立(不重试到绿)" || bad "3c: rc=$(gq RC) PRE=$(gq PRE)"
J_COUNT=0; ST_NR=3; ST_NR2=4
run_q "标定前" > /dev/null
{ [[ "$(gq RC)" != 0 ]] && [[ "$(gq PRE)" == 0 ]]; } \
  && ok "3d: 期间发生**自动重启**(NRestarts 3→4) ⇒ 前置不成立" || bad "3d: rc=$(gq RC) PRE=$(gq PRE)"
ST_NR2=3; ST_ACTIVE=failed
run_q "标定前" > /dev/null
{ [[ "$(gq RC)" != 0 ]] && [[ "$(gq PRE)" == 0 ]]; } \
  && ok "3e: 静置后服务不稳(failed) ⇒ 前置不成立" || bad "3e: rc=$(gq RC) PRE=$(gq PRE)"
ST_ACTIVE=active

echo; echo '══ 4. 不接受“等于没有限制”的窗口, 也不做无界等待 ══' 
for bad_int in "infinity:infinity" "0:0"; do
  SL_INT="${bad_int%:*}"; SL_INT_S="${bad_int##*:}"
  run_q "标定前" > /dev/null
  { [[ "$(gq RC)" != 0 ]] && [[ "$(gq PRE)" == 0 ]] && [[ -z "$(gq SLEPT)" ]]; } \
    && ok "4: 生效窗口 '$SL_INT'(等于没有限制)⇒ 判前置不成立, 一秒都不等" \
    || { bad "4: '$SL_INT' rc=$(gq RC) PRE=$(gq PRE) 等了 '$(gq SLEPT)'"; }
done
SL_INT="10min"; SL_INT_S=600
run_q "标定前" > /dev/null
{ [[ "$(gq RC)" != 0 ]] && [[ "$(gq PRE)" == 0 ]] && [[ -z "$(gq SLEPT)" ]]; } \
  && ok "4: 窗口 600s 超过上限 ⇒ 不做无界等待, 判前置不成立" || bad "4: rc=$(gq RC) 等了 '$(gq SLEPT)'"
SL_INT=""; SL_INT_S=""
run_q "标定前" > /dev/null
[[ "$(gq RC)" != 0 ]] && ok "4: 没清点就静置 ⇒ 拒绝(不拿默认值猜)" || bad "4: 居然放行了"

echo; echo "══ 5. 阶段边界: 准备阶段的重启不算到产品动作头上 ══"
SL_INT="10s"; SL_INT_S=10
PH_T0="T0"; T_CAL0="T1"; T_CAL1="T2"; T_PROD0="T3"; T_PROD1="T4"
J_COUNT=4
PR="$WORK/ph.out"; _ev(){ cat > "$WORK/ph.ev"; }
phase_report > "$PR" 2>&1
grep -q '准备阶段' "$PR" && grep -q '标定阶段' "$PR" && grep -q '产品动作' "$PR" \
  && ok "5a: 四段边界(准备/标定/静置+采前像/产品动作)逐段打印了启动次数" || { bad "5a"; sed 's/^/      /' "$PR"; }
grep -q '不\*\*计成产品动作' "$WORK/ph.ev" 2>/dev/null || grep -q '不.*计成产品动作' "$WORK/ph.ev" 2>/dev/null \
  && ok "5b: 证据里写明了准备阶段的重启不计成产品动作" || bad "5b: 证据没写清边界口径"
grep -q 'StartLimit 一个字没改' "$WORK/ph.ev" && ok "5c: 证据里写明了没改产品 unit、没有 reset-failed" || bad "5c"

echo; echo "══ 6. 源码面的硬约束: 不许用产品侧手段换额度 ══"
BODY="$(_fn "$SRC" quiesce_startlimit)$(_fn "$SRC" startlimit_inventory)"
grep -q 'reset-failed' <<<"$BODY" && bad "6a: 用了 reset-failed 清额度" || ok "6a: 没有 reset-failed"
# 只查**写**的动作: 改属性 / 编辑 unit / 落 drop-in。读属性(show -p StartLimit…)和把读到的值
# 打进判词里(…StartLimitIntervalUSec=10s…)都不算改。
grep -qE 'systemctl (set-property|edit)|\.service\.d|/etc/systemd/system/[^ ]*\.conf|daemon-reload' <<<"$BODY" \
  && bad "6b: 动了 unit 的设置(set-property/edit/drop-in)" || ok "6b: 只读属性, 没有改产品 unit 的 StartLimit*"
grep -qE '^\s*(systemctl (restart|start)|mv |rm )' <<<"$BODY" \
  && bad "6c: 静置里夹带了服务动作" || ok "6c: 静置只等待与观测, 不做服务动作"
_pf="$(grep -c 'PREIMAGE_OK=0' <<<"$(_fn "$SRC" quiesce_startlimit)")"
[[ "$_pf" -ge 4 ]] && ok "6d: 四类不成立(读不懂/无限制/超上限/期间有动静)都落到前置不成立($_pf 处)" || bad "6d: 只有 $_pf 处"

echo; echo "══ 7. workflow 的范围选择: 显式, 且保留原默认语义 ══"
if [[ -f "$CI" ]]; then
  SEL="$(grep -c "real_scope == 'platform'" "$CI")"
  RET="$(grep -c "real_scope == 'retire'" "$CI")"
  ALL="$(grep -c "real_scope == 'all'" "$CI")"
  EMP="$(grep -c "real_scope == ''" "$CI")"
  { [[ "$SEL" == 2 ]] && [[ "$RET" == 1 ]] && [[ "$ALL" == 3 ]] && [[ "$EMP" == 3 ]]; } \
    && ok "7a: 三个真实验收 job 都挂了范围条件(platform 2 处 / retire 1 处 / all 与空各 3 处)" \
    || bad "7a: platform=$SEL retire=$RET all=$ALL 空=$EMP"
  grep -q "options: \[\"all\", \"platform\", \"retire\"\]" "$CI" \
    && ok "7b: real_scope 是**显式**选项(all/platform/retire), 默认 all" || bad "7b: 选项不对"
  awk '/^      real_scope:/{f=1} f&&/default:/{print; exit}' "$CI" | grep -q 'default: "all"' \
    && ok "7c: 默认值仍是 all(老式派发语义逐字保留)" || bad "7c: real_scope 的默认值不是 all"
  grep -n 'continue-on-error' "$CI" | grep -qE 'real-(platform|retire)' \
    && bad "7d: 真实验收 job 用 continue-on-error 绕过失败" || ok "7d: 没有用 continue-on-error 绕过失败"
  for j in real-retire-refusal real-platform-fail-a2i real-platform-fail-i2a; do
    awk -v j="$j" '$0 ~ "^  "j":" {f=1} f&&/if: /{print; exit}' "$CI" | grep -q "real_acceptance == 'true'" \
      && ok "7e($j): 仍然要求 real_acceptance=true(范围条件是**再加**一层, 不是放宽)" \
      || bad "7e($j): 条件里没有 real_acceptance"
  done
else
  bad "7: 找不到 $CI"
fi

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
