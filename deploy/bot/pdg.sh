#!/usr/bin/env bash
# PrivDNS Gateway 管理命令。直接 `sudo pdg` 进菜单, 或 pdg <子命令>。
#   pdg [menu] | status | update | token | restart | log [n] | uninstall [--purge]
# 设计: 生命周期(装/更新/卸载/token/状态/日志)走这里; 出口/分流/DNS上游 走 Telegram bot。
set -uo pipefail
REPO_URL="https://github.com/misaka-cpu/privdns-gateway.git"
REPO_DIR="/opt/privdns-gateway"
SVC="/etc/systemd/system/pdg-bot.service"
ENVD="/etc/privdns-gateway"
ENVF="$ENVD/bot.env"
# mihomo 路径安全: 面板 UI 在 /etc/sing-box/ui/dist(不在 /etc/mihomo 下), 放行给本脚本的所有 `mihomo -t` 校验。
export SAFE_PATHS="${SAFE_PATHS:-/etc/sing-box/ui/dist}"

c_g(){ echo -e "\033[1;32m$*\033[0m"; }
c_y(){ echo -e "\033[1;33m$*\033[0m"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "请用 root: sudo pdg $*"; exit 1; }; }
# 活动内核后端(mihomo / singbox; 读不到标记默认 singbox)
_pdg_core(){ local b; b=$(cat /etc/privdns-gateway/backend 2>/dev/null); [[ "$b" == mihomo || "$b" == singbox ]] && echo "$b" || echo singbox; }
_pdg_core_svc(){ [[ "$(_pdg_core)" == mihomo ]] && echo mihomo || echo sing-box; }
# 手机平台(ios / android; 读不到默认 android)
_pdg_platform(){ local p; p=$(cat /etc/privdns-gateway/platform 2>/dev/null); [[ "$p" == ios || "$p" == android ]] && echo "$p" || echo android; }

# 串行化"会写配置/重启服务"的操作(update/rollback/snapshot), 防 bot 更新按钮与命令行并发。
# 嵌套调用(update→snapshot)只锁一次。read-only 操作(status/doctor/report/log)不加锁。
LOCK="/run/privdns-gateway.lock"
PDG_LOCKED=""
_lock(){
  [[ -n "$PDG_LOCKED" ]] && return 0
  exec 9>"$LOCK" 2>/dev/null || return 0
  flock -n 9 || { echo "⛔ 已有 pdg 操作在运行, 请稍后再试 (锁: $LOCK)"; exit 1; }
  PDG_LOCKED=1
}

# ── 克制版低内存模式 ─────────────────────────────────────────────────────────
# PDG_LOWMEM=auto(默认)|1|0。MemTotal ≤ 1300 MiB 判低内存。只调确认安全的项:
# mosdns cache(8192/2048)+ journald SystemMaxUse(50M/20M)。不动 sysctl/swap/MemoryMax/GOMEMLIMIT。
# 决定持久化到 profile.env; auto 时 profile 已有就沿用(不每次更新改变用户已定模式)。
LOWMEM_THRESHOLD_KB=1331200      # 1300 MiB
PROFILE_ENV="${PDG_PROFILE:-/etc/privdns-gateway/profile.env}"
_mem_total_kb(){ sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' "${PDG_MEMINFO:-/proc/meminfo}" 2>/dev/null; }
_profile_val(){ [[ -f "$PROFILE_ENV" ]] && sed -n 's/^PDG_LOWMEM=//p' "$PROFILE_ENV" | tail -1; }
pdg_cache_size(){ [[ "$1" == 1 ]] && echo 2048 || echo 8192; }
pdg_journald_max(){ [[ "$1" == 1 ]] && echo 20M || echo 50M; }

# 确保 journald drop-in 里 key= 的"未注释有效值"==val。返回: 1=已是目标(未改); 0=已改; 2=写入失败。
# 注释行不算数(避免"假成功/被误判已存在"); 追加时补 [Journal] 段与末尾换行(处理零字节/无换行文件)。
_journald_set_key(){
  local file="$1" key="$2" val="$3" cur
  cur="$(sed -n -E "s/^[[:space:]]*${key}=([^[:space:]#]+).*/\1/p" "$file" 2>/dev/null | tail -1)"
  [[ "$cur" == "$val" ]] && return 1
  if grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null; then       # 有未注释有效行 → 替换
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$file" 2>/dev/null || return 2
  else                                                               # 无有效行 → 追加(补段头/换行)
    if [[ -s "$file" && "$(tail -c1 "$file" 2>/dev/null | wc -l)" -eq 0 ]]; then
      printf '\n' >> "$file" 2>/dev/null || return 2                 # 末尾无换行 → 先补, 避免 [Journal]Key 拼接
    fi
    # 需"独立"段头(整行=[Journal]); 拼接畸形行 [Journal]Key= 不算, 缺则补一个独立段头
    grep -qxE '\[Journal\][[:space:]]*' "$file" 2>/dev/null || printf '[Journal]\n' >> "$file" 2>/dev/null || return 2
    printf '%s=%s\n' "$key" "$val" >> "$file" 2>/dev/null || return 2
  fi
  return 0
}

# 解析并持久化内存模式, 回显 1(低内存)/0(标准)。显式 1/0 优先; auto 时 profile 已有沿用, 否则按内存检测。
pdg_lowmem_resolve(){
  local want="${PDG_LOWMEM:-auto}" cur res mt; cur="$(_profile_val)"
  case "$want" in
    1) res=1;;
    0) res=0;;
    *) if [[ "$cur" == 0 || "$cur" == 1 ]]; then res="$cur"
       else mt="$(_mem_total_kb)"; if [[ -n "$mt" && "$mt" -le "$LOWMEM_THRESHOLD_KB" ]]; then res=1; else res=0; fi; fi;;
  esac
  mkdir -p "$(dirname "$PROFILE_ENV")" 2>/dev/null || true
  printf 'PDG_LOWMEM=%s\n' "$res" > "$PROFILE_ENV" 2>/dev/null || true
  echo "$res"
}

# 只读回显当前模式(profile 有则用之, 无则按内存推断; 不写盘)。供 status/doctor。
pdg_lowmem_current(){
  local cur mt; cur="$(_profile_val)"
  if [[ "$cur" == 0 || "$cur" == 1 ]]; then echo "$cur"; return; fi
  mt="$(_mem_total_kb)"; if [[ -n "$mt" && "$mt" -le "$LOWMEM_THRESHOLD_KB" ]]; then echo 1; else echo 0; fi
}

# mosdns lazy_cache size 调到目标。失败只影响自己(return 非0), 绝不 exit 调用方 → 不连累 journald 修复。
# 生成到同目录临时文件 + 判退出码/复核/原子替换, 只有真改成功才重启; 任何失败都不改原文件、不重启。
_migrate_mosdns_cache(){
  local mos="$1" cache="$2"
  [[ -f "$mos" ]] && grep -q 'tag: lazy_cache' "$mos" || return 0
  local cur; cur="$(awk '/tag: lazy_cache/{f=1} f&&/size:/{print $2; exit}' "$mos")"
  [[ -n "$cur" && "$cur" != "$cache" ]] || return 0
  local bak tmp; bak="$mos.prelowmem.$(date +%s)"; tmp="$mos.lowmem.$$.tmp"
  cp -a "$mos" "$bak" 2>/dev/null && cmp -s "$mos" "$bak" || return 1
  if ! python3 - "$mos" "$tmp" "$cache" <<'PY'
import sys, re
src, dst, cache = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
i = s.index('tag: lazy_cache'); head, tail = s[:i], s[i:]      # 只改 lazy_cache 块里第一处 size:
tail, n = re.subn(r'(size:\s*)\d+', r'\g<1>' + cache, tail, count=1)
assert n == 1, 'lazy_cache 块内未找到 size 行'
open(dst, 'w').write(head + tail)
PY
  then c_y "  生成 mosdns cache 失败 → 不改、不重启。"; rm -f "$tmp"; return 1; fi
  if ! grep -qE "size:[[:space:]]*$cache\b" "$tmp"; then
    c_y "  生成结果未含目标 cache size → 不改、不重启。"; rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$mos" 2>/dev/null; then
    c_y "  原子替换 mosdns 配置失败 → 清理临时文件, 不重启。"; rm -f "$tmp"; return 1; fi
  systemctl restart mosdns 2>/dev/null; sleep 1
  if [[ "$(systemctl is-active mosdns 2>/dev/null)" != active ]]; then
    c_y "  mosdns cache 调整后重启失败 → 还原。"; cp -a "$bak" "$mos" 2>/dev/null; systemctl restart mosdns 2>/dev/null; return 1
  fi
  c_g "  mosdns cache size → $cache"
}

# journald 封顶: 清错目录残留 + 正确目录 System/Runtime 都封到 jmax。写失败/复核不符/重启失败均 warn(不假绿)。
# 我们的 drop-in 是项目独占的; 文件缺失或"没有独立有效 [Journal] 段头"(含 v1.2.3 拼接畸形 [Journal]Key=、
# 只有 key、零字节)一律按标准内容重建, 避免非法段头修不掉。
_migrate_journald_cap(){
  local jrnl="$1" jrnl_legacy="$2" jmax="$3"
  [[ "$jrnl_legacy" != "$jrnl" && -f "$jrnl_legacy" ]] && rm -f "$jrnl_legacy"
  if [[ ! -f "$jrnl" ]] || ! grep -qxE '\[Journal\][[:space:]]*' "$jrnl" 2>/dev/null; then
    if mkdir -p "$(dirname "$jrnl")" 2>/dev/null \
       && printf '[Journal]\nSystemMaxUse=%s\nRuntimeMaxUse=%s\n' "$jmax" "$jmax" > "$jrnl" 2>/dev/null; then
      if systemctl restart systemd-journald 2>/dev/null; then c_g "  journald 封顶(重建)→ $jmax(System+Runtime)"
      else c_y "  journald 封顶已写入但 journald 重启失败 → 重启系统后生效。"; fi
    else
      c_y "  journald 封顶写入失败(目录只读?)→ 未生效, 请检查 $jrnl。"
    fi
    return 0
  fi
  # 有独立合法段头 → 逐 key 设置(保留文件其它内容)
  local r1 r2; _journald_set_key "$jrnl" SystemMaxUse "$jmax"; r1=$?; _journald_set_key "$jrnl" RuntimeMaxUse "$jmax"; r2=$?
  if [[ "$r1" == 2 || "$r2" == 2 ]]; then
    c_y "  journald 封顶写入失败(目录只读?)→ 未完全生效, 请检查 $jrnl。"; return 0
  fi
  [[ "$r1" == 0 || "$r2" == 0 ]] || return 0     # 两个都"已是目标"(未改)→ 幂等, 无需重启
  local rok=1; systemctl restart systemd-journald 2>/dev/null || rok=0
  local es rs
  es="$(sed -n -E 's/^[[:space:]]*SystemMaxUse=([^[:space:]#]+).*/\1/p'  "$jrnl" | tail -1)"
  rs="$(sed -n -E 's/^[[:space:]]*RuntimeMaxUse=([^[:space:]#]+).*/\1/p' "$jrnl" | tail -1)"
  if [[ "$es" == "$jmax" && "$rs" == "$jmax" && "$rok" == 1 ]]; then
    c_g "  journald 封顶 → $jmax(System+Runtime)"
  elif [[ "$es" == "$jmax" && "$rs" == "$jmax" ]]; then
    c_y "  journald 封顶已写入但 journald 重启失败 → 重启系统后生效。"
  else
    c_y "  journald 封顶复核异常(System=${es:-空} Runtime=${rs:-空})。"
  fi
}

# 老装迁移: 按 profile(内存模式)把 mosdns cache size / journald 封顶调到目标。幂等。
# 两步互相独立: mosdns 调整失败也不影响 journald 修复(反之亦然)。
# shellcheck disable=SC2120  # $1/$2/$3 仅测试注入
migrate_lowmem(){
  local mos="${1:-/etc/mosdns/config.yaml}" jrnl="${2:-/etc/systemd/journald.conf.d/50-pdg.conf}"
  local jrnl_legacy="${3:-/etc/systemd/system/journald.conf.d/50-pdg.conf}"   # 历史装错目录
  local mode cache jmax; mode="$(pdg_lowmem_resolve)"; cache="$(pdg_cache_size "$mode")"; jmax="$(pdg_journald_max "$mode")"
  _migrate_mosdns_cache "$mos" "$cache" || true       # mosdns 失败不影响下面 journald
  _migrate_journald_cap "$jrnl" "$jrnl_legacy" "$jmax"
}

pdg_fetch_release_tags(){
  local dir="${1:-$REPO_DIR}"
  git -C "$dir" fetch -q --tags origin main || return 1
  if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    git -C "$dir" fetch -q --unshallow --tags origin main || return 1
  fi
}

cmd_status(){
  c_g "== 服务 =="
  local core; core="$(_pdg_core)"
  for s in mosdns "$(_pdg_core_svc)" pdg-bot pdg-probe81; do
    printf "  %-12s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  echo "  timer        $(systemctl is-active pdg-rules-update.timer 2>/dev/null)"
  echo "  内核后端     $core$([[ "$core" == mihomo ]] && echo "(可更新, 无版本天花板)" || echo "(1.12.x 钉死)")"
  echo "  手机平台     $(_pdg_platform)"
  echo "  DoT 域名     $(cat /opt/pdg-bot/dot-domain 2>/dev/null || echo ?)"
  local ports p9090="9090(local clash_api)"
  if jq -e '.experimental.clash_api as $c | $c.external_controller == "0.0.0.0:9090" and $c.external_ui == "/etc/sing-box/ui/dist" and (($c.secret // "") | length > 0)' /etc/sing-box/config.json >/dev/null 2>&1; then
    p9090="9090(panel临时内网)"
  fi
  # mihomo 模式 443/80 由 nft 转到 7893(redir), 故把 7893 一并纳入端口展示
  ports=$(ss -lntu 2>/dev/null | grep -oE ':(53|80|81|443|853|7893|8445|9090)\b' | sed 's/^://' | sort -u | sed "s|^9090$|$p9090|" | tr '\n' ' ')
  echo "  监听端口     $ports"
  if [[ -d "$REPO_DIR/.git" ]]; then echo "  代码版本     $(git -C "$REPO_DIR" describe --tags --always 2>/dev/null)"; fi
  local lm cache; lm="$(pdg_lowmem_current)"; cache="$(awk '/tag: lazy_cache/{f=1} f&&/size:/{print $2; exit}' /etc/mosdns/config.yaml 2>/dev/null)"
  echo "  内存模式     $([[ "$lm" == 1 ]] && echo 低内存 || echo 标准)(mosdns cache=${cache:-?})"
}

cmd_doctor(){ python3 /opt/pdg-bot/doctor.py "$@"; }

# 旧装把 token 写在 unit 的 Environment= 里 → 迁到 bot.env(600), unit 改用 EnvironmentFile。幂等。
migrate_botenv(){
  [[ -f "$SVC" ]] || return 0
  local tok allow
  tok=$(grep -oP '^Environment=PDG_BOT_TOKEN=\K.*'   "$SVC" | head -1)
  allow=$(grep -oP '^Environment=PDG_BOT_ALLOWED=\K.*' "$SVC" | head -1)
  install -d -m700 "$ENVD"
  if [[ ! -f "$ENVF" && -n "$tok" ]]; then
    ( umask 077; printf 'PDG_BOT_TOKEN=%s\nPDG_BOT_ALLOWED=%s\n' "$tok" "$allow" > "$ENVF" )
    chmod 600 "$ENVF"
    c_g "已把 token 从 unit 迁移到 $ENVF (600)"
  fi
  grep -qE '^Environment=PDG_BOT_(TOKEN|ALLOWED)=' "$SVC" \
    && sed -i -E '/^Environment=PDG_BOT_(TOKEN|ALLOWED)=/d' "$SVC"
  grep -q '^EnvironmentFile=-\?/etc/privdns-gateway/bot.env' "$SVC" \
    || sed -i -E 's#^\[Service\]#[Service]\nEnvironmentFile=-/etc/privdns-gateway/bot.env#' "$SVC"
}

# 判断旧 /etc/nftables.conf 是不是本项目"原装"防火墙(无用户自定义)。
# 严格白名单(默认拒绝): 去注释/空行、收紧空白后, **每一行**都必须匹配下面某条已知原装规则;
# 只要出现一行不认识的(自定义来源/端口/动作/链/表等)就判"非原装" → 不自动重建, 以免静默丢规则。
# 白名单用正则, 因此兼容历史变体: forward/output 单行或多行写法、不同年代的内网端口子集
# ({53,80,81,443} → +853 → +8445)都算原装。
_fw_is_stock(){
  local f="$1" port="$2" cidr="$3" line norm matched pat
  local cre="${cidr//./\\.}"               # 内网段做正则(转义点)
  local pset='(53|80|81|443|853|8445)'     # 内网放行端口集(任意子集/顺序)
  local -a pats=(
    '^flush ruleset$'
    '^table inet filter [{]$'
    '^chain (input|forward|output) [{]$'
    '^chain (forward|output) [{] type filter hook (forward|output) priority 0; policy accept; [}]$'
    '^type filter hook input priority 0; policy drop;$'
    '^type filter hook (forward|output) priority 0; policy accept;$'
    '^iif "lo" accept$'
    '^ct state established,related accept$'
    "^tcp dport [{] ${port}(, 853)? [}] accept$"
    "^tcp dport ${port} accept$"
    "^ip saddr ${cre} tcp dport [{] ${pset}(, ${pset})* [}] accept$"
    "^ip saddr ${cre} udp dport [{] (53|443)(, (53|443))* [}] accept$"
    "^ip saddr ${cre} udp dport (53|443) accept$"
    "^ip saddr ${cre} udp dport 443 reject$"
    '^ip protocol icmp accept$'
    '^ip6 nexthdr icmpv6 accept$'
    '^[}]$'
  )
  while IFS= read -r line; do
    norm="${line%%#*}"                                                  # 去行内/整行注释
    norm="$(printf '%s' "$norm" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//')"  # 收紧空白+去首尾
    [[ -z "$norm" ]] && continue
    matched=0
    for pat in "${pats[@]}"; do printf '%s' "$norm" | grep -qE "$pat" && { matched=1; break; }; done
    [[ "$matched" == 1 ]] || return 1                                   # 出现白名单外的行 → 非原装
  done < "$f"
  return 0
}

# 旧装防火墙迁移: 把旧的 `flush ruleset` + `table inet filter` 迁到独立表 `inet pdg`。幂等。
# 不迁移则: 证书续期 pre-hook 进不了 inet pdg 开不了 80、doctor 读不到防火墙、且仍会 flush 掉别的表。
# 安全做法: 解析旧配置里的 SSH 端口/内网段 → 渲染新模板 → nft -c 校验 → 备份 → nft -f → 删旧表。
# 全程 SSH 不断(established + 新表放行 SSH; 加载新表时旧 inet filter 仍在 → 双重放行)。
migrate_firewall_to_pdg(){
  local f=/etc/nftables.conf
  [[ -f "$f" ]] || return 0
  # 已是新表(有 inet pdg 且无 inet filter)→ 无需迁移
  grep -q 'table inet pdg' "$f" && ! grep -q 'table inet filter' "$f" && return 0
  # 必须看起来像本项目的防火墙(含我们放行的端口特征), 否则不乱动用户的自定义规则
  grep -qE '\b(853|8445)\b' "$f" || return 0
  local port cidr tmp; tmp="$(mktemp)"
  port=$(grep -E 'tcp dport.*accept' "$f" | grep -v saddr | grep -oE '[0-9]+' | head -1)
  cidr=$(grep -oE 'ip saddr [0-9./]+' "$f" | head -1 | awk '{print $3}')
  if [[ -z "$port" || -z "$cidr" ]]; then
    c_y "检测到旧防火墙但解析不出 SSH端口/内网段, 跳过自动迁移(可手动重渲染)。"; rm -f "$tmp"; return 0
  fi
  # 迁移=用标准模板重建, 只保留 SSH端口+内网段; 若旧配置里有自定义端口/规则/额外表,
  # 重建会静默丢掉它们 → 检测到非原装就不自动迁移, 让用户手动并入(旧配置原样留在 $f)。
  if ! _fw_is_stock "$f" "$port" "$cidr"; then
    c_y "检测到旧防火墙含自定义规则/额外端口/额外表 → 不自动迁移(避免静默丢失你的规则)。"
    c_y "  迁移会用标准模板重建(只保留 SSH=$port + 内网段=$cidr)。请任选其一:"
    c_y "   • 把自定义规则并进 deploy/firewall/nftables.conf 同风格后手动 nft -f; 或"
    c_y "   • sudo pdg migrate-fw 先迁标准部分, 再把自定义规则补到 inet pdg。"
    c_y "  现状: 旧 inet filter 不动(证书 hook/doctor 已兼容它, 不迁也能正常用)。"
    rm -f "$tmp"; return 0
  fi
  c_g "检测到旧版(原装)防火墙 → 迁移到独立表 inet pdg (SSH=$port, 内网段=$cidr)…"
  sed -e "s/__SSH_PORT__/$port/g" -e "s#__INTERNAL_CIDR__#$cidr#g" \
      "$REPO_DIR/deploy/firewall/nftables.conf" > "$tmp"
  if ! nft -c -f "$tmp" >/dev/null 2>&1; then
    c_y "  新规则 nft -c 校验未过, 保留旧防火墙不动。"; rm -f "$tmp"; return 0
  fi
  # 必须先确认备份完整(cmp 逐字节相同)才敢覆盖现网配置; 磁盘满/cp 失败时中止, 不动现网。
  local bak; bak="$f.prepdg.$(date +%s)"
  if ! cp -a "$f" "$bak" 2>/dev/null || ! cmp -s "$f" "$bak"; then
    c_y "  备份 $f 失败/不完整(磁盘满?), 中止迁移、不改动现网。"; rm -f "$tmp" "$bak" 2>/dev/null; return 0
  fi
  # 写新配置; 若写失败/不完整(磁盘满), 用刚验证过的备份还原, 不动内核(尚未 nft -f)。
  if ! cp "$tmp" "$f" 2>/dev/null || ! cmp -s "$tmp" "$f"; then
    c_y "  写入新配置失败/不完整(磁盘满?), 已还原备份、不改动现网。"; cp -a "$bak" "$f" 2>/dev/null; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  # 关键: 只有"新表加载成功且 inet pdg 确实在内核里"才删旧表; 否则绝不删 inet filter。
  # nft -f 是原子的, 失败则内核不变(旧 inet filter 仍在生效), 只需把 on-disk 配置还原回旧的。
  if nft -f "$f" 2>/dev/null && nft list table inet pdg >/dev/null 2>&1; then
    nft delete table inet filter 2>/dev/null || true   # 确认新表已载入, 再删旧表, 只留 inet pdg
    c_g "  ✅ 已迁移为 inet pdg。"
  else
    cp -a "$bak" "$f" 2>/dev/null                       # 还原 on-disk 配置=旧(内核里旧表仍在)
    c_y "  ⚠️ 新规则加载失败 → 保留旧防火墙、未删 inet filter、配置已还原(防火墙未中断)。"
  fi
}

# 给 /etc/mosdns 里"缺 concurrent"的 forward args 行补上(单上游=1, 多上游=2)。幂等。读 $1 → stdout。
# (mosdns 默认 concurrent=1=随机选1个不故障转移; 单上游配 2 会把同一台并发查两次, 故按上游数定。)
_mosdns_add_concurrent(){
  awk '
    /args: \{ upstreams:/ {
      n = gsub(/addr:/, "addr:")        # 数本行上游个数
      c = (n <= 1) ? 1 : 2
      sub(/args: \{ upstreams:/, "args: { concurrent: " c ", upstreams:")
    }
    { print }
  ' "$1"
}

# 旧装迁移: 老的 /etc/mosdns/config.yaml 的 forward 块没有 concurrent(=默认随机单上游、不故障转移)。
# pdg update 不重渲染该文件, 故在此幂等补上(不动用户现有上游/顺序)。
migrate_mosdns_concurrent(){
  local f=/etc/mosdns/config.yaml
  [[ -f "$f" ]] || return 0
  grep -qE 'args: [{] upstreams:' "$f" || return 0     # 没有"缺 concurrent"的行 → 无需迁移
  c_g "检测到 mosdns forward 块缺 concurrent → 补上(单上游=1/多上游=2, 不动你的上游)…"
  local bak; bak="$f.preconc.$(date +%s)"
  if ! cp -a "$f" "$bak" 2>/dev/null || ! cmp -s "$f" "$bak"; then
    c_y "  备份失败(磁盘满?), 中止、不动现网。"; rm -f "$bak" 2>/dev/null; return 0
  fi
  if ! _mosdns_add_concurrent "$f" > "$f.tmp" 2>/dev/null || ! grep -q concurrent "$f.tmp"; then
    c_y "  生成失败, 中止。"; rm -f "$f.tmp"; return 0
  fi
  mv "$f.tmp" "$f"
  systemctl restart mosdns 2>/dev/null; sleep 1
  if [[ "$(systemctl is-active mosdns 2>/dev/null)" == active ]]; then
    c_g "  ✅ 已补 concurrent。"
  else
    c_y "  ⚠️ mosdns 重启失败 → 还原。"; cp -a "$bak" "$f" 2>/dev/null; systemctl restart mosdns 2>/dev/null
  fi
}

# 旧装迁移: 给 mosdns 补"WDA/流媒体解锁支"(常驻、平时休眠)。pdg update 不重渲染 config, 故在此幂等补。
# 加 unlock_upstream(22.22.22.22) + geosite_unlock(读 unlock.txt) 两个插件 + main_sequence 一条
# "本机查询命中解锁域名→解锁DNS"的支(带 jump has_resp 防被 remote_upstream 覆盖)+ 建空 unlock.txt。
# 空 unlock.txt = 不命中任何域名 = 休眠, 不改变现有行为; bot『🔓 解锁走 WDA』开启时才填充。
migrate_mosdns_unlock(){
  local f=/etc/mosdns/config.yaml
  [[ -f "$f" ]] || return 0
  grep -q 'unlock_upstream' "$f" && return 0                   # 已有 → 跳过
  grep -q 'tag: main_sequence' "$f" || return 0               # 不是本项目的 mosdns 配置 → 不动
  c_g "给 mosdns 补 WDA 解锁支(常驻休眠, 不改现有行为)…"
  local bak; bak="$f.preunlock.$(date +%s)"
  if ! cp -a "$f" "$bak" 2>/dev/null || ! cmp -s "$f" "$bak"; then
    c_y "  备份失败, 中止。"; rm -f "$bak" 2>/dev/null; return 0
  fi
  python3 - "$f" <<'PY' || { c_y "  生成失败, 中止(已留备份)。"; return 0; }
import sys
f=sys.argv[1]; s=open(f).read()
plug='''  - tag: unlock_upstream
    type: forward
    args: { concurrent: 1, upstreams: [ {addr: "udp://22.22.22.22"} ] }
  - tag: geosite_unlock
    type: domain_set
    args: { files: ["/etc/mosdns/rules/unlock.txt"] }
  - tag: geosite_cn'''
assert s.count('  - tag: geosite_cn')==1
s=s.replace('  - tag: geosite_cn', plug, 1)
old='''      - matches: client_ip $npn_clients
        exec: goto internal_sequence
      - exec: $remote_upstream'''
new='''      - matches: client_ip $npn_clients
        exec: goto internal_sequence
      - matches: qname $geosite_unlock
        exec: $unlock_upstream
      - exec: jump has_resp
      - exec: $remote_upstream'''
assert old in s
open(f,'w').write(s.replace(old,new,1))
PY
  [[ -e /etc/mosdns/rules/unlock.txt ]] || : > /etc/mosdns/rules/unlock.txt
  systemctl restart mosdns 2>/dev/null; sleep 1
  if [[ "$(systemctl is-active mosdns 2>/dev/null)" == active ]]; then
    c_g "  ✅ 已补解锁支(休眠)。bot『🌐 DNS 上游→🔓 解锁走 WDA』可启用。"
  else
    c_y "  ⚠️ mosdns 重启失败 → 还原。"; cp -a "$bak" "$f" 2>/dev/null; systemctl restart mosdns 2>/dev/null
  fi
}

# 老装迁移: 给 mosdns 补"单客户端 QPS 兜底"(rate_limiter)。幂等。
# 只对本项目形态的 config(有 internal_sequence + npn_clients)做定点插入: 加 client_limiter 插件,
# 并在 internal_sequence 缓存查询之前插一条 "!$client_limiter → reject 5"。高度自定义的配置不动(doctor 会 warn)。
# 只改这两处, 不碰用户的上游/其它内容; check(重启+active)失败自动还原。$1 可指定文件(供测试)。
# shellcheck disable=SC2120  # $1 仅测试注入, 生产调用不传参
migrate_mosdns_ratelimit(){
  local f="${1:-/etc/mosdns/config.yaml}"
  [[ -f "$f" ]] || return 0
  grep -q 'client_limiter' "$f" && return 0                       # 已有 → 幂等退出
  grep -q 'tag: internal_sequence' "$f" && grep -q 'tag: npn_clients' "$f" || return 0   # 非本项目形态 → 不动
  grep -qE '^\s+- exec: \$lazy_cache' "$f" || return 0            # 缺缓存锚点 → 不动(交 doctor warn)
  c_g "给 mosdns 补单客户端 QPS 兜底(rate_limiter, 平时无感)…"
  local bak; bak="$f.preratelimit.$(date +%s)"
  if ! cp -a "$f" "$bak" 2>/dev/null || ! cmp -s "$f" "$bak"; then
    c_y "  备份失败(磁盘满?), 中止、不动现网。"; rm -f "$bak" 2>/dev/null; return 0
  fi
  if ! python3 - "$f" <<'PY'
import sys
f=sys.argv[1]; s=open(f).read()
plug='''  - tag: client_limiter
    type: rate_limiter
    args: { qps: 200, burst: 400, mask4: 32, mask6: 128 }
  - tag: internal_sequence'''
assert s.count('  - tag: internal_sequence')==1, 'internal_sequence 锚点不唯一'
s=s.replace('  - tag: internal_sequence', plug, 1)
step='''      - matches: "!$client_limiter"
        exec: reject 5
      - exec: $lazy_cache'''
assert s.count('      - exec: $lazy_cache')==1, 'lazy_cache 锚点不唯一'
s=s.replace('      - exec: $lazy_cache', step, 1)
open(f,'w').write(s)
PY
  then c_y "  生成失败 → 还原。"; cp -a "$bak" "$f"; return 0; fi
  systemctl restart mosdns 2>/dev/null; sleep 1
  if [[ "$(systemctl is-active mosdns 2>/dev/null)" == active ]]; then
    c_g "  ✅ 已补 client_limiter。"
  else
    c_y "  ⚠️ mosdns 重启失败 → 还原。"; cp -a "$bak" "$f" 2>/dev/null; systemctl restart mosdns 2>/dev/null
  fi
}

# 老装迁移: sing-box 补 5228-5230 direct 嗅探入站(GMS/FCM 推送端口 mtalk.google.com)。幂等。
# 不补则被 DNS 劫持的 mtalk 只能靠客户端回落 443, 回落慢的手机表现为"Google 服务连不上"。
# check 不过/起不来自动还原。$1 可指定文件(供测试), 默认 /etc/sing-box/config.json。
# shellcheck disable=SC2120  # $1 仅测试注入, 生产调用不传参
migrate_singbox_gms(){
  local f="${1:-/etc/sing-box/config.json}"
  [[ -f "$f" ]] || return 0
  grep -q '"listen_port": 5228' "$f" && return 0              # 已有 → 幂等退出
  grep -q '"sniff_override_destination"' "$f" || return 0     # 不是本项目形态的配置 → 不动
  command -v sing-box >/dev/null || return 0
  c_g "检测到 sing-box 缺 GMS 推送入站 → 补 5228-5230 嗅探入站…"
  local bak; bak="$f.pregms.$(date +%s)"
  if ! cp -a "$f" "$bak" 2>/dev/null || ! cmp -s "$f" "$bak"; then
    c_y "  备份失败(磁盘满?), 中止、不动现网。"; rm -f "$bak" 2>/dev/null; return 0
  fi
  if ! python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
ins = c.get("inbounds", [])
idx = next((n + 1 for n, i in enumerate(ins) if i.get("listen_port") == 80),
           next((n + 1 for n, i in enumerate(ins) if i.get("listen_port") == 443), len(ins)))
for off, port in enumerate((5228, 5229, 5230)):
    ins.insert(idx + off, {"type": "direct", "tag": "in-gms-%d" % port, "network": "tcp",
                           "listen": "0.0.0.0", "listen_port": port,
                           "sniff": True, "sniff_override_destination": True, "sniff_timeout": "300ms"})
c["inbounds"] = ins
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
PY
  then c_y "  生成失败 → 还原。"; cp -a "$bak" "$f"; return 0; fi
  if ! sing-box check -c "$f" >/dev/null 2>&1; then
    c_y "  sing-box check 未过 → 还原、不重启。"; cp -a "$bak" "$f"; return 0
  fi
  systemctl reset-failed sing-box 2>/dev/null; systemctl restart sing-box 2>/dev/null; sleep 2
  if [[ "$(systemctl is-active sing-box 2>/dev/null)" == active ]]; then
    c_g "  ✅ 已补 GMS 入站(5228-5230)。"
  else
    c_y "  ⚠️ sing-box 重启失败 → 还原。"; cp -a "$bak" "$f"
    systemctl reset-failed sing-box 2>/dev/null; systemctl restart sing-box 2>/dev/null
  fi
}

# 老装迁移: 防火墙内网放行集补 5228-5230(配合上面的 sing-box 入站)。幂等。
# 只动"原装形态"的那一行(严格匹配现行端口集); 自定义端口集不碰, 提示手动加。
# $1 可指定文件(供测试), 默认 /etc/nftables.conf; 测试时 nft 可用函数打桩。
# shellcheck disable=SC2120  # $1 仅测试注入, 生产调用不传参
migrate_fw_gms(){
  local f="${1:-/etc/nftables.conf}"
  [[ -f "$f" ]] || return 0
  grep -q 'table inet pdg' "$f" || return 0                   # 未迁到 inet pdg 的先走 migrate_firewall_to_pdg, 下次再补
  grep -qE 'tcp dport [{][^}]*5228' "$f" && return 0          # 已有 → 幂等退出
  if ! grep -qE 'ip saddr [0-9./]+ tcp dport [{] 53, 80, 81, 443, 853, 8445 [}] accept' "$f"; then
    c_y "防火墙端口集非原装形态, 不自动加 GMS 推送端口。可手动把 5228-5230 加进内网 tcp 放行集。"
    return 0
  fi
  c_g "检测到防火墙缺 GMS 推送端口 → 内网放行集补 5228-5230…"
  local bak; bak="$f.pregms.$(date +%s)"
  if ! cp -a "$f" "$bak" 2>/dev/null || ! cmp -s "$f" "$bak"; then
    c_y "  备份失败(磁盘满?), 中止、不动现网。"; rm -f "$bak" 2>/dev/null; return 0
  fi
  sed -E -i 's#(ip saddr [0-9./]+ tcp dport [{] 53, 80, 81, 443, 853), 8445 [}] accept#\1, 5228-5230, 8445 } accept#' "$f"
  if ! grep -qE 'tcp dport [{][^}]*5228-5230' "$f"; then
    c_y "  改写未生效 → 还原。"; cp -a "$bak" "$f"; return 0
  fi
  if ! nft -c -f "$f" >/dev/null 2>&1; then
    c_y "  nft -c 校验未过 → 还原、内核未动。"; cp -a "$bak" "$f"; return 0
  fi
  if nft -f "$f" 2>/dev/null; then
    c_g "  ✅ 已放行 5228-5230(仅内网卡来源)。"
  else
    c_y "  ⚠️ 加载失败 → 还原配置(内核里旧规则仍在生效)。"; cp -a "$bak" "$f"
  fi
}

# 返回一个已创建的非空临时目录；失败不输出路径。供 snapshot/rollback 共用，避免空路径退化到 /etc。
_pdg_mktemp_dir(){
  local d=""
  d="$(mktemp -d)" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  printf '%s\n' "$d"
}

# 按原归档成员清单把已验证临时树落到目标根；不递归顶层隐式父目录，避免误改 /etc、/opt 元数据。
_pdg_apply_snapshot_tree(){
  local tree="$1" members="$2" dest="$3"
  [[ -d "$tree" && -s "$members" && -d "$dest" ]] || return 1
  (
    set -o pipefail
    tar --no-recursion -cf - -C "$tree" -T "$members" 2>/dev/null \
      | tar xpf - -C "$dest" 2>/dev/null
  )
}

# 面板临时态净化(与 bot backup_blob/restore_from 对称): 快照/回滚不持久化面板的公网监听+密钥+UI。
# 只认"本项目受管开启态"(0.0.0.0:9090 + 项目 UI 目录 + 有 secret + 项目下载地址); 自定义 clash_api 不动。
_sb_panel_managed_on(){
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.experimental.clash_api as $c | ($c.external_controller=="0.0.0.0:9090")
         and ($c.external_ui=="/etc/sing-box/ui/dist") and ((($c.secret) // "")|length>0)
         and (($c.external_ui_download_url // "") as $d |
              if ($d|type)!="string" then false
              else ($d=="" or ($d|test("^https://github[.]com/Zephyruso/zashboard/releases/download/[^/]+/dist-no-fonts[.]zip$"))) end)' \
      "$1" >/dev/null 2>&1
}
# 生成关闭态净化副本；调用方只传临时目标。成功副本固定 600，失败不留半成品。
_sb_write_sanitized(){
  local src="$1" dst="$2"
  [[ "$src" != "$dst" ]] || return 1
  if jq '.experimental.clash_api={external_controller:"127.0.0.1:9090"}' "$src" > "$dst" 2>/dev/null \
     && [[ -s "$dst" ]] && chmod 600 "$dst"; then
    return 0
  fi
  rm -f "$dst"; return 1
}
# 把受管开启态原子净化为关闭态(clash_api 只留本地控制器)。改了返回 0, 未改/失败非 0。
_sb_sanitize_panel(){
  _sb_panel_managed_on "$1" || return 1
  local dir base t=""
  dir="$(dirname -- "$1")"; base="$(basename -- "$1")"
  t="$(mktemp "$dir/.${base}.pdg.XXXXXX")" || return 2
  if _sb_write_sanitized "$1" "$t" && mv -f -- "$t" "$1"; then
    return 0
  fi
  rm -f "$t"; return 2
}

SNAP_DIR="/var/lib/privdns-gateway/backups"

cmd_snapshot(){
  need_root snapshot; _lock
  local ts d; ts=$(date +%Y%m%d-%H%M%S); d="$SNAP_DIR/$ts"
  install -d -m700 "$d"
  # 整机配置 + 防火墙 + bot.env(含 token)+ service + journald 封顶(含历史错路径)(相对 / 打包, 回滚 -C / 解开)
  # 只打包"存在的"路径 —— 历史错路径可能已被迁移清掉, 无条件列进去会让 tar 报 Cannot stat 并返 2。
  local cand=(etc/mosdns etc/sing-box etc/mihomo opt/pdg-bot etc/privdns-gateway etc/nftables.conf
              etc/systemd/system/pdg-bot.service etc/systemd/journald.conf.d/50-pdg.conf
              etc/systemd/system/journald.conf.d/50-pdg.conf)
  local items=(); local p; for p in "${cand[@]}"; do [[ -e "/$p" ]] && items+=("$p"); done
  # 面板受管开启态: 用净化后的 config 入档(排除真实 config.json, 追加净化版), 快照不含临时监听/密钥/UI。
  local stg=""
  if [[ -e /etc/sing-box/config.json ]] && _sb_panel_managed_on /etc/sing-box/config.json; then
    if ! stg="$(_pdg_mktemp_dir)"; then
      c_y "❌ 快照创建临时目录失败"; rmdir "$d" 2>/dev/null; return 1
    fi
    if ! mkdir -p "$stg/etc/sing-box" \
       || ! _sb_write_sanitized /etc/sing-box/config.json "$stg/etc/sing-box/config.json"; then
      c_y "❌ 快照净化面板配置失败"; rm -rf "$stg"; rmdir "$d" 2>/dev/null; return 1
    fi
  fi
  if [[ -n "$stg" ]]; then      # cf(排除真实 config)+ rf(追加净化 config)+ gzip: --exclude 只对第一次 tar 生效
    if ! tar cf "$d/snap.tar" --exclude='etc/sing-box/config.json' -C / "${items[@]}" 2>/dev/null \
       || ! tar rf "$d/snap.tar" -C "$stg" etc/sing-box/config.json 2>/dev/null \
       || ! gzip -f "$d/snap.tar" 2>/dev/null; then
      c_y "❌ 快照打包失败"; rm -f "$d/snap.tar" "$d/snap.tar.gz"; rm -rf "$stg"; rmdir "$d" 2>/dev/null; return 1
    fi
    rm -rf "$stg"
  elif ! tar czf "$d/snap.tar.gz" -C / "${items[@]}" 2>/dev/null; then
    c_y "❌ 快照打包失败"; rm -f "$d/snap.tar.gz"; rmdir "$d" 2>/dev/null; return 1
  fi
  chmod 600 "$d/snap.tar.gz"
  echo "✅ 快照: $d/snap.tar.gz"
  ls -1dt "$SNAP_DIR"/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf   # 只留最近 10 份
}

cmd_rollback(){
  need_root rollback; _lock
  local snaps; mapfile -t snaps < <(ls -1dt "$SNAP_DIR"/*/ 2>/dev/null)
  [[ ${#snaps[@]} -gt 0 ]] || { echo "没有快照(先 pdg snapshot)"; return 1; }
  echo "可用快照(新→旧):"; local i=0; for s in "${snaps[@]}"; do echo "  [$i] $(basename "$s")"; i=$((i+1)); done
  local idx="${1:-0}" target
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "无效序号 $idx"; return 1; }
  idx=$((10#$idx))
  (( idx >= ${#snaps[@]} )) && { echo "无效序号 $idx"; return 1; }
  target="${snaps[$idx]}"
  local f="$target/snap.tar.gz"
  [[ -f "$f" ]] || { echo "快照文件缺失: $f"; return 1; }
  # 先完整解包、净化并校验临时树，再把同一棵树落盘；坏包/净化失败不碰现网。
  local tmp="" tree="" members="" panel_sanitized=0
  if ! tmp="$(_pdg_mktemp_dir)"; then echo "❌ 无法创建回滚临时目录"; return 1; fi
  tree="$tmp/tree"; members="$tmp/members"
  if ! mkdir -p "$tree" || ! tar tzf "$f" > "$members" 2>/dev/null || [[ ! -s "$members" ]]; then
    echo "❌ 快照目录或成员清单读取失败, 中止"; rm -rf "$tmp"; return 1
  fi
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$members" || grep -Evq '^(etc|opt)(/|$)' "$members"; then
    echo "❌ 快照含越界路径, 中止"; rm -rf "$tmp"; return 1
  fi
  if ! tar xzf "$f" -C "$tree" 2>/dev/null; then
    echo "❌ 快照解包失败, 中止"; rm -rf "$tmp"; return 1
  fi
  if _sb_panel_managed_on "$tree/etc/sing-box/config.json"; then
    if ! _sb_sanitize_panel "$tree/etc/sing-box/config.json"; then
      echo "❌ 快照面板临时态净化失败, 中止"; rm -rf "$tmp"; return 1
    fi
    panel_sanitized=1
  fi
  # 内核配置校验: 按当前后端 (mihomo / sing-box) 校验快照里对应配置
  if [[ "$(_pdg_core)" == mihomo ]]; then
    [[ -f "$tree/etc/mihomo/config.yaml" ]] && { mihomo -t -d "$tree/etc/mihomo" -f "$tree/etc/mihomo/config.yaml" >/dev/null 2>&1 || { echo "❌ 快照的 mihomo 配置 check 失败, 中止"; rm -rf "$tmp"; return 1; }; }
  elif [[ -f "$tree/etc/sing-box/config.json" ]]; then
    if ! sed "s#/etc/sing-box/rs/#$tree/etc/sing-box/rs/#g" "$tree/etc/sing-box/config.json" > "$tmp/sb.chk"; then
      echo "❌ 快照的 sing-box 校验副本生成失败, 中止"; rm -rf "$tmp"; return 1
    fi
    sing-box check -c "$tmp/sb.chk" >/dev/null 2>&1 || { echo "❌ 快照的 sing-box 配置 check 失败, 中止"; rm -rf "$tmp"; return 1; }
    rm -f "$tmp/sb.chk"
  fi
  [[ -f "$tree/etc/nftables.conf" ]] && { nft -c -f "$tree/etc/nftables.conf" >/dev/null 2>&1 || { echo "❌ 快照的 nftables 语法错, 中止"; rm -rf "$tmp"; return 1; }; }
  echo "回滚到 $(basename "$target") …"
  if ! _pdg_apply_snapshot_tree "$tree" "$members" /; then
    echo "❌ 快照落盘失败, 系统可能已部分恢复, 请立即检查"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  (( panel_sanitized == 1 )) && c_g "  已净化回滚出的面板临时态 → 关闭"
  systemctl daemon-reload
  nft -f /etc/nftables.conf 2>/dev/null || true
  systemctl restart mosdns "$(_pdg_core_svc)" pdg-bot pdg-probe81 2>/dev/null || true
  systemctl restart systemd-journald 2>/dev/null || true   # journald CanReload=no: 还原封顶需 restart 才生效
  echo "✅ 已回滚并重启服务"
}

# 内核二进制更新: 比对 versions.sh 钉死版本与已装版本, 不一致则下载+SHA校验+装。
# 关键安全: 先备份旧二进制, 用新二进制对现有配置跑 check, 通过才切换/重启; 失败还原旧版, 不留坏内核。
_update_core_binary(){
  local core march ver tmp prev=""
  core="$(_pdg_core)"
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/versions.sh" 2>/dev/null || { c_y "读不到 versions.sh, 跳过内核更新"; return 0; }
  march=$(dpkg --print-architecture 2>/dev/null); [[ "$march" == arm64 ]] || march=amd64
  tmp=$(mktemp -d)
  if [[ "$core" == mihomo ]]; then
    ver="$MIHOMO_VER"
    mihomo -v 2>/dev/null | grep -q "$ver" && { rm -rf "$tmp"; return 0; }   # 已是钉死版本
    c_g "更新 mihomo 内核 → $ver …"
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${march}-${ver}.gz" -o "$tmp/m.gz" \
      || { c_y "  下载失败, 保留现版本"; rm -rf "$tmp"; return 0; }
    pdg_verify_sha256 "$tmp/m.gz" "${PDG_SHA256[mihomo-$march]:-}" "mihomo $ver ($march)" \
      || { c_y "  SHA 校验失败, 保留现版本"; rm -rf "$tmp"; return 0; }
    gunzip -c "$tmp/m.gz" > "$tmp/mihomo" || { c_y "  解压失败, 保留现版本"; rm -rf "$tmp"; return 0; }
    prev="/usr/local/bin/mihomo.prev"; cp -a /usr/local/bin/mihomo "$prev" 2>/dev/null
    install -m755 "$tmp/mihomo" /usr/local/bin/mihomo
    if mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1; then
      rm -f "$prev"; systemctl restart mihomo 2>/dev/null || true; c_g "  → mihomo $ver 已装并重启"
    else
      [[ -f "$prev" ]] && mv "$prev" /usr/local/bin/mihomo; c_y "  新版与当前配置不兼容(check 失败), 已还原旧版内核"
    fi
  else
    ver="$SINGBOX_VER"
    sing-box version 2>/dev/null | grep -q "version $ver" && { rm -rf "$tmp"; return 0; }
    c_g "更新 sing-box 内核 → $ver …"
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${march}.tar.gz" -o "$tmp/sb.tgz" \
      || { c_y "  下载失败, 保留现版本"; rm -rf "$tmp"; return 0; }
    pdg_verify_sha256 "$tmp/sb.tgz" "${PDG_SHA256[singbox-$march]:-}" "sing-box $ver ($march)" \
      || { c_y "  SHA 校验失败, 保留现版本"; rm -rf "$tmp"; return 0; }
    tar -xzf "$tmp/sb.tgz" -C "$tmp" || { c_y "  解压失败, 保留现版本"; rm -rf "$tmp"; return 0; }
    prev="/usr/local/bin/sing-box.prev"; cp -a /usr/local/bin/sing-box "$prev" 2>/dev/null
    install -m755 "$tmp"/sing-box-*/sing-box /usr/local/bin/sing-box
    if sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
      rm -f "$prev"; systemctl restart sing-box 2>/dev/null || true; c_g "  → sing-box $ver 已装并重启"
    else
      [[ -f "$prev" ]] && mv "$prev" /usr/local/bin/sing-box; c_y "  新版与当前配置不兼容, 已还原旧版内核"
    fi
  fi
  rm -rf "$tmp"
}

cmd_update(){
  need_root update
  command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }
  if [[ "${1:-}" == "--dry-run" ]]; then
    [[ -d "$REPO_DIR/.git" ]] && pdg_fetch_release_tags "$REPO_DIR" 2>/dev/null
    local tgt; tgt=$(git -C "$REPO_DIR" tag -l 'v*' --sort=-v:refname 2>/dev/null | head -1)
    echo "当前: $(git -C "$REPO_DIR" describe --tags --always 2>/dev/null)   最新发布: ${tgt:-(无 tag)}"
    [[ -n "$tgt" ]] && { echo "待更新提交(HEAD..$tgt):"; git -C "$REPO_DIR" log --oneline "HEAD..$tgt" 2>/dev/null || echo "  (已是最新或无法比较)"; }
    return 0
  fi
  _lock   # 取锁(嵌套的 cmd_snapshot 不会重复锁)
  c_g "更新前留快照…"; cmd_snapshot >/dev/null 2>&1 || true
  c_g "拉取最新发布 tag…"
  [[ -d "$REPO_DIR/.git" ]] || { rm -rf "$REPO_DIR"; git clone -q "$REPO_URL" "$REPO_DIR"; }
  if ! pdg_fetch_release_tags "$REPO_DIR"; then
    c_y "拉取发布 tag 失败, 中止更新。"; return 1
  fi
  local tgt; tgt=$(git -C "$REPO_DIR" tag -l 'v*' --sort=-v:refname | head -1)
  if [[ -z "$tgt" ]]; then
    c_y "仓库没有发布 tag(v*), 中止更新。"; return 1
  fi
  git -C "$REPO_DIR" reset --hard -q "$tgt"
  c_g "→ 已切到发布 $tgt"
  c_g "刷新代码(配置/出口/token/证书均不动)…"
  install -m755 "$REPO_DIR"/deploy/bot/pdg-bot.py           /opt/pdg-bot/bot.py
  install -m755 "$REPO_DIR"/deploy/bot/parse-geosite.py     /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/update-rules.sh      /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/scheduled-update.sh  /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/healthcheck.py      /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/checks.py           /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/doctor.py           /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/report.py           /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/sb2mihomo.py        /opt/pdg-bot/
  install -m755 "$REPO_DIR"/deploy/bot/mitm_ca.py          /opt/pdg-bot/ 2>/dev/null || true
  install -m755 "$REPO_DIR"/deploy/bot/mitm_server.py      /opt/pdg-bot/ 2>/dev/null || true
  install -m755 "$REPO_DIR"/deploy/bot/mitm_wloc.py        /opt/pdg-bot/ 2>/dev/null || true
  install -m755 "$REPO_DIR"/deploy/ios/probe81.py           /opt/pdg-bot/
  install -m644 "$REPO_DIR"/deploy/bot/pdg-health.service  /etc/systemd/system/ 2>/dev/null || true
  install -m644 "$REPO_DIR"/deploy/bot/pdg-health.timer    /etc/systemd/system/ 2>/dev/null || true
  install -m644 "$REPO_DIR"/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
  install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-open-cert-http.sh   /usr/local/bin/
  install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-restore-firewall.sh /usr/local/bin/
  install -m755 "$REPO_DIR"/deploy/cert/99-reload-cert.deploy-hook.sh     /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh
  install -m755 "$REPO_DIR"/deploy/bot/pdg-set-token.sh     /usr/local/bin/pdg-set-token
  install -m755 "$REPO_DIR"/deploy/bot/pdg.sh               /usr/local/bin/pdg
  # 迁移用"刚装好的新脚本"跑(本进程还是旧 bash, 直接调会用旧版函数 → 新迁移要等下次命令才生效)。
  bash /usr/local/bin/pdg __migrate
  # 内核二进制: 按 versions.sh 钉死版本更新(mihomo 可持续升版; sing-box 仍钉 1.12.x)。
  _update_core_binary

  # ── 更新后校验门: 任一硬校验失败即回滚到更新前快照 ──
  c_g "校验新版本…"
  if ! python3 -m py_compile /opt/pdg-bot/*.py 2>/dev/null; then
    c_y "Python 语法错误, 回滚到更新前快照…"; cmd_rollback 0; return 1
  fi
  if [[ "$(_pdg_core)" == mihomo ]]; then
    if ! mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1; then
      c_y "mihomo 配置 check 失败, 回滚…"; cmd_rollback 0; return 1
    fi
  elif ! sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
    c_y "sing-box 配置 check 失败, 回滚…"; cmd_rollback 0; return 1
  fi
  if ! nft -c -f /etc/nftables.conf >/dev/null 2>&1; then
    c_y "nftables 配置 check 失败, 回滚…"; cmd_rollback 0; return 1
  fi
  systemctl daemon-reload
  systemctl enable --now pdg-health.timer >/dev/null 2>&1 || true   # 老装升级时补上健康自检
  systemctl restart pdg-bot pdg-probe81 2>/dev/null || true
  sleep 2

  # token 是否已配置(未配则 pdg-bot 不在跑属正常, 不据此回滚)
  local token_set=0
  [[ -f "$ENVF" ]] && grep -qE '^PDG_BOT_TOKEN=.+' "$ENVF" && grep -qE '^PDG_BOT_ALLOWED=.+' "$ENVF" && token_set=1
  if [[ "$token_set" == 1 && "$(systemctl is-active pdg-bot 2>/dev/null)" != "active" ]]; then
    c_y "pdg-bot 更新后起不来, 回滚到更新前快照…"; cmd_rollback 0; return 1
  fi

  # doctor 自检: 有 fail 回滚, warn 仅提示 (未配 token 时把"服务: 未运行: pdg-bot"这单一项排除, 避免误判)
  local j fails warns
  j=$(python3 /opt/pdg-bot/doctor.py --json 2>/dev/null || true)
  if [[ -n "$j" ]] && command -v jq >/dev/null; then
    fails=$(echo "$j" | jq -r --argjson t "$token_set" \
      '[ .[] | select(.level=="fail")
            | select( ($t==1) or (.check!="服务") or (.detail!="未运行: pdg-bot") ) ] | length' 2>/dev/null)
    warns=$(echo "$j" | jq -r '[ .[] | select(.level=="warn") ] | length' 2>/dev/null)
    if [[ "${fails:-0}" -gt 0 ]]; then
      c_y "自检发现 $fails 项失败, 回滚到更新前快照:"
      echo "$j" | jq -r '.[] | select(.level=="fail") | "  ❌ \(.check): \(.detail)"'
      cmd_rollback 0; return 1
    fi
    [[ "${warns:-0}" -gt 0 ]] && { c_y "自检有 $warns 项警告(不回滚, 仅提示):"
      echo "$j" | jq -r '.[] | select(.level=="warn") | "  ⚠️ \(.check): \(.detail)"'; }
  fi
  c_g "✅ 已更新。"
}

cmd_token(){ need_root token; pdg-set-token; }   # 不 exec, 设完/取消都回菜单

cmd_restart(){ need_root restart; local svc; svc="$(_pdg_core_svc)"; systemctl restart mosdns "$svc" pdg-bot pdg-probe81 2>/dev/null; echo "已重启 mosdns / $svc / pdg-bot / pdg-probe81"; }

cmd_log(){ journalctl -u pdg-bot -u mosdns -u sing-box -n "${1:-40}" --no-pager -o cat; }

cmd_traffic(){ command -v vnstat >/dev/null && vnstat || echo "vnstat 未装: sudo apt install -y vnstat && systemctl enable --now vnstat"; }

cmd_report(){ need_root report; python3 /opt/pdg-bot/report.py "$@"; }

# 抓包识别内网卡来源段, 检测到与现配不符时可一键写回 mosdns+nftables 并重启(装完随时跑, 比装机时从容)。
cmd_detect_cidr(){
  need_root detect-cidr
  local dur="${1:-30}" sip det cur
  sip=$(grep -oE '"[0-9.]+/32"' /etc/sing-box/config.json 2>/dev/null | tr -d '"' | grep -v '^127' | head -1 | cut -d/ -f1)
  det=$(bash "$REPO_DIR/lib/detect-internal-range.sh" "$dur" "${sip:-本机IP}" || true)
  if [[ -z "$det" ]]; then
    c_y "没抓到。确认手机走内网卡(关 WiFi), 或云安全组放行入站 80/ICMP, 再重试。"; return 1
  fi
  cur=$(grep -oE 'ip saddr [0-9./]+' /etc/nftables.conf 2>/dev/null | head -1 | awk '{print $3}')
  echo "  检测到内网卡段: $det"
  echo "  当前配置:       ${cur:-未知}"
  [[ "$det" == "$cur" ]] && { c_g "✅ 与当前一致, 无需改动。"; return 0; }
  read -rp "把内网卡段 ${cur:-?} → $det 并应用(写 mosdns+nftables 并重启)? [y/N]: " yn
  [[ "$yn" == [yY] ]] || { echo "已取消, 未改动。"; return 0; }
  _lock; c_g "先留快照…"; cmd_snapshot >/dev/null 2>&1 || true
  [[ -n "$cur" ]] && sed -i "s#${cur//./\\.}#$det#g" /etc/nftables.conf
  sed -i -E "s#(ips:[[:space:]]*\[[[:space:]]*\")[0-9./]+(\")#\1$det\2#" /etc/mosdns/config.yaml
  if ! nft -c -f /etc/nftables.conf >/dev/null 2>&1; then c_y "nft 校验失败, 回滚…"; cmd_rollback 0; return 1; fi
  nft -f /etc/nftables.conf
  systemctl restart mosdns; sleep 2
  [[ "$(systemctl is-active mosdns)" == active ]] || { c_y "mosdns 重启异常, 回滚…"; cmd_rollback 0; return 1; }
  c_g "✅ 内网卡段已更新为 $det 并重启 mosdns。"
}

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
  nft insert rule inet pdg input ip saddr "$CIDR" tcp dport "$PORT" accept 2>/dev/null
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
    echo "  2) 自检 (doctor)"
    echo "  3) 更新"
    echo "  4) 快照备份"
    echo "  5) 回滚"
    echo "  6) 设置/更换 Bot Token 与 TG ID"
    echo "  7) 重启服务"
    echo "  8) 日志"
    echo "  9) 流量 (vnstat)"
    echo " 10) iOS 描述文件"
    echo " 11) 诊断报告 (脱敏)"
    echo " 12) 识别内网卡段"
    echo " 13) 卸载"
    echo "  0) 退出"
    echo "  下次打开本菜单命令: pdg"
    printf "选择: "
    read -r c || exit 0
    case "$c" in
      1) cmd_status;;
      2) cmd_doctor;;
      3) cmd_update && exec /usr/local/bin/pdg menu;;
      4) cmd_snapshot;;
      5) read -rp "回滚到第几个快照(默认 0=最近, 回车确认): " i; cmd_rollback "${i:-0}";;
      6) cmd_token;;
      7) cmd_restart;;
      8) cmd_log 60;;
      9) cmd_traffic;;
      10) cmd_ios;;
      11) cmd_report;;
      12) cmd_detect_cidr;;
      13) read -rp "卸载: 留空取消 / yes 仅卸载 / purge 连配置一起删: " x
         case "$x" in yes) cmd_uninstall;; purge) cmd_uninstall --purge;; *) echo "已取消";; esac;;
      0|q) exit 0;;
      *) echo "无效选择";;
    esac
  done
}

# 老装升级"自愈": 旧版 pdg update 跑的是旧脚本, 不会调用迁移 → 装上新 pdg.sh 后,
# 全部老装迁移(幂等)。集中一处, 供管理类命令的自愈调用 + cmd_update 装好新脚本后经 `pdg __migrate` 调"新版"。
# 老装 mihomo: 给 mihomo.service 补 Environment=SAFE_PATHS(面板 UI 在 /etc/sing-box/ui/dist, 不在 -d 下)。幂等。
migrate_mihomo_safepaths(){
  [[ "$(_pdg_core)" == mihomo ]] || return 0
  local unit=/etc/systemd/system/mihomo.service
  [[ -f "$unit" ]] || return 0
  grep -q 'SAFE_PATHS' "$unit" && return 0
  c_g "补 mihomo.service 的 SAFE_PATHS(面板 UI 路径放行)…"
  sed -i '/^ExecStart=.*mihomo/a Environment=SAFE_PATHS=/etc/sing-box/ui/dist' "$unit"
  systemctl daemon-reload; systemctl restart mihomo 2>/dev/null || true
}

run_all_migrations(){
  migrate_botenv || true; migrate_firewall_to_pdg || true; migrate_mosdns_concurrent || true
  migrate_mosdns_unlock || true; migrate_singbox_gms || true; migrate_fw_gms || true
  migrate_mosdns_ratelimit || true; migrate_lowmem || true; migrate_mihomo_safepaths || true
}

# 内核切换: sing-box <-> mihomo。出口/分流/证书/DoT/mosdns 全不动(model 共用), 只换内核二进制 +
# 服务 + nft 入站模型(sing-box 裸 accept ↔ mihomo REDIRECT→7893)。失败自动回滚。
_switchcore_nft(){   # $1=target 渲染并应用对应内核的 nft(用当前 SSH端口/内网段)
  local target="$1" tmpl sshp icidr
  sshp=$(grep -oP '^\s*tcp dport \{ \K[0-9]+(?= \} accept)' /etc/nftables.conf | head -1)
  icidr=$(python3 -c "import sys;sys.path.insert(0,'/opt/pdg-bot');import checks;print(checks._internal_cidr())" 2>/dev/null)
  [[ -n "$sshp" && -n "$icidr" ]] || { echo "提取 SSH端口/内网段失败(ssh=$sshp cidr=$icidr)"; return 1; }
  [[ "$target" == mihomo ]] && tmpl=nftables-mihomo.conf || tmpl=nftables.conf
  [[ -f "$REPO_DIR/deploy/firewall/$tmpl" ]] || { echo "缺 $tmpl(先 pdg update)"; return 1; }
  sed -e "s|__SSH_PORT__|$sshp|g" -e "s|__INTERNAL_CIDR__|$icidr|g" "$REPO_DIR/deploy/firewall/$tmpl" > /etc/nftables.conf
  nft -f /etc/nftables.conf
}

cmd_switch_core(){
  need_root switch-core; _lock
  local target="${1:-}" cur march plat
  [[ "$target" == mihomo || "$target" == singbox ]] || { echo "用法: pdg switch-core <mihomo|singbox>"; return 1; }
  cur="$(_pdg_core)"
  [[ "$cur" == "$target" ]] && { echo "已经是 $target 内核。"; return 0; }
  [[ -f /etc/mihomo/config.yaml || -f "$REPO_DIR/deploy/bot/sb2mihomo.py" ]] || { echo "❌ 缺 mihomo 支持文件, 先 sudo pdg update。"; return 1; }
  c_g "切换内核 $cur → $target(出口/分流/证书/DoT 均不动)…"
  cmd_snapshot >/dev/null 2>&1 || true
  march=$(dpkg --print-architecture 2>/dev/null); [[ "$march" == arm64 ]] || march=amd64
  plat="$(_pdg_platform)"
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/versions.sh" 2>/dev/null || { echo "❌ 读不到 versions.sh"; return 1; }
  cp /etc/nftables.conf /etc/nftables.conf.scbak 2>/dev/null

  if [[ "$target" == mihomo ]]; then
    if ! mihomo -v 2>/dev/null | grep -q "$MIHOMO_VER"; then
      c_g "下载 mihomo $MIHOMO_VER…"; local t; t=$(mktemp -d)
      if ! curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-${march}-${MIHOMO_VER}.gz" -o "$t/m.gz" \
         || ! pdg_verify_sha256 "$t/m.gz" "${PDG_SHA256[mihomo-$march]:-}" "mihomo $MIHOMO_VER" \
         || ! gunzip -c "$t/m.gz" > "$t/mihomo"; then rm -rf "$t"; echo "❌ mihomo 下载/校验失败, 未切换"; return 1; fi
      install -m755 "$t/mihomo" /usr/local/bin/mihomo; rm -rf "$t"
    fi
    install -d -m700 /etc/mihomo
    printf 'mihomo\n' > /etc/privdns-gateway/backend      # 先切标记, 让渲染/迁移按 mihomo 走
    if ! ( cd /opt/pdg-bot && python3 -c "import bot; bot._render_mihomo_file()" ) 2>/dev/null \
       || ! mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1; then
      printf 'singbox\n' > /etc/privdns-gateway/backend; echo "❌ 渲染/校验 mihomo 配置失败, 已回滚标记, 未切换"; return 1
    fi
    cat > /etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=mihomo (PrivDNS Gateway core)
After=network-online.target mosdns.service
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    [[ "$plat" == ios ]] && cat > /etc/systemd/system/pdg-mitm.service <<'EOF'
[Unit]
Description=pdg-mitm
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/pdg-bot/mitm_server.py 7894
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    _switchcore_nft mihomo || { printf 'singbox\n' > /etc/privdns-gateway/backend; [[ -f /etc/nftables.conf.scbak ]] && { cp /etc/nftables.conf.scbak /etc/nftables.conf; nft -f /etc/nftables.conf; }; echo "❌ nft 应用失败, 已回滚"; return 1; }
    systemctl stop sing-box 2>/dev/null
    systemctl reset-failed mihomo 2>/dev/null; systemctl enable --now mihomo >/dev/null 2>&1
    [[ "$plat" == ios ]] && { systemctl enable --now pdg-mitm >/dev/null 2>&1 || true; }
  else
    if ! sing-box version 2>/dev/null | grep -q "version $SINGBOX_VER"; then
      c_g "下载 sing-box $SINGBOX_VER…"; local t; t=$(mktemp -d)
      if ! curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${march}.tar.gz" -o "$t/sb.tgz" \
         || ! pdg_verify_sha256 "$t/sb.tgz" "${PDG_SHA256[singbox-$march]:-}" "sing-box $SINGBOX_VER" \
         || ! tar -xzf "$t/sb.tgz" -C "$t"; then rm -rf "$t"; echo "❌ sing-box 下载/校验失败, 未切换"; return 1; fi
      install -m755 "$t"/sing-box-*/sing-box /usr/local/bin/sing-box; rm -rf "$t"
    fi
    printf 'singbox\n' > /etc/privdns-gateway/backend
    if ! sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
      printf 'mihomo\n' > /etc/privdns-gateway/backend; echo "❌ sing-box 配置校验失败, 已回滚, 未切换"; return 1
    fi
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
    systemctl daemon-reload
    _switchcore_nft singbox || { printf 'mihomo\n' > /etc/privdns-gateway/backend; [[ -f /etc/nftables.conf.scbak ]] && { cp /etc/nftables.conf.scbak /etc/nftables.conf; nft -f /etc/nftables.conf; }; echo "❌ nft 应用失败, 已回滚"; return 1; }
    systemctl stop mihomo pdg-mitm 2>/dev/null
    systemctl reset-failed sing-box 2>/dev/null; systemctl enable --now sing-box >/dev/null 2>&1
  fi

  sleep 2
  local svc; svc="$(_pdg_core_svc)"
  if [[ "$(systemctl is-active "$svc" 2>/dev/null)" == active ]]; then
    rm -f /etc/nftables.conf.scbak
    echo "✅ 已切换到 $target 内核(出口/分流/证书/DoT 未动)。"
    return 0
  fi
  # 回滚
  c_y "$svc 启动失败 → 回滚到 $cur …"
  printf '%s\n' "$cur" > /etc/privdns-gateway/backend
  [[ -f /etc/nftables.conf.scbak ]] && { cp /etc/nftables.conf.scbak /etc/nftables.conf; nft -f /etc/nftables.conf 2>/dev/null; rm -f /etc/nftables.conf.scbak; }
  systemctl stop "$svc" 2>/dev/null
  systemctl reset-failed "$(_pdg_core_svc)" 2>/dev/null; systemctl start "$(_pdg_core_svc)" 2>/dev/null
  echo "❌ 切换失败, 已回滚到 $cur 内核。"
  return 1
}

# 切换劫持模式: all(非CN全劫持) | gfw(只劫持 GFWList 真被墙域名, 非墙海外直连)。换 hijack_set 加载的域名文件。
cmd_hijack_mode(){
  need_root hijack-mode
  local mode="${1:-}" file
  if [[ "$mode" != all && "$mode" != gfw ]]; then
    echo "用法: pdg hijack-mode <all|gfw>"
    echo "  all = 非CN域名全劫持进代理(默认)"
    echo "  gfw = 只劫持 GFWList 真被墙域名; 非墙海外域名直连(修 SSH/直连走域名被劫持)。前提: 内网卡 SIM 能直达一般互联网"
    echo "  当前: $(cat /etc/privdns-gateway/profile.env 2>/dev/null | sed -n 's/^PDG_HIJACK_MODE=//p' | tail -1 || echo '?')"
    return 1
  fi
  grep -q 'tag: hijack_set' /etc/mosdns/config.yaml 2>/dev/null \
    || { echo "❌ 当前 mosdns 配置无 hijack_set(旧版装机)。先 sudo pdg update 到 v1.4.2+ 再切。"; return 1; }
  if [[ "$mode" == gfw ]]; then
    file="geosite_gfw.txt"
    if [[ ! -s /etc/mosdns/rules/geosite_gfw.txt ]]; then
      c_g "生成 GFWList(geosite_gfw.txt)…"; bash /opt/pdg-bot/update-rules.sh >/dev/null 2>&1 || true
    fi
    [[ -s /etc/mosdns/rules/geosite_gfw.txt ]] || { echo "❌ geosite_gfw.txt 生成失败, 仍为原模式"; return 1; }
  else
    file="geosite_geolocation-!cn.txt"
  fi
  cp /etc/mosdns/config.yaml /etc/mosdns/config.yaml.hjbak
  # geosite_gfw.txt / geosite_geolocation-!cn.txt 仅 hijack_set 引用, 故全局替换安全
  sed -i -E "s#/etc/mosdns/rules/geosite_(gfw|geolocation-!cn)\.txt#/etc/mosdns/rules/$file#g" /etc/mosdns/config.yaml
  systemctl restart mosdns; sleep 1.5
  if [[ "$(systemctl is-active mosdns 2>/dev/null)" != active ]]; then
    c_y "mosdns 重启失败 → 还原"; cp /etc/mosdns/config.yaml.hjbak /etc/mosdns/config.yaml
    systemctl restart mosdns; rm -f /etc/mosdns/config.yaml.hjbak; return 1
  fi
  rm -f /etc/mosdns/config.yaml.hjbak
  install -d -m700 /etc/privdns-gateway
  if grep -q '^PDG_HIJACK_MODE=' /etc/privdns-gateway/profile.env 2>/dev/null; then
    sed -i "s/^PDG_HIJACK_MODE=.*/PDG_HIJACK_MODE=$mode/" /etc/privdns-gateway/profile.env
  else
    echo "PDG_HIJACK_MODE=$mode" >> /etc/privdns-gateway/profile.env
  fi
  echo "✅ 劫持模式 → $mode"
}

# 下一次以 root 运行"管理类"命令(update/restart/menu/…)时幂等自动迁移防火墙(已迁移则首个 grep 秒退)。
# 只读命令(status/doctor/log/traffic/report)与卸载不触发, 以保持"只读命令不写任何东西"的语义;
# 只跑只读命令的用户可显式 `sudo pdg migrate-fw` 迁移(且证书 hook/doctor 已兼容旧 inet filter, 不迁也能用)。
if [[ $EUID -eq 0 ]]; then
  case "${1:-menu}" in
    status|st|doctor|dr|log|logs|traffic|tr|report|uninstall|rm|__migrate) : ;;   # 只读/卸载/内部迁移: 不重复迁移
    *) run_all_migrations ;;   # 管理类命令才迁移(idempotent)
  esac
fi

case "${1:-menu}" in
  menu|"")       menu;;
  __migrate)     need_root __migrate; run_all_migrations;;   # 内部: cmd_update 装好新脚本后据此跑"新版"迁移
  status|st)     cmd_status;;
  doctor|dr)     shift || true; cmd_doctor "${1:-}";;
  update|up)     shift || true; cmd_update "${1:-}";;
  migrate-fw)    need_root migrate-fw; migrate_firewall_to_pdg;;
  snapshot|snap) cmd_snapshot;;
  rollback)      shift || true; cmd_rollback "${1:-0}";;
  token)         cmd_token;;
  restart)       cmd_restart;;
  log|logs)      shift || true; cmd_log "${1:-40}";;
  traffic|tr)    cmd_traffic;;
  ios)           cmd_ios;;
  report)        shift || true; cmd_report "$@";;
  detect-cidr|cidr) shift || true; cmd_detect_cidr "${1:-}";;
  hijack-mode)   shift || true; cmd_hijack_mode "${1:-}";;
  switch-core)   shift || true; cmd_switch_core "${1:-}";;
  uninstall|rm)  shift || true; cmd_uninstall "${1:-}";;
  *) echo "用法: pdg [menu|status|doctor [--json|--deep]|update [--dry-run]|snapshot|rollback [n]|token|restart|log [n]|traffic|ios|report [--redact-ip|--full]|detect-cidr|hijack-mode <all|gfw>|switch-core <mihomo|singbox>|migrate-fw|uninstall [--purge]]";;
esac
