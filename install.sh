#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PrivDNS Gateway 一键安装 (Debian 12+ / Ubuntu 22+, 需 root)
#   sudo ./install.sh
# 非交互/自动化: 预置 PDG_* 环境变量 + PDG_NONINTERACTIVE=1 (见 docs/INSTALL.md)。
#   PDG_SERVER_IP PDG_SSH_PORT PDG_INTERNAL_CIDR PDG_BOT_TOKEN PDG_ALLOWED PDG_DOT_DOMAIN
#   PDG_SKIP_CERT=1  跳过 certbot, 生成自签占位证书 (之后用 bot 补正式证书)
# 做什么: 装 mosdns + sing-box(1.12) + 管理 bot + 防火墙 + DoT 证书。
#   自动识别公网IP / 内网卡段; DNS(域名 A 记录) 那步留给你自己做; 落地出口装好后用 bot 加。
# 也支持 curl|bash 直接跑: curl -fsSL <raw>/install.sh | sudo bash  (脚本会自动拉取仓库)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_URL="https://github.com/misaka-cpu/privdns-gateway.git"
MOSDNS_VER="v5.3.4"
SINGBOX_VER="1.12.9"          # 必须 1.12.x —— 1.13 移除了 sniff_override_destination, 本网关会失效
CERT_DIR="/etc/mosdns/certs"
NONINT="${PDG_NONINTERACTIVE:-}"

c_g(){ echo -e "\033[1;32m[*]\033[0m $*"; }
c_y(){ echo -e "\033[1;33m[!]\033[0m $*"; }
die(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行: sudo ./install.sh  (或 curl ... | sudo bash)"
command -v apt-get >/dev/null || die "目前仅支持 Debian/Ubuntu (apt)"
case "$(dpkg --print-architecture)" in
  amd64) MARCH=amd64 ;; arm64) MARCH=arm64 ;; *) die "不支持的架构: $(dpkg --print-architecture)";;
esac

# ── 自举: 若通过 curl|bash 直接运行(不在仓库内), 自动 clone 后从文件重跑 ──
# (从文件重跑能让 read 交互正常: curl|bash 时 stdin 是脚本本身, 故把 stdin 接回 /dev/tty)
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
if [[ ! -f "$SRC/deploy/mosdns/config.yaml" ]]; then
  c_g "未在仓库目录内运行 → 自动拉取 privdns-gateway…"
  command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }
  DEST=/opt/privdns-gateway
  if [[ -d "$DEST/.git" ]]; then git -C "$DEST" pull -q --ff-only || true
  else rm -rf "$DEST"; git clone -q --depth 1 "$REPO_URL" "$DEST"; fi
  # 有可用控制终端就把 stdin 接回它(交互), 否则直接重跑(靠 PDG_* 环境变量非交互)
  if { true < /dev/tty; } 2>/dev/null; then exec bash "$DEST/install.sh" "$@" < /dev/tty
  else exec bash "$DEST/install.sh" "$@"; fi
fi
REPO_DIR="$SRC"

# ── 1. 依赖 ──
c_g "安装依赖…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl tar unzip nftables python3 openssl certbot dnsutils tcpdump jq ca-certificates >/dev/null

# ── 2. mosdns ──
if ! command -v mosdns >/dev/null; then
  c_g "下载 mosdns $MOSDNS_VER ($MARCH)…"
  t=$(mktemp -d)
  curl -fsSL "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-${MARCH}.zip" -o "$t/m.zip"
  (cd "$t" && unzip -q m.zip && install -m755 mosdns /usr/local/bin/mosdns)
  rm -rf "$t"
fi

# ── 3. sing-box 1.12.x ──
if ! sing-box version 2>/dev/null | grep -q "version 1.12"; then
  c_g "下载 sing-box $SINGBOX_VER ($MARCH)…"
  t=$(mktemp -d)
  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${MARCH}.tar.gz" -o "$t/sb.tgz"
  tar -xzf "$t/sb.tgz" -C "$t"
  install -m755 "$t"/sing-box-*/sing-box /usr/local/bin/sing-box
  rm -rf "$t"
fi

# ── 4. 收集参数 (env 预置优先; PDG_NONINTERACTIVE=1 则不交互) ──
echo
SERVER_IP="${PDG_SERVER_IP:-}"
if [[ -z "$SERVER_IP" ]]; then
  DET_IP=$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  if [[ -n "$NONINT" ]]; then SERVER_IP="$DET_IP"; else read -rp "本机公网 IP [${DET_IP}]: " SERVER_IP; SERVER_IP="${SERVER_IP:-$DET_IP}"; fi
fi
[[ -n "$SERVER_IP" ]] || die "公网 IP 不能为空"

SSH_PORT="${PDG_SSH_PORT:-}"
if [[ -z "$SSH_PORT" ]]; then
  DET_SSH=$(ss -lntpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}'); DET_SSH="${DET_SSH:-22}"
  if [[ -n "$NONINT" ]]; then SSH_PORT="$DET_SSH"; else read -rp "SSH 端口 [${DET_SSH}]: " SSH_PORT; SSH_PORT="${SSH_PORT:-$DET_SSH}"; fi
fi

INTERNAL_CIDR="${PDG_INTERNAL_CIDR:-}"
if [[ -z "$INTERNAL_CIDR" ]]; then
  if [[ -n "$NONINT" ]]; then
    INTERNAL_CIDR="172.16.0.0/12"
  else
    echo; c_y "识别【内网卡来源段】(抓包 ~90s, 期间用手机走【内网卡/蜂窝, 关 WiFi】访问本机一次)"
    DET_CIDR=$(bash "$REPO_DIR/lib/detect-internal-range.sh" 90 "$SERVER_IP" || true)
    [[ -n "$DET_CIDR" ]] && c_g "抓到内网卡段: $DET_CIDR" || c_y "没抓到。请手填你内网卡精确的 /16 (如 172.22.0.0/16)。"
    read -rp "内网卡来源段 CIDR [${DET_CIDR:-请手填如 172.22.0.0/16}]: " INTERNAL_CIDR
    INTERNAL_CIDR="${INTERNAL_CIDR:-${DET_CIDR:-}}"
    [[ -n "$INTERNAL_CIDR" ]] || die "必须填内网卡来源段 (形如 172.22.0.0/16)"
  fi
fi

BOT_TOKEN="${PDG_BOT_TOKEN:-}"; ALLOWED_IDS="${PDG_ALLOWED:-}"; DOT_DOMAIN="${PDG_DOT_DOMAIN:-}"
if [[ -z "$NONINT" ]]; then
  echo
  [[ -n "$BOT_TOKEN" ]] || read -rp "Telegram bot token (可留空, 装完用 sudo pdg-set-token 再设): " BOT_TOKEN
  if [[ -n "$BOT_TOKEN" && -z "$ALLOWED_IDS" ]]; then read -rp "你的 Telegram user id (只允许它管理): " ALLOWED_IDS; fi
  [[ -n "$DOT_DOMAIN" ]] || read -rp "DoT 域名 (如 dot.example.com): " DOT_DOMAIN
fi
[[ -n "$DOT_DOMAIN" ]] || die "DoT 域名不能为空 (非交互请用 PDG_DOT_DOMAIN)"
# token / user id 可留空 → 装完先不启 bot, 之后 sudo pdg-set-token 补

# ── 5. 目录 + 静态文件 ──
c_g "铺设文件…"
install -d /etc/mosdns/rules /etc/sing-box/rs /opt/pdg-bot "$CERT_DIR" /etc/letsencrypt/renewal-hooks/deploy /etc/systemd/system/journald.conf.d
install -m755 "$REPO_DIR"/deploy/bot/pdg-bot.py            /opt/pdg-bot/bot.py
install -m755 "$REPO_DIR"/deploy/bot/parse-geosite.py     /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/update-rules.sh      /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/scheduled-update.sh  /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/ios/probe81.py           /opt/pdg-bot/
install -m644 "$REPO_DIR"/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-open-cert-http.sh     /usr/local/bin/
install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-restore-firewall.sh   /usr/local/bin/
install -m755 "$REPO_DIR"/deploy/cert/99-reload-cert.deploy-hook.sh       /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh
install -m755 "$REPO_DIR"/deploy/bot/pdg-set-token.sh                     /usr/local/bin/pdg-set-token
install -m755 "$REPO_DIR"/deploy/bot/pdg.sh                               /usr/local/bin/pdg
# 把仓库放到 /opt/privdns-gateway 供 `pdg update` / `pdg uninstall` 用
if [[ "$REPO_DIR" != "/opt/privdns-gateway" ]]; then
  [[ -d /opt/privdns-gateway/.git ]] || { rm -rf /opt/privdns-gateway; cp -a "$REPO_DIR" /opt/privdns-gateway 2>/dev/null || true; }
fi
: > /etc/mosdns/rules/custom_direct.txt

render(){ sed -e "s|__SERVER_IP__|$SERVER_IP|g" -e "s|__INTERNAL_CIDR__|$INTERNAL_CIDR|g" \
              -e "s|__CERT_DIR__|$CERT_DIR|g"   -e "s|__SSH_PORT__|$SSH_PORT|g" \
              -e "s|__BOT_TOKEN__|$BOT_TOKEN|g" -e "s|__ALLOWED_IDS__|$ALLOWED_IDS|g" "$1"; }

render "$REPO_DIR/deploy/mosdns/config.yaml"          > /etc/mosdns/config.yaml
render "$REPO_DIR/deploy/singbox/config.json.tmpl"    > /etc/sing-box/config.json
render "$REPO_DIR/deploy/firewall/nftables.conf"      > /etc/nftables.conf
render "$REPO_DIR/deploy/bot/pdg-bot.service"         > /etc/systemd/system/pdg-bot.service
chmod 600 /etc/systemd/system/pdg-bot.service        # 含 token
install -m644 "$REPO_DIR"/deploy/bot/pdg-rules-update.service /etc/systemd/system/
install -m644 "$REPO_DIR"/deploy/bot/pdg-rules-update.timer   /etc/systemd/system/
install -m644 "$REPO_DIR"/deploy/ios/pdg-probe81.service      /etc/systemd/system/
install -m644 "$REPO_DIR"/deploy/firewall/journald-50-pdg.conf /etc/systemd/system/journald.conf.d/50-pdg.conf

cat > /etc/systemd/system/mosdns.service <<'EOF'
[Unit]
Description=mosdns
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/mosdns start -d /etc/mosdns
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

# ── 6. DoT 证书 ──
if [[ -n "${PDG_SKIP_CERT:-}" ]]; then
  c_y "PDG_SKIP_CERT: 跳过 certbot, 生成自签占位证书 (生产请用 bot『🌐 DoT 自定义域名』补正式证书)"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" -days 3650 -subj "/CN=$DOT_DOMAIN" >/dev/null 2>&1
  chmod 644 "$CERT_DIR/fullchain.pem"; chmod 600 "$CERT_DIR/privkey.pem"
  echo "$DOT_DOMAIN" > /opt/pdg-bot/dot-domain
else
  echo
  c_y "现在签 DoT 证书。请先确认: $DOT_DOMAIN 的 A 记录已指向 $SERVER_IP"
  c_y "(Cloudflare 等用『灰云 / DNS only』, 不要开代理; 等生效后再继续)"
  [[ -n "$NONINT" ]] || read -rp "A 记录已指好? 回车继续签发 / Ctrl-C 退出去配 DNS: " _
  certbot certonly --standalone -d "$DOT_DOMAIN" --non-interactive --agree-tos \
    --register-unsafely-without-email --keep-until-expiring \
    --pre-hook  /usr/local/bin/proxy-gateway-open-cert-http.sh \
    --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh \
    || die "证书签发失败: 检查 A 记录是否已生效、80 口是否能从公网到达"
  echo "$DOT_DOMAIN" > /opt/pdg-bot/dot-domain
  install -m644 "/etc/letsencrypt/live/$DOT_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
  install -m600 "/etc/letsencrypt/live/$DOT_DOMAIN/privkey.pem"   "$CERT_DIR/privkey.pem"
fi

# ── 7. geosite 规则库 (此时 DNS 仍可用) ──
c_g "下载并解析 geosite 规则库…"
bash /opt/pdg-bot/update-rules.sh || c_y "geosite 下载失败, 装好后可在 bot『更新规则库』重试"

# ── 8. 启动 ──
c_g "启动服务…"
# 释放 53 口: systemd-resolved 的 stub 占 127.0.0.53:53, 会和 mosdns 0.0.0.0:53 冲突
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  systemctl disable --now systemd-resolved 2>/dev/null || true
fi
rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable --now mosdns sing-box pdg-probe81 >/dev/null 2>&1 || true
systemctl enable --now pdg-rules-update.timer >/dev/null 2>&1 || true
if [[ -n "$BOT_TOKEN" && -n "$ALLOWED_IDS" ]]; then
  systemctl enable --now pdg-bot >/dev/null 2>&1 || true
else
  systemctl enable pdg-bot >/dev/null 2>&1 || true   # 开机自启; 现在没 token 暂不启动, 用 pdg-set-token 设置后启用
fi
printf 'nameserver 127.0.0.1\nnameserver 1.1.1.1\n' > /etc/resolv.conf

# ── 9. 防火墙 ──
c_g "应用防火墙…"
systemctl enable nftables >/dev/null 2>&1 || true
nft -f /etc/nftables.conf

# ── 10. 体检 ──
echo; c_g "安装完成。状态:"
for s in mosdns sing-box pdg-bot pdg-probe81; do printf "  %-12s %s\n" "$s" "$(systemctl is-active "$s")"; done
if [[ -z "$BOT_TOKEN" || -z "$ALLOWED_IDS" ]]; then
  echo; c_y "管理 bot 未启用(没填 token)。设置并启用:  sudo pdg-set-token"
fi
cat <<EOF

下一步:
  1) 手机【私密 DNS / DoT】填:  $DOT_DOMAIN
  $( [[ -z "$BOT_TOKEN" || -z "$ALLOWED_IDS" ]] && echo "2) 启用管理 bot:  sudo pdg-set-token  (之后再发 /start)" || echo "2) Telegram 给你的 bot 发 /start, 然后:" )
       • 「📤 出口管理 → 添加」粘贴 ss:// / vmess:// / trojan:// / vless:// 落地节点
       • 「📑 分流管理」按需把域名/规则集指到出口 (默认其余国际走 jp 直出)
  3) iOS 用户: bot「📱 客户端 → iOS 描述文件」, 装上即可(蜂窝探测 :81 已就绪)
  4) 换域名随时用 bot「🌐 DoT 自定义域名」

🛠 日常管理:  sudo pdg   (状态 / 更新 / 换 token / 重启 / 日志 / 卸载)
⚠️ SSH 端口当前按 $SSH_PORT 放行; 若你之后改 sshd Port, 记得同步改 /etc/nftables.conf 再 nft -f。
EOF
