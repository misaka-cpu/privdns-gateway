#!/bin/bash
# certbot --standalone post-hook: 还原防火墙 + (sing-box 模式)把 80 口还给 sing-box。
set -e
if command -v nft >/dev/null 2>&1 && [[ -f /etc/nftables.conf ]]; then
    nft -f /etc/nftables.conf 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do :; done
fi
CORE=$(cat /etc/privdns-gateway/backend 2>/dev/null || echo singbox)
[[ "$CORE" == singbox ]] && { systemctl start sing-box 2>/dev/null || true; }
# mihomo 模式: 全程没停 mihomo, 无需启动
exit 0
