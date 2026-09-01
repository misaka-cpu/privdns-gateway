#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 换核回滚必须能穿过 systemd 的启动限速。
#
# 机制(本轮实测确认, 不是推测): systemd 的 StartLimitBurst 把**成功的启动也计入** ——
# 一个完全健康的服务在 10s 窗口里第 6 次 restart 同样会被拒:
#     Job for X.service failed because start of the service was attempted too often.
#     Result=start-limit-hit
# 所以这不是"崩溃循环才会碰到"的边角: 一次 pdg update 本来就会重启若干服务, 换核自己还要
# restart 新核、失败后再 restart 旧核。预算一旦在窗口内用尽, systemd 就会拒掉
# _core_restore_prev 还原回去的那个**完全正确的旧二进制**。
#
# 结果: 盘上的文件是对的, 服务却起不来。
#
# ⚠️ 触发是**时序相关**的 —— 预算没用尽时同一条路径会正常恢复(本轮第一次跑就是这样,
# Result=success)。所以这里用真实 systemd 启动把预算确定性地压到临界: 那正是"更新期间这个
# unit 刚被重启过几次"的现场, 不是伪造。
#
# 结果: 盘上的文件是对的, 服务却起不来, DNS 不恢复; 换核报"旧版内核回退未达标",
# pdg update 据此整体回滚。这台机器上 mosdns 是 DNS 核心。
#
# 这个形态项目并非不知道 —— reset-failed 在别处用了十几处, pdg.sh 里有一句注释直写
# "清 start-limit", 还有整支 test-p2-runtime-fixes.sh 在测"start 少一句 reset-failed,
# 静态看毫无异常"。缺的恰恰是换核与它的回滚这两处。
#
# 本文件把"到底是不是 start-limit"钉死: 除它之外的八种可能各有一条排除断言, 其中最后一条
# 是决定性的 —— 生产代码放弃之后, 测试自己 reset-failed + start, 同一份二进制、同一份配置、
# 同一个 unit 立刻恢复并继续解析。那就只剩一个解释。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
XV_ROOT="$ROOT"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
die(){ echo "[FAIL] $1"; echo "通过 $pass, 失败 $((nfail+1))"; exit 1; }
# shellcheck source=tests/e2e-lib-crossver.sh
source "$HERE/e2e-lib-crossver.sh"
# shellcheck source=tests/legacy-pins.sh
source "$HERE/legacy-pins.sh"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || die "读不到 lib/versions.sh"

XV_WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-slimit.XXXXXX")"
trap xv_cleanup EXIT
xv_require_env || exit 1
ok "环境: root + 真 systemd + 真 systemctl + 无同名 unit 可覆盖"

ARCH="$(dpkg --print-architecture 2>/dev/null)"; [[ "$ARCH" == arm64 ]] || ARCH=amd64
OLDBIN="${PDG_TEST_MOSDNS_LEGACY:-$ROOT/tests/.bin/mosdns-legacy}"
[[ -x "$OLDBIN" ]] || die "拿不到旧版 mosdns($OLDBIN)。CI 由取件步骤备好; 本机: bash tests/prepare-mosdns-legacy.sh"
OLD_SHA="$(xv_sha "$OLDBIN")"
[[ "$OLD_SHA" == "${PDG_LEGACY_SHA256[mosdns-bin-$ARCH]}" ]] \
  && ok "旧版二进制内容等于旧版钉值(${OLD_SHA:0:12}…)" || die "旧版二进制与钉值不符"
[[ "$("$OLDBIN" version 2>/dev/null | head -1)" == "$PDG_LEGACY_MOSDNS_SELFVER" ]] \
  && ok "旧版自报版本整行等于钉死值($PDG_LEGACY_MOSDNS_SELFVER)" || die "旧版自报版本不符"

xv_setup_site "$OLDBIN" || die "现场搭建失败"
systemctl start "$XV_UNIT" || die "旧版起不来, 后面无从谈起"
xv_wait_listeners 3 || die "旧版监听没起齐: $(xv_listeners | tr '\n' ' ')"
L0="$(xv_listeners)"
CFG_SHA="$(xv_sha "$XV_CFG/config.yaml")"
ok "前像: v5.3.3 由真 systemd 管着, UDP/TCP/DoT 三类监听齐($(wc -l <<<"$L0") 条)"
xv_dns_ok && ok "前像: DNS 真查询成功" || die "前像 DNS 查不通"

# ── 预置条件: 把该 unit 的启动预算压到临界 ───────────────────────────────────
# 全部是**真实且成功**的 systemctl restart(服务每次都正常起来)。这一步不制造任何故障,
# 只还原"这个 unit 在限速窗口内已经被重启过几次"这个再普通不过的现场。
SLB="$(systemctl show "$XV_UNIT" -p StartLimitBurst --value 2>/dev/null)"
SLI="$(systemctl show "$XV_UNIT" -p StartLimitIntervalUSec --value 2>/dev/null)"
BURN=$(( ${SLB:-5} - 1 ))

# 对照组: 另起一个一次性 unit, 受同样次数的重启, 然后再来一次**不带 reset-failed** 的
# restart。它必须被拒 —— 这就证明了"预算确实用尽"这个前提是真的。
# 为什么要对照而不是直接看被测 unit: 修好之后被测 unit 永远不会再撞上限速(那正是修复的
# 意义), 拿它当判据的话, 这一格会在修复后变成一条永远测不到东西的断言。
CTRL=pdg-xv-ctrl
cat > "/etc/systemd/system/$CTRL.service" <<CTRLEOF
[Unit]
Description=pdg cross-version start-limit control
[Service]
ExecStart=/bin/sleep 600
Restart=on-failure
RestartSec=3
CTRLEOF
systemctl daemon-reload
for ((i=0;i<=BURN;i++)); do systemctl restart "$CTRL" >/dev/null 2>&1; done
if systemctl restart "$CTRL" >/dev/null 2>&1; then
  bad "对照组: 连续重启 $((BURN+2)) 次仍未被限速(burst=$SLB interval=$SLI) —— 本机限速语义与预期不符, 这一格没测到目标前提"
else
  ok "对照组证明预算确实会用尽: 同一窗口内第 $((BURN+2)) 次 restart 被 systemd 拒(burst=$SLB interval=$SLI)"
fi
systemctl stop "$CTRL" >/dev/null 2>&1; systemctl reset-failed "$CTRL" >/dev/null 2>&1
rm -f "/etc/systemd/system/$CTRL.service"; systemctl daemon-reload

# 被测 unit: 同样把预算压到临界。全部是真实且成功的 restart, 不制造任何故障 ——
# 还原的是"这个 unit 在限速窗口内已经被重启过几次"这个再普通不过的现场。
for ((i=0;i<BURN;i++)); do systemctl restart "$XV_UNIT" >/dev/null 2>&1; done
xv_wait_listeners 3 >/dev/null 2>&1
{ [[ "$(systemctl is-active "$XV_UNIT")" == active ]] && xv_dns_ok; } \
  && ok "预置: 被测 unit 窗口内已有 $BURN 次启动, 服务仍然健康、仍在解析" \
  || die "预置阶段就把服务弄坏了 —— 后面的因果链不成立"

# ── 换入一个起不来的新核, 走真实换核路径 ───────────────────────────────────────
printf '#!/bin/sh\nexit 1\n' > "$XV_WORK/deadbin"; chmod 755 "$XV_WORK/deadbin"
xv_mkzip "$XV_WORK/dead.zip" "$XV_WORK/deadbin"
mkdir -p "$XV_WORK/repo/lib"
{ echo "MOSDNS_VER=\"$MOSDNS_VER\""
  echo "declare -A PDG_SHA256=( [mosdns-$ARCH]=\"$(xv_sha "$XV_WORK/dead.zip")\" [mosdns-bin-$ARCH]=\"$(xv_sha "$XV_WORK/deadbin")\" )"
  sed -n '/^pdg_mosdns_version(){/,/^}/p'    "$ROOT/lib/versions.sh"
  sed -n '/^pdg_mosdns_is_version(){/,/^}/p' "$ROOT/lib/versions.sh"
  sed -n '/^pdg_mosdns_binary_ok(){/,/^}/p'  "$ROOT/lib/versions.sh"
  sed -n '/^pdg_verify_sha256(){/,/^}/p'     "$ROOT/lib/versions.sh"; } > "$XV_WORK/repo/lib/versions.sh"

H="$XV_WORK/harness.sh"
xv_build_harness "$H" _core_bindir _pdg_mktemp_dir _core_dl_reason _pdg_sha _core_restart_clean \
  _core_stash_kernel _core_restore_prev _core_kernel_stable _core_listeners \
  _core_config_check _core_swap_verify _update_mosdns_binary || exit 1
ok "换核闭包完整且可解析(12 个函数全在, bash -n 通过)"

rc=0
REPO_DIR="$XV_WORK/repo" PDG_CORE_BINDIR="$XV_BINDIR" FEED="$XV_WORK/dead.zip" \
  bash -c 'source "$0"; [[ "${HARNESS_OK:-}" == 1 ]] || exit 90; _update_mosdns_binary' \
  "$H" > "$XV_WORK/swap.log" 2>&1 || rc=$?
[[ "$rc" != 90 ]] || die "闭包没加载成功 —— 后面的断言全不算数"
grep -q 'command not found' "$XV_WORK/swap.log" && die "闭包漏桩: $(grep -m1 'command not found' "$XV_WORK/swap.log")"

echo
echo "══ 第一失败点 ══"
[[ "$rc" != 0 ]] && ok "起不来的新核 → 换核返回非零" || bad "起不来的新核被判成功"
RESULT="$(systemctl show "$XV_UNIT" -p Result --value)"
SLHIT="$(journalctl -u "$XV_UNIT" --since "-3min" --no-pager 2>/dev/null \
         | grep -c 'Start request repeated too quickly')"
echo "       (现场记录: Result=$RESULT, journal 里 'Start request repeated too quickly' x$SLHIT)"
[[ "$(xv_sha "$XV_BINDIR/mosdns")" == "$OLD_SHA" ]] \
  && ok "_core_swap_verify 把旧二进制内容正确还原了(${OLD_SHA:0:12}…)" \
  || bad "旧二进制没还原: $(xv_sha "$XV_BINDIR/mosdns" | cut -c1-12)…"
grep -q '还原旧版内核' "$XV_WORK/swap.log" \
  && ok "日志显示 _core_restore_prev 确实尝试过启动旧核" || bad "日志里没有还原动作"

# ↓ 这三条就是缺陷本身: 生产代码返回之后, 服务应当已经回来了
ACT="$(systemctl is-active "$XV_UNIT")"
[[ "$ACT" == active ]] \
  && ok "生产代码返回后, 旧核已经 active" \
  || bad "生产代码返回后旧核仍未启动(is-active=$ACT) —— 二进制对了, 服务没回来"
for _ in $(seq 1 15); do [[ "$(xv_listeners)" == "$L0" ]] && break; sleep 1; done
[[ "$(xv_listeners)" == "$L0" ]] \
  && ok "生产代码返回后, 三类监听已恢复" \
  || bad "生产代码返回后监听没回来: 现在 [$(xv_listeners | tr '\n' ' ')]"
xv_dns_ok && ok "生产代码返回后, DNS 真查询已恢复" || bad "生产代码返回后 DNS 仍不通"

echo
echo "══ 排除法: 除 start-limit 外的八种可能 ══"
[[ "$(xv_sha "$XV_BINDIR/mosdns")" == "$OLD_SHA" ]] \
  && ok "① 不是旧版二进制摘要不符(盘上就是钉死的旧版)" || bad "① 旧版摘要确实不符"
[[ "$(xv_sha "$XV_CFG/config.yaml")" == "$CFG_SHA" ]] \
  && ok "② 不是配置被改(config.yaml 逐字节未变)" || bad "② 配置被动过了"
[[ "$(xv_sha "/etc/systemd/system/$XV_UNIT.service")" == "$XV_UNIT_SHA" ]] \
  && ok "③ 不是 unit 文件损坏(逐字节未变)" || bad "③ unit 文件被动过了"
# 端口要么没人占, 要么只被本 unit 的 mosdns 占 —— 两种都排除了"被第三方抢走"。
# (第一版这里写成"必须无人监听", 那是预设服务停着; 预算没用尽时它自己就恢复了, 于是
#  一条本该是排除法的断言反而报红。判据要对两种状态都成立。)
_foreign="$(ss -lntupH 2>/dev/null | grep -E ":$XV_UDP_PORT |:$XV_DOT_PORT " | grep -cv '"mosdns"')"
[[ "$_foreign" == 0 ]] \
  && ok "④ 不是端口被第三方占用($XV_UDP_PORT/$XV_DOT_PORT 上没有非 mosdns 的监听者)" \
  || bad "④ 端口被第三方占: $(ss -lntupH | grep -E ":$XV_UDP_PORT |:$XV_DOT_PORT " | grep -v '"mosdns"')"
{ [[ -r "$XV_CFG/cert.pem" && -r "$XV_CFG/key.pem" ]]; } \
  && ok "⑤ 不是证书缺失(cert/key 都在且可读)" || bad "⑤ 证书不见了"
[[ "$(readlink /proc/1/ns/net)" == "$(readlink /proc/self/ns/net)" ]] \
  && ok "⑥ 不是网络命名空间问题(与 PID1 同一个 netns)" || bad "⑥ 不在 PID1 的 netns 里"
{ [[ "$(ps -p 1 -o comm=)" == systemd ]] && [[ -x "$(command -v systemctl)" ]] \
  && [[ "$(xv_sha "$OLDBIN")" == "${PDG_LEGACY_SHA256[mosdns-bin-$ARCH]}" ]]; } \
  && ok "⑦ 不是 shell 桩冒充 systemd/mosdns(PID1 是 systemd, 二进制过官方钉值)" \
  || bad "⑦ 现场里有假东西"

# ⑧ 决定性: 生产代码放弃之后, 只补一句 reset-failed 就能让同一现场立刻恢复。
systemctl reset-failed "$XV_UNIT" >/dev/null 2>&1
systemctl start "$XV_UNIT" >/dev/null 2>&1
xv_wait_listeners 3 >/dev/null 2>&1
{ [[ "$(systemctl is-active "$XV_UNIT")" == active ]] && [[ "$(xv_listeners)" == "$L0" ]] && xv_dns_ok; } \
  && ok "⑧ 决定性: 同一二进制/配置/unit, 补一句 reset-failed 后立刻恢复并继续解析 —— 不是测试清理过早, 也不是现场坏了" \
  || bad "⑧ 补了 reset-failed 仍然起不来 —— 那就还有别的原因, 本轮的因果链不成立"

echo
echo "══ 源码判据: 恢复闭包里必须有 reset-failed ══"
_rp="$(sed -n '/^_core_restore_prev(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
_sv="$(sed -n '/^_core_swap_verify(){/,/^}/p'  "$ROOT/deploy/bot/pdg.sh")"
_rc="$(sed -n '/^_core_restart_clean(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
[[ -n "$_rc" ]] && ok "有共用的 _core_restart_clean" || bad "没有 _core_restart_clean"
_i_reset="$(grep -n 'reset-failed' <<<"$_rc" | head -1 | cut -d: -f1)"
_i_restart="$(grep -n 'systemctl restart' <<<"$_rc" | head -1 | cut -d: -f1)"
{ [[ -n "$_i_reset" && -n "$_i_restart" ]] && [[ "$_i_reset" -lt "$_i_restart" ]]; } \
  && ok "_core_restart_clean 里 reset-failed 排在 restart **之前**(第 $_i_reset 行 vs 第 $_i_restart 行)" \
  || bad "reset-failed 不在 restart 之前(reset=$_i_reset restart=$_i_restart) —— 事后补等于没清"
grep -qE 'reset-failed "\$svc"' <<<"$_rc" \
  && ok "reset-failed 明确指定了 unit(不是无参数清全系统 failed 状态)" \
  || bad "reset-failed 没指定 unit —— 会清掉别人的 failed 状态"
for _pair in "_core_swap_verify:$_sv" "_core_restore_prev:$_rp"; do
  _nm="${_pair%%:*}"; _body="${_pair#*:}"
  grep -q '_core_restart_clean' <<<"$_body" \
    && ok "$_nm 走 _core_restart_clean(与另一处同一份时序)" \
    || bad "$_nm 没走 _core_restart_clean"
  grep -qE '^\s*systemctl restart' <<<"$_body" \
    && bad "$_nm 里还留着裸的 systemctl restart —— 那一条不清限速" \
    || ok "$_nm 里没有裸的 systemctl restart"
done
# .prev 只能在新核稳定且监听回来之后才删
_i_lis="$(grep -n '监听端口没有回到换核前' <<<"$_sv" | head -1 | cut -d: -f1)"
_i_rm="$(grep -n 'rm -f "\$bak"' <<<"$_sv" | head -1 | cut -d: -f1)"
{ [[ -n "$_i_lis" && -n "$_i_rm" ]] && [[ "$_i_rm" -gt "$_i_lis" ]]; } \
  && ok "旧核备份(.prev)在监听对账之后才删(第 $_i_rm 行 > 第 $_i_lis 行)" \
  || bad "备份删得太早(lis=$_i_lis rm=$_i_rm) —— 判据还没过就没得退了"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
