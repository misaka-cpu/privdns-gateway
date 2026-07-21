#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# switch-core 内核切换的 enable/disable 纪律回归(Item 7)。
# 不起真核心/真 systemd: 用**假 systemctl 状态机**(记录每个 unit 的 active/enabled)
# + 重启模拟, 验证:
#   A. 切换后: 目标核 active+enabled, 旧核 inactive+**disabled**(不再只 stop 不 disable)。
#   B. 重启只起一个内核(enabled 集里内核唯一)—— 旧坑: 旧核仍 enabled → reboot 双起冲突。
#   C. 目标核起不来 → activate 返回失败, restore 把旧核 enable+start 回来。
#   D. "旧核 disable 没生效(仍 enabled)"必须被 activate 判失败(不放过潜在双起)。
#   E. unit 模板单一事实源: mihomo unit 含 SAFE_PATHS, 且切核与装机用同一函数(无漂移)。
# 退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# ── 抽取被测函数 + 单一事实源 unit 库 ────────────────────────────────────────
sed -n '/^_core_kernel_activate(){/,/^cmd_switch_core(){/p' "$ROOT/deploy/bot/pdg.sh" | sed '$d' > "$WORK/helpers.sh"
grep -q '_core_kernel_restore' "$WORK/helpers.sh" && ok "抽出 activate/restore 两个收尾函数" || bad "抽取失败"

# ── 假 systemctl 状态机(active/enabled 双状态) + 故障注入 ────────────────────
cat > "$WORK/harness.sh" <<'EOF'
declare -A ACTIVE ENABLED
FAIL_ENABLE=""      # 令某 unit 的 enable 失败(模拟起不来)
NODISABLE=""        # 令某 unit 的 disable 变空操作(模拟旧核没被真正停用)
sleep(){ :; }       # 跳过 activate 里的 sleep 2
systemctl(){
  local verb="$1"; shift
  case "$verb" in
    daemon-reload|reset-failed) return 0;;
    enable)
      local now=0; [[ "${1:-}" == --now ]] && { now=1; shift; }
      local u; for u in "$@"; do
        [[ "$u" == "$FAIL_ENABLE" ]] && return 1
        ENABLED[$u]=1; [[ "$now" == 1 ]] && ACTIVE[$u]=1
      done; return 0;;
    disable)
      local now=0; [[ "${1:-}" == --now ]] && { now=1; shift; }
      local u; for u in "$@"; do
        [[ "$u" == "$NODISABLE" ]] && continue
        ENABLED[$u]=0; [[ "$now" == 1 ]] && ACTIVE[$u]=0
      done; return 0;;
    start|restart) local u; for u in "$@"; do ACTIVE[$u]=1; done; return 0;;
    stop)          local u; for u in "$@"; do ACTIVE[$u]=0; done; return 0;;
    is-active)  [[ "${ACTIVE[$1]:-0}"  == 1 ]] && { echo active;  return 0; } || { echo inactive; return 3; };;
    is-enabled) [[ "${ENABLED[$1]:-0}" == 1 ]] && { echo enabled; return 0; } || { echo disabled; return 1; };;
  esac
  return 0
}
reboot_sim(){ local u; for u in "${!ENABLED[@]}"; do [[ "${ENABLED[$u]}" == 1 ]] && ACTIVE[$u]=1 || ACTIVE[$u]=0; done; }
kernels_active(){ local n=0 u; for u in mihomo sing-box; do [[ "${ACTIVE[$u]:-0}" == 1 ]] && n=$((n+1)); done; echo "$n"; }
EOF

run(){ bash -c "source '$WORK/harness.sh'; source '$WORK/helpers.sh'; $1"; }

# ── A + B. sing-box→mihomo: 目标 active+enabled, 旧核 inactive+disabled, 重启只起一个 ──
out=$(run '
  ENABLED[sing-box]=1; ACTIVE[sing-box]=1        # 初态: 跑着 sing-box
  _core_kernel_activate mihomo sing-box; rc=$?
  echo "rc=$rc mihomo=${ACTIVE[mihomo]:-0}/${ENABLED[mihomo]:-0} singbox=${ACTIVE[sing-box]:-0}/${ENABLED[sing-box]:-0}"
  reboot_sim; echo "reboot_kernels=$(kernels_active) mihomo_after=${ACTIVE[mihomo]:-0} singbox_after=${ACTIVE[sing-box]:-0}"
')
echo "$out" | grep -q 'rc=0 mihomo=1/1 singbox=0/0' && ok "sing-box→mihomo: 目标 active+enabled, 旧核 inactive+disabled" || bad "A: $out"
echo "$out" | grep -q 'reboot_kernels=1 mihomo_after=1 singbox_after=0' && ok "重启只起 mihomo 一个内核(旧核已 disable)" || bad "B: $out"

# 反向 mihomo→sing-box 同样
out=$(run '
  ENABLED[mihomo]=1; ACTIVE[mihomo]=1
  _core_kernel_activate sing-box mihomo; rc=$?
  echo "rc=$rc"; reboot_sim; echo "reboot_kernels=$(kernels_active) singbox=${ACTIVE[sing-box]:-0} mihomo=${ACTIVE[mihomo]:-0}"
')
echo "$out" | grep -q 'rc=0' && echo "$out" | grep -q 'reboot_kernels=1 singbox=1 mihomo=0' \
  && ok "mihomo→sing-box: 反向亦只起 sing-box 一个内核" || bad "反向: $out"

# ── C. 目标核 enable 失败 → activate 返回非 0; restore 恢复旧核 ────────────────
out=$(run '
  ENABLED[sing-box]=1; ACTIVE[sing-box]=1; FAIL_ENABLE=mihomo
  _core_kernel_activate mihomo sing-box; rc=$?
  echo "activate_rc=$rc"
  _core_kernel_restore mihomo sing-box
  echo "after_restore mihomo=${ACTIVE[mihomo]:-0}/${ENABLED[mihomo]:-0} singbox=${ACTIVE[sing-box]:-0}/${ENABLED[sing-box]:-0}"
  reboot_sim; echo "reboot_kernels=$(kernels_active) singbox=${ACTIVE[sing-box]:-0}"
')
echo "$out" | grep -q 'activate_rc=1' && ok "目标核 enable 失败 → activate 返回失败(不误判成功)" || bad "C1: $out"
echo "$out" | grep -q 'after_restore mihomo=0/0 singbox=1/1' && ok "restore: 旧核 enable+start 回来, 目标核 disable" || bad "C2: $out"
echo "$out" | grep -q 'reboot_kernels=1 singbox=1' && ok "失败回滚后重启仍只起旧核 sing-box" || bad "C3: $out"

# ── D. 旧核 disable 没生效(仍 enabled)→ activate 必须判失败(拦潜在双起) ──────
out=$(run '
  ENABLED[sing-box]=1; ACTIVE[sing-box]=1; NODISABLE=sing-box
  _core_kernel_activate mihomo sing-box; rc=$?
  echo "activate_rc=$rc singbox_enabled=${ENABLED[sing-box]:-0}"
')
echo "$out" | grep -q 'activate_rc=1' && echo "$out" | grep -q 'singbox_enabled=1' \
  && ok "旧核仍 enabled → activate 判失败(不放过 reboot 双起隐患)" || bad "D: $out"

# ── E. unit 单一事实源: mihomo 含 SAFE_PATHS + 切核/装机同一函数(无漂移) ──────
# shellcheck source=/dev/null
source "$ROOT/lib/units.sh"
pdg_unit_mihomo | grep -q 'Environment=SAFE_PATHS=/etc/sing-box/ui/dist' && ok "mihomo unit 含 SAFE_PATHS(切核不再漏)" || bad "mihomo unit 缺 SAFE_PATHS"
[[ "$(pdg_unit_mihomo)" == "$(pdg_unit_for_core_svc mihomo)" ]] && ok "pdg_unit_for_core_svc(mihomo) 与 pdg_unit_mihomo 同源" || bad "unit 生成不一致"
# install.sh 与 switch-core 都调 pdg_write_unit pdg_unit_mihomo → 内容必然一致(同函数)
grep -q 'pdg_write_unit pdg_unit_mihomo' "$ROOT/install.sh" && grep -q 'pdg_write_unit pdg_unit_mihomo' "$ROOT/deploy/bot/pdg.sh" \
  && ok "install.sh 与 switch-core 均用 pdg_write_unit pdg_unit_mihomo(无手写漂移)" || bad "两处未统一到 units.sh"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
