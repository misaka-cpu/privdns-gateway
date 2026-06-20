#!/usr/bin/env bash
# PrivDNS Gateway 管理命令。直接 `sudo pdg` 进菜单, 或 pdg <子命令>。
#   pdg [menu] | status | update | token | restart | log [n] | uninstall [--purge]
# 设计: 生命周期(装/更新/卸载/token/状态/日志)走这里; 出口/分流/DNS上游 走 Telegram bot。
set -uo pipefail
REPO_URL="https://github.com/misaka-cpu/privdns-gateway.git"
REPO_DIR="/opt/privdns-gateway"

c_g(){ echo -e "\033[1;32m$*\033[0m"; }
c_y(){ echo -e "\033[1;33m$*\033[0m"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "请用 root: sudo pdg $*"; exit 1; }; }

cmd_status(){
  c_g "== 服务 =="
  for s in mosdns sing-box pdg-bot pdg-probe81; do
    printf "  %-12s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  echo "  timer        $(systemctl is-active pdg-rules-update.timer 2>/dev/null)"
  echo "  DoT 域名     $(cat /opt/pdg-bot/dot-domain 2>/dev/null || echo ?)"
  echo "  监听端口     $(ss -lntu 2>/dev/null | grep -oE ':(53|80|81|443|853|9090)\b' | sort -u | tr '\n' ' ')"
  if [[ -d "$REPO_DIR/.git" ]]; then echo "  代码版本     $(git -C "$REPO_DIR" log --oneline -1 2>/dev/null)"; fi
}

cmd_update(){
  need_root update
  command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }
  c_g "拉取最新代码…"
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" fetch -q origin main && git -C "$REPO_DIR" reset --hard -q origin/main
  else
    rm -rf "$REPO_DIR"; git clone -q --depth 1 "$REPO_URL" "$REPO_DIR"
  fi
  c_g "刷新代码(配置/出口/token/证书均不动)…"
  install -m755 "$REPO_DIR"/deploy/bot/pdg-bot.py           /opt/pdg-bot/bot.py
  install -m755 "$REPO_DIR"/deploy/bot/parse-geosite.py     /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/update-rules.sh      /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/scheduled-update.sh  /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/ios/probe81.py           /opt/pdg-bot/
  install -m644 "$REPO_DIR"/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
  install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-open-cert-http.sh   /usr/local/bin/
  install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-restore-firewall.sh /usr/local/bin/
  install -m755 "$REPO_DIR"/deploy/cert/99-reload-cert.deploy-hook.sh     /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh
  install -m755 "$REPO_DIR"/deploy/bot/pdg-set-token.sh     /usr/local/bin/pdg-set-token
  install -m755 "$REPO_DIR"/deploy/bot/pdg.sh               /usr/local/bin/pdg
  python3 -m py_compile /opt/pdg-bot/bot.py 2>/dev/null || { c_y "新 bot.py 语法异常?? 已保留旧服务"; }
  systemctl daemon-reload
  systemctl restart pdg-bot pdg-probe81 2>/dev/null || true
  c_g "✅ 已更新。"
}

cmd_token(){ need_root token; pdg-set-token; }   # 不 exec, 设完/取消都回菜单

cmd_restart(){ need_root restart; systemctl restart mosdns sing-box pdg-bot pdg-probe81 2>/dev/null; echo "已重启 mosdns / sing-box / pdg-bot / pdg-probe81"; }

cmd_log(){ journalctl -u pdg-bot -u mosdns -u sing-box -n "${1:-40}" --no-pager -o cat; }

cmd_ios(){
  need_root ios
  local TMPL=/opt/pdg-bot/pdg-dot.mobileconfig.tmpl
  [[ -f "$TMPL" ]] || { echo "缺少 $TMPL, 先装好 PrivDNS Gateway"; return 1; }
  command -v qrencode >/dev/null || { c_g "装 qrencode…"; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode; }
  # 取 DoT 主机名(证书 CN)/ 公网 IP / 内网卡段
  local CERT=/etc/mosdns/certs/fullchain.pem; [[ -f /etc/dnsdist/certs/fullchain.pem ]] && CERT=/etc/dnsdist/certs/fullchain.pem
  local HOST IP CIDR
  HOST=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | grep -oE 'CN *= *[A-Za-z0-9.*-]+' | sed 's/.*= *//')
  IP=$(grep -oE '"[0-9.]+/32"' /etc/sing-box/config.json 2>/dev/null | tr -d '"' | grep -v '^127' | head -1 | cut -d/ -f1)
  [[ -n "$IP" ]] || IP=$(curl -fsSL --max-time 6 https://api.ipify.org)
  CIDR=$(grep -oE 'ip saddr [0-9./]+' /etc/nftables.conf 2>/dev/null | head -1 | awk '{print $3}')
  [[ -n "$HOST" && -n "$IP" && -n "$CIDR" ]] || { echo "信息不全 (HOST=$HOST IP=$IP CIDR=$CIDR)"; return 1; }

  local PORT=8443 TOK U1 U2 WWW URL
  TOK=$(openssl rand -hex 6)
  U1=$(cat /proc/sys/kernel/random/uuid | tr a-z A-Z); U2=$(cat /proc/sys/kernel/random/uuid | tr a-z A-Z)
  WWW=$(mktemp -d)
  sed -e "s/__DOT_HOST__/$HOST/g" -e "s/__JP_IP__/$IP/g" -e "s/__UUID1__/$U1/g" -e "s/__UUID2__/$U2/g" \
      "$TMPL" > "$WWW/$TOK.mobileconfig"
  URL="http://$IP:$PORT/$TOK.mobileconfig"

  local SRV=""
  trap 'kill "$SRV" 2>/dev/null; nft -f /etc/nftables.conf 2>/dev/null; rm -rf "$WWW"; trap - INT TERM' INT TERM
  nft insert rule inet filter input ip saddr "$CIDR" tcp dport "$PORT" accept 2>/dev/null
  ( cd "$WWW" && timeout 600 python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1 ) &
  SRV=$!
  qrencode -o /opt/pdg-bot/ios-qr.png "$URL" 2>/dev/null || true
  echo
  c_g "用手机(走【内网卡/蜂窝】, 关 WiFi)扫下面二维码 → Safari 打开 → 安装描述文件:"
  echo; qrencode -t ANSIUTF8 "$URL"; echo
  echo "  链接: $URL"
  echo "  DoT:  $HOST   (PNG 已存 /opt/pdg-bot/ios-qr.png)"
  c_y "装好后按回车收尾(10 分钟自动收)…"
  read -t 600 -r _ || true
  kill "$SRV" 2>/dev/null
  nft -f /etc/nftables.conf 2>/dev/null   # 撤掉临时放行
  rm -rf "$WWW"
  echo "已关闭临时下载服务。"
}

cmd_uninstall(){
  need_root uninstall
  if [[ -f "$REPO_DIR/uninstall.sh" ]]; then bash "$REPO_DIR/uninstall.sh" "${1:-}"
  else c_y "没找到 $REPO_DIR/uninstall.sh, 先 pdg update 拉取仓库"; fi
}

menu(){
  while true; do
    echo; c_g "===== PrivDNS Gateway 管理 ====="
    echo "  1) 状态"
    echo "  2) 更新"
    echo "  3) 设置 / 更换 bot token"
    echo "  4) 重启服务"
    echo "  5) 日志"
    echo "  6) iOS 描述文件"
    echo "  7) 卸载"
    echo "  0) 退出"
    read -rp "选择: " c || exit 0
    case "$c" in
      1) cmd_status;;
      2) cmd_update;;
      3) cmd_token;;
      4) cmd_restart;;
      5) cmd_log 60;;
      6) cmd_ios;;
      7) read -rp "卸载: 留空取消 / yes 仅卸载 / purge 连配置一起删: " x
         case "$x" in yes) cmd_uninstall;; purge) cmd_uninstall --purge;; *) echo "已取消";; esac;;
      0|q) exit 0;;
      *) echo "无效选择";;
    esac
  done
}

case "${1:-menu}" in
  menu|"")       menu;;
  status|st)     cmd_status;;
  update|up)     cmd_update;;
  token)         cmd_token;;
  restart)       cmd_restart;;
  log|logs)      shift || true; cmd_log "${1:-40}";;
  ios)           cmd_ios;;
  uninstall|rm)  shift || true; cmd_uninstall "${1:-}";;
  *) echo "用法: pdg [menu|status|update|token|restart|log [n]|ios|uninstall [--purge]]";;
esac
