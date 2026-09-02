#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mosdns **真实跨版本换核** E2E: 真 systemd + 两份真上游二进制。
#
# 为什么必须有这一支: v1.11.9 补上了 _update_mosdns_binary, 但 MOSDNS_VER 自那以后没动过,
# 短路判据每次直接返回 —— 这条路径**在真机上一次都没跑过**。既有的
# test-update-mosdns-binary.sh 是离线夹具(假 curl + 现造 zip + shell 桩内核), 它能证明取件与
# 校验的判据, 证明不了"换完之后这台机器还在解析 DNS"。
#
# 这里换的是真的: v5.3.3(上游正式发布) → v5.3.4(仓库钉死版), 两份归档与两份解压产物各自
# 独立钉死 SHA256(旧版见 tests/legacy-pins.sh, 新版走 lib/versions.sh)。
#
# 全程离线: 两份二进制由 CI 的**单一取件步骤**经 artifact 送进来(本机手跑则各 prepare 一次),
# 换核路径里的 curl 由夹具接管, 只从本地喂 zip。
#
# 不碰生产路径: PDG_CORE_BINDIR 指向临时目录, /usr/local/bin/mosdns 一字节不动; 监听走
# 127.0.0.1 高位端口, 不碰 53/853。unit 用真名 mosdns(换核判据按服务名比对监听), 收尾停掉
# 并删除, 末尾有残留断言。
#
# 需要 root 与真 systemd。**不够就判失败, 不 SKIP**。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC2034  # 给 e2e-lib-crossver.sh 用, shellcheck 看不到跨文件
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

XV_WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-crossver.XXXXXX")"
trap xv_cleanup EXIT
xv_require_env || exit 1
ok "环境: root + 真 systemd + 真 systemctl + 无同名 unit 可覆盖"

# ── 清理前像 ─────────────────────────────────────────────────────────────────
# 判据是「结束状态 == 开始状态」, 不是「结束状态等于我以为的那个样子」。
# 上一版把生产路径写成"摘要必须等于钉值": 在开发机上恰好成立(早前 E2E 留下的就是钉死版),
# 在 CI 上那个文件**根本不存在** —— 于是一条"我没碰过它"的断言反而报红(run 33518310032)。
# **「不存在」是一种合法前像**, 不是无条件豁免: 开始不存在, 结束就必须仍然不存在。
state_of(){   # 文件的完整前像; 不存在也是一种状态
  local p="$1"
  [[ -e "$p" ]] || { echo "absent"; return; }
  printf 'present sha=%s mode=%s\n' \
    "$(sha256sum "$p" 2>/dev/null | cut -d' ' -f1)" "$(stat -c %a "$p" 2>/dev/null)"
}
unit_state_of(){   # unit 的完整前像: 文件在不在 + active/enabled/失败结果
  local u="$1"
  [[ -e "/etc/systemd/system/$u.service" ]] || { echo "absent"; return; }
  printf 'present active=%s enabled=%s result=%s\n' \
    "$(systemctl is-active "$u" 2>/dev/null)" "$(systemctl is-enabled "$u" 2>/dev/null)" \
    "$(systemctl show "$u" -p Result --value 2>/dev/null)"
}
nproc_mosdns(){ local n; n="$(pgrep -c -x mosdns 2>/dev/null)"; printf '%s\n' "${n:-0}"; }
nlisten_test(){ ss -lntuH 2>/dev/null | grep -cE ":($XV_UDP_PORT|$XV_DOT_PORT) "; }

PRE_PROD="$(state_of /usr/local/bin/mosdns)"
PRE_UNIT="$(unit_state_of "$XV_UNIT")"
PRE_PROC="$(nproc_mosdns)"
PRE_PORTS="$(nlisten_test)"
[[ "$PRE_PORTS" == 0 ]] || die "开始时 $XV_UDP_PORT/$XV_DOT_PORT 已被占用 —— 现场不干净, 拒绝在上面做判定"
ok "前像已采集: 生产内核[$PRE_PROD] unit[$PRE_UNIT] mosdns进程[$PRE_PROC] 测试端口[$PRE_PORTS]"

ARCH="$(dpkg --print-architecture 2>/dev/null)"; [[ "$ARCH" == arm64 ]] || ARCH=amd64
OLDBIN="${PDG_TEST_MOSDNS_LEGACY:-$ROOT/tests/.bin/mosdns-legacy}"
NEWBIN="${PDG_TEST_MOSDNS:-$ROOT/tests/.bin/mosdns}"
[[ -x "$OLDBIN" ]] || die "拿不到旧版 mosdns($OLDBIN); 本机: bash tests/prepare-mosdns-legacy.sh"
[[ -x "$NEWBIN" ]] || die "拿不到钉死版 mosdns($NEWBIN); 本机: bash tests/prepare-mosdns.sh"
OLD_SHA="$(xv_sha "$OLDBIN")"; NEW_SHA="$(xv_sha "$NEWBIN")"

echo
echo "══ 0. 两份都是真上游件, 各过各的钉值 ══"
[[ "$OLD_SHA" == "${PDG_LEGACY_SHA256[mosdns-bin-$ARCH]}" ]] \
  && ok "旧版二进制 = 旧版钉值(${OLD_SHA:0:12}…)" || die "旧版与钉值不符"
[[ "$NEW_SHA" == "${PDG_SHA256[mosdns-bin-$ARCH]}" ]] \
  && ok "新版二进制 = 仓库钉值(${NEW_SHA:0:12}…)" || die "新版与 lib/versions.sh 钉值不符"
[[ "$OLD_SHA" != "$NEW_SHA" ]] && ok "两份确实不同(跨版本, 不是自己换自己)" || die "新旧同一份"
[[ "$("$OLDBIN" version 2>/dev/null | head -1)" == "$PDG_LEGACY_MOSDNS_SELFVER" ]] \
  && ok "旧版自报整行 = $PDG_LEGACY_MOSDNS_SELFVER" || die "旧版自报版本不符"
"$NEWBIN" version 2>/dev/null | head -1 | grep -q "${MOSDNS_VER#v}" \
  && ok "新版自报含 $MOSDNS_VER" || die "新版自报版本不符"

# 现场 + 闭包(两支共用同一套, 见 e2e-lib-crossver.sh)
xv_setup_site "$OLDBIN" || die "现场搭建失败"
H="$XV_WORK/harness.sh"
xv_build_harness "$H" _core_bindir _pdg_mktemp_dir _core_dl_reason _pdg_sha _core_restart_clean \
  _core_stash_kernel _core_restore_prev _core_kernel_stable _core_listeners \
  _core_config_check _core_swap_verify _pdg_apply_snapshot_tree _update_mosdns_binary || exit 1
ok "换核闭包完整且可解析(13 个函数全在, bash -n 通过)"

mkrepo(){  # $1=归档钉值 $2=二进制钉值
  mkdir -p "$XV_WORK/repo/lib"
  { echo "MOSDNS_VER=\"$MOSDNS_VER\""
    echo "declare -A PDG_SHA256=( [mosdns-$ARCH]=\"$1\" [mosdns-bin-$ARCH]=\"$2\" )"
    sed -n '/^pdg_mosdns_version(){/,/^}/p'    "$ROOT/lib/versions.sh"
    sed -n '/^pdg_mosdns_is_version(){/,/^}/p' "$ROOT/lib/versions.sh"
    sed -n '/^pdg_mosdns_binary_ok(){/,/^}/p'  "$ROOT/lib/versions.sh"
    sed -n '/^pdg_verify_sha256(){/,/^}/p'     "$ROOT/lib/versions.sh"; } > "$XV_WORK/repo/lib/versions.sh"
}
swap(){    # $1=喂进去的 zip → 打印 rc
  local rc=0
  REPO_DIR="$XV_WORK/repo" PDG_CORE_BINDIR="$XV_BINDIR" FEED="$1" \
    bash -c 'source "$0"; [[ "${HARNESS_OK:-}" == 1 ]] || exit 90; _update_mosdns_binary' \
    "$H" > "$XV_WORK/swap.log" 2>&1 || rc=$?
  [[ "$rc" != 90 ]] || die "闭包没加载成功 —— 后面的断言全不算数"
  grep -q 'command not found' "$XV_WORK/swap.log" && die "闭包漏桩: $(grep -m1 'command not found' "$XV_WORK/swap.log")"
  echo "$rc"
}
# 每一格开始前把现场复位成"旧版正在健康运行", 并清掉限速计数 ——
# 上一格留下的状态不能变成下一格的隐式输入(那正是上一轮 cell5 空转变绿的原因)。
reset_site(){
  install -m755 "$OLDBIN" "$XV_BINDIR/mosdns"
  systemctl reset-failed "$XV_UNIT" >/dev/null 2>&1
  systemctl restart "$XV_UNIT" >/dev/null 2>&1
  xv_wait_listeners 3 || return 1
  xv_dns_ok || return 1
}
reset_site || die "现场复位失败"
L0="$(xv_listeners)"
ok "前像: v5.3.3 由真 systemd 管着, UDP/TCP/DoT 三类监听齐, DNS 可查"

echo
echo "══ 1. 成功换核: v5.3.3 → v5.3.4 ══"
xv_mkzip "$XV_WORK/new.zip" "$NEWBIN"
mkrepo "$(xv_sha "$XV_WORK/new.zip")" "${PDG_SHA256[mosdns-bin-$ARCH]}"
NR0="$(systemctl show "$XV_UNIT" -p NRestarts --value)"
rc="$(swap "$XV_WORK/new.zip")"
[[ "$rc" == 0 ]] && ok "换核返回 0" || bad "换核失败(rc=$rc): $(tail -4 "$XV_WORK/swap.log")"
[[ "$(xv_sha "$XV_BINDIR/mosdns")" == "$NEW_SHA" ]] \
  && ok "落盘二进制 = 仓库钉值" || bad "落盘的不是钉死那一份"
"$XV_BINDIR/mosdns" version 2>/dev/null | head -1 | grep -q "${MOSDNS_VER#v}" \
  && ok "落盘二进制自报 $MOSDNS_VER" || bad "落盘版本不对"
[[ "$(systemctl is-active "$XV_UNIT")" == active ]] && ok "systemd active" || bad "不是 active"
[[ "$(systemctl show "$XV_UNIT" -p NRestarts --value)" == "$NR0" ]] \
  && ok "NRestarts 稳定($NR0)" || bad "NRestarts 变了"
for _ in $(seq 1 20); do [[ "$(xv_listeners)" == "$L0" ]] && break; sleep 1; done
[[ "$(xv_listeners)" == "$L0" ]] && ok "UDP/TCP/DoT 监听集合逐条相同" \
  || bad "监听没回来: 前[$(tr '\n' ' ' <<<"$L0")] 后[$(xv_listeners | tr '\n' ' ')]"
xv_dns_ok && ok "DNS 真查询成功" || bad "换核后查不出东西"
shopt -s nullglob; _p=( "$XV_BINDIR"/.mosdns.pdg-prev.* ); shopt -u nullglob
[[ "${#_p[@]}" == 0 ]] && ok ".prev 备份已清理" || bad ".prev 残留: ${_p[*]}"

echo
echo "══ 2. 新核直接启动失败 → 旧核恢复 ══"
# 注入的是**故障本身**(装上去就起不来的候选), 不是拿桩冒充跨版本证据: 这一格要证的是
# "真的 v5.3.3 回到岗位并继续解析"。
reset_site || die "复位失败"
printf '#!/bin/sh\nexit 1\n' > "$XV_WORK/deadbin"; chmod 755 "$XV_WORK/deadbin"
xv_mkzip "$XV_WORK/dead.zip" "$XV_WORK/deadbin"
mkrepo "$(xv_sha "$XV_WORK/dead.zip")" "$(xv_sha "$XV_WORK/deadbin")"
rc="$(swap "$XV_WORK/dead.zip")"
[[ "$rc" != 0 ]] && ok "整次换核返回非零" || bad "起不来的新核被判成功"
[[ "$(xv_sha "$XV_BINDIR/mosdns")" == "$OLD_SHA" ]] && ok "盘上恢复成真的 v5.3.3" || bad "没恢复旧版"
for _ in $(seq 1 20); do [[ "$(xv_listeners)" == "$L0" ]] && break; sleep 1; done
{ [[ "$(systemctl is-active "$XV_UNIT")" == active ]] && [[ "$(xv_listeners)" == "$L0" ]]; } \
  && ok "旧核重新稳定, 三类监听恢复" || bad "旧核没恢复(is-active=$(systemctl is-active "$XV_UNIT"))"
xv_dns_ok && ok "DNS 恢复" || bad "回退后 DNS 不通"
shopt -s nullglob; _p=( "$XV_BINDIR"/.mosdns.pdg-prev.* ); shopt -u nullglob
[[ "${#_p[@]}" == 0 ]] && ok "失败路径也没留下 .prev" || bad ".prev 残留: ${_p[*]}"

echo
echo "══ 3. 新核触发真实 start-limit-hit → 仍须恢复 ══"
reset_site || die "复位失败"
SLB="$(systemctl show "$XV_UNIT" -p StartLimitBurst --value)"; BURN=$(( ${SLB:-5} - 1 ))
for ((i=0;i<BURN;i++)); do systemctl restart "$XV_UNIT" >/dev/null 2>&1; done
xv_wait_listeners 3 >/dev/null 2>&1
ok "预置: 窗口内已有 $BURN 次启动(burst=$SLB), 预算逼近用尽"
rc="$(swap "$XV_WORK/dead.zip")"
[[ "$rc" != 0 ]] && ok "预算用尽 + 新核起不来 → 换核返回非零" || bad "被判成功了"
[[ "$(xv_sha "$XV_BINDIR/mosdns")" == "$OLD_SHA" ]] && ok "盘上恢复成真的 v5.3.3" || bad "没恢复旧版"
for _ in $(seq 1 20); do [[ "$(xv_listeners)" == "$L0" ]] && break; sleep 1; done
{ [[ "$(systemctl is-active "$XV_UNIT")" == active ]] && [[ "$(xv_listeners)" == "$L0" ]] && xv_dns_ok; } \
  && ok "限速现场下旧核仍然恢复并继续解析(这正是 _core_restart_clean 要保住的)" \
  || bad "限速现场下旧核没能恢复 —— 恢复闭包又被挡住了"

echo
echo "══ 4. 新核 active 但监听漂移 → 判红并恢复 ══"
# 服务活着、端口没绑回来: is-active 与 NRestarts 都看不见, 只有监听对账能拦。
reset_site || die "复位失败"
printf '#!/bin/sh\nsleep 3600\n' > "$XV_WORK/mutebin"; chmod 755 "$XV_WORK/mutebin"
xv_mkzip "$XV_WORK/mute.zip" "$XV_WORK/mutebin"
mkrepo "$(xv_sha "$XV_WORK/mute.zip")" "$(xv_sha "$XV_WORK/mutebin")"
rc="$(swap "$XV_WORK/mute.zip")"
[[ "$rc" != 0 ]] && ok "起得来但不绑端口 → 换核返回非零" || bad "监听没回来却判成功"
grep -q '监听端口没有回到换核前' "$XV_WORK/swap.log" \
  && ok "失败原因点名监听集合(不是笼统的「起不来」)" || bad "原因没点名监听: $(tail -3 "$XV_WORK/swap.log")"
[[ "$(xv_sha "$XV_BINDIR/mosdns")" == "$OLD_SHA" ]] && ok "盘上恢复成真的 v5.3.3" || bad "没恢复旧版"
for _ in $(seq 1 20); do [[ "$(xv_listeners)" == "$L0" ]] && break; sleep 1; done
{ [[ "$(xv_listeners)" == "$L0" ]] && xv_dns_ok; } && ok "旧核监听齐备, DNS 恢复" || bad "旧核没恢复"

echo
echo "══ 5. 换核成功后, 后续步骤失败 → 快照恢复旧版 ══"
# 走真实的 _pdg_apply_snapshot_tree(cmd_rollback 落盘用的就是它), 快照里放 v5.3.3。
reset_site || die "复位失败"
SNAP="$XV_WORK/snap"; mkdir -p "$SNAP/usr/local/bin"
cp -a "$XV_BINDIR/mosdns" "$SNAP/usr/local/bin/mosdns"          # 前像: v5.3.3
printf 'usr/local/bin/mosdns\n' > "$XV_WORK/members"
mkrepo "$(xv_sha "$XV_WORK/new.zip")" "${PDG_SHA256[mosdns-bin-$ARCH]}"
rc="$(swap "$XV_WORK/new.zip")"
[[ "$rc" == 0 && "$(xv_sha "$XV_BINDIR/mosdns")" == "$NEW_SHA" ]] \
  && ok "先换核成功(盘上已是 v5.3.4)" || bad "前置换核没成功"
DESTROOT="$XV_WORK/destroot"; mkdir -p "$DESTROOT/usr/local/bin"
cp -a "$XV_BINDIR/mosdns" "$DESTROOT/usr/local/bin/mosdns"
REPO_DIR="$XV_WORK/repo" bash -c 'source "$0"; _pdg_apply_snapshot_tree "$1" "$2" "$3"' \
  "$H" "$SNAP" "$XV_WORK/members" "$DESTROOT" >/dev/null 2>&1
[[ "$(xv_sha "$DESTROOT/usr/local/bin/mosdns")" == "$OLD_SHA" ]] \
  && ok "cmd_rollback 的落盘原语把快照里的 v5.3.3 放了回去" || bad "快照恢复没把旧版放回去"
install -m755 "$DESTROOT/usr/local/bin/mosdns" "$XV_BINDIR/mosdns"
systemctl reset-failed "$XV_UNIT" >/dev/null 2>&1; systemctl restart "$XV_UNIT" >/dev/null 2>&1
xv_wait_listeners 3 >/dev/null 2>&1
{ [[ "$(xv_sha "$XV_BINDIR/mosdns")" == "$OLD_SHA" ]] && [[ "$(xv_listeners)" == "$L0" ]] && xv_dns_ok; } \
  && ok "回滚后二进制/监听/DNS 都回到前像" || bad "回滚后没回到前像"

echo
echo "══ 6. 恢复闭包自身失败: 不许报「已恢复」 ══"
# 让 restore 之后的 restart 真的失败(备份里就是个起不来的东西), 判据是: 返回非零、
# 文案点明"恢复闭包未完成"、且带出 reset-failed 的线索、盘上证据不被抹掉。
reset_site || die "复位失败"
BAKBIN="$XV_WORK/badbak"; printf '#!/bin/sh\nexit 3\n' > "$BAKBIN"; chmod 755 "$BAKBIN"
out="$(REPO_DIR="$XV_WORK/repo" PDG_CORE_BINDIR="$XV_BINDIR" \
  bash -c 'source "$0"; cp -a "$1" "$2/.mosdns.pdg-prev.test"
           _core_restore_prev mosdns "$2" "$2/.mosdns.pdg-prev.test" "$(_pdg_sha "$1")"' \
  "$H" "$BAKBIN" "$XV_BINDIR" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ok "恢复失败 → 返回非零" || bad "恢复失败却返回 0"
grep -q '恢复闭包未完成' <<<"$out" \
  && ok "文案点明恢复闭包未完成(不是笼统的「不稳定」)" || bad "文案没点明: $out"
grep -q '已还原到盘上' <<<"$out" \
  && ok "文案分清了「文件已还原」与「服务没回来」" || bad "文案没分清: $out"
[[ -e "$XV_BINDIR/mosdns" ]] && ok "盘上仍留有内核文件(证据没被抹掉)" || bad "把现场删空了"

# 6c: 备份内容与登记的摘要对不上 → 必须在重启之前就拒绝。
# 备份是"退路"的全部内容; 它要是被换过, 还原就等于把一个来路不明的文件装上去再起服务。
out6c="$(REPO_DIR="$XV_WORK/repo" PDG_CORE_BINDIR="$XV_BINDIR" \
  bash -c 'source "$0"; cp -a "$1" "$2/.mosdns.pdg-prev.bad"
           _core_restore_prev mosdns "$2" "$2/.mosdns.pdg-prev.bad" deadbeef' \
  "$H" "$OLDBIN" "$XV_BINDIR" 2>&1)"; rc6c=$?
[[ "$rc6c" != 0 ]] && ok "6c: 备份摘要对不上 → 还原被拒(返回非零)" || bad "6c: 摘要不符却还原了"
grep -q '校验和与备份不符' <<<"$out6c" \
  && ok "6c: 点名是校验和不符, 不是笼统失败" || bad "6c: 原因没点名: $out6c"
rm -f "$XV_BINDIR"/.mosdns.pdg-prev.*

# 6d: **直打恢复路径**的限速。_core_swap_verify 里新核那次 restart 会先把计数清掉, 于是
# 恢复时预算总是新的 —— 恢复侧那句 reset-failed 在"换核已经重启过新核"的路径上被上游遮住了。
# 它真正要保住的是**还没走到新核 restart 就失败**的那几条(装不上去 / 配置检查不过), 那时
# 预算还是进函数时的样子。这里把预算真正打满, 再直接调 _core_restore_prev, 让那句话单独受检。
reset_site || die "复位失败"
SLB6="$(systemctl show "$XV_UNIT" -p StartLimitBurst --value)"
for ((i=0;i<=${SLB6:-5};i++)); do systemctl restart "$XV_UNIT" >/dev/null 2>&1; done
if systemctl restart "$XV_UNIT" >/dev/null 2>&1; then
  bad "6d 前提不成立: 预算没打满(burst=$SLB6), 这一格测不到目标形态"
else
  ok "6d 前提: 预算已打满, 裸 restart 被 systemd 拒"
  cp -a "$OLDBIN" "$XV_WORK/goodbak"
  out6d="$(REPO_DIR="$XV_WORK/repo" PDG_CORE_BINDIR="$XV_BINDIR" \
    bash -c 'source "$0"; cp -a "$1" "$2/.mosdns.pdg-prev.good"
             _core_restore_prev mosdns "$2" "$2/.mosdns.pdg-prev.good" "$(_pdg_sha "$1")"' \
    "$H" "$XV_WORK/goodbak" "$XV_BINDIR" 2>&1)"; rc6d=$?
  [[ "$rc6d" == 0 ]] \
    && ok "6d: 预算打满时, _core_restore_prev 自己就能把旧核带回来(恢复侧的 reset-failed 起作用)" \
    || bad "6d: 预算打满时恢复失败(rc=$rc6d): $out6d"
  xv_wait_listeners 3 >/dev/null 2>&1
  { [[ "$(systemctl is-active "$XV_UNIT")" == active ]] && xv_dns_ok; } \
    && ok "6d: 恢复后服务 active 且 DNS 可查" || bad "6d: 恢复后服务没起来"
  rm -f "$XV_BINDIR"/.mosdns.pdg-prev.*
fi

# 6b: systemd 直接**拒绝** start 的那条分支。Type=simple 下 `systemctl restart` 对"起来就退"
# 的进程是返回 0 的(失败由 _core_kernel_stable 抓), 所以真现场里走不到那条分支 —— 修好之后
# 更走不到(限速已经被清掉了)。这里只把 systemctl restart 打成非零来验**文案**: 拒绝时必须
# 带出 reset-failed 的线索, 否则限速没清掉这件事会被说成别的原因。
out6b="$(PDG_CORE_BINDIR="$XV_BINDIR" bash -c '
  c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
  systemctl(){ case "$1" in reset-failed) echo "Unit not loaded." >&2; return 1;; restart) return 1;; esac; return 0; }
  '"$(sed -n '/^_core_restart_clean(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"'
  _core_restart_clean mosdns' 2>&1)"; rc6b=$?
[[ "$rc6b" != 0 ]] && ok "6b: systemd 拒绝 start → _core_restart_clean 返回非零" || bad "6b: 拒绝了却返回 0"
grep -q 'reset-failed' <<<"$out6b" \
  && ok "6b: 拒绝时带出 reset-failed 的返回码与输出(不静默冒充成别的原因)" \
  || bad "6b: reset-failed 的线索被吞了: $out6b"
reset_site || die "复位失败"

echo
echo "══ 7. 幂等短路: 已是钉死版就什么都不做 ══"
install -m755 "$NEWBIN" "$XV_BINDIR/mosdns"
systemctl reset-failed "$XV_UNIT" >/dev/null 2>&1; systemctl restart "$XV_UNIT" >/dev/null 2>&1
xv_wait_listeners 3 >/dev/null 2>&1
mkrepo "$(xv_sha "$XV_WORK/new.zip")" "${PDG_SHA256[mosdns-bin-$ARCH]}"
NR7="$(systemctl show "$XV_UNIT" -p NRestarts --value)"
INV7="$(systemctl show "$XV_UNIT" -p InvocationID --value)"
TMPN0="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)"
rc="$(swap "$XV_WORK/new.zip")"
[[ "$rc" == 0 ]] && ok "短路返回 0" || bad "短路失败(rc=$rc)"
[[ ! -s "$XV_WORK/swap.log" ]] && ok "一个字都没打印(没下载、没换核)" \
  || bad "短路却有输出: $(cat "$XV_WORK/swap.log")"
[[ "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)" == "$TMPN0" ]] \
  && ok "没有新建临时目录" || bad "短路还是建了临时目录"
[[ "$(systemctl show "$XV_UNIT" -p InvocationID --value)" == "$INV7" ]] \
  && ok "服务没有被重启(InvocationID 未变)" || bad "短路却重启了服务"
[[ "$(systemctl show "$XV_UNIT" -p NRestarts --value)" == "$NR7" ]] \
  && ok "NRestarts 未变" || bad "NRestarts 变了"

echo
echo "══ 残留: 先验前后一致, 再收尾验清零 ══"
shopt -s nullglob; _p=( "$XV_BINDIR"/.mosdns.pdg-prev.* "$XV_BINDIR"/*.prev ); shopt -u nullglob
[[ "${#_p[@]}" == 0 ]] && ok "bindir 无 .prev 残留" || bad "残留: ${_p[*]}"
[[ ! -e /m.zip && ! -e /mosdns ]] && ok "根目录无残留" || bad "根目录有残留"

# 没碰别人的东西: 结束状态必须逐字等于前像(含"开始就不存在, 结束也得不存在")。
POST_PROD="$(state_of /usr/local/bin/mosdns)"
[[ "$POST_PROD" == "$PRE_PROD" ]] \
  && ok "生产路径 /usr/local/bin/mosdns 前后一致([$PRE_PROD])" \
  || bad "生产路径被动过: 前[$PRE_PROD] 后[$POST_PROD]"

# 测试自己造的东西**无条件清零**, 不受前像影响 —— 前像里它们本来就都不存在
# (unit 由 xv_require_env 挡掉同名, 端口在采集前像时已确认无人监听)。
# 收尾在这里显式跑一次(xv_cleanup 幂等, EXIT trap 再跑无副作用), 好让"清零"成为**被断言过**
# 的事实, 而不是留给 CI 收尾步去发现。
xv_cleanup
[[ "$(unit_state_of "$XV_UNIT")" == absent ]] \
  && ok "测试建的 $XV_UNIT.service 已删除(前像 absent → 结束 absent)" \
  || bad "unit 残留: $(unit_state_of "$XV_UNIT")"
[[ "$(nproc_mosdns)" == "$PRE_PROC" ]] \
  && ok "mosdns 进程数回到前像($PRE_PROC)" || bad "进程残留: 前 $PRE_PROC 后 $(nproc_mosdns)"
[[ "$(nlisten_test)" == 0 ]] \
  && ok "测试端口 $XV_UDP_PORT/$XV_DOT_PORT 无人监听" || bad "端口残留: $(nlisten_test) 条"
[[ ! -d "$XV_WORK" ]] && ok "临时目录已删除" || bad "临时目录残留: $XV_WORK"
[[ ! -e /etc/systemd/system/pdg-xv-ctrl.service ]] \
  && ok "无 pdg-xv-ctrl.service 残留(另一支 E2E 的对照 unit)" || bad "pdg-xv-ctrl.service 残留"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
