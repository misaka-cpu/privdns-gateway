#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Issue 3 回归: 内核热切必须"确认新核稳定运行后才删旧核备份(.prev)"。
#   A. 配置 check 失败      → 还原旧核(内容/sha 一致)、无 .prev 残留、return 1、不报"已装并重启"
#   B. check 过但重启不稳定 → 同上(旧实现此时 .prev 已删 → 无核可退, 正是本 issue)
#   C. 全过                 → 新核就位、.prev 已删、return 0、报"已装并重启"
#   mihomo 与 sing-box 两内核对称覆盖。
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
eval "$(xt _pdg_sha)"; eval "$(xt _core_stash_kernel)"; eval "$(xt _core_restore_prev)"; eval "$(xt _core_swap_verify)"; eval "$(xt _pdg_apply_snapshot_tree)"

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

for svc in mihomo sing-box; do
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
for svc in mihomo sing-box; do
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
for svc in mihomo sing-box; do
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
for svc in mihomo sing-box; do
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
for svc in mihomo sing-box; do
  setup "$svc" 0; NEW_ACTIVE=active; RESTART_LOOP=1; : > "$WORK/nrestarts"
  rc=0; out=$(_core_swap_verify "$svc" "$WORK/new-$svc" "$BIN" vTEST 2>&1) || rc=$?
  unset RESTART_LOOP; rm -f "$WORK/nrestarts"
  { [[ "$rc" != 0 ]] && [[ "$(cursha "$svc")" == "$OLDSHA" ]] && ! grep -q '已装并重启' <<<"$out"; } \
    && ok "$svc: 崩溃循环(NRestarts 上涨)被判不稳定 → 还原旧核 + 非0" \
    || bad "H($svc): rc=$rc sha=$(cursha "$svc")"
done

# ── D. 快照含内核二进制, 且回滚能按内容还原(网络无关) ──
grep -q 'usr/local/bin/mihomo usr/local/bin/sing-box' "$ROOT/deploy/bot/pdg.sh" \
  && ok "cmd_snapshot cand 已含两内核二进制(回滚不依赖联网重下)" || bad "D1: 快照 cand 缺内核二进制"

TREE="$WORK/tree"; DEST="$WORK/dest"; mkdir -p "$TREE/usr/local/bin" "$DEST"
printf '#!/bin/sh\n# SNAPSHOT-OLDKERNEL\nexit 0\n' > "$TREE/usr/local/bin/mihomo"
SNAPSHA=$(sha256sum "$TREE/usr/local/bin/mihomo" | cut -d' ' -f1)
printf 'usr/local/bin/mihomo\n' > "$WORK/members"
mkdir -p "$DEST/usr/local/bin"; printf 'BROKEN-NEW\n' > "$DEST/usr/local/bin/mihomo"
if _pdg_apply_snapshot_tree "$TREE" "$WORK/members" "$DEST" \
   && [[ "$(sha256sum "$DEST/usr/local/bin/mihomo" | cut -d' ' -f1)" == "$SNAPSHA" ]]; then
  ok "回滚落盘: 快照里的内核二进制按 sha 覆盖回坏内核"
else bad "D2: 回滚未还原内核二进制"; fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
