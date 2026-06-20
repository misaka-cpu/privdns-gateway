#!/bin/bash
# certbot deploy-hook (装到 /etc/letsencrypt/renewal-hooks/deploy/)。
# 续期/签发后把证书拷到 mosdns(853 DoT) 读取的位置并重载 mosdns。
# 选哪张证书: 优先 certbot 注入的 RENEWED_LINEAGE; 否则 /opt/pdg-bot/dot-domain 指定的活动域名; 再否则最近的 live。
set -e
# 活动 DoT 域名优先 (/opt/pdg-bot/dot-domain): 多域名时, 即便续期的是另一张证书,
# 也只把"当前生效域名"的证书部署给 mosdns, 否则旧域名续期会把活动证书覆盖掉 → DoT 不匹配。
DOMAIN_FILE=/opt/pdg-bot/dot-domain
ACTIVE=""
[[ -f "$DOMAIN_FILE" ]] && ACTIVE="$(head -n1 "$DOMAIN_FILE" | tr -d '[:space:]')"
if [[ -n "$ACTIVE" ]] && [[ -d "/etc/letsencrypt/live/$ACTIVE" ]]; then
    LIVE_DIR="/etc/letsencrypt/live/$ACTIVE"
elif [[ -n "${RENEWED_LINEAGE:-}" ]]; then
    LIVE_DIR="$RENEWED_LINEAGE"
else
    LIVE_DIR=$(find /etc/letsencrypt/live -maxdepth 1 -type d ! -path /etc/letsencrypt/live | sort | head -n1)
fi
[[ -z "$LIVE_DIR" ]] && { echo "[!] no LE live dir"; exit 1; }

mkdir -p /etc/dnsdist/certs
cp "$LIVE_DIR/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
cp "$LIVE_DIR/privkey.pem"   /etc/dnsdist/certs/privkey.pem
chown -R _dnsdist:_dnsdist /etc/dnsdist/certs/
chmod 640 /etc/dnsdist/certs/*.pem

# mosdns 现在是 DoT(853) 的实际服务者; dnsdist 已停用(保留则也 reload)。
systemctl is-active --quiet mosdns && systemctl restart mosdns
systemctl is-active --quiet dnsdist && { systemctl reload dnsdist 2>/dev/null || systemctl restart dnsdist; }
exit 0
