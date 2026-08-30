#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Issue 3 回归: 内核热切必须"确认新核稳定运行后才删旧核备份(.prev)"。
#   A. 配置 check 失败      → 还原旧核(内容/sha 一致)、无 .prev 残留、return 1、不报"已装并重启"
#   B. check 过但重启不稳定 → 同上(旧实现此时 .prev 已删 → 无核可退, 正是本 issue)
#   C. 全过                 → 新核就位、.prev 已删、return 0、报"已装并重启"
#   v1.6.0 起 mihomo 是唯一内核(sing-box 运行时已移除), 故只覆盖 mihomo。
#   D. 快照含内核二进制 + 回滚能按内容还原(不依赖联网重下)。
# 沙箱化: PDG_CORE_BINDIR 指到临时目录; systemctl is-active 依"当前装的是新核还是旧核"作答。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

xt(){ sed -n "/^$1(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"; }
eval "$(xt _core_bindir)"; eval "$(xt _core_config_check)"; eval "$(xt _core_kernel_stable)"
eval "$(xt _core_listeners)"
eval "$(xt _pdg_sha)"; eval "$(xt _core_stash_kernel)"; eval "$(xt _core_restore_prev)"; eval "$(xt _core_swap_verify)"; eval "$(xt _pdg_apply_snapshot_tree)"
eval "$(xt _pdg_mktemp_dir)"
# 落盘要先给 iOS 生命周期拍完整底片, 那套 helper 全在 pdg.sh 里。按前缀自动抽 —— 写死
# 名字的话, 生产那边多加一个 helper 就变成 "command not found" 的假红(已经发生过两次)。
eval "$(sed -n '/^_PDG_IOS_[A-Z_]*=/p' "$ROOT/deploy/bot/pdg.sh")"
for _f in $(grep -oE '^_pdg_ios_[a-z_]+\(\)' "$ROOT/deploy/bot/pdg.sh" | tr -d '()'); do
  eval "$(sed -n "/^$_f(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh")"
done

c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
sleep(){ :; }
BIN="$WORK/bin"; export PDG_CORE_BINDIR="$BIN"
# is-active: 装的是新核 → 用 NEW_ACTIVE 模拟其死活; 旧核一律 active(还原后应恢复)
systemctl(){
  if [[ "${1:-}" == is-active ]]; then
    if grep -q NEWKERNEL "$BIN/${2:-}" 2>/dev/null; then echo "${NEW_ACTIVE:-active}"; else echo active; fi
  elif [[ "${1:-}" == show ]]; then
    # 模拟 NRestarts: RESTART_LOOP=1 时每问一次就涨一次(起来即崩的样子)。
    # 必须用文件计数 —— $(systemctl show …) 在子 shell 里跑, 变量自增回传不到父 shell。
    if [[ -n "${RESTART_LOOP:-}" ]]; then
      local n; n=$(( $(cat "$WORK/nrestarts" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$WORK/nrestarts"; echo "$n"
    else echo 0; fi
  fi
  return 0
}

setup(){ # $1=svc $2=新核 check 退出码
  rm -rf "$BIN"; mkdir -p "$BIN"
  printf '#!/bin/sh\n# OLDKERNEL\nexit 0\n' > "$BIN/$1"; chmod 755 "$BIN/$1"
  OLDSHA=$(sha256sum "$BIN/$1" | cut -d' ' -f1)
  printf '#!/bin/sh\n# NEWKERNEL\nexit %s\n' "$2" > "$WORK/new-$1"; chmod 755 "$WORK/new-$1"
  NEWSHA=$(sha256sum "$WORK/new-$1" | cut -d' ' -f1)
}
cursha(){ sha256sum "$BIN/$1" | cut -d' ' -f1; }

# A 只对有离线 check 的组件成立。mosdns 的 _core_config_check 恒返回 2(查不了),
# 拿它跑这一格测的是"不存在的能力失败了没有", 没有意义 —— 它那条路由 I/J 两组覆盖。
# shellcheck disable=SC2043  # 有意只有 mihomo 一项; 将来再有带离线 check 的组件直接扩列表
for svc in mihomo; do
  # ── A. 配置 check 失败 → 还原旧核 ──
  setup "$svc" 3; NEW_ACTIVE=active
  rc=0; out=$(_core_swap_verify "$svc" "$WORK/new-$svc" "$BIN" vTEST 2>&1) || rc=$?
  { [[ "$rc" != 0 ]] && [[ "$(cursha "$svc")" == "$OLDSHA" ]] && [[ ! -e "$BIN/$svc.prev" ]] \
    && ! grep -q '已装并重启' <<<"$out"; } \
    && ok "$svc: check 失败 → 旧核按 sha 还原 + 无 .prev 残留 + 非0 + 不报已装" \
    || bad "$svc A: rc=$rc sha=$(cursha "$svc") prev=$([[ -e "$BIN/$svc.prev" ]] && echo 有 || echo 无) out=$out"

  # ── B. check 过但新核重启后不 active → 仍能退回旧核(旧实现此处 .prev 已删) ──
  setup "$svc" 0; NEW_ACTIVE=failed
  rc=0; out=$(_core_swap_verify "$svc" "$WORK/new-$svc" "$BIN" vTEST 2>&1) || rc=$?
  { [[ "$rc" != 0 ]] && [[ "$(cursha "$svc")" == "$OLDSHA" ]] && [[ ! -e "$BIN/$svc.prev" ]] \
    && ! grep -q '已装并重启' <<<"$out"; } \
    && ok "$svc: 重启后不稳定 → 旧核按 sha 还原 + 非0 + 不报已装(核心回归)" \
    || bad "$svc B: rc=$rc sha=$(cursha "$svc") prev=$([[ -e "$BIN/$svc.prev" ]] && echo 有 || echo 无) out=$out"

  # ── C. 全过 → 新核就位, .prev 删掉, 报已装并重启 ──
  setup "$svc" 0; NEW_ACTIVE=active
  rc=0; out=$(_core_swap_verify "$svc" "$WORK/new-$svc" "$BIN" vTEST 2>&1) || rc=$?
  { [[ "$rc" == 0 ]] && [[ "$(cursha "$svc")" == "$NEWSHA" ]] && [[ ! -e "$BIN/$svc.prev" ]] \
    && grep -q '已装并重启' <<<"$out"; } \
    && ok "$svc: 全过 → 新核按 sha 就位 + .prev 已删 + 报已装并重启" \
    || bad "$svc C: rc=$rc sha=$(cursha "$svc") out=$out"
done

# ── E. 备份失败必须在装新内核之前中止(问题四) ────────────────────────────
# 旧实现 `cp -a "$bin" "$prev"` 不看结果, 备份没成也照装新核 → 出事时无核可退。
for svc in mihomo mosdns; do
  setup "$svc" 0; NEW_ACTIVE=active
  rc=0
  out=$(cp(){ return 1; }                       # 注入: 备份拷不动
        install(){ echo "INSTALL_RAN" >&2; command install "$@"; }
        _core_swap_verify "$svc" "$WORK/new-$svc" "$BIN" vTEST 2>&1) || rc=$?
  { [[ "$rc" != 0 ]] && ! grep -q INSTALL_RAN <<<"$out" && [[ "$(cursha "$svc")" == "$OLDSHA" ]]; } \
    && ok "$svc: 备份失败 → 非0 且新内核 install 从未执行, 旧核原封不动" \
    || bad "E($svc): rc=$rc out=$out"
done

# ── F. 历史遗留的 <svc>.prev 不得被当成"本次备份"还原回去 ──────────────────
# 真正的危险: 备份 cp 失败时旧实现原地留下上次的 .prev, 还原那步会把这个**来源不明的
# 历史文件** mv 成当前内核 —— 等于用一个谁也不知道是什么的二进制顶替了正在跑的内核。
for svc in mihomo mosdns; do
  setup "$svc" 3; NEW_ACTIVE=active
  printf '#!/bin/sh\n# STALE-HISTORICAL-PREV\nexit 0\n' > "$BIN/$svc.prev"
  rc=0
  out=$(cp(){ return 1; }                      # 备份拷不动, 历史 .prev 原地不动
        _core_swap_verify "$svc" "$WORK/new-$svc" "$BIN" vTEST 2>&1) || rc=$?
  { [[ "$rc" != 0 ]] && ! grep -q STALE "$BIN/$svc" 2>/dev/null && [[ "$(cursha "$svc")" == "$OLDSHA" ]]; } \
    && ok "$svc: 备份失败且存在历史 .prev → 不拿它顶替内核, 旧核原封不动" \
    || bad "F($svc): rc=$rc 当前内核=$(sed -n 2p "$BIN/$svc" 2>/dev/null)"
  rm -f "$BIN/$svc.prev"
done

# ── G. 还原时 mv 失败 → _core_restore_prev 必须返回非0(不能只凭服务 active 判成功) ──
for svc in mihomo mosdns; do
  setup "$svc" 0; NEW_ACTIVE=active
  cp -a "$BIN/$svc" "$BIN/$svc.prev"           # 备份路径同时喂给新旧两种签名
  rc=0
  out=$(mv(){ return 1; }
        _core_restore_prev "$svc" "$BIN" "$BIN/$svc.prev" "$OLDSHA" 2>&1) || rc=$?
  [[ "$rc" != 0 ]] && ok "$svc: 还原 mv 失败 → _core_restore_prev 返回非0(服务 active 不算数)" \
    || bad "G($svc): rc=$rc out=$out"
  rm -f "$BIN/$svc.prev"
done

# ── H. 起来即崩: is-active 每次都答 active, 但观察窗口内 NRestarts 在涨 → 必须判不稳定 ──
for svc in mihomo mosdns; do
  setup "$svc" 0; NEW_ACTIVE=active; RESTART_LOOP=1; : > "$WORK/nrestarts"
  rc=0; out=$(_core_swap_verify "$svc" "$WORK/new-$svc" "$BIN" vTEST 2>&1) || rc=$?
  unset RESTART_LOOP; rm -f "$WORK/nrestarts"
  { [[ "$rc" != 0 ]] && [[ "$(cursha "$svc")" == "$OLDSHA" ]] && ! grep -q '已装并重启' <<<"$out"; } \
    && ok "$svc: 崩溃循环(NRestarts 上涨)被判不稳定 → 还原旧核 + 非0" \
    || bad "H($svc): rc=$rc sha=$(cursha "$svc")"
done

# ── D. 快照含内核二进制, 且回滚能按内容还原(网络无关) ──
grep -q 'usr/local/bin/mosdns usr/local/bin/mihomo usr/local/bin/sing-box' "$ROOT/deploy/bot/pdg.sh" \
  && ok "cmd_snapshot cand 已含 mosdns + 两内核二进制(回滚不依赖联网重下)" || bad "D1: 快照 cand 缺二进制"

TREE="$WORK/tree"; DEST="$WORK/dest"; mkdir -p "$TREE/usr/local/bin" "$DEST"
printf '#!/bin/sh\n# SNAPSHOT-OLDKERNEL\nexit 0\n' > "$TREE/usr/local/bin/mihomo"
SNAPSHA=$(sha256sum "$TREE/usr/local/bin/mihomo" | cut -d' ' -f1)
printf 'usr/local/bin/mihomo\n' > "$WORK/members"
mkdir -p "$DEST/usr/local/bin"; printf 'BROKEN-NEW\n' > "$DEST/usr/local/bin/mihomo"
if _pdg_apply_snapshot_tree "$TREE" "$WORK/members" "$DEST" \
   && [[ "$(sha256sum "$DEST/usr/local/bin/mihomo" | cut -d' ' -f1)" == "$SNAPSHA" ]]; then
  ok "回滚落盘: 快照里的内核二进制按 sha 覆盖回坏内核"
else bad "D2: 回滚未还原内核二进制"; fi

# ── I. "没有离线校验能力" 必须是一个**独立状态**, 不许伪装成"检查通过" ──────
# mosdns 上游没有 -t / validate。诱惑是让 _core_config_check 直接 return 0 —— 那样
# 调用方就会把"我没查"当成"我查过没问题", 而这正是本项目反复在清的那类假绿。
rc=0; _core_config_check mosdns "$BIN" || rc=$?
[[ "$rc" == 2 ]] && ok "mosdns: 离线校验返回 2(具名的「查不了」), 不是 0" \
  || bad "I1: mosdns 的离线校验返回 $rc —— 0 就是把「没查」说成了「通过」"
rc=0; _core_config_check no-such-core "$BIN" || rc=$?
{ [[ "$rc" != 0 && "$rc" != 2 ]]; } \
  && ok "不认识的组件: 判失败(不替它宣布检查通过)" || bad "I2: 未知组件返回 $rc"

# ── J. 换核后的监听对照: 端口没回来 = 与配置不兼容 → 还原 ───────────────────
# 这是替 mosdns 补上离线 check 那一层的判据。配置解析不了 / server 插件起不来的形态,
# 恰恰是"服务活着但端口没绑回来" —— is-active 和 NRestarts 都看不见它。
setup mosdns 0; NEW_ACTIVE=active
# 桩必须按**调用次序**作答: 第一次是换核前的前像, 之后才是换核后的。
# (第一版按"文件存不存在"分支, 结果前后两次拿到同一个值, 判据恒真 —— 那就是个假绿桩。)
_core_listeners(){
  local n; n=$(( $(cat "$WORK/lcount" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/lcount"
  if [[ "$n" == 1 ]]; then printf 'udp:127.0.0.1:53\n'; else cat "$WORK/after"; fi
}
: > "$WORK/lcount"; printf 'udp:127.0.0.1:9999\n' > "$WORK/after"   # 换核后绑到了别处
rc=0; out=$(_core_swap_verify mosdns "$WORK/new-mosdns" "$BIN" vTEST 2>&1) || rc=$?
{ [[ "$rc" != 0 ]] && [[ "$(cursha mosdns)" == "$OLDSHA" ]] && ! grep -q '已装并重启' <<<"$out"; } \
  && ok "mosdns: 监听端口没回到换核前的样子 → 还原旧版 + 非 0" \
  || bad "J1: rc=$rc sha=$(cursha mosdns) out=$out"
grep -q '换核前' <<<"$out" && ok "mosdns: 把前后两组监听都打了出来(能查)" || bad "J2: 没打印前后对照"

setup mosdns 0; NEW_ACTIVE=active
: > "$WORK/lcount"; printf 'udp:127.0.0.1:53\n' > "$WORK/after"    # 端口原样回来
rc=0; out=$(_core_swap_verify mosdns "$WORK/new-mosdns" "$BIN" vTEST 2>&1) || rc=$?
{ [[ "$rc" == 0 ]] && [[ "$(cursha mosdns)" == "$NEWSHA" ]] && grep -q '已装并重启' <<<"$out"; } \
  && ok "mosdns: 监听原样回来 → 换核成功" || bad "J3: rc=$rc sha=$(cursha mosdns) out=$out"

# 前像读不到时**明说**只验到活性, 不许闷声当成"比过了"
setup mosdns 0; NEW_ACTIVE=active
_core_listeners(){ printf ''; }
rc=0; out=$(_core_swap_verify mosdns "$WORK/new-mosdns" "$BIN" vTEST 2>&1) || rc=$?
{ [[ "$rc" == 0 ]] && grep -q '只验到' <<<"$out"; } \
  && ok "mosdns: 读不到监听前像 → 放行但**明说**本次只验到活性与稳定性" \
  || bad "J4: rc=$rc out=$out"
# J5. 端口**晚几拍**才绑上 → 不许误判。mosdns 要先读完规则集才 bind, 去广告规则大的时候
# 那是秒级的; 单次抽样会把"还没绑好"当成"绑不回来", 而这条的处置是让整次更新回滚。
setup mosdns 0; NEW_ACTIVE=active
: > "$WORK/lcount"
_core_listeners(){
  local n; n=$(( $(cat "$WORK/lcount" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/lcount"
  # 第 1 次是前像; 第 2..4 次还没绑上(空); 第 5 次起才回到原样
  if [[ "$n" == 1 ]]; then printf 'udp:127.0.0.1:53\n'
  elif [[ "$n" -le 4 ]]; then printf ''
  else printf 'udp:127.0.0.1:53\n'; fi
}
rc=0; out=$(_core_swap_verify mosdns "$WORK/new-mosdns" "$BIN" vTEST 2>&1) || rc=$?
{ [[ "$rc" == 0 ]] && [[ "$(cursha mosdns)" == "$NEWSHA" ]] && grep -q '已装并重启' <<<"$out"; } \
  && ok "mosdns: 端口晚几拍才绑上 → 有界重试等到了, 没有误判成不兼容" \
  || bad "J5: 慢启动被误判(rc=$rc sha=$(cursha mosdns)) —— 一次计时误判就能拖垮整次更新"

rm -f "$WORK/after" "$WORK/lcount"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
