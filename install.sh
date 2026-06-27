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
CERT_DIR="/etc/mosdns/certs"
NONINT="${PDG_NONINTERACTIVE:-}"
# 二进制版本(MOSDNS_VER/SINGBOX_VER)+ 钉死 SHA256 来自 lib/versions.sh, 自举进仓库后 source(见下)

c_g(){ echo -e "\033[1;32m[*]\033[0m $*"; }
c_y(){ echo -e "\033[1;33m[!]\033[0m $*"; }
die(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

pdg_checkout_latest_tag(){
  local dir="$1" tag cur target
  git -C "$dir" fetch -q --tags origin main
  if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    git -C "$dir" fetch -q --unshallow --tags origin main
  fi
  tag=$(git -C "$dir" tag -l 'v*' --sort=-v:refname | head -1)
  [[ -n "$tag" ]] || die "仓库没有发布 tag(v*), 中止安装。"
  cur=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
  target=$(git -C "$dir" rev-parse "$tag^{commit}" 2>/dev/null || true)
  if [[ "$cur" != "$target" ]]; then
    git -C "$dir" checkout -q "$tag"
  fi
  echo "$tag"
}

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
  if [[ ! -d "$DEST/.git" ]]; then
    rm -rf "$DEST"; git clone -q "$REPO_URL" "$DEST"
  fi
  TAG=$(pdg_checkout_latest_tag "$DEST")
  c_g "使用最新发布 $TAG"
  # 有可用控制终端就把 stdin 接回它(交互), 否则直接重跑(靠 PDG_* 环境变量非交互)
  export PDG_TAG_BOOTSTRAPPED=1
  if { true < /dev/tty; } 2>/dev/null; then exec bash "$DEST/install.sh" "$@" < /dev/tty
  else exec bash "$DEST/install.sh" "$@"; fi
fi
REPO_DIR="$SRC"
if [[ -d "$REPO_DIR/.git" && "${PDG_TAG_BOOTSTRAPPED:-}" != "1" ]]; then
  command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }
  TAG=$(pdg_checkout_latest_tag "$REPO_DIR")
  export PDG_TAG_BOOTSTRAPPED=1
  c_g "使用最新发布 $TAG"
  if { true < /dev/tty; } 2>/dev/null; then exec bash "$REPO_DIR/install.sh" "$@" < /dev/tty
  else exec bash "$REPO_DIR/install.sh" "$@"; fi
fi

# ── 版本 + 钉死 SHA256(供应链校验)──
# shellcheck source=lib/versions.sh
source "$REPO_DIR/lib/versions.sh"

# ── 事务性安装: 失败自动回滚(只撤本次新装的, 不误伤既有可用部署)──
INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0
PRIOR_INSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; RESOLVED_DISABLED=0
[[ -f /opt/pdg-bot/bot.py || -x /usr/local/bin/pdg ]] && PRIOR_INSTALL=1

# 已有部署: install.sh 会重写配置, 半途失败难以无损还原 → 默认拒绝, 引导走 pdg update(带快照+回滚)。
# 确需原机覆盖重装的显式 PDG_FORCE_REINSTALL=1; 此时先打快照, 失败用 pdg rollback 恢复。
if [[ "$PRIOR_INSTALL" == 1 ]]; then
  if [[ -z "${PDG_FORCE_REINSTALL:-}" ]]; then
    die "检测到已有 PrivDNS Gateway 部署。
  升级请用:  sudo pdg update   (带快照 + 校验门 + 失败自动回滚, 不动出口/分流/证书)
  确要原机覆盖重装(会重写配置): sudo PDG_FORCE_REINSTALL=1 ./install.sh"
  fi
  FORCED_REINSTALL=1
  c_y "PDG_FORCE_REINSTALL: 在已有部署上覆盖重装 → 先留一份快照(失败可 pdg rollback)…"
  pdg snapshot >/dev/null 2>&1 || c_y "  (快照失败, 仍继续; 万一失败可能无法自动恢复)"
fi

rollback(){
  set +e
  [[ "$ROLLBACK_DONE" == 1 ]] && return; ROLLBACK_DONE=1
  if [[ "$FORCED_REINSTALL" == 1 ]]; then
    c_y "覆盖重装中途失败 —— 既有部署的配置可能已被改写。"
    c_y "  恢复:  sudo pdg rollback   (用安装前那份快照), 再  sudo pdg doctor  复查。"
    return
  fi
  c_y "安装失败 → 回滚本次全新安装的改动…"
  systemctl disable --now pdg-bot pdg-probe81 mosdns sing-box \
      pdg-rules-update.timer pdg-health.timer 2>/dev/null
  rm -f /etc/systemd/system/{pdg-bot,pdg-probe81,mosdns,sing-box,pdg-rules-update,pdg-health}.service \
        /etc/systemd/system/pdg-rules-update.timer /etc/systemd/system/pdg-health.timer \
        /etc/systemd/system/journald.conf.d/50-pdg.conf
  systemctl daemon-reload 2>/dev/null
  nft delete table inet pdg 2>/dev/null
  rm -rf /etc/mosdns /etc/sing-box /opt/pdg-bot /etc/privdns-gateway
  rm -f /usr/local/bin/{pdg,pdg-set-token,proxy-gateway-open-cert-http.sh,proxy-gateway-restore-firewall.sh}
  [[ "$MOSDNS_INSTALLED" == 1 ]] && rm -f /usr/local/bin/mosdns
  [[ "$SINGBOX_INSTALLED" == 1 ]] && rm -f /usr/local/bin/sing-box
  # 还原系统级改动(仅全新安装才到这里)
  if [[ -e /etc/nftables.conf.pdg-orig ]]; then
    cp -a /etc/nftables.conf.pdg-orig /etc/nftables.conf 2>/dev/null
    nft -f /etc/nftables.conf 2>/dev/null
    rm -f /etc/nftables.conf.pdg-orig
  fi
  [[ "$RESOLVED_DISABLED" == 1 ]] && systemctl enable --now systemd-resolved 2>/dev/null
  if [[ -e /etc/resolv.conf.pdg-orig ]]; then rm -f /etc/resolv.conf; mv /etc/resolv.conf.pdg-orig /etc/resolv.conf 2>/dev/null; fi
  c_y "已回滚到安装前状态。修正问题后可重跑 install.sh。"
}
on_exit(){ local rc="$1"; [[ "$INSTALL_OK" == 1 || "$rc" == 0 ]] && return 0; rollback; }
trap 'on_exit $?' EXIT

# ── 1. 依赖 ──
c_g "安装依赖…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl tar unzip nftables python3 openssl certbot dnsutils tcpdump jq ca-certificates vnstat >/dev/null
systemctl enable --now vnstat >/dev/null 2>&1 || true   # 网卡流量统计(轻量, ~3MB)

# ── 2. mosdns ──
if ! command -v mosdns >/dev/null; then
  c_g "下载 mosdns $MOSDNS_VER ($MARCH)…"
  t=$(mktemp -d)
  curl -fsSL "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-${MARCH}.zip" -o "$t/m.zip"
  pdg_verify_sha256 "$t/m.zip" "${PDG_SHA256[mosdns-$MARCH]:-}" "mosdns $MOSDNS_VER ($MARCH)" \
    || { rm -rf "$t"; die "mosdns 二进制校验未通过 → 拒绝安装(供应链异常, 或版本与 lib/versions.sh 不符)"; }
  (cd "$t" && unzip -q m.zip && install -m755 mosdns /usr/local/bin/mosdns)
  MOSDNS_INSTALLED=1
  rm -rf "$t"
fi

# ── 3. sing-box 1.12.x ──
if ! sing-box version 2>/dev/null | grep -q "version 1.12"; then
  c_g "下载 sing-box $SINGBOX_VER ($MARCH)…"
  t=$(mktemp -d)
  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${MARCH}.tar.gz" -o "$t/sb.tgz"
  pdg_verify_sha256 "$t/sb.tgz" "${PDG_SHA256[singbox-$MARCH]:-}" "sing-box $SINGBOX_VER ($MARCH)" \
    || { rm -rf "$t"; die "sing-box 二进制校验未通过 → 拒绝安装(供应链异常, 或版本与 lib/versions.sh 不符)"; }
  tar -xzf "$t/sb.tgz" -C "$t"
  install -m755 "$t"/sing-box-*/sing-box /usr/local/bin/sing-box
  SINGBOX_INSTALLED=1
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
    if [[ -n "$DET_CIDR" ]]; then c_g "抓到内网卡段: $DET_CIDR"
    else c_y "没抓到(手机没走内网卡? 云安全组挡了 80/ICMP?)。可先手填(如 172.22.0.0/16),"
         c_y "装完再从容跑 \`sudo pdg detect-cidr\` 重新识别并一键应用。"; fi
    read -rp "内网卡来源段 CIDR [${DET_CIDR:-请手填如 172.22.0.0/16}]: " INTERNAL_CIDR
    INTERNAL_CIDR="${INTERNAL_CIDR:-${DET_CIDR:-}}"
    [[ -n "$INTERNAL_CIDR" ]] || die "必须填内网卡来源段 (形如 172.22.0.0/16)"
  fi
fi

BOT_TOKEN="${PDG_BOT_TOKEN:-}"; ALLOWED_IDS="${PDG_ALLOWED:-}"; DOT_DOMAIN="${PDG_DOT_DOMAIN:-}"
if [[ -z "$NONINT" ]]; then
  echo
  if [[ -z "$BOT_TOKEN" ]]; then
    c_y "提示: 出口(落地节点)和分流规则都在 Telegram bot 里设置。不填 token 也能装完,"
    c_y "      但要等之后 sudo pdg-set-token 设好 token、给 bot 发 /start 才能配代理。"
    read -rp "Telegram bot token (可留空): " BOT_TOKEN
  fi
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
install -m755 "$REPO_DIR"/deploy/bot/healthcheck.py      /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/checks.py           /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/doctor.py           /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/report.py           /opt/pdg-bot/
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
: > /etc/mosdns/rules/unlock.txt          # WDA 解锁域名集(空=休眠; bot『🔓 解锁走 WDA』填充)

render(){ sed -e "s|__SERVER_IP__|$SERVER_IP|g" -e "s|__INTERNAL_CIDR__|$INTERNAL_CIDR|g" \
              -e "s|__CERT_DIR__|$CERT_DIR|g"   -e "s|__SSH_PORT__|$SSH_PORT|g" "$1"; }

render "$REPO_DIR/deploy/mosdns/config.yaml"          > /etc/mosdns/config.yaml
render "$REPO_DIR/deploy/singbox/config.json.tmpl"    > /etc/sing-box/config.json
chmod 700 /etc/sing-box; chmod 600 /etc/sing-box/config.json   # config 含出口密码/uuid
[[ -e /etc/nftables.conf.pdg-orig ]] || cp -a /etc/nftables.conf /etc/nftables.conf.pdg-orig 2>/dev/null || true  # 供 uninstall 还原
render "$REPO_DIR/deploy/firewall/nftables.conf"      > /etc/nftables.conf
render "$REPO_DIR/deploy/bot/pdg-bot.service"         > /etc/systemd/system/pdg-bot.service
chmod 644 /etc/systemd/system/pdg-bot.service        # 不再含 token (token 在 bot.env)

# token / 允许 id 写入受限的 bot.env (目录 700 / 文件 600), 不进 unit 也不进版本库
install -d -m700 /etc/privdns-gateway
( umask 077; printf 'PDG_BOT_TOKEN=%s\nPDG_BOT_ALLOWED=%s\n' "$BOT_TOKEN" "$ALLOWED_IDS" > /etc/privdns-gateway/bot.env )
chmod 600 /etc/privdns-gateway/bot.env
install -m644 "$REPO_DIR"/deploy/bot/pdg-rules-update.service /etc/systemd/system/
install -m644 "$REPO_DIR"/deploy/bot/pdg-rules-update.timer   /etc/systemd/system/
install -m644 "$REPO_DIR"/deploy/bot/pdg-health.service       /etc/systemd/system/
install -m644 "$REPO_DIR"/deploy/bot/pdg-health.timer         /etc/systemd/system/
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
# 先备份原 resolv.conf(含符号链接), 供 uninstall 恢复
[[ -e /etc/resolv.conf.pdg-orig ]] || cp -a /etc/resolv.conf /etc/resolv.conf.pdg-orig 2>/dev/null || true
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  systemctl disable --now systemd-resolved 2>/dev/null && RESOLVED_DISABLED=1 || true
fi
rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable --now mosdns sing-box pdg-probe81 >/dev/null 2>&1 || true
systemctl enable --now pdg-rules-update.timer >/dev/null 2>&1 || true
systemctl enable --now pdg-health.timer >/dev/null 2>&1 || true
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

# ── 提交点前: 确认核心服务"持续"起来了 ──
# systemd 默认 Type=simple, `systemctl start` 返 0 只代表 exec 成功, 进程可能随即崩溃。
# 单看一次 active 有竞态(起来又崩) → 要求连续 3 次保持 active 才算稳(flapping 的 failed/activating 会打断)。
c_g "校验核心服务(需连续保持 active, 防起来又崩)…"
svc_ok=0; streak=0
for _ in $(seq 1 20); do
  allact=1
  for s in mosdns sing-box pdg-probe81; do
    [[ "$(systemctl is-active "$s" 2>/dev/null)" == active ]] || allact=0
  done
  if [[ "$allact" == 1 ]]; then streak=$((streak+1)); else streak=0; fi
  [[ "$streak" -ge 3 ]] && { svc_ok=1; break; }
  sleep 1
done
if [[ "$svc_ok" != 1 ]]; then
  for s in mosdns sing-box pdg-probe81; do printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done
  journalctl -u mosdns -u sing-box -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
  die "核心服务未能持续保持运行(见上日志)。"   # → 触发回滚
fi
INSTALL_OK=1   # 提交点: 核心服务已确认稳定 active, 后面只是打印, 不再回滚

# ── 10. 自检 ──
echo; c_g "安装完成。状态:"
for s in mosdns sing-box pdg-bot pdg-probe81; do printf "  %-12s %s\n" "$s" "$(systemctl is-active "$s")"; done
if [[ -z "$BOT_TOKEN" || -z "$ALLOWED_IDS" ]]; then
  echo; c_y "⚠️ 管理 bot 未启用(没填 token)。出口和分流规则都在 bot 里设——"
  c_y "   现在还没法配代理。先跑:  sudo pdg-set-token  设好 token, 再给 bot 发 /start。"
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
