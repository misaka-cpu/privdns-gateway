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

# 两件事, 互补不是替代:
#   ① 按标记逐处删 —— 补重载够不着的地方。`nft -f` 那份配置只定义 inet pdg, 重载它
#      根本不碰 `inet filter`; 于是 pre 落一处、post 重载另一处时, 残骸永远撤不掉。
#   ② 重载磁盘配置 —— post-hook 的本职: 把防火墙恢复到规范状态, 而不只是"删掉我加的那条"。
# 顺序是先删后重载: 重载在最后, 最终状态就是磁盘上的规范状态。
if [[ -n "$NFT" ]]; then
    for tbl in "inet pdg" "inet filter"; do
        # shellcheck disable=SC2086  # tbl 有意按空格拆成 family + name
        while read -r h; do
            [[ -n "$h" ]] && "$NFT" delete rule $tbl input handle "$h" 2>/dev/null || true
        done < <("$NFT" -a list table $tbl 2>/dev/null \
                 | grep "comment \"$MARK\"" | grep -oE 'handle [0-9]+$' | awk '{print $2}')
    done
fi
# iptables 侧**只在这台机器根本没有 nft 时**才清 —— 与 pre-hook 插入分支的门控对称:
# 只在写得进去的地方清。有 nft 却来调 iptables 是有害的: iptables-nft 会顺手**建出**
# `table ip filter`, 而那张表和 inet pdg 挂同一个 input hook, 它的存在本身就是 doctor
# 判红「防火墙链冲突」的来源 —— 清理动作反而制造出要清理的东西。
if [[ -z "$NFT" ]] && ! command -v nft >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
    # 次数封顶, 理由同 pre-hook: 退出条件由外部命令决定, 恒返回 0 的实现会让它死循环。
    i=0
    while [ "$i" -lt 32 ] \
          && iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do
        i=$((i + 1))
    done
fi

# ② 重载: 把 inet pdg 恢复成磁盘上的样子。失败不致命(标记规则上面已经删干净了),
# 但要出声 —— 静默跳过等于防火墙停在一个没人声明过的状态。
if [[ -n "$NFT" ]]; then
    "$NFT" -f /etc/nftables.conf 2>/dev/null \
        || echo "post-hook: 重载 /etc/nftables.conf 失败, 防火墙可能未回到规范状态" >&2
fi

CORE=$(cat /etc/privdns-gateway/backend 2>/dev/null || echo singbox)
[[ "$CORE" == singbox ]] && { systemctl start sing-box 2>/dev/null || true; }
# mihomo 模式: 全程没停 mihomo, 无需启动
exit 0
