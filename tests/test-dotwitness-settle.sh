#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 迁移链成功之后的 dotwitness 核验(_dw_settle)—— 模型。
#
# 按 pdg.sh 里唯一的一对标记(# >>> dw-settle / # <<< dw-settle)抽**产品原文**执行;
# systemctl / ss / cat(只拦 /proc/<pid>/cgroup)/ sleep 用替身, 替身逐次把调用写进记录,
# 动作次数一律从记录里数, 不信被测代码自己的输出。
#
# 钉住的是 370 选定的接线(乙)与退出政策(甲):
#   · 派发行 `run_all_migrations && _dw_settle --after-migrate`: 迁移链返回 0 才调, 恰好一次;
#     返回非 0 时新步骤零查询、零动作、零输出, 原始退出码原样传出; 权限 / 锁拒绝时两者都不执行。
#   · cmd_migrate / cmd_platform 不经过派发行, 不会执行新步骤。
#   · 参数必须恰好是 --after-migrate, 否则不查询、不动作。
#   · 恒返回 0; 只对有效确认的 start-limit-hit 做 reset-failed ≤1 次 + start ≤1 次;
#     观察次数与间隔写死, 读取失败不会被后面的成功冲掉; 报告不写原因推断。
#   · (371)每次观察按完整健康条件判(loaded + enabled + active / running), 取值必须认识;
#     多个监听者每个都要读到, 读不到不能被后面的匹配盖掉; 内部异常仍返回 0, 但具名告警并带原始退出码。
# 模型通过只说明产品原文在这些输入下的判定与动作次数, 不等于真机上的修复成立
# (真 systemd 的那一半见 tests/e2e-dotwitness-settle.sh, 只在 CI 的 core-startlimit job 里跑)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

echo "══ 零. 抽取(先核非空、唯一, 抽不到不能当成相同) ══"
BLK="$BOX/dws.sh"
nb="$(grep -c '^# >>> dw-settle' "$PDG")"; ne="$(grep -c '^# <<< dw-settle$' "$PDG")"
lb="$(grep -n '^# >>> dw-settle' "$PDG" | head -1 | cut -d: -f1)"; le="$(grep -n '^# <<< dw-settle$' "$PDG" | head -1 | cut -d: -f1)"
awk '/^# >>> dw-settle/{f=1} f{print} /^# <<< dw-settle$/{f=0}' "$PDG" > "$BLK"
if [[ "$nb" == 1 && "$ne" == 1 && "${lb:-0}" -lt "${le:-0}" ]] \
   && grep -q '^_dw_settle(){$' "$BLK" && grep -q '^_dws_run(){$' "$BLK"; then
  ok "X1: 成对标记各恰一处, 抽出 $(wc -l < "$BLK") 行, 含 _dw_settle 与 _dws_run"
else
  bad "X1: 标记 / 抽取不成立(开始 $nb 处, 结束 $ne 处, 行 ${lb:-?}–${le:-?}); 后面各格没有可执行的原文"
  echo "通过 $pass, 失败 $nfail"; exit 1
fi
COLOR="$BOX/color.sh"; grep -E '^c_[gy]\(\)\{.*\}$' "$PDG" > "$COLOR"
[[ "$(grep -c . "$COLOR")" == 2 ]] && ok "X2: c_g / c_y 各取到一行原文" || { bad "X2: c_g / c_y 取不到唯一原文"; exit 1; }
DISP="$BOX/disp.txt"
awk '/^case "[$][{]1:-menu[}]" in$/{f=1; next} f&&/^esac$/{f=0} f&&/^  __migrate\)/{print}' "$PDG" > "$DISP"
[[ "$(grep -c . "$DISP")" == 1 ]] && grep -q ';;$' "$DISP" \
  && ok "X3: 顶层分发器里恰有一条完整的 __migrate 分支" || { bad "X3: __migrate 分支取不到唯一完整的一条"; exit 1; }

# ── 夹具 ─────────────────────────────────────────────────────────────────────
HA=0123456789abcdef0123456789abcdef
st(){ printf 'LoadState=%s\nUnitFileState=%s\nActiveState=%s\nSubState=%s\nResult=%s\nNRestarts=%s\nInvocationID=%s\n' "$@"; }
SS_HDR='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process'
SS_OWN="$SS_HDR"$'\n''UNCONN 0      0      127.0.0.1:5399      0.0.0.0:*         users:(("python3",pid=4242,fd=3))'
CG_UNIT=/system.slice/pdg-dotwitness.service
# 一格一个夹具目录: <种类>.<序号> 是第几次调用的输出, 没有就用 <种类>.dflt; 同名加 .rc 是退出码。
fx(){ # $1=格 $2=种类.序号 $3=内容 [$4=退出码]
  local d="$BOX/c-$1/fx"; mkdir -p "$d"; printf '%s\n' "$3" > "$d/$2"; [[ -n "${4:-}" ]] && printf '%s\n' "$4" > "$d/$2.rc"; return 0; }
healthy(){ # $1=格: 默认健康(active + 5399 归 unit)
  fx "$1" show.dflt "$(st loaded enabled active running success 0 $HA)"; fx "$1" ss.dflt "$SS_OWN"
  fx "$1" cg.dflt "$CG_UNIT"; fx "$1" proc.4242 "0::$CG_UNIT"; }

# 替身。计数从记录文件里数(调用常发生在命令替换的子壳里, 内存计数器带不回来)。
STUBS="$BOX/stubs.sh"
cat > "$STUBS" <<'EOF'
_n(){ local n; n="$(command grep -cE "^$1( |\$)" "$LOG")"; printf '%s' "$((n))"; }
_fx(){ local f="$FX/$1.$2" rc=0; [[ -e "$f" ]] || f="$FX/$1.dflt"
  [[ -e "$f" ]] && command cat "$f"; [[ -e "$f.rc" ]] && rc="$(command cat "$f.rc")"; return "$rc"; }
systemctl(){
  case "$*" in
    "show pdg-dotwitness -p LoadState -p UnitFileState -p ActiveState -p SubState -p Result -p NRestarts -p InvocationID --no-pager")
      echo state >> "$LOG"; _fx show "$(_n state)" ;;
    "show pdg-dotwitness -p ControlGroup --value") echo cg >> "$LOG"; _fx cg "$(_n cg)" ;;
    "reset-failed pdg-dotwitness") echo reset-failed >> "$LOG"; _fx reset "$(_n reset-failed)" ;;
    "start pdg-dotwitness") echo start >> "$LOG"; _fx start "$(_n start)" ;;
    *) echo "systemctl-other $*" >> "$LOG"; return 0 ;;
  esac
}
ss(){ echo "ss $*" >> "$LOG"; _fx ss "$(_n ss)"; }
cat(){
  if [[ $# == 1 && "$1" == /proc/*/cgroup ]]; then
    echo "proc $1" >> "$LOG"; local p="${1#/proc/}"; p="${p%/cgroup}"
    [[ -f "$FX/proc.$p" ]] || return 1; command cat "$FX/proc.$p"; return 0
  fi
  command cat "$@"
}
sleep(){ echo "sleep $*" >> "$LOG"; [[ -e "$FX/sleep.exit" ]] && exit "$(command cat "$FX/sleep.exit")"; return 0; }
EOF

# 直接调 _dw_settle 的一格。$1=格 其余=传给 _dw_settle 的参数。留下 out / log / rc。
settle(){
  local c="$1"; shift; local d="$BOX/c-$c"; mkdir -p "$d/fx"; : > "$d/log"
  { echo 'set -uo pipefail'; printf 'LOG=%q; FX=%q\n' "$d/log" "$d/fx"
    command cat "$COLOR" "$STUBS" "$BLK"
    echo '_dw_settle "$@"; echo "SETTLE_RC=$?"'; } > "$d/run.sh"
  bash "$d/run.sh" "$@" > "$d/out" 2>&1; echo "$?" > "$d/prc"
}
cnt(){ local n; n="$(grep -cE "^$2( |\$)" "$BOX/c-$1/log")"; printf '%s' "$((n))"; }
# 期望: 格 说明 期望文字(固定子串) reset start 状态查询 sleep
chk(){
  local c="$1" what="$2" want="$3" er="$4" es="$5" eq="$6" ez="$7" d="$BOX/c-$1" got
  got="$(cnt "$c" reset-failed)/$(cnt "$c" start)/$(cnt "$c" systemctl-other)/$(cnt "$c" state)/$(cnt "$c" sleep)"
  if [[ "$(command cat "$d/prc")" != 0 ]]; then bad "$c: 执行无效 —— 生成脚本退出 $(command cat "$d/prc")(不判定: $what)"; return; fi
  if [[ "$got" == "$er/$es/0/$eq/$ez" ]] && grep -q '^SETTLE_RC=0$' "$d/out" && grep -qF -- "$want" "$d/out"; then
    ok "$c: $what(动作 $got)"
  else
    bad "$c: $what —— 实得动作 $got(期望 $er/$es/0/$eq/$ez), 返回 $(grep -o 'SETTLE_RC=[0-9]*' "$d/out"), 输出: $(grep -v '^SETTLE_RC' "$d/out" | head -3)"
  fi
}
T_S1='核验通过 —— 运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有'
T_S2='本步不启动、不改自启; 迁移链前面的步骤是否改动过它的自启状态, 本步不作结论'
T_S3='状态未取得('
T_S4='已做一次定向恢复(reset-failed 退出 0, start 退出 0), 恢复后运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有 —— 本次核验已恢复'
T_S6='未就绪('
T_S7='服务 active, 但 127.0.0.1:5399'

echo
echo "══ 一. 固定参数: 缺少或不对就不查询、不动作、不输出 ══"
for p in P1 P2 P3 P4; do
  mkdir -p "$BOX/c-$p/fx"; healthy "$p"
  case $p in P1) settle P1 ;; P2) settle P2 --after ;; P3) settle P3 --after-migrate --after-migrate ;; P4) settle P4 --AFTER-MIGRATE ;; esac
  if [[ "$(command cat "$BOX/c-$p/prc")" == 0 && ! -s "$BOX/c-$p/log" && "$(command cat "$BOX/c-$p/out")" == "SETTLE_RC=0" ]]; then
    ok "$p: 参数不对 ⇒ 记录 0 行、无输出、返回 0"
  else bad "$p: 参数不对却有查询 / 动作 / 输出: $(head -3 "$BOX/c-$p/log" | tr '\n' ' ') / $(head -2 "$BOX/c-$p/out" | tr '\n' ' ')"; fi
done

echo
echo "══ 二. 健康与只观察的状态 ══"
healthy S1a; settle S1a --after-migrate; chk S1a "健康, 两次观察即成立 ⇒ 核验通过" "$T_S1" 0 0 3 1
healthy S1b; fx S1b ss.1 "$SS_HDR"; fx S1b ss.2 "$SS_HDR"; settle S1b --after-migrate
chk S1b "监听第 3 次才出现 ⇒ 第 3、4 次连续成立后核验通过" "$T_S1" 0 0 5 3
healthy S2a; fx S2a show.dflt "$(st loaded disabled inactive dead success 0 '')"; settle S2a --after-migrate
chk S2a "disabled ⇒ 只报观察, 不启动" "$T_S2" 0 0 1 0
healthy S2b; fx S2b show.dflt "$(st loaded masked inactive dead success 0 '')"; settle S2b --after-migrate
chk S2b "UnitFileState=masked ⇒ 只报观察" "$T_S2" 0 0 1 0
healthy S2c; fx S2c show.dflt "$(st masked masked inactive dead success 0 '')"; settle S2c --after-migrate
chk S2c "LoadState=masked ⇒ 只报观察" "$T_S2" 0 0 1 0

echo
echo "══ 三. 未取得 / 输出无效: 不动作, 不报核验通过 ══"
healthy S3a; fx S3a show.1 "" 1; settle S3a --after-migrate; chk S3a "systemctl show 退出 1" "$T_S3" 0 0 1 0
healthy S3b; fx S3b show.1 "$(st loaded enabled failed failed start-limit-hit 5 '')" 1; settle S3b --after-migrate
chk S3b "show 先输出 start-limit-hit 再退出 1 ⇒ 已输出的内容不采信, 不恢复" "$T_S3" 0 0 1 0
healthy S3c; fx S3c show.1 "$(st loaded enabled active running success 0 $HA | grep -v '^Result=')"; settle S3c --after-migrate
chk S3c "缺 Result 行" "$T_S3" 0 0 1 0
healthy S3d; fx S3d show.1 "$(st loaded enabled failed failed start-limit-hit 5 ''; echo 'Result=success')"; settle S3d --after-migrate
chk S3d "Result 重复" "$T_S3" 0 0 1 0
healthy S3e; fx S3e show.1 "$(st loaded enabled failed failed start-limit-hit x5 '')"; settle S3e --after-migrate
chk S3e "NRestarts 不是数字" "$T_S3" 0 0 1 0
healthy S3f; fx S3f show.1 "$(st loaded enabled active running success 0 '')"; settle S3f --after-migrate
chk S3f "active 但 InvocationID 为空" "$T_S3" 0 0 1 0
healthy S3g; fx S3g ss.dflt "$SS_OWN" 1; settle S3g --after-migrate; chk S3g "active, ss 退出 1" "$T_S3" 0 0 2 0
healthy S3h; fx S3h ss.dflt "$SS_HDR"$'\n''UNCONN 0      0      127.0.0.1:5399      0.0.0.0:*'; settle S3h --after-migrate
chk S3h "监听行里取不到 pid ⇒ 归属未取得, 不是没有监听" "$T_S3" 0 0 2 0
healthy S3i; fx S3i cg.dflt "" 1; settle S3i --after-migrate; chk S3i "ControlGroup 查询退出 1" "$T_S3" 0 0 2 0
healthy S3j; rm -f "$BOX/c-S3j/fx/proc.4242"; settle S3j --after-migrate; chk S3j "/proc/<pid>/cgroup 读取失败" "$T_S3" 0 0 2 0
healthy S3k; fx S3k show.dflt "$(st not-found '' inactive dead success 0 '')"; settle S3k --after-migrate
chk S3k "LoadState=not-found" "$T_S3" 0 0 1 0
healthy S3l; fx S3l show.dflt "$(st loaded static inactive dead success 0 '')"; settle S3l --after-migrate
chk S3l "UnitFileState=static(不在判定范围)" "$T_S3" 0 0 1 0
grep -qF "$T_S1" "$BOX"/c-S3?/out && bad "S3*: 有一格在未取得时报了核验通过" || ok "S3*: 未取得的各格都没有报核验通过"

echo
echo "══ 四. start-limit-hit: 只做一次定向恢复 ══"
SLH="$(st loaded enabled failed failed start-limit-hit 5 '')"
healthy S4; fx S4 show.1 "$SLH"; settle S4 --after-migrate
chk S4 "有效确认的 start-limit-hit ⇒ reset-failed 1 次、start 1 次, 两次成立后报本次核验已恢复" "$T_S4" 1 1 3 1
grep -qF 'NRestarts=5' "$BOX/c-S4/out" && ok "S4b: 报告带观察到的 NRestarts" || bad "S4b: 报告没带 NRestarts"
healthy S5a; fx S5a show.1 "$SLH"; fx S5a reset.dflt "" 1; settle S5a --after-migrate
chk S5a "reset-failed 退出 1 ⇒ 不执行 start" "reset-failed 退出 1, 未执行 start; 不再重试" 1 0 1 0
healthy S5b; fx S5b show.1 "$SLH"; fx S5b start.dflt "" 1; settle S5b --after-migrate
chk S5b "start 退出 1 ⇒ 不再重试" "reset-failed 退出 0, start 退出 1; 不再重试" 1 1 1 0
healthy S5c; fx S5c show.dflt "$SLH"; settle S5c --after-migrate
chk S5c "恢复后 10 次都 failed ⇒ 确认未就绪" "但恢复后确认未就绪(最后一次观察 ActiveState=failed" 1 1 11 9
healthy S5d; fx S5d show.1 "$SLH"; fx S5d show.2 "$(st loaded enabled active running success 0 $HA)" 1; settle S5d --after-migrate
chk S5d "恢复后第 1 次观察 show 退出 1、之后都健康 ⇒ 观察未取得(后面的成功冲不掉)" "但恢复后观察未取得(第 1 次观察: systemctl show 退出 1" 1 1 2 0
healthy S5e; fx S5e show.1 "$SLH"; fx S5e proc.4242 "0::/user.slice/user-0.slice/session-1.scope"; settle S5e --after-migrate
chk S5e "恢复后 active 但 5399 归别的进程(10 次)⇒ 确认未就绪" "但恢复后确认未就绪(最后一次观察 active 但 127.0.0.1:5399 由别的进程持有" 1 1 11 9
_claim=""; for c in S5a S5b S5c S5d S5e; do grep -qF '本次核验已恢复' "$BOX/c-$c/out" && _claim="$_claim $c"; done
[[ -z "$_claim" ]] && ok "S5*: 恢复不成立的五格都没有写本次核验已恢复" || bad "S5*: 恢复没成却写了本次核验已恢复:$_claim"

echo
echo "══ 五. 其它未就绪 / 监听不对: 不重置、不启动 ══"
healthy S6a; fx S6a show.dflt "$(st loaded enabled failed failed exit-code 2 '')"; settle S6a --after-migrate
chk S6a "failed 但 Result=exit-code ⇒ 不恢复" "$T_S6" 0 0 1 0
healthy S6b; fx S6b show.dflt "$(st loaded enabled inactive dead success 0 '')"; settle S6b --after-migrate
chk S6b "inactive / dead" "$T_S6" 0 0 1 0
healthy S6c; fx S6c show.dflt "$(st loaded enabled activating start success 0 $HA)"; settle S6c --after-migrate
chk S6c "activating" "$T_S6" 0 0 1 0
healthy S6d; i=1; for h in 0 1 2 3 4 5 6 7 8 9 a; do fx S6d "show.$i" "$(st loaded enabled active running success 0 "${h}123456789abcdef0123456789abcdef")"; i=$((i+1)); done
settle S6d --after-migrate; chk S6d "每次观察都是新实例 ⇒ 未就绪(实例在变)" "InvocationID 在变" 0 0 11 9
healthy S7a; fx S7a ss.dflt "$SS_HDR"; settle S7a --after-migrate
chk S7a "active 但 10 次都没有监听" "$T_S7 没有监听; 本步不处理" 0 0 11 9
healthy S7b; fx S7b proc.4242 "0::/user.slice/user-0.slice/session-1.scope"; settle S7b --after-migrate
chk S7b "active 但监听者 cgroup 不是这个 unit" "$T_S7 由别的进程持有(unit: $CG_UNIT; 监听者: 4242:/user.slice" 0 0 11 9

echo
echo "══ 五之二. 健康要按完整条件核(loaded + enabled + active / running), 取值要认识 ══"
# 首次观察健康、之后某个字段变了: 每一次观察都按完整条件判, 不能只看 active + 监听归属。
OKST="$(st loaded enabled active running success 0 $HA)"
healthy H1; fx H1 show.1 "$OKST"; fx H1 show.dflt "$(st bad-setting enabled active running success 0 $HA)"; settle H1 --after-migrate
chk H1 "之后 LoadState=bad-setting ⇒ 有效未就绪, 不报核验通过" "未就绪(观察期内没能确认就绪; 最后一次观察" 0 0 11 9
healthy H2; fx H2 show.1 "$OKST"; fx H2 show.dflt "$(st loaded disabled active running success 0 $HA)"; settle H2 --after-migrate
chk H2 "之后 UnitFileState=disabled ⇒ 有效未就绪" "UnitFileState=disabled" 0 0 11 9
healthy H3; fx H3 show.1 "$OKST"; fx H3 show.dflt "$(st loaded enabled active reload success 0 $HA)"; settle H3 --after-migrate
chk H3 "之后 SubState=reload(active 但不是 running)⇒ 有效未就绪" "SubState=reload" 0 0 11 9
healthy H4; fx H4 show.dflt "$(st loaded enabled active exited success 0 $HA)"; settle H4 --after-migrate
chk H4 "全程 active / exited ⇒ 有效未就绪" "SubState=exited" 0 0 11 9
healthy H5a; fx H5a show.1 "$OKST"; fx H5a show.dflt "$(st loaded enabled active bogus-state success 0 $HA)"; settle H5a --after-migrate
chk H5a "之后 SubState 不认识 ⇒ 观察未取得(不是未就绪)" "状态未取得(第 1 次观察: systemctl show 输出无效(SubState=bogus-state 不认识))" 0 0 2 0
healthy H5b; fx H5b show.dflt "$(st loaded enabled active running bogus-result 0 $HA)"; settle H5b --after-migrate
chk H5b "Result 不认识 ⇒ 首次查询即输出无效" "状态未取得(systemctl show 输出无效(Result=bogus-result 不认识))" 0 0 1 0
healthy H5c; fx H5c show.1 "$OKST"; fx H5c show.dflt "$(st bogus-load enabled active running success 0 $HA)"; settle H5c --after-migrate
chk H5c "之后 LoadState 不认识 ⇒ 观察未取得" "LoadState=bogus-load 不认识" 0 0 2 0
healthy H6; fx H6 show.1 "$SLH"; fx H6 show.dflt "$(st loaded enabled active exited success 0 $HA)"; settle H6 --after-migrate
chk H6 "恢复后 active / exited ⇒ 确认未就绪, 不写已恢复" "但恢复后确认未就绪(最后一次观察 ActiveState=active, SubState=exited" 1 1 11 9
healthy H7; fx H7 show.1 "$SLH"; fx H7 show.dflt "$(st loaded disabled active running success 0 $HA)"; settle H7 --after-migrate
chk H7 "恢复后 UnitFileState=disabled ⇒ 确认未就绪, 不写已恢复" "UnitFileState=disabled); 不再重试" 1 1 11 9

echo
echo "══ 五之三. 多个监听者: 每个都要读到, 读不到不能被后面的匹配盖掉 ══"
row(){ printf 'UNCONN 0      0      127.0.0.1:5399      0.0.0.0:*         users:(("python3",pid=%s,fd=3))' "$1"; }
two(){ fx "$1" ss.dflt "$SS_HDR"$'\n'"$(row "$2")"$'\n'"$(row "$3")"; }
reads(){ grep -c "^proc /proc/$2/cgroup\$" "$BOX/c-$1/log"; }
CG_FOREIGN=/user.slice/user-0.slice/session-1.scope
healthy O1; two O1 4243 4242; settle O1 --after-migrate
chk O1 "[4243 读不到, 4242 归 unit] ⇒ 归属未取得" "读不到 127.0.0.1:5399 监听进程的 cgroup(pid: 4243)" 0 0 2 0
healthy O2; two O2 4242 4243; settle O2 --after-migrate
chk O2 "顺序调换 [4242 归 unit, 4243 读不到] ⇒ 同样未取得" "读不到 127.0.0.1:5399 监听进程的 cgroup(pid: 4243)" 0 0 2 0
for c in O1 O2; do
  [[ "$(reads "$c" 4242)" == 1 && "$(reads "$c" 4243)" == 1 ]] \
    && ok "$c: 两个监听者都真的读过一次(4242 / 4243 各 1 次), 没有在匹配处短路" \
    || bad "$c: 读取记录不对(4242 $(reads "$c" 4242) 次, 4243 $(reads "$c" 4243) 次)"
done
healthy O3; two O3 4343 4242; fx O3 proc.4343 "0::$CG_FOREIGN"; settle O3 --after-migrate
chk O3 "全部读到, 一个外来一个归 unit ⇒ 核验通过(有一个归它管)" "$T_S1" 0 0 3 1
healthy O3b; two O3b 4242 4244; fx O3b proc.4244 "0::$CG_UNIT"; settle O3b --after-migrate
chk O3b "全部读到, 两个都归 unit ⇒ 核验通过" "$T_S1" 0 0 3 1
healthy O4; two O4 4343 4344; fx O4 proc.4343 "0::$CG_FOREIGN"; fx O4 proc.4344 "0::$CG_FOREIGN"; settle O4 --after-migrate
chk O4 "全部读到, 都是外来 ⇒ 由别的进程持有" "$T_S7 由别的进程持有" 0 0 11 9
healthy O5; fx O5 show.1 "$SLH"; two O5 4243 4242; settle O5 --after-migrate
chk O5 "恢复后 [4243 读不到, 4242 归 unit] ⇒ 恢复后观察未取得, 不写已恢复" "但恢复后观察未取得(第 1 次观察: 读不到 127.0.0.1:5399 监听进程的 cgroup(pid: 4243))" 1 1 2 0
_claim=""; for c in H1 H2 H3 H4 H5a H5b H5c H6 H7 O1 O2 O5; do grep -qE '核验通过|本次核验已恢复' "$BOX/c-$c/out" && _claim="$_claim $c"; done
[[ -z "$_claim" ]] && ok "H* / O1 / O2 / O5: 都没有报核验通过或本次核验已恢复" || bad "这些格报了健康 / 已恢复:$_claim"

echo
echo "══ 六. 退出政策甲: 内部意外不外溢, 也不静默 ══"
healthy F1; printf '7\n' > "$BOX/c-F1/fx/sleep.exit"; settle F1 --after-migrate
chk F1 "观察中替身直接 exit 7 ⇒ 只结束子壳, 仍返回 0, 具名告警本次核验未完成并带原始退出码" "本次核验未完成(核验过程异常退出, 退出码 7)" 0 0 2 1
healthy F2; fx F2 show.1 "$SLH"; printf '9\n' > "$BOX/c-F2/fx/sleep.exit"; settle F2 --after-migrate
chk F2 "恢复命令发出之后替身 exit 9 ⇒ 仍返回 0, 具名告警, 不再追加恢复" "本次核验未完成(核验过程异常退出, 退出码 9)" 1 1 2 1
_fc=""; for c in F1 F2; do grep -qE '核验通过|本次核验已恢复' "$BOX/c-$c/out" && _fc="$_fc $c"; done
[[ -z "$_fc" ]] && ok "F1 / F2: 内部异常时不声称核验通过或已恢复" || bad "内部异常却声称健康 / 已恢复:$_fc"

echo
echo "══ 七. 汇总约束(T1) ══"
_bad_word="$(grep -lE '用尽|本次升级的重启|原因是' "$BOX"/c-*/out 2>/dev/null)"
[[ -z "$_bad_word" ]] && ok "T1a: 所有格的报告里都没有原因推断(用尽 / 本次升级的重启 / 原因是)" || bad "T1a: 报告写了原因推断: $_bad_word"
_nz=""; for d in "$BOX"/c-[PS]*; do grep -q '^SETTLE_RC=0$' "$d/out" || _nz="$_nz ${d##*/c-}"; done
[[ -z "$_nz" ]] && ok "T1b: 所有直接调用的格 _dw_settle 都返回 0" || bad "T1b: 这些格返回非 0:$_nz"
_oth="$(cat "$BOX"/c-*/log 2>/dev/null | grep -c '^systemctl-other')"
[[ "$_oth" == 0 ]] && ok "T1c: 所有格都没有 enable / restart / stop / kill 等其它 systemctl 动作" || bad "T1c: 出现 $_oth 次其它 systemctl 动作"

echo
echo "══ 八. 派发行(乙): 驱动分发器里 __migrate 那一条原文 ══"
# need_root / _lock / run_all_migrations 用各自的替身记录调用与参数; _dw_settle 跑真身, 外面包一层记录。
wire(){ # $1=格 $2=迁移返回码 [$3=root|lock 拒绝]  其余夹具沿用 healthy
  local c="$1" d="$BOX/c-$1"; mkdir -p "$d/fx"; : > "$d/log"
  { echo 'set -uo pipefail'; printf 'LOG=%q; FX=%q; T_MIG=%q; T_DENY=%q\n' "$d/log" "$d/fx" "$2" "${3:-}"
    command cat "$COLOR" "$STUBS" "$BLK"
    echo 'need_root(){ echo "need_root $#:$*" >> "$LOG"; [[ "$T_DENY" == root ]] && exit 1; return 0; }'
    echo '_lock(){ echo "_lock $#" >> "$LOG"; [[ "$T_DENY" == lock ]] && exit 1; return 0; }'
    echo 'run_all_migrations(){ echo "run_all_migrations $#" >> "$LOG"; return "$T_MIG"; }'
    echo 'eval "$(declare -f _dw_settle | sed "1s/^_dw_settle /_dw_settle_real /")"'
    echo '_dw_settle(){ echo "_dw_settle $#:$*" >> "$LOG"; _dw_settle_real "$@"; }'
    echo 'case "${1:-menu}" in'; command cat "$DISP"; echo 'esac'; } > "$d/run.sh"
  bash "$d/run.sh" __migrate --probe-a "值 带空格" > "$d/out" 2>&1; echo "$?" > "$d/prc"
}
seq_of(){ grep -E '^(need_root|_lock|run_all_migrations|_dw_settle) ' "$BOX/c-$1/log" | tr '\n' '|'; }
healthy W1; wire W1 0
if [[ "$(command cat "$BOX/c-W1/prc")" == 0 && "$(seq_of W1)" == "need_root 1:__migrate|_lock 0|run_all_migrations 0|_dw_settle 1:--after-migrate|" ]] \
   && [[ "$(cnt W1 state)" == 3 ]] && grep -qF "$T_S1" "$BOX/c-W1/out"; then
  ok "W1: 迁移返回 0 ⇒ 新步骤恰好一次、参数恰为 [--after-migrate](外来参数没递进去), 外层退出 0"
else bad "W1: 实得顺序 $(seq_of W1) 退出 $(command cat "$BOX/c-W1/prc")"; fi
healthy W1b; fx W1b show.dflt "$(st loaded enabled failed failed exit-code 2 '')"; wire W1b 0
if [[ "$(command cat "$BOX/c-W1b/prc")" == 0 && "$(seq_of W1b)" == *"_dw_settle 1:--after-migrate|" ]] && grep -qF "$T_S6" "$BOX/c-W1b/out"; then
  ok "W1b: 迁移返回 0、新步骤走告警路径 ⇒ 告警照打, 外层仍退出 0(成功的迁移没被改成失败)"
else bad "W1b: 实得顺序 $(seq_of W1b) 退出 $(command cat "$BOX/c-W1b/prc")"; fi
for m in 1 2 137; do
  c="W-rc$m"; healthy "$c"; wire "$c" "$m"
  if [[ "$(command cat "$BOX/c-$c/prc")" == "$m" && "$(seq_of "$c")" == "need_root 1:__migrate|_lock 0|run_all_migrations 0|" ]] \
     && [[ "$(grep -cvE '^(need_root|_lock|run_all_migrations) ' "$BOX/c-$c/log")" == 0 && ! -s "$BOX/c-$c/out" ]]; then
    ok "$c: 迁移返回 $m ⇒ 新步骤零查询、零动作、零输出, 外层退出码原样是 $m"
  else bad "$c: 外层退出 $(command cat "$BOX/c-$c/prc")(应为 $m), 记录 $(tr '\n' '|' < "$BOX/c-$c/log"), 输出 $(head -2 "$BOX/c-$c/out" | tr '\n' ' ')"; fi
done
healthy W5; wire W5 0 root
[[ "$(command cat "$BOX/c-W5/prc")" == 1 && "$(tr '\n' '|' < "$BOX/c-W5/log")" == "need_root 1:__migrate|" ]] \
  && ok "W5: 权限拒绝 ⇒ 迁移与新步骤都不执行, 外层退出 1" || bad "W5: 记录 $(tr '\n' '|' < "$BOX/c-W5/log") 退出 $(command cat "$BOX/c-W5/prc")"
healthy W6; wire W6 0 lock
[[ "$(command cat "$BOX/c-W6/prc")" == 1 && "$(tr '\n' '|' < "$BOX/c-W6/log")" == "need_root 1:__migrate|_lock 0|" ]] \
  && ok "W6: 锁拒绝 ⇒ 迁移与新步骤都不执行, 外层退出 1" || bad "W6: 记录 $(tr '\n' '|' < "$BOX/c-W6/log") 退出 $(command cat "$BOX/c-W6/prc")"

echo
echo "══ 九. 其它两个调用方不执行新步骤 ══"
fnx(){ sed -n "/^$2(){\$/,/^}\$/p" "$1"; }
# 静态: 不是注释的 _dw_settle 只有定义行与派发行; 两个调用方与迁移链里都没有它。
_uses="$(grep -n '_dw_settle' "$PDG" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v ':_dw_settle(){$')"
[[ "$(grep -c . <<< "$_uses")" == 1 && "$_uses" == *'  __migrate)'*'run_all_migrations && _dw_settle --after-migrate;;' ]] \
  && ok "W7a: 新步骤的调用点只有派发行一处" || bad "W7a: 调用点不止派发行: $_uses"
for f in cmd_migrate cmd_platform run_all_migrations; do
  fnx "$PDG" "$f" > "$BOX/fn-$f.sh"
  # 只看代码行(迁移链的注释里提到过 __migrate)。
  if [[ ! -s "$BOX/fn-$f.sh" || "$(grep -c "^$f(){\$" "$PDG")" != 1 ]]; then bad "W7b: 抽不到唯一的 $f, 不判定"
  elif grep -vE '^[[:space:]]*#' "$BOX/fn-$f.sh" > "$BOX/code-$f.sh"; grep -q '_dw_settle\|__migrate' "$BOX/code-$f.sh"; then
    bad "W7b: $f 的代码行里出现了 _dw_settle 或 __migrate"
  else ok "W7b: $f 的代码行里没有 _dw_settle, 也不经 __migrate 派发($(wc -l < "$BOX/fn-$f.sh") 行)"; fi
done
grep -q '^  run_all_migrations || true ' "$BOX/fn-cmd_platform.sh" && grep -qF 'PDG_UPDATE_SVCSTATE="$snap/svcstate.tsv" run_all_migrations || rc=$?' "$BOX/fn-cmd_migrate.sh" \
  && ok "W7c: cmd_platform 的 \`run_all_migrations || true\` 与 cmd_migrate 的 \`… run_all_migrations || rc=\$?\` 原文仍在" \
  || bad "W7c: 两个调用方调用迁移链的原文变了"
# 动态: 真跑 cmd_migrate 原文。它依赖的函数都用记录替身(快照造一个带 svcstate.tsv 的目录), 迁移链返回 0 / 1 各一格。
caller(){ # $1=格 $2=迁移返回码
  local c="$1" d="$BOX/c-$1"; mkdir -p "$d/snap"; : > "$d/log"; : > "$d/snap/svcstate.tsv"
  { echo 'set -uo pipefail'; printf 'LOG=%q; SNAPD=%q; T_MIG=%q\n' "$d/log" "$d/snap" "$2"
    command cat "$COLOR"
    echo 'need_root(){ :; }; _lock(){ :; }'
    echo 'cmd_snapshot(){ _PDG_SNAP_CREATED="$SNAPD"; echo cmd_snapshot >> "$LOG"; }'
    echo '_pdg_svcstate_plan(){ echo "_pdg_svcstate_plan $*" >> "$LOG"; return 0; }'
    echo '_tx_audit(){ echo "_tx_audit $*" >> "$LOG"; }'
    echo 'run_all_migrations(){ echo "run_all_migrations $#" >> "$LOG"; return "$T_MIG"; }'
    echo '_dw_settle(){ echo "_dw_settle $#:$*" >> "$LOG"; return 0; }'
    command cat "$BOX/fn-cmd_migrate.sh"
    echo 'cmd_migrate; echo "CALLER_RC=$?"'; } > "$d/run.sh"
  bash "$d/run.sh" > "$d/out" 2>&1; echo "$?" > "$d/prc"
}
for m in 0 1; do
  c="W9-rc$m"; caller "$c" "$m"; want=$(( m == 0 ? 0 : 1 ))
  if [[ "$(command cat "$BOX/c-$c/prc")" == 0 && "$(grep -c '^run_all_migrations ' "$BOX/c-$c/log")" == 1 ]] \
     && ! grep -q '^_dw_settle' "$BOX/c-$c/log" && grep -q "^CALLER_RC=$want\$" "$BOX/c-$c/out"; then
    ok "$c: 真跑 cmd_migrate, 迁移链返回 $m ⇒ 迁移链 1 次、新步骤 0 次, cmd_migrate 返回 $want"
  else bad "$c: 记录 $(tr '\n' '|' < "$BOX/c-$c/log") 输出 $(tail -2 "$BOX/c-$c/out" | tr '\n' ' ')"; fi
done

# 动态: 真跑迁移链原文(两个调用方都直接调它)。链里的 migrate_* 全换成记录替身, 前置门放行;
# 链内没有任何一处会调到新步骤 —— 不论链返回 0 还是非 0。
# cmd_platform 本身没有在这里驱动: 它在走到迁移链之前要用 shell 重定向写 /etc/privdns-gateway/platform,
# 没有挂载隔离写不进去; 它对新步骤的覆盖靠上面的 W7b / W7c 与这里的链级动态格。
chain(){ # $1=格 $2=migrate_dotwitness 的返回码
  local c="$1" d="$BOX/c-$1"; mkdir -p "$d"; : > "$d/log"
  { echo 'set -uo pipefail'; printf 'LOG=%q; T_DW=%q\n' "$d/log" "$2"
    command cat "$COLOR"; grep -E '^c_r\(\)\{.*\}$' "$PDG"
    grep -oE 'migrate_[a-z0-9_]+' "$PDG" | sort -u | while IFS= read -r f; do printf '%s(){ echo "%s" >> "$LOG"; return 0; }\n' "$f" "$f"; done
    echo 'migrate_dotwitness(){ echo migrate_dotwitness >> "$LOG"; return "$T_DW"; }'
    echo '_retire_precheck(){ return 0; }'
    echo '_dw_settle(){ echo "_dw_settle $#:$*" >> "$LOG"; return 0; }'
    echo 'command_not_found_handle(){ echo "unknown $1" >> "$LOG"; return 0; }'
    command cat "$BOX/fn-run_all_migrations.sh"
    echo 'run_all_migrations; echo "CHAIN_RC=$?"'; } > "$d/run.sh"
  bash "$d/run.sh" > "$d/out" 2>&1; echo "$?" > "$d/prc"
}
for m in 0 1; do
  c="W10-rc$m"; chain "$c" "$m"
  if [[ "$(command cat "$BOX/c-$c/prc")" == 0 && "$(grep -c '^migrate_dotwitness$' "$BOX/c-$c/log")" == 1 ]] \
     && grep -q "^CHAIN_RC=$m\$" "$BOX/c-$c/out" && ! grep -q '^_dw_settle' "$BOX/c-$c/log"; then
    ok "$c: 真跑迁移链原文, 链返回 $m ⇒ 链内调用 $(grep -c . "$BOX/c-$c/log") 次替身, 新步骤 0 次"
  else bad "$c: 输出 $(tail -2 "$BOX/c-$c/out" | tr '\n' ' ') 记录里的新步骤 $(grep -c '^_dw_settle' "$BOX/c-$c/log") 次"; fi
done

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
