#!/bin/bash
# certbot --standalone post-hook: 还原防火墙 + (sing-box 模式)把 80 口还给 sing-box。
set -e

# nft 位置同 pre-hook, 走共用判据(lib/nftbin.sh)。
NFT=""
if [[ -f /opt/privdns-gateway/lib/nftbin.sh ]]; then
    # shellcheck source=../../lib/nftbin.sh
    . /opt/privdns-gateway/lib/nftbin.sh && NFT="$(pdg_nft_bin || true)"
fi
[[ -n "$NFT" ]] || NFT="$(command -v nft 2>/dev/null || true)"

MARK='pdg-cert-http'

# 清理必须**覆盖全部三处且幂等**, 不依赖"当初加在哪"这个记忆。
# 原因: 两个钩子各算各的 —— 以前 post 的 nft 分支只做 `nft -f /etc/nftables.conf`,
# 而那份配置只定义 inet pdg, 重载它根本不碰 ip filter。于是 pre 落 iptables、post 走 nft 时,
# 残骸永远撤不掉。按标记逐处删就没有这个缝。
if [[ -n "$NFT" ]]; then
    for tbl in "inet pdg" "inet filter"; do
        # shellcheck disable=SC2086  # tbl 有意按空格拆成 family + name
        while read -r h; do
            [[ -n "$h" ]] && "$NFT" delete rule $tbl input handle "$h" 2>/dev/null || true
        done < <("$NFT" -a list table $tbl 2>/dev/null \
                 | grep "comment \"$MARK\"" | grep -oE 'handle [0-9]+$' | awk '{print $2}')
    done
fi
if command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do :; done
fi

CORE=$(cat /etc/privdns-gateway/backend 2>/dev/null || echo singbox)
[[ "$CORE" == singbox ]] && { systemctl start sing-box 2>/dev/null || true; }
# mihomo 模式: 全程没停 mihomo, 无需启动
exit 0
