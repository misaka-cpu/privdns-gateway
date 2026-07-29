#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PrivDNS Gateway 一键安装 (Debian 12+ / Ubuntu 22+, 需 root)
#   sudo ./install.sh
# 非交互/自动化: 预置 PDG_* 环境变量 + PDG_NONINTERACTIVE=1 (见 docs/INSTALL.md)。
#   PDG_SERVER_IP PDG_SSH_PORT PDG_INTERNAL_CIDR PDG_BOT_TOKEN PDG_ALLOWED PDG_DOT_DOMAIN
#   PDG_SKIP_CERT=1  跳过 certbot, 生成自签占位证书 (之后用 bot 补正式证书)
# 做什么: 装 mosdns + mihomo + 管理 bot + 防火墙 + DoT 证书。
#   自动识别公网IP / 内网卡段; DNS(域名 A 记录) 那步留给你自己做; 落地出口装好后用 bot 加。
# 也支持 curl|bash 直接跑: curl -fsSL <raw>/install.sh | sudo bash  (脚本会自动拉取仓库)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_URL="https://github.com/misaka-cpu/privdns-gateway.git"
CERT_DIR="/etc/mosdns/certs"
NONINT="${PDG_NONINTERACTIVE:-}"
# 二进制版本(MOSDNS_VER/MIHOMO_VER)+ 钉死 SHA256 来自 lib/versions.sh, 自举进仓库后 source(见下)

c_g(){ echo -e "\033[1;32m[*]\033[0m $*"; }
c_y(){ echo -e "\033[1;33m[!]\033[0m $*"; }
die(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# 交互读取一行到指定变量, 撞 EOF / 无可用终端时回落到默认值 —— 绝不触发 errexit。
# 用法: ask <变量名> <提示语> [默认值]
# 为什么每次新开 /dev/tty: 自举把 fd 0 绑成某一个 /dev/tty 打开描述(见下方 exec ... < /dev/tty),
# 长时间抓包(detect-internal-range.sh ~90s)后该描述在某些云主机/终端上会进入异常态, 后续 read
# 立即返回 EOF。旧写法 `read ... VAR` 的非零返回会被 set -e 判成致命错误 → 整场安装回滚, 且不留
# 任何错误行(见 issue: "内网卡来源段 CIDR [...]: [!] 安装失败")。这里每次都新开 /dev/tty 取一个
# 干净的终端描述, 并把 EOF/无终端当"用默认值"处理, 让一次 read 失手不再拖垮整场安装。
ask(){
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  # 探针与重跑处同款: 把重定向挂在普通命令上, 打不开只让该命令返回非零(不会让 shell 退出);
  # 能打开才 read, 且 read 的 EOF 用 `|| __ans=""` 吃掉 —— 两条路都回落到默认值, 均不触发 errexit。
  if { true < /dev/tty; } 2>/dev/null; then
    read -rp "$__prompt" __ans < /dev/tty || __ans=""
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

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
source "$REPO_DIR/lib/units.sh"   # systemd unit 单一事实源(与 pdg 迁移共用, 免漂移)
# shellcheck source=lib/mosdns.sh
source "$REPO_DIR/lib/mosdns.sh"
# shellcheck source=lib/modules.sh
source "$REPO_DIR/lib/modules.sh"  # 运行模块单一事实源(与 pdg update 共用) # mosdns 劫持形态单一事实源(与 hijack-mode/迁移共用)
# shellcheck source=lib/cidr.sh
source "$REPO_DIR/lib/cidr.sh"   # 内网卡段校验 + 抓包/手输并行(与 pdg detect-cidr 共用)

# ── 事务性安装: 失败自动回滚(只撤本次新装的, 不误伤既有可用部署)──
INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0
# 安装状态: 全部在注册 EXIT trap 前初始化 —— rollback 在 set -u 下读到未赋值的变量会
# 二次崩溃, 把最初的安装错误盖掉, 还会漏掉它后面的 nftables/resolved/resolv.conf 还原。
PRIOR_INSTALL=0; MOSDNS_INSTALLED=0; MIHOMO_INSTALLED=0; RESOLVED_DISABLED=0
# 二进制安装事务台账: 每项 "目标路径|装前是否存在(0/1)|备份路径|装前SHA"。
# 只要"即将改动目标"就先记一笔 —— *_INSTALLED 表示的是"装成功了吗", 不能拿来表示
# "这次碰过目标没有": install 写了一半才失败时它还是 0, 回滚就会漏掉那个半成品。
BIN_TXN=()
# 目录事务台账: 每项 "目录|装前是否存在(0/1)|装前内容备份路径"。
# 回滚只该撤销**本次**造成的改动: 本次新建的目录才删, 装前就存在的要按备份还原 ——
# 直接 rm -rf 那几个目录会把装前就在那儿的东西(可能是别人的)一并抹掉。
DIR_TXN=()
[[ -f /opt/pdg-bot/bot.py || -x /usr/local/bin/pdg ]] && PRIOR_INSTALL=1

# ── 第三方路径冲突: 在改动任何东西之前中止 ──────────────────────────────────
# 本项目把 /etc/sing-box/config.json 当数据模型, 而手工装的 sing-box 也常用这个路径。
# 若机器上已有一份**证明不了归属**的 sing-box(unit / 二进制 / 配置), 继续装就会覆盖别人的
# 配置且不可逆 —— 直接中止, 把处置权交回用户。
# shellcheck source=lib/singbox.sh
source "$REPO_DIR/lib/singbox.sh"
if [[ "$PRIOR_INSTALL" == 0 ]]; then
  _sb_conflict=()
  [[ -e /etc/systemd/system/sing-box.service ]] && _sb_conflict+=("/etc/systemd/system/sing-box.service")
  [[ -e /usr/local/bin/sing-box ]] && _sb_conflict+=("/usr/local/bin/sing-box")
  [[ -e /etc/sing-box/config.json ]] && _sb_conflict+=("/etc/sing-box/config.json")
  if [[ ${#_sb_conflict[@]} -gt 0 ]] && ! pdg_singbox_is_ours; then
    die "检测到已存在的 sing-box, 且无法确认是本项目安装的 → 中止安装(未改动任何文件)。
  冲突路径: ${_sb_conflict[*]}
  本项目会把 /etc/sing-box/config.json 用作数据模型, 继续装会覆盖上面这些内容, 且不可逆。
  请先确认它们的归属: 确实不再需要就自行备份并移除, 再重跑本脚本;
  若那是你自己在跑的 sing-box, 请换一台机器部署本项目。"
  fi
fi

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

# ── 防火墙冲突: 同样在改动任何东西之前中止 ──────────────────────────────────
# 本项目的 table inet pdg 带 `hook input priority 0; policy drop`, 而 nftables 里同一 hook
# 上的多个 base chain **都会执行** —— 任一条判 drop 包就没了。机器上已有别的 input base chain
# 时装上去, 用户那些放行(自定义端口/VPN)会被架空: 配置看着还在, 端口实际不通。
# 判据与迁移共用 deploy/bot/nftscan.py, 不另写一套。
# **安全检查前置依赖**: 扫描器是 python3 写的。极简 Debian 12 默认没有 python3, 那时
# `python3 …` 直接 127 —— 旧写法的 case 只认 0 和 2, 127 静默落空, 于是"有冲突的机器照样
# 装下去", 这道门等于不存在。所以先把 python3 装上(只装它, 与后面那批正式依赖分开: 这是
# 为了**能做检查**, 不是开始部署), 装不上就中止 —— 检查做不了就不能往下走。
_NFTSCAN="$REPO_DIR/deploy/bot/nftscan.py"
[[ -f "$_NFTSCAN" ]] || die "缺少防火墙冲突扫描器 $_NFTSCAN → 中止安装(未改动任何文件)。
  仓库不完整? 请重新 clone 后再装。"
if ! command -v python3 >/dev/null 2>&1; then
  c_y "[*] 安全检查前置依赖: 本机没有 python3, 先装上它才能做防火墙冲突检查…"
  apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-minimal >/dev/null 2>&1 \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null 2>&1 || true
  command -v python3 >/dev/null 2>&1 \
    || die "装不上 python3 → 无法检查现有 nftables 是否与本项目冲突, 中止安装(未改动配置)。
  本项目本来就依赖 python3(bot / 自检 / 渲染都用它)。请先手工装好:
    sudo apt-get update && sudo apt-get install -y python3
  再重跑本脚本。"
fi

# 退出码本身就是结论(0=有冲突 1=干净 2=读不到), 非零是正常返回 —— 赋值必须自己接住,
# 否则 set -e 会在"现场干净"时把安装直接杀掉。stderr 单独留一份: 出了别的错(解释器炸了 /
# 脚本语法坏了)要能看见原因, 不能只丢一句"检查失败"。
_nft_rc=0
_nft_err="$(mktemp)" || die "无法创建临时文件"
_nft_conflict="$(python3 "$_NFTSCAN" /etc/nftables.conf 2>"$_nft_err")" || _nft_rc=$?
_nft_stderr="$(head -c 2000 "$_nft_err" 2>/dev/null)"; rm -f "$_nft_err"
case "$_nft_rc" in
  0) die "检测到与本项目不兼容的 nftables input 链 → 中止安装(未改动任何文件)。
$(printf '%s\n' "$_nft_conflict" | sed 's/^/    /')
  本项目的 table inet pdg 是 policy drop, 而同一 hook 上每条 base chain 都会执行 ——
  上面这些表里的放行会被架空(端口看着开着、实际不通), 比直接报错更难查。
  请把需要的放行并入 table inet pdg 的 input chain(或把那些链改挂到非 input hook), 再重跑。" ;;
  1) : ;;   # 确认无冲突 → 继续
  2) # 读不到运行中的 ruleset。机器上压根没有 nft = 还没装 nftables, 没有现网规则可冲突,
     # 照常继续(本脚本随后会装 nftables); nft 在却读不到 = 权限/内核异常, 不能盲目往下写规则。
     #
     # "在不在"必须与扫描器用**同一份**判据: `command -v nft` 只看 PATH, 而 nft 装在
     # /usr/sbin —— `su`(不带 -)、cron、某些容器的 root PATH 里没有 sbin, 于是明明装着
     # nftables 却被判成"没装", 一整套现网 input 链就这么被当成裸机放过去了。
     _nft_bin="$(python3 "$_NFTSCAN" --nft-path 2>/dev/null || true)"
     if [[ -n "$_nft_bin" && -x "$_nft_bin" ]]; then
       die "无法确认现有 nftables 规则(nft 在 $_nft_bin, 但 list ruleset 读不到)
  → 中止安装(未改动任何文件)。
$(printf '%s\n' "$_nft_conflict" | sed 's/^/    /')
  请用 root 重跑; 若 nftables 本身不可用(内核缺 nf_tables 模块等), 请先修好它再装。"
     fi
     c_y "[*] 本机还没有 nftables(扫描器也找不到 nft)→ 仅依据 /etc/nftables.conf 判定, 继续安装。" ;;
  *) # 127=找不到解释器 / 126=不可执行 / 1xx=被信号杀 / 其它=扫描器自己出错。
     # 一律中止: "检查没跑成"和"检查通过"是两回事, 后者才有资格继续装。
     die "防火墙冲突检查没能跑起来(退出码 $_nft_rc)→ 中止安装(未改动任何文件)。
$( [[ -n "$_nft_stderr" ]] && printf '  扫描器输出:\n%s\n' "$(printf '%s\n' "$_nft_stderr" | sed 's/^/    /')" )
  常见原因: python3 不可用或版本过旧(127/126)、$_NFTSCAN 损坏、被 OOM/信号杀掉。
  先确认 \`python3 $_NFTSCAN /etc/nftables.conf; echo \$?\` 能跑出 0/1/2, 再重跑本脚本。" ;;
esac

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
  # 按目录事务台账还原: 本次新建的删掉; 装前就存在的按备份原样还原 —— 无差别 rm -rf 会把
  # 装前就在那儿的东西(可能是第三方 sing-box 的配置)一并抹掉, 那不是"回滚"而是破坏。
  # 台账可能还没建(极早期失败) —— 在 set -u 下必须先安全取用, 直接 ${#DIR_TXN[@]} 会 unbound,
  # 那会让回滚自己崩掉并盖住最初的安装错误(正是本项目专门防的那类事故)。
  local dirtxn=(); dirtxn=(${DIR_TXN[@]+"${DIR_TXN[@]}"})
  if [[ ${#dirtxn[@]} -gt 0 ]]; then
    local entry d pre bak
    for entry in "${dirtxn[@]}"; do
      IFS='|' read -r d pre bak <<<"$entry"
      if [[ "$pre" == 1 ]]; then
        rm -rf "$d" 2>/dev/null
        if [[ -n "$bak" && -d "$bak" ]]; then
          mkdir -p "$d" && cp -a "$bak/." "$d/" 2>/dev/null || failed+=("还原 $d")
          rm -rf "$bak"
        else
          failed+=("还原 $d(备份丢失)")
        fi
      else
        [[ -e "$d" ]] && { rm -rf "$d" || failed+=("删除 $d"); }
      fi
    done
  else                                    # 台账还没建起来就失败了(极早期): 退回旧行为
    for d in /etc/mosdns /etc/sing-box /etc/mihomo /opt/pdg-bot /etc/privdns-gateway; do
      [[ -e "$d" ]] || continue
      rm -rf "$d" || failed+=("删除 $d")
    done
  fi
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
# zstd: 读 mihomo .mrs 规则集的头部(判 domain/ipcidr), 没它大文件就只能让用户手填类型
# iproute2: install.sh 用 ss 探 SSH 端口, pdg status/report/doctor 也靠它看监听 —— 极简
# Debian 12 默认不带, 缺了它"监听端口"整块是空的, 而装机不会报任何错。
apt-get install -y -qq curl tar unzip zstd nftables iproute2 python3 openssl certbot dnsutils tcpdump jq ca-certificates vnstat >/dev/null
systemctl enable --now vnstat >/dev/null 2>&1 || true   # 网卡流量统计(轻量, ~3MB)

# ── 2. mosdns ──
# 按**钉死版本**判定, 不是"装了就算数": 机器上原有的 mosdns(第三方装的/早年老版)会让
# `command -v mosdns` 成立而整段跳过 —— 既不升到钉死版, 也跳过 SHA256 供应链校验,
# 安装日志上连"下载 mosdns"这行都不会出现(现场就这么发现的)。
if ! pdg_mosdns_is_version "$MOSDNS_VER"; then
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

# ── 3. 内核: mihomo(clash.meta)—— 唯一流量内核 ──
# 历史上支持 sing-box(1.12.x)/mihomo 二选一; 但 sing-box 1.13 移除了本网关依赖的
# sniff_override_destination、被钉死在死胡同, 故 v1.6.0 起彻底移除 sing-box 运行时,
# mihomo 成唯一内核。旧的 sing-box 机器 `pdg update` 时由 migrate_drop_singbox 自动迁移。
CORE=mihomo
CORE_SVC=mihomo
if ! pdg_mihomo_is_version "$MIHOMO_VER"; then
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

# ── 4. 收集参数 (env 预置优先; PDG_NONINTERACTIVE=1 则不交互) ──
echo
SERVER_IP="${PDG_SERVER_IP:-}"
if [[ -z "$SERVER_IP" ]]; then
  DET_IP=$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  if [[ -n "$NONINT" ]]; then SERVER_IP="$DET_IP"; else ask SERVER_IP "本机公网 IP [${DET_IP}]: " "$DET_IP"; fi
fi
[[ -n "$SERVER_IP" ]] || die "公网 IP 不能为空"

SSH_PORT="${PDG_SSH_PORT:-}"
if [[ -z "$SSH_PORT" ]]; then
  DET_SSH=$(ss -lntpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}'); DET_SSH="${DET_SSH:-22}"
  if [[ -n "$NONINT" ]]; then SSH_PORT="$DET_SSH"; else ask SSH_PORT "SSH 端口 [${DET_SSH}]: " "$DET_SSH"; fi
fi

INTERNAL_CIDR="${PDG_INTERNAL_CIDR:-}"
if [[ -z "$INTERNAL_CIDR" ]]; then
  if [[ -n "$NONINT" ]]; then
    INTERNAL_CIDR="172.16.0.0/12"
  else
    echo; c_y "识别【内网卡来源段】(抓包 ~90s; 期间可随时直接手输网段, 谁先给出结果就用谁)"
    # 抓包与手输并行: 知道网段的人不必干等 90 秒, 抓到了也不用再确认一遍。
    INTERNAL_CIDR="$(pdg_detect_cidr_race 90 "$SERVER_IP" || true)"
    if [[ -n "$INTERNAL_CIDR" ]]; then
      c_g "内网卡来源段: $INTERNAL_CIDR"
    else
      c_y "没抓到(手机没走内网卡? 云安全组挡了 80/ICMP?)。"
      c_y "先手填一个即可; 装完再从容跑 \`sudo pdg detect-cidr\` 重新识别并一键应用。"
    fi
    # 取不到/填错都再给机会 —— 等满 90 秒后因一个空回车就回滚整场安装, 那是白等。
    _cidr_try=0
    while ! pdg_cidr_valid "$INTERNAL_CIDR"; do
      [[ -n "$INTERNAL_CIDR" ]] && c_y "「$INTERNAL_CIDR」不是合法网段(形如 172.22.0.0/16)。"
      _cidr_try=$((_cidr_try + 1))
      if [[ "$_cidr_try" -gt 3 ]]; then
        die "未取得内网卡来源段 (形如 172.22.0.0/16; 非交互/无终端请用 PDG_INTERNAL_CIDR)"
      fi
      # 无终端时再问也白问(ask 会立刻回空), 直接给出可操作的出路, 不空转三次
      if ! { true < /dev/tty; } 2>/dev/null; then
        die "无可用终端且未取得内网卡来源段 (请用 PDG_INTERNAL_CIDR=172.22.0.0/16 重跑)"
      fi
      ask INTERNAL_CIDR "内网卡来源段 CIDR (如 172.22.0.0/16): " ""
    done
  fi
fi

# 手机平台: ios | android。一台网关服务一个内网卡手机号, 故平台是每台装机的固定属性。
# 决定客户端下发方式(iOS 描述文件 / 安卓私密DNS)+ 是否提供 iOS 专属功能(如 MITM 插件, 安卓需 root 故不提供)。
PLATFORM="${PDG_PLATFORM:-}"
# 覆盖重装(PDG_FORCE_REINSTALL)未显式传 PDG_PLATFORM 时: 优先沿用已有平台标记 —— 不能默认把 iOS 改成 Android。
if [[ -z "$PLATFORM" ]]; then
  # 全新装时该文件尚不存在, cat 返 1 —— 在 set -e 下"赋值里命令替换失败"是致命错误, 会当场
  # 中止并回滚(屏幕上只剩"安装失败", 真原因被埋掉; 正是交互全新装偏偏挂在这里的根因)。故 || true。
  _ep="$(cat /etc/privdns-gateway/platform 2>/dev/null || true)"
  [[ "$_ep" == ios || "$_ep" == android ]] && { PLATFORM="$_ep"; c_g "沿用已有平台标记: $PLATFORM"; }
fi
if [[ -z "$PLATFORM" ]]; then
  if [[ -n "$NONINT" ]]; then PLATFORM="android"
  else
    echo; c_y "你的手机平台?(决定客户端下发 + iOS 专属功能;一台网关对一个手机)"
    _p=""; ask _p "平台 [1=iOS / 2=Android, 默认 2]: " ""
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
    ask BOT_TOKEN "Telegram bot token (可留空): " ""
  fi
  if [[ -n "$BOT_TOKEN" && -z "$ALLOWED_IDS" ]]; then ask ALLOWED_IDS "你的 Telegram user id (只允许它管理): " ""; fi
  [[ -n "$DOT_DOMAIN" ]] || ask DOT_DOMAIN "DoT 域名 (如 dot.example.com): " ""
fi
[[ -n "$DOT_DOMAIN" ]] || die "DoT 域名不能为空 (非交互请用 PDG_DOT_DOMAIN)"
# token / user id 可留空 → 装完先不启 bot, 之后 sudo pdg-set-token 补

# ── 5. 目录 + 静态文件 ──
c_g "铺设文件…"
# 记目录事务: 在**动这些目录之前**记下"装前存在吗", 存在的先备份一份内容。
# 回滚据此只撤本次的改动: 本次新建的删掉, 装前就有的按备份还原(不再无差别 rm -rf)。
_dir_txn_record(){
  local d bak
  for d in "$@"; do
    if [[ -e "$d" ]]; then
      bak="$(mktemp -d)" || { c_y "无法为 $d 备份 → 中止(拒绝在无法回退的前提下改动它)"; return 1; }
      cp -a "$d/." "$bak/" 2>/dev/null || { rm -rf "$bak"; c_y "备份 $d 失败 → 中止"; return 1; }
      DIR_TXN+=("$d|1|$bak")
    else
      DIR_TXN+=("$d|0|")
    fi
  done
}
_dir_txn_record /etc/mosdns /etc/sing-box /etc/mihomo /opt/pdg-bot /etc/privdns-gateway \
  || die "目录备份失败, 未改动任何文件。"
install -d /etc/mosdns/rules /etc/sing-box/rs /opt/pdg-bot "$CERT_DIR" /etc/letsencrypt/renewal-hooks/deploy /etc/systemd/journald.conf.d
# ── 项目静态文件: 全部走 lib/modules.sh 这份**单一事实源** ────────────────
# 全新安装、`pdg update` 与 uninstall 读同一份清单, 于是不可能出现"装机装了、升级漏了、
# 卸载没删"这种缺口。少装一个的后果不是报错, 是整块能力静默降级(救援页标"旧核心不支持")。
#
# 以前 bot.py / parse-geosite.py / update-rules.sh / scheduled-update.sh / healthcheck.py
# 与五个 iOS 组件是在这里各写一行 `install -m755 …` 装的, 不在任何清单里 —— 于是 update
# 永远不同步它们, 卸载也不删。平台专属那部分由 pdg_platform_modules 按 $PLATFORM 取。
pdg_install_runtime_modules "$REPO_DIR" /opt/pdg-bot "$PLATFORM" \
  || die "运行模块安装失败, 未继续(避免新旧混装)。"
install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-open-cert-http.sh     /usr/local/bin/
install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-restore-firewall.sh   /usr/local/bin/
install -m755 "$REPO_DIR"/deploy/cert/99-reload-cert.deploy-hook.sh       /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh
install -m755 "$REPO_DIR"/deploy/bot/pdg-set-token.sh                     /usr/local/bin/pdg-set-token
install -m755 "$REPO_DIR"/deploy/bot/pdg.sh                               /usr/local/bin/pdg
# 把仓库放到 /opt/privdns-gateway 供 `pdg update` / `pdg uninstall` 用。
# 复制失败**必须中止**: 旧写法 `|| true` 吞掉错误, 装完机器上没有仓库副本, 之后 pdg update
# 和 pdg uninstall 都无从谈起, 而装机全程一句提示都没有。
if [[ "$REPO_DIR" != "/opt/privdns-gateway" ]]; then
  if [[ ! -d /opt/privdns-gateway/.git ]]; then
    rm -rf /opt/privdns-gateway
    cp -a "$REPO_DIR" /opt/privdns-gateway || die "复制仓库到 /opt/privdns-gateway 失败(磁盘满/权限?)"
    [[ -d /opt/privdns-gateway/.git ]] || die "复制后的 /opt/privdns-gateway 里没有 .git —— 更新/卸载会用不了"
  fi
fi
# 属主统一收归 root: 用户常见做法是普通账号 git clone 后 sudo ./install.sh, 复制过去的副本
# 于是归那个普通用户所有。之后 root 跑 pdg update, git 会以 "dubious ownership" 拒绝一切操作
# (连 describe/tag 都读不到), 表现成"更新检查不出新版"这种莫名其妙的样子。
chown -R root:root /opt/privdns-gateway 2>/dev/null || true
git config --system --get-all safe.directory 2>/dev/null | grep -qx '/opt/privdns-gateway' \
  || git config --system --add safe.directory /opt/privdns-gateway 2>/dev/null || true
# 规则集: **存在就保留**。重装的语义是"重新部署程序", 不是"把用户填的域名清空" ——
# 这四个文件是 bot 指到出口的域名、WDA 解锁域名、以及 WLOC/MITM 的接管域名, 清掉之后
# 分流与 WLOC 会静默退化, 而用户以为只是重装了一下程序(.200 实机上就这么丢过 WLOC 域名)。
# shellcheck source=lib/preserve.sh
source "$REPO_DIR/lib/preserve.sh"
_kept_rules=(); _new_rules=()
for _rf in custom_direct custom_hijack unlock mitm_hijack; do
  if pdg_keep_or_init "/etc/mosdns/rules/$_rf.txt"; then _kept_rules+=("$_rf"); else _new_rules+=("$_rf"); fi
done
(( ${#_kept_rules[@]} )) && c_g "保留已有规则集: ${_kept_rules[*]}"
(( ${#_new_rules[@]} ))  && echo "新建空规则集: ${_new_rules[*]}"

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
#
# 走临时文件 + 原子替换, 且每一步的失败都要看见。旧写法是
#     { printf …; [[ -f old ]] && grep -v … old; } > new && mv new old
# 新装时 `[[ -f old ]]` 为假 → 整个 group 返回 1 → `&& mv` 不执行(而 && 列表里的失败又不触发
# set -e), 于是机器上只剩一个 profile.env.new: PDG_HIJACK_MODE 根本没落盘, 下一次 pdg restart
# 读不到就按默认 all 把 mosdns 形态改回去 —— 装机时选的 gfw 悄悄没了。
_prof_tmp="$(mktemp /etc/privdns-gateway/.profile.env.XXXXXX)" || die "创建 profile.env 临时文件失败"
{
  # PDG_INTERNAL_CIDR 是内网卡来源段的**唯一真源**(5.2/T7): nft、mosdns、救援服务的监听
  # 地址、doctor 全都从它读或由它渲染。以前只把这个值渲染进 nft 与 mosdns 两份配置, 读回时
  # 又从 mosdns 里正则抠 —— 于是"当前网段是多少"这件事没有权威答案, 而 mosdns 配置恰恰是
  # 救援场景里可能已经损坏的那一份。
  printf 'PDG_LOWMEM=%s\nPDG_HIJACK_MODE=%s\nPDG_PLATFORM=%s\nPDG_INTERNAL_CIDR=%s\n' \
    "$LOWMEM" "$HIJACK_MODE" "$PLATFORM" "$INTERNAL_CIDR"
  if [[ -f /etc/privdns-gateway/profile.env ]]; then
    # grep -v 在"旧文件只有受管键"时没有输出 → 返回 1, 不能让它把整段判成失败
    grep -vE '^[[:space:]]*(PDG_LOWMEM|PDG_HIJACK_MODE|PDG_PLATFORM|PDG_INTERNAL_CIDR)=' \
      /etc/privdns-gateway/profile.env || true
  fi
} > "$_prof_tmp" || { rm -f "$_prof_tmp"; die "写 profile.env 失败(磁盘满/只读?)"; }
chmod 600 "$_prof_tmp"
mv -f "$_prof_tmp" /etc/privdns-gateway/profile.env \
  || { rm -f "$_prof_tmp"; die "落盘 profile.env 失败"; }
rm -f /etc/privdns-gateway/profile.env.new          # 清掉历史版本留下的半成品
grep -q "^PDG_HIJACK_MODE=$HIJACK_MODE$" /etc/privdns-gateway/profile.env \
  || die "profile.env 未写入预期的 PDG_HIJACK_MODE"
# 真源必须**确实**落盘: 渲染进 nft/mosdns 的值与 profile.env 记的值不是同一个来源的话,
# 救援服务会绑到一个防火墙没放行的地址上, 而且没人看得出为什么。
grep -q "^PDG_INTERNAL_CIDR=$INTERNAL_CIDR$" /etc/privdns-gateway/profile.env \
  || die "profile.env 未写入预期的 PDG_INTERNAL_CIDR"
printf '%s\n' "$PLATFORM" > /etc/privdns-gateway/platform

# 救援平面的端口/路径常量来自 lib/rescue.sh(单一事实源, 不在这里另写字面量)。
# shellcheck source=lib/rescue.sh
source "$REPO_DIR/lib/rescue.sh"
# 监听地址与来源段是**两件事**(5.2/10b 实机结论):
#   INTERNAL_CIDR = 允许连进来的客户端网段(运营商内网卡);
#   RESCUE_BIND   = 救援 socket 绑的本机地址。
# 真实网关上后者往往不在前者里 —— 早期版本"从来源段里挑一个本机地址"在那种机器上要么什么
# 都挑不到(救援平面装了也用不了), 要么挑中一个恰好落在段内的**别的**接口地址(实机上就捡到过
# 一个测试用的 veth 地址, 于是监听开在了一个没人能连的地方)。所以: 显式值优先, 唯一候选才
# 自动决定, 含糊时**问人**, 非交互就留空并保持停用。绝不用 0.0.0.0/::。
RESCUE_BIND="${PDG_RESCUE_BIND:-}"
[[ -z "$RESCUE_BIND" ]] && RESCUE_BIND="$(pdg_rescue_bind 2>/dev/null || true)"   # 已有配置沿用
if [[ -n "$RESCUE_BIND" ]] && ! pdg_rescue_bind_valid "$RESCUE_BIND"; then
  c_y "PDG_RESCUE_BIND=$RESCUE_BIND 不是合法的 IPv4 监听地址(禁止主机名/0.0.0.0/广播/组播), 忽略。"
  RESCUE_BIND=""
fi
if [[ -z "$RESCUE_BIND" ]]; then
  mapfile -t _rb_in < <(python3 - "$INTERNAL_CIDR" <<'PYBIND'
import ipaddress, subprocess, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except Exception:
    sys.exit(0)
out = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"],
                     capture_output=True, text=True).stdout
for line in out.splitlines():
    parts = line.split()
    for i, tok in enumerate(parts):
        if tok == "inet" and i + 1 < len(parts):
            try:
                ip = ipaddress.ip_address(parts[i + 1].split("/")[0])
            except ValueError:
                continue
            if ip in net:
                print(ip)
PYBIND
)
  if (( ${#_rb_in[@]} == 1 )); then
    RESCUE_BIND="${_rb_in[0]}"          # 来源段内**恰好一个**本机地址 → 沿用旧的安全路径
  else
    mapfile -t _rb_all < <(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print $2" "a[1]}')
    if [[ -n "$NONINT" ]]; then
      c_y "未指定救援监听地址(PDG_RESCUE_BIND), 且来源段 $INTERNAL_CIDR 内有 ${#_rb_in[@]} 个本机地址 —— 不猜。"
      c_y "  救援平面照常装上但**保持停用**。本机可选地址:"
      printf '     %s\n' "${_rb_all[@]}"
      c_y "  设好即可启用: sudo pdg rescue bind <IPv4>"
    else
      echo
      c_y "救援平面要绑在哪个本机地址上?(它与来源段 $INTERNAL_CIDR 是两件事: 来源段管谁能连)"
      local_i=1
      for _l in "${_rb_all[@]}"; do echo "   $local_i) $_l"; local_i=$((local_i+1)); done
      echo "   0) 暂不设置(装上但停用, 之后用 sudo pdg rescue bind <IPv4>)"
      read -r -p "选择 [0-$(( ${#_rb_all[@]} ))]: " _pick || _pick=0
      if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_rb_all[@]} )); then
        RESCUE_BIND="$(awk '{print $2}' <<<"${_rb_all[$((_pick-1))]}")"
      fi
    fi
  fi
fi
if [[ -n "$RESCUE_BIND" ]]; then
  pdg_rescue_bind_is_global "$RESCUE_BIND" \
    && c_y "⚠️ 救援监听地址 $RESCUE_BIND 是全局可路由地址: 端口会暴露在该地址上, 由 nft 来源约束与应用层来源校验两层兜底。"
  # 落盘到真源。不落的话 pdg / 救援服务下次读不到, 又会退回"从来源段猜"的老路 ——
  # 装机时渲染进 unit 的地址与后续读到的地址必须是同一个, 否则没人看得出为什么连不上。
  _rb_tmp="$(mktemp /etc/privdns-gateway/.profile.env.XXXXXX)" || die "创建 profile.env 临时文件失败"
  { printf 'PDG_RESCUE_BIND=%s\n' "$RESCUE_BIND"
    grep -vE '^[[:space:]]*PDG_RESCUE_BIND=' /etc/privdns-gateway/profile.env 2>/dev/null || true
  } > "$_rb_tmp" || { rm -f "$_rb_tmp"; die "写 PDG_RESCUE_BIND 失败"; }
  chmod 600 "$_rb_tmp"; mv -f "$_rb_tmp" /etc/privdns-gateway/profile.env || die "落盘 PDG_RESCUE_BIND 失败"
  grep -q "^PDG_RESCUE_BIND=$RESCUE_BIND$" /etc/privdns-gateway/profile.env \
    || die "profile.env 未写入预期的 PDG_RESCUE_BIND"
fi

render(){ sed -e "s|__SERVER_IP__|$SERVER_IP|g" -e "s|__INTERNAL_CIDR__|$INTERNAL_CIDR|g" \
              -e "s|__CERT_DIR__|$CERT_DIR|g"   -e "s|__SSH_PORT__|$SSH_PORT|g" \
              -e "s|__MOSDNS_CACHE__|$MOSDNS_CACHE|g" -e "s|__JOURNALD_MAXUSE__|$JOURNALD_MAXUSE|g" \
              -e "s|__HIJACK_SET_FILE__|$HIJACK_SET_FILE|g" \
              -e "s|__RESCUE_PORT__|$PDG_RESCUE_PORT|g" \
              -e "s|__RESCUE_BIND__|$RESCUE_BIND|g" "$1"; }

render "$REPO_DIR/deploy/mosdns/config.yaml"          > /etc/mosdns/config.yaml
# 模板自带 gfw 那道劫持门; all 模式要去掉它 —— all 的语义是"不是国内就劫持"(排除式),
# 留着门会退化成"只劫持 geosite 策展分类里的域名"。
_mosdns_hijack_shape "$HIJACK_MODE" /etc/mosdns/config.yaml "$HIJACK_SET_FILE" >/dev/null \
  || die "mosdns 劫持形态渲染失败"
# 数据模型(出口 / 分流 / 默认出口的唯一数据源): 已有且有效 → **保留**, 绝不拿模板盖回去。
# 拿模板覆盖等于把用户所有出口与规则换成默认值, 而它恰恰是最难重建的那份数据。
if pdg_model_ok /etc/sing-box/config.json; then
  c_g "保留已有数据模型 /etc/sing-box/config.json($(python3 -c "import json;print(len(json.load(open('/etc/sing-box/config.json'))['outbounds']))" 2>/dev/null || echo '?') 个出口, 出口/分流不动)"
elif [[ -e /etc/sing-box/config.json ]]; then
  die "已有 /etc/sing-box/config.json 解析不出出口 —— 拒绝用模板覆盖它(那会把你的出口与分流换成默认值)。
   先修好或移走它再重装: cp -a /etc/sing-box/config.json /root/config.json.bak && rm /etc/sing-box/config.json"
else
  render "$REPO_DIR/deploy/singbox/config.json.tmpl"  > /etc/sing-box/config.json   # 全新安装才渲染
fi
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
# /etc/sing-box 是本项目的**数据模型**目录(即便 v1.6 起已不装 sing-box 运行时)。落一份归属
# 标记, 卸载 --purge 才知道该删它 —— 里面是出口密码/UUID/节点地址, 留在盘上等于凭据没清。
# 标记落在 /etc/privdns-gateway 下, 已在目录事务台账里(装机失败回滚会连它一起还原)。
pdg_sbmodel_mark_owned || die "写数据模型归属标记失败(磁盘满/只读?)"
[[ -e /etc/nftables.conf.pdg-orig ]] || cp -a /etc/nftables.conf /etc/nftables.conf.pdg-orig 2>/dev/null || true  # 供 uninstall 还原
# 内核后端: 标记(恒 mihomo)+ 防火墙(mihomo REDIRECT 入站变体)+ 初始渲染 mihomo 配置
printf '%s\n' "$CORE" > /etc/privdns-gateway/backend
# 防火墙: **合并**而不是整文件覆盖 —— 用户的 VPN/NAT/转发/开放端口原样保留(与迁移同一实现)。
# iOS 的 GMS 剥离在**渲染出来的块上**做, 不在合并结果上做: 后者会拿正则去扫用户自己的规则行。
_nft_block="$(mktemp)"; _nft_merged="$(mktemp)"
render "$REPO_DIR/deploy/firewall/nftables-mihomo.conf" > "$_nft_block"
if [[ "$PLATFORM" == ios ]]; then
  sed -E -i 's#(tcp dport [{] 53, 80, 81, 443, 853), 5228-5230, 8445 [}] accept#\1, 8445 } accept#' "$_nft_block"
  sed -E -i 's#(tcp dport [{] 80, 443), 5228-5230 [}] redirect#\1 } redirect#' "$_nft_block"
fi
python3 "$REPO_DIR/deploy/bot/nftmerge.py" "$_nft_block" /etc/nftables.conf "$_nft_merged" \
  || { rm -f "$_nft_block" "$_nft_merged"
       die "无法安全合并 /etc/nftables.conf(见上方冲突位置)→ 未改动防火墙。
  请把本项目所需规则手工并入 table inet pdg 后重试, 或先备份并清理冲突配置。"; }
# 用与扫描器同一份解析结果调 nft(PATH 缺 sbin 时不能因此跳过校验 —— 那等于不校验就落盘)
_nft_exe="$(python3 "$_NFTSCAN" --nft-path 2>/dev/null || true)"
[[ -n "$_nft_exe" && -x "$_nft_exe" ]] || _nft_exe=""     # 输出不是可执行文件就当没拿到
if [[ -n "$_nft_exe" ]] && ! "$_nft_exe" -c -f "$_nft_merged" >/dev/null 2>&1; then
  rm -f "$_nft_block" "$_nft_merged"; die "合并后的 nftables 配置校验(nft -c)未过 → 未改动防火墙。"
fi
cp -f "$_nft_merged" /etc/nftables.conf || { rm -f "$_nft_block" "$_nft_merged"; die "写入 /etc/nftables.conf 失败"; }
rm -f "$_nft_block" "$_nft_merged"
install -d -m700 /etc/mihomo
python3 - <<PY
import json, os, sys
sys.path.insert(0, "$REPO_DIR/deploy/bot")
import sb2mihomo
model = json.load(open("/etc/sing-box/config.json"))   # config.json 仍是核无关的数据模型
# WLOC/MITM 的接管域名要一起带上。这些域名的真源是 /etc/mosdns/rules/mitm_hijack.txt(重装
# 会保留它), 但派生出来的 mihomo 配置里那条 MITM-OUT 出站与 gs-loc 路由是**渲染时**加的 ——
# 渲染时不传, 重装完 doctor 立刻报"mihomo 缺 MITM-OUT 出站或 gs-loc 路由", WLOC 静默失效
# (.200 实机重装后就是这样)。域名文件为空 = WLOC 休眠, 那时本来就不该有这条出站。
_mitm = []
try:
    with open("/etc/mosdns/rules/mitm_hijack.txt", encoding="utf-8") as _fh:
        for _l in _fh:
            _l = _l.strip()
            if _l and not _l.startswith("#"):
                _mitm.append(_l.split(":", 1)[1] if _l.startswith("domain:") else _l)
except OSError:
    pass
cfg, _ = sb2mihomo.singbox_to_mihomo(model, redir_port=7893, mitm_domains=_mitm or None)
with open("/etc/mihomo/config.yaml", "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)   # JSON 即合法 YAML
os.chmod("/etc/mihomo/config.yaml", 0o600)
PY
render "$REPO_DIR/deploy/bot/pdg-bot.service"         > /etc/systemd/system/pdg-bot.service
chmod 644 /etc/systemd/system/pdg-bot.service        # 不再含 token (token 在 bot.env)

# token / 允许 id 写入受限的 bot.env (目录 700 / 文件 600), 不进 unit 也不进版本库
install -d -m700 /etc/privdns-gateway
# 已有 token 就保留 —— 重装不该把 Telegram 凭据清掉(非交互重装时 BOT_TOKEN 往往是空的,
# 旧写法会拿空值把它覆盖, 管理 bot 就此失联)。显式传了新 token 才更新。
if [[ -z "${BOT_TOKEN:-}" ]] && pdg_bot_env_ok /etc/privdns-gateway/bot.env; then
  c_g "保留已有 bot.env(Telegram token 与允许 id 不动)"
else
  ( umask 077; printf 'PDG_BOT_TOKEN=%s\nPDG_BOT_ALLOWED=%s\n' "$BOT_TOKEN" "$ALLOWED_IDS" > /etc/privdns-gateway/bot.env )
fi
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
pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service

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
  # 交互暂停确认 A 记录: 撞 EOF/无终端不该触发 errexit → 直接继续(等同回车); Ctrl-C 仍能中止。
  if [[ -z "$NONINT" ]] && { true < /dev/tty; } 2>/dev/null; then
    read -rp "A 记录已指好? 回车继续签发 / Ctrl-C 退出去配 DNS: " _ < /dev/tty || true
  fi
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
# ── 救援平面: 凭据 + unit + 默认启用 ──────────────────────────────────────
# 默认启用是已拍板的方案(T5): 它存在的意义就是"别的都不通时还能进去", 而需要它的那一刻
# 用户往往已经进不去 SSH 了 —— 那时候再让他去开是开不了的。
install -d -m700 "$PDG_RESCUE_DIR"
# ensure: 缺什么补什么, **已有的一律不动** —— 更新时绝不重生成 token 或证书。
if python3 /opt/pdg-bot/rescue_cred.py ensure "${RESCUE_BIND:-}" >/dev/null 2>&1; then
  c_g "救援平面凭据就绪(token + 自签证书)。"
else
  c_y "救援平面凭据生成失败 —— 服务暂不可用, 修好后跑 sudo pdg rescue enable。"
fi
# unit 用模板渲染(端口/绑定地址来自 lib/rescue.sh 与上面探到的内网地址)
render "$REPO_DIR/deploy/rescue/pdg-rescue.socket"  > /etc/systemd/system/pdg-rescue.socket
render "$REPO_DIR/deploy/rescue/pdg-rescue.service" > /etc/systemd/system/pdg-rescue.service
chmod 644 /etc/systemd/system/pdg-rescue.socket /etc/systemd/system/pdg-rescue.service
systemctl daemon-reload
if [[ -n "$RESCUE_BIND" ]]; then
  systemctl enable --now pdg-rescue.socket >/dev/null 2>&1 \
    && c_g "救援平面已启用: https://$RESCUE_BIND:$PDG_RESCUE_PORT/(仅内网卡可达)" \
    || c_y "救援平面 socket 起不来, 装完可用 sudo pdg rescue status 查。"
else
  systemctl enable pdg-rescue.socket >/dev/null 2>&1 || true   # 开机自启, 现在还没地址可绑
fi
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
# 救援平面已启用的机器: 渲染出来的这份配置里**没有**那条带标记的救援放行(模板不含它,
# 它是 enable 时注入的)。直接应用等于把门关上 —— socket 还在监听、防火墙已经不放行, 而
# 下一次 pdg update 的迁移会发现不一致、试图修复、失败之后把整次更新回滚(.200 实机实测)。
# 所以: 启用中就在应用之前把规则补回候选, 一次应用到位, 不留无放行的窗口。
if [[ "$(pdg_profile_get PDG_RESCUE_ENABLED 2>/dev/null || echo)" == 1 && -n "$RESCUE_BIND" ]]; then
  _rc_cand="$(mktemp)"
  if python3 "$REPO_DIR/deploy/bot/rescue_nft.py" "$INTERNAL_CIDR" "$PDG_RESCUE_PORT" \
       "$RESCUE_BIND" < /etc/nftables.conf > "$_rc_cand" 2>/dev/null \
     && nft -c -f "$_rc_cand" >/dev/null 2>&1; then
    cat "$_rc_cand" > /etc/nftables.conf
    c_g "救援放行已随防火墙一起应用(救援平面处于启用状态)"
  else
    c_y "⚠️ 救援放行没能注入防火墙候选 —— 装完请跑 sudo pdg rescue enable 复查。"
  fi
  rm -f "$_rc_cand"
fi
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
