#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# GMS 推送端口迁移回归: 校验 pdg.sh 的 migrate_fw_gms ——
# 「原装应补 5228-5230、自定义/非本项目形态应跳过、幂等、失败回滚」。
# (v1.6.0: mihomo 靠 nft 把 5228-5230 REDIRECT 进 redir 端口再嗅 SNI 分流; sing-box 侧的
#  model 入站迁移 migrate_singbox_gms 已随 sing-box 运行时一并退役。)
# 纯 bash + python3, nft/systemctl 用函数打桩, 可在 CI 跑。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 抽出被测函数; 外部命令与输出函数打桩
eval "$(sed -n '/^migrate_fw_gms(){/,/^}/p' "$(bash "$ROOT/tests/pdg-source-lib.sh" path "$ROOT")")"
c_g(){ :; }; c_y(){ :; }
NFT_RC=0; SB_RC=0; SVC_STATE=active
nft(){ return "$NFT_RC"; }
sing-box(){ return "$SB_RC"; }
systemctl(){ [[ "$1" == is-active ]] && echo "$SVC_STATE"; return 0; }

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# ── 防火墙: 原装(inet pdg, 现行端口集) → 应补 5228-5230, 且幂等 ──
cat > "$WORK/fw" <<'EOF'
table inet pdg
delete table inet pdg
table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 22 } accept
        ip saddr 172.22.0.0/16 tcp dport { 53, 80, 81, 443, 853, 8445 } accept
        ip saddr 172.22.0.0/16 udp dport { 53 } accept
        ip saddr 172.22.0.0/16 udp dport 443 reject
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
}
EOF
migrate_fw_gms "$WORK/fw"
if grep -q 'tcp dport { 53, 80, 81, 443, 853, 5228-5230, 8445 } accept' "$WORK/fw"; then
  ok "fw 原装 → 补 5228-5230"
else bad "fw 原装未补上 5228-5230"; fi
snap="$(cat "$WORK/fw")"
migrate_fw_gms "$WORK/fw"
[[ "$(cat "$WORK/fw")" == "$snap" ]] && ok "fw 幂等(二跑不变)" || bad "fw 二跑改动了文件"
grep -q 'udp dport 443 reject' "$WORK/fw" && ok "fw 其余行未被波及" || bad "fw 其它行被改动"

# ── 防火墙: 自定义端口集 → 跳过不动 ──
sed 's/{ 53, 80, 81, 443, 853, 5228-5230, 8445 }/{ 53, 443, 9999 }/' "$WORK/fw" > "$WORK/fw2"
snap="$(cat "$WORK/fw2")"
migrate_fw_gms "$WORK/fw2"
[[ "$(cat "$WORK/fw2")" == "$snap" ]] && ok "fw 自定义端口集 → 跳过" || bad "fw 自定义端口集被改动!"

# ── 防火墙: 还没迁到 inet pdg(老 inet filter)→ 跳过 ──
sed 's/inet pdg/inet filter/g; s/, 5228-5230,/,/' "$WORK/fw" > "$WORK/fw3"
snap="$(cat "$WORK/fw3")"
migrate_fw_gms "$WORK/fw3"
[[ "$(cat "$WORK/fw3")" == "$snap" ]] && ok "fw 未迁 inet pdg → 跳过" || bad "fw inet filter 被改动!"

# ── 防火墙: nft -c 失败 → 还原 ──
sed 's/{ 53, 80, 81, 443, 853, 5228-5230, 8445 }/{ 53, 80, 81, 443, 853, 8445 }/' "$WORK/fw" > "$WORK/fw4"
snap="$(cat "$WORK/fw4")"
NFT_RC=1; migrate_fw_gms "$WORK/fw4"; NFT_RC=0
[[ "$(cat "$WORK/fw4")" == "$snap" ]] && ok "fw nft 校验失败 → 还原" || bad "fw 校验失败未还原!"


echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
