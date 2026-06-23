#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 回归测试: pdg.sh 的 _mosdns_add_concurrent —— 旧 mosdns 配置补 concurrent 的迁移逻辑。
#   • 多上游(≥2)缺 concurrent → 补 concurrent: 2(真故障转移)
#   • 单上游缺 concurrent     → 补 concurrent: 1(否则同一台被并发查两次)
#   • 已有 concurrent          → 不动(幂等)
#   • 上游列表/顺序            → 原样保留
# 纯文本, 不需 mosdns/root, 可在 CI 跑。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

eval "$(sed -n '/^_mosdns_add_concurrent(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
ko(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# 多上游缺 concurrent → 2
printf '    args: { upstreams: [ {addr: "https://1.1.1.1/dns-query"}, {addr: "udp://8.8.8.8:53"} ] }\n' > "$WORK/multi"
out="$(_mosdns_add_concurrent "$WORK/multi")"
grep -qF 'args: { concurrent: 2, upstreams: [ {addr: "https://1.1.1.1/dns-query"}, {addr: "udp://8.8.8.8:53"} ] }' <<<"$out" \
  && ok "多上游 → concurrent: 2" || ko "多上游应补 2: $out"

# 单上游缺 concurrent → 1
printf '    args: { upstreams: [ {addr: "udp://9.9.9.9:53"} ] }\n' > "$WORK/single"
out="$(_mosdns_add_concurrent "$WORK/single")"
grep -qF 'args: { concurrent: 1, upstreams: [ {addr: "udp://9.9.9.9:53"} ] }' <<<"$out" \
  && ok "单上游 → concurrent: 1(不重复查两次)" || ko "单上游应补 1: $out"

# 已有 concurrent → 不动(幂等)
printf '    args: { concurrent: 2, upstreams: [ {addr: "udp://1.1.1.1:53"}, {addr: "udp://8.8.8.8:53"} ] }\n' > "$WORK/has"
out="$(_mosdns_add_concurrent "$WORK/has")"
[[ "$out" == "$(cat "$WORK/has")" ]] && ok "已有 concurrent → 不动" || ko "不应改: $out"

# 跑两次 = 跑一次(幂等)
once="$(_mosdns_add_concurrent "$WORK/multi")"; printf '%s\n' "$once" > "$WORK/once"
twice="$(_mosdns_add_concurrent "$WORK/once")"
[[ "$twice" == "$once" ]] && ok "二次运行幂等" || ko "二次不幂等: $twice"

# 上游内容/顺序保留
grep -qF '{addr: "https://1.1.1.1/dns-query"}, {addr: "udp://8.8.8.8:53"}' <<<"$once" \
  && ok "上游列表与顺序保留" || ko "上游被改: $once"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" -eq 0 ]] || exit 1
echo "✅ mosdns concurrent 迁移回归全过"
