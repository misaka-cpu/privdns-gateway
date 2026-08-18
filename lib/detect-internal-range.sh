#!/usr/bin/env bash
# 自动识别「内网卡来源段」: 抓"手机经内网卡打到本机网关服务"的包, 看私有源网段, 推断成 /16。
# 覆盖 10/8、172.16-31、192.168、以及运营商常用的 CGNAT 100.64.0.0/10。
# 用法: detect-internal-range.sh [抓包秒数] [本机公网IP(仅用于提示)]
# 成功: stdout 打印 CIDR (如 172.22.0.0/16) 并 exit 0; 失败: 空输出 exit 1。
set -uo pipefail
DUR="${1:-90}"
SERVER_IP="${2:-本机公网IP}"

command -v tcpdump >/dev/null 2>&1 || { echo ""; exit 1; }

cat >&2 <<EOF
──────────────────────────────────────────────
 正在抓包识别内网卡网段, 最多 ${DUR} 秒(抓到就提前结束)。
 让手机产生一点到本机的流量即可:
   • 已在用网关(私密 DNS 已生效)→ 它本来就在发 DoT, 通常立刻抓到, 你什么都不用做。
   • 还没用上 → 手机【走内网卡/蜂窝, 关 WiFi】打开 http://${SERVER_IP} 或 ping 它。
 注意:http 打不开是正常的(本机此时未必有 web 服务), 只要"包发出去"就行。
 抓不到的常见原因:① 手机没真走内网卡(WiFi 没关); ② 云安全组没放行入站 80 / ICMP。
EOF
# 调用方支持"抓包与手输并行"时才提示可以现在就输(否则这句是空头支票)
[[ -n "${PDG_DETECT_TYPEAHEAD:-}" ]] && cat >&2 <<EOF
 ★ 已经知道网段? 现在就能直接输入(如 172.22.0.0/16)并回车 —— 不必等抓包结束。
EOF
cat >&2 <<EOF
──────────────────────────────────────────────
EOF

# Tailscale 的节点地址同样落在 100.64.0.0/10 —— 和运营商 CGNAT 用的是同一个段, 只看源地址
# 分不开。若把 tailnet 的样本当成内网卡来源推成 /16 写进 PDG_INTERNAL_CIDR, nft 的 REDIRECT
# 就会改挂到 tailnet 上, 管理流量被送进透明代理。所以这里按**入口接口**排除, 不按地址段
# (按段排除会连真实运营商 CGNAT 一起误伤)。
#
# `tcpdump -i any` 从 4.99 起把接口名打在第二个字段。老版本不打 —— 那种情况下我们**拿不到
# 入口接口这个事实**, 于是无从排除。此时:
#   · 机器上没有 tailscale0 → 与本改动前完全等价, 照常抓(不因装没装 Tailscale 改变行为);
#   · 机器上有 tailscale0   → 宁可不猜: 直接失败并让调用方走手输, 而不是冒险选到 tailnet。
TS_IF="tailscale0"
have_ts=0; ip -o link show "$TS_IF" >/dev/null 2>&1 && have_ts=1
ifname_ok=0
if timeout 3 tcpdump -ni any -c 1 2>/dev/null | grep -qE '^[0-9:.]+ +[A-Za-z][A-Za-z0-9_.:-]* +(In|Out|P|M|B) '; then
  ifname_ok=1
fi
if [[ "$have_ts" == 1 && "$ifname_ok" == 0 ]]; then
  cat >&2 <<EOF
 ⚠️  本机存在 $TS_IF, 但这台的 tcpdump 不在 -i any 的输出里给接口名 ——
     无法把 tailnet 的样本从候选里排除。为避免把 tailnet 地址误认成内网卡来源,
     这里**不猜**。请直接手输内网卡网段(如 172.22.0.0/16), 或用 PDG_INTERNAL_CIDR 指定。
EOF
  echo ""; exit 1
fi

# 抓"打到网关服务端口(53/80/443/853)或 ICMP"且源/目的在私网/CGNAT 段的包; 不限 SYN, 已建连的 DoT 也能抓到
src=$(timeout "$DUR" tcpdump -ni any -c 60 \
        '((tcp port 53 or tcp port 80 or tcp port 443 or tcp port 853) or icmp or udp port 53 or udp port 443)
         and (net 10.0.0.0/8 or net 172.16.0.0/12 or net 192.168.0.0/16 or net 100.64.0.0/10)' \
        2>/dev/null \
      | awk -v ts="$TS_IF" '$2 != ts' \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | awk -F. '($1==10)||($1==172&&$2>=16&&$2<=31)||($1==192&&$2==168)||($1==100&&$2>=64&&$2<=127)' \
      | grep -vE '\.(255|0)$' \
      | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')

[[ -z "$src" ]] && { echo ""; exit 1; }
# 取前两段当 /16 (内网卡通常是一个 /16 或更大的运营商私网段)
echo "$src" | awk -F. '{print $1"."$2".0.0/16"}'
