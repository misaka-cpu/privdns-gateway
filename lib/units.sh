#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# systemd unit 单一事实源。install.sh(装机)与 pdg 的 sing-box→mihomo 迁移都从这里
# 生成内核 / pdg-mitm 的 unit, 杜绝两处手写漂移 —— 历史坑: 换核时生成的
# mihomo.service 漏了 Environment=SAFE_PATHS, 与装机版不一致。
#
# 各函数把 unit 内容打到 stdout, 由调用方重定向落盘, 例:
#   pdg_unit_mihomo > /etc/systemd/system/mihomo.service
# 或用 pdg_write_unit 一步写入并 chmod 644。
# ─────────────────────────────────────────────────────────────────────────────

pdg_unit_mihomo(){ cat <<'EOF'
[Unit]
Description=mihomo (PrivDNS Gateway core)
After=network-online.target mosdns.service
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml
Environment=SAFE_PATHS=/etc/sing-box/ui/dist
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
}

pdg_unit_pdg_mitm(){ cat <<'EOF'
[Unit]
Description=pdg-mitm (PrivDNS Gateway MITM plugins)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/pdg-bot/mitm_server.py 7894
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
}

# 内网面板(方案 B)的反代。$1 = 是否需要放宽 TLS 套件(1/空)。
#
# 三条不是可选项:
#   ① ExecStartPre 加载出站白名单, 前缀 `+` 表示以 root 跑(主进程是 pdg-lan)。
#      白名单那份是 fail-open 的 —— 加载不上时规则不存在而反代照跑, 于是它必须挡在
#      启动路径上: 加载不了就别起来。这是门三能不能成立的前提, 不是加固。
#   ② CAP_NET_BIND_SERVICE: 反代监听 127.0.0.1:443, 低端口, 而它不是 root。
#      少了这一条的症状是"服务起不来 + permission denied", 看着像文件权限问题。
#   ④ 反代要读的东西全在 /etc/pdg-lan/(750 root:pdg-lan), **不在** /etc/privdns-gateway/。
#      后者是 700 root:root: 里面有 profile.env 与 DNS API 凭据, 不该为了让反代读一份
#      配置就把它开出去。踩过 —— 文件给了 640 root:pdg-lan 仍然 permission denied,
#      因为进不去父目录; 症状显示成"读配置失败", 与真正的原因(目录不可穿越)隔着一层。
#      分开之后"pdg-lan 需要读什么"看一个目录就有答案。
#
#   ③ XDG_DATA_HOME: Caddy 默认把数据写到 $HOME/.local/share, 而系统用户没有可写的
#      HOME —— 不指的话它会在一个谁也想不到的位置建目录, 或者直接起不来。
#      它必须与 ReadWritePaths **同一个目录**: ProtectSystem=strict 之下别处全只读,
#      指到 /var/lib 而只放行 /var/lib/pdg-lan 的话, Caddy 会去写 /var/lib/caddy 然后
#      permission denied —— 症状看着像文件属主不对, 其实是 sandbox 把它挡了。
#
# GODEBUG=tlsrsakex=1 只在**确有面板需要**时才加(面板表里有 legacy_tls)。老设备可能只
# 提供 AES256-GCM-SHA384(RSA 密钥交换), Go 1.22 起默认禁用, 症状是 502 + handshake
# failure —— 看着像证书问题。但这是**全进程**的开关, 不需要就不该开: 给所有上游都放宽
# 密钥交换, 只为了迁就其中一台。
pdg_unit_lan_caddy(){
  local legacy="${1:-}"
  cat <<EOF
[Unit]
Description=pdg-lan (PrivDNS Gateway LAN panel reverse proxy)
After=network-online.target nftables.service
Wants=network-online.target
[Service]
User=pdg-lan
Group=pdg-lan
ExecStartPre=+/usr/sbin/nft -f /etc/nftables-pdg-lan.conf
ExecStart=/usr/local/bin/caddy run --config /etc/pdg-lan/caddy.conf --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/pdg-lan/caddy.conf --adapter caddyfile --force
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/pdg-lan
Environment=XDG_DATA_HOME=/var/lib/pdg-lan${legacy:+
Environment=GODEBUG=tlsrsakex=1}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
}

# 内核 svc 名 → 对应 unit 生成函数(mihomo 为唯一内核; 保留此壳以便将来扩展/调用方不改)。
pdg_unit_for_core_svc(){
  case "$1" in
    mihomo)   pdg_unit_mihomo ;;
    *) return 1 ;;
  esac
}

# 写入 unit 并置 644(幂等)。$1=生成函数名 $2=目标路径。
#
# 必须原子: 先渲染到同目录临时文件, 确认生成函数成功**且产出非空**, 再 mv 落位。
# 旧写法 `"$fn" > "$path"` 会让 shell **先把目标截断**再去解析命令 —— 生成函数不存在
# (跨版本回滚: 旧 updater 调新版 units.sh 里已删除的 pdg_unit_singbox)时, 目标就成了
# 0 字节, 而调用方还可能照报成功。宁可不写, 也不能把现成的 unit 毁掉。
pdg_write_unit(){
  local fn="$1" path="$2" tmp
  command -v "$fn" >/dev/null 2>&1 || {
    echo "pdg_write_unit: 生成函数 $fn 不存在, 拒绝写 $path(保留原文件)" >&2; return 1; }
  tmp="$(mktemp "$(dirname "$path")/.pdg-unit.XXXXXX")" || return 1
  if ! "$fn" > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "pdg_write_unit: $fn 生成失败或产出为空, 拒绝写 $path(保留原文件)" >&2; return 1
  fi
  chmod 644 "$tmp" && mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}
