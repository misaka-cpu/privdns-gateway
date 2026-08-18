#!/bin/bash
# certbot --standalone pre-hook: 腾出 80 口 + 放行防火墙, 让 ACME HTTP-01 能验证。
# sing-box 模式: sing-box 占着 0.0.0.0:80, 必须先停它, 否则 certbot 绑不上 80。
# mihomo 模式: 80 口本就无人监听(nft 把内网来源 80 REDIRECT 到 7893, 外部 80 default-drop),
#   certbot 可直接绑, 无需停代理 —— 续期期间保持在线。
set -e

# nft 的位置走共用判据(lib/nftbin.sh): 本脚本由 certbot(systemd timer / cron)拉起, 那套
# PATH 里未必有 /usr/sbin —— 只看 PATH 会当成"没装 nft"。
NFT=""
if [[ -f /opt/privdns-gateway/lib/nftbin.sh ]]; then
    # shellcheck source=../../lib/nftbin.sh
    . /opt/privdns-gateway/lib/nftbin.sh && NFT="$(pdg_nft_bin || true)"
fi
[[ -n "$NFT" ]] || NFT="$(command -v nft 2>/dev/null || true)"

MARK='pdg-cert-http'

# 进场先清一遍残骸: certbot 认证失败时以非零退出, post-hook **未必执行** —— jp 上就是这样,
# 每失败一次就多积一条 80 放行, 积到两条时 doctor 判红、升级整次回滚。
# 所以清理不能只挂在 post-hook 上, 这里也要兜一次; 两边都必须幂等。
_purge_cert_http() {
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
}
_purge_cert_http

CORE=$(cat /etc/privdns-gateway/backend 2>/dev/null || echo singbox)
[[ "$CORE" == singbox ]] && { systemctl stop sing-box 2>/dev/null || true; }

# 放行加在哪里, 取决于这台机器用的是哪张表。带标记插入, 撤销才能精确定位 ——
# 绝不按端口删: 用户完全可能自己写过一条同端口放行。
if [[ -n "$NFT" ]] && "$NFT" list table inet pdg >/dev/null 2>&1; then
    "$NFT" insert rule inet pdg input tcp dport 80 accept comment "$MARK" 2>/dev/null || true
elif [[ -n "$NFT" ]] && "$NFT" list table inet filter >/dev/null 2>&1; then
    "$NFT" insert rule inet filter input tcp dport 80 accept comment "$MARK" 2>/dev/null || true
elif [[ -z "$NFT" ]] && command -v nft >/dev/null 2>&1; then
    # 有 nft 却解析不到路径, 说明 lib/nftbin.sh 缺失或坏了。这时**绝不能**落到 iptables:
    # iptables-nft 会建出 `table ip filter`, 而它和 inet pdg 挂同一个 input hook,
    # PDG 那条是 policy drop —— 加进去的放行从一开始就被架空(实测 packets 0),
    # 认证必然失败, 还留下越积越多的残骸。响亮地失败比悄悄留个没用的规则强。
    echo "pre-hook: 找不到可用的 nft(lib/nftbin.sh 缺失?), 拒绝改用 iptables —— " \
         "那会在 inet pdg 同 hook 上建一张被架空的表。请修好 nft 路径后重试。" >&2
    exit 1
elif command -v iptables >/dev/null 2>&1; then
    # 这台机器根本没有 nft(纯 iptables 环境), 此时 iptables 分支是唯一且正确的选择。
    iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
fi
