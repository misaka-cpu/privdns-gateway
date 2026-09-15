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
# ── 身份策略(本支所有 unshare 调用共用这一条)────────────────────────────────
# 上一次(run 34947857248 的第④步)栽在这: workflow 用 `sudo env … bash 本脚本`,
# 而脚本重入时还加 --map-root-user —— 新用户命名空间里**只映射 uid 0**, 源码路径上
# 属于 runner(uid 1001)的目录全变成未映射, 命名空间内的 root 对它们没有
# CAP_DAC_OVERRIDE, 于是连自己的源码都读不开: exit 126 Permission denied。
#   EUID=0  ⇒ 保留当前用户命名空间身份, **只**建要用的私有挂载/网络命名空间;
#   非 root ⇒ 仍走 --map-root-user(否则没有建挂载命名空间的能力)。
# 最外层能力探测、实际重入、第 9 节四处嵌套网络隔离**都**用这两个数组, 不各写一套。
NS_MNT=(unshare); NS_NET=(unshare)
if [[ "$(id -u)" != 0 ]]; then NS_MNT+=(--map-root-user); NS_NET+=(--map-root-user); fi
NS_MNT+=(--mount --propagation private)
NS_NET+=(--net --mount --propagation private)
# 传播必须是 private: 否则 root 身份下的 bind 会漏回宿主。重入标记只是控制流标记,
# 隔离要由**下面这些实测**来证明, 不能拿标记当证据。
_prop_private(){   # $1=挂载点 → 0 私有 / 1 还是 shared / 2 查不到这个挂载点
  local ln; ln="$(awk -v m="$1" '$5==m{l=$0} END{if(l!="")print l}' /proc/self/mountinfo)"
  [[ -n "$ln" ]] || return 2
  grep -q ' shared:' <<<"$ln" && return 1 || return 0
}
if [[ -z "${PDG_DNSCAL_NS:-}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FAKE="$(mktemp -d)" || { echo "[未执行] 建不出自有根"; exit 1; }
  trap 'rm -rf "$FAKE"' EXIT
  mkdir -p "$FAKE/etc/mosdns/rules" "$FAKE/etc/privdns-gateway" "$FAKE/etc/systemd/system" "$FAKE/var/lib" || { echo "[未执行] 自有根建不全"; exit 1; }
  cp -a /etc/alternatives "$FAKE/etc/" 2>/dev/null
  # 第 7 节的播种末尾要用 openssl 签一张自签证书, 它要读 /etc/ssl/openssl.cnf ——
  # 自有根里没有的话 openssl 会静默失败, 证书生不出来(那是**本测试的隔离根缺东西**,
  # 不是被测脚本的问题; 真 runner 上没有这层遮挡)。
  cp -a /etc/ssl "$FAKE/etc/" 2>/dev/null
  for _f in passwd group nsswitch.conf localtime hosts resolv.conf; do cp -a "/etc/$_f" "$FAKE/etc/" 2>/dev/null; done
  export FAKE
  if "${NS_MNT[@]}" true 2>/dev/null; then
    export PDG_DNSCAL_NS=1
    PDG_DNSCAL_MNT0="$(readlink /proc/self/ns/mnt)"   # 重入后拿它核"确实换了挂载命名空间"
    export PDG_DNSCAL_MNT0
    # 这里**不用 exec**: 留一个父进程专管自有根的清理。上一版是"先清 EXIT trap 再 exec",
    # 于是 exec 一失败(比如上一次那个 Permission denied)自有根就漏在宿主 /tmp 上。
    # 留着父进程, 则 exec 失败、unshare 建不起来、子进程中途崩, 三种都有人收尾。
    "${NS_MNT[@]}" bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"; _rc=$?
    rm -rf "$FAKE"; trap - EXIT
    case "$_rc" in
      126|127) echo "[未执行] 重入没跑起来(rc=$_rc; ${NS_MNT[*]}) —— 自有根已清, 不退回宿主执行。";;
    esac
    exit "$_rc"
  fi
  echo "[未执行] 建不出挂载隔离(没有可用的 unshare)。被测函数要往 /etc 写, 没有自有根就不能跑,"
  echo "         不靠权限失败兜底, 也不冒充通过。"
  exit 1
fi
trap 'rm -rf "${WORK:-}" "$FAKE"' EXIT
# 任何绑定、任何往绝对路径的写入之前, 先把隔离本身证实了(标记只是标记):
[[ "$(readlink /proc/self/ns/mnt)" != "${PDG_DNSCAL_MNT0:-}" ]] \
  || { echo "[未执行] 挂载命名空间没换(仍是 ${PDG_DNSCAL_MNT0:-读不到}) —— 不在宿主上接着跑"; exit 1; }
_prop_private / \
  || { echo "[未执行] 根挂载的传播不是 private —— 绑定会漏回宿主, 停"; exit 1; }
mount --bind "$FAKE/etc" /etc || { echo "[未执行] 绑定 /etc 失败"; exit 1; }
[[ "$(stat -c '%d:%i' /etc)" == "$(stat -c '%d:%i' "$FAKE/etc")" ]] \
  || { echo "[未执行] 隔离自检没过"; exit 1; }
_prop_private /etc || { echo "[未执行] /etc 绑定后的传播不是 private, 停"; exit 1; }
# 第 7 节要跑**真播种函数**, 它会往 /var/lib/privdns-gateway/adblock 写 —— 同样不能落到宿主上。
mkdir -p "$FAKE/var/lib"
mount --bind "$FAKE/var/lib" /var/lib || { echo "[未执行] 绑定 /var/lib 失败"; exit 1; }
[[ "$(stat -c '%d:%i' /var/lib)" == "$(stat -c '%d:%i' "$FAKE/var/lib")" ]] \
  || { echo "[未执行] /var/lib 隔离自检没过"; exit 1; }
_prop_private /var/lib || { echo "[未执行] /var/lib 绑定后的传播不是 private, 停"; exit 1; }

P=0; F=0
# 断言台账: 每条断言除了打印, 再往 $ALOG 记一行。末尾拿 P+F 与台账行数对账 ——
# "打印了 [OK]/[FAIL] 却没进总数"这种计数漏洞, 只有对账查得出来(本轮就查出了一处)。
ALOG=""
ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); printf 'OK\t%s\n' "$1" >> "${ALOG:-/dev/null}"; }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); printf 'FAIL\t%s\n' "$1" >> "${ALOG:-/dev/null}"; }
note(){ printf '[NOTE] %s\n' "$1"; }
# 跑"被测脚本自己也会调 ok/bad"的那几段时, 用这一对把计数与台账一起冻住再回滚,
# 免得被测方的断言混进本支的数。**必须在本支自己的判据之前** _release, 否则连自己的
# 失败都会被一起抹掉(6b/6c 原来就是这么丢的)。
_HP=0; _HF=0; _HA=0
_hold(){ _HP="$P"; _HF="$F"; _HA="$(awk 'END{print NR}' "$ALOG" 2>/dev/null)"; _HA="${_HA:-0}"; }
_release(){ P="$_HP"; F="$_HF"
  local t; t="$(mktemp "${TMPDIR:-/tmp}/alog.XXXXXX")"
  head -n "$_HA" "$ALOG" > "$t" 2>/dev/null; mv "$t" "$ALOG"
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${PDG_ACCEPT_SH:-$HERE/e2e-real-platform-fail.sh}"
[[ -f "$SRC" ]] || { echo "[未执行] 找不到 $SRC"; exit 1; }
WORK="$(mktemp -d)"; EVID="$WORK/evid"; mkdir -p "$EVID"
ALOG="$WORK/assert.log"; : > "$ALOG"
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
  _hold; : > "$WORK/out"
  ok(){ printf '  [被测] OK   %s\n' "$1" >> "$WORK/out"; }
  bad(){ printf '  [被测] FAIL %s\n' "$1" >> "$WORK/out"; }
  note(){ printf '  [被测] NOTE %s\n' "$1" >> "$WORK/out"; }
  dns_instrument_calibrate >>"$WORK/out" 2>&1; RC=$?
  printf 'WHY=%s DISK=%s RUN=%s\n' "${DNS_CALIB_WHY:-（空）}" "$DNS_RESTORE_DISK" "$DNS_RESTORE_RUN" >> "$WORK/out"
  unset -f ok bad note
  ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); printf 'OK\t%s\n' "$1" >> "${ALOG:-/dev/null}"; }
  bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); printf 'FAIL\t%s\n' "$1" >> "${ALOG:-/dev/null}"; }
  note(){ printf '[NOTE] %s\n' "$1"; }
  _release
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
_hold; dns_verdict "6" "$BEFORE" "$AFTER" > "$WORK/v.out" 2>&1
_release
grep -q '前像或恢复后的观测\*\*无效\*\*' "$WORK/v.out" \
  && ok "6a: 前后两份**无效**观测即使逐字相等也判红, 且理由就是'观测无效'" \
  || { bad "6a: 没有以'观测无效'为由判红"; sed 's/^/      /' "$WORK/v.out"; }
_hold
dns_verdict "6" "$(printf 'VALID\t%s\t%s' "$DNS_H" "$DNS_U")" "$(printf 'VALID\t%s\t%s' "$DNS_H" "$DNS_U")" > "$WORK/v2.out" 2>&1
_release
grep -q '见证与对照都回到前像' "$WORK/v2.out" && grep -q '差异确实来自接管规则' "$WORK/v2.out" \
  && ok "6b: 两份**有效**且等于预期 U/H 时才判通过" || { bad "6b"; sed 's/^/      /' "$WORK/v2.out"; }
_hold
dns_verdict "6" "$(printf 'VALID\t%s\t%s' "$DNS_U" "$DNS_U")" "$(printf 'VALID\t%s\t%s' "$DNS_U" "$DNS_U")" > "$WORK/v3.out" 2>&1
_release
grep -q '不符合预先固定的 U/H' "$WORK/v3.out" \
  && ok "6c: 前后一致但见证不等于 H(两边都是 U)也判红 —— 不是'两个非空串相等就行'" || { bad "6c"; sed 's/^/      /' "$WORK/v3.out"; }

PIN="${PDG_PINPOINT_SH:-$HERE/e2e-dns-instrument-systemd.sh}"
echo; echo "══ 7. 定点脚本的最小环境准备链(真播种函数; 自有根, 不写宿主 /etc 与 /var/lib)══"
# 上一次 run 34932738273 栽在这里: e2e_seed_mosdns 假定 /etc/mosdns/rules 与
# /etc/privdns-gateway 已存在(以前由 e2e_seed_install 顺手建), 目录不在时它一路写失败,
# 末句 `chmod … || true` 却让它**返回 0** —— 配置压根没生成, 而 `|| _hard` 没触发。
# 这一节用**真的** e2e_seed_mosdns 把整条准备链跑一遍, 判产物, 并验"被拒时没动服务"。
if [[ ! -f "$PIN" ]]; then
  bad "7-0: 找不到定点脚本 $PIN"
else
  # systemctl 桩: **绑到 /usr/bin/systemctl 上** —— 定点脚本的硬门要求它就在那个路径,
  # 放到 PATH 前面会被硬门判掉。桩把每一次调用记下来, 用来验"被拒之后没有 daemon-reload/start"。
  SCLOG="$WORK/systemctl.calls"; : > "$SCLOG"
  # 桩要会答 `show -p <属性> --value`: 定点脚本在**首次启动之前**要读自建 unit
  # 实际生效的 Restart / StartLimitIntervalUSec / StartLimitBurst。这里按真 systemd 的
  # 语义建模(本机 systemd 252 实测): StartLimitIntervalSec **只有写在 [Unit] 段才生效**,
  # 写进 [Service] 会静默退回默认 10s; 而 StartLimitBurst 在两段里都认。不设时 10s/5。
  cat > "$WORK/systemctl" <<EOS
#!/bin/sh
echo "\$@" >> "$SCLOG"
_u=/etc/systemd/system/mosdns.service
_val(){ [ -f "\$_u" ] || return 0; awk -v sec="\$1" -v key="\$2" -F= '
  /^\\[/{s=\$0} s=="["sec"]" && \$1==key{v=\$2} END{if(v!="")print v}' "\$_u"; }
_human(){ n="\$1"
  case "\$n" in infinity|0) echo "\$n"; return;; esac
  if [ "\$n" -lt 60 ] 2>/dev/null; then echo "\${n}s"
  elif [ \$((n % 60)) -eq 0 ]; then echo "\$((n / 60))min"
  else echo "\$((n / 60))min \$((n % 60))s"; fi; }
case "\$1" in
  is-active) echo inactive;;
  is-enabled) echo disabled;;
  show)
    _p=""; _prev=""
    for _a in "\$@"; do [ "\$_prev" = "-p" ] && _p="\$_a"; _prev="\$_a"; done
    case "\$_p" in
      Restart)                 v="\$(_val Service Restart)"; echo "\${v:-no}";;
      StartLimitIntervalUSec)  v="\$(_val Unit StartLimitIntervalSec)"; v="\${v%s}"; _human "\${v:-10}";;
      StartLimitBurst)         v="\$(_val Unit StartLimitBurst)"; [ -z "\$v" ] && v="\$(_val Service StartLimitBurst)"; echo "\${v:-5}";;
      NRestarts)               echo 0;;
      *)                       echo "";;
    esac;;
esac
exit 0
EOS
  chmod +x "$WORK/systemctl"
  if mount --bind "$WORK/systemctl" /usr/bin/systemctl 2>/dev/null; then
    ok "7-0: systemctl 已换成可记账的桩(绑在 /usr/bin/systemctl 上, 硬门照旧成立)"
  else
    bad "7-0: 绑不上 systemctl 桩, 这一节的服务动作判据无从谈起"
  fi
  # 拷贝出来的脚本仍要能 source 到夹具: 把 e2e-lib.sh 与它依赖的 repoguard.sh 一起放到 $WORK,
  # 并显式给 E2E_ROOT(否则它会按 $HERE/.. 推成 /tmp)。
  cp "$HERE/e2e-lib.sh" "$HERE/repoguard.sh" "$WORK/" 2>/dev/null
  REPO_ROOT="$(cd "$HERE/.." && pwd)"
  run_prep(){   # $1=被测脚本 → 打印退出码; 每次把自有根里的相关目录清干净
    rm -rf /etc/mosdns /etc/privdns-gateway /var/lib/privdns-gateway /etc/systemd/system/mosdns.service
    : > "$SCLOG"; rm -rf "$WORK/evid-prep"; mkdir -p "$WORK/evid-prep"
    E2E_ROOT="$REPO_ROOT" PDG_REAL_MIG_EVID="$WORK/evid-prep" timeout 120 bash "$1" > "$WORK/prep.out" 2>&1
    echo $?
  }
  pg(){ grep -q "$1" "$WORK/prep.out"; }

  # ── 7a 干净根里那两个目录本来就不存在(自证前提)──────────────────────────
  rm -rf /etc/mosdns /etc/privdns-gateway
  { [[ ! -d /etc/mosdns/rules && ! -d /etc/privdns-gateway ]]; } \
    && ok "7a: 干净根里 /etc/mosdns/rules 与 /etc/privdns-gateway 原本都不存在(前提成立)" \
    || bad "7a: 前提不成立, 目录已经在了"

  # ── 7b 修后: 目录建得出来, 产物齐 ───────────────────────────────────────
  run_prep "$PIN" >/dev/null      # 健康准备跑一遍, 判据都落在它的输出与落盘产物上
  pg '一-0: 前置目录已按夹具约定建好' && ok "7b-1: 前置目录按夹具约定建好" || { bad "7b-1"; tail -6 "$WORK/prep.out" | sed 's/^/      /'; }
  pg '一-2: config.yaml 非空' && ok "7b-2: config.yaml 非空且形态成立(占位符已渲染, 关键插件齐)" || { bad "7b-2: 配置形态门没过"; tail -6 "$WORK/prep.out" | sed 's/^/      /'; }
  pg '一-3: 配置实际引用的' && ok "7b-3: 配置实际引用的规则/集合文件全部就位(允许为空)" || bad "7b-3"
  pg '一-4: profile.env 与 DoT 证书/私钥就位' && ok "7b-4: profile.env 与证书/私钥就位, 私钥 600" || bad "7b-4"
  [[ -s /etc/mosdns/config.yaml ]] && ok "7b-5: 自有根里确实落下了非空的 config.yaml" || bad "7b-5: 没落下 config.yaml"

  # ── 7c 冻结版(上一版定点脚本)在同样前像下重现产物缺失 ────────────────────
  FROZEN_PIN="${PDG_PINPOINT_FROZEN:-}"
  if [[ -n "$FROZEN_PIN" && -f "$FROZEN_PIN" ]]; then
    cp "$FROZEN_PIN" "$WORK/frozen-pin.sh"      # 放到 $WORK 才 source 得到那份 e2e-lib.sh
    RC_F="$(run_prep "$WORK/frozen-pin.sh")"
    { pg '没有 mosdns 配置' || pg '一-4: 没有 mosdns 配置'; } \
      && ok "7c: 冻结版在同一前像下重现产物缺失(报'没有 mosdns 配置')" \
      || { bad "7c: 没重现出来(rc=$RC_F)"; tail -6 "$WORK/prep.out" | sed 's/^/      /'; }
  else
    note "7c: 没给 PDG_PINPOINT_FROZEN, 跳过与冻结版的对照(本轮已在证据里单独记过)"
  fi

  # ── 7d 播种返回 0 但产物缺失 ⇒ 前置门仍拒绝 ─────────────────────────────
  # 造法: 预先把 /etc/mosdns/config.yaml 建成一个**目录** —— 播种那句 sed 重定向必然失败,
  # 而它其余部分照跑、末句仍返回 0。不改任何共享函数。
  rm -rf /etc/mosdns /etc/privdns-gateway /var/lib/privdns-gateway
  mkdir -p /etc/mosdns/config.yaml
  : > "$SCLOG"; rm -rf "$WORK/evid-prep"; mkdir -p "$WORK/evid-prep"
  E2E_ROOT="$REPO_ROOT" PDG_REAL_MIG_EVID="$WORK/evid-prep" timeout 120 bash "$PIN" > "$WORK/prep.out" 2>&1; RC_D=$?
  SEEDRC="$(grep -oE 'e2e_seed_mosdns all 退出码 = [0-9]+' "$WORK/prep.out" | grep -oE '[0-9]+$')"
  [[ "$RC_D" != 0 ]] && ok "7d-1: 产物缺失时最终非零(rc=$RC_D)" || { bad "7d-1: 居然返回 0"; tail -8 "$WORK/prep.out" | sed 's/^/      /'; }
  pg '准备未完成' && ok "7d-2: 具名说明了准备未完成" || bad "7d-2: 没有具名说明"
  [[ "${SEEDRC:-x}" == 0 ]] \
    && ok "7d-3: 播种函数**返回 0**($SEEDRC), 前置门照样拒绝 —— 没有信它的返回码" \
    || note "7d-3: 这次播种退出码是 ${SEEDRC:-读不到}(不是 0 也行, 判据看的是产物)"

  # ── 7e 被拒之后: 没建本轮 unit, 也没有 daemon-reload / start ─────────────
  [[ ! -e /etc/systemd/system/mosdns.service ]] \
    && ok "7e-1: 被拒之后**没有**创建本轮 unit" || bad "7e-1: unit 竟然被创建了"
  grep -qE '^daemon-reload' "$SCLOG" && bad "7e-2: 被拒之后仍调了 daemon-reload" || ok "7e-2: 没有 daemon-reload"
  grep -qE '^start ' "$SCLOG" && bad "7e-3: 被拒之后仍调了 start" || ok "7e-3: 没有 start"
  note "7e 说明: 这里用的是 systemctl 桩的调用记录, 它证明的是'脚本没去动服务',"
  note "  **不是**真 systemd 上的启动证据 —— 那一条只能由定点派发回答。"

  # ── 7f 健康准备必须**真正跨过启动前边界** ────────────────────────────────
  # 旧版只看"打印了下一节标题"就算过 —— 那证明不了它真的走完 目录准备 → 真实播种 →
  # 产物核对 → 监听改写 → 监听核对 → 自建 unit 与启动调用 这一整条。
  run_prep "$PIN" >/dev/null
  PRE="$(awk '/二-3: 自建 unit/{exit} {print}' "$WORK/prep.out")"
  PREFAIL="$(grep -c '^\[FAIL\]' <<<"$PRE" || true)"
  [[ "$PREFAIL" == 0 ]] && ok "7f-1: 启动前范围内没有真实失败(0 条 [FAIL])" \
    || { bad "7f-1: 启动前就有 $PREFAIL 条失败"; grep '^\[FAIL\]' <<<"$PRE" | head -4 | sed 's/^/      /'; }
  pg '二-3: 自建 unit' && ok "7f-2: 走到了自建 unit 那段**实际代码**(不是打印标题)" \
    || { bad "7f-2: 没走到"; tail -8 "$WORK/prep.out" | sed 's/^/      /'; }
  # unit **确实被写出来过** —— 二-3 那行是在 `cat > $OWN_UNIT_PATH` 之后才打的;
  # 跑完之后它不在了, 是收尾按设计撤掉的(这一格顺带验到了"正常清理"在模型里成立)。
  [[ ! -e /etc/systemd/system/mosdns.service ]] \
    && ok "7f-3: 跑完之后自建 unit 已被收尾撤除(创建本身由 7f-2 与 start 调用记录佐证)" \
    || bad "7f-3: 自建 unit 跑完还留着 —— 收尾没撤掉"
  grep -qE '^daemon-reload' "$SCLOG" && ok "7f-4: 有 daemon-reload 调用记录" || bad "7f-4: 没有 daemon-reload"
  grep -qE '^start mosdns' "$SCLOG" && ok "7f-5: 有 start mosdns 调用记录" || { bad "7f-5: 没有 start"; head -8 "$SCLOG" | sed 's/^/      /'; }
  pg '一-1: \*\*没有\*\*安装 /usr/local/bin/pdg' && ok "7f-6: 没有安装 pdg" || bad "7f-6"
  pg '一-2: \*\*没有\*\*复制仓库' && ok "7f-7: 没有复制仓库到 /opt/privdns-gateway" || bad "7f-7"
  pg '一-3: \*\*没有\*\*安装任何 bot 模块' && ok "7f-8: 没有安装 bot 模块" || bad "7f-8"
  POSTFAIL="$(awk '/二-3: 自建 unit/{f=1} f' "$WORK/prep.out" | grep -c '^\[FAIL\]' || true)"
  note "7f-9: 启动前 0 条失败; 启动**之后** $POSTFAIL 条 —— 后者是模型里没有真 mosdns 造成的,"
  note "  与'启动前准备通过'分开报告; 不拿后段的预期失败去解释前段的任何失败。"

  # ── 7h 违规监听同样要在动作之前停(撤掉监听收窄作反例)──────────────────────
  python3 - "$PIN" "$WORK/nolisten.sh" <<'PYN'
import sys
src,dst=sys.argv[1],sys.argv[2]
s=open(src,encoding="utf-8").read()
a='sed -i "s|listen: \\"0.0.0.0:53\\"'
i=s.index(a); j=s.index("\n", i)
open(dst,"w",encoding="utf-8").write(s[:i]+"true  # 负控: 撤掉监听收窄\n"+s[j+1:])
PYN
  RC_NL="$(run_prep "$WORK/nolisten.sh")"
  { [[ "$RC_NL" != 0 ]] && { pg '还有通配监听' || pg '监听没改成' || pg '收窄不全'; }; } \
    && ok "7h-1: 监听没收窄时当场具名拒绝(rc=$RC_NL)" || { bad "7h-1"; tail -6 "$WORK/prep.out" | sed 's/^/      /'; }
  [[ ! -e /etc/systemd/system/mosdns.service ]] && ok "7h-2: 被拒之后没有创建本轮 unit" || bad "7h-2: unit 竟然被创建了"
  grep -qE '^daemon-reload|^start ' "$SCLOG" && bad "7h-3: 被拒之后仍动了服务" || ok "7h-3: 被拒之后没有 daemon-reload / start"


  # ── 7g 失败保留诊断; 汇总与退出码符合既有执行有效性契约 ──────────────────
  # 播种**没有输出**是正常的 —— 判"这份诊断在不在", 不判它非空。
  [[ -e "$WORK/evid-prep/00-seed-output.txt" ]] \
    && ok "7g-1: 播种的 stdout/stderr 留了档($(stat -c %s "$WORK/evid-prep/00-seed-output.txt") 字节; 没有丢进 /dev/null)" \
    || bad "7g-1: 播种诊断没留"
  grep -qE '^通过 [0-9]+, 失败 [0-9]+$' "$WORK/prep.out" \
    && ok "7g-2: 仍然打出了汇总行" || bad "7g-2: 没有汇总行"
  # 一致性: 日志里有 [FAIL] 就必须非零退出。用一次健康准备跑的结果来看。
  RC_C="$(run_prep "$PIN")"
  if grep -qE '^\[FAIL\]' "$WORK/prep.out"; then
    [[ "$RC_C" != 0 ]] && ok "7g-3: 日志里有 [FAIL] 且退出码非零($RC_C) —— 两者一致" \
                       || bad "7g-3: 日志里有 [FAIL] 却返回 0"
  else
    [[ "$RC_C" == 0 ]] && ok "7g-3: 日志里没有 [FAIL] 且返回 0 —— 两者一致" || bad "7g-3: 没有 [FAIL] 却非零($RC_C)"
  fi

  # ── 撤销对照 ─────────────────────────────────────────────────────────────
  U="$WORK/u.sh"
  # U1: 撤掉目录准备
  python3 - "$PIN" "$U" <<'PYU'
import sys,re
src,dst=sys.argv[1],sys.argv[2]
s=open(src,encoding="utf-8").read()
a=s.index('for _d in /etc/mosdns/rules /etc/privdns-gateway; do')
b=s.index('ok "一-0: 前置目录已按夹具约定建好')
s=s[:a]+s[b:]
open(dst,"w",encoding="utf-8").write(s)
PYU
  RC_U1="$(run_prep "$U")"
  { [[ "$RC_U1" != 0 ]] && { pg '没有 mosdns 配置' || pg '准备未完成'; }; } \
    && ok "U1: 撤掉目录准备 → 产物门当场拒绝(rc=$RC_U1)" || { bad "U1: 没有被拒"; tail -6 "$WORK/prep.out" | sed 's/^/      /'; }
  # U2: 撤掉产物硬门(把 _prep_fail 变成只记一笔就往下走)
  sed 's|^_prep_fail(){.*$|_prep_fail(){ bad "准备未完成(负控: 硬门已撤): $1"; return 0; }|' "$PIN" > "$U"
  rm -rf /etc/mosdns /etc/privdns-gateway /var/lib/privdns-gateway; mkdir -p /etc/mosdns/config.yaml
  : > "$SCLOG"; rm -rf "$WORK/evid-prep"; mkdir -p "$WORK/evid-prep"
  E2E_ROOT="$REPO_ROOT" PDG_REAL_MIG_EVID="$WORK/evid-prep" timeout 120 bash "$U" > "$WORK/prep.out" 2>&1
  { [[ -e /etc/systemd/system/mosdns.service ]] || grep -qE '^daemon-reload|^start ' "$SCLOG"; } \
    && ok "U2: 撤掉产物硬门 → 带着缺产物的现场去动服务了(正是 7e 要拦的)" \
    || { bad "U2: 撤掉硬门却没往下走, 这一格没验到东西"; tail -6 "$WORK/prep.out" | sed 's/^/      /'; }
  rm -rf /etc/mosdns /etc/privdns-gateway /var/lib/privdns-gateway /etc/systemd/system/mosdns.service
fi

echo; echo "══ 8. 监听残留检查的三态(真实 set -uo pipefail 条件下)══"
# 上一次 run 34934021143 的唯一失败就出在这条检查: 写成 `grep -c … | grep -qx 0`,
# 而 grep 零匹配退 1 + pipefail ⇒ **配置正确时反而判红**。
# 三态: 0=发现违规(拒) / 1=正常跑完且零匹配(放行) / 其它=检查本身没做成(也拒)。
CHK="$(_fn "$PIN" _listen_wildcard_check)"
if [[ -z "$CHK" ]]; then
  bad "8-0: 抽不到 _listen_wildcard_check"
else
  ok "8-0: 从定点脚本原文抽到了 _listen_wildcard_check"
  L="$WORK/lsn"; mkdir -p "$L"
  # 健康: 三处都收窄, 且 ECS 的 preset 原样留着
  cat > "$L/ok.yaml" <<'EOS'
  - tag: ecs_neutral
    args: {forward: false, send: true, preset: "0.0.0.0", mask4: 24, mask6: 48}
  - tag: udp_server
    args: {entry: main_sequence, listen: "127.0.0.1:53"}
  - tag: tcp_server
    args: {entry: main_sequence, listen: "127.0.0.1:53"}
  - tag: dot_server
    args: {entry: main_sequence, listen: "127.0.0.1:8853", cert: "/c/f.pem", key: "/c/k.pem"}
EOS
  # 违规: 只留一处没收窄
  sed 's|listen: "127.0.0.1:8853"|listen: "0.0.0.0:853"|' "$L/ok.yaml" > "$L/bad.yaml"
  # 读取错误: 自指符号链接(ELOOP) —— 错误发生在**这条检查**上, 不是靠更早的"文件不存在"门
  ln -sf "$L/loop.yaml" "$L/loop.yaml"
  # 在真实 set -uo pipefail 条件下驱动
  run_chk(){   # $1=函数体 $2=目标 → "rc|why"
    bash -c "set -uo pipefail
_LISTEN_WHY=''
$1
_listen_wildcard_check '$2'; rc=\$?
printf '%s|%s\n' \"\$rc\" \"\${_LISTEN_WHY:-}\""
  }
  R="$(run_chk "$CHK" "$L/ok.yaml")"
  [[ "${R%%|*}" == 0 ]] && ok "8a: 三处都收窄且 ECS preset 保留 → 放行(rc=0)" || { bad "8a: 实得 $R"; }
  R="$(run_chk "$CHK" "$L/bad.yaml")"
  { [[ "${R%%|*}" == 1 ]] && [[ "$R" == *'0.0.0.0:853'* ]]; } \
    && ok "8b: 留一处禁止监听 → 具名拒绝(rc=1, 点名了那一行)" || bad "8b: 实得 $R"
  R="$(run_chk "$CHK" "$L/loop.yaml")"
  { [[ "${R%%|*}" != 0 && "${R%%|*}" != 1 ]] && [[ "$R" == *'退出码'* ]]; } \
    && ok "8c: 检查本身读取出错 → 第三态(rc=${R%%|*}), 没有把错误反转成通过" || bad "8c: 实得 $R"
  # 8d 换回原管道: 健康配置重新转红
  OLDCHK='_listen_wildcard_check(){ _LISTEN_WHY="旧管道"; grep -c '"'"'listen: "0.0.0.0'"'"' "$1" | grep -qx 0; }'
  R="$(run_chk "$OLDCHK" "$L/ok.yaml")"
  [[ "${R%%|*}" != 0 ]] && ok "8d: 换回 \`grep -c … | grep -qx 0\` → 健康配置重新转红(rc=${R%%|*}) —— 正是上一次那个误判" \
                        || bad "8d: 旧管道居然没复现误判($R)"
  # 8e 换成单纯 ! grep: 读取错误用例被当成"干净"
  NOTCHK='_listen_wildcard_check(){ _LISTEN_WHY="单纯!grep"; ! grep -q '"'"'listen:[[:space:]]*"0\.0\.0\.0:'"'"' "$1"; }'
  R="$(run_chk "$NOTCHK" "$L/loop.yaml")"
  [[ "${R%%|*}" == 0 ]] && ok "8e: 换成单纯 \`! grep\` → 读取错误被当成'没有违规'(rc=0) —— 所以不能那么写" \
                        || bad "8e: 没复现出来($R)"
  # 8f 无关注释对照: 只在函数体里加一行注释, 三态结果一个都不变
  CMTCHK="$(printf '%s\n' "$CHK" | sed '2i\  # 本行仅为无关注释对照' )"
  same=1
  for t in ok bad loop; do
    [[ "$(run_chk "$CHK" "$L/$t.yaml")" == "$(run_chk "$CMTCHK" "$L/$t.yaml")" ]] || same=0
  done
  [[ "$same" == 1 ]] && ok "8f: 无关注释对照 —— 三个用例结果逐一相同, 零新增失败" || bad "8f: 加一行注释竟然改变了结果"
fi


echo; echo "══ 9. socket 观测口径: 用**真 socket** 在自有私有网络命名空间里标定 ══"
# 上一次 run 34936173665 栽在 `ss -lnup | awk '$5==…'` —— 只 UDP 时没有 Netid 列, 本地地址是 $4。
# 这一节不造 ss 文本, 而是在**自有 netns** 里真的 bind/listen, 看观测口径认不认得出来。
# netns 是私有的: 不占开发宿主的 53, 不改宿主 DNS / 服务 / 路由 / nft。
SOCKRUN="$WORK/sockcal-runner.sh"
cat > "$SOCKRUN" <<'SOCKRUNEOF'
#!/usr/bin/env bash
# 在**自有私有网络命名空间**里用真 socket 标定 socket 观测口径。
# 由 test-dns-calibration-contract.sh 通过 unshare 调起; 打印 KEY=value 供上层判定。
set -uo pipefail
PIN="$1"; FAKE2="$2"; REPO="$3"; OUT="$4"; NET0="${5:-}"
# 起任何测试 socket、绑任何东西之前, 先把"确实进了自己的网络命名空间"证实了:
# ① 命名空间 id 与调用方不同 ② 传播是 private ③ 这里的监听表是空的(宿主的 :53 不在这儿)。
# 证不了就**不往下跑**, 不退回宿主执行。
if [[ "$(readlink /proc/self/ns/net)" == "$NET0" || -z "$NET0" ]]; then
  echo "NS_NET_OK=0" >> "$OUT"; echo "[未执行] 网络命名空间没换(调用方=$NET0)" >&2; exit 3
fi
if awk '$5=="/"{l=$0} END{exit (l ~ / shared:/) ? 1 : 0}' /proc/self/mountinfo; then :; else
  echo "NS_NET_OK=0" >> "$OUT"; echo "[未执行] 传播不是 private" >&2; exit 3
fi
if [[ -n "$(ss -H -l -n -t -u 2>/dev/null)" ]]; then
  echo "NS_NET_OK=0" >> "$OUT"; echo "[未执行] 新网络命名空间里竟然已有监听 —— 不是干净的自有命名空间" >&2; exit 3
fi
echo "NS_NET_OK=1" >> "$OUT"
ip link set lo up 2>/dev/null
# 自有根: /etc /var/lib /etc/systemd/system, 免得脚本那一段写到宿主
mount --bind "$FAKE2/etc" /etc || { echo "NS_BIND_OK=0" >> "$OUT"; echo "[未执行] 绑不上 /etc" >&2; exit 3; }
mount --bind "$FAKE2/var/lib" /var/lib || { echo "NS_BIND_OK=0" >> "$OUT"; echo "[未执行] 绑不上 /var/lib" >&2; exit 3; }
# systemctl 记账桩
mount --bind "$FAKE2/systemctl" /usr/bin/systemctl || { echo "NS_BIND_OK=0" >> "$OUT"; echo "[未执行] 绑不上 systemctl 桩" >&2; exit 3; }
[[ "$(stat -c '%d:%i' /etc)" == "$(stat -c '%d:%i' "$FAKE2/etc")" \
   && "$(stat -c '%d:%i' /var/lib)" == "$(stat -c '%d:%i' "$FAKE2/var/lib")" ]] \
  || { echo "NS_BIND_OK=0" >> "$OUT"; echo "[未执行] 自有根自检没过" >&2; exit 3; }
echo "NS_BIND_OK=1" >> "$OUT"
: > "$FAKE2/calls"
_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
eval "$(_fn "$PIN" sock_query)"; eval "$(_fn "$PIN" sock_conflict)"; eval "$(_fn "$PIN" sock_owned_by)"
SOCK_ROWS=""; SOCK_WHY=""; SOCK_RAW=""; SOCK_ERR=""; SOCK_HIT_PIDS=""
say(){ printf '%s\n' "$1" >> "$OUT"; }

hold(){   # $1=proto(u|t) $2=addr $3=port → 打印 pid
  python3 -c "
import socket,sys,time
p,a,port=sys.argv[1],sys.argv[2],int(sys.argv[3])
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM if p=='u' else socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,0)
s.bind((a,port))
if p=='t': s.listen(1)
time.sleep(120)" "$1" "$2" "$3" >/dev/null 2>&1 & 
  local bg=$!; sleep 0.6; echo "$bg"   # 只回 bash 的后台 PID; python 的 stdout 已丢弃
}
q(){ sock_conflict "$1" "$2" "$3"; echo $?; }
drop(){ [[ -n "${1:-}" ]] || return 0; kill "$1" 2>/dev/null; sleep 0.2; kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; return 0; }

# 1. 空闲
say "C1=$(q udp 127.0.0.1 53)"
# 2. 自有进程占住 UDP/53
P_U53="$(hold u 127.0.0.1 53)"; say "C2=$(q udp 127.0.0.1 53)"; say "C2_PID=$P_U53"
# 6. 归属: 真实 socket 属于预期 PID / 属于另一进程
sock_owned_by udp 127.0.0.1 53 "$P_U53"; say "C6_self=$?"
sock_owned_by udp 127.0.0.1 53 999999;   say "C6_other=$?"
drop "$P_U53"; sleep 0.4
# 8. 占用者退出并回收后再观测
say "C8=$(q udp 127.0.0.1 53)"
# 3. TCP/53 与 TCP/8853
P_T53="$(hold t 127.0.0.1 53)";   say "C3_tcp53=$(q tcp 127.0.0.1 53)"
say "C3_udp53_while_tcp=$(q udp 127.0.0.1 53)"
drop "$P_T53"; sleep 0.3
P_T88="$(hold t 127.0.0.1 8853)"; say "C3_tcp8853=$(q tcp 127.0.0.1 8853)"
drop "$P_T88"; sleep 0.3
# 4. 通配绑定被识别; 不冲突的回环地址与不同端口不误报
P_W="$(hold u 0.0.0.0 53)";       say "C4_wild=$(q udp 127.0.0.1 53)"
drop "$P_W"; sleep 0.3
ip addr add 127.0.0.53/8 dev lo 2>/dev/null
P_O="$(hold u 127.0.0.53 53)";    say "C4_otheraddr=$(q udp 127.0.0.1 53)"
drop "$P_O"; sleep 0.3
P_P="$(hold u 127.0.0.1 5353)";   say "C4_otherport=$(q udp 127.0.0.1 53)"
drop "$P_P"; sleep 0.3
# 7. ss 查询失败 → 第三态
mkdir -p "$FAKE2/binshim"; printf '#!/bin/sh\necho "boom" >&2\nexit 2\n' > "$FAKE2/binshim/ss"; chmod +x "$FAKE2/binshim/ss"
say "C7=$(PATH="$FAKE2/binshim:$PATH" q udp 127.0.0.1 53)"
# 5. 被拒之后: 没有 unit / daemon-reload / start; 占用者仍存活且未被改变
P_K="$(hold u 127.0.0.1 53)"
rm -rf /etc/mosdns /etc/privdns-gateway /var/lib/privdns-gateway /etc/systemd/system/mosdns.service
: > "$FAKE2/calls"
E2E_ROOT="$REPO" PDG_REAL_MIG_EVID="$FAKE2/evid" timeout 180 bash "$PIN" > "$FAKE2/run.out" 2>&1
say "C5_rc=$?"
say "C5_unit=$([[ -e /etc/systemd/system/mosdns.service ]] && echo yes || echo no)"
say "C5_reload=$(grep -c '^daemon-reload' "$FAKE2/calls" 2>/dev/null || echo 0)"
say "C5_start=$(grep -c '^start ' "$FAKE2/calls" 2>/dev/null || echo 0)"
say "C5_holder_alive=$(kill -0 "$P_K" 2>/dev/null && echo yes || echo no)"
say "C5_rejected=$(grep -c '已被占用' "$FAKE2/run.out" 2>/dev/null || echo 0)"
drop "$P_K"
SOCKRUNEOF
chmod +x "$SOCKRUN"
F2="$WORK/fake2"; mkdir -p "$F2/etc/mosdns/rules" "$F2/etc/privdns-gateway" "$F2/etc/systemd/system" "$F2/var/lib" "$F2/evid"
cp -a /etc/alternatives "$F2/etc/" 2>/dev/null; cp -a /etc/ssl "$F2/etc/" 2>/dev/null
for _f in passwd group nsswitch.conf localtime hosts resolv.conf; do cp -a "/etc/$_f" "$F2/etc/" 2>/dev/null; done
printf '#!/bin/sh\necho "$@" >> %s/calls\ncase $1 in is-active) echo inactive;; is-enabled) echo disabled;; show) echo "";; esac\nexit 0\n' "$F2" > "$F2/systemctl"
chmod +x "$F2/systemctl"
SOUT="$WORK/sockcal.out"; : > "$SOUT"
if "${NS_NET[@]}" \
     bash "$SOCKRUN" "$PIN" "$F2" "$(cd "$HERE/.." && pwd)" "$SOUT" "$(readlink /proc/self/ns/net)" >"$WORK/sockcal.log" 2>&1; then
  ok "9-0: 自有私有网络命名空间建起来了, 标定跑完(宿主 :53 一个字没动)"
else
  bad "9-0: 标定跑不起来"; tail -8 "$WORK/sockcal.log" | sed 's/^/      /'
fi
gv(){ grep -m1 "^$1=" "$SOUT" 2>/dev/null | cut -d= -f2-; }
# 隔离不能只看"跑起来了": 命名空间换没换、传播私不私有、自有根绑没绑上, 由 runner 实测后回报。
{ [[ "$(gv NS_NET_OK)" == 1 ]] && [[ "$(gv NS_BIND_OK)" == 1 ]]; } \
  && ok "9-0b: 嵌套隔离**实测**成立 —— 换了网络命名空间、传播 private、监听表起初为空、/etc 与 /var/lib 绑到自有根" \
  || bad "9-0b: 嵌套隔离没证实(NS_NET_OK=$(gv NS_NET_OK) NS_BIND_OK=$(gv NS_BIND_OK))"
[[ "$(gv C1)" == 1 ]] && ok "9a: 没有占用时正确放行(rc=1 = 查询成功且没有)" || bad "9a: 实得 $(gv C1)"
[[ "$(gv C2)" == 0 ]] && ok "9b: 自有进程占住 UDP/53 → 判为占用(rc=0)" || bad "9b: 实得 $(gv C2)"
{ [[ "$(gv C3_tcp53)" == 0 ]] && [[ "$(gv C3_tcp8853)" == 0 ]]; } \
  && ok "9c: 分别占住 TCP/53 与 TCP/8853 → 都判为占用" || bad "9c: 实得 tcp53=$(gv C3_tcp53) tcp8853=$(gv C3_tcp8853)"
[[ "$(gv C3_udp53_while_tcp)" == 1 ]] \
  && ok "9c2: 只占 TCP/53 时, UDP/53 仍判为空闲(协议分得清)" || bad "9c2: 实得 $(gv C3_udp53_while_tcp)"
[[ "$(gv C4_wild)" == 0 ]] && ok "9d: 通配绑定 0.0.0.0:53 被识别为冲突" || bad "9d: 实得 $(gv C4_wild)"
[[ "$(gv C4_otheraddr)" == 1 ]] && ok "9d2: 127.0.0.53:53 与 127.0.0.1 不冲突, 不误报" || bad "9d2: 实得 $(gv C4_otheraddr)"
[[ "$(gv C4_otherport)" == 1 ]] && ok "9d3: 127.0.0.1:5353 与 :53 不同端口, 不误报" || bad "9d3: 实得 $(gv C4_otherport)"
[[ "$(gv C6_self)" == 0 ]] && ok "9f: 真实 socket 属于预期 PID 时能识别(rc=0)" || bad "9f: 实得 $(gv C6_self)"
[[ "$(gv C6_other)" == 1 ]] && ok "9f2: 属于另一个 PID 时不冒充本轮服务(rc=1)" || bad "9f2: 实得 $(gv C6_other)"
[[ "$(gv C7)" == 2 ]] && ok "9g: ss 查询失败 → 第三态(rc=2), **没有**报空闲或释放完成" || bad "9g: 实得 $(gv C7)"
[[ "$(gv C8)" == 1 ]] && ok "9h: 自有占用者退出并回收后, 重新观测确实为空" || bad "9h: 实得 $(gv C8)"
{ [[ "$(gv C5_rc)" != 0 ]] && [[ "$(gv C5_rejected)" != 0 ]]; } \
  && ok "9e: 目标端口被占时定点脚本当场拒绝(rc=$(gv C5_rc))" || bad "9e: rc=$(gv C5_rc) 拒绝行数=$(gv C5_rejected)"
[[ "$(gv C5_unit)" == no ]] && ok "9e2: 被拒后没有本轮 unit" || bad "9e2: unit 竟然建了"
{ [[ "$(gv C5_reload)" == 0 ]] && [[ "$(gv C5_start)" == 0 ]]; } \
  && ok "9e3: 被拒后没有 daemon-reload / start" || bad "9e3: reload=$(gv C5_reload) start=$(gv C5_start)"
[[ "$(gv C5_holder_alive)" == yes ]] && ok "9e4: 占用者仍存活且未被改变(只观察, 没停没杀)" || bad "9e4: 占用者没了"
note "9: 这一节的 systemctl 是**模型**记录器; 它证明脚本没去动服务, 不代表真 systemd 就绪已通过。"

# ── 撤销对照 ─────────────────────────────────────────────────────────────
# N1: 撤销正确字段解析 —— 改回只 UDP(去掉 -t); 取第 5 列的写法不变, 但少了 Netid 那列后第 5 列就成了对端地址
sed 's|ss -H -l -n -t -u -p "sport = :$port"|ss -H -l -n -u -p "sport = :$port"|' "$PIN" > "$WORK/pin-n1.sh"
: > "$WORK/sockcal-n1.out"
"${NS_NET[@]}" \
  bash "$SOCKRUN" "$WORK/pin-n1.sh" "$F2" "$(cd "$HERE/.." && pwd)" "$WORK/sockcal-n1.out" "$(readlink /proc/self/ns/net)" >/dev/null 2>&1
gv1(){ grep -m1 "^$1=" "$WORK/sockcal-n1.out" 2>/dev/null | cut -d= -f2-; }
{ [[ "$(gv1 C2)" != 0 ]] || [[ "$(gv1 C6_self)" != 0 ]]; } \
  && ok "N1: 撤销正确字段解析 → 重现'有占用却放行'/'实际监听识别不到'(C2=$(gv1 C2) C6_self=$(gv1 C6_self))" \
  || bad "N1: 没重现出来(C2=$(gv1 C2) C6_self=$(gv1 C6_self))"
# N2: 撤销错误传播 —— 把 ss 非零当成"没有匹配"
python3 - "$PIN" "$WORK/pin-n2.sh" <<'PYN2'
import sys
src,dst=sys.argv[1],sys.argv[2]
s=open(src,encoding="utf-8").read()
a='  if [[ "$rc" != 0 ]]; then\n'
i=s.index(a); j=s.index("  fi\n", i)+len("  fi\n")
open(dst,"w",encoding="utf-8").write(s[:i]+'  if [[ "$rc" != 0 ]]; then return 1; fi\n'+s[j:])
PYN2
: > "$WORK/sockcal-n2.out"
"${NS_NET[@]}" \
  bash "$SOCKRUN" "$WORK/pin-n2.sh" "$F2" "$(cd "$HERE/.." && pwd)" "$WORK/sockcal-n2.out" "$(readlink /proc/self/ns/net)" >/dev/null 2>&1
[[ "$(grep -m1 '^C7=' "$WORK/sockcal-n2.out" | cut -d= -f2-)" != 2 ]] \
  && ok "N2: 撤销错误传播 → 查询失败那格转红(不再是第三态)" || bad "N2: 没转红"
# N3: 无关注释对照
sed '0,/^SOCK_ROWS=""/s//# 本行仅为无关注释对照\nSOCK_ROWS=""/' "$PIN" > "$WORK/pin-n3.sh"
: > "$WORK/sockcal-n3.out"
"${NS_NET[@]}" \
  bash "$SOCKRUN" "$WORK/pin-n3.sh" "$F2" "$(cd "$HERE/.." && pwd)" "$WORK/sockcal-n3.out" "$(readlink /proc/self/ns/net)" >/dev/null 2>&1
same=1
for k in C1 C2 C3_tcp53 C4_wild C6_self C7 C8; do
  [[ "$(grep -m1 "^$k=" "$SOUT" | cut -d= -f2-)" == "$(grep -m1 "^$k=" "$WORK/sockcal-n3.out" | cut -d= -f2-)" ]] || same=0
done
[[ "$same" == 1 ]] && ok "N3: 无关注释对照 —— 七个用例结果逐一相同, 零新增失败" || bad "N3: 加一行注释改变了结果"


echo; echo "══ 10. 主动启动预算 与 systemd 启动频率限制(只给自建 unit 的有限配额)══"
if ! declare -F run_prep >/dev/null; then
  bad "10-0: 第 7 节没建起准备链(run_prep 不在), 这一节无从谈起"
else
# 上一次 run 34941133783 的唯一失败: 第六节那次 restart 撞上默认 10s/5 的启动频率限制,
# journal 里是 "Start request repeated too quickly" / "start-limit-hit"。
# 这一节验的是修法本身: 配额只落在本轮自建 unit 上、仍然有限、**实际生效**才放行,
# 以及"脚本主动启动 / systemd 自动重启 / 频率预算"这三种量没有互相顶替。
# ⚠️ 本节的 systemctl 仍是第 7 节那个**桩**(按本机 systemd 252 实测语义建模);
#    真 systemd 上的那一半只能由定点派发回答, 两类证据分列。
UNITTXT="$(awk '/^cat > "\$OWN_UNIT_PATH" <<EOF$/{f=1;next} f&&/^EOF$/{exit} f' "$PIN")"
_k(){ grep -m1 "^$1=" "$PIN" | sed 's/[^=]*=//; s/ *#.*//'; }
SP="$(_k START_PLAN)"; SB="$(_k START_BUDGET)"; SW="$(_k START_WINDOW_SEC)"
[[ -n "$UNITTXT" ]] && ok "10-0: 抽到了自建 unit 的原文与预算常量(计划=$SP 预算=$SB 窗口=${SW}s)" \
  || bad "10-0: 抽不到 unit 原文"

# 10a 配额写在 [Unit] 段 —— 本机实测: 写进 [Service], Interval 会静默退回 10s
_u_line="$(grep -n '^\[Unit\]'    <<<"$UNITTXT" | cut -d: -f1)"
_s_line="$(grep -n '^\[Service\]' <<<"$UNITTXT" | cut -d: -f1)"
_i_line="$(grep -n '^StartLimitIntervalSec=' <<<"$UNITTXT" | cut -d: -f1)"
_b_line="$(grep -n '^StartLimitBurst='       <<<"$UNITTXT" | cut -d: -f1)"
{ [[ -n "$_i_line" && -n "$_b_line" && "$_i_line" -gt "$_u_line" && "$_i_line" -lt "$_s_line" \
     && "$_b_line" -gt "$_u_line" && "$_b_line" -lt "$_s_line" ]]; } \
  && ok "10a: 两条配额都写在 [Unit] 段(不是 [Service] —— 那样 Interval 会静默退回默认)" \
  || bad "10a: 配额行的位置不对(Unit 在第 $_u_line 行, Service 在第 $_s_line 行, Interval 第 ${_i_line:-无}, Burst 第 ${_b_line:-无})"
grep -q '^Restart=no$' <<<"$UNITTXT" && ok "10b: Restart=no 仍在(没有为了绕限额改成自动重启)" || bad "10b: Restart 不是 no"

# 10c 数值: 有限、正、由计划推导(预算 = 计划 + 1 次有界失败恢复), 不是随手加的保险
{ [[ "$SP" =~ ^[1-9][0-9]*$ && "$SB" =~ ^[1-9][0-9]*$ && "$SW" =~ ^[1-9][0-9]*$ ]]; } \
  && ok "10c-1: 计划/预算/窗口都是有限正整数(不是 0, 不是 infinity)" \
  || bad "10c-1: 有值不是有限正整数(计划=$SP 预算=$SB 窗口=$SW)"
[[ "$SB" == "$((SP+1))" ]] \
  && ok "10c-2: 预算 $SB = 计划 $SP + 1 次有界失败恢复 —— 由执行路径推导, 没凭空加保险次数" \
  || bad "10c-2: 预算 $SB 与计划 $SP 对不上(应为 $((SP+1)))"
{ [[ "$SW" -ge 30 && "$SW" -le 3600 ]]; } \
  && ok "10c-3: 频率窗口 ${SW}s 有限且盖得住整段脚本(run 34941133783 实测首末启动相距 24s)" \
  || bad "10c-3: 窗口 ${SW}s 不合适(要有限, 且盖得住整段)"

# 10d 只作用于自建 unit: 不动全局默认, 不用 reset-failed 清额度
_bad_scope=0; _scope_hit=""
_nc="$WORK/pin-nocomment.txt"; grep -vE '^[[:space:]]*#' "$PIN" > "$_nc"
_scope_hit="$(grep -nE 'system\.conf|DefaultStartLimit|reset-failed' "$_nc" | head -3)"
[[ -n "$_scope_hit" ]] && _bad_scope=1
(( _bad_scope == 0 )) \
  && ok "10d-1: 没碰 system.conf / 全局 DefaultStartLimit*, 也没用 reset-failed 清额度" \
  || { bad "10d-1: 出现了全局改动或 reset-failed"; sed 's/^/      /' <<<"$_scope_hit"; }
_wr="$(grep -oE '> *"\$(OWN_UNIT_PATH|PROBE_PATH)"|> *"/etc/systemd/system/[^"]*"' "$PIN" | sort -u)"
[[ "$(grep -c '/etc/systemd/system/' <<<"$_wr")" == 0 ]] \
  && ok "10d-2: 写 unit 只经本轮登记过的两个变量(自建 mosdns 与反例 unit), 没有写死别的路径" \
  || bad "10d-2: 有写死的 unit 路径: $_wr"

# 10e 计数包装: 动作仍交给真二进制, 且定义在硬门之后(否则硬门只看得到函数名)
WRAPTXT="$(_fn "$PIN" systemctl)"
grep -q 'command systemctl "\$@"' <<<"$WRAPTXT" \
  && ok "10e-1: 计数包装把动作原样转给 \`command systemctl\`(只记账, 不改行为)" || bad "10e-1: 包装没转给真二进制"
{ [[ "$(grep -n '^SCTL=' "$PIN" | cut -d: -f1)" -lt "$(grep -n '^systemctl(){' "$PIN" | cut -d: -f1)" ]]; } \
  && ok "10e-2: 包装定义在硬门之后 —— 硬门验的仍是真 systemctl 二进制" || bad "10e-2: 包装定义得太早, 会挡住硬门"
_sl="$(grep -n 'start-limit' "$PIN" | grep -vcE '^[0-9]+:#')"
[[ "$_sl" == 0 ]] \
  && ok "10f: 'start-limit' 只出现在注释里 —— 没把它加进容忍列表, 也没改成 SKIP" \
  || bad "10f: 有 $_sl 处非注释的 start-limit 处理"

# ── 行为: 生效属性门(桩按真语义作答; 不生效/不有限 ⇒ 首次启动之前就拒绝)──────
_mk(){   # $1=改法(python 片段名) → 生成一份改过的定点脚本副本, 回显路径
  python3 - "$PIN" "$WORK/pin-$1.sh" "$1" <<'PYQ'
import sys
src,dst,how=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(src,encoding="utf-8").read()
i=s.index('cat > "$OWN_UNIT_PATH" <<EOF'); j=s.index("\nEOF\n", i)+len("\nEOF\n")
unit=s[i:j]
if how=="service":      # 两条配额挪进 [Service] 段(真 systemd 下 Interval 会静默退回 10s)
    u=unit.replace("StartLimitIntervalSec=$START_WINDOW_SEC\n","").replace("StartLimitBurst=$START_BUDGET\n","")
    u=u.replace("Restart=no\n","Restart=no\nStartLimitIntervalSec=$START_WINDOW_SEC\nStartLimitBurst=$START_BUDGET\n")
elif how=="infinity":
    u=unit.replace("StartLimitIntervalSec=$START_WINDOW_SEC","StartLimitIntervalSec=infinity")
elif how=="burst0":
    u=unit.replace("StartLimitBurst=$START_BUDGET","StartLimitBurst=0")
elif how=="always":
    u=unit.replace("Restart=no","Restart=always")
elif how=="none":       # 撤销配额设置: 回到系统默认 10s/5
    u=unit.replace("StartLimitIntervalSec=$START_WINDOW_SEC\n","").replace("StartLimitBurst=$START_BUDGET\n","")
elif how=="cmt":        # 无关注释对照: unit 一个字不动, 只在别处插一行注释
    u=unit
else: raise SystemExit("unknown "+how)
out=s[:i]+u+s[j:]
if how=="cmt":
    out=out.replace("# ── 硬门 ──","# 本行仅为无关注释对照\n# ── 硬门 ──",1)
open(dst,"w",encoding="utf-8").write(out)
PYQ
  echo "$WORK/pin-$1.sh"
}
_gate_case(){   # $1=脚本 $2=期望(pass|reject) $3=标签 $4=具名关键字
  local rc; rc="$(run_prep "$1")"
  local started=0; grep -qE '^start mosdns' "$SCLOG" && started=1
  if [[ "$2" == reject ]]; then
    { pg '准备未完成' && pg "$4" && [[ "$started" == 0 ]]; } \
      && ok "$3(rc=$rc; 具名拒绝, 且**首次启动之前**就停了 —— 没有 start)" \
      || { bad "$3: rc=$rc started=$started"; grep -E '^\[(FAIL|OK)\]' "$WORK/prep.out" | tail -4 | sed 's/^/      /'; }
  else
    { pg '二-3b: 本轮自建 unit 的启动配额\*\*实际生效\*\*' && [[ "$started" == 1 ]]; } \
      && ok "$3(配额生效门放行, 之后确实发出了 start)" \
      || { bad "$3: started=$started"; grep -E '^\[(FAIL|OK)\]' "$WORK/prep.out" | tail -4 | sed 's/^/      /'; }
  fi
}
_gate_case "$PIN"                  pass   "10g: 健康路径 —— 配额实际生效(桩按 [Unit] 段作答)"     ""
_gate_case "$(_mk service)"        reject "10h: 配额错写进 [Service] 段 ⇒ 窗口退回 10s, 当场拒绝" '启动频率窗口没按写的生效'
_gate_case "$(_mk infinity)"       reject "10i: 窗口 infinity(等效无限制) ⇒ 拒绝"                 '频率限制必须仍然开着'
_gate_case "$(_mk burst0)"         reject "10j: Burst=0(等于关掉限制) ⇒ 拒绝"                     '必须是有限的正整数'
_gate_case "$(_mk always)"         reject "10k: Restart=always ⇒ 拒绝(不靠自动重启遮掩崩溃)"      '不靠自动重启遮掩崩溃'

# ── 行为: 计数包装只给自建 mosdns unit 记帐, 且每次都真的转发出去 ─────────────
CB="$WORK/cntbin"; mkdir -p "$CB"
printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$WORK/fwd.log" > "$CB/systemctl"; chmod +x "$CB/systemctl"
: > "$WORK/fwd.log"
( eval "$WRAPTXT"
  # 这三个由 eval 进来的包装函数读, shellcheck 看不到
  SELF_STARTS=0; START_LOG="$WORK/starts.log"; : > "$START_LOG"
  # shellcheck disable=SC2034
  BUDGET_UNIT=mosdns.service
  PATH="$CB:$PATH"
  systemctl restart mosdns            >/dev/null 2>&1   # _dns_reload 的写法: 不带 .service
  systemctl start   mosdns.service    >/dev/null 2>&1
  systemctl start   pdg-dnsinst-flap-TESTONLY.service >/dev/null 2>&1   # 第八节的反例 unit
  systemctl stop    mosdns            >/dev/null 2>&1
  systemctl show -p MainPID --value mosdns >/dev/null 2>&1
  echo "$SELF_STARTS" > "$WORK/cnt" )
CNT="$(cat "$WORK/cnt" 2>/dev/null)"
[[ "$CNT" == 2 ]] && ok "10l-1: 只给自建 mosdns 的 start/restart 记帐(实得 $CNT 次; 反例 unit、stop、show 都不计)" \
  || { bad "10l-1: 记成了 $CNT 次(应为 2)"; cat "$WORK/starts.log" 2>/dev/null | sed 's/^/      /'; }
[[ "$(wc -l < "$WORK/fwd.log")" == 5 ]] \
  && ok "10l-2: 五次调用**全部**转发到了真二进制位置(记账不吞动作)" \
  || { bad "10l-2: 转发了 $(wc -l < "$WORK/fwd.log") 次(应 5)"; sed 's/^/      /' "$WORK/fwd.log"; }
[[ "$(wc -l < "$WORK/starts.log")" == 2 ]] && ok "10l-3: 每一次主动启动都逐条留了记录(可与预算对账)" \
  || bad "10l-3: 启动记录 $(wc -l < "$WORK/starts.log") 行(应 2)"

# ── 行为: 三种量分开 —— 预算对账判词 ────────────────────────────────────────
VTXT="$(_fn "$PIN" _start_budget_verdict)"
eval "$VTXT"
_vc(){ _start_budget_verdict "$1" "$2" "$3" "$4" 2>/dev/null; }
V_OK="$(_vc 7 7 8 0)";  V_OVER="$(_vc 9 7 8 0)"; V_UNDER="$(_vc 5 7 8 0)"; V_AUTO="$(_vc 7 7 8 2)"
[[ "$(grep -c '^BAD|' <<<"$V_OK")" == 0 ]] && ok "10m-1: 计划内(主动 7 / 预算 8 / 自动 0)判全成立" || { bad "10m-1"; sed 's/^/      /' <<<"$V_OK"; }
grep -q '^BAD|九-1' <<<"$V_OVER"  && ok "10m-2: 主动启动 9 次超预算 8 ⇒ 九-1 判红" || bad "10m-2: 超支没判红"
grep -q '^BAD|九-2' <<<"$V_UNDER" && ok "10m-3: 只启动 5 次少于计划 7 ⇒ 九-2 判红(不能靠少跑一段省配额)" || bad "10m-3: 少跑没判红"
grep -q '^BAD|九-3' <<<"$V_AUTO"  && ok "10m-4: NRestarts=2 ⇒ 九-3 判红(自动重启与主动启动分开计)" || bad "10m-4"
grep -q '证明不了' <<<"$V_OK" && ok "10m-5: NRestarts=0 那条明说了它**证明不了**主动启动次数" || bad "10m-5: 文案没说清三种量的区别"

# ── 撤销对照 ────────────────────────────────────────────────────────────────
_gate_case "$(_mk none)" reject "N4: 撤销配额设置 ⇒ 退回默认 10s/5, 生效属性门当场拒绝(模型)" '启动频率窗口没按写的生效'
note "N4 说明: 这是**模型**层(桩按实测语义作答)。真实层的反例有两处实测, 单列不混算:"
note "  ① run 34941133783: 真 systemd 默认 10s/5 下第 6 次 restart 被拒, Result=start-limit-hit;"
note "  ② 本机自有一次性 unit 实测: 默认 10s/5 连做 8 次 → 第 6 次起被拒; 300s/8 → 8 次全过, 第 9 次仍被拒(限制确实还开着)。"
CMT="$(_mk cmt)"
_c1="$(run_prep "$CMT")"; _c1g=0; pg '二-3b: 本轮自建 unit 的启动配额\*\*实际生效\*\*' && _c1g=1
_c2="$(run_prep "$PIN")"; _c2g=0; pg '二-3b: 本轮自建 unit 的启动配额\*\*实际生效\*\*' && _c2g=1
{ [[ "$_c1" == "$_c2" && "$_c1g" == "$_c2g" ]]; } \
  && ok "N5: 无关注释对照 —— 退出码与配额门结论都相同(rc=$_c1, 门=$_c1g), 零新增失败" \
  || bad "N5: 加一行注释改变了结果(rc $_c1 vs $_c2, 门 $_c1g vs $_c2g)"
fi


echo; echo "══ 11. 命名空间重入的身份策略(root 与非 root 都要能跑, 且隔离不打折)══"
# 上一次(run 34947857248 第④步)栽在这: workflow 用 `sudo env … bash 本脚本`, 而脚本重入时
# 还加 --map-root-user —— 新用户命名空间只映射 uid 0, 源码路径上属于 runner 的目录变成未映射,
# 命名空间里的 root 对它们没有 CAP_DAC_OVERRIDE ⇒ 连自己都读不开(exit 126)。
SELF="${BASH_SOURCE[0]}"
NSW="$WORK/ns"; mkdir -p "$NSW"

# 11a 策略本身: 同一段代码, 两种身份给出两套参数(拿假 id 驱动, 不改被测逻辑)
POL="$(sed -n '/^NS_MNT=(unshare)/,/^NS_NET+=(/p' "$SELF")"
R_ROOT="$( id(){ echo 0; };    eval "$POL"; printf '%s | %s' "${NS_MNT[*]}" "${NS_NET[*]}" )"
R_USER="$( id(){ echo 1000; }; eval "$POL"; printf '%s | %s' "${NS_MNT[*]}" "${NS_NET[*]}" )"
{ [[ "$R_ROOT" != *--map-root-user* ]] && [[ "$R_ROOT" == *"--mount --propagation private"* ]] \
  && [[ "$R_ROOT" == *--net* ]]; } \
  && ok "11a-1: EUID=0 ⇒ 不再新建单 UID 映射, 只建私有挂载/网络命名空间($R_ROOT)" \
  || bad "11a-1: root 那套参数不对: $R_ROOT"
{ [[ "$R_USER" == *--map-root-user* ]] && [[ "$R_USER" == *"--mount --propagation private"* ]]; } \
  && ok "11a-2: 非 root ⇒ 保留 --map-root-user 这条既有路径($R_USER)" \
  || bad "11a-2: 非 root 那套参数不对: $R_USER"

# 11b 所有调用点都走这套策略 —— 不能只修最外层, 把同一个错留在第 9 节
_raw="$(grep -nE '(^|[^_A-Za-z"])unshare +--' "$SELF" | grep -v '^[0-9]*:#' | grep -vE 'NS_(MNT|NET)=\(unshare\)' || true)"
[[ -z "$_raw" ]] \
  && ok "11b-1: 文件里没有绕过策略的裸 unshare 调用(最外层探测、重入、第 9 节四处全用 NS_MNT/NS_NET)" \
  || { bad "11b-1: 还有裸调用"; sed 's/^/      /' <<<"$_raw"; }
_nsn="$(grep -c '"\${NS_NET\[@\]}"' "$SELF")"; _nsm="$(grep -c '"\${NS_MNT\[@\]}"' "$SELF")"
{ [[ "$_nsn" == 5 ]] && [[ "$_nsm" == 2 ]]; } \
  && ok "11b-2: 用点数目对得上 —— NS_MNT 2 处(能力探测 + 重入), NS_NET 5 处(第 9 节标定 + 三个撤销对照 + 11e-3 的绑定反例)" \
  || bad "11b-2: NS_MNT=$_nsm(应 2) NS_NET=$_nsn(应 5)"

# 11c 重入跑不起来: 明确未执行、非零、且自有根不留在宿主上
FU="$NSW/fakeunshare"; mkdir -p "$FU"
# 探测那次(参数以 true 结尾)放行, 真正重入那次失败 —— 正是"exec 失败"的形状
cat > "$FU/unshare" <<'EOS'
#!/bin/sh
for a in "$@"; do last="$a"; done
[ "$last" = "true" ] && exit 0
echo "假 unshare: 故意失败" >&2; exit 126
EOS
chmod +x "$FU/unshare"
TD="$NSW/tmp1"; mkdir -p "$TD"
# 自调用必须按 workflow 的形态**清掉重入标记**(env -u PDG_DNSCAL_NS -u FAKE):
# 不清的话子进程会以为自己已经重入过, 直接跑测试主体 —— 那就是无限递归。
OUT1="$NSW/out1"
env -u PDG_DNSCAL_NS -u FAKE -u PDG_DNSCAL_MNT0 PATH="$FU:$PATH" TMPDIR="$TD" \
  bash "$SELF" > "$OUT1" 2>&1; RC1=$?
LEFT1="$(find "$TD" -mindepth 1 -maxdepth 1 | wc -l)"
{ [[ "$RC1" != 0 ]] && grep -q '未执行' "$OUT1" && ! grep -q '^\[OK\]' "$OUT1"; } \
  && ok "11c-1: 重入失败 ⇒ 明确[未执行]+非零(rc=$RC1), 测试主体一条断言都没跑" \
  || { bad "11c-1: rc=$RC1"; head -3 "$OUT1" | sed 's/^/      /'; }
[[ "$LEFT1" == 0 ]] \
  && ok "11c-2: 重入失败后自有根已清干净(临时根目录里 0 个残留) —— 不再是'先清 trap 再 exec'那种漏法" \
  || { bad "11c-2: 留下了 $LEFT1 个自有根"; find "$TD" -mindepth 1 -maxdepth 1 | sed 's/^/      /'; }

# 11d 重入标记只是标记: 命名空间没换就**不准**往下跑(否则会写到宿主 /etc)
TD2="$NSW/tmp2"; mkdir -p "$TD2"; FK2="$NSW/fakeroot2"; mkdir -p "$FK2/etc" "$FK2/var/lib"
OUT2="$NSW/out2"
( PDG_DNSCAL_NS=1 PDG_DNSCAL_MNT0="$(readlink /proc/self/ns/mnt)" FAKE="$FK2" TMPDIR="$TD2" \
  bash "$SELF" ) > "$OUT2" 2>&1; RC2=$?
{ [[ "$RC2" != 0 ]] && grep -q '挂载命名空间没换' "$OUT2" && ! grep -q '^\[OK\]' "$OUT2"; } \
  && ok "11d-1: 挂着重入标记但命名空间没换 ⇒ 当场停(rc=$RC2), 不在宿主上接着跑" \
  || { bad "11d-1: rc=$RC2"; head -3 "$OUT2" | sed 's/^/      /'; }
[[ ! -e "$FK2/etc/mosdns" ]] \
  && ok "11d-2: 停在绑定之前 —— 自有根里连 /etc/mosdns 都没建, 更没往宿主写" \
  || bad "11d-2: 已经开始往里写了"

# 11e 第 9 节的前置同样是实测: 网络命名空间没换时 runner 不往下跑
OUT3="$NSW/out3"; : > "$OUT3"
bash "$SOCKRUN" "$PIN" "$F2" "$(cd "$HERE/.." && pwd)" "$OUT3" "$(readlink /proc/self/ns/net)" \
  >"$NSW/run3.log" 2>&1; RC3=$?
{ [[ "$RC3" != 0 ]] && grep -q '^NS_NET_OK=0' "$OUT3" && ! grep -q '^C1=' "$OUT3"; } \
  && ok "11e-1: 传进同一个网络命名空间 ⇒ runner 报 NS_NET_OK=0 并停(rc=$RC3), 没跑任何用例" \
  || { bad "11e-1: rc=$RC3"; head -3 "$OUT3" | sed 's/^/      /'; }
[[ "$(gv NS_NET_OK)" == 1 ]] \
  && ok "11e-2: 而正常那次确实进了自己的网络命名空间(NS_NET_OK=1, 与 9-0b 同源)" || bad "11e-2"
# 绑定失败同样要停在用例之前(拿一个不存在的自有根去绑)
OUT5="$NSW/out5"; : > "$OUT5"
"${NS_NET[@]}" bash "$SOCKRUN" "$PIN" "$NSW/没有这个根" "$(cd "$HERE/.." && pwd)" "$OUT5" \
  "$(readlink /proc/self/ns/net)" >"$NSW/run5.log" 2>&1; RC5=$?
{ [[ "$RC5" != 0 ]] && grep -q '^NS_BIND_OK=0' "$OUT5" && ! grep -q '^C1=' "$OUT5"; } \
  && ok "11e-3: 自有根绑不上 ⇒ 报 NS_BIND_OK=0 并停(rc=$RC5), 一个用例都没跑, 没退回宿主执行" \
  || { bad "11e-3: rc=$RC5"; head -3 "$OUT5" | sed 's/^/      /'; }

# 11f 无关注释对照
CP="$NSW/self-cmt.sh"; sed '0,/^set -uo pipefail$/s//set -uo pipefail\n# 本行仅为无关注释对照/' "$SELF" > "$CP"
OUT4="$NSW/out4"; mkdir -p "$NSW/tmp4"
env -u PDG_DNSCAL_NS -u FAKE -u PDG_DNSCAL_MNT0 PATH="$FU:$PATH" TMPDIR="$NSW/tmp4" \
  bash "$CP" > "$OUT4" 2>&1; RC4=$?
{ [[ "$RC4" == "$RC1" ]] && [[ "$(grep -c '未执行' "$OUT4")" == "$(grep -c '未执行' "$OUT1")" ]]; } \
  && ok "11f: 无关注释对照 —— 同样的重入反例结论不变(rc=$RC4), 零新增失败" \
  || bad "11f: 加一行注释改变了结果(rc $RC4 vs $RC1)"


# ── 计数对账: 打印出来的断言条数必须等于进了总数的条数 ──────────────────────
A_ALL="$(awk 'END{print NR}' "$ALOG" 2>/dev/null)"; A_ALL="${A_ALL:-0}"
if [[ "$((P+F))" == "$A_ALL" ]]; then
  ok "计数对账: 打印 $A_ALL 条断言, 全部进了总数"
else
  bad "计数对账: 打印 $A_ALL 条断言, 只有 $((P+F)) 条进了总数 —— 有断言没计数"
  awk -F'\t' 'NR>0{print "      未对上的台账行: " $0}' "$ALOG" | tail -5
fi

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
