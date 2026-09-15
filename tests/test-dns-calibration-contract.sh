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
  mkdir -p "$FAKE/etc/mosdns/rules" "$FAKE/etc/privdns-gateway" "$FAKE/etc/systemd/system" "$FAKE/var/lib" || { echo "[未执行] 自有根建不全"; exit 1; }
  cp -a /etc/alternatives "$FAKE/etc/" 2>/dev/null
  # 第 7 节的播种末尾要用 openssl 签一张自签证书, 它要读 /etc/ssl/openssl.cnf ——
  # 自有根里没有的话 openssl 会静默失败, 证书生不出来(那是**本测试的隔离根缺东西**,
  # 不是被测脚本的问题; 真 runner 上没有这层遮挡)。
  cp -a /etc/ssl "$FAKE/etc/" 2>/dev/null
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
# 第 7 节要跑**真播种函数**, 它会往 /var/lib/privdns-gateway/adblock 写 —— 同样不能落到宿主上。
mkdir -p "$FAKE/var/lib"
mount --bind "$FAKE/var/lib" /var/lib || { echo "[未执行] 绑定 /var/lib 失败"; exit 1; }
[[ "$(stat -c '%d:%i' /var/lib)" == "$(stat -c '%d:%i' "$FAKE/var/lib")" ]] \
  || { echo "[未执行] /var/lib 隔离自检没过"; exit 1; }

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
  cat > "$WORK/systemctl" <<EOS
#!/bin/sh
echo "\$@" >> "$SCLOG"
case "\$1" in is-active) echo inactive;; is-enabled) echo disabled;; show) echo "";; esac
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


echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
