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
    # iptables 侧**只在这台机器根本没有 nft 时**才清 —— 与下面插入分支的门控对称:
    # 只在写得进去的地方清。有 nft 却来调 iptables 是有害的: iptables-nft 会顺手
    # **建出** `table ip filter`, 而那张表和 inet pdg 挂同一个 input hook, 它的存在
    # 本身就是 doctor 判红「防火墙链冲突」的来源 —— 清理动作反而制造出要清理的东西。
    # 门看的是 **$NFT 解析结果**, 不是 `command -v nft` —— 这正是本文件反复强调的那条:
    # 本脚本由 certbot 的 timer/cron 拉起, PATH 里未必有 /usr/sbin, 只看 PATH 会把一台
    # 有 nft 的机器误判成没有。$NFT 非空 = nft 侧已处理完, 直接收工。
    [[ -n "$NFT" ]] && return 0
    # $NFT 为空但 PATH 上有 nft: 说明 lib/nftbin.sh 缺失或坏了。插入分支在这种情况下
    # 是响亮失败, 清理这边同样不许碰 iptables。
    command -v nft >/dev/null 2>&1 && return 0
    if command -v iptables >/dev/null 2>&1; then
        # 次数封顶: 退出条件是"iptables -D 终于返回非零", 而这个前提由外部命令决定。
        # 碰上恒返回 0 的实现(测试桩、某些包装器)就是死循环 —— 这段跑在 certbot 的
        # systemd timer 里, 挂住的是续期本身, 比它要修的缺陷更糟。上限取 32:
        # 真实残骸是"每次认证失败积一条", 到不了这个量级。
        local i=0
        while [ "$i" -lt 32 ] \
              && iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do
            i=$((i + 1))
        done
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
