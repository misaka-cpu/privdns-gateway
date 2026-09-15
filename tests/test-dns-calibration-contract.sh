#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DNS 仪器的**判定契约**。跑的是验收脚本里那几个函数的原文
# (dns_probe / dns_probe_ok / dns_expect / _dns_reload / dns_instrument_calibrate /
#  dns_feature_probe / dns_verdict), 不抄一份。
#
# ⚠️ **模型验证**: dig 与 systemctl 是桩, 真 mosdns 没参与。它证明"各种观测下判得对不对";
#    真二进制那一半在 tests/test-dns-instrument-real.sh(真钉版 mosdns + 真 dig + 自有上游)。
#    两类证据分列, 谁也不代替谁。
#
# 隔离: unshare 私有挂载, /etc 绑到一次性目录 —— 被测函数写的是 /etc 的绝对路径,
# **不**给它加"测试专用路径开关"(那种开关本身就是个洞)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
if [[ -z "${PDG_DNSCAL_NS:-}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FAKE="$(mktemp -d)" || { echo "[未执行] 建不出自有根"; exit 1; }
  trap 'rm -rf "$FAKE"' EXIT
  mkdir -p "$FAKE/etc/mosdns/rules" "$FAKE/etc/privdns-gateway" || { echo "[未执行] 自有根建不全"; exit 1; }
  cp -a /etc/alternatives "$FAKE/etc/" 2>/dev/null
  for _f in passwd group nsswitch.conf localtime hosts resolv.conf; do cp -a "/etc/$_f" "$FAKE/etc/" 2>/dev/null; done
  export FAKE
  if unshare --map-root-user --mount --propagation private true 2>/dev/null; then
    export PDG_DNSCAL_NS=1; trap - EXIT
    exec unshare --map-root-user --mount --propagation private bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  fi
  echo "[未执行] 建不出挂载隔离(没有可用的 unshare)。被测函数要往 /etc 写, 没有自有根就不能跑,"
  echo "         不靠权限失败兜底, 也不冒充通过。"
  exit 1
fi
trap 'rm -rf "${WORK:-}" "$FAKE"' EXIT
mount --bind "$FAKE/etc" /etc || { echo "[未执行] 绑定 /etc 失败"; exit 1; }
[[ "$(stat -c '%d:%i' /etc)" == "$(stat -c '%d:%i' "$FAKE/etc")" ]] \
  || { echo "[未执行] 隔离自检没过"; exit 1; }

P=0; F=0
ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${PDG_ACCEPT_SH:-$HERE/e2e-real-platform-fail.sh}"
[[ -f "$SRC" ]] || { echo "[未执行] 找不到 $SRC"; exit 1; }
WORK="$(mktemp -d)"; EVID="$WORK/evid"; mkdir -p "$EVID"
E2E_TMP="$WORK"; E2E_ROOT="$(cd "$HERE/.." && pwd)"; E2E_SIP=203.0.113.1
export E2E_TMP E2E_ROOT E2E_SIP
HIJ=/etc/mosdns/rules/mitm_hijack.txt
CNF=/etc/mosdns/rules/geosite_cn.txt

_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
for f in dns_probe dns_probe_ok dns_answer_of _dns_reload dns_expect \
         dns_fix_conditions dns_instrument_calibrate dns_feature_probe dns_verdict; do
  b="$(_fn "$SRC" "$f")"; [[ -n "$b" ]] || { echo "[未执行] 抽不到 $f"; exit 1; }
  eval "$b"
done
# 被测块顶部那几个变量也从原文取, 不在测试里另写一份默认值。
eval "$(grep -E '^DNS_(U|H|UP_PORT|WITNESS|CONTROL)=' "$SRC")"
DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""; DNS_CALIB_NAME=""
DNS_RESTORE_DISK=0; DNS_RESTORE_RUN=0
_evn(){ printf '%s\n' "$2" >> "$EVID/$1"; }
c_keep_note(){ :; }

CTL="$WORK/ctl"
# ── 桩: dig / systemctl / wait_stable / 自有上游 ────────────────────────────
# dig 的答案由**规则文件**决定 —— 这正是"产品配置决定 DNS 结果"的建模:
#   在 mitm_hijack → H;  否则在 geosite_cn → U(并记一笔"上游收到");  都不在 → H(all 形态)。
dig(){
  local name="" a
  for a in "$@"; do case "$a" in -*|@*|A) ;; *) name="$a";; esac; done
  local n; n="$(cat "$CTL/digcount" 2>/dev/null || echo 0)"; echo $((n+1)) > "$CTL/digcount"
  # 从第 N 次起**一直**超时 —— 用来构造"还原确认始终做不到"的现场(重试也救不回来)。
  [[ -e "$CTL/dead_from" && "$n" -ge "$(cat "$CTL/dead_from")" ]] && {
    echo ";; communications error to 127.0.0.1#53: timed out" >&2; return 9; }
  [[ -e "$CTL/second_timeout" && "$n" == "$(cat "$CTL/failon" 2>/dev/null || echo 1)" ]] && {
    echo ";; communications error to 127.0.0.1#53: timed out" >&2; return 9; }
  [[ -e "$CTL/second_servfail" && "$n" == "$(cat "$CTL/failon" 2>/dev/null || echo 1)" ]] && {
    printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'; return 0; }
  [[ -e "$CTL/second_empty" && "$n" == "$(cat "$CTL/failon" 2>/dev/null || echo 1)" ]] && {
    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'; return 0; }
  local ip="$DNS_H"
  if grep -qxF "full:$name" "$HIJ" 2>/dev/null; then ip="$DNS_H"
  elif grep -qxF "full:$name" "$CNF" 2>/dev/null; then
    [[ -e "$CTL/config_dead" ]] && ip="$DNS_H" || {   # 配置没生效: 还是落普通劫持
      ip="$DNS_U"; printf '%.3f q=%s len=40\n' "$(date +%s)" "$name" >> "$E2E_TMP/dns-up.log"; }
  fi
  printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n\n;; ANSWER SECTION:\n%s.\t60\tIN\tA\t%s\n' "$name" "$ip"
}
systemctl(){
  case "$1 ${2:-}" in
    "restart mosdns")
      local rn; rn="$(cat "$CTL/restartcount" 2>/dev/null || echo 0)"; echo $((rn+1)) > "$CTL/restartcount"
      [[ -e "$CTL/reload_fail" ]] && return 1
      [[ -e "$CTL/reload_fail_on" && "$rn" == "$(cat "$CTL/reload_fail_on")" ]] && return 1
      [[ -e "$CTL/inv_frozen" ]] && return 0
      echo "INV-$RANDOM$RANDOM" > "$CTL/inv"; return 0;;
  esac
  [[ "$1" == show ]] && { cat "$CTL/inv" 2>/dev/null || echo "INV-0"; return 0; }
  return 0
}
wait_stable(){ cat "$CTL/mosdns_state" 2>/dev/null || echo active; }
# dns_fix_conditions 里真正会起一个上游进程 —— 本支不起真进程, 只把它换成"登记一个假 PID"。
# 被测的是**判定逻辑**, 不是进程管理; 这一条在结尾的"仍被替换的边界"里明确列出。
dns_fix_conditions(){
  DNS_CALIB_NAME="dns-calib-model.e2e.test"
  : > "$E2E_TMP/dns-up.log"
  printf 'full:%s\nfull:%s\nfull:%s\n' "$DNS_CALIB_NAME" "$DNS_WITNESS" "$DNS_CONTROL" >> "$CNF"
  _dns_reload || return 1
  dns_expect "$DNS_CONTROL" "$DNS_U" || return 1
  grep -q " q=$DNS_CONTROL " "$E2E_TMP/dns-up.log" || { DNS_CALIB_WHY="对照名答案不是上游给的"; return 1; }
  ok_quiet
}
ok_quiet(){ return 0; }

# shellcheck disable=SC2120   # 参数是可选的(empty), 大多数用例用默认
seed(){
  rm -rf "$CTL"; mkdir -p "$CTL"; echo "INV-0" > "$CTL/inv"
  mkdir -p /etc/mosdns/rules
  printf 'domain:baidu.com\n' > "$CNF"
  if [[ "${1:-normal}" == empty ]]; then : > "$HIJ"; else
    printf 'full:gs-loc.apple.com\nfull:legacy-hand-edited.example\n' > "$HIJ"; fi
  chmod 640 "$HIJ"
  SUM0="$(sha256sum "$HIJ" | awk '{print $1}')"; MODE0="$(stat -c %a "$HIJ")"; OWN0="$(stat -c %u:%g "$HIJ")"
}
restored_ok(){ [[ "$(sha256sum "$HIJ" | awk '{print $1}')" == "$SUM0" \
                 && "$(stat -c %a "$HIJ")" == "$MODE0" && "$(stat -c %u:%g "$HIJ")" == "$OWN0" ]]; }
RC=0
# 被测函数自己也调 ok/bad/note —— 跑它时换成写文件, 否则它的计数会混进本支的计数。
run_calib(){
  DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""; DNS_RESTORE_DISK=0; DNS_RESTORE_RUN=0
  local _P="$P" _F="$F"; : > "$WORK/out"
  ok(){ printf '  [被测] OK   %s\n' "$1" >> "$WORK/out"; }
  bad(){ printf '  [被测] FAIL %s\n' "$1" >> "$WORK/out"; }
  note(){ printf '  [被测] NOTE %s\n' "$1" >> "$WORK/out"; }
  dns_instrument_calibrate >>"$WORK/out" 2>&1; RC=$?
  printf 'WHY=%s DISK=%s RUN=%s\n' "${DNS_CALIB_WHY:-（空）}" "$DNS_RESTORE_DISK" "$DNS_RESTORE_RUN" >> "$WORK/out"
  unset -f ok bad note
  ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
  bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
  note(){ printf '[NOTE] %s\n' "$1"; }
  P="$_P"; F="$_F"
}

echo "══ 1. 两份有效配置精确走出 U/H → 标定成功 ══"
seed; run_calib
{ [[ "$RC" == 0 && "$DNS_INSTRUMENT_OK" == 1 ]]; } && ok "1a: 标定通过" || { bad "1a: rc=$RC OK=$DNS_INSTRUMENT_OK"; sed 's/^/      /' "$WORK/out"; }
restored_ok && ok "1b: 接管表按内容与属性逐项还原" || bad "1b: 还原对不上"
grep -q '运行配置.*回到未接管' "$WORK/out" && ok "1c: 还原之后用**真实查询**确认了运行配置(不是只看 InvocationID)" || bad "1c"
grep -q 'DISK=1 RUN=1' "$WORK/out" && ok "1d: 磁盘还原与运行配置还原**分别**判定且都成立" || bad "1d"
grep -q '没有\*\*问上游' "$WORK/out" && ok "1e: 记了'配置乙那次没问上游'(答案确实来自接管分支)" || bad "1e"
grep -q 'rc/status/answer/stderr' "$EVID/dns-calibration.txt" && ok "1f: 两次观测的退出码/状态/答案/stderr 都留了档" || bad "1f"

echo; echo "══ 2. 配置没实际生效(两次都落普通劫持)→ 标定失败 ══"
seed; : > "$CTL/config_dead"; run_calib
{ [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]]; } && ok "2a: 判为标定失败" || bad "2a: rc=$RC OK=$DNS_INSTRUMENT_OK"
grep -qE '固定实验条件失败|不符合预先固定的 U/H' "$WORK/out" && ok "2b: 理由指向'配置没生效', 不是含糊一句" || { bad "2b"; tail -4 "$WORK/out" | sed 's/^/      /'; }

echo; echo "══ 3. 查询超时 / SERVFAIL / 空答案都不能冒充可区分 ══"
for k in second_timeout second_servfail second_empty; do
  # dig 调用序: ①固定条件里的对照名 ②配置甲 ③**配置乙** ④还原后的确认。
  # 注入要落在③ —— 落在④就变成"还原确认失败"那一格了(那是第 5 节的事)。
  seed; : > "$CTL/$k"; echo 2 > "$CTL/failon"; run_calib
  { [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]]; } \
    && ok "3-$k: 判为标定失败" || { bad "3-$k: rc=$RC OK=$DNS_INSTRUMENT_OK"; tail -4 "$WORK/out" | sed 's/^/      /'; }
  restored_ok || bad "3-$k: 没还原接管表"
done
ok "3-还原: 三种异常路径都把接管表还原了"

echo; echo "══ 4. 重载失败不能被吞成'标定有效' ══"
seed; : > "$CTL/reload_fail"; run_calib
{ [[ "$RC" != 0 ]] && grep -q '重启动作失败' "$WORK/out"; } && ok "4a: 重启动作失败 → 具名失败" || { bad "4a"; tail -3 "$WORK/out" | sed 's/^/      /'; }
seed; : > "$CTL/inv_frozen"; run_calib
{ [[ "$RC" != 0 ]] && grep -q '实例没有更替' "$WORK/out"; } && ok "4b: 实例没更替 → 具名失败" || { bad "4b"; tail -3 "$WORK/out" | sed 's/^/      /'; }
seed; echo failed > "$CTL/mosdns_state"; run_calib
{ [[ "$RC" != 0 ]] && grep -q '没有稳定运行' "$WORK/out"; } && ok "4c: 重启后没稳定在 active → 具名失败" || { bad "4c"; tail -3 "$WORK/out" | sed 's/^/      /'; }
seed; echo 2 > "$CTL/reload_fail_on"; : > "$CTL/reload_fail_on"; echo 2 > "$CTL/reload_fail_on"; run_calib
{ [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]]; } \
  && ok "4d: **只有配置乙那一次**重载失败也要当场报(不能靠后面那次好的重载兜住)" \
  || { bad "4d: 被吞了 rc=$RC OK=$DNS_INSTRUMENT_OK"; tail -4 "$WORK/out" | sed 's/^/      /'; }

echo; echo "══ 5. 提前失败后的收尾: 磁盘与运行配置分别判定 ══"
seed; echo 3 > "$CTL/dead_from"; run_calib   # 从④(还原后的确认)起一直查不通, 重试也救不回来
restored_ok && ok "5a: 磁盘内容与属性已还原" || bad "5a: 磁盘没还原"
grep -qE 'DISK=1 RUN=0|收尾未完成' "$WORK/out" \
  && ok "5b: **运行配置**没能确认时如实说收尾未完成, 不因为写回磁盘就宣称已恢复" \
  || { bad "5b"; tail -5 "$WORK/out" | sed 's/^/      /'; }

echo; echo "══ 6. 正式取证无效时不能因为文本相等判恢复通过 ══"
seed
BEFORE="$(printf 'INVALID\t观测不满足成功契约(见证=9\tNO-STATUS\tNO-ANSWER\ttimed out ; 对照=9\tNO-STATUS\tNO-ANSWER\ttimed out)')"
AFTER="$BEFORE"
_P="$P"; _F="$F"; dns_verdict "6" "$BEFORE" "$AFTER" > "$WORK/v.out" 2>&1
P="$_P"; F="$_F"
grep -q '前像或恢复后的观测\*\*无效\*\*' "$WORK/v.out" \
  && ok "6a: 前后两份**无效**观测即使逐字相等也判红, 且理由就是'观测无效'" \
  || { bad "6a: 没有以'观测无效'为由判红"; sed 's/^/      /' "$WORK/v.out"; }
_P="$P"; _F="$F"
dns_verdict "6" "$(printf 'VALID\t%s\t%s' "$DNS_H" "$DNS_U")" "$(printf 'VALID\t%s\t%s' "$DNS_H" "$DNS_U")" > "$WORK/v2.out" 2>&1
grep -q '见证与对照都回到前像' "$WORK/v2.out" && grep -q '差异确实来自接管规则' "$WORK/v2.out" \
  && ok "6b: 两份**有效**且等于预期 U/H 时才判通过" || { bad "6b"; cat "$WORK/v2.out" | sed 's/^/      /'; }
P="$_P"; F="$_F"
_P="$P"; _F="$F"
dns_verdict "6" "$(printf 'VALID\t%s\t%s' "$DNS_U" "$DNS_U")" "$(printf 'VALID\t%s\t%s' "$DNS_U" "$DNS_U")" > "$WORK/v3.out" 2>&1
grep -q '不符合预先固定的 U/H' "$WORK/v3.out" \
  && ok "6c: 前后一致但见证不等于 H(两边都是 U)也判红 —— 不是'两个非空串相等就行'" || { bad "6c"; cat "$WORK/v3.out" | sed 's/^/      /'; }
P="$_P"; F="$_F"

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
