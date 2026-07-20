#!/bin/bash
# certbot --standalone pre-hook: 腾出 80 口 + 放行防火墙, 让 ACME HTTP-01 能验证。
# sing-box 模式: sing-box 占着 0.0.0.0:80, 必须先停它, 否则 certbot 绑不上 80。
# mihomo 模式: 80 口本就无人监听(nft 把内网来源 80 REDIRECT 到 7893, 外部 80 default-drop),
#   certbot 可直接绑, 无需停代理 —— 续期期间保持在线。
set -e
CORE=$(cat /etc/privdns-gateway/backend 2>/dev/null || echo singbox)
[[ "$CORE" == singbox ]] && { systemctl stop sing-box 2>/dev/null || true; }
# 兼容两种表名: 新版独立表 inet pdg; 旧装(尚未迁移)仍是 inet filter。
if command -v nft >/dev/null 2>&1 && nft list table inet pdg >/dev/null 2>&1; then
    nft insert rule inet pdg input tcp dport 80 accept 2>/dev/null || true
elif command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    nft insert rule inet filter input tcp dport 80 accept 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
fi
