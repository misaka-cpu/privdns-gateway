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

# 救援放行所在的**独立** nft 表名。python 侧的真源是 rescue_nft.py 的 TABLE(那个模块刻意
# 零依赖 —— 它要在"完整恢复"最脆弱的时刻跑, 不能再去 import 常量解析器), 两处由守卫测试
# 逐字比对。这里之所以也要有一份: 卸载得把这张表从磁盘配置与内核里摘掉。
PDG_RESCUE_TABLE="pdgrescue"

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
etc/systemd/system/pdg-rescue.socket
var/lib/privdns-gateway/rescue-state.json"

# 逐行输出受保护成员(供 bash 侧过滤 tar 成员清单用)
pdg_rescue_protected(){ printf '%s\n' "$PDG_RESCUE_PROTECTED_MEMBERS"; }

# 卸载时拆掉救援平面在盘上的全部形态。$1=根前缀(测试注入, 真实卸载传空), $2=nft 可执行(可空)。
#
# 为什么必须清干净、而且清不掉要**明说**: 卸载完还留着的是一把仍然有效的 token 与 TLS 私钥,
# 外加一条内网放行规则 —— 服务没了、门却还开着一条缝, 比不卸载更糟。所以任何一项删不掉都
# 逐条打印到 stdout 并返回非 0, 由调用方原样报给用户; 绝不吞掉错误假装"已完成"。
#
# 删什么不另列清单, 直接复用 PDG_RESCUE_PROTECTED_MEMBERS —— 那张表的定义就是"救援平面自身
# 由哪些文件构成"(完整恢复时要事前排除的正是它们)。两处共用一份真源, 以后加了新成员, 恢复
# 保护与卸载清理同时跟上, 不会一边记得一边忘。
pdg_rescue_cleanup(){
  local root="${1:-}" nftbin="${2:-}" residue=() m target conf
  conf="$root/etc/nftables.conf"

  # 1) 磁盘配置里我们注入的独立表: 用 rescue_nft.py 靠 BANNER 定界整块摘掉。
  #    **绝不按端口 grep -v 删行** —— 用户完全可能自己写过一条同端口放行, 那是他的规则。
  #    删除动作发生在清运行文件之前, 否则要用的 rescue_nft.py 已经被自己删掉了。
  if [[ -f "$conf" ]] && grep -q "table inet $PDG_RESCUE_TABLE" "$conf" 2>/dev/null; then
    local nftpy=""
    for m in "$root/opt/pdg-bot/rescue_nft.py" "${PDG_RESCUE_REPO:-}/deploy/bot/rescue_nft.py"; do
      [[ "$m" == /deploy/* ]] && continue
      [[ -f "$m" ]] && { nftpy="$m"; break; }
    done
    if [[ -n "$nftpy" ]] && python3 "$nftpy" --strip < "$conf" > "$conf.pdg-un" 2>/dev/null \
       && mv -f "$conf.pdg-un" "$conf"; then :
    else
      rm -f "$conf.pdg-un" 2>/dev/null
      residue+=("$conf 里的 table inet $PDG_RESCUE_TABLE —— 请手工删掉该块后 nft -f 重载")
    fi
  fi

  # 2) 内核里那张表。磁盘清了内核没清的话, 规则此刻仍然生效, 而用户从配置文件上完全看不出
  #    为什么 —— 与 uninstall 处理 inet pdg 是同一个道理。
  [[ -n "$nftbin" ]] || nftbin="$(command -v nft 2>/dev/null || true)"
  if [[ -z "$root" && -n "$nftbin" ]]; then
    "$nftbin" delete table inet "$PDG_RESCUE_TABLE" 2>/dev/null || true   # 本来就没有 → 不算残留
  fi

  # 3) 凭据、状态、unit、运行文件 —— 逐条删并逐条复核
  while read -r m; do
    [[ -n "$m" ]] || continue
    target="$root/$m"
    rm -f "$target" 2>/dev/null
    [[ -e "$target" ]] && residue+=("$target")
  done < <(pdg_rescue_protected)
  rmdir "$root$PDG_RESCUE_DIR" 2>/dev/null || true   # 空了才收走; 用户往里放过别的东西就留着

  if ((${#residue[@]})); then
    printf '%s\n' "${residue[@]}"
    return 1
  fi
  return 0
}

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
