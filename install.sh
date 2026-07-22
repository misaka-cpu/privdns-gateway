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
# shellcheck source=lib/units.sh
source "$REPO_DIR/lib/units.sh"   # systemd unit 单一事实源(与 switch-core 共用, 免漂移)
# shellcheck source=lib/mosdns.sh
source "$REPO_DIR/lib/mosdns.sh" # mosdns 劫持形态单一事实源(与 hijack-mode/迁移共用)

# ── 事务性安装: 失败自动回滚(只撤本次新装的, 不误伤既有可用部署)──
INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0
# 安装状态: 全部在注册 EXIT trap 前初始化 —— rollback 在 set -u 下读到未赋值的变量会
# 二次崩溃, 把最初的安装错误盖掉, 还会漏掉它后面的 nftables/resolved/resolv.conf 还原。
PRIOR_INSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; MIHOMO_INSTALLED=0; RESOLVED_DISABLED=0
# 二进制安装事务台账: 每项 "目标路径|装前是否存在(0/1)|备份路径|装前SHA"。
# 只要"即将改动目标"就先记一笔 —— *_INSTALLED 表示的是"装成功了吗", 不能拿来表示
# "这次碰过目标没有": install 写了一半才失败时它还是 0, 回滚就会漏掉那个半成品。
BIN_TXN=()
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
  # 覆盖重装会重写既有部署的配置, 没有快照就等于不可恢复 → 快照拿不到就在动任何文件之前中止。
  command -v pdg >/dev/null 2>&1 \
    || die "PDG_FORCE_REINSTALL: 找不到 pdg 命令, 无法在覆盖前留快照 → 中止。"
  c_y "PDG_FORCE_REINSTALL: 在已有部署上覆盖重装 → 先留一份快照…"
  pdg snapshot >/dev/null 2>&1 \
    || die "覆盖重装前快照失败 → 中止(拒绝在无法恢复配置的前提下覆盖已有部署)。"
fi

_sha(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 覆盖既有内核/解析器二进制前先留一份原件。别人装的 mosdns/sing-box/mihomo(哪怕版本
# 不同)不算"本次新增", 回滚时应当还原原件而不是删掉。
#
# 返回非 0 = 备份不可靠, 调用方**必须中止**, 绝不能继续覆盖 —— 备份失败还照装, 等于
# 在没有退路的前提下改别人的二进制。目标本来就不存在时返回 0(没什么可留)。
_stash_bin(){
  local p="$1" bak="$1.pdg-preinstall" tmp sha
  if [[ ! -e "$p" ]]; then
    BIN_TXN+=("$p|0||")               # 仍要记账: 回滚时要删掉本次可能留下的半成品
    return 0
  fi
  sha="$(_sha "$p")"
  [[ -n "$sha" ]] || { c_y "读不到 $p 的校验和 → 中止(无法保证可回退)。"; return 1; }
  if [[ -e "$bak" ]]; then
    # 残留备份分两种: 与当前文件**内容一致** = 上次装成功后没清掉的, 清掉继续即可(常见, 安全);
    # 内容不同 = 来源不明, 既不能拿当前文件盖掉它, 也不能拿它顶替当前文件 → 交人工。
    if [[ "$(_sha "$bak")" == "$sha" ]]; then
      rm -f "$bak" 2>/dev/null || { c_y "清理残留备份 $bak 失败 → 中止。"; return 1; }
    else
      c_y "发现上次遗留的备份: $bak(内容与当前 $p 不同, 来源不明)"
      c_y "  拒绝覆盖。请先人工确认(确是旧版就 mv 回 $p, 无用则删除), 再重跑。"
      return 1
    fi
  fi
  # 先写同目录临时文件, 校验通过再原子 mv 落位: 半截拷贝不会被当成完整原件
  tmp="$(mktemp "$(dirname "$p")/.pdg-stash.XXXXXX" 2>/dev/null)" \
    || { c_y "无法在 $(dirname "$p") 创建临时文件 → 中止。"; return 1; }
  if ! cp -a "$p" "$tmp" 2>/dev/null || [[ "$(_sha "$tmp")" != "$sha" ]]; then
    rm -f "$tmp" 2>/dev/null
    c_y "备份 $p 失败(拷贝不完整) → 中止, 不在无法回退的前提下覆盖二进制。"; return 1
  fi
  if ! mv -f "$tmp" "$bak" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null; c_y "备份落位失败 → 中止。"; return 1
  fi
  BIN_TXN+=("$p|1|$bak|$sha")
  return 0
}

# 回滚二进制: 按事务台账逐条独立处理, 失败计入调用方的 failed(动态作用域)。
# 台账在"即将改动目标"之前就记好, 所以 install 写了一半才失败也能被恢复 ——
# 用 *_INSTALLED(装成功了吗)判断"这次碰过目标没有"会漏掉正是这种情况。
_rollback_bins(){
  local entry p pre bak sha
  for entry in ${BIN_TXN[@]+"${BIN_TXN[@]}"}; do
    IFS='|' read -r p pre bak sha <<<"$entry"
    if [[ "$pre" == 1 ]]; then
      if [[ -z "$bak" || ! -e "$bak" ]]; then failed+=("还原 $p(备份丢失)"); continue; fi
      if ! mv -f "$bak" "$p" 2>/dev/null;   then failed+=("还原 $p(mv 失败)");  continue; fi
      # 只看"文件在"不够: 必须确认还原出来的确实等于备份下来的那一份
      if [[ -n "$sha" && "$(_sha "$p")" != "$sha" ]]; then failed+=("还原 $p(校验和不符)"); continue; fi
    else
      rm -f "$p" 2>/dev/null || failed+=("移除 $p")
    fi
  done
}

# 安装确认成功后清理备份(原件不再需要)。
_commit_bins(){
  local entry p pre bak sha
  for entry in ${BIN_TXN[@]+"${BIN_TXN[@]}"}; do
    IFS='|' read -r p pre bak sha <<<"$entry"
    [[ -n "$bak" ]] && rm -f "$bak" 2>/dev/null
  done
  return 0
}

rollback(){
  # set +e 只关 errexit, nounset 仍然生效 → 下面一律用 ${VAR:-0} 兜底, 不整体关 nounset。
  set +e
  local failed=()                       # 未能恢复的项; 单项失败不中断后续恢复
  [[ "${ROLLBACK_DONE:-0}" == 1 ]] && return; ROLLBACK_DONE=1
  if [[ "${FORCED_REINSTALL:-0}" == 1 ]]; then
    c_y "覆盖重装中途失败 —— 既有部署的配置可能已被改写。"
    # 配置交给 pdg rollback(有安装前快照), 但**本次事务动过的二进制必须自己还原**:
    # 旧版本的快照未必含内核二进制, 指望 pdg rollback 收拾它们并不可靠。
    _rollback_bins
    if [[ ${#failed[@]} -eq 0 ]]; then
      c_y "  本次覆盖的二进制已还原(无备份残留)。"
    else
      c_y "  以下二进制未能还原, 请手工检查: ${failed[*]}"
    fi
    c_y "  恢复配置:  sudo pdg rollback   (用安装前那份快照), 再  sudo pdg doctor  复查。"
    [[ ${#failed[@]} -eq 0 ]] || return 1
    return 0
  fi
  c_y "安装失败 → 回滚本次全新安装的改动…"
  # 各步骤相互独立: 单项失败只记账, 不挡住后面的恢复; 但也绝不因此谎报"已回滚"。
  local units="pdg-bot.service pdg-probe81.service mosdns.service sing-box.service mihomo.service
               pdg-mitm.service pdg-rules-update.service pdg-health.service
               pdg-rules-update.timer pdg-health.timer"
  for u in $units; do
    [[ -e "/etc/systemd/system/$u" ]] || continue        # 本次没创建过的 unit 不算失败
    systemctl disable --now "$u" >/dev/null 2>&1 || failed+=("停用 $u")
  done
  for u in $units; do
    [[ -e "/etc/systemd/system/$u" ]] || continue
    rm -f "/etc/systemd/system/$u" || failed+=("删除 unit $u")
  done
  for d in /etc/systemd/journald.conf.d/50-pdg.conf /etc/systemd/system/journald.conf.d/50-pdg.conf; do
    [[ -e "$d" ]] || continue                            # 正确 + 历史错路径都删
    rm -f "$d" || failed+=("删除 $d")
  done
  systemctl daemon-reload 2>/dev/null || failed+=("daemon-reload")
  systemctl restart systemd-journald 2>/dev/null || true   # CanReload=no: 必须 restart 才松开封顶
  if nft list table inet pdg >/dev/null 2>&1; then         # 表不存在不算失败
    nft delete table inet pdg 2>/dev/null || failed+=("删除 nft 表 inet pdg")
  fi
  for d in /etc/mosdns /etc/sing-box /etc/mihomo /opt/pdg-bot /etc/privdns-gateway; do
    [[ -e "$d" ]] || continue
    rm -rf "$d" || failed+=("删除 $d")
  done
  rm -f /usr/local/bin/{pdg,pdg-set-token,proxy-gateway-open-cert-http.sh,proxy-gateway-restore-firewall.sh} \
    || failed+=("删除本次安装的管理脚本")
  _rollback_bins        # 按事务台账还原/清除二进制(装前存在的还原原件, 不存在的删半成品)
  # 还原系统级改动(仅全新安装才到这里)。逐项独立判定: 任一项失败都不许挡住后面的还原。
  if [[ -e /etc/nftables.conf.pdg-orig ]]; then
    if cp -a /etc/nftables.conf.pdg-orig /etc/nftables.conf 2>/dev/null; then
      nft -f /etc/nftables.conf 2>/dev/null || failed+=("nftables 重载")
      rm -f /etc/nftables.conf.pdg-orig
    else
      failed+=("nftables.conf 还原")
    fi
  fi
  if [[ "${RESOLVED_DISABLED:-0}" == 1 ]]; then
    systemctl enable --now systemd-resolved 2>/dev/null || failed+=("systemd-resolved 恢复")
  fi
  if [[ -e /etc/resolv.conf.pdg-orig ]]; then
    # 同装机那侧: bind-mount 的 resolv.conf 删不掉也 mv 不上去, 但内容能原地写回。
    # 退化路径丢的是"原来是个符号链接"这一属性, 内容(上游 DNS)是对的 —— 比整条还原失败强。
    if rm -f /etc/resolv.conf 2>/dev/null && mv /etc/resolv.conf.pdg-orig /etc/resolv.conf 2>/dev/null; then
      :
    elif cat /etc/resolv.conf.pdg-orig > /etc/resolv.conf 2>/dev/null; then
      rm -f /etc/resolv.conf.pdg-orig 2>/dev/null
    else
      failed+=("resolv.conf 还原")
    fi
  fi
  if [[ ${#failed[@]} -eq 0 ]]; then
    c_y "已回滚到安装前状态。修正问题后可重跑 install.sh。"
  else
    c_y "回滚已尽力执行完, 但以下项未能恢复, 请手工检查: ${failed[*]}"
    return 1
  fi
}
# 不在此处 exit: 让 shell 保持触发退出的原始状态码, 回滚的失败不改写最初的安装错误。
on_exit(){
  local rc="$1"
  if [[ "${INSTALL_OK:-0}" == 1 || "$rc" == 0 ]]; then
    _commit_bins                      # 装成了, 原件备份不再需要
    return 0
  fi
  rollback || true                    # 回滚自身的成败已在上面打印, 不改写最初的安装退出码
  return 0
}
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
  _stash_bin /usr/local/bin/mosdns || die "备份既有 mosdns 失败 → 中止(不在无法回退的前提下覆盖二进制)。"
  (cd "$t" && unzip -q m.zip && install -m755 mosdns /usr/local/bin/mosdns)
  # shellcheck disable=SC2034  # 保留为"装成功了吗"的标记并保持 trap 前初始化;
  # 回滚已改看 BIN_TXN 事务台账(它才代表"这次碰过目标没有")。
  MOSDNS_INSTALLED=1
  rm -rf "$t"
fi

# ── 3. 内核: sing-box 1.12.x(默认)或 mihomo(PDG_CORE=mihomo, 原型)──
CORE="${PDG_CORE:-singbox}"
[[ "$CORE" == singbox || "$CORE" == mihomo ]] || die "PDG_CORE 只能是 singbox 或 mihomo"
if [[ "$CORE" == mihomo ]]; then
  CORE_SVC=mihomo
  if ! mihomo -v 2>/dev/null | grep -q "$MIHOMO_VER"; then
    c_g "下载 mihomo $MIHOMO_VER ($MARCH)…"
    t=$(mktemp -d)
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-${MARCH}-${MIHOMO_VER}.gz" -o "$t/mihomo.gz"
    pdg_verify_sha256 "$t/mihomo.gz" "${PDG_SHA256[mihomo-$MARCH]:-}" "mihomo $MIHOMO_VER ($MARCH)" \
      || { rm -rf "$t"; die "mihomo 二进制校验未通过 → 拒绝安装(供应链异常, 或版本与 lib/versions.sh 不符)"; }
    gunzip -c "$t/mihomo.gz" > "$t/mihomo"
    _stash_bin /usr/local/bin/mihomo || die "备份既有 mihomo 失败 → 中止(不在无法回退的前提下覆盖二进制)。"
    install -m755 "$t/mihomo" /usr/local/bin/mihomo
    # shellcheck disable=SC2034  # 保留为"装成功了吗"的标记并保持 trap 前初始化;
  # 回滚已改看 BIN_TXN 事务台账(它才代表"这次碰过目标没有")。
  MIHOMO_INSTALLED=1
    rm -rf "$t"
  fi
else
  CORE_SVC=sing-box
  if ! sing-box version 2>/dev/null | grep -q "version 1.12"; then
    c_g "下载 sing-box $SINGBOX_VER ($MARCH)…"
    t=$(mktemp -d)
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${MARCH}.tar.gz" -o "$t/sb.tgz"
    pdg_verify_sha256 "$t/sb.tgz" "${PDG_SHA256[singbox-$MARCH]:-}" "sing-box $SINGBOX_VER ($MARCH)" \
      || { rm -rf "$t"; die "sing-box 二进制校验未通过 → 拒绝安装(供应链异常, 或版本与 lib/versions.sh 不符)"; }
    tar --no-same-owner -xzf "$t/sb.tgz" -C "$t"
    _stash_bin /usr/local/bin/sing-box || die "备份既有 sing-box 失败 → 中止(不在无法回退的前提下覆盖二进制)。"
    install -m755 "$t"/sing-box-*/sing-box /usr/local/bin/sing-box
    # shellcheck disable=SC2034  # 保留为"装成功了吗"的标记并保持 trap 前初始化;
  # 回滚已改看 BIN_TXN 事务台账(它才代表"这次碰过目标没有")。
  SINGBOX_INSTALLED=1
    rm -rf "$t"
  fi
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

# 手机平台: ios | android。一台网关服务一个内网卡手机号, 故平台是每台装机的固定属性。
# 决定客户端下发方式(iOS 描述文件 / 安卓私密DNS)+ 是否提供 iOS 专属功能(如 MITM 插件, 安卓需 root 故不提供)。
PLATFORM="${PDG_PLATFORM:-}"
# 覆盖重装(PDG_FORCE_REINSTALL)未显式传 PDG_PLATFORM 时: 优先沿用已有平台标记 —— 不能默认把 iOS 改成 Android。
if [[ -z "$PLATFORM" ]]; then
  _ep="$(cat /etc/privdns-gateway/platform 2>/dev/null)"
  [[ "$_ep" == ios || "$_ep" == android ]] && { PLATFORM="$_ep"; c_g "沿用已有平台标记: $PLATFORM"; }
fi
if [[ -z "$PLATFORM" ]]; then
  if [[ -n "$NONINT" ]]; then PLATFORM="android"
  else
    echo; c_y "你的手机平台?(决定客户端下发 + iOS 专属功能;一台网关对一个手机)"
    read -rp "平台 [1=iOS / 2=Android, 默认 2]: " _p
    case "$_p" in 1 | ios | iOS | IOS) PLATFORM=ios;; *) PLATFORM=android;; esac
  fi
fi
[[ "$PLATFORM" == ios || "$PLATFORM" == android ]] || die "PDG_PLATFORM 只能是 ios 或 android"

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
install -d /etc/mosdns/rules /etc/sing-box/rs /opt/pdg-bot "$CERT_DIR" /etc/letsencrypt/renewal-hooks/deploy /etc/systemd/journald.conf.d
install -m755 "$REPO_DIR"/deploy/bot/pdg-bot.py            /opt/pdg-bot/bot.py
install -m755 "$REPO_DIR"/deploy/bot/parse-geosite.py     /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/update-rules.sh      /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/scheduled-update.sh  /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/healthcheck.py      /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/checks.py           /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/doctor.py           /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/report.py           /opt/pdg-bot/
install -m755 "$REPO_DIR"/deploy/bot/sb2mihomo.py        /opt/pdg-bot/
# iOS 专属组件(MITM 模块 / :81 探测 / 描述文件模板)只在 iOS 平台安装; Android 不装。
if [[ "$PLATFORM" == ios ]]; then
  install -m755 "$REPO_DIR"/deploy/bot/mitm_ca.py          /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/mitm_server.py      /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/mitm_wloc.py        /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/ios/probe81.py           /opt/pdg-bot/
  install -m644 "$REPO_DIR"/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
fi
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
: > /etc/mosdns/rules/custom_hijack.txt   # bot 指到出口的域名(必须被 mosdns 劫持才会进代理)
: > /etc/mosdns/rules/unlock.txt          # WDA 解锁域名集(空=休眠; bot『🔓 解锁走 WDA』填充)
: > /etc/mosdns/rules/mitm_hijack.txt     # MITM 接管域名集(空=休眠; iOS 启用 MITM 插件时填充)

# 内存模式(克制版): PDG_LOWMEM=auto(默认)|1|0; MemTotal ≤ 1300MiB 判低内存。持久化到 profile.env。
# 只调确认安全的项: mosdns cache(8192/2048)+ journald 上限(50M/20M)。不动 sysctl/swap/MemoryMax。
case "${PDG_LOWMEM:-auto}" in
  1) LOWMEM=1;; 0) LOWMEM=0;;
  *) _cur=""; [[ -f /etc/privdns-gateway/profile.env ]] && _cur=$(sed -n 's/^PDG_LOWMEM=//p' /etc/privdns-gateway/profile.env | tail -1)
     if [[ "$_cur" == 0 || "$_cur" == 1 ]]; then LOWMEM="$_cur"   # 已固定的模式沿用(强制重装不覆盖用户选择)
     else _mt=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)
          if [[ -n "$_mt" && "$_mt" -le 1331200 ]]; then LOWMEM=1; else LOWMEM=0; fi; fi;;
esac
if [[ "$LOWMEM" == 1 ]]; then MOSDNS_CACHE=2048; JOURNALD_MAXUSE=20M; else MOSDNS_CACHE=8192; JOURNALD_MAXUSE=50M; fi

# 劫持模式: all(默认, 非CN域名全劫持进代理) | gfw(只劫持 GFWList 真被墙域名, 非墙海外域名返真实IP直连)。
# gfw 模式修 "SSH/直连走域名被劫持到网关" 的问题; 但要求内网卡 SIM 能直达一般互联网(非墙海外可达)。持久化到 profile.env。
case "${PDG_HIJACK_MODE:-}" in
  gfw) HIJACK_MODE=gfw;; all) HIJACK_MODE=all;;
  *) _hm=""; [[ -f /etc/privdns-gateway/profile.env ]] && _hm=$(sed -n 's/^PDG_HIJACK_MODE=//p' /etc/privdns-gateway/profile.env | tail -1)
     [[ "$_hm" == gfw || "$_hm" == all ]] && HIJACK_MODE="$_hm" || HIJACK_MODE=all;;
esac
[[ "$HIJACK_MODE" == gfw ]] && HIJACK_SET_FILE="geosite_gfw.txt" || HIJACK_SET_FILE="geosite_geolocation-!cn.txt"

install -d -m700 /etc/privdns-gateway
# 写本次管理的三个键; 在已有安装上覆盖重装时(与上面读回 PDG_LOWMEM/PDG_HIJACK_MODE 的意图一致),
# 保留 profile.env 里其余键 —— 尤其 PDG_TFO(bot 持久化的 TFO 意图)与未知/自定义键, 不被重装清掉。
{
  printf 'PDG_LOWMEM=%s\nPDG_HIJACK_MODE=%s\nPDG_PLATFORM=%s\n' "$LOWMEM" "$HIJACK_MODE" "$PLATFORM"
  [[ -f /etc/privdns-gateway/profile.env ]] && \
    grep -vE '^[[:space:]]*(PDG_LOWMEM|PDG_HIJACK_MODE|PDG_PLATFORM)=' /etc/privdns-gateway/profile.env
} > /etc/privdns-gateway/profile.env.new && mv -f /etc/privdns-gateway/profile.env.new /etc/privdns-gateway/profile.env
printf '%s\n' "$PLATFORM" > /etc/privdns-gateway/platform

render(){ sed -e "s|__SERVER_IP__|$SERVER_IP|g" -e "s|__INTERNAL_CIDR__|$INTERNAL_CIDR|g" \
              -e "s|__CERT_DIR__|$CERT_DIR|g"   -e "s|__SSH_PORT__|$SSH_PORT|g" \
              -e "s|__MOSDNS_CACHE__|$MOSDNS_CACHE|g" -e "s|__JOURNALD_MAXUSE__|$JOURNALD_MAXUSE|g" \
              -e "s|__HIJACK_SET_FILE__|$HIJACK_SET_FILE|g" "$1"; }

render "$REPO_DIR/deploy/mosdns/config.yaml"          > /etc/mosdns/config.yaml
# 模板自带 gfw 那道劫持门; all 模式要去掉它 —— all 的语义是"不是国内就劫持"(排除式),
# 留着门会退化成"只劫持 geosite 策展分类里的域名"。
_mosdns_hijack_shape "$HIJACK_MODE" /etc/mosdns/config.yaml "$HIJACK_SET_FILE" >/dev/null \
  || die "mosdns 劫持形态渲染失败"
render "$REPO_DIR/deploy/singbox/config.json.tmpl"    > /etc/sing-box/config.json   # 始终是 bot 的数据模型(mihomo 模式下也由它渲染)
# iOS: 模板含 GMS(in-gms-5228/5229/5230)入站, iOS 走 APNs 不需要 → 删掉, 让 canonical model 从一开始就无 GMS。
if [[ "$PLATFORM" == ios ]]; then
  python3 - /etc/sing-box/config.json <<'PY'
import json, sys
f = sys.argv[1]; c = json.load(open(f))
c["inbounds"] = [i for i in c.get("inbounds", []) if i.get("tag") not in ("in-gms-5228", "in-gms-5229", "in-gms-5230")]
json.dump(c, open(f, "w"), ensure_ascii=False, indent=2)
PY
fi
chmod 700 /etc/sing-box; chmod 600 /etc/sing-box/config.json   # config 含出口密码/uuid
[[ -e /etc/nftables.conf.pdg-orig ]] || cp -a /etc/nftables.conf /etc/nftables.conf.pdg-orig 2>/dev/null || true  # 供 uninstall 还原
# 内核后端: 标记 + 防火墙模板(mihomo 用 REDIRECT 入站变体)+ 初始渲染 mihomo 配置
printf '%s\n' "$CORE" > /etc/privdns-gateway/backend
if [[ "$CORE" == mihomo ]]; then
  render "$REPO_DIR/deploy/firewall/nftables-mihomo.conf" > /etc/nftables.conf
  install -d -m700 /etc/mihomo
  python3 - <<PY
import json, os, sys
sys.path.insert(0, "$REPO_DIR/deploy/bot")
import sb2mihomo
model = json.load(open("/etc/sing-box/config.json"))
cfg, _ = sb2mihomo.singbox_to_mihomo(model, redir_port=7893)
with open("/etc/mihomo/config.yaml", "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)   # JSON 即合法 YAML
os.chmod("/etc/mihomo/config.yaml", 0o600)
PY
else
  render "$REPO_DIR/deploy/firewall/nftables.conf"      > /etc/nftables.conf
fi
# iOS: 防火墙模板对两平台通用, 但 iOS 走 APNs 不需要 GMS 5228-5230 → 渲染后剥掉(sing-box 端口集 + mihomo REDIRECT)。
if [[ "$PLATFORM" == ios ]]; then
  sed -E -i 's#(tcp dport [{] 53, 80, 81, 443, 853), 5228-5230, 8445 [}] accept#\1, 8445 } accept#' /etc/nftables.conf
  sed -E -i 's#(tcp dport [{] 80, 443), 5228-5230 [}] redirect#\1 } redirect#' /etc/nftables.conf
fi
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
# pdg-probe81(:81 探测)是 iOS 专属, 仅 iOS 装 unit; Android 不装、不起、不开 81。
[[ "$PLATFORM" == ios ]] && install -m644 "$REPO_DIR"/deploy/ios/pdg-probe81.service /etc/systemd/system/
render "$REPO_DIR/deploy/firewall/journald-50-pdg.conf" > /etc/systemd/journald.conf.d/50-pdg.conf; chmod 644 /etc/systemd/journald.conf.d/50-pdg.conf

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
if [[ "$CORE" == mihomo ]]; then
  pdg_write_unit pdg_unit_mihomo  /etc/systemd/system/mihomo.service
else
  pdg_write_unit pdg_unit_singbox /etc/systemd/system/sing-box.service
fi

# pdg-mitm: MITM 插件服务(Feature B, 仅 iOS)。按 /etc/privdns-gateway/mitm.json 加载启用的插件。
if [[ "$PLATFORM" == ios ]]; then
  pdg_write_unit pdg_unit_pdg_mitm /etc/systemd/system/pdg-mitm.service
fi

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
# LXC/Docker 之类的环境把 /etc/resolv.conf **bind-mount** 进来: 删不掉(EBUSY), 但能原地写。
# 直接 `rm -f` 会被 set -e 判成致命错误, 整场安装在这里中止并转入回滚 —— 而回滚打印的是
# "安装失败", 真原因(删不掉 resolv.conf)反倒看不见。删不掉就原地覆盖内容即可。
# 连写都写不进去(只读挂载)也不该中止: 那只影响**网关自己**解析用哪个上游, 转发链路照常。
_write_resolv(){
  rm -f /etc/resolv.conf 2>/dev/null || true    # 常见是指向 resolved stub 的符号链接, 删掉才落得下实文件
  printf '%s\n' "$@" > /etc/resolv.conf 2>/dev/null \
    || c_y "写不了 /etc/resolv.conf(只读挂载?), 本机自身 DNS 维持原样; 转发不受影响。"
}
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  systemctl disable --now systemd-resolved 2>/dev/null && RESOLVED_DISABLED=1 || true
fi
_write_resolv "nameserver 1.1.1.1"
systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable --now mosdns "$CORE_SVC" >/dev/null 2>&1 || true
# pdg-probe81 / pdg-mitm 仅 iOS: Android 不启 :81 探测、不起 MITM 服务。
[[ "$PLATFORM" == ios ]] && { systemctl enable --now pdg-probe81 >/dev/null 2>&1 || true
                             systemctl enable --now pdg-mitm >/dev/null 2>&1 || true; }
systemctl enable --now pdg-rules-update.timer >/dev/null 2>&1 || true
systemctl enable --now pdg-health.timer >/dev/null 2>&1 || true
if [[ -n "$BOT_TOKEN" && -n "$ALLOWED_IDS" ]]; then
  systemctl enable --now pdg-bot >/dev/null 2>&1 || true
else
  systemctl enable pdg-bot >/dev/null 2>&1 || true   # 开机自启; 现在没 token 暂不启动, 用 pdg-set-token 设置后启用
fi
_write_resolv "nameserver 127.0.0.1" "nameserver 1.1.1.1"

# ── 9. 防火墙 ──
c_g "应用防火墙…"
systemctl enable nftables >/dev/null 2>&1 || true
nft -f /etc/nftables.conf

# ── 提交点前: 确认核心服务"持续"起来了 ──
# systemd 默认 Type=simple, `systemctl start` 返 0 只代表 exec 成功, 进程可能随即崩溃。
# 单看一次 active 有竞态(起来又崩) → 要求连续 3 次保持 active 才算稳(flapping 的 failed/activating 会打断)。
c_g "校验核心服务(需连续保持 active, 防起来又崩)…"
# 按平台的必需服务: pdg-probe81 仅 iOS(Android 不装/不起, 不纳入门槛, 否则 Android 装机误判失败回滚)。
PLAT_SVCS=(mosdns "$CORE_SVC"); [[ "$PLATFORM" == ios ]] && PLAT_SVCS+=(pdg-probe81)
svc_ok=0; streak=0
for _ in $(seq 1 20); do
  allact=1
  for s in "${PLAT_SVCS[@]}"; do
    [[ "$(systemctl is-active "$s" 2>/dev/null)" == active ]] || allact=0
  done
  if [[ "$allact" == 1 ]]; then streak=$((streak+1)); else streak=0; fi
  [[ "$streak" -ge 3 ]] && { svc_ok=1; break; }
  sleep 1
done
if [[ "$svc_ok" != 1 ]]; then
  for s in "${PLAT_SVCS[@]}"; do printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done
  journalctl -u mosdns -u "$CORE_SVC" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
  die "核心服务未能持续保持运行(见上日志)。"   # → 触发回滚
fi
INSTALL_OK=1   # 提交点: 核心服务已确认稳定 active, 后面只是打印, 不再回滚

# ── 10. 自检 ──
echo; c_g "安装完成($PLATFORM 平台)。状态:"
for s in mosdns "$CORE_SVC" pdg-bot "${PLAT_SVCS[@]:2}"; do printf "  %-12s %s\n" "$s" "$(systemctl is-active "$s")"; done
if [[ -z "$BOT_TOKEN" || -z "$ALLOWED_IDS" ]]; then
  echo; c_y "⚠️ 管理 bot 未启用(没填 token)。出口和分流规则都在 bot 里设——"
  c_y "   现在还没法配代理。先跑:  sudo pdg-set-token  设好 token, 再给 bot 发 /start。"
fi
cat <<EOF

下一步($PLATFORM 平台):
  1) $( [[ "$PLATFORM" == ios ]] && echo "iOS:见第 3 步生成并安装 iOS 描述文件(DoT 域名:$DOT_DOMAIN)" || echo "手机「私密 DNS」填:  $DOT_DOMAIN" )
  $( [[ -z "$BOT_TOKEN" || -z "$ALLOWED_IDS" ]] && echo "2) 启用管理 bot:  sudo pdg-set-token  (之后再发 /start)" || echo "2) Telegram 给你的 bot 发 /start, 然后:" )
       • 「📤 出口管理 → 添加」粘贴 ss:// / vmess:// / trojan:// / vless:// 落地节点
       • 「📑 分流管理」按需把域名/规则集指到出口 (默认其余国际走 jp 直出)
  $( [[ "$PLATFORM" == ios ]] && echo "3) iOS:bot「📱 客户端 → iOS 描述文件」生成并安装(Wi-Fi/蜂窝由 :81 探测激活)" || echo "3) Android:私密 DNS 填上面的 DoT 域名即可" )
  4) 换域名随时用 bot「🌐 DoT 自定义域名」

🛠 日常管理:  sudo pdg   (状态 / 更新 / 换 token / 重启 / 日志 / 卸载)
⚠️ SSH 端口当前按 $SSH_PORT 放行; 若你之后改 sshd Port, 记得同步改 /etc/nftables.conf 再 nft -f。
EOF
