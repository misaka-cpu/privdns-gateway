#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # 本文件供 source, 常量在 install.sh / pdg / 测试里用(同 lib/versions.sh)
# ─────────────────────────────────────────────────────────────────────────────
# 独立救援平面(5.2)的常量单一事实源。
#
# 为什么要有这个文件: 救援端口要同时出现在 nftables 模板、systemd socket、doctor 的端口
# 文案与敏感端口集、老机器迁移、以及文档里。这几处各写一遍字面量的下场是可预见的 ——
# 改端口时漏掉一处, 于是防火墙放行了 A、服务监听在 B, 页面打不开, 而 doctor 还报"一切正常"
# (它检查的是自己那份硬编码)。所以: **端口与路径只在这里定义一次**, 其余全部读它或由它渲染,
# 并有一条守卫测试盯着"除本文件外不许出现字面量端口号"。
#
# 用法(bash 侧): source lib/rescue.sh; echo "$PDG_RESCUE_PORT"
# 用法(python 侧): rescue_const.py 从**同一个文件**解析, 不在 python 里另写一份。
# ─────────────────────────────────────────────────────────────────────────────

# 监听端口。选 8446 的依据(2026-07 全仓扫描):
#   已占用 53(mosdns) 81(probe81/iOS) 853(DoT) 7893(mihomo redir) 7894(pdg-mitm)
#           8445(TG SOCKS5) 9090(clash_api) 以及被 prerouting 改写的 80/443/5228-5230;
#   80/443 **不可用** —— 内网来源在 nat prerouting 就被 REDIRECT 到 7893, mihomo 一挂就是死路;
#   8446 紧邻 8445, 语义连贯, 且全仓与测试端口池均无冲突。
PDG_RESCUE_PORT="${PDG_RESCUE_PORT:-8446}"

# 凭据与状态。凭据目录 700, 证书 644(要给用户比对指纹), 私钥与 token 600。
PDG_RESCUE_DIR="${PDG_RESCUE_DIR:-/etc/privdns-gateway/rescue}"
PDG_RESCUE_CERT="${PDG_RESCUE_CERT:-$PDG_RESCUE_DIR/cert.pem}"
PDG_RESCUE_KEY="${PDG_RESCUE_KEY:-$PDG_RESCUE_DIR/key.pem}"
PDG_RESCUE_TOKEN="${PDG_RESCUE_TOKEN:-$PDG_RESCUE_DIR/token}"
# 救援自身的运行状态(紧急默认出口的原值等)。放 /var/lib 而不是 /etc: 它是运行态, 不是配置。
PDG_RESCUE_STATE="${PDG_RESCUE_STATE:-/var/lib/privdns-gateway/rescue-state.json}"

# unit 名(socket activation: socket 常驻, service 按需拉起)
PDG_RESCUE_SOCKET_UNIT="pdg-rescue.socket"
PDG_RESCUE_SERVICE_UNIT="pdg-rescue.service"

# 内网卡来源段的**唯一真源**(5.2/T7)。nft、mosdns、救援绑定、doctor 全部读它或由它渲染。
# 老机器在迁移写入之前可能没有这个键 —— 调用方必须处理"读不到"的情况, 不许猜。
PDG_PROFILE_ENV="${PDG_PROFILE_ENV:-/etc/privdns-gateway/profile.env}"
PDG_CIDR_KEY="PDG_INTERNAL_CIDR"

# 救援平面的**固定**受保护成员(相对快照根的路径)。完整恢复时这些一律**事前排除** ——
# 不是"先覆盖再补回来": 补回来的那一瞬之前, 盘上已经是旧凭据/旧代码了, 而恢复正是用户最怕
# 失联的时刻。清单只含救援平面自身: 普通 Bot 代码、bot.env、mihomo/mosdns、platform/backend、
# WLOC 都**不在**其中(它们本来就该被完整恢复换掉)。
# 这份清单不接受 HTTP、快照 manifest、环境变量或命令行的任何扩展 —— 谁都不能往里加一项,
# 否则"完整恢复"就能被人指定成"什么都不恢复"。
PDG_RESCUE_PROTECTED_MEMBERS="etc/privdns-gateway/rescue/token
etc/privdns-gateway/rescue/cert.pem
etc/privdns-gateway/rescue/key.pem
opt/pdg-bot/rescue.py
opt/pdg-bot/rescue_const.py
opt/pdg-bot/rescue_cred.py
opt/pdg-bot/breakglass.py
opt/pdg-bot/rescue_nft.py
opt/pdg-bot/rescue.sh
etc/systemd/system/pdg-rescue.service
etc/systemd/system/pdg-rescue.socket"

# 逐行输出受保护成员(供 bash 侧过滤 tar 成员清单用)
pdg_rescue_protected(){ printf '%s\n' "$PDG_RESCUE_PROTECTED_MEMBERS"; }

# profile.env 里读一个键。读不到 → 返回 1 且不打印(调用方据此判断"没有", 而不是拿到空串当成"有")。
pdg_profile_get(){
  local k="$1" f="${2:-$PDG_PROFILE_ENV}" v
  [[ -f "$f" ]] || return 1
  v="$(sed -n "s/^[[:space:]]*${k}=//p" "$f" | tail -1)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# 内网卡来源段(唯一真源)。读不到返回 1 —— 绝不回落成 0.0.0.0/0 之类的"宽松默认":
# 救援服务拿它决定监听地址, 猜错就是把恢复入口暴露到公网。
pdg_internal_cidr(){ pdg_profile_get "$PDG_CIDR_KEY" "$@"; }
