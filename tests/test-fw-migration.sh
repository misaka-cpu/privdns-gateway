#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 防火墙迁移识别回归测试: 校验 pdg.sh 的 _fw_is_stock —— "原装应迁移、自定义应跳过"。
#
# 为什么需要它: 迁移=用标准模板重建, 只保留 SSH端口+内网段; 若把含自定义规则的旧配置
# 误判为"原装", 重建会静默丢掉用户的端口/规则/额外表。历史上的原装模板在排版(forward/
# output 单行 vs 多行)和端口集(不同年代 {53,80,81,443} → +853 → +8445)上都有差异 ——
# 任一变体被误判为"自定义"就会导致老机器永远不自动迁移。本测试覆盖全部已知变体。
#
# 纯 bash, 无需 root / nft, 可在 CI 跑。退出码 0=全过, 非 0=有用例失败。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 抽出被测函数(避免 source 整个 pdg.sh 触发它底部的命令分发)
eval "$(sed -n '/^_fw_is_stock(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"

# 生成一份"原装"防火墙: $1端口 $2内网段 $3端口集 $4是否有reject(1/0) $5排版(single|multi)
gen_stock(){
  local port="$1" cidr="$2" set="$3" rej="$4" style="$5"
  printf '#!/usr/sbin/nft -f\n# PrivDNS Gateway 防火墙 (inet filter, policy drop)\nflush ruleset\n\n'
  printf 'table inet filter {\n    chain input {\n'
  printf '        type filter hook input priority 0; policy drop;\n'
  printf '        iif "lo" accept\n'
  printf '        ct state established,related accept\n'
  printf '        tcp dport { %s } accept\n' "$port"
  printf '        ip saddr %s tcp dport { %s } accept\n' "$cidr" "$set"
  printf '        ip saddr %s udp dport { 53 } accept\n' "$cidr"
  [[ "$rej" == 1 ]] && printf '        ip saddr %s udp dport 443 reject   # QUIC/HTTP3 拒掉\n' "$cidr"
  printf '        ip protocol icmp accept\n        ip6 nexthdr icmpv6 accept\n    }\n'
  if [[ "$style" == single ]]; then
    printf '    chain forward { type filter hook forward priority 0; policy accept; }\n'
    printf '    chain output  { type filter hook output  priority 0; policy accept; }\n'
  else
    printf '    chain forward {\n        type filter hook forward priority 0; policy accept;\n    }\n'
    printf '    chain output {\n        type filter hook output priority 0; policy accept;\n    }\n'
  fi
  printf '}\n'
}

pass=0; nfail=0
assert_stock(){  # f port cidr name
  if _fw_is_stock "$1" "$2" "$3"; then echo "[OK]   原装→迁移: $4"; pass=$((pass+1))
  else echo "[FAIL] 应判原装却被当自定义(老机器将永不迁移): $4"; nfail=$((nfail+1)); fi
}
assert_custom(){
  if _fw_is_stock "$1" "$2" "$3"; then echo "[FAIL] 应判自定义却被当原装(重建会静默丢规则!): $4"; nfail=$((nfail+1))
  else echo "[OK]   自定义→跳过: $4"; pass=$((pass+1)); fi
}

# ── 原装变体(都应判"原装", 可安全迁移)──
gen_stock 22 172.22.0.0/16 "53, 80, 81, 443, 853, 8445" 1 single > "$WORK/a"; assert_stock "$WORK/a" 22 172.22.0.0/16 "单行 forward/output + 全端口集(8107b7f, 曾被误判)"
gen_stock 22 172.22.0.0/16 "53, 80, 81, 443, 853"       1 multi  > "$WORK/b"; assert_stock "$WORK/b" 22 172.22.0.0/16 "多行 forward/output + {..853}"
gen_stock 22 172.22.0.0/16 "53, 80, 81, 443"            0 multi  > "$WORK/c"; assert_stock "$WORK/c" 22 172.22.0.0/16 "最早期: 多行 + {53,80,81,443} + 无 reject 行"
gen_stock 2222 10.0.0.0/8  "53, 80, 81, 443, 853"       1 single > "$WORK/d"; assert_stock "$WORK/d" 2222 10.0.0.0/8 "自定义 SSH端口/内网段但形态原装"

# ── 自定义(都应判"非原装", 必须跳过)──
gen_stock 22 172.22.0.0/16 "53, 80, 81, 443, 853, 8445" 1 single > "$WORK/e"
sed -i 's#\(ip protocol icmp accept\)#tcp dport { 8080 } accept\n        \1#' "$WORK/e"   # 多开一个全网端口
assert_custom "$WORK/e" 22 172.22.0.0/16 "额外开放 8080 端口(全网)"

gen_stock 22 172.22.0.0/16 "53, 80, 81, 443, 853" 1 single > "$WORK/f"
printf '\ntable ip nat {\n    chain post {\n        type nat hook postrouting priority 100;\n        masquerade\n    }\n}\n' >> "$WORK/f"
assert_custom "$WORK/f" 22 172.22.0.0/16 "额外 table ip nat + masquerade"

gen_stock 22 172.22.0.0/16 "53, 80, 81, 443, 853" 1 single > "$WORK/g"
sed -i 's#\(ip protocol icmp accept\)#ip saddr 203.0.113.5 tcp dport 853 accept\n        \1#' "$WORK/g"
assert_custom "$WORK/g" 22 172.22.0.0/16 "放行额外来源 IP(203.0.113.5)"

gen_stock 22 172.22.0.0/16 "53, 80, 81, 443, 853" 1 single > "$WORK/h"
sed -i 's#\(ip protocol icmp accept\)#tcp dport 443 accept\n        \1#' "$WORK/h"
assert_custom "$WORK/h" 22 172.22.0.0/16 "把 443 对全网开放(无 saddr, 非 SSH 端口)"

gen_stock 22 172.22.0.0/16 "53, 80, 81, 443, 853" 1 multi > "$WORK/i"
sed -i 's#\(        type filter hook forward priority 0; policy accept;\)#\1\n        ip daddr 10.1.2.3 accept#' "$WORK/i"
assert_custom "$WORK/i" 22 172.22.0.0/16 "forward 链加 daddr 转发规则"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" -eq 0 ]] || exit 1
echo "✅ 防火墙迁移识别回归测试全过"
