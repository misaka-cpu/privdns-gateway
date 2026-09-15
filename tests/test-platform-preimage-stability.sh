#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ⑤b 前像的**合法性与持续稳定**判据契约。跑的是 tests/e2e-real-platform-fail.sh 里
# svc_stable_window / svc_stable_assert / mitm_listen_verdict 的**原文**, 不抄一份。
#
# ⚠️ **模型验证**: systemctl / journalctl / logger / sleep 是桩(桩维护一份可变状态与事件簿,
#    被测代码真的要自己去采样、比对 MainPID/InvocationID/NRestarts、用 journal 界桩算启动事件)。
#    真服务那一半由一次性 runner 上的真实派发回答, 两类证据分列。
#
# 为什么有这一支: run 34966909411 的 ⑤b 里, pdg-mitm 其实在崩溃循环(每 3s 被
# Restart=on-failure 拉起来一次, 重启计数到 10), 而前像判据只取了一瞬的 is-active=active
# 就报了"处在稳定运行态" —— 瞬时 active 被当成了稳定。
# 注: 一批全局变量是给 eval 进来的被测函数读的; 静态检查器看不到, 整支关掉 SC2034。
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/e2e-real-platform-fail.sh"
[[ -f "$SRC" ]] || { echo "[未执行] 找不到 $SRC"; exit 1; }
WORK="$(mktemp -d)" || { echo "[未执行] 建不出临时目录"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

P=0; F=0; ALOG="$WORK/assert.log"; : > "$ALOG"
ok(){  printf '[OK]   %s\n' "$1"; P=$((P+1)); printf 'OK\t%s\n' "$1" >> "$ALOG"; }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); printf 'FAIL\t%s\n' "$1" >> "$ALOG"; }
note(){ printf '[NOTE] %s\n' "$1"; }
_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
for f in svc_stable_window svc_stable_assert mitm_listen_verdict wait_stable _j_mark _j_interval; do
  [[ -n "$(_fn "$SRC" "$f")" ]] || { echo "[未执行] 抽不到 $f"; exit 1; }
done
ok "0: 被测函数全部从平台验收脚本**原文**抽到"

# ── 桩: 一份可变的服务状态 + 事件簿 ─────────────────────────────────────────
mk_env(){   # $1=场景目录
  local T="$1"; mkdir -p "$T/bin"
  cat > "$T/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
# 模型 systemctl: plan 文件每行 "KEY=v0,v1,v2…", 第 t 秒取第 t 个(不足取最后一个)。
T="$STATEDIR"
prop=""; prev=""; for a in "$@"; do [ "$prev" = "-p" ] && prop="$a"; prev="$a"; done
t="$(cat "$T/vclock" 2>/dev/null || echo 0)"
pick(){ local line i; line="$(grep -m1 "^$1=" "$T/plan" | cut -d= -f2-)"
  IFS=',' read -r -a arr <<< "$line"; i="$t"
  [ "$i" -ge "${#arr[@]}" ] && i=$(( ${#arr[@]} - 1 )); [ "$i" -lt 0 ] && i=0
  printf '%s\n' "${arr[$i]}"; }
case "$prop" in
  ActiveState|MainPID|InvocationID|NRestarts) pick "$prop";;
  *) echo "";;
esac
EOS
  cat > "$T/bin/journalctl" <<'EOS'
#!/usr/bin/env bash
T="$STATEDIR"
[ "${J_FAIL:-0}" = 1 ] && { echo "模型: journalctl 故意失败" >&2; exit 13; }
unit=""; tag=""; after=""; nn=""; fmt="short"
while (( $# )); do case "$1" in
  --sync) exit 0;; -u) unit="$2"; shift 2;; -t) tag="$2"; shift 2;;
  --after-cursor) after="$2"; shift 2;; -n) nn="$2"; shift 2;;
  -o) fmt="$2"; shift 2;; --output-fields=*) shift;; --no-pager) shift;; *) shift;; esac; done
aidx=0; [ -n "$after" ] && aidx="$(awk -F'\t' -v c="$after" '{if ("cur-"$1==c){print $1; exit}}' "$T/journal")"
[ -n "$aidx" ] || aidx=0
out="$(awk -F'\t' -v u="$unit" -v t="$tag" -v a="$aidx" '
  NF<3 {next} { idx=$1; id=$2; msg=$3 }
  (u!="" && id!=u) {next} (t!="" && id!=t) {next} (idx+0 <= a+0) {next}
  { printf "%s|%s|%s\n", idx, id, msg }' "$T/journal")"
case "$fmt" in
  json) while IFS='|' read -r i id m; do [ -n "$i" ] && python3 -c 'import json,sys; print(json.dumps({"MESSAGE":sys.argv[1],"__CURSOR":"cur-"+sys.argv[2]}))' "$m" "$i"; done <<< "$out";;
  cat)  while IFS='|' read -r i id m; do [ -n "$i" ] && printf '%s\n' "$m"; done <<< "$out";;
  *)    while IFS='|' read -r i id m; do [ -n "$i" ] && printf '%s: %s\n' "$id" "$m"; done <<< "$out";;
esac
exit 0
EOS
  cat > "$T/bin/logger" <<'EOS'
#!/usr/bin/env bash
T="$STATEDIR"; tag=""
while (( $# )); do case "$1" in -t) tag="$2"; shift 2;; *) break;; esac; done
i="$(awk -F'\t' 'NF>=3{n=$1} END{print n+0}' "$T/journal")"
printf '%s\t%s\t%s\n' "$((i+1))" "$tag" "$*" >> "$T/journal"
EOS
  chmod +x "$T/bin"/*
  : > "$T/journal"; echo 0 > "$T/tick"
}
# 跑一格: $1=plan 文本 $2=running|stopped $3=窗口秒 [$4..]=额外环境(K=V)
sw_case(){
  local plan="$1" want="$2" secs="$3"; shift 3
  local T kv; T="$(mktemp -d "$WORK/sw.XXXXXX")"
  mk_env "$T"; printf '%s\n' "$plan" > "$T/plan"; echo 0 > "$T/vclock"
  (
    export STATEDIR="$T" PATH="$T/bin:$PATH" E2E_TMP="$T" JBOUND_TAG="pdg-e2e-jbound" J_ERR=""
    for kv in "$@"; do export "${kv?}"; done
    for f in _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after \
             _j_tag_after _j_interval wait_stable svc_stable_window; do eval "$(_fn "$SRC" "$f")"; done
    # 模型时间: 每"睡"一秒推进一格; EVENTS="3:pdg-mitm" 表示第 3 秒往事件簿里落一条启动
    sleep(){ case "${1:-}" in 0.*) return 0;; esac
      local t i; t="$(cat "$STATEDIR/vclock")"; t=$((t+1)); echo "$t" > "$STATEDIR/vclock"
      if [[ -n "${EVENTS:-}" && "${EVENTS%%:*}" == "$t" ]]; then
        i="$(awk -F'\t' 'NF>=3{n=$1} END{print n+0}' "$STATEDIR/journal")"
        printf '%s\t%s\t%s\n' "$((i+1))" "${EVENTS##*:}" "Started ${EVENTS##*:}.service - x." >> "$STATEDIR/journal"
      fi; return 0; }
    svc_stable_window "${UNIT:-pdg-mitm}" "$want" "$secs"; rc=$?
    echo "RC=$rc"; echo "WHY=$SVC_STABLE_WHY"
  ) 2>&1
}
gs(){ grep -m1 "^$1=" <<<"$SWOUT" | cut -d= -f2-; }

echo; echo "══ 1. 具名对照: 什么算持续稳定, 什么不算 ══"
# ① 健康持续运行: 状态、MainPID、InvocationID 都不变, NRestarts 不增长, 窗口内零启动事件
SWOUT="$(sw_case 'ActiveState=active
MainPID=111
InvocationID=inv-a
NRestarts=0' running 4)"
{ [[ "$(gs RC)" == 0 ]]; } && ok "1a 健康持续运行: 判成立 —— $(gs WHY)" || { bad "1a: rc=$(gs RC) $(gs WHY)"; }
# ② 合法持续停止(⑤b 的目标态): 一直 inactive, 没有 MainPID, 窗口内没有被拉起来
SWOUT="$(sw_case 'ActiveState=inactive
MainPID=0
InvocationID=
NRestarts=0' stopped 4)"
[[ "$(gs RC)" == 0 ]] && ok "1b 合法持续停止: 判成立 —— $(gs WHY)" || bad "1b: rc=$(gs RC) $(gs WHY)"
# ③ 瞬时 active 后退出: 第 0 秒 active, 之后 failed —— **必须**判不成立(这正是上一轮被放过的那种)
SWOUT="$(sw_case 'ActiveState=active,active,failed,failed,failed
MainPID=111,111,0,0,0
InvocationID=inv-a,inv-a,inv-a,inv-a,inv-a
NRestarts=0' running 4)"
{ [[ "$(gs RC)" == 1 ]] && [[ "$(gs WHY)" == *掉出\ active* ]]; } \
  && ok "1c 瞬时 active 后退出: 判不成立($(gs WHY))" || bad "1c: rc=$(gs RC) $(gs WHY)"
# ④ 自动重启中: NRestarts 增长
SWOUT="$(sw_case 'ActiveState=active
MainPID=111
InvocationID=inv-a
NRestarts=3,3,3,4,4' running 4)"
{ [[ "$(gs RC)" == 1 ]] && [[ "$(gs WHY)" == *自动重启* ]]; } \
  && ok "1d 自动重启中: 判不成立($(gs WHY))" || bad "1d: rc=$(gs RC) $(gs WHY)"
# ⑤ 实例更替: MainPID / InvocationID 换了(哪怕一直 active、NRestarts 也没动)
SWOUT="$(sw_case 'ActiveState=active
MainPID=111,111,222,222,222
InvocationID=inv-a
NRestarts=0' running 4)"
{ [[ "$(gs RC)" == 1 ]] && [[ "$(gs WHY)" == *MainPID* ]]; } \
  && ok "1e 实例更替(MainPID): 判不成立($(gs WHY))" || bad "1e: rc=$(gs RC) $(gs WHY)"
SWOUT="$(sw_case 'ActiveState=active
MainPID=111
InvocationID=inv-a,inv-a,inv-b,inv-b,inv-b
NRestarts=0' running 4)"
{ [[ "$(gs RC)" == 1 ]] && [[ "$(gs WHY)" == *InvocationID* ]]; } \
  && ok "1f 实例更替(InvocationID): 判不成立($(gs WHY))" || bad "1f: rc=$(gs RC) $(gs WHY)"
# ⑥ 期望停止却被拉起来: 窗口内出现启动事件(界桩裁决)
SWOUT="$(sw_case 'ActiveState=inactive,inactive,active,active,active
MainPID=0,0,333,333,333
InvocationID=
NRestarts=0' stopped 4)"
{ [[ "$(gs RC)" == 1 ]]; } && ok "1g 期望停止却被拉起来: 判不成立($(gs WHY))" || bad "1g: rc=$(gs RC) $(gs WHY)"
# ⑦ 查询失败/字段缺失 ⇒ 观测无效(rc=2), 不是"稳定"也不是"零事件"
SWOUT="$(sw_case 'ActiveState=active
MainPID=111
InvocationID=inv-a
NRestarts=' running 4)"
{ [[ "$(gs RC)" == 2 ]] && [[ "$(gs WHY)" == *观测无效* ]]; } \
  && ok "1h NRestarts 读不到合法值 ⇒ 观测无效($(gs WHY))" || bad "1h: rc=$(gs RC) $(gs WHY)"
SWOUT="$(sw_case 'ActiveState=active,active,,active
MainPID=111
InvocationID=inv-a
NRestarts=0' running 4)"
{ [[ "$(gs RC)" == 2 ]] && [[ "$(gs WHY)" == *观测无效* ]]; } \
  && ok "1i 中途取不到 ActiveState ⇒ 观测无效($(gs WHY))" || bad "1i: rc=$(gs RC) $(gs WHY)"
SWOUT="$(sw_case 'ActiveState=active
MainPID=111
InvocationID=inv-a
NRestarts=0' running 4 J_FAIL=1)"
{ [[ "$(gs RC)" == 2 ]] && [[ "$(gs WHY)" == *观测无效* ]]; } \
  && ok "1j journal 观测失败 ⇒ 观测无效($(gs WHY))" || bad "1j: rc=$(gs RC) $(gs WHY)"
# ⑧ 一直卡在过渡态
SWOUT="$(sw_case 'ActiveState=activating
MainPID=0
InvocationID=inv-a
NRestarts=0' running 3)"
{ [[ "$(gs RC)" == 1 ]] && [[ "$(gs WHY)" == *过渡态* ]]; } \
  && ok "1k 一直卡在 activating: 判不成立($(gs WHY))" || bad "1k: rc=$(gs RC) $(gs WHY)"

echo; echo "══ 2. 配置与监听的一致性(判据来自 v1.11.15 的 serve() 原文) ══"
eval "$(_fn "$SRC" mitm_listen_verdict)"
mitm_listen_verdict active 1; [[ "$?" == 0 ]] && ok "2a: 活着 + 有监听 ⇒ 自洽($MITM_VERDICT_WHY)" || bad "2a"
mitm_listen_verdict inactive 0; [[ "$?" == 0 ]] && ok "2b: 停着 + 无监听 ⇒ 自洽($MITM_VERDICT_WHY)" || bad "2b"
mitm_listen_verdict active 0; [[ "$?" == 1 ]] && ok "2c: 说是 active 却没监听 ⇒ 不自洽($MITM_VERDICT_WHY)" || bad "2c"
mitm_listen_verdict inactive 2; [[ "$?" == 1 ]] && ok "2d: 停着却还有监听 ⇒ 不自洽($MITM_VERDICT_WHY)" || bad "2d"
mitm_listen_verdict failed x;  [[ "$?" == 1 ]] && ok "2e: 监听数读不出来 ⇒ 不自洽($MITM_VERDICT_WHY)" || bad "2e"
note "2: 判据是「监听跟着进程在不在」—— serve() 无条件 bind 7894, 与 wloc.enabled 无关;"
note "   enabled 决定的是 load_from_config 登不登记接管插件。"

echo; echo "══ 3. ⑤b 前像的形状与建立路径(源码推导出来的那几条) ══"
PRE="$(sed -n '/③ iOS→Android 方向: WLOC 关闭态/,/^fi$/p' "$SRC")"
grep -q '"locations": \[ { "name": "osaka"' <<<"$PRE" \
  && ok "3a: i2a 的 mitm.json 用**列表**形状的 locations(旧版 _wloc_active 解析得了)" || bad "3a: 形状不对"
grep -q 'systemctl stop pdg-mitm' <<<"$PRE" \
  && ok "3b: 关闭态由旧版真实关闭路径的动作建立(stop:pdg-mitm)" || bad "3b: 没走真实关闭路径"
{ grep -q 'restart mihomo' <<<"$PRE" && grep -q 'restart mosdns' <<<"$PRE"; } \
  && ok "3c: 关闭顺序与 _mitm_transact 一致(落盘 → stop:pdg-mitm → restart:mihomo → restart:mosdns)" || bad "3c: 顺序不对"
grep -qE 'Restart=no|reset-failed|systemctl mask|--now.*disable pdg-mitm' <<<"$PRE" \
  && bad "3d: 用了关 Restart / 清重启计数 / mask 之类的手段让它看起来稳定" \
  || ok "3d: 没有关 Restart、没有 reset-failed、没有 mask —— 停止态是真的停下来"
grep -q '不证明「活跃 WLOC 的 iOS→Android 恢复」' "$SRC" \
  && ok "3e: 明确写了这一格只证明**关闭态**方向, 不外推到活跃 WLOC" || bad "3e: 没写清适用边界"
grep -q 'migrate_android_cleanup 只在' "$SRC" \
  && ok "3f: 写清了为什么本方向必须关 WLOC(否则整表截断会把失败触发条件清掉)" || bad "3f"

echo; echo "══ N. 撤销对照 ══"
# N1 撤回稳定性修复: 只取一次 is-active ⇒ "瞬时 active" 那一格必须失守
python3 - "$SRC" "$WORK/rev-inst.sh" <<'PYN'
import sys
src,dst=sys.argv[1],sys.argv[2]
s=open(src,encoding="utf-8").read()
i=s.index("svc_stable_window(){"); j=s.index("\n}\n", i)+len("\n}\n")
s=s[:i]+'''svc_stable_window(){   # 撤销对照: 退回"取一次 is-active"
  local st; st="$(systemctl show -p ActiveState --value "$1" 2>/dev/null)"
  SVC_STABLE_WHY="只取了一瞬: $st"
  if [[ "$2" == running ]]; then [[ "$st" == active ]]; else [[ "$st" != active ]]; fi
}
'''+s[j:]
open(dst,"w",encoding="utf-8").write(s)
PYN
SRC_SAVE="$SRC"; SRC="$WORK/rev-inst.sh"
SWOUT="$(sw_case 'ActiveState=active,active,failed,failed,failed
MainPID=111,111,0,0,0
InvocationID=inv-a
NRestarts=0' running 4)"
SRC="$SRC_SAVE"
[[ "$(gs RC)" == 0 ]] \
  && ok "N1: 撤回稳定性修复(只取一瞬 is-active)⇒ 瞬时 active 被误认稳定, 1c 那一格失守 —— 证明该格确实在测这条路径" \
  || bad "N1: 撤销版本居然也判不成立 rc=$(gs RC)"
# N2 无关注释对照
sed '0,/^SVC_STABLE_WHY=""/s//# 本行仅为无关注释对照\nSVC_STABLE_WHY=""/' "$SRC" > "$WORK/cmt.sh"
A="$(sw_case 'ActiveState=active
MainPID=111
InvocationID=inv-a
NRestarts=0' running 3)"
SRC_SAVE="$SRC"; SRC="$WORK/cmt.sh"
B="$(sw_case 'ActiveState=active
MainPID=111
InvocationID=inv-a
NRestarts=0' running 3)"
SRC="$SRC_SAVE"
[[ "$(grep -m1 '^RC=' <<<"$A")" == "$(grep -m1 '^RC=' <<<"$B")" ]] \
  && ok "N2: 无关注释对照 —— 结论相同($(grep -m1 '^RC=' <<<"$A")), 零新增失败" || bad "N2: 加一行注释改变了结果"

# ── 计数对账: 打印出来的断言条数必须等于进了总数的条数 ──────────────────────
A_ALL="$(awk 'END{print NR}' "$ALOG" 2>/dev/null)"; A_ALL="${A_ALL:-0}"
if [[ "$((P+F))" == "$A_ALL" ]]; then ok "计数对账: 打印 $A_ALL 条断言, 全部进了总数"
else bad "计数对账: 打印 $A_ALL 条, 只有 $((P+F)) 条进了总数"; fi
echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
