#!/usr/bin/env bash
# 卸载 PrivDNS Gateway (保留 certbot 证书与二进制; 加 --purge 一并删)。
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }

# sing-box 归属判定: v1.6 起本项目不再装 sing-box, 但老机器上可能仍有一份。机器上那份未必
# 是我们装的(用户完全可能自己跑一个干别的) —— 删别人的东西不可逆, 故只删能证明是本项目装的。
# 判据集中在 lib/singbox.sh(与 pdg / install 共用): 可信归属标记, 或"完整匹配历史 PDG unit
# 形态 + 现场另有本项目特征"。单凭一条 ExecStart 不算数 —— 那正是手工安装最常见的写法。
# 运行时归属(unit/二进制)与**数据模型归属**(/etc/sing-box 目录)是两回事: v1.6 起本项目根本
# 不装 sing-box 运行时, 于是运行时归属恒为否 —— 但 /etc/sing-box/config.json 仍是本项目的数据
# 模型, 里面是出口密码、UUID、节点地址。拿运行时归属决定 purge 删不删这个目录, 纯 mihomo 的
# 新装机器 purge 完凭据还原样躺在盘上。两者分开判。
SB_UNIT=/etc/systemd/system/sing-box.service
SB_OWNED=0
SB_WHY="(未判定)"
MODEL_OWNED=0
MODEL_WHY="(未判定)"
_UN_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
_UNINSTALL_FAILED=0
if [[ -f "$_UN_HERE/lib/singbox.sh" ]]; then
  # shellcheck source=lib/singbox.sh
  source "$_UN_HERE/lib/singbox.sh"
  pdg_singbox_is_ours "$SB_UNIT" && SB_OWNED=1
  # 原因要在 --purge 动手**之前**问出来: backend 标记等判据文件待会儿就被删了, 事后再问,
  # 报出来的会是"缺 backend"这种由卸载自己造成的假原因。
  [[ "$SB_OWNED" == 0 ]] && SB_WHY="$(pdg_singbox_why_not_ours "$SB_UNIT")"
  pdg_sbmodel_is_ours && MODEL_OWNED=1
  [[ "$MODEL_OWNED" == 0 ]] && MODEL_WHY="$(pdg_sbmodel_why_not_ours)"
else
  echo "警告: 找不到 lib/singbox.sh, 无法判定 sing-box 归属 → 一律保留(不删)。"
fi

# nft 可执行位置先解析出来(救援清理与后面删 inet pdg 共用)。只看 PATH 的话, /usr/sbin 未导出
# 的机器上会当成"没装 nft"整条跳过 —— 磁盘上的配置还原了, 内核里的表还在, 卸载完端口仍被
# policy drop 挡着, 而用户从配置文件上完全看不出为什么。
_UN_NFT=""
for _l in "$_UN_HERE/lib/nftbin.sh" /opt/privdns-gateway/lib/nftbin.sh; do
  [[ -f "$_l" ]] || continue
  # shellcheck source=lib/nftbin.sh
  source "$_l" && _UN_NFT="$(pdg_nft_bin || true)"
  break
done
[[ -n "$_UN_NFT" ]] || _UN_NFT="$(command -v nft 2>/dev/null || true)"   # 判据文件缺失时的兜底

# 救援平面 + 全部运行模块: 停用 unit, 再把凭据、状态、运行模块与那条独立放行规则一起带走。
# 救援是最后一道门, 但既然是卸载, 门本身也要带走 —— 留一个 token + TLS 私钥在盘上、外加
# 一条内网放行, 而服务已经没了, 比不卸载更糟。
# 删哪些走 pdg_project_members(= lib/modules.sh 的运行模块真源 + 救援 unit/凭据/状态),
# **不是**"完整恢复受保护成员"那份清单 —— 那份只是恢复旧快照时要保住的最小通道, 拿它当
# 卸载清单会把 pdgtx.py/checks.py 这些留在盘上。
systemctl disable --now pdg-rescue.socket pdg-rescue.service 2>/dev/null || true
systemctl reset-failed pdg-rescue.socket pdg-rescue.service 2>/dev/null || true
_RESCUE_RESIDUE=""
if [[ -f "$_UN_HERE/lib/rescue.sh" ]]; then
  # shellcheck source=lib/rescue.sh
  source "$_UN_HERE/lib/rescue.sh"
  # shellcheck disable=SC2034  # 前缀赋值是给 pdg_rescue_cleanup 的环境变量, shellcheck
  # 看不进函数体所以判它"未使用"。CI 的 shellcheck 是阻断步骤, 这条告警会让整条流水线红。
  PDG_RESCUE_REPO="$_UN_HERE" _RESCUE_RESIDUE="$(pdg_rescue_cleanup "" "$_UN_NFT")" || true
else
  _RESCUE_RESIDUE="找不到 lib/rescue.sh, 救援平面(凭据/状态/放行规则)未清理"
fi
# 内网面板(方案 B): 反代 unit、出站白名单、配置与证书、DNS API 凭据、acme 账户密钥、
# caddy 二进制、专用用户。与救援平面同一条规矩 —— 残留要逐条报出来, 因为这里留下的是
# **能改用户 DNS 记录的凭据**与**能签发证书的账户密钥**: 服务已经没了而凭据还在,
# 比不卸载更糟。
_LAN_RESIDUE=""
_LAN_REMOVED=""
[[ -e /etc/pdg-lan || -e /opt/pdg-acme \
   || -x /usr/local/bin/caddy || -e /etc/systemd/system/pdg-lan.service ]] && _LAN_REMOVED=1
systemctl disable --now pdg-lan 2>/dev/null || true
systemctl reset-failed pdg-lan 2>/dev/null || true
rm -f /etc/systemd/system/pdg-lan.service /etc/nftables-pdg-lan.conf
[[ -n "$_UN_NFT" ]] && "$_UN_NFT" delete table inet pdglan 2>/dev/null || true
# 注意这里**没有** /etc/privdns-gateway 下的任何路径: 普通卸载路径上碰那个目录是禁止的
# (tests/test-ios-profile-persist.py 有守卫)。DNS 凭据放在 /etc/pdg-lan/dns.env, 跟着
# 上面第一项一起走 —— 既删干净了, 又没碰用户配置目录。
for _lp in /etc/pdg-lan /var/lib/pdg-lan /opt/pdg-acme; do
  [[ -e "$_lp" ]] || continue
  rm -rf "$_lp" 2>/dev/null || true
  [[ -e "$_lp" ]] && _LAN_RESIDUE="$_LAN_RESIDUE $_lp"
done
rm -f /usr/local/bin/caddy 2>/dev/null || true
[[ -e /usr/local/bin/caddy ]] && _LAN_RESIDUE="$_LAN_RESIDUE /usr/local/bin/caddy"
# 去广告: 删**可再生**的第三方表与编译产物; 用户自己写的 allow/block 在
# /etc/mosdns/rules/ 下, 与其它规则集同口径由那一段统一处理, 这里一个字节都不碰。
[[ -d /var/lib/privdns-gateway/adblock ]] && rm -rf /var/lib/privdns-gateway/adblock

if id pdg-lan >/dev/null 2>&1; then
  userdel pdg-lan 2>/dev/null || _LAN_RESIDUE="$_LAN_RESIDUE 用户pdg-lan(删不掉,可能还有进程在跑)"
fi
# 面板表跟着 /etc/privdns-gateway 走(purge 模式一起删, 否则保留) —— 与 mosdns/mihomo
# 配置同一个口径: 它是用户配置, 重装可复用。这里不单独处理。

systemctl disable --now pdg-bot pdg-probe81 pdg-dotwitness mosdns mihomo pdg-mitm pdg-rules-update.timer pdg-health.timer 2>/dev/null || true
[[ "$SB_OWNED" == 1 ]] && systemctl disable --now sing-box 2>/dev/null || true
rm -f /etc/systemd/system/{pdg-bot,pdg-probe81,pdg-dotwitness,mosdns,mihomo,pdg-mitm,pdg-rules-update,pdg-health}.service \
      /etc/systemd/system/pdg-rules-update.timer /etc/systemd/system/pdg-health.timer \
      /etc/systemd/journald.conf.d/50-pdg.conf /etc/systemd/system/journald.conf.d/50-pdg.conf   # 正确路径 + 历史错路径都删
[[ "$SB_OWNED" == 1 ]] && rm -f "$SB_UNIT"
systemctl daemon-reload
systemctl restart systemd-journald 2>/dev/null || true   # journald CanReload=no, 必须 restart 才会松开封顶

# 防火墙: 从**当前**配置里摘掉本项目的管理块, 而不是拿装机前的备份整份盖回去。
#
# 旧写法 `mv /etc/nftables.conf.pdg-orig /etc/nftables.conf` 等于"还原到装机前", 后果是用户
# 装完 PDG 之后加的所有防火墙配置一并消失, 且毫无提示 —— WireGuard 转发、fail2ban 的表、
# 自己写的放行, 卸载完才发现没了, 那时现网已经被覆盖。备份是**参考材料**, 不是能拿来覆盖
# 现网的权威版本, 所以 .pdg-orig 现在只保留、不再自动套用。
_NFT_RESIDUE=""
if [[ -f /etc/nftables.conf ]]; then
  _nb="/var/backups/pdg-uninstall-$(date +%Y%m%d-%H%M%S)"
  install -d -m700 "$_nb" 2>/dev/null
  if install -m600 /etc/nftables.conf "$_nb/nftables.conf" 2>/dev/null; then
    echo "当前防火墙配置已备份: $_nb/nftables.conf"
  else
    _NFT_RESIDUE="备份当前 /etc/nftables.conf 失败 —— 未改动防火墙配置(拒绝在没有退路时动它)"
  fi
  if [[ -z "$_NFT_RESIDUE" ]]; then
    _cand="$_nb/nftables.conf.candidate"
    if python3 "$_UN_HERE/deploy/bot/nftpurge.py" --strip < /etc/nftables.conf > "$_cand" 2>"$_nb/err"; then
      if [[ -n "$_UN_NFT" ]] && ! "$_UN_NFT" -c -f "$_cand" >/dev/null 2>&1; then
        _NFT_RESIDUE="摘掉项目块后的候选没通过 nft -c —— 现网配置**一个字节未动**, 候选留在 $_cand"
      else
        cp -a "$_cand" /etc/nftables.conf 2>/dev/null \
          || _NFT_RESIDUE="写回 /etc/nftables.conf 失败(磁盘满/只读?)"
        [[ -n "$_UN_NFT" && -z "$_NFT_RESIDUE" ]] && { "$_UN_NFT" -f /etc/nftables.conf >/dev/null 2>&1 \
          || _NFT_RESIDUE="新配置应用失败 —— 内核里可能仍有本项目规则, 备份见 $_nb/nftables.conf"; }
      fi
    else
      _NFT_RESIDUE="$(head -1 "$_nb/err" 2>/dev/null || echo '识别不了本项目的防火墙块')"
      _NFT_RESIDUE="$_NFT_RESIDUE —— 现网配置未改动, 备份见 $_nb/nftables.conf"
    fi
  fi
fi
# 内核对象: 配置里已经没有 inet pdg 了, 增量 nft -f 删不掉它, 要单独删
[[ -n "$_UN_NFT" ]] && "$_UN_NFT" delete table inet pdg 2>/dev/null || true
# 磁盘与内核都必须没有项目痕迹, 否则不许说"卸载完成"
if [[ -z "$_NFT_RESIDUE" ]]; then
  python3 "$_UN_HERE/deploy/bot/nftpurge.py" --check < /etc/nftables.conf >/dev/null 2>&1 \
    || _NFT_RESIDUE="磁盘上仍有 table inet pdg"
  if [[ -n "$_UN_NFT" ]] && "$_UN_NFT" list tables 2>/dev/null | grep -q "inet pdg$"; then
    _NFT_RESIDUE="${_NFT_RESIDUE:+$_NFT_RESIDUE; }内核里仍有 table inet pdg"
  fi
fi
[[ -e /etc/nftables.conf.pdg-orig ]] \
  && echo "装机前的防火墙配置仍保留在 /etc/nftables.conf.pdg-orig(仅供人工参考, 不会自动套用)"
# DNS: 还原 systemd-resolved 与 resolv.conf
systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved' && systemctl enable --now systemd-resolved 2>/dev/null || true
RESOLV_WARN=""
if [[ -e /etc/resolv.conf.pdg-orig ]]; then
  # Docker/LXC 里 /etc/resolv.conf 是 bind mount: rm/mv 都会 EBUSY, 但**内容能原地写回**。
  # 老写法直接 rm+mv, 失败了也照样往下走并宣布"已完成" —— 机器上留着指向本机 mosdns 的
  # resolv.conf, 而 mosdns 已经被卸载, 于是整机没 DNS。
  if rm -f /etc/resolv.conf 2>/dev/null && mv /etc/resolv.conf.pdg-orig /etc/resolv.conf 2>/dev/null; then
    :
  elif cat /etc/resolv.conf.pdg-orig > /etc/resolv.conf 2>/dev/null; then
    # 退化路径丢的是"原来是个符号链接"这一属性, 内容(上游 DNS)是对的
    rm -f /etc/resolv.conf.pdg-orig 2>/dev/null
  else
    RESOLV_WARN="1"                       # 备份**不删**: 留着让用户能自己恢复
  fi
elif [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null \
    || RESOLV_WARN="1"
fi

if [[ -n "$RESOLV_WARN" ]]; then
  echo "⚠️  /etc/resolv.conf 未能还原(可能是 Docker/LXC 的 bind mount, 删不掉也写不进)。"
  echo "    现在它可能仍指向已被卸载的本机 mosdns → 整机 DNS 会不通。请手工恢复:"
  [[ -e /etc/resolv.conf.pdg-orig ]] \
    && echo "      cat /etc/resolv.conf.pdg-orig > /etc/resolv.conf   # 备份已保留" \
    || echo "      在 /etc/resolv.conf 里填一个可用的 nameserver(如 nameserver 1.1.1.1)"
  echo "已停止并移除 systemd 单元、防火墙表(inet pdg); DNS 未能完全还原(见上)。"
else
  echo "已停止并移除 systemd 单元、防火墙表(inet pdg)、并尽量还原 DNS。"
fi
# 救援平面没清干净就必须逐条报出来: 残留的是仍然有效的 token 与 TLS 私钥。宁可让用户看见
# 一段刺眼的清单, 也不能让卸载在有残留的情况下只丢一句"已完成"。
if [[ -n "$_NFT_RESIDUE" ]]; then
  echo "⚠️  防火墙未能完全清理: $_NFT_RESIDUE"
  _UNINSTALL_FAILED=1
fi
if [[ -n "$_RESCUE_RESIDUE" ]]; then
  echo "⚠️  救援平面未能完全清除, 以下项目仍留在机器上(含凭据, 请手工删除):"
  printf '%s\n' "$_RESCUE_RESIDUE" | sed 's/^/    /'
else
  echo "救援平面已完全移除(unit、凭据、状态、运行文件与 ${PDG_RESCUE_PORT} 放行规则)。"
fi
if [[ -z "$_LAN_RESIDUE" && -n "$_LAN_REMOVED" ]]; then
  echo "内网面板已完全移除(反代 unit、出站白名单、配置与证书、caddy、专用用户)。"
  # 单独点名凭据: 删证书和二进制是"卸载本来就该做的", 而删掉 DNS API token 与 acme
  # 账户密钥意味着**证书续期从此不再进行**, 而且那两样是用户自己去服务商申请来的。
  echo "  连同 DNS API 凭据与 acme 账户密钥一并删除 —— 已签发的证书到期即失效, 不会再续。"
fi
if [[ -n "$_LAN_RESIDUE" ]]; then
  echo "⚠️  内网面板未能完全清除, 以下仍留在机器上(含 DNS API 凭据 / acme 账户密钥, 请手工删除):"
  printf '%s\n' "$_LAN_RESIDUE" | tr ' ' '\n' | sed '/^$/d; s/^/    /'
  _UNINSTALL_FAILED=1
fi

echo "保留: /etc/mosdns /etc/sing-box /etc/mihomo 与 Let's Encrypt 证书(配置与数据, 重装可复用)。"
echo "已删除: /opt/pdg-bot 下的事务与救援运行模块(清单见 lib/modules.sh 的 PDG_RUNTIME_MODULES)。"
# 说"全部"是不准的: install.sh 另有一路把 Bot 本体(bot.py)、MITM 组件、探测脚本等装进同一个
# 目录, 它们不在那份清单里, 卸载也不会删。`.200` 实测卸载完那里还剩 10 个项目程序文件, 而
# 文案说的是"全部运行模块" —— 用户据此以为盘上干净了, 其实没有。这里如实列出剩了什么。
if [[ -d /opt/pdg-bot ]]; then
  _left="$(find /opt/pdg-bot -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' -o -name '*.tmpl' \) -printf '%f ' 2>/dev/null)"
  if [[ -n "$_left" ]]; then
    echo "保留(不在上述清单内, 需要清干净请用 --purge): /opt/pdg-bot 下 $_left"
  fi
fi
# 归属证明不了 → 全保留。但不能只丢一句"已保留": 用户手工改过 unit 的情况下也会走到这里,
# 机器上从此挂着一个没人管的 sing-box。逐条列出留了什么、为什么判不出来、怎么自己清。
_sb_report_kept(){   # $1=with-config(--purge 时连配置目录一起列)
  local kept; kept="$(pdg_singbox_kept_paths "${1:-}")"
  [[ -n "$kept" ]] || return 0
  echo "注意: 以下 sing-box 文件无法确认是本项目安装的 → 已原样保留:"
  printf '%s\n' "$kept" | sed 's/^/    /'
  echo "  判不出归属的原因: $SB_WHY"
  echo "  确认它无用可自行清理:"
  echo "    systemctl disable --now sing-box"
  echo "    rm -rf $(printf '%s' "$kept" | tr '\n' ' ')"
}
[[ "$SB_OWNED" == 0 && "${1:-}" != "--purge" ]] && declare -F pdg_singbox_kept_paths >/dev/null \
  && _sb_report_kept

if [[ "${1:-}" == "--purge" ]]; then
  echo "[--purge] 删除配置与数据…"
  rm -rf /etc/mosdns /etc/mihomo /opt/pdg-bot /etc/privdns-gateway   # /etc/privdns-gateway 含 bot.env(token) + CA 私钥
  # /etc/sing-box 是本项目的数据模型目录(config.json/rs/ui), 里面有出口密码/UUID/节点地址。
  # 按**数据模型归属**判, 不看运行时归属 —— v1.6 起本项目不装 sing-box 运行时, 拿运行时归属
  # 判的话纯 mihomo 新装机器永远删不掉它, 凭据就留在盘上了。证明不了归属仍旧一律保留。
  [[ "$MODEL_OWNED" == 1 || "$SB_OWNED" == 1 ]] && rm -rf /etc/sing-box
  rm -f /usr/local/bin/mosdns /usr/local/bin/mihomo \
        /usr/local/bin/pdg /usr/local/bin/pdg-set-token \
        /usr/local/bin/proxy-gateway-open-cert-http.sh \
        /usr/local/bin/proxy-gateway-restore-firewall.sh \
        /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh
  # sing-box 二进制同样只删本项目装的; 来源不明的留给用户自己处置
  [[ "$SB_OWNED" == 1 ]] && rm -f /usr/local/bin/sing-box
  # 保留清单(unit / 二进制 / 整个 /etc/sing-box)一次性报全, 不散在各处只提一句
  if [[ "$SB_OWNED" == 0 ]] && declare -F pdg_singbox_kept_paths >/dev/null; then
    if [[ "$MODEL_OWNED" == 1 ]]; then
      _sb_report_kept                              # 模型已删, 只报 unit/二进制
    else
      _sb_report_kept with-config
      [[ -d /etc/sing-box ]] && echo "  /etc/sing-box 判不出归属的原因: $MODEL_WHY"
    fi
  fi
  rm -rf /opt/privdns-gateway /var/lib/privdns-gateway   # 仓库副本 + 快照 (放最后, 脚本已载入内存, 删它安全)
  echo "已 purge。证书目录 /etc/letsencrypt 仍保留(含账户), 如需彻底清除请手动 certbot delete。"
fi

# 有任何未清理项 → 非 0 退出。调用方(pdg uninstall / CI / 人)据此知道"这次没干净",
# 而不是看到最后一行 echo 就以为完事了。
[[ -n "$_RESCUE_RESIDUE" ]] && _UNINSTALL_FAILED=1
exit "$_UNINSTALL_FAILED"
