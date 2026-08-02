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
# 活动内核后端: v1.6.0 起恒 mihomo(彻底移除 sing-box 运行时)。旧机器的 backend 标记里可能还
# 写着 singbox, 但由 migrate_drop_singbox 在 update 时迁移 —— 判定一律按 mihomo。
_pdg_core(){ echo mihomo; }
_pdg_core_svc(){ echo mihomo; }
# 手机平台(ios / android; 读不到默认 android)
_pdg_platform(){ local p; p=$(cat /etc/privdns-gateway/platform 2>/dev/null); [[ "$p" == ios || "$p" == android ]] && echo "$p" || echo android; }
# 平台标记是否明确(status/doctor 据此提示"缺失回退")
_pdg_platform_present(){ local p; p=$(cat /etc/privdns-gateway/platform 2>/dev/null); [[ "$p" == ios || "$p" == android ]]; }
# 展示用的服务集(status 逐个列状态): 恒含 pdg-bot —— 用户想看到它在不在跑, 哪怕没配凭据。
# pdg-probe81 仍是 iOS 专属。
_pdg_svcs(){ local s; s="mosdns $(_pdg_core_svc) pdg-bot"; [[ "$(_pdg_platform)" == ios ]] && s="$s pdg-probe81"; echo "$s"; }

# **必需**服务集(校验门用): 与 checks.expected_services() 同语义 —— bot.env 两项都空是合法的
# "这台机器不用 Telegram 管理", pdg-bot 不运行属正常禁用态, 不该把它算成必须在跑的服务。
# 以前平台切换直接用 _pdg_svcs 校验, 于是没配 bot 的机器 `pdg platform ios` 必然卡在
# "pdg-bot 未稳定运行"并整体回滚 —— 而那台机器本来就没打算起 bot。
_pdg_required_svcs(){
  local s; s="mosdns $(_pdg_core_svc)"
  [[ "$(_pdg_bot_cred)" == ready ]] && s="$s pdg-bot"
  [[ "$(_pdg_platform)" == ios ]] && s="$s pdg-probe81"
  echo "$s"
}

# nft 可执行文件位置: 判据集中在 lib/nftbin.sh(pdg / uninstall / certbot 钩子共用), 详见
# 该文件注释 —— 只看 PATH 会把"nft 在 /usr/sbin 但 PATH 没导出"当成没装。找不到回显空串。
_pdg_nft_bin(){
  # shellcheck source=lib/nftbin.sh
  source "${REPO_DIR:-/opt/privdns-gateway}/lib/nftbin.sh" 2>/dev/null \
    || { command -v nft 2>/dev/null || true; return 0; }   # 连判据文件都没有: 至少别比以前差
  pdg_nft_bin || true
}

# ── sing-box 文件归属 ────────────────────────────────────────────────────────
# 判据集中在 lib/singbox.sh(install/uninstall/pdg 共用), 详见该文件注释:
# 只有可信归属标记, 或"完整匹配历史 PDG unit 形态 + 现场另有本项目特征", 才算自家的。
# 手工装 sing-box 最常见的 ExecStart 与本项目历史模板逐字一致, 单凭它认亲会误删别人的东西。
_pdg_singbox_is_ours(){
  # shellcheck source=lib/singbox.sh
  source "$REPO_DIR/lib/singbox.sh" 2>/dev/null || return 1
  pdg_singbox_is_ours "$@"
}

_pdg_drop_singbox_files(){
  local why="${1:-}" pfx="${PDG_ROOT_PREFIX:-}"
  local unit="$pfx/etc/systemd/system/sing-box.service" bin="$pfx/usr/local/bin/sing-box"
  [[ -e "$unit" || -e "$bin" ]] || return 0
  if ! _pdg_singbox_is_ours "$unit"; then
    local kept reason
    kept="$(pdg_singbox_kept_paths 2>/dev/null)"
    reason="$(pdg_singbox_why_not_ours "$unit" 2>/dev/null)"
    c_y "  检测到 sing-box${why:+($why)}, 但无法确认是本项目安装的 → 原样保留, 不删:"
    [[ -n "$kept" ]] && printf '%s\n' "$kept" | sed 's/^/      /'
    c_y "  判不出归属的原因: ${reason:-未知}"
    c_y "  (确认它无用可自行清理: systemctl disable --now sing-box; rm -f $unit $bin)"
    return 0
  fi
  # 确认是自家的 → 先落一份可信标记再动手: 中途崩了(断电/被杀)下次仍认得出是本项目所有,
  # 不至于因为 unit 已删、判据失效而退化成"证明不了", 从此再也清不掉残留。
  # shellcheck source=lib/singbox.sh
  source "$REPO_DIR/lib/singbox.sh" 2>/dev/null && pdg_singbox_mark_owned
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  rm -f "$unit" "$bin" "${PDG_ROOT_PREFIX:-}/etc/privdns-gateway/singbox.pdg-owned"
  return 0
}
# iOS: 从已渲染的 nft 移除 GMS 5228-5230(iOS 走 APNs, 不需要)。nft 模板对两平台通用 —— 装机/切核
# 渲染后在 iOS 上剥掉, 免得 iOS 带上 GMS(或切核后 GMS 复活)。$1=nft 文件; 非 iOS 或文件不存在=空操作。
_pdg_nft_strip_gms(){
  local f="$1"
  [[ "$(_pdg_platform)" == ios && -f "$f" ]] || return 0
  sed -E -i 's#(tcp dport [{] 53, 80, 81, 443, 853), 5228-5230, 8445 [}] accept#\1, 8445 } accept#' "$f"  # sing-box 端口集
  sed -E -i 's#(tcp dport [{] 80, 443), 5228-5230 [}] redirect#\1 } redirect#' "$f"                        # mihomo REDIRECT
}

# 串行化"会写配置/重启服务"的操作(update/rollback/snapshot), 防 bot 更新按钮与命令行并发。
# 嵌套调用(update→snapshot)只锁一次。read-only 操作(status/doctor/report/log)不加锁。
LOCK="${PDG_LOCKFILE:-/run/privdns-gateway.lock}"
PDG_LOCKED=""
_lock(){
  [[ -n "$PDG_LOCKED" ]] && return 0
  # 打不开锁文件 → **拒绝执行**(fail-closed)。以前这里 `|| return 0` 继续往下写: 而
  # /run 出问题往往正意味着系统不正常, 恰恰是最不该让两个进程同时改配置的时候。
  if ! exec 9>"$LOCK" 2>/dev/null; then
    echo "⛔ 锁文件不可用($LOCK) —— 为避免并发写坏配置, 本次拒绝执行。"
    echo "   请检查 /run 是否可写(磁盘满/只读挂载/权限), 修好后重试。"
    exit 1
  fi
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

# 原子 upsert: 只更新 profile.env 里的 key=val 这一行, 其余键/注释/未知项原样保留。
# 语义与 pdg-bot.py 的 _profile_text_with 一致(去前导空白后以 key= 开头才算命中; #key= 注释不算)。
# 重复(多行同键)规范为一个有效值(保首个位置, 丢后续); 缺失则追加; 文件不存在则创建。
# 临时文件 + mv 原子替换: 失败不留半截/空文件。返回非 0 表示写入失败。
_profile_set(){
  local key="$1" val="$2" tmp found=0 line stripped
  mkdir -p "$(dirname "$PROFILE_ENV")" 2>/dev/null || true
  tmp="$(mktemp "${PROFILE_ENV}.XXXXXX" 2>/dev/null)" || return 1
  {
    if [[ -f "$PROFILE_ENV" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "$stripped" == "${key}="* ]]; then
          [[ "$found" == 1 ]] || { printf '%s=%s\n' "$key" "$val"; found=1; }   # 首个→规范值; 后续重复→丢弃
        else
          printf '%s\n' "$line"
        fi
      done < "$PROFILE_ENV"
    fi
    [[ "$found" == 1 ]] || printf '%s=%s\n' "$key" "$val"
  } > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$PROFILE_ENV" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
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
  # 原子 upsert, 不整覆盖(保留 HIJACK_MODE/PLATFORM/TFO 等); 告警走 stderr 免污染被捕获的 $res
  _profile_set PDG_LOWMEM "$res" || c_y "⚠️ profile.env 写入失败(磁盘满/只读?), PDG_LOWMEM 本次未持久化。" >&2
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
  local s
  # shellcheck disable=SC2046  # _pdg_svcs 输出有意按空白分词
  local _cred; _cred="$(_pdg_bot_cred)"
  for s in $(_pdg_svcs); do   # 按平台: pdg-probe81 仅 iOS
    local _st; _st="$(systemctl is-active "$s" 2>/dev/null)"
    if [[ "$s" == pdg-bot && "$_cred" != ready ]]; then
      # 合法禁用态不是故障: 两项都空 = 这台机器不用 Telegram 管理; 只配一半才是配置错误
      [[ "$_cred" == partial ]] \
        && printf "  %-12s %s (⚠️ 凭据只配了一项, 需成对配置)\n" "$s" "$_st" \
        || printf "  %-12s %s (未配置凭据, 正常禁用态; 需要时 pdg-set-token)\n" "$s" "$_st"
    else
      printf "  %-12s %s\n" "$s" "$_st"
    fi
  done
  [[ "$(_pdg_platform)" == ios ]] && printf "  %-12s %s\n" "pdg-mitm" "$(systemctl is-active pdg-mitm 2>/dev/null)"
  echo "  timer        $(systemctl is-active pdg-rules-update.timer 2>/dev/null)"
  echo "  内核后端     $core$([[ "$core" == mihomo ]] && echo "(版本随项目发布更新)" || echo "(固定 1.12.x)")"
  if _pdg_platform_present; then echo "  手机平台     $(_pdg_platform)"
  else echo "  手机平台     android(⚠️ 平台标记缺失, 按 Android 安全回退; 运行 sudo pdg 触发迁移落定)"; fi
  echo "  DoT 域名     $(cat /opt/pdg-bot/dot-domain 2>/dev/null || echo ?)"
  local ports p9090="9090(local clash_api)"
  if jq -e '.experimental.clash_api as $c | $c.external_controller == "0.0.0.0:9090" and $c.external_ui == "/etc/sing-box/ui/dist" and (($c.secret // "") | length > 0)' /etc/sing-box/config.json >/dev/null 2>&1; then
    p9090="9090(panel临时内网)"
  fi
  # mihomo 模式 443/80 由 nft 转到 7893(redir), 故把 7893 一并纳入端口展示
  ports=$(ss -lntu 2>/dev/null | grep -oE ':(53|80|81|443|853|7893|8445|9090)\b' | sed 's/^://' | sort -u | sed "s|^9090$|$p9090|" | tr '\n' ' ')
  echo "  监听端口     $ports"
  # 读不到就说读不到 —— 以前 describe 失败(仓库损坏 / dubious ownership)时这里输出一个空值,
  # 看起来像"版本号是空的", 排错方向全歪。
  if [[ -d "$REPO_DIR/.git" ]]; then
    local ver
    if ver="$(git -C "$REPO_DIR" describe --tags --always 2>/dev/null)" && [[ -n "$ver" ]]; then
      echo "  代码版本     $ver"
    else
      echo "  代码版本     未知(仓库不可读: 试 git -C $REPO_DIR describe --tags --always 看具体原因)"
    fi
  else
    echo "  代码版本     未知($REPO_DIR 不是 git 仓库 → pdg update 不可用)"
  fi
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
    '^include "/etc/privdns-gateway/nft-input\\.d/\\*\\.conf"$'
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
    c_y "   • 把自定义规则并进 deploy/firewall/nftables-mihomo.conf 同风格后手动 nft -f; 或"
    c_y "   • sudo pdg migrate-fw 先迁标准部分, 再把自定义规则补到 inet pdg。"
    c_y "  现状: 旧 inet filter 不动(证书 hook/doctor 已兼容它, 不迁也能正常用)。"
    rm -f "$tmp"; return 0
  fi
  c_g "检测到旧版(原装)防火墙 → 迁移到独立表 inet pdg (SSH=$port, 内网段=$cidr)…"
  sed -e "s/__SSH_PORT__/$port/g" -e "s#__INTERNAL_CIDR__#$cidr#g" \
      "$REPO_DIR/deploy/firewall/nftables-mihomo.conf" > "$tmp"
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


# 老装迁移: 防火墙内网放行集补 5228-5230(GMS/FCM 推送 mtalk.google.com 的原生端口;
# mihomo 靠 nft 把它们 REDIRECT 进 redir 端口再嗅 SNI 分流)。幂等。
# 只动"原装形态"的那一行(严格匹配现行端口集); 自定义端口集不碰, 提示手动加。
# $1 可指定文件(供测试), 默认 /etc/nftables.conf; 测试时 nft 可用函数打桩。
# shellcheck disable=SC2120  # $1 仅测试注入, 生产调用不传参
migrate_fw_gms(){
  local f="${1:-/etc/nftables.conf}"
  [[ "$(_pdg_platform 2>/dev/null)" == ios ]] && return 0     # GMS/FCM 仅 Android; iOS 不放行 5228-5230
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

# ── iOS 生命周期这一组的整组落盘 ───────────────────────────────────────────
# 快照落盘只**覆盖**成员: 快照里没有的文件原样留在盘上。对绝大多数目标这是对的 —— 回滚不该
# 顺手删掉用户后来加的东西。iOS 生命周期是例外, 因为 ios-profile.json 与 current/previous
# 不是三份独立配置, 而是**一一对应的一组**:
#     rev1 打快照(那时还没有 previous) → 生成 rev2(previous 出现) → 回滚到 rev1
# 记录回到"没有上一版", 盘上却躺着一份 previous.mobileconfig。它属于一个已经不存在的版本,
# 没有任何记录能解释它是什么; 备份会把它一起打包, 下一次恢复就把这份自相矛盾的东西搬到另
# 一台机器上 —— 全程不报任何错。
#
# 所以这一组按"整组替换"来做, 而且**只对这一组**: /etc/privdns-gateway 下的其它文件、
# /var/lib/privdns-gateway 下的事务记录、救援运行态、备份包一律不碰。
#
# 顺序上有一条硬要求: **底片必须在 tar 覆盖之前拍完**。tar 是先覆盖再对账的, 等对账失败时
# ios-profile.json 与 current.mobileconfig 早已被旧快照盖掉 —— 那时候只把删掉的孤儿放回去,
# 留下的是"记录来自旧快照、产物新旧混着"的半回滚状态, 比不回滚更难查。
_PDG_IOS_STATE_REL="etc/privdns-gateway/ios-profile.json"
_PDG_IOS_ART_REL="var/lib/privdns-gateway/ios-profile"

# 快照里有没有这一组成员。没有(5.4 之前的快照)⇒ 它对这组文件没有发言权, 一个字节都不动。
_pdg_ios_group_in_members(){
  grep -qE "^($_PDG_IOS_ART_REL(/|\$)|$_PDG_IOS_STATE_REL\$)" "$1"
}

# 把这一组现在的样子逐项列出来(相对路径, NUL 分隔): 记录 + 整棵产物子树。
_pdg_ios_group_rels(){
  local dest="$1" f
  local dir="${dest%/}/$_PDG_IOS_ART_REL"
  printf '%s\0' "$_PDG_IOS_STATE_REL"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' f; do
    printf '%s\0' "$_PDG_IOS_ART_REL/${f#"$dir"/}"
  done < <(find "$dir" -mindepth 1 ! -type d -print0 2>/dev/null)
}

# 拍一张**完整底片**: 存在/缺失 + 内容 + mode + uid + gid。任何一项拍不下就整体失败 ——
# 没有底片就没有退路, 那种情况下宁可不落盘。
_pdg_ios_capture(){
  local dest="$1" bak="$2" rel f st
  mkdir -p -- "$bak/files" 2>/dev/null || return 1
  : > "$bak/manifest" 2>/dev/null || return 1
  : > "$bak/names" 2>/dev/null || return 1
  while IFS= read -r -d '' rel; do
    f="${dest%/}/$rel"
    printf '%s\n' "$rel" >> "$bak/names" || return 1
    if [[ -e "$f" || -L "$f" ]]; then
      # 软链/特殊文件在这一组里说不清"操作前是什么", 也不该被当成产物 —— 拒绝落盘。
      [[ -f "$f" && ! -L "$f" ]] || return 1
      st="$(stat -c '%a %u %g' -- "$f" 2>/dev/null)" || return 1
      [[ -n "$st" ]] || return 1
      mkdir -p -- "$(dirname -- "$bak/files/$rel")" 2>/dev/null || return 1
      cp -a -- "$f" "$bak/files/$rel" 2>/dev/null || return 1
      cmp -s -- "$f" "$bak/files/$rel" 2>/dev/null || return 1
      printf 'F %s %s\n' "$st" "$rel" >> "$bak/manifest" || return 1
    else
      printf 'A - - - %s\n' "$rel" >> "$bak/manifest" || return 1
    fi
  done < <(_pdg_ios_group_rels "$dest")
  [[ -s "$bak/manifest" ]] || return 1
  return 0
}

# 按底片把整组退回操作前, 然后**逐项复核**内容/存在性/mode/uid/gid。
# 未恢复项打到 stdout(每行一条), 调用方连同原始错误一起报给用户 —— 退回本身失败的时候,
# 人必须知道盘上现在到底是什么。
_pdg_ios_rollback(){
  local dest="$1" bak="$2" kind mode uid gid rel f rc=0
  local dir="${dest%/}/$_PDG_IOS_ART_REL"
  if [[ ! -s "$bak/manifest" ]]; then
    echo "底片清单缺失, 无法退回"; return 1
  fi
  while read -r kind mode uid gid rel; do
    [[ -n "$rel" ]] || continue
    f="${dest%/}/$rel"
    if [[ "$kind" == F ]]; then
      mkdir -p -- "$(dirname -- "$f")" 2>/dev/null
      if ! cp -a -- "$bak/files/$rel" "$f" 2>/dev/null; then
        echo "$rel(写不回去)"; rc=1; continue
      fi
      chmod -- "$mode" "$f" 2>/dev/null || { echo "$rel(权限没改回去)"; rc=1; }
      if [[ "$(stat -c '%u %g' -- "$f" 2>/dev/null)" != "$uid $gid" ]]; then
        chown -- "$uid:$gid" "$f" 2>/dev/null || { echo "$rel(属主没改回去)"; rc=1; }
      fi
    else
      rm -f -- "$f" 2>/dev/null || true
    fi
  done < "$bak/manifest"
  # 底片里没有、盘上却有的: 这次落盘新造出来的, 清掉才叫"回到操作前"
  if [[ -d "$dir" ]]; then
    while IFS= read -r -d '' f; do
      rel="$_PDG_IOS_ART_REL/${f#"$dir"/}"
      grep -qxF -- "$rel" "$bak/names" && continue
      rm -f -- "$f" 2>/dev/null || true
    done < <(find "$dir" -mindepth 1 ! -type d -print0 2>/dev/null)
  fi
  # 复核: 该在的内容/权限/属主都对, 该没有的确实没有, 且没有多出来的
  while read -r kind mode uid gid rel; do
    [[ -n "$rel" ]] || continue
    f="${dest%/}/$rel"
    if [[ "$kind" == F ]]; then
      cmp -s -- "$bak/files/$rel" "$f" 2>/dev/null || { echo "$rel(内容与操作前不符)"; rc=1; }
      [[ "$(stat -c '%a %u %g' -- "$f" 2>/dev/null)" == "$mode $uid $gid" ]] \
        || { echo "$rel(mode/属主与操作前不符)"; rc=1; }
    else
      [[ -e "$f" ]] && { echo "$rel(操作前不存在, 现在还在)"; rc=1; }
    fi
  done < "$bak/manifest"
  if [[ -d "$dir" ]]; then
    while IFS= read -r -d '' f; do
      rel="$_PDG_IOS_ART_REL/${f#"$dir"/}"
      grep -qxF -- "$rel" "$bak/names" || { echo "$rel(操作前没有这一份)"; rc=1; }
    done < <(find "$dir" -mindepth 1 ! -type d -print0 2>/dev/null)
  fi
  return $rc
}

# 删掉快照里没有的那些(孤儿)。不再自己做备份/回退 —— 底片由 _pdg_apply_snapshot_tree
# 在动手之前统一拍好, 这里只负责"删干净并复核", 失败交给调用方整组退回。
_pdg_ios_reconcile(){
  local members="$1" dest="$2"
  local dir="${dest%/}/$_PDG_IOS_ART_REL" f rel
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' f; do
    rel="$_PDG_IOS_ART_REL/${f#"$dir"/}"
    grep -qxF -- "$rel" "$members" && continue      # 快照里有 ⇒ 刚刚已被覆盖, 不动
    rm -f -- "$f" 2>/dev/null || return 1
    [[ -e "$f" ]] && return 1                       # rm 谎报成功(只读挂载/被 LSM 拦下)
  done < <(find "$dir" -mindepth 1 ! -type d -print0 2>/dev/null)
  while IFS= read -r -d '' f; do                    # 复核: 剩下的每一份都必须在清单里
    rel="$_PDG_IOS_ART_REL/${f#"$dir"/}"
    grep -qxF -- "$rel" "$members" || return 1
  done < <(find "$dir" -mindepth 1 ! -type d -print0 2>/dev/null)
  return 0
}

# 覆盖任何生产文件**之前**, 对解包出来的临时树做联合校验 —— 与 Bot 备份恢复、救援平面
# 受管恢复走的是同一份判据(iosstate.plan_restore)。
# 不能靠"这是本机快照所以一定可信": 快照可能损坏、被替换、或者上一次只恢复了一半; 而这一组
# 恢复完之后就是「📱 iOS 描述文件」页发给用户安装的东西。
_pdg_ios_verify_tree(){
  local tree="$1" members="$2" mod="" out=""
  _pdg_ios_group_in_members "$members" || return 0    # 快照里没有这一组 ⇒ 无话可说
  if ! mod="$(_pdg_module iosstate.py)"; then
    echo "❌ 快照里带着 iOS 描述文件生命周期, 但找不到校验它的 iosstate.py —— 中止(现网未改动)"
    return 1
  fi
  if ! out="$(python3 "$mod" verify-restore --tree "$tree" 2>&1)"; then
    echo "❌ 快照里的 iOS 描述文件没通过联合校验, 已中止(现网一个字节都没改):"
    printf '%s\n' "$out" | sed 's/^/   /'
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/  /'
  return 0
}

# 按原归档成员清单把已验证临时树落到目标根；不递归顶层隐式父目录，避免误改 /etc、/opt 元数据。
_pdg_apply_snapshot_tree(){
  local tree="$1" members="$2" dest="$3"
  [[ -d "$tree" && -s "$members" && -d "$dest" ]] || return 1
  local guard=0 bak="" why="" left=""
  if _pdg_ios_group_in_members "$members"; then
    guard=1
    if ! bak="$(_pdg_mktemp_dir)"; then
      echo "❌ 建不出 iOS 生命周期的底片目录 → 拒绝落盘(没有底片就没有退路)"; return 1
    fi
    if ! _pdg_ios_capture "$dest" "$bak"; then
      echo "❌ 拍不下 iOS 生命周期的完整底片(记录 + 产物子树) → 拒绝落盘, 现网未被改动"
      rm -rf -- "$bak"; return 1
    fi
  fi
  if ! ( set -o pipefail
         tar --no-recursion -cf - -C "$tree" -T "$members" 2>/dev/null \
           | tar xpf - -C "$dest" 2>/dev/null ); then
    why="快照落盘(tar)失败"
  elif (( guard == 1 )) && ! _pdg_ios_reconcile "$members" "$dest"; then
    why="iOS 产物目录对账失败"
  fi
  if [[ -n "$why" ]]; then
    if (( guard == 1 )); then
      if left="$(_pdg_ios_rollback "$dest" "$bak")"; then
        echo "❌ $why —— iOS 生命周期(记录 + 产物子树)已整组退回操作前"
      else
        echo "❌ $why —— 而且退回没有完全成功, 请立即检查:"
        printf '%s\n' "$left" | sed 's/^/   未恢复: /'
      fi
      rm -rf -- "$bak"
    else
      echo "❌ $why"
    fi
    return 1
  fi
  [[ -n "$bak" ]] && rm -rf -- "$bak"
  return 0
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

# 供 cmd_update 读取"本次刚创建的快照目录"(精确回滚目标, 不靠 index 0 猜)。
_PDG_SNAP_CREATED=""
# ── 快照来源元数据 ───────────────────────────────────────────────────────────
# 光有时间戳目录名回答不了"这份快照是谁拍的": 手动拍的、更新前自动拍的、平台切换前拍的、
# 显式迁移前拍的、救援完整恢复前拍的 —— 出事时想回到"那次操作之前"却分不出是哪一次。
#
# 只写固定枚举 + 版本信息。不写 token / 证书正文 / 私钥 / 配置正文 / URL / 命令参数 ——
# 快照目录是 0700, 但这份元数据将来会被列出来给人看, 值必须是**闭集**里的东西。
_SNAP_SOURCES=" cli rescue bot scheduler "
_SNAP_OPS=" snapshot update platform migrate pre-full-restore "
_SNAP_META_SCHEMA=1

# 写元数据。临时文件 + 原子替换; 失败返回非 0(调用方据此把整份快照作废)。
_snap_meta_write(){
  local d="$1" id="$2" src="$3" op="$4" tmp commit desc
  [[ "$_SNAP_SOURCES" == *" $src "* ]] || { echo "内部错误: 未知快照来源 $src" >&2; return 1; }
  [[ "$_SNAP_OPS"     == *" $op "*  ]] || { echo "内部错误: 未知快照操作 $op"  >&2; return 1; }
  commit="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
  desc="$(git -C "$REPO_DIR" describe --tags 2>/dev/null)"
  # 只留标签/哈希会用到的字符: 仓库里理论上不会有别的, 但这份文件要展示给人看, 不放行任意串。
  commit="$(printf '%s' "${commit:-unknown}" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  desc="$(printf '%s' "${desc:-unknown}"     | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  tmp="$(mktemp "$d/.snapshot.json.XXXXXX" 2>/dev/null)" || return 1
  {
    printf '{\n'
    printf '  "schema_version": %s,\n' "$_SNAP_META_SCHEMA"
    printf '  "snapshot_id": "%s",\n'  "$id"
    printf '  "created_at": "%s",\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "source": "%s",\n'       "$src"
    printf '  "op": "%s",\n'           "$op"
    printf '  "git_commit": "%s",\n'   "${commit:-unknown}"
    printf '  "git_describe": "%s"\n'  "${desc:-unknown}"
    printf '}\n'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$d/snapshot.json" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# 读来源, 供列表展示。老快照没有这个文件 —— 那是**正常的跨版本形态**, 显示"未知"而不是报错。
# 元数据坏了也只当未知: 绝不 eval / source 它, 也不因为它坏了就挡住回滚。
_snap_meta_label(){
  local d="$1" j="$1/snapshot.json"
  [[ -f "$j" ]] || { echo "来源未知(旧快照)"; return 0; }
  python3 - "$j" 2>/dev/null <<'PY' || echo "来源未知(元数据无法解析)"
import json, re, sys
try:
    m = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
ok = re.compile(r"^[A-Za-z0-9._:+-]{0,64}$")
src, op = str(m.get("source", "")), str(m.get("op", ""))
ver = str(m.get("git_describe", ""))
if not (ok.match(src) and ok.match(op) and ok.match(ver)) or not src or not op:
    raise SystemExit(1)
print("%s/%s  %s" % (src, op, ver or "-"))
PY
}

cmd_snapshot(){
  need_root snapshot; _lock
  _PDG_SNAP_CREATED=""
  local src=cli op=snapshot
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) src="${2:-}"; shift 2 || { echo "--source 缺参数"; return 1; };;
      --op)     op="${2:-}";  shift 2 || { echo "--op 缺参数"; return 1; };;
      *) shift;;                      # 旧调用方可能带别的参数, 忽略即可(向后兼容)
    esac
  done
  local ts d; ts=$(date +%Y%m%d-%H%M%S); d="$SNAP_DIR/$ts"
  # 目录名是秒级的, 同一秒内拍第二份会**撞名**。以前撞了就直接覆盖(悄悄弄丢前一份);
  # 现在元数据写失败要 rm -rf 这个目录, 撞名就会把**别人那一份**删掉 —— 所以宁可等一秒
  # 换个名字, 也不复用。ID 形态必须保持 %Y%m%d-%H%M%S: 救援侧 cfgrestore 按这个正则认。
  if [[ -e "$d" ]]; then
    sleep 1; ts=$(date +%Y%m%d-%H%M%S); d="$SNAP_DIR/$ts"
    [[ -e "$d" ]] && { c_y "❌ 同名快照目录已存在($ts), 为避免覆盖已有快照, 本次未创建。"; return 1; }
  fi
  install -d -m700 "$d"
  # 整机配置 + 防火墙 + bot.env(含 token)+ service + journald 封顶(含历史错路径)(相对 / 打包, 回滚 -C / 解开)
  # 含: 已安装脚本(pdg / pdg-set-token / cert hook)+ 全部 pdg unit —— 升级会改它们, 回滚要一并还原。
  # 只打包"存在的"路径 —— 历史错路径可能已被迁移清掉, 无条件列进去会让 tar 报 Cannot stat 并返 2。
  # var/lib/.../ios-profile 是唯一进快照的 /var/lib 成员: iOS 描述文件产物。它不是缓存 ——
  # previous 那一版用的根证书只在产物里有正文(元数据里只有指纹), 不打包就永远回不来了。
  # 清单里的 etc/sing-box 与 usr/local/bin/sing-box 是**跨版本回滚要用到**的: 少了它们,
  # 把旧机器恢复到更早版本就会缺内核。v2.0 清理前提见 docs/ROADMAP.md。
  local cand=(etc/mosdns etc/sing-box etc/mihomo opt/pdg-bot etc/privdns-gateway etc/nftables.conf
              var/lib/privdns-gateway/ios-profile
              etc/systemd/system/pdg-bot.service etc/systemd/journald.conf.d/50-pdg.conf
              etc/systemd/system/journald.conf.d/50-pdg.conf
              etc/systemd/system/mihomo.service etc/systemd/system/sing-box.service
              etc/systemd/system/pdg-mitm.service etc/systemd/system/pdg-probe81.service
              etc/systemd/system/pdg-rules-update.service etc/systemd/system/pdg-rules-update.timer
              etc/systemd/system/pdg-health.service etc/systemd/system/pdg-health.timer
              etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh
              usr/local/bin/pdg usr/local/bin/pdg-set-token
              usr/local/bin/mihomo usr/local/bin/sing-box
              usr/local/bin/proxy-gateway-open-cert-http.sh usr/local/bin/proxy-gateway-restore-firewall.sh)
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
  # 元数据写不成 → 整份作废。留下"有归档、没来源"的新格式快照比没有更糟: 列表会把它显示成
  # 旧快照, 而它其实是本次刚拍的, 于是"这份到底是哪次操作之前的"永远说不清了。
  if ! _snap_meta_write "$d" "$ts" "$src" "$op"; then
    c_y "❌ 快照元数据写入失败 → 本次快照作废(未留下半份)"; rm -rf "$d"; return 1
  fi
  _PDG_SNAP_CREATED="$d"
  echo "✅ 快照: $d/snap.tar.gz ($src/$op)"
  ls -1dt "$SNAP_DIR"/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf   # 只留最近 10 份
}

cmd_rollback(){
  need_root rollback; _lock
  # 参数: <序号>(默认0) | --dir <快照目录>(精确指定, 供 update 用) | --git <ref>(回滚后把 REPO_DIR 复位到该提交)
  local idx="" dir="" git_ref="" target preserve=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="${2:-}"; shift 2 || { echo "--dir 缺参数"; return 1; };;
      --git) git_ref="${2:-}"; shift 2 || { echo "--git 缺参数"; return 1; };;
      # 救援平面内部固定模式: **事前排除**救援自身的文件, 并让恢复出来的 nft 候选自带救援
      # 放行。只有这一个固定开关 —— 不提供 `--exclude <path>` 之类的任意排除, 否则"完整恢复"
      # 可以被指定成"什么都不恢复"。普通 CLI 不传它时行为与历史完全一致。
      --preserve-rescue) preserve=1; shift;;
      *) idx="$1"; shift;;
    esac
  done
  if [[ -n "$dir" ]]; then
    target="$dir"; [[ -d "$target" ]] || { echo "指定快照目录不存在: $target"; return 1; }
  else
    local snaps; mapfile -t snaps < <(ls -1dt "$SNAP_DIR"/*/ 2>/dev/null)
    [[ ${#snaps[@]} -gt 0 ]] || { echo "没有快照(先 pdg snapshot)"; return 1; }
    echo "可用快照(新→旧):"; local i=0
    for s in "${snaps[@]}"; do
      # 时间来自目录名(%Y%m%d-%H%M%S), 来源来自 snapshot.json; 老快照没有那个文件 → "来源未知"。
      echo "  [$i] $(basename "$s")  $(_snap_meta_label "${s%/}")"; i=$((i+1))
    done
    idx="${idx:-0}"
    [[ "$idx" =~ ^[0-9]+$ ]] || { echo "无效序号 $idx"; return 1; }
    idx=$((10#$idx))
    (( idx >= ${#snaps[@]} )) && { echo "无效序号 $idx"; return 1; }
    target="${snaps[$idx]}"
  fi
  local f="$target/snap.tar.gz"
  [[ -f "$f" ]] || { echo "快照文件缺失: $f"; return 1; }
  # 先完整解包、净化并校验临时树，再把同一棵树落盘；坏包/净化失败不碰现网。
  local tmp="" tree="" members="" panel_sanitized=0
  if ! tmp="$(_pdg_mktemp_dir)"; then echo "❌ 无法创建回滚临时目录"; return 1; fi
  tree="$tmp/tree"; members="$tmp/members"
  if ! mkdir -p "$tree" || ! tar tzf "$f" > "$members" 2>/dev/null || [[ ! -s "$members" ]]; then
    echo "❌ 快照目录或成员清单读取失败, 中止"; rm -rf "$tmp"; return 1
  fi
  # 越界守卫的前缀集必须与 cmd_snapshot 的候选集对齐。放行 var/lib 下的**那一个子树**而不是
  # 整个 var/lib: 快照里本来就不该有 tx 记录、救援运行态、备份包这些东西, 放宽到 var/lib
  # 等于让一份构造出来的快照可以往那里写任意文件。
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$members" \
     || grep -Evq '^(etc|opt|usr/local/bin|var/lib/privdns-gateway/ios-profile)(/|$)' "$members"; then
    echo "❌ 快照含越界路径, 中止"; rm -rf "$tmp"; return 1
  fi
  if ! tar xzf "$f" -C "$tree" 2>/dev/null; then
    echo "❌ 快照解包失败, 中止"; rm -rf "$tmp"; return 1
  fi
  if (( preserve == 1 )); then
    # **事前排除**: 受保护成员既不进落盘清单, 也从 staging 里删掉 —— 于是生产上的救援文件
    # 从头到尾没有被覆盖过, 不存在"先覆盖再补回来"的那一瞬。
    # shellcheck source=lib/rescue.sh
    if ! source "$REPO_DIR/lib/rescue.sh" 2>/dev/null && ! source /opt/pdg-bot/rescue.sh 2>/dev/null; then
      echo "❌ 读不到救援保护清单(lib/rescue.sh), 拒绝在无保护的情况下执行完整恢复"
      rm -rf "$tmp"; return 1
    fi
    local _prot _kept="$tmp/members.kept"
    : > "$_kept"
    while IFS= read -r _m; do
      [[ -n "$_m" ]] || continue
      _prot=0
      while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        [[ "$_m" == "$_p" || "$_m" == "$_p/" ]] && { _prot=1; break; }
      done < <(pdg_rescue_protected)
      if (( _prot == 1 )); then
        rm -f -- "$tree/$_m" 2>/dev/null || true      # staging 里也不留, 免得被后续步骤用到
        echo "  保留当前救援平面文件(不恢复): $_m"
      else
        printf '%s\n' "$_m" >> "$_kept"
      fi
    done < "$members"
    mv -f "$_kept" "$members"
  fi
  if _sb_panel_managed_on "$tree/etc/sing-box/config.json"; then
    if ! _sb_sanitize_panel "$tree/etc/sing-box/config.json"; then
      echo "❌ 快照面板临时态净化失败, 中止"; rm -rf "$tmp"; return 1
    fi
    panel_sanitized=1
  fi
  # 内核配置校验(v1.6.0 只剩 mihomo)。快照带 mihomo 配置就用 mihomo 校验(优先用快照自带的
  # mihomo 二进制 —— 拿刚升上来的新核校验旧配置可能误挡回滚)。迁移前(singbox)快照没有 mihomo
  # 配置, 此处不拦, 留待落盘后从还原出的 config.json 现渲染再核验(见下方内核收尾)。
  local snap_mbin=""
  [[ -x "$tree/usr/local/bin/mihomo" ]] && snap_mbin="$tree/usr/local/bin/mihomo"
  if [[ -f "$tree/etc/mihomo/config.yaml" ]]; then
    "${snap_mbin:-mihomo}" -t -d "$tree/etc/mihomo" -f "$tree/etc/mihomo/config.yaml" >/dev/null 2>&1 \
      || { echo "❌ 快照的 mihomo 配置 check 失败, 中止"; rm -rf "$tmp"; return 1; }
  fi
  # 保护模式下: 在**staging 里**就把救援放行注入候选, 于是落盘的那份从一开始就带着它,
  # 后面只需要既有的那一次 `nft -f`。绝不做"先应用旧配置再补一条" —— 两次 apply 之间就是
  # 救援入口真实消失的窗口, 而完整恢复正是最需要它的时刻。
  if (( preserve == 1 )) && [[ -f "$tree/etc/nftables.conf" ]]; then
    local _rn _cidr _cand="$tmp/nft.cand"
    _rn="$(_pdg_module rescue_nft.py)" || { echo "❌ 找不到 rescue_nft.py, 拒绝在无救援放行的情况下恢复防火墙"; rm -rf "$tmp"; return 1; }
    _cidr="$(pdg_internal_cidr 2>/dev/null || true)"
    [[ -n "$_cidr" ]] || _cidr="$(grep -oE 'ip saddr [0-9.]+/[0-9]+' /etc/nftables.conf 2>/dev/null | head -1 | awk '{print $3}')"
    if [[ -z "$_cidr" ]]; then
      echo "❌ 读不到内网卡段, 无法生成带救援放行的防火墙候选 → 中止(不改动现网)"
      rm -rf "$tmp"; return 1
    fi
    if [[ -z "${PDG_RESCUE_PORT:-}" ]]; then
      echo "❌ 读不到救援端口常量(lib/rescue.sh), 拒绝生成防火墙候选"; rm -rf "$tmp"; return 1
    fi
    if ! python3 "$_rn" "$_cidr" "$PDG_RESCUE_PORT" < "$tree/etc/nftables.conf" > "$_cand"; then
      echo "❌ 生成带救援放行的防火墙候选失败 → 中止(不改动现网)"; rm -rf "$tmp"; return 1
    fi
    if ! nft -c -f "$_cand" >/dev/null 2>&1; then
      echo "❌ 带救援放行的防火墙候选校验(nft -c)未过 → 中止(磁盘与内核都未改动)"
      rm -rf "$tmp"; return 1
    fi
    mv -f "$_cand" "$tree/etc/nftables.conf" || { echo "❌ 写回候选失败, 中止"; rm -rf "$tmp"; return 1; }
  fi
  [[ -f "$tree/etc/nftables.conf" ]] && { nft -c -f "$tree/etc/nftables.conf" >/dev/null 2>&1 || { echo "❌ 快照的 nftables 语法错, 中止"; rm -rf "$tmp"; return 1; }; }
  # 覆盖生产文件之前先过联合校验(见 _pdg_ios_verify_tree)。不过就中止, 现网零改动。
  if ! _pdg_ios_verify_tree "$tree" "$members"; then
    rm -rf "$tmp"; return 1
  fi
  echo "回滚到 $(basename "$target") …"
  if ! _pdg_apply_snapshot_tree "$tree" "$members" /; then
    echo "❌ 快照落盘失败, 系统可能已部分恢复, 请立即检查"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  (( panel_sanitized == 1 )) && c_g "  已净化回滚出的面板临时态 → 关闭"
  local unrestored=()                         # 未能恢复项(内核激活/仓库Git); 非空即"未完全回滚"
  # daemon-reload 失败必须计入: 后面 enable/start 全建立在它之上, 吞掉它等于谎报回滚成功。
  systemctl daemon-reload || unrestored+=("daemon-reload")
  nft -f /etc/nftables.conf 2>/dev/null || true
  # v1.6.0: mihomo 是唯一内核。无论快照记录的是 mihomo 还是迁移前的 singbox, 一律起 mihomo ——
  # config.json 是核无关数据模型, mihomo 总能从它渲染。并清掉快照可能带回来的 sing-box 残留。
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/units.sh" 2>/dev/null || true
  if [[ ! -f /etc/mihomo/config.yaml ]] && [[ -f /etc/sing-box/config.json ]]; then
    install -d -m700 /etc/mihomo                # 迁移前快照只有 config.json → 现渲染 mihomo 配置
    (cd /opt/pdg-bot && python3 -c 'import sys;sys.path.insert(0,"/opt/pdg-bot");import bot;bot._render_mihomo_file()') 2>/dev/null \
      || unrestored+=("mihomo配置渲染")
  fi
  printf 'mihomo\n' > /etc/privdns-gateway/backend
  # 快照里已经带回 unit 的就别再重生成 —— 快照那份才是"回滚目标状态"的权威。
  # 只有快照没有(或空文件)时才用模板补一份, 免得回滚顺手把状态又改成了当前版本的样子。
  if [[ ! -s /etc/systemd/system/mihomo.service ]]; then
    pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service \
      || unrestored+=("mihomo.service 生成")
  fi
  # sing-box 残留只清"项目自己装的"(见 _pdg_singbox_is_ours), 第三方的原样保留
  _pdg_drop_singbox_files "快照带回的"
  systemctl daemon-reload || unrestored+=("daemon-reload(清理后)")
  # 激活失败必须计入 unrestored: 内核没起来就不是"已回滚", 不能只 warn 后照报成功。
  if ! _core_kernel_activate mihomo sing-box; then
    c_y "  mihomo 起核核验未达标, 请 pdg doctor 复查"
    unrestored+=("内核激活(mihomo)")
  fi
  # 明确列出要重启的 unit, 绝不用 `pdg-*` 之类的通配 —— 那会把救援服务一起重启掉。
  systemctl restart mosdns pdg-bot pdg-probe81 2>/dev/null || true
  systemctl is-enabled pdg-mitm >/dev/null 2>&1 && { systemctl reset-failed pdg-mitm 2>/dev/null; systemctl restart pdg-mitm 2>/dev/null; }   # iOS/WLOC: 清 start-limit + 一并恢复 MITM 服务
  systemctl restart systemd-journald 2>/dev/null || true   # journald CanReload=no: 还原封顶需 restart 才生效
  # 仓库 Git 复位(update 回滚: 让 REPO_DIR 与还原出的旧脚本版本一致); 记录未能恢复项, 不谎报"完全回滚"
  if [[ -n "$git_ref" ]]; then
    if [[ -d "$REPO_DIR/.git" ]] && git -C "$REPO_DIR" reset --hard -q "$git_ref" 2>/dev/null; then
      c_g "  仓库已复位到 ${git_ref:0:12}"
    else
      unrestored+=("仓库Git($git_ref)")
    fi
  fi
  if [[ ${#unrestored[@]} -eq 0 ]]; then
    echo "✅ 已回滚并重启服务"
  else
    c_y "⚠️ 已回滚配置/服务, 但以下项未能恢复(未完全回滚): ${unrestored[*]}"
    return 1
  fi
}

# 内核二进制目录(默认 /usr/local/bin; 测试可用 PDG_CORE_BINDIR 指到沙箱)。
_core_bindir(){ echo "${PDG_CORE_BINDIR:-/usr/local/bin}"; }

# 用**刚装上的**新内核二进制对现网配置跑 check(显式走路径, 不依赖 PATH)。
_core_config_check(){
  local svc="$1" bindir="$2"   # svc 恒为 mihomo(v1.6.0 唯一内核); 保留形参以兼容调用方
  "$bindir/mihomo" -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1
}

# 内核活性 + 稳定判定: 起得来, 且持续观察若干次仍在跑。
# 只抽两次 is-active 挡不住"起来即崩": systemd 会把它反复拉起, 每次抽样都可能正好撞上
# 刚起来的那一瞬。故再比对 NRestarts —— 观察窗口内重启计数涨了就是崩溃循环。
_core_kernel_stable(){
  local svc="$1" i n="${PDG_STABLE_SAMPLES:-3}" r0 r1
  r0="$(systemctl show -p NRestarts --value "$svc" 2>/dev/null)"; r0="${r0:-0}"
  for ((i = 0; i < n; i++)); do
    [[ "$(systemctl is-active "$svc" 2>/dev/null)" == active ]] || return 1
    sleep 1
  done
  r1="$(systemctl show -p NRestarts --value "$svc" 2>/dev/null)"; r1="${r1:-0}"
  [[ "$r0" == "$r1" ]] || { c_y "  $svc 在观察窗口内重启了($r0→$r1), 判为不稳定"; return 1; }
  [[ "$(systemctl is-active "$svc" 2>/dev/null)" == active ]]
}

_pdg_sha(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 把当前内核二进制备份到**本次事务专属**的临时文件, 回显 "备份路径|SHA256"。
# 用 mktemp 而不是固定的 <svc>.prev: 固定名会撞上历史遗留的 .prev —— 备份没拷成时
# 那个来源不明的旧文件会在还原那步被 mv 成正在跑的内核。
# 旧内核存在但备份没做成 → 返回非 0, 调用方必须中止, 绝不能去装新内核。
_core_stash_kernel(){
  local svc="$1" bindir="$2" tmp sha
  local bin="$bindir/$svc"
  [[ -e "$bin" ]] || { echo "|"; return 0; }        # 装前没有旧内核: 没什么可备份
  sha="$(_pdg_sha "$bin")"; [[ -n "$sha" ]] || return 1
  tmp="$(mktemp "$bindir/.$svc.pdg-prev.XXXXXX" 2>/dev/null)" || return 1
  if ! cp -a "$bin" "$tmp" 2>/dev/null || [[ "$(_pdg_sha "$tmp")" != "$sha" ]]; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  echo "$tmp|$sha"
}

# 还原本次事务备份的旧内核并重新拉起。逐项校验: mv 成功 → 内容 SHA 与备份一致 →
# 旧服务 active 且稳定。任一步不达标返回非 0(只看"服务 active"不算数)。
_core_restore_prev(){
  local svc="$1" bindir="${2:-$(_core_bindir)}" bak="${3:-}" sha="${4:-}"
  local bin="$bindir/$svc"
  if [[ -n "$bak" ]]; then
    [[ -e "$bak" ]] || { c_y "  旧内核备份不存在($bak), 无法还原"; return 1; }
    mv -f "$bak" "$bin" 2>/dev/null || { c_y "  旧内核还原失败(mv)"; return 1; }
    if [[ -n "$sha" && "$(_pdg_sha "$bin")" != "$sha" ]]; then
      c_y "  旧内核还原后校验和与备份不符"; return 1
    fi
  fi
  systemctl restart "$svc" 2>/dev/null || true
  _core_kernel_stable "$svc" || { c_y "  旧内核重启后未稳定运行"; return 1; }
}

# 内核热切(mihomo/sing-box 同一套): 备份旧核 → 装新 → 配置 check → 重启 → 活性/稳定判定。
# 关键安全: **确认新核已稳定运行后才删 .prev**; 在此之前任一步失败都还原旧核并 return 1
# (旧实现在 check 通过时就删了 .prev, 新核重启失败便无核可退)。
_core_swap_verify(){
  local svc="$1" newbin="$2" bindir="$3" ver="$4"
  local bin="$bindir/$svc" stash bak="" sha=""
  # 备份必须先成: 拷不下来就在这里停, 绝不能带着"无核可退"的状态去装新内核。
  if ! stash="$(_core_stash_kernel "$svc" "$bindir")"; then
    c_y "  备份现有 $svc 失败 → 中止换核(不在无法回退的前提下装新内核)。"; return 1
  fi
  IFS='|' read -r bak sha <<<"$stash"
  if ! install -m755 "$newbin" "$bin"; then
    c_y "  新内核安装失败, 还原旧版内核"
    _core_restore_prev "$svc" "$bindir" "$bak" "$sha" || c_y "  ⚠️ 旧版内核回退未达标, 请立即 pdg doctor"
    return 1
  fi
  if ! _core_config_check "$svc" "$bindir"; then
    c_y "  新版与当前配置不兼容(check 失败), 已还原旧版内核"
    _core_restore_prev "$svc" "$bindir" "$bak" "$sha" || c_y "  ⚠️ 旧版内核回退未达标, 请立即 pdg doctor"
    return 1
  fi
  systemctl restart "$svc" 2>/dev/null || true
  if ! _core_kernel_stable "$svc"; then
    c_y "  新版内核重启后未稳定运行, 已还原旧版内核并重启"
    _core_restore_prev "$svc" "$bindir" "$bak" "$sha" || c_y "  ⚠️ 旧版内核回退未达标, 请立即 pdg doctor"
    return 1
  fi
  [[ -n "$bak" ]] && rm -f "$bak" 2>/dev/null    # 到此新核确认可用, 旧核备份才可以删
  c_g "  → $svc $ver 已装并重启"
}

# 内核二进制更新: 比对 versions.sh 钉死版本与已装版本, 不一致则下载+SHA校验+装。
# 关键安全: 先备份旧二进制, 用新二进制对现有配置跑 check + 重启稳定判定, 全过才切换; 失败还原旧版, 不留坏内核。
# 返回: 0=已是钉死版/下载或校验失败(保留现版本, 非致命); 1=换核失败(已还原) → 调用方须回滚整次更新。
_update_core_binary(){
  local march ver tmp bindir   # v1.6.0: mihomo 是唯一内核
  bindir="$(_core_bindir)"
  # shellcheck source=/dev/null
  # 读不到 versions.sh 就无从知道该装哪个版本 —— 以前"跳过"后照报成功, 实际内核可能没升上去。
  source "$REPO_DIR/lib/versions.sh" 2>/dev/null \
    || { c_y "读不到 versions.sh, 无法确认内核目标版本"; return 1; }
  march=$(dpkg --print-architecture 2>/dev/null); [[ "$march" == arm64 ]] || march=amd64
  tmp=$(mktemp -d)
  ver="$MIHOMO_VER"
  pdg_mihomo_is_version "$ver" && { rm -rf "$tmp"; return 0; }   # 已是钉死版本(精确比较, 非子串)
  c_g "更新 mihomo 内核 → $ver …"
  curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${march}-${ver}.gz" -o "$tmp/m.gz" \
    || { c_y "  下载失败(版本与发布不一致, 不能当作已更新)"; rm -rf "$tmp"; return 1; }
  pdg_verify_sha256 "$tmp/m.gz" "${PDG_SHA256[mihomo-$march]:-}" "mihomo $ver ($march)" \
    || { c_y "  SHA 校验失败 → 判为更新失败(不降级成警告后继续)"; rm -rf "$tmp"; return 1; }
  gunzip -c "$tmp/m.gz" > "$tmp/mihomo" || { c_y "  解压失败"; rm -rf "$tmp"; return 1; }
  [[ -s "$tmp/mihomo" ]] || { c_y "  解压产物为空"; rm -rf "$tmp"; return 1; }
  if ! _core_swap_verify mihomo "$tmp/mihomo" "$bindir" "$ver"; then rm -rf "$tmp"; return 1; fi
  rm -rf "$tmp"
}

cmd_update(){
  need_root update
  # --dry-run 只查看: 不装 git、不迁移、不写任何东西。任一步失败都要返回非 0 并说清是哪一步 ——
  # 以前 fetch/describe/tag 全用 `2>/dev/null` 吞掉, 拿不到就打印"最新发布: (无 tag)"再 return 0,
  # 用户会当成"已经是最新版", 实际是网络不通或仓库读不了。
  if [[ "${1:-}" == "--dry-run" ]]; then
    command -v git >/dev/null 2>&1 || { c_y "❌ 没有 git, 无法查看更新(dry-run 不安装任何东西)"; return 1; }
    [[ -d "$REPO_DIR/.git" ]] || { c_y "❌ $REPO_DIR 不是 git 仓库, 无法查看更新"; return 1; }
    local cur_desc tgt
    if ! pdg_fetch_release_tags "$REPO_DIR"; then
      c_y "❌ 拉取远端 tag 失败(网络不通 / 仓库地址无效 / 属主异常)→ 无法判断是否有新版"; return 1
    fi
    if ! cur_desc="$(git -C "$REPO_DIR" describe --tags --always 2>/dev/null)" || [[ -z "$cur_desc" ]]; then
      c_y "❌ 读不到当前版本(git describe 失败: 仓库损坏 / 无提交 / 属主异常)"; return 1
    fi
    tgt="$(git -C "$REPO_DIR" tag -l 'v*' --sort=-v:refname 2>/dev/null | head -1)"
    [[ -n "$tgt" ]] || { c_y "❌ 仓库里没有任何发布 tag(v*)→ 无法确定目标版本"; return 1; }
    echo "当前: $cur_desc   最新发布: $tgt"
    echo "待更新提交(HEAD..$tgt):"
    git -C "$REPO_DIR" log --oneline "HEAD..$tgt" 2>/dev/null || echo "  (已是最新或无法比较)"
    return 0
  fi
  command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }
  _lock   # 取锁(嵌套的 cmd_snapshot 不会重复锁)
  c_g "更新前留快照…"
  if ! cmd_snapshot --source cli --op update >/dev/null 2>&1 || [[ -z "$_PDG_SNAP_CREATED" || ! -f "$_PDG_SNAP_CREATED/snap.tar.gz" ]]; then
    c_y "❌ 更新前快照失败, 中止更新(拒绝在无法回滚的前提下继续)。"; return 1
  fi
  local snap_dir="$_PDG_SNAP_CREATED"                                    # 精确回滚目标(不靠 index 0 猜)
  local pre_sha; pre_sha="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"   # 升级前精确提交, 回滚据此复位仓库
  c_g "拉取最新发布 tag…"
  [[ -d "$REPO_DIR/.git" ]] || { rm -rf "$REPO_DIR"; git clone -q "$REPO_URL" "$REPO_DIR"; }
  if ! pdg_fetch_release_tags "$REPO_DIR"; then
    c_y "拉取发布 tag 失败, 中止更新。"; return 1
  fi
  local tgt; tgt=$(git -C "$REPO_DIR" tag -l 'v*' --sort=-v:refname | head -1)
  if [[ -z "$tgt" ]]; then
    c_y "仓库没有发布 tag(v*), 中止更新。"; return 1
  fi
  if ! git -C "$REPO_DIR" reset --hard -q "$tgt"; then
    c_y "git reset 到 $tgt 失败, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  c_g "→ 已切到发布 $tgt"
  c_g "刷新代码(配置/出口/token/证书均不动)…"
  # 运行模块清单的单一事实源(与 install.sh 共用)。读不到就别装 —— 宁可这次不更新, 也不要
  # 按一份残缺的清单装出新旧混装。
  # shellcheck source=lib/modules.sh
  source "$REPO_DIR/lib/modules.sh" 2>/dev/null \
    || { c_y "读不到 lib/modules.sh(运行模块清单), 回滚到更新前快照…"
         cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1; }
  # 必需文件: 任一装失败即立即回滚(拒绝新旧混部)。`! A || ! B` 在首个失败处短路。
  # /opt/pdg-bot 下的项目静态文件**全部**走 lib/modules.sh 这一份 manifest(平台专属那批
  # 由 pdg_platform_modules 按平台取)。以前这里手写了五行、iOS 组件另有一段, 与 install.sh
  # 各写各的 —— 两边只要有一处忘了改就是新旧混装, 而那不会报错, 只会静默降级。
  if   ! pdg_install_runtime_modules "$REPO_DIR" /opt/pdg-bot "$(_pdg_platform)" \
    || ! install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-open-cert-http.sh   /usr/local/bin/ \
    || ! install -m755 "$REPO_DIR"/deploy/cert/proxy-gateway-restore-firewall.sh /usr/local/bin/ \
    || ! install -m755 "$REPO_DIR"/deploy/bot/pdg-set-token.sh     /usr/local/bin/pdg-set-token \
    || ! install -m755 "$REPO_DIR"/deploy/bot/pdg.sh               /usr/local/bin/pdg; then
    c_y "必需文件安装失败, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  # iOS 专属组件按平台部署: Android 更新不把 iOS 文件装回来(migrate_android_cleanup 亦会清残留)。
  # iOS 上这些**不是可选项**: probe81 与描述文件模板是 iOS 基础能力, WLOC 开着时 mitm 三件
  # 也是必需件。以前一律 `|| true`, 装失败就把上一版的旧文件留在原地 → 新旧混装, 而 doctor
  # 只看"文件在不在", 照样判绿。
  # iOS 专属组件已并入上面那一次调用(manifest 按平台取), 不再单列。
  install -m644 "$REPO_DIR"/deploy/bot/pdg-health.service  /etc/systemd/system/ 2>/dev/null || true
  install -m644 "$REPO_DIR"/deploy/bot/pdg-health.timer    /etc/systemd/system/ 2>/dev/null || true
  install -m755 "$REPO_DIR"/deploy/cert/99-reload-cert.deploy-hook.sh     /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh 2>/dev/null || true
  # 迁移用"刚装好的新脚本"跑(本进程还是旧 bash, 直接调会用旧版函数 → 新迁移要等下次命令才生效)。
  if ! bash /usr/local/bin/pdg __migrate; then
    c_y "迁移(__migrate)失败, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  # 内核二进制: mihomo 按 versions.sh 钉死版本更新。
  if ! _update_core_binary; then
    c_y "内核二进制更新失败, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi

  # ── 更新后校验门: 任一硬校验失败即回滚到更新前快照 ──
  c_g "校验新版本…"
  if ! python3 -m py_compile /opt/pdg-bot/*.py 2>/dev/null; then
    c_y "Python 语法错误, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  if ! mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1; then
    c_y "mihomo 配置 check 失败, 回滚…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  if ! nft -c -f /etc/nftables.conf >/dev/null 2>&1; then
    c_y "nftables 配置 check 失败, 回滚…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  if ! systemctl daemon-reload; then
    c_y "systemctl daemon-reload 失败, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  systemctl enable --now pdg-health.timer >/dev/null 2>&1 || true   # 老装升级时补上健康自检
  systemctl restart pdg-bot pdg-probe81 2>/dev/null || true
  systemctl is-enabled pdg-mitm >/dev/null 2>&1 && { systemctl reset-failed pdg-mitm 2>/dev/null; systemctl restart pdg-mitm 2>/dev/null; }   # iOS/WLOC: 清 start-limit + 载新插件代码, 否则 doctor 判 pdg-mitm 未运行而误回滚
  sleep 2

  # token 是否已配置(未配则 pdg-bot 不在跑属正常, 不据此回滚)
  # 凭据状态取 checks.bot_credentials(与 status/doctor/healthcheck 同一份判断), 不再本地
  # 各写一遍 grep。ready=两项都配 / unset=两项都空(正常禁用态) / partial=只配一半(配置错)。
  local cred token_set=0
  cred="$(_pdg_bot_cred)"
  [[ "$cred" == ready ]] && token_set=1
  if [[ "$token_set" == 1 && "$(systemctl is-active pdg-bot 2>/dev/null)" != "active" ]]; then
    c_y "pdg-bot 更新后起不来, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi

  # doctor 自检门: 自检本身必须跑通且输出可信, 才有资格说"已更新"。
  # 以前 doctor 用 `|| true` 吞掉退出码, 且没有 jq 就整段跳过 —— 自检崩了/输出坏了/机器没装
  # jq, 都会直接跳到"✅ 已更新"。改用 python3 解析(本项目本来就硬依赖 python3, 不再依赖 jq),
  # 并要求输出是**非空的 JSON 数组**; 任何一环不成立都按"无法确认更新结果"回滚。
  # 不再按文案豁免任何检查项: 未配凭据时 pdg-bot 压根不在 expected_services() 里, doctor
  # 自己就不会报它 —— 靠比对 doctor 的 detail 字符串做豁免, 那句话多一个服务名
  # 或改个措辞就会失效, 属于最脆的一类耦合。
  local j rcd=0 summary nfail
  if ! command -v python3 >/dev/null 2>&1; then   # 与"自检输出坏"区分开, 免得排错走偏
    c_y "python3 不可用, 无法运行/判读自检 → 回滚到更新前快照…"
    cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  j=$(python3 /opt/pdg-bot/doctor.py --json 2>/dev/null) || rcd=$?
  # doctor 的约定是"有 fail → 1, 否则 0", 所以 **1 是正常结果**而不是"没跑起来"。
  # 把 1 也当异常会直接绕过下面按 JSON 做的判定 —— 包括"未配 token 时 pdg-bot 未运行"
  # 那条豁免, 于是没配 bot token 的机器会永远升级失败; 也拿不到逐项失败清单。
  # 真正的异常是**别的**退出码(崩溃 / 找不到 / 被杀)。
  if [[ "$rcd" != 0 && "$rcd" != 1 ]]; then
    c_y "自检命令异常退出(exit $rcd), 无法确认更新结果, 回滚到更新前快照…"
    cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  if ! summary=$(printf '%s' "$j" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, list) or not d:
    raise SystemExit("doctor 输出不是非空 JSON 数组")
fails = [x for x in d if x.get("level") == "fail"]
warns = [x for x in d if x.get("level") == "warn"]
print(len(fails))
for x in fails: print("  ❌ %s: %s" % (x.get("check"), x.get("detail")))
print("@@WARN@@")
for x in warns: print("  ⚠️ %s: %s" % (x.get("check"), x.get("detail")))
' 2>/dev/null); then
    c_y "自检输出不可解析(应为非空 JSON 数组), 无法确认更新结果, 回滚到更新前快照…"
    cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  nfail="$(sed -n 1p <<<"$summary")"
  if [[ ! "$nfail" =~ ^[0-9]+$ ]]; then
    c_y "自检结果无法判读, 回滚到更新前快照…"; cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  if [[ "$nfail" -gt 0 ]]; then
    c_y "自检发现 $nfail 项失败, 回滚到更新前快照:"
    sed -n '2,/^@@WARN@@$/p' <<<"$summary" | sed '/^@@WARN@@$/d'
    cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1
  fi
  local warnlines; warnlines="$(sed -n '/^@@WARN@@$/,$p' <<<"$summary" | tail -n +2)"
  [[ -n "$warnlines" ]] && { c_y "自检有警告(不回滚, 仅提示):"; printf '%s\n' "$warnlines"; }
  c_g "✅ 已更新。"
}

cmd_token(){ need_root token; pdg-set-token; }   # 不 exec, 设完/取消都回菜单

# shellcheck disable=SC2086  # $svcs 是有意按空白分词的服务名列表
# Bot 凭据状态: ready | unset | partial。判据在 checks.bot_credentials(单一来源),
# 读不到 checks 时按最保守的 unset 处理(不因为拿不到判断就去要求 pdg-bot 必须在跑)。
_pdg_bot_cred(){
  python3 -c 'import sys; sys.path.insert(0, "/opt/pdg-bot"); import checks; print(checks.bot_credentials())' \
    2>/dev/null || echo unset
}

# 重启并**确认真的起来了**。旧实现 `systemctl restart $svcs 2>/dev/null; echo 已重启` ——
# 返回值直接丢掉: mihomo 配置是空的、服务一直 activating/failed, 它照样返回 0 说"已重启",
# 用户以为好了, 实际整条链是断的。
cmd_restart(){
  need_root restart
  local core; core="$(_pdg_core_svc)"
  local cred; cred="$(_pdg_bot_cred)"
  # 1) 先校验内核配置: 配置本身不合法的话重启只会换来一个起不来的服务, 不如当场说清楚
  if command -v mihomo >/dev/null 2>&1 && [[ -f /etc/mihomo/config.yaml ]]; then
    if ! mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1; then
      c_y "❌ mihomo 配置校验(mihomo -t)未过 → 没有重启任何服务。"
      mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml 2>&1 | tail -5 | sed 's/^/    /'
      return 1
    fi
  fi
  # 2) 要重启哪些: 平台必需服务 + 已启用的 pdg-mitm; 未配凭据的 pdg-bot 明确跳过
  local want=() s
  for s in mosdns "$core"; do want+=("$s"); done
  [[ "$(_pdg_platform)" == ios ]] && want+=(pdg-probe81)
  if [[ "$cred" == ready ]]; then
    want+=(pdg-bot)
  elif [[ "$cred" == partial ]]; then
    c_y "⚠️ Bot 凭据只配了一项(token 与允许 id 必须成对)→ 跳过 pdg-bot; 用 pdg-set-token 补齐。"
  else
    c_y "ℹ️ Bot 凭据未配置 → pdg-bot 未启动(正常禁用态; 需要时运行 pdg-set-token)。"
  fi
  [[ -f /etc/systemd/system/pdg-mitm.service ]] \
    && systemctl is-enabled pdg-mitm >/dev/null 2>&1 && want+=(pdg-mitm)
  # 3) 重启并逐个确认"持续 active"(_core_kernel_stable 连采多次 + 比对 NRestarts)
  local bad=()
  for s in "${want[@]}"; do
    systemctl reset-failed "$s" >/dev/null 2>&1 || true
    systemctl restart "$s" >/dev/null 2>&1 || { bad+=("$s"); continue; }
  done
  for s in "${want[@]}"; do
    _core_kernel_stable "$s" || { [[ " ${bad[*]} " == *" $s "* ]] || bad+=("$s"); }
  done
  if [[ ${#bad[@]} -gt 0 ]]; then
    c_y "❌ 以下服务未能稳定运行: ${bad[*]}"
    for s in "${bad[@]}"; do
      echo "  ── $s 最近日志 ──"
      journalctl -u "$s" -n 12 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
    done
    return 1
  fi
  c_g "✅ 已重启并确认运行: ${want[*]}"
}

# 内核日志跟当前后端走(mihomo 机上取 sing-box 只会得到空日志), 与 report.py 同口径。
cmd_log(){ journalctl -u pdg-bot -u mosdns -u "$(_pdg_core_svc)" -n "${1:-40}" --no-pager -o cat; }

cmd_traffic(){ command -v vnstat >/dev/null && vnstat || echo "vnstat 未装: sudo apt install -y vnstat && systemctl enable --now vnstat"; }

cmd_report(){ need_root report; python3 /opt/pdg-bot/report.py "$@"; }

# 抓包识别内网卡来源段, 检测到与现配不符时可一键写回 mosdns+nftables 并重启(装完随时跑, 比装机时从容)。
cmd_detect_cidr(){
  need_root detect-cidr
  local dur="${1:-30}" sip det cur_src cur_nft cur_mos
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/cidr.sh" 2>/dev/null || { echo "❌ 读不到 lib/cidr.sh"; return 1; }
  sip=$(grep -oE '"[0-9.]+/32"' /etc/sing-box/config.json 2>/dev/null | tr -d '"' | grep -v '^127' | head -1 | cut -d/ -f1)
  # 抓包与手输并行(与装机同款): 知道网段就直接输, 不必干等抓包
  det=$(pdg_detect_cidr_race "$dur" "${sip:-本机IP}" || true)
  if [[ -z "$det" ]]; then
    c_y "没抓到。确认手机走内网卡(关 WiFi), 或云安全组放行入站 80/ICMP, 再重试。"; return 1
  fi
  if ! pdg_cidr_valid "$det"; then
    c_y "「$det」不是合法网段(形如 172.22.0.0/16), 未改动。"; return 1
  fi
  # 私网判定放在**动手之前**: 公网段一旦进 nft, REDIRECT 与放行就对全网生效 —— 那不是配置
  # 不当, 是把网关变成开放中继。判据与候选生成器同一份(cidrgen.valid_cidr), 不在两处各写一套。
  local _vw
  if ! _vw="$(_pdg_cidrgen_check "$det")"; then
    c_y "❌ 「$det」不能用作内网卡段: ${_vw:-判定失败} → 未改动任何文件。"; return 1
  fi
  # 三处现状: 真源(profile.env) / 防火墙 / mosdns。旧版只比 nft 一处, 于是"真源落后但 nft 已新"
  # 这种半套状态会被当成"无需改动"放过去。
  cur_src="$(sed -n 's/^[[:space:]]*PDG_INTERNAL_CIDR=//p' /etc/privdns-gateway/profile.env 2>/dev/null | tail -1)"
  # 当前段只认**真规则**里的值: 本项目渲染出的 nft 头部注释里也写着同一个段, 而注释不参与
  # 替换 —— 改过一次之后拿注释里的旧值去找替换位置, 真规则里根本没有, 就会被判成"自定义形态"
  # 而拒绝执行(这条是 e2e-cli-ops 的幂等用例真抓出来的)。判据与候选生成器同一份。
  local _gen_c
  if _gen_c="$(_pdg_module cidrgen.py)"; then
    cur_nft="$(python3 "$_gen_c" current < /etc/nftables.conf 2>/dev/null || true)"
  else
    cur_nft=""
  fi
  cur_mos="$(grep -oE 'ips:[[:space:]]*\[[[:space:]]*"[0-9./]+"' /etc/mosdns/config.yaml 2>/dev/null \
             | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')"
  echo "  检测到内网卡段: $det"
  echo "  当前真源:       ${cur_src:-未写入}"
  echo "  当前防火墙:     ${cur_nft:-未知}"
  echo "  当前 mosdns:    ${cur_mos:-未知}"
  if [[ "$det" == "$cur_src" && "$det" == "$cur_nft" && "$det" == "$cur_mos" ]]; then
    c_g "✅ 三处均已是 $det, 无需修改。"; return 0
  fi
  [[ -z "$cur_nft" ]] && { c_y "❌ nftables 配置里读不到当前内网卡段(自定义形态?) → 未改动任何文件。"; return 1; }
  read -rp "把内网卡段改成 $det 并应用(真源+防火墙+mosdns 一笔事务)? [y/N]: " yn
  [[ "$yn" == [yY] ]] || { echo "已取消, 未改动。"; return 0; }
  _pdg_cidr_transact "$det" "$cur_nft"
}

# 候选生成器的私网/形态判定(单一判据, 与落盘时用的是同一份代码)。
# 通过 → 返回 0; 不通过 → 打印原因并返回非 0。
_pdg_cidrgen_check(){
  local m
  m="$(_pdg_module cidrgen.py)" || { echo "找不到 cidrgen.py"; return 1; }
  python3 - "$m" "$1" <<'PYCHK'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cidrgen", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
ok, why = g.valid_cidr(sys.argv[2])
print(why)
sys.exit(0 if ok else 1)
PYCHK
}

# 找一个已安装的模块(仓库副本优先, 其次 /opt/pdg-bot)。找不到返回非 0。
_pdg_module(){
  local n="$1" f
  for f in "$REPO_DIR/deploy/bot/$n" "/opt/pdg-bot/$n"; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# 内网卡段变更 = **一笔 pdgtx 事务**。三个目标同一个候选值生成, 一起校验、一起落盘、一起观察,
# 任一步失败整体回滚到 before-image。旧版是"自己打快照 + cp -a 备份 + sed 改临时文件 + 手写
# _dc_restore 还原": 落盘落一半、nft 应用失败、mosdns 起不来这三种情况各走各的还原分支, 而
# 还原本身没有复核 —— 于是"改动已应用但复核不一致"只能靠一句提示让人自己去 doctor。
_pdg_cidr_transact(){
  local det="$1" cur_nft="$2" txm txid rc=0 wd
  txm="$(_pdg_module pdgtx.py)" || { c_y "❌ 找不到 pdgtx.py(事务核心缺失), 未改动任何文件。"; return 1; }
  local gen; gen="$(_pdg_module cidrgen.py)" || { c_y "❌ 找不到 cidrgen.py, 未改动任何文件。"; return 1; }
  # 未完成事务先收尾 —— 此刻现网可能停在别人的中间态, 再叠一笔只会让两笔都说不清
  local pend; pend="$(python3 "$txm" pending 2>/dev/null)"
  if [[ -n "$pend" ]]; then
    c_y "⛔ 有未完成的配置事务, 本次拒绝执行(未改动任何文件):"
    printf '%s\n' "$pend" | sed 's/^/    /'
    c_y "   请先 sudo pdg tx show <id> 查看, 再 sudo pdg tx recover <id> 收尾。"
    return 1
  fi
  wd="$(mktemp -d)" || { c_y "❌ 无法创建临时目录"; return 1; }
  txid="$(python3 "$txm" new --source cli --op detect-cidr 2>"$wd/err")" || {
    c_y "❌ 无法开始配置事务: $(tr -d '\n' < "$wd/err")"; rm -rf "$wd"; return 1; }
  # 逐个目标: read 拿"候选所依据的那一份"的 sha → 生成候选 → stage --expect <sha>。
  # 前置条件用的是 read 到的 sha, 所以事务开始后有人改了同一个文件, 落盘阶段会当场撞出来。
  local t kind arg
  for t in profile_env:profile:"" nftables_conf:nft:"$cur_nft" mosdns_conf:mosdns:""; do
    local tgt="${t%%:*}" rest="${t#*:}"
    kind="${rest%%:*}"; arg="${rest#*:}"
    python3 "$txm" read --target "$tgt" > "$wd/$tgt.raw" 2>"$wd/err" || {
      c_y "❌ 读不到目标 $tgt: $(tr -d '\n' < "$wd/err") → 未改动任何文件。"; rc=1; break; }
    local sha; sha="$(head -1 "$wd/$tgt.raw")"
    tail -n +2 "$wd/$tgt.raw" > "$wd/$tgt.cur"
    if ! python3 "$gen" "$kind" "$det" "$arg" < "$wd/$tgt.cur" > "$wd/$tgt.new" 2>"$wd/err"; then
      c_y "❌ 生成候选失败($tgt): $(tr -d '\n' < "$wd/err") → 未改动任何文件。"; rc=1; break
    fi
    python3 "$txm" stage --tx "$txid" --target "$tgt" --file "$wd/$tgt.new" --expect "$sha" 2>"$wd/err" || {
      c_y "❌ 暂存候选失败($tgt): $(tr -d '\n' < "$wd/err") → 未改动任何文件。"; rc=1; break; }
  done
  if [[ "$rc" != 0 ]]; then
    python3 "$txm" abort "$txid" >/dev/null 2>&1 || true    # 候选阶段放弃: 现网一个字节没动过
    rm -rf "$wd"; return 1
  fi
  python3 "$txm" service --tx "$txid" --action nft:apply >/dev/null 2>&1
  python3 "$txm" service --tx "$txid" --action restart:mosdns >/dev/null 2>&1
  local out
  out="$(python3 "$txm" apply --tx "$txid" 2>"$wd/err")"; rc=$?
  if [[ "$rc" == 0 ]]; then
    c_g "✅ 内网卡段已更新为 $det(真源 / 防火墙 / mosdns 同一笔事务落盘, 已重启并观察通过)。"
    rm -rf "$wd"; return 0
  fi
  case "$rc" in
    4) c_y "⛔ 已有配置操作在执行(锁被占用), 本次未改动任何文件。";;
    # REFUSED 涵盖多种"拒绝执行": 锁文件不可用、操作前硬门就是坏的、前置条件已失效。
    # 一律照抄核心给出的原因 —— 自己编一句"锁不可用"会把"mosdns 操作前就没在跑"说成锁的问题。
    5) c_y "⛔ 拒绝执行(未改动任何文件):"
       [[ -s "$wd/err" ]] && sed 's/^/    /' "$wd/err";;
    *) c_y "❌ 内网卡段变更失败, 已按 before-image 回滚:"
       [[ -s "$wd/err" ]] && sed 's/^/    /' "$wd/err"
       [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /'
       c_y "   如显示回滚不完整(ROLLBACK_FAILED), 用 sudo pdg tx show $txid 查看后再 recover。";;
  esac
  rm -rf "$wd"; return 1
}

ic_gate(){
  # iOS 专属命令的统一平台门控。Android 上一律拒绝: 不装 qrencode、不临时改 nft、不开 8443,
  # 也不读写任何生命周期记录。
  if [[ "$(_pdg_platform)" != ios ]]; then
    echo "❌ iOS 描述文件仅 iOS 平台可用(本机为 Android)。"
    if [[ -e /etc/privdns-gateway/platform.guessed ]]; then
      echo "   ⚠️ 这个 android 是**推测**的(老装升级时无确凿证据), 没人确认过。"
      echo "   若本网关服务的是 iPhone: sudo pdg platform ios   (确认后本功能立即可用)"
    else
      echo "   Android 请在手机『私密 DNS』直接填 DoT 域名。"
    fi
    return 1
  fi
  return 0
}

# iOS 生命周期的只读子命令。这几个**不开**临时下载端口 —— 它们只是看记录。
# (取回上一版要把文件送到手机上, 因此不在这里, 见 cmd_ios_previous。)
cmd_ios_state(){
  need_root ios
  ic_gate || return 1
  local st; st="$(_pdg_module iosstate.py)" || { echo "❌ 找不到 iosstate.py, 先跑 pdg update"; return 1; }
  local sub="${1:-status}"; shift || true
  case "$sub" in
    status)
      local HOST IP
      HOST="$(_ios_dot_host)"; IP="$(_ios_server_ip)"
      if [[ -n "$HOST" && -n "$IP" ]]; then
        python3 "$st" status --dot-host "$HOST" --server-ip "$IP" --template "$IOS_TMPL" \
          --wloc-config /etc/privdns-gateway/mitm.json --ca-crt /etc/privdns-gateway/ca/ca.crt
      else
        # 读不到当前网关配置就只报记录, 不硬猜一个判定结果。
        echo "⚠️ 读不到当前 DoT 主机名 / 网关地址, 只显示已生成的记录:"
        python3 "$st" status
      fi;;
    diff|ack|recover) python3 "$st" "$sub";;
    repair)
      # 按记录逐字节复原 current。要带上 WLOC 配置与 CA —— 那一版用的根证书指纹对不上就
      # 复原不了(拿现在的证书渲染出来的是另一份文件), 缺参数会让它误报"模板变了"。
      python3 "$st" repair --template "$IOS_TMPL" \
        --wloc-config /etc/privdns-gateway/mitm.json --ca-crt /etc/privdns-gateway/ca/ca.crt
      ;;
    *) echo "用法: pdg ios {status|diff|previous|ack|recover|repair}"; return 2;;
  esac
}

IOS_TMPL=/opt/pdg-bot/pdg-dot.mobileconfig.tmpl

_ios_dot_host(){
  local CERT=/etc/mosdns/certs/fullchain.pem
  [[ -f /etc/dnsdist/certs/fullchain.pem ]] && CERT=/etc/dnsdist/certs/fullchain.pem
  openssl x509 -in "$CERT" -noout -subject 2>/dev/null \
    | grep -oE 'CN *= *[A-Za-z0-9.*-]+' | sed 's/.*= *//'
}

_ios_server_ip(){
  local ip
  ip=$(grep -oE '"[0-9.]+/32"' /etc/sing-box/config.json 2>/dev/null | tr -d '"' \
       | grep -v '^127' | head -1 | cut -d/ -f1)
  [[ -n "$ip" ]] || ip=$(curl -fsSL --max-time 6 https://api.ipify.org)
  printf '%s' "$ip"
}

_ios_internal_cidr(){
  grep -oE 'ip saddr [0-9./]+' /etc/nftables.conf 2>/dev/null | head -1 | awk '{print $3}'
}

# 给一份**已经生成好**的描述文件开一条临时下载通道, 用完就收:
#   二维码 → 临时 HTTP :8443 → 只对内网卡段的临时 nft 放行 → 回车或 10 分钟后一起撤掉。
# 当前版(cmd_ios)和上一版(cmd_ios_previous)共用这一处 —— 手机取件只有这一条路, 于是加固
# (一次性路径、放行范围、超时、收尾)只有一个地方要改, 不存在"改了一边、另一边照旧"。
# 用法: _ios_offer_download <文件> <网关IP> <内网卡段> [附注行…]
_ios_offer_download(){
  local SRC="$1" IP="$2" CIDR="$3"; shift 3
  [[ -s "$SRC" ]] || { echo "❌ 没有可下发的文件, 未开放任何临时端口。"; return 1; }
  command -v qrencode >/dev/null || { c_g "装 qrencode…"; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode; }
  local PORT=8443 TOK WWW URL SRV="" note
  TOK=$(openssl rand -hex 6)
  WWW=$(mktemp -d)
  # 文件名带一次性随机串: 同一网段里的别的设备猜不到这一次的路径。
  if ! install -m 0644 "$SRC" "$WWW/$TOK.mobileconfig"; then
    rm -rf "$WWW"; echo "❌ 准备临时下载目录失败, 未开放任何临时端口。"; return 1
  fi
  URL="http://$IP:$PORT/$TOK.mobileconfig"

  trap 'kill "$SRV" 2>/dev/null; nft -f /etc/nftables.conf 2>/dev/null; rm -rf "$WWW"; trap - INT TERM' INT TERM
  nft insert rule inet pdg input ip saddr "$CIDR" tcp dport "$PORT" accept 2>/dev/null
  # exec: 让下面那个 kill 直接打在 timeout 上(它再转发给 python3)。少了它被杀的只是外层
  # 子 shell, 端口会一直开到 10 分钟超时为止 —— 与"按回车即收"不符。
  ( cd "$WWW" && exec timeout 600 python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1 ) &
  SRV=$!
  qrencode -o /opt/pdg-bot/ios-qr.png "$URL" 2>/dev/null || true
  echo
  c_g "用手机(走【内网卡/蜂窝】, 关 WiFi)扫下面二维码 → Safari 打开 → 安装描述文件:"
  echo; qrencode -t ANSIUTF8 "$URL"; echo
  echo "  链接: $URL"
  for note in "$@"; do echo "  $note"; done
  echo "  (二维码 PNG 已存 /opt/pdg-bot/ios-qr.png)"
  c_y "装好后按回车收尾(10 分钟自动收)…"
  read -t 600 -r _ || true
  kill "$SRV" 2>/dev/null
  nft -f /etc/nftables.conf 2>/dev/null   # 撤掉临时放行
  rm -rf "$WWW"
  trap - INT TERM
  echo "已关闭临时下载服务。"
}

# 取回上一版: 走的是与 `pdg ios` **同一条**临时下载通道。以前这里只把文件写到服务器上的
# /opt/pdg-bot/, 手机没有任何办法拿到它, 命令却照样说"已取出" —— 于是"取回上一版"实际上
# 只有 Telegram Bot 那条路能用, 而文档和输出都不像是这么回事。
cmd_ios_previous(){
  need_root ios
  ic_gate || return 1
  local st; st="$(_pdg_module iosstate.py)" || { echo "❌ 找不到 iosstate.py, 先跑 pdg update"; return 1; }
  local IP CIDR
  IP="$(_ios_server_ip)"
  CIDR="$(_ios_internal_cidr)"
  [[ -n "$IP" && -n "$CIDR" ]] || { echo "信息不全 (IP=$IP CIDR=$CIDR), 未开放任何临时端口。"; return 1; }
  local STAGE OUT rc
  STAGE=$(mktemp -d); OUT="$STAGE/PrivDNS-Gateway-prev.mobileconfig"
  # 取字节这一步在 iosstate.py 里过 verified_artifact(): 与记录对不上就拿不到文件, 也就
  # 不会有端口被打开 —— 通道只服务于已经确认过的那一份产物, 和 Bot 那条路一样严。
  if ! python3 "$st" previous --out "$OUT"; then
    rm -rf "$STAGE"; echo "❌ 取不出上一版, 未开放任何临时端口。"; return 1
  fi
  _ios_offer_download "$OUT" "$IP" "$CIDR" \
    "这一份是**上一版**: 只是把旧文件再给你一次, 记录的当前版本不会回退。"
  rc=$?
  rm -rf "$STAGE"
  return $rc
}

cmd_ios(){
  need_root ios
  # 平台门控: Android 直接拒绝 —— 不装 qrencode、不临时改 nft、不开 8443。
  ic_gate || return 1
  # 子命令。只看记录的那几个不开端口; previous 要把文件送到手机上, 走与本函数同一条通道。
  # 无参数 = 生成并临时提供下载。
  case "${1:-}" in
    status|diff|ack|recover|repair) cmd_ios_state "$@"; return $?;;
    previous) shift; cmd_ios_previous "$@"; return $?;;
  esac
  local TMPL="$IOS_TMPL"
  [[ -f "$TMPL" ]] || { echo "缺少 $TMPL, 先装好 PrivDNS Gateway"; return 1; }
  # 取 DoT 主机名(证书 CN)/ 公网 IP / 内网卡段
  local HOST IP CIDR
  HOST="$(_ios_dot_host)"
  IP="$(_ios_server_ip)"
  CIDR="$(_ios_internal_cidr)"
  [[ -n "$HOST" && -n "$IP" && -n "$CIDR" ]] || { echo "信息不全 (HOST=$HOST IP=$IP CIDR=$CIDR)"; return 1; }

  # 生成走 iosstate.py(内部再调 iosprofile.py)—— 和 Bot 的「📱 iOS 描述文件」是同一份实现,
  # 同一份记录。以前这里是四个占位符的 sed 替换: 每次现取随机 UUID, WLOC 开着也不附根证书,
  # 不支持强制直连 SSID。于是"用命令行生成的"和"用 bot 生成的"内容不一样、身份也不一样,
  # 而两处都没提示过这件事 —— 用户手机上就这么一份一份堆起来。
  local ST; ST="$(_pdg_module iosstate.py)" || { echo "❌ 找不到 iosstate.py, 先跑 pdg update"; return 1; }
  local LEGACY=() ans=""
  if [[ ! -s /etc/privdns-gateway/ios-profile.json ]]; then
    # 服务器没有任何办法知道这台网关以前有没有发过旧版(随机身份)描述文件, 而用户知道。
    # 与其猜, 不如问 —— 猜错的代价是用户手机上悄悄多出一个永远不会被更新的描述文件。
    echo
    c_y "首次启用受管描述文件。以前在这台网关上装过 PrivDNS Gateway 的 iOS 描述文件吗?"
    echo "  装过 → 旧版每次都是随机身份, iOS 会把新的当成**另一个**描述文件, 需要先手工删掉旧的。"
    if [[ -n "${PDG_IOS_LEGACY:-}" ]]; then
      ans="$PDG_IOS_LEGACY"          # 非交互场景(装机脚本 / 测试)显式给出, 不在这里卡住
    else
      printf "装过请输入 y, 没装过按回车: "
      read -r -t 120 ans || ans=""
    fi
    [[ "$ans" == [yY]* ]] && LEGACY=(--legacy)
  fi
  local STAGE OUT rc
  STAGE=$(mktemp -d); OUT="$STAGE/PrivDNS-Gateway.mobileconfig"
  if ! python3 "$ST" generate --dot-host "$HOST" --server-ip "$IP" --template "$TMPL" \
        --wloc-config /etc/privdns-gateway/mitm.json --ca-crt /etc/privdns-gateway/ca/ca.crt \
        --out "$OUT" "${LEGACY[@]}"; then
    rm -rf "$STAGE"; echo "❌ 生成描述文件失败, 未开放任何临时端口。"; return 1
  fi
  _ios_offer_download "$OUT" "$IP" "$CIDR" "DoT:  $HOST"
  rc=$?
  rm -rf "$STAGE"
  return $rc
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
    [[ "$(_pdg_platform)" == ios ]] && echo " 10) iOS 描述文件"   # iOS 专属: Android 不显示
    [[ "$(_pdg_platform)" == ios ]] && echo " 14) iOS 描述文件状态"
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
      4) cmd_snapshot --source cli --op snapshot;;
      5) read -rp "回滚到第几个快照(默认 0=最近, 回车确认): " i; cmd_rollback "${i:-0}";;
      6) cmd_token;;
      7) cmd_restart;;
      8) cmd_log 60;;
      9) cmd_traffic;;
      10) cmd_ios;;
      14) cmd_ios_state status;;
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

# 老装升级: 确保所有 bot 模块(.py)都部署到 /opt/pdg-bot。修「旧版 cmd_update 安装列表缺新模块
# (如 sb2mihomo/mitm_*)、首次升级时序滞后漏装」→ 迁移/WLOC 渲染报 ModuleNotFoundError。
# pdg-bot.py 由主安装装成 bot.py, 此处跳过。幂等。
# 老装迁移: 把仓库里的 systemd unit 重新部署到已装机器。幂等。
# cmd_update 只装 pdg-health.service/timer, 从不重装 pdg-bot / pdg-rules-update ——
# 于是老机器一直带着 `After=... sing-box.service ...`(v1.6 已无 sing-box, 依赖悬空且与实际
# 内核不符, 排障时极易误导)。
# 关键: pdg-bot.service 里有 __CERT_DIR__ 占位符, 必须沿用**装机时那个证书目录**(从现有 unit
# 里读回来), 直接拿模板覆盖会把占位符原样写进去, bot 就读不到证书了。
# 只更新**已经存在**的 unit(没装过就不该凭空造), 内容没变则不写也不 reload。
migrate_deploy_units(){
  [[ -d "$REPO_DIR/deploy/bot" ]] || return 0
  local changed=0 u src cur tmp certdir
  for u in pdg-bot pdg-rules-update; do
    src="$REPO_DIR/deploy/bot/$u.service"
    cur="/etc/systemd/system/$u.service"
    [[ -f "$src" && -f "$cur" ]] || continue
    tmp="$(mktemp)" || continue
    if [[ "$u" == pdg-bot ]]; then
      # 从现有 unit 取回证书目录(Environment=PDG_CERT=<dir>/fullchain.pem), 取不到用装机默认值
      certdir="$(sed -n 's#^Environment=PDG_CERT=\(.*\)/fullchain\.pem[[:space:]]*$#\1#p' "$cur" | head -1)"
      certdir="${certdir:-/etc/mosdns/certs}"
      sed -e "s|__CERT_DIR__|$certdir|g" "$src" > "$tmp"
    else
      cp -f "$src" "$tmp"
    fi
    if [[ -s "$tmp" ]] && ! cmp -s "$tmp" "$cur"; then
      if install -m644 "$tmp" "$cur" 2>/dev/null; then
        changed=1; c_g "  更新 systemd unit: $u.service"
      else
        c_y "  更新 $u.service 失败(保留原文件)"
      fi
    fi
    rm -f "$tmp"
  done
  [[ "$changed" == 1 ]] && systemctl daemon-reload 2>/dev/null
  return 0
}

migrate_deploy_botfiles(){
  [[ -d "$REPO_DIR/deploy/bot" ]] || return 0
  # shellcheck source=lib/modules.sh
  source "$REPO_DIR/lib/modules.sh" 2>/dev/null || return 0
  # 运行模块走 lib/modules.sh 这份**单一事实源** —— 与 install.sh、cmd_update 同一份清单,
  # 于是不会再出现"装机装了、升级漏了"那类缺口(它不报错, 只让整块能力静默降级)。
  # 与 install.sh、cmd_update 同一个函数、同一份 manifest。原先这后面还跟着一个
  # `deploy/bot/*.py` 的 glob 兜底循环 —— 那是一份**隐式的第二名单**: 仓库里任何新加的 .py
  # 都会被它装进 /opt/pdg-bot, 而那些文件不在 manifest 里, 卸载不会删、mode 也无从对齐。
  # 失败要向上传播: 迁移装了一半就返回成功, 机器会停在新旧混装且没人知道。
  pdg_install_runtime_modules "$REPO_DIR" /opt/pdg-bot "$(_pdg_platform)" || return 1
}

# 老机首次获得救援平面: 装 unit + 备好凭据, 并按"默认启用"拍板方案开起来。
# **但用户主动停用过就不许开回来** —— 升级把用户关掉的东西又打开, 是最招人恨的一类行为。
# 幂等: 已经装好且没被停用的机器上, 这里什么都不做。
migrate_rescue_plane(){
  _rescue_load 2>/dev/null || return 0
  [[ -f /opt/pdg-bot/rescue.py ]] || return 0        # 运行模块还没装到位(10a-1 负责), 下轮再说
  _rescue_intent_migrate                             # 早期标记文件 → profile.env
  local intent; intent="$(_rescue_intent)"
  if [[ "$intent" == 0 ]]; then
    return 0                                         # 用户明确关过 —— 尊重它, 一个字都不改
  fi
  local bind; bind="$(_rescue_bind_addr || true)"
  if [[ -z "$bind" ]]; then
    # 非交互更新**不猜**监听地址: 猜错就是把恢复入口开到不该开的网上。保持停用并说清怎么配。
    local auto; auto="$(_rescue_bind_from_cidr 2>/dev/null || true)"
    if [[ -n "$auto" ]] && pdg_rescue_bind_valid "$auto"; then
      _profile_set "$RESCUE_BIND_KEY" "$auto" && bind="$auto"
      c_g "  救援平面: 按来源段内唯一的本机地址确定监听地址 $bind"
    else
      c_y "  救援平面: 未配置监听地址(PDG_RESCUE_BIND), 保持停用。"
      c_y "     设置后即可启用: sudo pdg rescue bind <IPv4>(候选: $(_rescue_bind_candidates | awk '{print $2}' | tr '\n' ' '))"
      return 0
    fi
  fi
  # 已布防 → 幂等退出(不重生成凭据、不重启、不动任何文件)。
  #
  # 判据是 **socket** 在监听 + unit 在盘上 + 放行还在, 不看 service: socket activation
  # (Accept=no)下 service 平时就该是 inactive —— 那是"已布防、等待请求", 不是挂了。拿
  # service 当判据的话, 每次 update 都会认定它没起来而重跑一遍 enable, 于是凭据被重新生成、
  # 证书指纹变掉, 用户下次访问看到指纹不一致, 只能怀疑自己遇上了中间人。
  # 只看 is-enabled 同样不够: 服务崩掉之后它仍然是 enabled, 那种情况恰恰是要救回来的。
  # unit 模板改了就要刷到盘上。update 只装运行模块、不碰已安装的 unit —— 于是 unit 层面的
  # 修复(硬化项、TimeoutStopSec、监听形态)永远到不了已经装好的机器, 改了等于没改
  # (.200 实机上 TimeoutStopSec 一直停在 systemd 默认的 90 秒)。
  # 只有**内容真的不同**才重写并重启 socket: 每次 update 都重启会平白打断在用的连接。
  _rescue_refresh_units "$bind"
  if _rescue_socket_present \
     && systemctl is-enabled "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 \
     && systemctl is-active "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 \
     && _rescue_nft_has; then
    [[ -n "$intent" ]] || _rescue_intent_set 1       # 老机器补记意图(此前只有 unit 没有键)
    return 0
  fi
  if [[ "$intent" == 1 ]]; then
    c_g "  救援平面意图为启用但当前没起来, 恢复中…"    # 服务崩了 ≠ 用户关了, 这种要救回来
  else
    c_g "  首次启用救援平面(默认开; 之后可 pdg rescue disable)…"
  fi
  _rescue_enable >/dev/null 2>&1 \
    && c_g "  ✅ 救援平面已启用: https://$bind:$PDG_RESCUE_PORT/" \
    || c_y "  救援平面启用失败, 现网未受影响; 可跑 sudo pdg rescue status 查。"
  return 0
}

# 统一平台判定源: 确保 /etc/privdns-gateway/platform 存在且合法(canonical)。幂等。
# 缺失/非法时按证据回退: profile.env 的 PDG_PLATFORM → 明确 iOS 证据(pdg-mitm unit / WLOC 配置) → android。
# 仍无法确定=android, 但 status/doctor 会另行提示"标记缺失回退"(见 _pdg_platform_present / check_platform)。
migrate_platform_marker(){
  # 路径可用 env 覆盖(供测试注入), 生产用默认 /etc/privdns-gateway/*。
  local pf="${PDG_PLATFORM_FILE:-/etc/privdns-gateway/platform}"
  local prof="${PROFILE_ENV:-/etc/privdns-gateway/profile.env}"
  local mj="${PDG_MITM_JSON:-/etc/privdns-gateway/mitm.json}"
  local mu="${PDG_MITM_UNIT:-/etc/systemd/system/pdg-mitm.service}"
  local cur; cur="$(cat "$pf" 2>/dev/null)"
  [[ "$cur" == ios || "$cur" == android ]] && return 0        # 已合法 → 幂等
  local plat=""
  # 1) profile.env 的 PDG_PLATFORM
  if [[ -f "$prof" ]]; then
    local pp; pp="$(sed -n 's/^PDG_PLATFORM=//p' "$prof" | tail -1)"
    [[ "$pp" == ios || "$pp" == android ]] && plat="$pp"
  fi
  # 2) 明确 iOS 证据: 已装 pdg-mitm unit 或存在 WLOC 配置(启用过接管)
  if [[ -z "$plat" ]]; then
    if [[ -f "$mu" ]] || grep -q '"wloc"' "$mj" 2>/dev/null; then plat=ios; fi
  fi
  # 3) 仍无法确定 → 安全回退 android, 但**标记为推测**。v1.4.x 把 probe81/描述文件装给所有
  #    机器, 它们的存在证明不了平台; 贸然按 android 做破坏性清理会把真 iPhone 部署的 iOS
  #    组件删掉。打上 .guessed 后: 破坏性清理一律不做, doctor 持续提示, 等人工确认。
  local guessed=0
  [[ -n "$plat" ]] || { plat=android; guessed=1; }
  mkdir -p "$(dirname "$pf")" 2>/dev/null || true
  local t; t="$(mktemp "$(dirname "$pf")/.platform.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n' "$plat" > "$t" && mv -f "$t" "$pf"; then
    if [[ "$guessed" == 1 ]]; then
      : > "$(dirname "$pf")/platform.guessed" 2>/dev/null || true
      c_y "补平台标记: android(**推测**, 无确凿证据)。若这台服务 iPhone, 请运行: sudo pdg platform ios"
    else
      rm -f "$(dirname "$pf")/platform.guessed" 2>/dev/null || true
      c_g "补平台标记: $plat(据现有证据)。"
    fi
  else rm -f "$t" 2>/dev/null; fi
}

# 老装(v1.4.x, WLOC 之前)迁移: 给 mosdns 补 MITM 接管结构 —— force_hijack domain_set +
# force_hijack_seq + internal_sequence 里的优先级规则 + 空 mitm_hijack.txt。平时空文件=休眠, 零影响。
# 只认标准结构(有 internal_sequence + geosite_cn 优先级锚点 + 可提取的网关 IP); 自定义配置不强改(交 doctor)。
# 幂等(已有 force_hijack 即退); 备份→生成→校验重启→失败还原。$1 可指定文件(供测试)。
# shellcheck disable=SC2120
migrate_mosdns_mitm(){
  local f="${1:-/etc/mosdns/config.yaml}"
  [[ -f "$f" ]] || return 0
  grep -q 'tag: force_hijack' "$f" && return 0                          # 已有 → 幂等退出
  grep -q 'tag: internal_sequence' "$f" && grep -q 'tag: ecs_china' "$f" || return 0   # 非本项目形态 → 不动
  grep -qE '^\s+- matches: qname \$geosite_cn' "$f" || return 0         # 缺优先级锚点 → 不动(交 doctor warn)
  local sip; sip="$(grep -oE 'black_hole [0-9.]+' "$f" | head -1 | awk '{print $2}')"
  [[ -n "$sip" ]] || { c_y "  [MITM迁移] 提取网关IP失败(未渲染?), 跳过(交 doctor)。"; return 0; }
  # 规则目录从现有 geosite_cn 路径推导(生产=/etc/mosdns/rules; 测试=临时目录), 保证注入路径与实际文件一致
  local rdir; rdir="$(grep -oE '"/[^"]*/geosite_cn\.txt"' "$f" | head -1 | tr -d '"')"
  rdir="$(dirname "$rdir" 2>/dev/null)"; [[ -n "$rdir" && "$rdir" != "." ]] || rdir="/etc/mosdns/rules"
  c_g "补 mosdns MITM 接管结构(force_hijack, 平时空文件=休眠)…"
  install -d -m755 "$rdir" 2>/dev/null || true
  [[ -e "$rdir/mitm_hijack.txt" ]] || : > "$rdir/mitm_hijack.txt"   # 空接管集(休眠)
  local bak; bak="$f.premitm.$(date +%s)"
  if ! cp -a "$f" "$bak" 2>/dev/null || ! cmp -s "$f" "$bak"; then
    c_y "  备份失败(磁盘满?), 中止、不动现网。"; rm -f "$bak" 2>/dev/null; return 0
  fi
  if ! python3 - "$f" "$sip" "$rdir" <<'PY'
import sys
f, sip, rdir = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read()
# 1. force_hijack domain_set(锚点: 明确代理集之前; 没有它就退回 ecs_china —— 老配置的原锚点)
anchor_ds = '  - tag: explicit_proxy\n' if '  - tag: explicit_proxy\n' in s else '  - tag: ecs_china'
ds = ('  - tag: force_hijack\n'
      '    type: domain_set\n'
      '    args: { files: ["%s/mitm_hijack.txt"] }\n' % rdir) + anchor_ds
assert s.count(anchor_ds) == 1, '锚点不唯一: %r' % anchor_ds
s = s.replace(anchor_ds, ds, 1)
# 2. force_hijack_seq(锚点: internal_sequence 定义行之前); black_hole 用真实网关 IP
seq = ('  - tag: force_hijack_seq\n'
       '    type: sequence\n'
       '    args:\n'
       '      - matches: qtype 28\n'
       '        exec: reject 0\n'
       '      - matches: qtype 65\n'
       '        exec: reject 0\n'
       '      - exec: jump has_resp\n'
       '      - matches: qtype 1\n'
       '        exec: black_hole %s\n'
       '  - tag: internal_sequence') % sip
# 锚点同上: 有明确代理序列就排在它之前, 让插件定义顺序与模板一致(功能上按 tag 引用, 与顺序无关)
anchor_seq = ('  - tag: explicit_proxy_seq\n' if '  - tag: explicit_proxy_seq\n' in s
              else '  - tag: internal_sequence')
seq = seq.replace('  - tag: internal_sequence', anchor_seq)
assert s.count(anchor_seq) == 1, '锚点不唯一: %r' % anchor_seq
s = s.replace(anchor_seq, seq, 1)
# 3. 优先级规则。锚点是"第一道会抢先给出答案的判断":
#    有明确代理判断时必须排在**它**之前(MITM 接管是最高优先级, 而它已经在 CN 判定之前);
#    没有(老配置)就仍用第一个 geosite_cn —— 原语义不变。
anchor = '      - matches: qname $explicit_proxy'
if anchor not in s:
    anchor = '      - matches: qname $geosite_cn'
rule = ('      - matches: qname $force_hijack\n'
        '        exec: goto force_hijack_seq\n' + anchor)
i = s.find(anchor)
assert i != -1, 'geosite_cn 锚点缺失'
s = s[:i] + rule + s[i + len(anchor):]
open(f, 'w').write(s)
PY
  then c_y "  生成失败 → 还原。"; cp -a "$bak" "$f"; return 0; fi
  # 校验: 若装了 mosdns 就真起一遍确认可加载, 否则只留新配置(测试环境无 mosdns)
  # 判据用 unit 文件是否存在, **不要** `systemctl list-units --all | grep -q`:
  # 本文件开头 set -o pipefail, 而 grep -q 命中即关管道 → systemctl 拿到 SIGPIPE 退 141
  # → 整条管道非 0 → 条件为假。输出短时 systemctl 先写完才被关, 于是它是**按机器上装了
  # 多少 unit 决定成败的竞态**: 开发机上判真, .200 上判假。v1.7.2 在 .200 上就是这么
  # 打出"本机无 mosdns 服务"、跳过校验直接报成功的。
  if command -v mosdns >/dev/null 2>&1 && [[ -e /etc/systemd/system/mosdns.service ]]; then
    systemctl restart mosdns 2>/dev/null; sleep 1
    if [[ "$(systemctl is-active mosdns 2>/dev/null)" == active ]]; then
      c_g "  ✅ 已补 force_hijack(MITM 接管结构)。"
    else
      c_y "  ⚠️ mosdns 重启失败 → 还原。"; cp -a "$bak" "$f" 2>/dev/null; systemctl restart mosdns 2>/dev/null
    fi
  else
    c_g "  ✅ 已补 force_hijack(未起 mosdns 校验: 本机无 mosdns 服务)。"
  fi
}

# 老装迁移: iOS 平台补 pdg-mitm 服务(MITM 插件宿主)。仅 iOS; Android 不建。
# 需 mitm_server.py 已就位(靠 migrate_deploy_botfiles 先补)。幂等(已有 unit 且 enabled 即退)。
migrate_pdg_mitm_service(){
  [[ "$(_pdg_platform)" == ios ]] || return 0                          # 仅 iOS; Android 无 MITM
  [[ -f /etc/systemd/system/pdg-mitm.service ]] && systemctl is-enabled pdg-mitm >/dev/null 2>&1 && return 0
  [[ -f /opt/pdg-bot/mitm_server.py ]] || return 0                     # MITM 服务代码未就位 → 下轮 botfiles 迁移后再补
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/units.sh" 2>/dev/null || return 0
  pdg_write_unit pdg_unit_pdg_mitm /etc/systemd/system/pdg-mitm.service
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed pdg-mitm 2>/dev/null; systemctl enable --now pdg-mitm >/dev/null 2>&1 || true
  c_g "  ✅ 已补 iOS pdg-mitm 服务(MITM 插件宿主)。"
}

# 老装迁移(Android): 清理误装/残留的 iOS 专属组件。幂等; 仅匹配本项目精确路径/unit, 不误删用户文件。
# CA / WLOC 地点数据不永久删 —— 留作休眠(Android 上 _mitm_enabled_domains 恒空, 本就不生效)。
migrate_android_cleanup(){
  [[ "$(_pdg_platform)" == android ]] || return 0
  # 推测出来的 android 不做破坏性清理: 万一这台其实服务 iPhone, 一删就把描述文件/probe81/
  # MITM 组件全没了, 而且 doctor 之后还会一路判绿(它已经认为自己是 Android 机)。
  local _gf; _gf="$(dirname "${PDG_PLATFORM_FILE:-/etc/privdns-gateway/platform}")/platform.guessed"
  if [[ -e "$_gf" ]]; then
    c_y "  平台是推测的 android(无确凿证据) → 跳过 iOS 组件清理。"
    c_y "  确认后运行: sudo pdg platform android(或 ios), 再重跑。"
    return 0
  fi
  # 有启用中的 WLOC → 先安全休眠: 清运行时接管 + enabled=false(保留地点/CA 数据)
  if grep -q '"enabled": *true' /etc/privdns-gateway/mitm.json 2>/dev/null; then
    : > /etc/mosdns/rules/mitm_hijack.txt 2>/dev/null || true
    python3 - /etc/privdns-gateway/mitm.json <<'PY' 2>/dev/null || true
import json, sys
f = sys.argv[1]; c = json.load(open(f))
if isinstance(c.get("wloc"), dict): c["wloc"]["enabled"] = False
json.dump(c, open(f, "w"), ensure_ascii=False, indent=2)
PY
    systemctl restart mosdns 2>/dev/null || true
  fi
  local removed=0 u f
  for u in pdg-probe81 pdg-mitm; do
    if [[ -f /etc/systemd/system/$u.service ]]; then
      systemctl disable --now "$u" 2>/dev/null; rm -f "/etc/systemd/system/$u.service"; removed=1
    fi
  done
  for f in /opt/pdg-bot/probe81.py /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py \
           /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py \
           /opt/pdg-bot/pdg-dot.mobileconfig.tmpl /opt/pdg-bot/pdg-mitm.mobileconfig.tmpl; do
    [[ -f "$f" ]] && { rm -f "$f"; removed=1; }
  done
  [[ "$removed" == 1 ]] && { systemctl daemon-reload 2>/dev/null || true
    c_g "Android: 已清理 iOS 专属残留(pdg-probe81/pdg-mitm 服务 + mitm 模块 + 描述文件模板; CA/地点数据保留为休眠)。"; }
  return 0
}

# 老装迁移(iOS): 精确、幂等清除本项目误装的 GMS 5228-5230(iOS 走 APNs, 不需要)。
# 只删 tag=in-gms-5228/5229/5230 的入站 + 从原装端口集/ mihomo REDIRECT 移除 5228-5230。
# 改前备份, sing-box/nft 均校验, 失败自动还原; 自定义配置不动。$1/$2 供测试注入。
# shellcheck disable=SC2120
# iOS GMS 残留清理 —— **CLI 侧的精确事务**(不复用 Python pdgtx: 这里已经在 pdg.sh 的 _lock
# 里, 再让 pdgtx 去抢同一把 flock 会自锁; 而"释放锁/跳过锁/信任调用方已锁"三种绕法都会把并发
# 保护弄没)。它按事务的规矩来: 候选先行 → 全部校验通过才落盘 → 固定顺序应用 → 任一步失败按
# before-image 完整回滚并复核 → 结果如实传播(非 0)。三个目标: canonical model、渲染出的内核
# 配置、nftables 配置(含运行态)。
migrate_ios_gms_cleanup(){
  [[ "$(_pdg_platform)" == ios ]] || return 0
  local sb="${1:-/etc/sing-box/config.json}" nf="${2:-/etc/nftables.conf}"
  # 内核配置 / 工作目录根 / bot 模块位置都可用 env 覆盖 —— 生产是默认值, 沙箱用例据此在
  # 临时树里跑真实现(不打桩被测逻辑)。
  local mh="${PDG_MIHOMO_CFG:-/etc/mihomo/config.yaml}"
  local statedir="${PDG_STATE_DIR:-/var/lib/privdns-gateway}"
  local botpy="${PDG_BOT_PY:-/opt/pdg-bot/bot.py}"
  # nft 位置用项目统一判据(_pdg_nft_bin): `command -v nft` 只看 PATH, 而 nft 常在 /usr/sbin ——
  # PATH 里没有 sbin 时会"跳过校验与应用却照样写配置并报成功", 那正是要避免的。
  local nftexe; nftexe="$(_pdg_nft_bin)"
  local need_sb=0 need_nf=0
  [[ -f "$sb" ]] && grep -q '"in-gms-5228"' "$sb" && need_sb=1
  [[ -f "$nf" ]] && grep -qE 'tcp dport [{][^}]*5228' "$nf" && need_nf=1
  # 幂等: 没有残留就一个字节都不改、一个服务都不重启
  [[ "$need_sb" == 1 || "$need_nf" == 1 ]] || return 0

  # 工作目录放 /var/lib(0700), 不放 /tmp —— before-image 里的 model 带出口凭据
  local wd rc=0 applied=() step=""
  mkdir -p "$statedir" 2>/dev/null
  wd="$(mktemp -d "$statedir/iosgms.XXXXXX" 2>/dev/null)" || {
    c_y "  iOS GMS 清理: 建不出工作目录 → 跳过本次(未改动任何文件)"; return 1; }
  chmod 700 "$wd"

  # ── 1) before-image: 逐个文件记"原本存在/不存在 + 权限", 内容留在 0600 的副本里 ──
  # ① 形态守卫: 事务目标必须是**受控普通文件**。软链会让 `cp -a` 把链接原样搬进候选目录,
  #    随后的 chmod / python 写入 / sed -i 就直接改到现网(甚至改到链接指向的别处), 而 before-image
  #    也不再是真正的旧内容; 硬链接则会让"只改这一个文件"波及另一个名字。
  #    这一步必须在任何 cp / chmod / stat / python / sed 之前完成, 拒绝时现网、链接目标、权限
  #    与服务状态都还没被碰过。
  local f name g
  for g in "$sb:config.json" "$mh:config.yaml" "$nf:nftables.conf"; do
    f="${g%%:*}"
    if [[ -L "$f" ]]; then
      c_y "  iOS GMS 清理: $f 是符号链接, 事务目标只接受普通文件 → 未改动任何文件"
      rm -rf "$wd"; return 1
    fi
    [[ -e "$f" ]] || continue                     # 不存在: absent 语义, 下面照旧
    if [[ ! -f "$f" ]]; then
      c_y "  iOS GMS 清理: $f 不是普通文件 → 未改动任何文件"; rm -rf "$wd"; return 1
    fi
    local _nl; _nl="$(stat -c '%h' "$f" 2>/dev/null)"
    if [[ -z "$_nl" ]]; then
      c_y "  iOS GMS 清理: 取不到 $f 的 stat 信息 → 未改动任何文件"; rm -rf "$wd"; return 1
    fi
    if [[ "$_nl" != 1 ]]; then
      c_y "  iOS GMS 清理: $f 是硬链接(nlink=$_nl), 改它会波及另一个名字 → 未改动任何文件"
      rm -rf "$wd"; return 1
    fi
  done
  # ② before-image: 逻辑名固定为 config.json / config.yaml / nftables.conf —— 与落盘、回滚共用
  #    同一套键名(用 basename 当键会在路径被 env 换过时对不上)。**内容用读写复制**而不是 cp -a,
  #    这样材料一定是工作目录里的独立普通文件。mode/uid/gid 取不到就拒(不许猜 600 / 0:0 —— 那会
  #    在成功提交时悄悄改掉属主)。
  for g in "$sb:config.json" "$mh:config.yaml" "$nf:nftables.conf"; do
    f="${g%%:*}"; name="${g##*:}"
    if [[ -f "$f" ]]; then
      local _m _o
      _m="$(stat -c '%a' "$f" 2>/dev/null)"; _o="$(stat -c '%u:%g' "$f" 2>/dev/null)"
      if [[ -z "$_m" || -z "$_o" ]]; then
        c_y "  iOS GMS 清理: 取不到 $name 的权限/归属 → 未改动任何文件"; rm -rf "$wd"; return 1
      fi
      ( umask 177; cat "$f" > "$wd/before-$name" ) 2>/dev/null \
        || { c_y "  iOS GMS 清理: 存 before-image 失败($name) → 未改动任何文件"; rm -rf "$wd"; return 1; }
      chmod 600 "$wd/before-$name"
      printf '%s\n' "$_m" > "$wd/mode-$name"
      printf '%s\n' "$_o" > "$wd/own-$name"
      echo 1 > "$wd/existed-$name"
    else
      echo 0 > "$wd/existed-$name"
    fi
  done

  # ── 2) 候选: 全部在工作目录里生成, 生产文件此刻一个字节都没动 ──
  if [[ "$need_sb" == 1 ]]; then
    ( umask 177; cat "$sb" > "$wd/cand-config.json" ) 2>/dev/null \
      && chmod 600 "$wd/cand-config.json" || rc=1
    if [[ $rc == 0 ]] && ! python3 - "$wd/cand-config.json" <<'PY'
import json, sys
f = sys.argv[1]
c = json.load(open(f))
c["inbounds"] = [i for i in c.get("inbounds", [])
                 if i.get("tag") not in ("in-gms-5228", "in-gms-5229", "in-gms-5230")]
with open(f, "w") as fh:
    json.dump(c, fh, ensure_ascii=False, indent=2)
PY
    then rc=1; fi
    [[ $rc == 0 ]] || { c_y "  iOS GMS 清理: 生成候选 model 失败 → 未改动任何文件"; rm -rf "$wd"; return 1; }
    # 候选 mihomo 配置: 从**候选 model** 渲染(不写生产文件), 顺带用与 Bot 相同的判据拦
    # unknown_proxies / dropped —— 那两类是"静默丢出口/丢分流", 必须在落盘前拒。
    if ! PDG_BOT_PY="$botpy" python3 - "$wd/cand-config.json" "$wd/cand-mihomo.yaml" <<'PY' 2>"$wd/render.err"
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("bot", os.environ["PDG_BOT_PY"])
bot = importlib.util.module_from_spec(spec); spec.loader.exec_module(bot)
data = open(sys.argv[1], "rb").read()
out = bot._mihomo_derive({"model": data})       # dropped / 无法转换的出口在这里被拒
open(sys.argv[2], "wb").write(out)
PY
    then
      c_y "  iOS GMS 清理: 候选内核配置渲染/校验未过 → 未改动任何文件"
      sed -n '$p' "$wd/render.err" 2>/dev/null | sed 's/^/    /'
      rm -rf "$wd"; return 1
    fi
    chmod 600 "$wd/cand-mihomo.yaml"
    if command -v mihomo >/dev/null 2>&1; then
      if ! mihomo -t -d /etc/mihomo -f "$wd/cand-mihomo.yaml" >/dev/null 2>&1; then
        c_y "  iOS GMS 清理: 候选内核配置 mihomo -t 未过 → 未改动任何文件"; rm -rf "$wd"; return 1
      fi
    fi
  fi
  if [[ "$need_nf" == 1 ]]; then
    # 这一步要改防火墙 → 没有可用的 nft 就**不许往下走**(以前会静默跳过校验与应用)
    if [[ -z "$nftexe" || ! -x "$nftexe" ]]; then
      c_y "  iOS GMS 清理: 找不到可执行的 nft, 无法校验/应用防火墙 → 未改动任何文件"
      rm -rf "$wd"; return 1
    fi
    # 旧配置文件必须在: 回滚运行态要靠"用旧配置再 nft -f 一次"。不在就别开始改运行态。
    if [[ ! -f "$nf" ]]; then
      c_y "  iOS GMS 清理: $nf 不存在, 无法保证运行态可回滚 → 未改动任何文件"
      rm -rf "$wd"; return 1
    fi
    ( umask 177; cat "$nf" > "$wd/cand-nftables.conf" ) 2>/dev/null \
      || { c_y "  iOS GMS 清理: 复制 nft 配置失败 → 未改动任何文件"; rm -rf "$wd"; return 1; }
    _pdg_nft_strip_gms "$wd/cand-nftables.conf"
    if grep -qE 'tcp dport [{][^}]*5228' "$wd/cand-nftables.conf"; then
      # 剥完还在 = 自定义形态, 不猜也不动(交 doctor warn), 但这不是失败
      c_y "  防火墙 5228-5230 非原装形态, 未自动改(交 doctor)"; need_nf=0
    elif ! "$nftexe" -c -f "$wd/cand-nftables.conf" >/dev/null 2>&1; then
      c_y "  iOS GMS 清理: 候选防火墙 nft -c 未过 → 未改动任何文件"; rm -rf "$wd"; return 1
    fi
  fi
  [[ "$need_sb" == 1 || "$need_nf" == 1 ]] || { rm -rf "$wd"; return 0; }

  # ── 3) 回滚: 逐文件按 before-image 还原 + 复核 SHA + nft 运行态 + 内核稳定 ──
  _iosgms_restore(){
    local bad=() g name src
    for g in "$sb:config.json" "$mh:config.yaml" "$nf:nftables.conf"; do
      f="${g%%:*}"; name="${g##*:}"
      [[ " ${applied[*]} " == *" $name "* ]] || continue
      if [[ "$(cat "$wd/existed-$name" 2>/dev/null)" == 1 ]]; then
        local want_mode want_own
        want_mode="$(cat "$wd/mode-$name")"; want_own="$(cat "$wd/own-$name" 2>/dev/null || echo 0:0)"
        install -m "$want_mode" "$wd/before-$name" "$f" 2>/dev/null || bad+=("$name 写回失败")
        # 回滚阶段允许尽力执行(非 root 环境 chown 必失败), 但**最终以下面的逐项复核为准** ——
        # 复核不过就是 rollback incomplete, 不存在"chown 失败却算还原成功"。
        chown "$want_own" "$f" 2>/dev/null || true
        cmp -s "$wd/before-$name" "$f" || bad+=("$name 内容未还原")
        [[ "$(stat -c '%a' "$f" 2>/dev/null)" == "$want_mode" ]] || bad+=("$name 权限未还原")
        [[ "$(stat -c '%u:%g' "$f" 2>/dev/null)" == "$want_own" ]] || bad+=("$name 归属未还原")
      else
        # 原本不存在的必须回到"不存在", 不许留下我们造出来的文件
        rm -f "$f" 2>/dev/null
        [[ -e "$f" ]] && bad+=("$name 本应不存在却还在")
      fi
    done
    # 只要 apply **被尝试过**就必须重放旧配置: 磁盘文件在上面已经还原, 这里用它把内核里的
    # 规则也拉回操作前, 并检查返回码 —— 第二次也失败就必须如实说"回滚不完整"。
    if [[ " ${applied[*]} " == *" nft-apply "* ]]; then
      if [[ -z "$nftexe" || ! -x "$nftexe" ]]; then
        bad+=("找不到 nft, 无法确认防火墙运行态已还原")
      elif ! "$nftexe" -f "$nf" >/dev/null 2>&1; then
        bad+=("nft 运行态未还原(用旧配置重新加载失败)")
      fi
    fi
    if [[ " ${applied[*]} " == *" core-restart "* ]]; then
      systemctl restart "$(_pdg_core_svc)" >/dev/null 2>&1 || bad+=("内核重启失败")
      _core_kernel_stable "$(_pdg_core_svc)" >/dev/null 2>&1 || bad+=("内核未稳定运行")
    fi
    if [[ ${#bad[@]} -gt 0 ]]; then
      c_r "  ⚠️ iOS GMS 清理失败, 而且**回滚不完整**: ${bad[*]}"
      c_y "     回滚材料保留在 $wd —— 请据此人工修复(内含恢复前的原文件)"
      return 1
    fi
    c_y "  已回滚: model / 内核配置 / 防火墙 均还原到清理前, 内核稳定运行。"
    rm -rf "$wd"; return 0
  }

  # ── 4) 落盘: 固定顺序 + 同目录临时文件 + 原子替换(绝不截断生产文件后再写) ──
  _iosgms_put(){  # $1=候选 $2=目标 $3=记账名
    # 原本存在的目标: 临时文件在 mv **之前**就设成原 mode/uid/gid —— 以 root 跑时, 只保 mode
    # 会把非 root:root 的文件悄悄换成 root:root。chmod/chown 任一步失败就不许覆盖生产。
    # 原本不存在的: 用该目标的明确默认 mode, owner 就是当前执行用户(生产由 need_root 保证是
    # root), 不伪造"恢复旧 owner"。
    local d t want_mode want_own
    d="$(dirname "$2")"; t="$d/.pdg-iosgms.$$"
    if [[ "$(cat "$wd/existed-$3" 2>/dev/null)" == 1 ]]; then
      want_mode="$(cat "$wd/mode-$3")"; want_own="$(cat "$wd/own-$3")"
    else
      case "$3" in nftables.conf) want_mode=644;; *) want_mode=600;; esac
      want_own="$(id -u):$(id -g)"
    fi
    cp -f "$1" "$t" 2>/dev/null || { rm -f "$t"; return 1; }
    chmod "$want_mode" "$t" 2>/dev/null || { rm -f "$t"; return 1; }
    chown "$want_own" "$t" 2>/dev/null || { rm -f "$t"; return 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; return 1; }
    applied+=("$3")
    # 落盘后复核: 内容 + 权限 + 归属都必须是期望值(不复核就等于"写了就算成功")
    cmp -s "$1" "$2" || return 1
    [[ "$(stat -c '%a' "$2" 2>/dev/null)" == "$want_mode" ]] || return 1
    [[ "$(stat -c '%u:%g' "$2" 2>/dev/null)" == "$want_own" ]] || return 1
    return 0
  }
  if [[ "$need_sb" == 1 ]]; then
    step="model";        _iosgms_put "$wd/cand-config.json"    "$sb" config.json  || rc=1
    [[ $rc == 0 ]] && { step="内核配置"; _iosgms_put "$wd/cand-mihomo.yaml" "$mh" config.yaml || rc=1; }
  fi
  if [[ $rc == 0 && "$need_nf" == 1 ]]; then
    step="防火墙配置"; _iosgms_put "$wd/cand-nftables.conf" "$nf" nftables.conf || rc=1
    if [[ $rc == 0 ]]; then
      # **先记账再执行**: nft -f 可能改了一部分内核状态之后才返回非 0, 那时运行态已经不是
      # 操作前的样子了 —— 只在成功后记账会让回滚只还原磁盘文件, 内核里留着半套规则。
      step="nft apply"; applied+=("nft-apply")
      "$nftexe" -f "$nf" >/dev/null 2>&1 || rc=1
    fi
  fi
  if [[ $rc == 0 && "$need_sb" == 1 ]]; then
    step="重启内核"
    systemctl reset-failed "$(_pdg_core_svc)" >/dev/null 2>&1
    if systemctl restart "$(_pdg_core_svc)" >/dev/null 2>&1; then
      applied+=("core-restart")
      _core_kernel_stable "$(_pdg_core_svc)" >/dev/null 2>&1 || { step="内核稳定观察"; rc=1; }
    else
      applied+=("core-restart"); rc=1
    fi
  fi
  if [[ $rc != 0 ]]; then
    c_y "  iOS GMS 清理在「$step」失败 → 回滚"
    _iosgms_restore || return 1
    return 1
  fi
  [[ "$need_sb" == 1 ]] && c_g "  iOS: 已移除 GMS 入站(in-gms-5228/5229/5230)并同步内核配置。"
  [[ "$need_nf" == 1 ]] && c_g "  iOS: 已从防火墙端口集移除 GMS 5228-5230(保留 80/443 redirect)。"
  rm -rf "$wd"
  return 0
}

# issue #1: bot 把域名"指到出口"时只改了内核路由, 没让 mosdns 劫持该域名 → 手机拿到真实 IP
# 直连, 流量根本不到网关, 那条出口规则是死的(用户现场: 加了 ip.skk.moe→jp 仍显示国内直连,
# 手工塞进 geosite 文件并重启 mosdns 才生效)。老装补: 建用户劫持表 → 并入 hijack_set →
# 回填已有的显式出口域名 → 有改动才重启 mosdns。幂等。
migrate_custom_hijack(){
  local mc=/etc/mosdns/config.yaml hj=/etc/mosdns/rules/custom_hijack.txt sb=/etc/sing-box/config.json out
  [[ -f "$mc" ]] || return 0
  install -d -m755 /etc/mosdns/rules 2>/dev/null || true
  if ! out=$(python3 - "$mc" "$sb" "$hj" <<'MIGPY'
import json, os, re, sys
mc, sb, hj = sys.argv[1], sys.argv[2], sys.argv[3]
changed = False

# 先保证劫持表文件存在, 再改 config —— mosdns 对 domain_set 文件是**强依赖**(缺文件直接
# FATAL 起不来), 顺序反了万一中途失败就把 mosdns 干趴了。
doms = set()
try:
    c = json.load(open(sb, encoding="utf-8"))
    for r in c.get("route", {}).get("rules", []):
        if "outbound" in r and not r.get("rule_set"):
            doms |= set(r.get("domain_suffix") or []) | set(r.get("domain") or [])
except Exception:
    pass
cur = set()
if os.path.exists(hj):
    cur = {l.strip().replace("domain:", "") for l in open(hj, encoding="utf-8")
           if l.strip() and not l.startswith("#")}
if not os.path.exists(hj) or (doms - cur):
    with open(hj, "w", encoding="utf-8") as f:
        f.write("# pdg-bot 显式出口域名劫持表(指到出口的域名必须由 mosdns 劫持才会进代理)\n")
        f.writelines("domain:" + d + "\n" for d in sorted(cur | doms))
    changed = True

s = open(mc, encoding="utf-8").read()
if hj not in s:                      # 按实际路径判幂等, 不靠硬编码文件名子串
    m = re.search(r"(- tag: hijack_set\b[\s\S]*?files: \[)([^\]]*)(\])", s)
    if not m:
        raise SystemExit("hijack_set 形态不认识")
    s = s[:m.end(2)] + ',"' + hj + '"' + s[m.end(2):]
    open(mc, "w", encoding="utf-8").write(s)
    changed = True
print("changed" if changed else "nochange")
MIGPY
  ); then
    c_y "  mosdns 配置里没有可识别的 hijack_set(自定义形态), 用户劫持表未并入; 劫持表本身已就绪。"; return 0
  fi
  if [[ "$out" == changed ]]; then
    systemctl restart mosdns 2>/dev/null || true
    c_g "  已建用户劫持表并回填显式出口域名(修: 指到出口的域名此前不被 mosdns 劫持)。"
  fi
}

# 把已有机器的 mosdns 劫持形态归一到"与 PDG_HIJACK_MODE 一致"。两类机器都要修:
#   · 老形态(无 hijack_set, 排除式): 补上 hijack_set 插件, 获得 gfw 能力; all 语义不变。
#   · 新形态(有劫持门)但模式是 all: 去掉那道门 —— 它把 all 悄悄退化成了"只劫持 geosite
#     策展分类里的域名", 用户指到出口的任意域名照样直连(issue #1)。
migrate_mosdns_hijack_shape(){
  local mc=/etc/mosdns/config.yaml mode file out
  [[ -f "$mc" ]] || return 0
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/mosdns.sh" 2>/dev/null || return 0
  mode="$(sed -n 's/^PDG_HIJACK_MODE=//p' /etc/privdns-gateway/profile.env 2>/dev/null | tail -1)"
  [[ "$mode" == gfw || "$mode" == all ]] || mode=all
  [[ "$mode" == gfw ]] && file=geosite_gfw.txt || file="geosite_geolocation-!cn.txt"
  # gfw 模式但劫持集文件不在 → 别把门装上(会把所有海外域名放行), 维持现状交人工
  if [[ "$mode" == gfw && ! -s "/etc/mosdns/rules/$file" ]]; then
    c_y "  gfw 模式但缺 /etc/mosdns/rules/$file, 劫持形态未动。"; return 0
  fi
  if ! out=$(_mosdns_hijack_shape "$mode" "$mc" "$file"); then
    c_y "  mosdns 劫持形态是自定义的, 未动(不猜着改)。"; return 0
  fi
  if [[ "$out" == changed ]]; then
    systemctl restart mosdns 2>/dev/null || true
    c_g "  已归一 mosdns 劫持形态 → $mode(all=不是国内就劫持; gfw=只劫持劫持集内域名)。"
  fi
}

# 明确代理优先于 geosite_cn(v1.7.0 → 之后)。
#
# v1.7.0 及更早, 用户在 bot 里点名指到出口的域名只在 hijack_set 那道门被查, 而那道门排在
# geosite_cn **之后**。上游 geosite 一旦把域名归进 CN(实例: 整个 byte-test.com), DNS 就先
# 返真实地址, 流量根本不进 mihomo —— 内核里那条 route 规则成了死规则, 而 doctor 看不出问题:
# 规则确实在, 只是永远匹配不到。
#
# **CLI 侧的精确事务, 不用 Python pdgtx** —— 与 migrate_ios_gms_cleanup 同一条理由: 本函数经
# `pdg __migrate` 跑, 而 cmd_update 是**持着 /run/privdns-gateway.lock 的父进程**在调它;
# pdgtx 抢的是同一把 flock, 于是必然 BUSY。第一版正是这么写的, 结果 .200 更新到 v1.7.1 之后
# 迁移被"已有配置操作正在执行"挡掉并回滚, 而 update 照样报成功 —— 只有 doctor 那条告警露了馅。
# "释放锁 / 跳过锁 / 信任调用方已锁"三种绕法都会把并发保护弄没, 所以按这里的规矩自己来:
# 候选先行(形态不认识就压根不碰现网)→ 备份 → 落盘 → 重启 → 复核 → 失败按备份完整还原。
migrate_mosdns_explicit_proxy(){
  local mc=/etc/mosdns/config.yaml wd sip out bak
  [[ -f "$mc" ]] || return 0
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/mosdns.sh" 2>/dev/null || return 0
  # 已经齐了 → 什么都不做(幂等)
  if grep -q "tag: explicit_proxy$" "$mc" && grep -q 'qname \$explicit_proxy' "$mc"; then
    return 0
  fi
  # 有事务卡在需要人工收尾的状态时不动手。判据用 pdgtx 的**退出码**(只读, 不取锁):
  # `pending` 的输出里还包含"开了但从没应用过"的陈旧 PREPARING —— 那类不挡任何写入,
  # 拿输出非空当判据的话, 线上机器攒着的旧 geosite_update 会把迁移永远挡在门外。
  local txm; txm="$(_pdg_module pdgtx.py)" || txm=""
  if [[ -n "$txm" ]]; then
    local pend rcp=0
    pend="$(python3 "$txm" pending 2>/dev/null)" || rcp=$?
    if [[ "$rcp" != 0 ]]; then
      c_y "  有需要收尾的配置事务, 明确代理优先级本次不迁移(未改动任何文件):"
      printf '%s\n' "$pend" | sed 's/^/    /'
      c_y "  → 先 sudo pdg tx recover <id> 收尾, 再跑一次 sudo pdg update。"
      return 0
    fi
  fi
  sip="$(sed -n 's/^PDG_SERVER_IP=//p' /etc/privdns-gateway/profile.env 2>/dev/null | tail -1)"
  [[ -n "$sip" ]] || sip="$(grep -oE 'black_hole [0-9.]+' "$mc" | head -1 | awk '{print $2}')"
  if [[ -z "$sip" ]]; then
    c_y "  取不到网关 IP(未渲染?), 明确代理优先级未迁移(交 doctor 点名)。"; return 0
  fi
  wd="$(mktemp -d)" || return 0
  # 先在**副本**上试改: 形态不认识就到此为止, 现网从未被碰过。
  cp "$mc" "$wd/cand.yaml" || { rm -rf "$wd"; return 0; }
  if ! out=$(_mosdns_explicit_proxy "$wd/cand.yaml" "$sip" 2>"$wd/err"); then
    c_y "  mosdns 配置是自定义形态, 明确代理优先级未迁移(不猜着改): $(tr -d '\n' < "$wd/err" | head -c 120)"
    c_y "  → sudo pdg doctor 会继续点名这一项。"
    rm -rf "$wd"; return 0
  fi
  [[ "$out" == changed ]] || { rm -rf "$wd"; return 0; }
  # 域名集要求文件存在, 缺了 mosdns 起不来 —— 必须在落盘之前建好
  [[ -e /etc/mosdns/rules/ruleset_hijack.txt ]] || : > /etc/mosdns/rules/ruleset_hijack.txt
  bak="$mc.preexplicit.$(date +%s)"
  if ! cp -a "$mc" "$bak" 2>/dev/null || ! cmp -s "$mc" "$bak"; then
    c_y "  备份失败(磁盘满?), 中止、不动现网。"; rm -f "$bak" 2>/dev/null; rm -rf "$wd"; return 0
  fi
  if ! cat "$wd/cand.yaml" > "$mc" 2>/dev/null; then
    c_y "  写入失败, 还原。"; cp -a "$bak" "$mc" 2>/dev/null; rm -f "$bak"; rm -rf "$wd"; return 0
  fi
  # 校验: 装了 mosdns 服务就真重启一遍确认能加载; 没有服务的环境只留新配置(与 MITM 迁移同规矩)
  # 判据用 unit 文件是否存在, **不要** `systemctl list-units --all | grep -q`:
  # 本文件开头 set -o pipefail, 而 grep -q 命中即关管道 → systemctl 拿到 SIGPIPE 退 141
  # → 整条管道非 0 → 条件为假。输出短时 systemctl 先写完才被关, 于是它是**按机器上装了
  # 多少 unit 决定成败的竞态**: 开发机上判真, .200 上判假。v1.7.2 在 .200 上就是这么
  # 打出"本机无 mosdns 服务"、跳过校验直接报成功的。
  if command -v mosdns >/dev/null 2>&1 && [[ -e /etc/systemd/system/mosdns.service ]]; then
    systemctl restart mosdns 2>/dev/null; sleep 1
    if [[ "$(systemctl is-active mosdns 2>/dev/null)" == active ]]; then
      c_g "  已把「用户点名指到出口的域名」提到 geosite_cn 之前(显式代理优先)。"
      rm -f "$bak"
    else
      c_y "  ⚠️ 新配置起不来 mosdns → 已还原到迁移前。"
      cp -a "$bak" "$mc" 2>/dev/null; systemctl restart mosdns 2>/dev/null; rm -f "$bak"
    fi
  else
    c_g "  已把「用户点名指到出口的域名」提到 geosite_cn 之前(未起 mosdns 校验: 本机无 mosdns 服务)。"
    rm -f "$bak"
  fi
  rm -rf "$wd"
}
# 规则集派生劫持表(v1.7.3 → 之后)。
#
# 规则集此前只写 mihomo 那一侧: all 模式下"不是国内就劫持"顺带把它们的域名兜住了, gfw 模式
# 下劫持集只有被墙域名 —— 规则集里的域名拿到真实 IP、手机直连, 那条 RULE-SET 规则永远匹配
# 不到。规则加了、UI 说成功了、doctor 也绿, 就是不生效。
#
# 老机器上这个文件要么是空的, 要么是管理员手填的。这里按**现有规则集**重算一次, 之后
# add/del/refresh/恢复 都会在各自的事务里保持它同步。
# 内容全由 bot 侧那一份纯函数产出(单一真源), 这里只负责调用与落盘校验。
migrate_ruleset_hijack(){
  local f=/etc/mosdns/rules/ruleset_hijack.txt meta=/opt/pdg-bot/rulesets.json
  [[ -f /etc/mosdns/config.yaml ]] || return 0
  grep -q 'qname \$explicit_proxy' /etc/mosdns/config.yaml || return 0   # 还没有明确代理层 → 轮不到它
  [[ -s "$meta" ]] || return 0                                            # 没有规则集 → 无从派生
  # 已经是派生产物且与当前规则集一致 → 幂等退出
  local wd; wd="$(mktemp -d)" || return 0
  if ! python3 - "$meta" "$wd/new.txt" <<'PY' 2>"$wd/err"; then
import json, sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
meta = json.load(open(sys.argv[1], encoding="utf-8"))
data, _undrivable = bot.ruleset_hijack_text(meta)
open(sys.argv[2], "wb").write(data)
PY
    c_y "  规则集劫持表未派生(读不出规则集元数据), 保持原样。"; rm -rf "$wd"; return 0
  fi
  if [[ -f "$f" ]] && cmp -s "$f" "$wd/new.txt"; then rm -rf "$wd"; return 0; fi   # 幂等
  # 管理员手填过(不是派生产物)→ 不覆盖, 交给他自己决定
  if [[ -s "$f" ]] && ! head -1 "$f" | grep -q '规则集派生劫持表'; then
    c_y "  /etc/mosdns/rules/ruleset_hijack.txt 是手填的, 未覆盖。"
    c_y "  → 想改用自动派生: 清空它再跑一次 sudo pdg update。"
    rm -rf "$wd"; return 0
  fi
  local bak; bak="$f.pre-derive.$(date +%s)"
  [[ -f "$f" ]] && { cp -a "$f" "$bak" 2>/dev/null || { rm -rf "$wd"; return 0; }; }
  if ! cat "$wd/new.txt" > "$f" 2>/dev/null; then
    c_y "  规则集劫持表写入失败, 还原。"; [[ -f "$bak" ]] && cp -a "$bak" "$f"
    rm -f "$bak"; rm -rf "$wd"; return 0
  fi
  if command -v mosdns >/dev/null 2>&1 && [[ -e /etc/systemd/system/mosdns.service ]]; then
    systemctl restart mosdns 2>/dev/null; sleep 1
    if [[ "$(systemctl is-active mosdns 2>/dev/null)" == active ]]; then
      c_g "  已按现有规则集生成劫持表($(grep -vc '^#' "$f" 2>/dev/null) 条; gfw 模式下规则集才会生效)。"
      rm -f "$bak"
    else
      c_y "  ⚠️ 新劫持表起不来 mosdns → 已还原。"
      [[ -f "$bak" ]] && cp -a "$bak" "$f"; systemctl restart mosdns 2>/dev/null; rm -f "$bak"
    fi
  else
    c_g "  已按现有规则集生成劫持表(未起 mosdns 校验: 本机无 mosdns 服务)。"; rm -f "$bak"
  fi
  rm -rf "$wd"
}

# 用户自定义放行的 include 点(v1.7.6 → 之后)。
#
# 以前 nftscan 撞上冲突时的建议是"把需要的放行并入 table inet pdg 的 input chain" —— 那个
# 建议其实**行不通**: 那张表每次装机/迁移都按模板重建, 手加进去的规则下次就没了。现在模板
# 末尾 glob include 一个不受更新影响的目录, 本函数给老机器补上它。
#
# 用 glob 而不是单文件: 目录空着也能加载。单文件 include 一旦缺文件, 整份 nftables.conf 就
# 加载失败 —— 那等于把人锁在门外。
migrate_nft_extra(){
  local f=/etc/nftables.conf d=/etc/privdns-gateway/nft-input.d
  local inc='        include "/etc/privdns-gateway/nft-input.d/*.conf"'
  [[ -f "$f" ]] || return 0
  install -d -m755 "$d" 2>/dev/null || true
  grep -q 'nft-input\.d/\*\.conf' "$f" && return 0          # 已有 → 幂等
  grep -q '^table inet pdg {' "$f" || return 0                # 还没装 pdg 表 → 轮不到它
  # 本项目的约定: 现场有 input 链冲突、**或读不到运行 ruleset**时, 一个字节都不动防火墙
  # (见 e2e-custom-nft)。那种机器上别的迁移已经决定不碰这个文件, 这里再插一行就把那条保证
  # 破坏了。判据复用 nftscan, 不另写一套 —— 只有它明确回"1=确认无冲突"才动手,
  # 0(有冲突) / 2(读不到) / 其它(脚本自己出错)一律不动。
  local scan rcs=0; scan="$(_pdg_module nftscan.py)" || scan=""
  [[ -n "$scan" ]] || return 0
  python3 "$scan" "$f" >/dev/null 2>&1 || rcs=$?
  [[ "$rcs" == 1 ]] || return 0
  local wd; wd="$(mktemp -d)" || return 0
  if ! python3 - "$f" "$wd/cand.conf" "$inc" <<'PY'; then
import re, sys
f, out, inc = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(f, encoding="utf-8").read().split("\n")
# 只认本项目自己那张表里的 input chain, 且只插在它的**末尾**(policy drop 之前的最后一条),
# 这样用户的放行不会绕过我们对 QUIC 的 reject, 也不会被 policy drop 架空。
i = next((k for k, l in enumerate(lines) if re.match(r"^table\s+inet\s+pdg\s*\{", l)), None)
if i is None:
    raise SystemExit("找不到 table inet pdg")
depth, chain_start, chain_end = 0, None, None
for k in range(i, len(lines)):
    depth += lines[k].count("{") - lines[k].count("}")
    if chain_start is None and re.search(r"^\s*chain\s+input\s*\{", lines[k]):
        chain_start, cd = k, depth
    elif chain_start is not None and depth < cd:
        chain_end = k
        break
    if depth <= 0 and k > i:
        break
if chain_start is None or chain_end is None:
    raise SystemExit("pdg 表里找不到闭合的 input chain")
lines[chain_end:chain_end] = [inc]
open(out, "w", encoding="utf-8").write("\n".join(lines))
PY
    c_y "  防火墙是自定义形态, 未加自定义放行 include 点(不猜着改)。"; rm -rf "$wd"; return 0
  fi
  local nft; nft="$(_pdg_nft_bin)"
  if [[ -n "$nft" && -x "$nft" ]] && ! "$nft" -c -f "$wd/cand.conf" >/dev/null 2>&1; then
    c_y "  加 include 点后 nft -c 未过, 未改动防火墙。"; rm -rf "$wd"; return 0
  fi
  local bak; bak="$f.preinclude.$(date +%s)"
  cp -a "$f" "$bak" 2>/dev/null || { rm -rf "$wd"; return 0; }
  if cat "$wd/cand.conf" > "$f" 2>/dev/null; then
    if [[ -n "$nft" && -x "$nft" ]] && ! "$nft" -f "$f" >/dev/null 2>&1; then
      c_y "  应用带 include 点的防火墙失败 → 已还原。"; cp -a "$bak" "$f"; "$nft" -f "$f" >/dev/null 2>&1 || true
    else
      c_g "  已加自定义放行 include 点: $d/*.conf(放这里的规则不会被更新覆盖)。"
    fi
  fi
  rm -f "$bak"; rm -rf "$wd"
}

# 老装(v1.4.x)从来没有 backend 标记。据现场证据把它落地(unit 文件存在才算数, 免得 is-active
# 的异常输出误导), 让"这台机器此刻跑的是哪个核"成为显式状态而非默认值。
# v1.6.0 起唯一内核是 mihomo, 本函数仍有用: 它跑在 migrate_drop_singbox **之前**, 于是万一
# 迁移失败, 标记如实停在 singbox(而不是谎称已是 mihomo) —— 下次 update 会据此重试迁移。
# 这里的 sing-box 探测只是**读现场**, 不是运行时依赖。
migrate_backend_marker(){
  local bm=/etc/privdns-gateway/backend cur core=""
  cur="$(cat "$bm" 2>/dev/null)"
  [[ "$cur" == mihomo || "$cur" == singbox ]] && return 0       # 已有合法标记 → 幂等
  local u_m=/etc/systemd/system/mihomo.service u_s=/etc/systemd/system/sing-box.service
  if   [[ -e "$u_m" ]] && [[ "$(systemctl is-active mihomo   2>/dev/null)" == active ]]; then core=mihomo
  elif [[ -e "$u_s" ]] && [[ "$(systemctl is-active sing-box 2>/dev/null)" == active ]]; then core=singbox
  elif [[ -e "$u_m" ]] && systemctl is-enabled mihomo   >/dev/null 2>&1; then core=mihomo
  elif [[ -e "$u_s" ]] && systemctl is-enabled sing-box >/dev/null 2>&1; then core=singbox
  elif [[ -f /etc/mihomo/config.yaml ]] && command -v mihomo >/dev/null 2>&1; then core=mihomo
  else core=singbox; fi                                          # 兜底与历史默认一致, 不改变现有行为
  install -d -m700 /etc/privdns-gateway 2>/dev/null || true
  printf '%s\n' "$core" > "$bm" \
    && c_g "  补内核标记: $core(据现场证据; 老装此前一直靠默认值兜底)。"
}

# 5.2/T7: 把内网卡来源段写进 profile.env, 让它成为**唯一真源**。
# 老机器上这个值只存在于两份渲染产物里(nft 的 ip saddr、mosdns 的 npn_clients.ips), 读回时
# 各处自己抠 —— 没有权威答案。救援服务要用它决定监听地址, 所以必须先有真源。
#
# **保守推断**: 两份产物都读得到且完全一致才写入。不一致 = 现网本来就处于半套状态(上次改段
# 只改了一处), 这时候挑一个写进真源, 等于用猜测把不一致固化下来 —— 宁可停手让人来看。
migrate_cidr_single_source(){
  local prof=/etc/privdns-gateway/profile.env
  [[ -f "$prof" ]] || return 0                       # 还没装完(装机自己会写)
  grep -qE '^[[:space:]]*PDG_INTERNAL_CIDR=' "$prof" && return 0     # 已有真源: 幂等
  local nftv mosv
  nftv="$(grep -oE 'ip saddr [0-9.]+/[0-9]+' /etc/nftables.conf 2>/dev/null | head -1 | awk '{print $3}')"
  mosv="$(grep -oE 'ips:[[:space:]]*\[[[:space:]]*"[0-9./]+"' /etc/mosdns/config.yaml 2>/dev/null \
          | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')"
  if [[ -z "$nftv" && -z "$mosv" ]]; then
    c_y "⚠️ 迁移: nft 与 mosdns 里都读不到内网卡段 → 未写入 PDG_INTERNAL_CIDR。"
    c_y "   请运行 sudo pdg detect-cidr 重新识别。"
    return 0
  fi
  if [[ -z "$nftv" || -z "$mosv" || "$nftv" != "$mosv" ]]; then
    c_y "⚠️ 迁移: 内网卡段在两处不一致(nft=${nftv:-读不到} mosdns=${mosv:-读不到})"
    c_y "   → **未写入**真源, 也未改动任何配置。这说明现网本来就是半套状态,"
    c_y "   请运行 sudo pdg detect-cidr 统一后再迁移。"
    return 0
  fi
  # 走与装机同款的原子替换; 失败必须看得见(半个 .tmp 留在盘上比不写更糟)
  local t
  t="$(mktemp /etc/privdns-gateway/.profile.env.XXXXXX)" || { c_y "⚠️ 迁移: 建临时文件失败, 未写入真源"; return 0; }
  { printf 'PDG_INTERNAL_CIDR=%s\n' "$nftv"; cat "$prof"; } > "$t" 2>/dev/null \
    || { rm -f "$t"; c_y "⚠️ 迁移: 写 profile.env 失败, 未改动"; return 0; }
  chmod 600 "$t"
  mv -f "$t" "$prof" || { rm -f "$t"; c_y "⚠️ 迁移: 落盘 profile.env 失败, 未改动"; return 0; }
  grep -q "^PDG_INTERNAL_CIDR=$nftv$" "$prof" \
    || { c_y "⚠️ 迁移: 真源复核未通过"; return 0; }
  c_g "✅ 迁移: 内网卡段真源已写入 profile.env ($nftv)"
}

run_all_migrations(){
  local rc=0
  migrate_platform_marker || true          # 先统一平台判定源(后续平台相关迁移据此走)
  migrate_rescue_plane || true             # 老机首次获得救援平面(用户停用过则不动)
  migrate_backend_marker || true           # 再把内核标记落地(别再靠默认值兜底)
  migrate_cidr_single_source || true       # 先立真源: 后续 nft/mosdns/救援都从它读
  migrate_botenv || true; migrate_firewall_to_pdg || true; migrate_mosdns_concurrent || true
  migrate_mosdns_unlock || true; migrate_fw_gms || true
  migrate_mosdns_ratelimit || true; migrate_lowmem || true; migrate_mihomo_safepaths || true
  migrate_deploy_botfiles || true; migrate_deploy_units || true
  migrate_mosdns_hijack_shape || true
  migrate_mosdns_explicit_proxy || true
  migrate_ruleset_hijack || true
  migrate_nft_extra || true
  migrate_custom_hijack || true
  migrate_mosdns_mitm || true; migrate_pdg_mitm_service || true
  migrate_android_cleanup || true
  # iOS GMS 清理**失败必须传出**: 它会动 model + 内核配置 + 防火墙三样, 失败即现网可能与
  # 期望形态不一致(它自己会完整回滚, 但回滚不完整时更要让上层知道)。以前是 `|| true`,
  # 于是 cmd_update / cmd_migrate / cmd_platform 全都收不到这条失败。
  migrate_ios_gms_cleanup || rc=1
  # 内核迁移放最后: 上面的 config.json / mosdns / 防火墙 迁移都先按老路子跑完(它们只动数据模型
  # 与 nft, 与内核无关), 这里再把**最终形态的** config.json 转 mihomo 并移除 sing-box 运行时。
  # 唯一"失败必须传出"的迁移 —— 失败即让 __migrate 返回非0,
  # cmd_update 据此回滚到更新前快照(其余迁移都是幂等自愈, 失败 best-effort 吞掉不挡后续)。
  migrate_drop_singbox || rc=1
  return $rc
}

# 迁移到 mihomo 时渲染并应用 mihomo 的 nft 入站模型(REDIRECT→7893)。出口/分流/证书/DoT/mosdns
# 全不动(model 共用)。$1 目前恒为 mihomo(唯一内核), 保留形参以兼容 _activate_mihomo_core 调用。
# 找出**除 table inet pdg 之外**挂在 `hook input` 上的 base chain。
# 为什么这条是硬门槛: PDG 的 input chain 是 `policy drop`, 而 nftables 里同一 hook 上的多个
# base chain **都会执行** —— 任一条判 drop, 包就没了。于是用户自己的 input chain 里对 9443 /
# WireGuard 的 accept 会被 PDG 这条 drop 架空: 配置文本还在, 端口实际已经不通, 而迁移还报成功。
# 这种"看着保留、其实失效"比直接报错危险得多, 故一律中止, 交由用户手工合并。
# 检测同时看**配置文件**与**当前运行 ruleset**(两边都可能只有一侧有), 宁可保守中止。
# 判据本身放在 deploy/bot/nftscan.py —— 迁移前置门与 doctor 共用同一份, 免得两处正则各写
# 一遍慢慢漂移(一边判冲突一边判干净, 比都不判还糟)。
# stdout: 冲突描述(每行一条)。返回 0=有冲突, 1=确认没有, 2=读不到运行 ruleset 无法确认。
_pdg_nft_foreign_input_chains(){
  local conf="${1:-/etc/nftables.conf}" scan
  for scan in "${REPO_DIR:-/opt/privdns-gateway}/deploy/bot/nftscan.py" /opt/pdg-bot/nftscan.py; do
    [[ -f "$scan" ]] || continue
    python3 "$scan" "$conf"
    return $?
  done
  # 判据脚本都不在 → 不能假装现场干净(那正是这道门要挡的事), 按"无法确认"处理
  echo "找不到 nftscan.py(判据脚本缺失), 无法确认 input 链冲突"
  return 2
}

# 把渲染好的 pdg 表块**合并**进现网 nftables.conf: 只替换本项目管理区(table inet pdg 的
# 声明/delete/表体), 其余内容逐字节保留。$1=渲染好的块文件 $2=目标 conf $3=输出文件。
# 无法证明能安全合并(pdg 块括号不配平 / 文件里有 flush ruleset 又还有别的表)→ 返回非 0,
# 调用方必须在改动运行环境**之前**中止 —— 整文件覆盖会把用户的 VPN/NAT/转发/开放端口抹掉。
_pdg_nft_splice(){
  local m
  for m in "${REPO_DIR:-/opt/privdns-gateway}/deploy/bot/nftmerge.py" /opt/pdg-bot/nftmerge.py; do
    [[ -f "$m" ]] || continue
    python3 "$m" "$1" "$2" "$3"
    return $?
  done
  echo "找不到 nftmerge.py(合并脚本缺失), 拒绝合并防火墙配置" >&2
  return 1
}

_switchcore_nft(){   # $1=target(mihomo)  渲染并应用 mihomo nft(用当前 SSH端口/内网段)
  local target="$1" sshp icidr
  [[ "$target" == mihomo ]] || { echo "内部错误: _switchcore_nft 只支持 mihomo(收到 $target)"; return 1; }
  sshp=$(grep -oP '^\s*tcp dport \{ \K[0-9]+(?= \} accept)' /etc/nftables.conf | head -1)
  # 现网 nft 认不出 SSH 端口时(自定义/异形防火墙)不能直接判死 —— 这条路现在跑在**自动迁移**里,
  # 硬失败会把用户永久挡在旧版上。退回问 sshd 实际在听哪个口, 再退回 22(与装机探测同口径)。
  if [[ -z "$sshp" ]]; then
    sshp=$(ss -lntpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}')
    sshp="${sshp:-22}"
    c_y "  未能从 /etc/nftables.conf 认出 SSH 端口 → 按实际监听/默认值取 $sshp(新防火墙会放行它)。"
  fi
  icidr=$(python3 -c "import sys;sys.path.insert(0,'/opt/pdg-bot');import checks;print(checks._internal_cidr())" 2>/dev/null)
  [[ -n "$sshp" && -n "$icidr" ]] || { echo "提取 SSH端口/内网段失败(ssh=$sshp cidr=$icidr)"; return 1; }
  [[ -f "$REPO_DIR/deploy/firewall/nftables-mihomo.conf" ]] || { echo "缺 nftables-mihomo.conf(先 pdg update)"; return 1; }
  # 兜底(调用方本应已在更早处拦下): 别的 input base chain 与 PDG 的 policy drop 不兼容,
  # 在写文件/执行 nft 之前中止, 免得"文本保留、端口失效"。
  local _fic2 _frc2
  _fic2="$(_pdg_nft_foreign_input_chains /etc/nftables.conf)"; _frc2=$?
  if [[ "$_frc2" == 0 ]]; then
    echo "检测到自定义 input base chain, 与 PDG 的 policy drop 不兼容 → 未改动防火墙:"
    printf '%s\n' "$_fic2" | sed 's/^/    /'
    return 1
  fi
  if [[ "$_frc2" == 2 ]]; then     # 读不到运行 ruleset: 不能假装干净就往下写规则
    echo "无法确认 input 链冲突 → 未改动防火墙:"
    printf '%s\n' "$_fic2" | sed 's/^/    /'
    return 1
  fi
  local wd rendered merged bak rc
  wd="$(mktemp -d)" || { echo "无法创建临时目录"; return 1; }
  rendered="$wd/pdg.nft"; merged="$wd/merged.conf"; bak="$wd/nftables.conf.bak"
  sed -e "s|__SSH_PORT__|$sshp|g" -e "s|__INTERNAL_CIDR__|$icidr|g" \
      "$REPO_DIR/deploy/firewall/nftables-mihomo.conf" > "$rendered"
  _pdg_nft_strip_gms "$rendered"          # iOS: 渲染后剥掉 GMS 5228-5230
  # 备份必须先成立(逐字节校验): 后面任何一步失败都要靠它把现网原样放回去
  if [[ -e /etc/nftables.conf ]]; then
    if ! cp -a /etc/nftables.conf "$bak" 2>/dev/null || ! cmp -s /etc/nftables.conf "$bak"; then
      rm -rf "$wd"; echo "备份 /etc/nftables.conf 失败(磁盘满?), 未改动防火墙"; return 1
    fi
  fi
  # 只替换本项目管理区(table inet pdg), 用户的额外表/VPN/NAT/转发/开放端口原样保留。
  # 合并不了(块不配平 / flush ruleset 与别的表共存)→ 在改动运行环境之前就中止。
  if ! _pdg_nft_splice "$rendered" /etc/nftables.conf "$merged"; then
    rm -rf "$wd"
    echo "无法安全合并防火墙配置 → 未改动 /etc/nftables.conf(见上方冲突位置)"
    echo "  请把本项目所需规则手工并入 table inet pdg 后重试, 或先备份并清理冲突配置。"
    return 1
  fi
  if ! nft -c -f "$merged" >/dev/null 2>&1; then
    rm -rf "$wd"; echo "合并后的 nftables 配置校验(nft -c)未过, 未改动防火墙"; return 1
  fi
  if ! cp -f "$merged" /etc/nftables.conf 2>/dev/null || ! cmp -s "$merged" /etc/nftables.conf; then
    [[ -e "$bak" ]] && cp -a "$bak" /etc/nftables.conf 2>/dev/null
    rm -rf "$wd"; echo "写入 /etc/nftables.conf 失败(磁盘满?), 已还原"; return 1
  fi
  if ! nft -f /etc/nftables.conf; then
    rc=1
    if [[ -e "$bak" ]]; then
      cp -a "$bak" /etc/nftables.conf 2>/dev/null
      nft -f /etc/nftables.conf 2>/dev/null || true
      echo "应用新防火墙失败 → 已还原并重新应用原配置"
    fi
    rm -rf "$wd"; return "$rc"
  fi
  rm -rf "$wd"
}

# 内核切换的 enable/disable 收尾 + 状态核验(单一职责, 便于打桩测试)。
# 目标: 目标核 enable --now 且 active+enabled; 旧核 disable --now 且 inactive+非 enabled
# (旧核只 stop 不 disable = 仍自启, 重启会双起 → 冲突)。任一不满足返回非 0。
# $1=目标核 svc  $2=旧核 svc。
_core_kernel_activate(){
  local tgt="$1" old="$2"
  systemctl reset-failed "$tgt" 2>/dev/null
  systemctl enable --now "$tgt" >/dev/null 2>&1 || { echo "  enable/start $tgt 失败"; return 1; }
  systemctl disable --now "$old" >/dev/null 2>&1 || true   # 旧核停用+关自启; 下面核验兜底
  sleep 2
  [[ "$(systemctl is-active  "$tgt" 2>/dev/null)" == active  ]] || { echo "  $tgt 未 active";  return 1; }
  [[ "$(systemctl is-enabled "$tgt" 2>/dev/null)" == enabled ]] || { echo "  $tgt 未 enabled"; return 1; }
  [[ "$(systemctl is-active  "$old" 2>/dev/null)" != active  ]] || { echo "  旧核 $old 仍 active"; return 1; }
  [[ "$(systemctl is-enabled "$old" 2>/dev/null)" == enabled ]] && { echo "  旧核 $old 仍 enabled(重启会双起)"; return 1; }
  return 0
}

# 切换失败回退: 目标核 disable+stop, 旧核 enable --now 恢复原态。
# $1=目标核 svc  $2=旧核 svc。
_core_kernel_restore(){
  local tgt="$1" old="$2"
  systemctl disable --now "$tgt" >/dev/null 2>&1 || true
  systemctl reset-failed "$old" 2>/dev/null
  systemctl enable --now "$old" >/dev/null 2>&1 || true
}

# 把当前机器激活成 mihomo 内核: 下核 → 渲染(拒 unknown_proxies) → mihomo -t 校验 → 写 unit →
# nft REDIRECT 入站 → 起 mihomo 并停旧 sing-box(_core_kernel_activate)。带失败回滚。成功 0 / 失败非 0。
# 由 migrate_drop_singbox 调用(旧 sing-box 机器 update 时迁移)。出口/分流/证书/DoT/mosdns 均不动(model 共用)。
_activate_mihomo_core(){
  local march plat prev_backend why t
  prev_backend="$(cat /etc/privdns-gateway/backend 2>/dev/null)"
  march=$(dpkg --print-architecture 2>/dev/null); [[ "$march" == arm64 ]] || march=amd64
  plat="$(_pdg_platform)"
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/versions.sh" 2>/dev/null || { echo "❌ 读不到 versions.sh"; return 1; }
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/units.sh"   2>/dev/null || { echo "❌ 读不到 units.sh"; return 1; }
  cp /etc/nftables.conf /etc/nftables.conf.scbak 2>/dev/null

  if ! pdg_mihomo_is_version "$MIHOMO_VER"; then
    c_g "下载 mihomo $MIHOMO_VER…"; t=$(mktemp -d)
    if ! curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-${march}-${MIHOMO_VER}.gz" -o "$t/m.gz" \
       || ! pdg_verify_sha256 "$t/m.gz" "${PDG_SHA256[mihomo-$march]:-}" "mihomo $MIHOMO_VER" \
       || ! gunzip -c "$t/m.gz" > "$t/mihomo"; then rm -rf "$t"; echo "❌ mihomo 下载/校验失败, 未迁移"; return 1; fi
    install -m755 "$t/mihomo" /usr/local/bin/mihomo; rm -rf "$t"
  fi
  install -d -m700 /etc/mihomo
  printf 'mihomo\n' > /etc/privdns-gateway/backend      # 先切标记, 让渲染/迁移按 mihomo 走
  # 渲染前先拦: 有出口 mihomo 无法无损转换(unknown_proxies)→ 拒绝迁移, 免得凭空丢一个出口。
  # 把**真实原因**带出来(渲染抛异常 / 有出口转不了 分开报), 用户据此在 bot 里删/换该出口再重试。
  if ! why=$(cd /opt/pdg-bot && python3 - <<'SCPY' 2>&1
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
try:
    meta = bot._render_mihomo_file()
except Exception as e:
    print("渲染 mihomo 配置失败: %s: %s" % (type(e).__name__, e)); sys.exit(1)
bad = (meta or {}).get("unknown_proxies") or []
if bad:
    print("这些出口 mihomo 无法转换(迁移会凭空丢失): " + ", ".join(str(x) for x in bad)); sys.exit(1)
# 规则/规则集同理: 进不了 mihomo 运行配置就不能迁 —— 迁过去 `mihomo -t` 照样会过, 但那条
# 分流实际已经不存在了。典型是老机器上遗留的 sing-box 二进制 .srs 规则集(mihomo 读不了)。
drop = (meta or {}).get("dropped") or []
if drop:
    names = [str(d.get("rule_set") or d) for d in drop] if isinstance(drop[0], dict) else [str(x) for x in drop]
    print("这些规则/规则集无法进入 mihomo 运行配置(迁移会凭空丢失): " + ", ".join(names[:8]))
    print("  .srs 是 sing-box 二进制规则集, mihomo 读不了 —— 请先在 bot 里删掉并换成 "
          ".list/.txt/.yaml/.mrs, 再重试 sudo pdg update。")
    sys.exit(1)
SCPY
  ); then
    printf '%s\n' "${prev_backend:-singbox}" > /etc/privdns-gateway/backend
    echo "❌ 未迁移(已回滚标记): ${why:-渲染 mihomo 配置失败(无输出)}"; return 1
  fi
  if ! why=$(mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml 2>&1); then
    printf '%s\n' "${prev_backend:-singbox}" > /etc/privdns-gateway/backend
    echo "❌ 未迁移(已回滚标记): mihomo 配置校验失败:"
    printf '%s\n' "$why" | tail -c 400 | sed 's/^/    /'; return 1
  fi
  pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service   # 与装机同源(含 SAFE_PATHS)
  [[ "$plat" == ios ]] && pdg_write_unit pdg_unit_pdg_mitm /etc/systemd/system/pdg-mitm.service
  systemctl daemon-reload
  _switchcore_nft mihomo || { printf '%s\n' "${prev_backend:-singbox}" > /etc/privdns-gateway/backend; [[ -f /etc/nftables.conf.scbak ]] && { cp /etc/nftables.conf.scbak /etc/nftables.conf; nft -f /etc/nftables.conf; }; echo "❌ nft 应用失败, 已回滚"; return 1; }
  if ! _core_kernel_activate mihomo sing-box; then
    c_y "mihomo 启动/自启核验失败 → 回滚"
    printf '%s\n' "${prev_backend:-singbox}" > /etc/privdns-gateway/backend
    [[ -f /etc/nftables.conf.scbak ]] && { cp /etc/nftables.conf.scbak /etc/nftables.conf; nft -f /etc/nftables.conf 2>/dev/null; }
    _core_kernel_restore mihomo sing-box; rm -f /etc/nftables.conf.scbak
    echo "❌ 迁移失败, 已回滚。mihomo 最近日志:"
    journalctl -u mihomo -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  [[ "$plat" == ios ]] && { systemctl reset-failed pdg-mitm 2>/dev/null; systemctl enable --now pdg-mitm >/dev/null 2>&1 || true; }
  rm -f /etc/nftables.conf.scbak
  return 0
}

# 旧 sing-box 机器迁到 mihomo(v1.6.0 彻底移除 sing-box 运行时)。加入 run_all_migrations, 故 `pdg update`
# 走 __migrate 时自动执行。幂等: 已是纯 mihomo(无 sing-box 服务/二进制)直接返回 0。
# 失败(unknown_proxies / 渲染 / 校验 / 起核)返回非 0 → run_all_migrations 传出 → cmd_update 回滚到
# 更新前快照(用户仍留在旧 sing-box 版, 数据无损), 而不是把机器留在半迁移态。
# v2.0 清理候选(见 docs/ROADMAP.md): 仍有从 v1.5.x 及更早直接升上来的机器, 删掉这段迁移
# 会让那些机器升级后同时躺着两个内核。
migrate_drop_singbox(){
  local cur; cur="$(cat /etc/privdns-gateway/backend 2>/dev/null)"
  if [[ "$cur" == mihomo ]] && [[ ! -e /etc/systemd/system/sing-box.service ]] && [[ ! -e /usr/local/bin/sing-box ]]; then
    return 0                                    # 已是纯 mihomo → 幂等短路
  fi
  # backend 已是 mihomo, 只剩来源不明的 sing-box 文件 → 那不是本项目的东西, 不该每次更新都去动它
  if [[ "$cur" == mihomo ]] && ! _pdg_singbox_is_ours; then
    _pdg_drop_singbox_files "非本项目安装"      # 只打印保留提示, 不删
    return 0
  fi
  # 前置硬门槛: 现场若还有别的 input base chain, PDG 的 policy drop 会把它们的放行架空
  # (配置看着还在、端口实际不通)。必须在**动任何东西之前**中止 —— 下核、翻标记、渲染配置、
  # 写 unit、改 nft、切服务, 一个都还没做。
  local _fic _frc
  _fic="$(_pdg_nft_foreign_input_chains /etc/nftables.conf)"; _frc=$?
  # 2 = 读不到运行中的 ruleset(非 root / nft 不可用): 内存里的冲突链没进视野, 不能当成干净。
  # 迁移本来就要写 nft 规则, 这台机器上迟早也过不去 —— 早停一步, 现场还没被动过。
  if [[ "$_frc" == 2 ]]; then
    c_y "无法确认现场是否存在其它 input base chain → 中止迁移(现场未做任何改动)。"
    printf '%s\n' "$_fic" | sed 's/^/    /'
    c_y "  怎么办: 用 root 重试 sudo pdg update; 若本机确无 nftables, 请先装好 nftables 再迁移。"
    return 1
  fi
  if [[ "$_frc" == 0 ]]; then
    c_y "检测到自定义 input base chain, 无法保证与 PDG 默认拒绝策略(policy drop)兼容 → 中止迁移。"
    printf '%s\n' "$_fic" | sed 's/^/    /'
    c_y "  原因: nftables 同一 hook 上的多个 base chain 都会执行, 任一条 drop 包就没了 ——"
    c_y "        PDG 的 input chain 是 policy drop, 会把上面这些表里的放行(如自定义端口/VPN)架空,"
    c_y "        表面上配置都在, 实际端口不通。这种失效比直接报错更难排查, 故不自动处理。"
    c_y "  怎么办: 把上述表里需要的放行规则并入 table inet pdg 的 input chain(或改用非 input hook),"
    c_y "          再重试 sudo pdg update。现场未做任何改动, sing-box 仍在正常运行。"
    return 1
  fi
  c_y "检测到 sing-box 运行时(v1.6.0 已移除)→ 迁移到 mihomo 唯一内核(出口/分流/证书/DoT 不动)…"
  _activate_mihomo_core || { echo "❌ 迁移到 mihomo 失败(见上)。请在 TG bot 处理无法转换的出口后, 重试 sudo pdg update。"; return 1; }
  # 收尾: _core_kernel_activate 已 stop+disable sing-box; 再删掉**本项目装的** unit + 二进制
  # (来源不明的一律保留 —— 删别人的东西不可逆)。
  _pdg_drop_singbox_files
  systemctl daemon-reload 2>/dev/null || true
  printf 'mihomo\n' > /etc/privdns-gateway/backend
  c_g "  已迁移到 mihomo 内核, sing-box 运行时已移除。"
  return 0
}

# 切换劫持模式: all(非CN全劫持) | gfw(只劫持 GFWList 真被墙域名, 非墙海外直连)。换 hijack_set 加载的域名文件。
# 人工确认手机平台。装机时会写标记; 只有老装(v1.4.x 无平台概念)推断不出来才需要手工定。
# profile.env 的 PDG_PLATFORM 与 platform 文件必须同步 —— 后者丢了(备份恢复/手工清理)时
# _pdg_platform 会回退去读 profile.env, 两处不一致就会在下一次迁移里把平台判反。
_plat_write_profile(){
  _profile_set PDG_PLATFORM "$1"
}

# 部署 iOS 专属组件(幂等)。probe81 / 描述文件模板 / MITM 模块 —— 缺一样 doctor 就会报
# "pdg-probe81 未运行 / :81 无响应", 而以前 `pdg platform ios` 只写个标记就说"已确认"。
# iOS 平台必须存在的文件(源 → 目标)。切平台是**事务**, 这里一个都不能少。
_PLAT_IOS_REQUIRED=(
  "deploy/ios/probe81.py|/opt/pdg-bot/probe81.py|755"
  "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl|/opt/pdg-bot/pdg-dot.mobileconfig.tmpl|644"
  "deploy/bot/iosprofile.py|/opt/pdg-bot/iosprofile.py|755"
  "deploy/bot/iosstate.py|/opt/pdg-bot/iosstate.py|755"
  "deploy/bot/mitm_ca.py|/opt/pdg-bot/mitm_ca.py|755"
  "deploy/bot/mitm_server.py|/opt/pdg-bot/mitm_server.py|755"
  "deploy/bot/mitm_wloc.py|/opt/pdg-bot/mitm_wloc.py|755"
  "deploy/ios/pdg-probe81.service|/etc/systemd/system/pdg-probe81.service|644"
)

_plat_deploy_ios(){
  # 严格模式: 每个必需文件自己装、自己查, 不走 migrate_deploy_botfiles ——
  # 那是**幂等迁移**的语义(`install … || true`, 装不上就当没这回事, 下轮再补), 放在平台切换
  # 这种一次性事务里就成了洞: 注入 mitm_server.py 安装失败后命令照样 RC=0、platform=ios,
  # 而机器上既没有 mitm_server.py 也没有 pdg-mitm.service —— 一个半残的 iOS 现场。
  local ent src dst mode
  install -d -m755 /opt/pdg-bot || { echo "  创建 /opt/pdg-bot 失败"; return 1; }
  for ent in "${_PLAT_IOS_REQUIRED[@]}"; do
    IFS='|' read -r src dst mode <<< "$ent"
    if ! install -m"$mode" "$REPO_DIR/$src" "$dst" 2>/dev/null; then
      echo "  部署失败: $src → $dst"; return 1
    fi
    [[ -s "$dst" ]] || { echo "  部署后文件为空/不存在: $dst"; return 1; }
  done
  systemctl daemon-reload >/dev/null 2>&1 || { echo "  systemctl daemon-reload 失败"; return 1; }
  systemctl reset-failed pdg-probe81 >/dev/null 2>&1 || true
  systemctl enable --now pdg-probe81 >/dev/null 2>&1 || { echo "  启用 pdg-probe81 失败"; return 1; }
  # pdg-mitm unit 也照严格口径写(migrate_pdg_mitm_service 是幂等迁移, 失败同样是吞掉的)
  # shellcheck source=lib/units.sh
  source "$REPO_DIR/lib/units.sh" 2>/dev/null || { echo "  读不到 lib/units.sh"; return 1; }
  pdg_write_unit pdg_unit_pdg_mitm /etc/systemd/system/pdg-mitm.service \
    || { echo "  写 pdg-mitm.service 失败"; return 1; }
  systemctl daemon-reload >/dev/null 2>&1 || { echo "  systemctl daemon-reload 失败"; return 1; }
  systemctl reset-failed pdg-mitm >/dev/null 2>&1 || true
  systemctl enable --now pdg-mitm >/dev/null 2>&1 || { echo "  启用 pdg-mitm 失败"; return 1; }
  return 0
}

# 切换成功前的复核: 目标平台**该有的**在、**该没有的**不在。
# 部署那步逐个查过返回值了, 这里再看一遍最终现场 —— 中间任何一步把文件又弄没了(比如某条
# 幂等迁移顺手清理), 也能在返回 0 之前发现。
_plat_verify(){
  local p="$1" f miss=() extra=()
  if [[ "$p" == ios ]]; then
    local ent dst
    for ent in "${_PLAT_IOS_REQUIRED[@]}"; do
      dst="$(cut -d'|' -f2 <<< "$ent")"
      [[ -s "$dst" ]] || miss+=("$dst")
    done
    [[ -s /etc/systemd/system/pdg-mitm.service ]] || miss+=("/etc/systemd/system/pdg-mitm.service")
    [[ "$(systemctl is-active pdg-probe81 2>/dev/null)" == active ]] || miss+=("pdg-probe81(未运行)")
    [[ "$(systemctl is-active pdg-mitm 2>/dev/null)" == active ]] || miss+=("pdg-mitm(未运行)")
  else
    for f in /opt/pdg-bot/probe81.py /opt/pdg-bot/pdg-dot.mobileconfig.tmpl \
             /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py \
             /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py \
             /etc/systemd/system/pdg-probe81.service /etc/systemd/system/pdg-mitm.service; do
      [[ -e "$f" ]] && extra+=("$f")
    done
    [[ "$(systemctl is-active pdg-probe81 2>/dev/null)" == active ]] && extra+=("pdg-probe81(仍在运行)")
    [[ "$(systemctl is-active pdg-mitm 2>/dev/null)" == active ]] && extra+=("pdg-mitm(仍在运行)")
  fi
  if [[ ${#miss[@]} -gt 0 ]]; then
    echo "❌ 切到 $p 后这些必需项缺失: ${miss[*]}"; return 1
  fi
  if [[ ${#extra[@]} -gt 0 ]]; then
    echo "❌ 切到 $p 后这些 iOS 专属残留没清掉: ${extra[*]}"; return 1
  fi
  return 0
}

# 切平台: 全局锁 + 快照 + 就地备份, 任一步失败恢复原平台与原配置并返回非 0。
# 以前这里只写个标记就 run_all_migrations 并恒返回 0: Android→iOS 缺 probe81/描述文件模板,
# iOS→Android 的 nft 里 GMS 5228-5230 回不来、mihomo 配置里 MITM-OUT 还留着, 而命令还说"已确认"。
UNIT_DIR="${PDG_UNIT_DIR:-/etc/systemd/system}"

_rescue_write_units(){
  local bind="$1" src="$REPO_DIR/deploy/rescue"
  [[ -d "$src" ]] || src=/opt/pdg-bot        # 仓库不在时用装好的那份(10a-1 已装 rescue.py 等)
  [[ -f "$src/pdg-rescue.socket" ]] || return 1
  sed -e "s|__RESCUE_BIND__|$bind|g" -e "s|__RESCUE_PORT__|$PDG_RESCUE_PORT|g" \
      "$src/pdg-rescue.socket" > "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" || return 1
  sed -e "s|__RESCUE_BIND__|$bind|g" -e "s|__RESCUE_PORT__|$PDG_RESCUE_PORT|g" \
      "$src/pdg-rescue.service" > "$UNIT_DIR/$PDG_RESCUE_SERVICE_UNIT" || return 1
  chmod 644 "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" "$UNIT_DIR/$PDG_RESCUE_SERVICE_UNIT"
}

# 配置里有没有**我们自己注入的**救援放行。判据交给 rescue_nft.py(它认自己的独立表),
# 不在这里按端口猜 —— 按端口猜会把用户自己写的同端口规则也算成我们的。
_rescue_nft_has(){
  [[ -f /etc/nftables.conf ]] || return 1
  local bind; bind="$(_rescue_bind_addr || true)"
  python3 - /etc/nftables.conf "$PDG_RESCUE_PORT" "${bind:-}" <<'PYH'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import rescue_nft
txt = open(sys.argv[1], encoding="utf-8", errors="surrogateescape").read()
sys.exit(0 if rescue_nft.has_rescue_rule(txt, int(sys.argv[2]), sys.argv[3] or None) else 1)
PYH
}

# 内核里有没有(数的是我们标记过的那条, 不是"含救援端口的任意行")
_rescue_nft_has_kernel(){
  local bind; bind="$(_rescue_bind_addr || true)"
  [[ -n "$bind" ]] || return 1
  nft list table inet pdg 2>/dev/null | grep -q "comment \"pdg-rescue\"" || return 1
  nft list table inet pdg 2>/dev/null | grep "comment \"pdg-rescue\"" | grep -q "$bind"
}

# 我们的规则在磁盘/内核里各有几条(盯"恰好一条")
_rescue_nft_count_disk(){
  python3 - /etc/nftables.conf "$PDG_RESCUE_PORT" <<'PYC'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import rescue_nft
print(rescue_nft.count_rules(open(sys.argv[1], encoding="utf-8", errors="surrogateescape").read(),
                             int(sys.argv[2])))
PYC
}
_rescue_nft_count_kernel(){
  # grep -c 计数为 0 时退出码是 1 —— 调用处若写了 `|| echo ?`, 就会在数字后面再打一个 "?",
  # 事故现场读到 "0 ?" 只会更慌。这里把退出码吞掉, 只输出数字。
  local n; n="$(nft list table inet pdg 2>/dev/null | grep -c 'comment "pdg-rescue"' || true)"
  printf '%s' "${n:-0}"
}

# 旧版独立表 inet pdgrescue 的清理(幂等)。0=没有或已清掉; 1=同名但形态不是我们生成的 → 不动它。
# 为什么必须清: 它挂在 input hook 上, doctor 会判成冲突, 于是启用救援平面的机器每次
# pdg update 的更新后自检都失败并整次回滚(.200 实机实测)。而它本来也不起作用 ——
# 同一 hook 上多条基链挨个走, 它的 accept 盖不过 inet pdg 的 policy drop。
_rescue_nft_drop_legacy(){
  local rc=0
  if [[ -f /etc/nftables.conf ]]; then
    python3 /opt/pdg-bot/rescue_nft.py --legacy-check < /etc/nftables.conf >/dev/null 2>&1
    rc=$?
    if (( rc == 2 )); then
      c_y "  ⚠️ 配置里有一张 inet pdgrescue, 但形态与本项目生成的不一致 —— 不擅自删除, 请自行确认。"
      return 1
    fi
  fi
  nft list tables 2>/dev/null | grep -q "inet pdgrescue" && nft delete table inet pdgrescue 2>/dev/null
  return 0
}

# 放行: 只往项目自己的 inet pdg input 链首插一条带标记的规则, 候选先过 nft -c 再整份应用。
# 整份应用(模板里带 `delete table inet pdg` 再重建)保证**磁盘与内核一致** —— 增量 nft -f
# 删不掉已经不在文件里的东西, 那正是旧实现留下孤儿表的原因。
_rescue_nft_open(){
  local cidr bind cand
  cidr="$(pdg_internal_cidr 2>/dev/null || true)"; [[ -n "$cidr" ]] || return 1
  bind="$(_rescue_bind_addr || true)";            [[ -n "$bind" ]] || return 1
  _rescue_nft_drop_legacy || return 1
  cand="$(_pdg_mktemp_dir)/nft.cand" || return 1
  python3 /opt/pdg-bot/rescue_nft.py "$cidr" "$PDG_RESCUE_PORT" "$bind" \
    < /etc/nftables.conf > "$cand" 2>/dev/null || return 1
  nft -c -f "$cand" >/dev/null 2>&1 || return 1      # 候选先校验, 再动现网
  cp -a /etc/nftables.conf /etc/nftables.conf.pdg-rescue-bak 2>/dev/null || true
  mv -f "$cand" /etc/nftables.conf || return 1
  nft -f /etc/nftables.conf >/dev/null 2>&1 || {
    mv -f /etc/nftables.conf.pdg-rescue-bak /etc/nftables.conf 2>/dev/null
    nft -f /etc/nftables.conf >/dev/null 2>&1; return 1; }
  rm -f /etc/nftables.conf.pdg-rescue-bak
  # 磁盘与内核都必须**恰好一条**; 对不上就回滚, 不留"看着开了实际不通"或重复规则
  [[ "$(_rescue_nft_count_disk)" == 1 && "$(_rescue_nft_count_kernel)" == 1 ]] || return 1
  return 0
}

# 撤销: 精确摘掉带标记的那条(rescue_nft.py --strip), 再整份重新应用 —— 磁盘与内核同时干净。
# 绝不按端口去删行: 用户完全可能自己写过一条同端口放行, 那是他的规则。
_rescue_nft_close(){
  [[ -f /etc/nftables.conf ]] || return 0
  local cand bak; cand="$(_pdg_mktemp_dir)/nft.cand" || return 1
  bak=/etc/nftables.conf.pdg-rescue-bak
  python3 /opt/pdg-bot/rescue_nft.py --strip < /etc/nftables.conf > "$cand" || return 1
  nft -c -f "$cand" >/dev/null 2>&1 || return 1
  cp -a /etc/nftables.conf "$bak" 2>/dev/null || true
  mv -f "$cand" /etc/nftables.conf || return 1
  nft -f /etc/nftables.conf >/dev/null 2>&1 || {
    mv -f "$bak" /etc/nftables.conf 2>/dev/null; nft -f /etc/nftables.conf >/dev/null 2>&1; return 1; }
  _rescue_nft_drop_legacy || true                  # 顺手带走旧独立表(内核对象)
  rm -f "$bak"
  [[ "$(_rescue_nft_count_disk)" == 0 && "$(_rescue_nft_count_kernel)" == 0 ]] || return 1
  return 0
}

# ── 救援平面的生命周期 ────────────────────────────────────────────────────
# 只有 enable / disable / status / fingerprint / rotate-token / rotate-cert 六个动作 ——
# 都是既有设计里就有的, 不自行加新命令。
_rescue_load(){
  # shellcheck source=lib/rescue.sh
  source "$REPO_DIR/lib/rescue.sh" 2>/dev/null || source /opt/pdg-bot/rescue.sh 2>/dev/null \
    || { echo "❌ 读不到救援常量(lib/rescue.sh)"; return 1; }
}

# 本机上落在内网卡段内的地址。找不到返回空 —— 绝不退回 0.0.0.0: 把恢复入口开到公网上,
# 等于把"换默认出口""完整恢复"这些按钮交给任何人。
# 监听地址 = profile.env 里的 PDG_RESCUE_BIND, **不再从来源段推导**。
# 那个假设在真实网关上不成立: 来源段是客户端所在的运营商内网, 而网关自己的地址在另一张网上,
# 于是"在来源段里找一个本机地址"什么也找不到, 救援平面在它唯一被需要的拓扑上根本起不来
# (.200 实机实测)。读不到就返回 1, 由调用方给出配置指引 —— 绝不回落到 0.0.0.0。
_rescue_bind_addr(){
  local v; v="$(pdg_rescue_bind 2>/dev/null || true)"
  [[ -n "$v" ]] || return 1
  pdg_rescue_bind_valid "$v" || return 1
  printf '%s\n' "$v"
}

# 本机所有 IPv4(供"没配 bind 时列给用户选"用; 绝不替用户选)
_rescue_bind_candidates(){
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '{split($4,a,"/"); print $2, a[1]}'
}

# 来源段内恰好一个本机地址 → 沿用旧的安全路径并落盘(老机器平滑迁移)。
# 有零个或多个都返回非 0: 多个的时候猜错就是把恢复入口开在错误的网上。
_rescue_bind_from_cidr(){
  local cidr; cidr="$(pdg_internal_cidr 2>/dev/null || true)"
  [[ -n "$cidr" ]] || return 1
  python3 - "$cidr" <<'PYB'
import ipaddress, subprocess, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except Exception:
    sys.exit(1)
out = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"],
                     capture_output=True, text=True).stdout
hits = []
for line in out.splitlines():
    parts = line.split()
    for i, tok in enumerate(parts):
        if tok == "inet" and i + 1 < len(parts):
            try:
                ip = ipaddress.ip_address(parts[i + 1].split("/")[0])
            except ValueError:
                continue
            if ip in net:
                hits.append(str(ip))
sys.exit(1) if len(hits) != 1 else print(hits[0])
PYB
}

# ── 启用意图的**单一真源**: profile.env 里的 PDG_RESCUE_ENABLED ──────────
# 为什么不能只看 systemctl is-active: 那分不清"用户关的"和"服务崩了"。前者升级时必须尊重,
# 后者升级时应当把它救回来 —— 判错任何一个方向都很糟(要么擅自打开用户关掉的入口, 要么让
# 一台本该有救援的机器一直没有)。所以意图单独记, 且用项目既有的 profile.env 原子 upsert。
#
# 四种状态:
#   (键不存在)  从未部署过 —— 首次部署按"默认启用"处理;
#   1           用户/装机明确启用;
#   0           **用户主动禁用** —— 普通更新与重复安装一律不得开回来;
#   运行态       socket 是否 active 由 systemctl 单独查, 与意图无关(服务崩了意图仍是 1)。
RESCUE_INTENT_KEY="PDG_RESCUE_ENABLED"
RESCUE_BIND_KEY="PDG_RESCUE_BIND"

_rescue_intent(){        # 回显 1 / 0 / 空(从未部署)
  [[ -f "$PROFILE_ENV" ]] || return 0
  sed -n "s/^[[:space:]]*${RESCUE_INTENT_KEY}=//p" "$PROFILE_ENV" | tail -1
}

_rescue_intent_set(){    # $1=1|0。原子写(_profile_set 走临时文件 + mv), 调用方已持锁。
  _profile_set "$RESCUE_INTENT_KEY" "$1"
}

# 兼容 10a-2 早期版本落下的标记文件: 读得到就当作"用户禁用", 并顺手迁进 profile.env。
_rescue_optout(){ echo "${PDG_RESCUE_DIR:-/etc/privdns-gateway/rescue}/disabled"; }
_rescue_intent_migrate(){
  [[ -e "$(_rescue_optout)" ]] || return 0
  [[ -z "$(_rescue_intent)" ]] && _rescue_intent_set 0
  rm -f "$(_rescue_optout)" 2>/dev/null
}

_rescue_socket_present(){ [[ -f "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" ]]; }

# 轮换凭据。**沿用 rescue_cred.py 既定的轮换范围**(token 只换 token, cert 连私钥一起重签),
# 这里只负责把它包成一次可回滚的受控操作: 先留 before-image, 换完验证, 出事按原样放回去。
# 换 token 会让所有已登录会话立即失效; 换证书会改指纹 —— 后者必须明确提示, 否则用户下次访问
# 看到"证书变了"会以为被中间人了。
_rescue_rotate(){
  local what="${1:-token}"
  case "$what" in token|cert) :;; *) echo "用法: pdg rescue rotate [token|cert]"; return 1;; esac
  _lock
  local bak; bak="$(_pdg_mktemp_dir)" || { echo "❌ 无法创建临时目录"; return 1; }
  chmod 700 "$bak"
  # before-image: 三个凭据一起留底 —— 只留被换的那个, 出事时另外两个与它的配对关系就断了
  local f
  for f in "$PDG_RESCUE_TOKEN" "$PDG_RESCUE_CERT" "$PDG_RESCUE_KEY"; do
    [[ -e "$f" ]] && { cp -a "$f" "$bak/$(basename "$f")" || { echo "❌ 备份失败, 未轮换。"
                       rm -rf "$bak"; return 1; }; }
  done
  local fp_old; fp_old="$(python3 /opt/pdg-bot/rescue_cred.py fingerprint 2>/dev/null || true)"
  local rc=0
  if [[ "$what" == token ]]; then
    python3 /opt/pdg-bot/rescue_cred.py rotate-token >/dev/null 2>&1 || rc=1
  else
    python3 /opt/pdg-bot/rescue_cred.py rotate-cert "$(_rescue_bind_addr || true)" >/dev/null 2>&1 || rc=1
  fi
  # 验证: 换完三个文件都得在、权限对、证书读得出指纹
  if (( rc == 0 )); then
    for f in "$PDG_RESCUE_TOKEN" "$PDG_RESCUE_CERT" "$PDG_RESCUE_KEY"; do
      [[ -s "$f" ]] || rc=1
    done
    [[ "$(stat -c %a "$PDG_RESCUE_KEY" 2>/dev/null)" == 600 ]] || rc=1
    [[ "$(stat -c %a "$PDG_RESCUE_TOKEN" 2>/dev/null)" == 600 ]] || rc=1
    python3 /opt/pdg-bot/rescue_cred.py fingerprint >/dev/null 2>&1 || rc=1
  fi
  if (( rc != 0 )); then
    for f in "$PDG_RESCUE_TOKEN" "$PDG_RESCUE_CERT" "$PDG_RESCUE_KEY"; do
      [[ -e "$bak/$(basename "$f")" ]] && cp -a "$bak/$(basename "$f")" "$f"
    done
    rm -rf "$bak"
    echo "❌ 轮换失败, 已恢复原凭据(指纹与 token 均未改变)。"
    return 1
  fi
  rm -rf "$bak"
  # 服务在跑就重启一次, 让新凭据生效并确认它还能起来
  if systemctl is-active "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1; then
    systemctl restart "$PDG_RESCUE_SERVICE_UNIT" >/dev/null 2>&1 || true
  fi
  local fp_new; fp_new="$(python3 /opt/pdg-bot/rescue_cred.py fingerprint 2>/dev/null || true)"
  if [[ "$what" == token ]]; then
    c_g "✅ 救援 Token 已轮换 —— 所有已登录会话立即失效, 请用 pdg rescue status 之外的渠道重新取。"
    [[ "$fp_new" == "$fp_old" ]] && echo "   证书指纹未变(仍是: $fp_new)"
  else
    c_g "✅ 救援证书已重签。"
    c_y "   ⚠️ 指纹已改变: $fp_old → $fp_new"
    c_y "   下次访问浏览器会提示证书变化 —— 那是预期的, 请按新指纹核对。"
  fi
}

cmd_rescue(){
  need_root rescue
  _rescue_load || return 1
  local act="${1:-status}"; shift 2>/dev/null || true
  set -- "$act" "${1:-}"
  case "$act" in
    enable)   _rescue_enable;;
    disable)  _rescue_disable;;
    status)   _rescue_status;;
    fingerprint) python3 /opt/pdg-bot/rescue_cred.py fingerprint;;
    rotate)       _rescue_rotate "${2:-token}";;
    rotate-token) _rescue_rotate token;;
    rotate-cert)  _rescue_rotate cert;;
    bind)         _rescue_set_bind "${2:-}";;
    *) echo "用法: pdg rescue <enable|disable|status|fingerprint|bind <IPv4>|rotate [token|cert]>"
       echo "  fingerprint  打印证书 SHA-256 指纹 —— 这是**独立渠道**, 手机上要拿它核对页面,"
       echo "               反过来用页面上的指纹核对页面没有意义。"
       echo "  rotate token 换 token, 已登录会话立即失效, 证书指纹不变"
       echo "  rotate cert  重签证书, 指纹一定改变, 需要重新核对(见 docs/rescue-plane-access.md)"
       return 1;;
  esac
}

_rescue_enable(){
  _lock
  local bind; bind="$(_rescue_bind_addr || true)"
  if [[ -z "$bind" ]]; then
    # 没配监听地址时先试老路径: 来源段内**恰好一个**本机地址 → 沿用并落盘(老机器平滑迁移)。
    # 有多个就不猜 —— 猜错等于把恢复入口开在错误的那张网上。
    local auto; auto="$(_rescue_bind_from_cidr 2>/dev/null || true)"
    if [[ -n "$auto" ]] && pdg_rescue_bind_valid "$auto"; then
      _profile_set "$RESCUE_BIND_KEY" "$auto" && bind="$auto"
      c_g "  已按来源段内唯一的本机地址确定监听地址: $bind(可用 pdg rescue bind 改)"
    fi
  fi
  if [[ -z "$bind" ]]; then
    echo "❌ 没有配置监听地址(PDG_RESCUE_BIND)—— 拒绝启用。"
    echo "   它与来源段是两件事: 来源段($(pdg_internal_cidr 2>/dev/null || echo 未设))管「谁可以连」,"
    echo "   监听地址管「绑在本机哪个地址上」; 真实网关上后者往往不在前者里。绝不回落 0.0.0.0。"
    echo "   本机可选地址:"; _rescue_bind_candidates | sed 's/^/     /'
    echo "   设置: sudo pdg rescue bind <IPv4>"
    return 1
  fi
  if pdg_rescue_bind_is_global "$bind"; then
    c_y "  ⚠️ 监听地址 $bind 是全局可路由地址 —— 端口会暴露在该地址上, 靠 nft 来源约束与"
    c_y "     应用层来源校验两层兜底。确认这是你要的。"
  fi
  # 回滚台账: 出错时把 unit / 启用状态 / 标记恢复回操作前
  local had_sock=0 was_enabled=0 had_optout=0 had_fw=0
  _rescue_socket_present && had_sock=1
  systemctl is-enabled "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 && was_enabled=1
  [[ -e "$(_rescue_optout)" ]] && had_optout=1
  _rescue_nft_has && had_fw=1        # 操作前就有放行 → 回滚时别把它撤了(重复 enable 的情形)
  _rescue_rollback(){
    (( had_optout == 1 )) && : > "$(_rescue_optout)" || rm -f "$(_rescue_optout)" 2>/dev/null
    (( was_enabled == 0 )) && systemctl disable --now "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1
    (( had_sock == 0 )) && rm -f "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" "$UNIT_DIR/$PDG_RESCUE_SERVICE_UNIT"
    # 放行也要撤 —— 否则回滚完成后盘上留着一条孤儿 accept: 端口开着、后面没有任何监听,
    # 而 status/doctor 读配置会报"防火墙已放行", 与"服务不存在"自相矛盾, 下一个人无从判断
    # 到底哪一半是真的。操作前本来就有放行(重复 enable 的情形)则保持原样, 不误撤。
    (( had_fw == 0 )) && _rescue_nft_close >/dev/null 2>&1
    systemctl daemon-reload 2>/dev/null || true
  }
  # 运行模块得先齐 —— 缺一个的后果不是报错, 是救援页把整块能力标成"旧核心不支持"。
  # 装机由 10a-1 的清单负责, 这里只是在**开门之前**再确认一次。名单读 PDG_RESCUE_CLOSURE
  # (救援平面自身的模块闭包), 不在这里手写第二份。
  local _miss=""
  for _m in $PDG_RESCUE_CLOSURE; do
    [[ -f "/opt/pdg-bot/$_m" ]] || _miss="$_miss $_m"
  done
  if [[ -n "$_miss" ]]; then
    echo "❌ 运行模块不完整(缺:$_miss) —— 拒绝启用。"
    echo "   先跑 sudo pdg update 把模块补齐, 否则救援页开着也是半残的。"
    return 1
  fi
  python3 /opt/pdg-bot/rescue_cred.py ensure "$bind" >/dev/null 2>&1 \
    || { echo "❌ 凭据准备失败, 未改动任何状态。"; return 1; }
  _rescue_write_units "$bind" || { echo "❌ unit 渲染失败, 未启用。"; _rescue_rollback; return 1; }
  systemctl daemon-reload || { echo "❌ daemon-reload 失败"; _rescue_rollback; return 1; }
  _rescue_nft_open || { echo "❌ 防火墙放行失败(候选未通过 nft -c 或应用失败), 已回滚。"
                        _rescue_rollback; return 1; }
  # socket 已经在跑时 `enable --now` **不会**重新读 unit —— 换了监听地址却不重启, systemd
  # 仍绑在旧地址上, 而 nft 只放行新地址: 门就此不可达, 命令还报成功(.200 实机上正是如此)。
  systemctl is-active "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 \
    && systemctl restart "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1
  if ! systemctl enable --now "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1; then
    echo "❌ socket 起不来, 回滚到操作前。"; _rescue_rollback; return 1
  fi
  _rescue_intent_set 1 || { echo "❌ 意图写入失败, 回滚。"; _rescue_rollback; return 1; }
  rm -f "$(_rescue_optout)" 2>/dev/null          # 清掉早期版本的标记文件
  # 收尾一致性核对: 意图 / unit / socket / 监听配置 / 项目 nft 规则必须彼此对得上。
  # 只要有一项对不上就当作没启用成功 —— "看着开了其实没开"比明确失败难查得多。
  local _bad=""
  [[ "$(_rescue_intent)" == 1 ]]                     || _bad="$_bad 意图"
  _rescue_socket_present                             || _bad="$_bad unit"
  systemctl is-enabled "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 || _bad="$_bad socket-enabled"
  grep -q "ListenStream=$bind:$PDG_RESCUE_PORT" "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" 2>/dev/null \
                                                     || _bad="$_bad 监听配置"
  _rescue_nft_has                                    || _bad="$_bad 防火墙"
  if [[ -n "$_bad" ]]; then
    echo "❌ 启用后自检不一致(${_bad# }) → 回滚到操作前。"; _rescue_rollback; return 1
  fi
  c_g "✅ 救援平面已启用: https://$bind:$PDG_RESCUE_PORT/(仅内网卡可达)"
  echo "   证书指纹(首次访问请核对): $(python3 /opt/pdg-bot/rescue_cred.py fingerprint 2>/dev/null || echo '读取失败')"
  c_y "   ⚠️ 这串指纹要拿到**手机上**去比对浏览器里看到的证书 —— 那才是核对的意义所在。"
  c_y "      不要用页面自己显示的指纹核对页面; 浏览器看不到完整 SHA-256 时不要输 token。"
}

_rescue_disable(){
  _lock
  systemctl disable --now "$PDG_RESCUE_SERVICE_UNIT" >/dev/null 2>&1
  systemctl disable --now "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1
  systemctl reset-failed "$PDG_RESCUE_SOCKET_UNIT" "$PDG_RESCUE_SERVICE_UNIT" >/dev/null 2>&1
  _rescue_nft_close || c_y "  防火墙放行没能撤掉, 请 pdg rescue status 复查。"
  _rescue_intent_set 0 || { c_y "  ⚠️ 意图未能写入 profile.env —— 升级时可能被当成「从未部署」而重新开启, 请手工复查。"; }
  rm -f "$(_rescue_optout)" 2>/dev/null          # 早期版本的标记文件不再使用
  # 校验: 停用之后不该还有可用入口
  local _left=""
  systemctl is-active "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 && _left="$_left socket仍active"
  _rescue_nft_has && _left="$_left 防火墙放行仍在"
  if [[ -n "$_left" ]]; then
    c_y "  ⚠️ 停用后仍有残留(${_left# }) —— 请 pdg rescue status 复查, 不要当成已停用。"
    return 1
  fi
  c_g "✅ 救援平面已停用(凭据保留; 再次 pdg rescue enable 即可恢复, 指纹不变)。"
}

# pdg rescue bind <IPv4> —— 设定救援 socket 真正绑的本机地址。
#
# 与来源段是两件事: 来源段管"谁可以连", 这里管"连到哪个地址"。真实网关上后者往往不在前者
# 里面(.200 就是), 所以必须显式配置, 不许从来源段猜。
# 已启用时这是**一笔可回滚的操作**: 渲染新 unit → 生成新候选 → 校验 → 重启 socket → 验证
# 新监听与来源约束, 任一步失败就把 bind / unit / socket / nft 全部退回操作前。
_rescue_set_bind(){
  _lock
  local newbind="${1:-}"
  if [[ -z "$newbind" ]]; then
    echo "用法: pdg rescue bind <IPv4>"
    echo "本机可选地址:"; _rescue_bind_candidates | sed 's/^/  /'
    echo "当前值: $(pdg_rescue_bind 2>/dev/null || echo '(未配置)')"
    return 1
  fi
  if ! pdg_rescue_bind_valid "$newbind"; then
    echo "❌ 不是合法的 IPv4 监听地址: $newbind"
    echo "   只收 IPv4 字面量; 主机名、0.0.0.0、广播与组播一律拒绝 —— 猜错就是把恢复入口开错地方。"
    return 1
  fi
  local old; old="$(pdg_rescue_bind 2>/dev/null || true)"
  if [[ "$old" == "$newbind" ]]; then
    echo "✅ 监听地址已是 $newbind(无变化)"; return 0
  fi
  if ! _rescue_bind_candidates | awk '{print $2}' | grep -qx "$newbind"; then
    c_y "  ⚠️ $newbind 目前不是本机地址 —— FreeBind 允许先绑上, 但地址不回来就没人连得进来。"
  fi
  pdg_rescue_bind_is_global "$newbind" && c_y "  ⚠️ $newbind 是全局可路由地址: 端口会暴露在该地址上, 只靠 nft 来源约束与应用层来源校验兜底。"

  local was_enabled=0
  systemctl is-enabled "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 && was_enabled=1
  _profile_set "$RESCUE_BIND_KEY" "$newbind" || { echo "❌ 写入 profile.env 失败"; return 1; }

  if (( was_enabled == 0 )); then
    # 停用状态: 只更新配置与候选 unit, **不开端口**
    _rescue_write_units "$newbind" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo "✅ 监听地址已设为 $newbind(当前处于停用状态, 未开放端口; pdg rescue enable 生效)"
    return 0
  fi
  # 启用状态: 整体重做一次, 失败退回
  if _rescue_enable >/dev/null 2>&1 && [[ "$(_rescue_listen_addr)" == "$newbind:$PDG_RESCUE_PORT" ]]; then
    echo "✅ 监听地址已切到 $newbind, socket 正在该地址上监听。"
    return 0
  fi
  c_y "❌ 切换到 $newbind 失败, 回退到 ${old:-未配置}。"
  # 回退不只是把 profile 写回去: 失败之前 unit 与 nft 规则已经指向新地址了, 光改配置会留下
  # 一个"配置说 A、防火墙放行 B、socket 监听 B"的三方不一致 —— 而且 B 是个起不来的地址,
  # 等于把入口悄悄关掉。所以 unit 与防火墙都要按旧值重做一遍。
  if [[ -n "$old" ]]; then
    _profile_set "$RESCUE_BIND_KEY" "$old"
    _rescue_write_units "$old" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    _rescue_nft_close >/dev/null 2>&1 || true      # 先撤掉指向新地址的那条
    _rescue_nft_open  >/dev/null 2>&1 \
      || c_y "  ⚠️ 防火墙未能退回旧地址, 请跑 sudo pdg rescue status 复查。"
  else
    # 本来就没配过 → 把键抹掉(而不是留一个空值: 空值会被 pdg_rescue_bind 当成"配了"而后
    # 在校验处再失败一次, 报错位置离真正原因更远)
    sed -i "/^${RESCUE_BIND_KEY}=/d" "$PROFILE_ENV" 2>/dev/null || true
  fi
  _rescue_enable >/dev/null 2>&1 || true
  return 1
}

# 盘上的 unit 与当前模板渲染结果不一致时重写(内容相同则一个字节都不动)。
# 返回 0 = 有更新并已重启 socket; 1 = 无需更新/不适用。
_rescue_refresh_units(){
  local bind="${1:-}"; [[ -n "$bind" ]] || return 1
  _rescue_socket_present || return 1                 # 没装过就不是"刷新"的事
  local tmp; tmp="$(_pdg_mktemp_dir)" || return 1
  local dst="$UNIT_DIR" changed=0 u
  UNIT_DIR="$tmp" _rescue_write_units "$bind" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  for u in "$PDG_RESCUE_SOCKET_UNIT" "$PDG_RESCUE_SERVICE_UNIT"; do
    if ! cmp -s "$tmp/$u" "$dst/$u" 2>/dev/null; then
      cp -f "$tmp/$u" "$dst/$u" && changed=1
    fi
  done
  rm -rf "$tmp"
  (( changed == 1 )) || return 1
  c_g "  救援 unit 已按新模板刷新(硬化项/停止期限等修复会在这里落到已装机器上)"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl is-active "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1 \
    && systemctl restart "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1
  return 0
}

# **真实**在监听的地址(不是 unit 文件里写的那个)。核对切换是否生效必须看这个 ——
# 看文件只能证明"我们写对了", 证明不了"systemd 照做了"。
_rescue_listen_addr(){
  local a; a="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep ":$PDG_RESCUE_PORT\$" | head -1)"
  [[ -n "$a" ]] && { printf '%s' "$a"; return 0; }
  sed -n 's/^ListenStream=//p' "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" 2>/dev/null | tail -1   # 没有 ss 时的兜底
}

_rescue_status(){
  local bind sock svc fp
  bind="$(_rescue_bind_addr || true)"
  sock="$(systemctl is-active "$PDG_RESCUE_SOCKET_UNIT" 2>/dev/null || true)"
  svc="$(systemctl is-active "$PDG_RESCUE_SERVICE_UNIT" 2>/dev/null || true)"
  echo "== 救援平面 =="
  local intent; intent="$(_rescue_intent)"
  case "$intent" in
    1) printf "  %-14s %s\n" "用户意图" "enabled";;
    0) printf "  %-14s %s\n" "用户意图" "disabled(主动停用; 升级不会开回来)";;
    *) printf "  %-14s %s\n" "用户意图" "未记录(从未部署过 —— 下次 pdg update 会按默认启用)";;
  esac
  printf "  %-14s %s\n" "socket unit"  "$(_rescue_socket_present && echo 已安装 || echo 缺失)"
  # is-enabled 失败时**自己也会打印** "disabled", 再 `|| echo disabled` 就成了两行 ——
  # 命令替换把换行原样带进 printf, status 里凭空多出一行孤零零的 disabled。
  local sock_en; sock_en="$(systemctl is-enabled "$PDG_RESCUE_SOCKET_UNIT" 2>/dev/null | head -1)"
  printf "  %-14s %s\n" "socket 状态"  "${sock:-unknown} / ${sock_en:-disabled}"
  # socket activation(Accept=no)下 service 平时就是 inactive: socket 在监听, 有请求才拉起
  # 它。把这种正常状态显示成"服务未运行", 会让人以为救援平面坏了而去反复重启 —— 真正该
  # 报的是 failed(起过并且失败了), 那和"闲着"完全是两回事, 必须分开说。
  case "$svc" in
    active)   printf "  %-14s %s\n" "service 状态" "active(正在服务请求)";;
    failed)   printf "  %-14s %s\n" "service 状态" "❌ failed(上次拉起失败 —— 需要处理; journalctl -u $PDG_RESCUE_SERVICE_UNIT 看原因)";;
    ""|inactive) printf "  %-14s %s\n" "service 状态" "inactive(正常: 待按需拉起, socket 收到连接才启动)";;
    *)        printf "  %-14s %s\n" "service 状态" "$svc";;
  esac
  local cidr_now; cidr_now="$(pdg_internal_cidr 2>/dev/null || echo '(未设)')"
  printf "  %-14s %s\n" "来源段"       "$cidr_now(允许连进来的客户端网段)"
  if [[ -n "$bind" ]]; then
    printf "  %-14s %s\n" "监听地址"   "$bind → https://$bind:$PDG_RESCUE_PORT/"
    if _rescue_bind_candidates | awk '{print $2}' | grep -qx "$bind"; then
      printf "  %-14s %s\n" "地址在本机" "是"
    else
      printf "  %-14s %s\n" "地址在本机" "⚠️ 否(FreeBind 能绑上, 但地址不回来就没人连得进)"
    fi
    if pdg_rescue_bind_is_global "$bind"; then
      printf "  %-14s %s\n" "地址属性"  "⚠️ 全局可路由 —— 端口暴露在该地址上, 靠 nft 来源约束 + 应用层来源校验两层兜底"
    else
      printf "  %-14s %s\n" "地址属性"  "私网/本地(不在公网上)"
    fi
    printf "  %-14s %s\n" "socket 监听" "$(ss -ltn 2>/dev/null | grep -q "$bind:$PDG_RESCUE_PORT" && echo "在 $bind:$PDG_RESCUE_PORT 上" || echo 无)"
  else
    printf "  %-14s %s\n" "监听地址"   "（未配置 —— 不能启用; sudo pdg rescue bind <IPv4>）"
  fi
  printf "  %-14s %s\n" "nft 磁盘规则" "$(_rescue_nft_count_disk 2>/dev/null || printf ?) 条(带 pdg-rescue 标记)"
  printf "  %-14s %s\n" "nft 内核规则" "$(_rescue_nft_count_kernel 2>/dev/null || printf ?) 条"
  printf "  %-14s %s\n" "应用层来源校验" "已启用(只认内核给的 peer 地址, 不看 X-Forwarded-For)"
  if nft list tables 2>/dev/null | grep -q "inet pdgrescue" \
     || grep -q "table inet pdgrescue" /etc/nftables.conf 2>/dev/null; then
    printf "  %-14s %s\n" "遗留独立表"  "⚠️ 检出 inet pdgrescue —— 旧设计残留, 会被 doctor 判冲突; 跑一次 pdg rescue enable/disable 清掉"
  else
    printf "  %-14s %s\n" "遗留独立表"  "无"
  fi
  # 凭据只报"齐不齐"与指纹, **绝不打印 token 或私钥**
  for f in "$PDG_RESCUE_TOKEN" "$PDG_RESCUE_CERT" "$PDG_RESCUE_KEY"; do
    printf "  %-14s %s\n" "$(basename "$f")" "$([[ -s "$f" ]] && echo "在($(stat -c %a "$f" 2>/dev/null))" || echo 缺失)"
  done
  fp="$(python3 /opt/pdg-bot/rescue_cred.py fingerprint 2>/dev/null || true)"
  printf "  %-14s %s\n" "证书指纹" "${fp:-读取失败}"
  printf "  %-14s %s\n" "指纹核对" "把上面这串带到手机上比对浏览器里的证书详情(见 docs/rescue-plane-access.md)"
  # 渲染出来的监听地址与当前内网段是否还对得上 —— detect-cidr 换过段之后它会过期
  local cidr rendered
  cidr="$(pdg_internal_cidr 2>/dev/null || true)"
  rendered="$(sed -n 's/^ListenStream=//p' "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" 2>/dev/null | tail -1)"
  printf "  %-14s %s\n" "渲染监听" "${rendered:-（unit 未安装）}"
  if [[ -n "$rendered" && -n "$bind" ]]; then
    [[ "$rendered" == "$bind:$PDG_RESCUE_PORT" ]] \
      && printf "  %-14s %s\n" "地址一致性" "与当前内网段($cidr)一致" \
      || printf "  %-14s %s\n" "地址一致性" "⚠️ 与当前内网段($cidr)不一致, 建议重跑 pdg rescue enable"
  fi
  if grep -qE 'ListenStream=(0\.0\.0\.0|\[?::\]?):' "$UNIT_DIR/$PDG_RESCUE_SOCKET_UNIT" 2>/dev/null; then
    printf "  %-14s %s\n" "通配监听" "⚠️ 检出通配地址 —— 这是严重问题, 请立刻 pdg rescue disable"
  else
    printf "  %-14s %s\n" "通配监听" "无(只绑内网地址)"
  fi
  # 运行模块是否完整: 缺一个救援页就会有整块能力标成"旧核心不支持"
  local _miss_mods=""
  for f in $PDG_RESCUE_CLOSURE; do
    [[ -f "/opt/pdg-bot/$f" ]] || _miss_mods="$_miss_mods $f"
  done
  printf "  %-14s %s\n" "运行模块" "$([[ -z "$_miss_mods" ]] && echo 完整 || echo "缺:$_miss_mods")"
  return 0
}

cmd_platform(){
  need_root platform
  local p="${1:-}" cur; cur="$(_pdg_platform)"
  if [[ "$p" != ios && "$p" != android ]]; then
    echo "用法: pdg platform <ios|android>"
    echo "  当前: $cur$( [[ -e /etc/privdns-gateway/platform.guessed ]] && echo "  ⚠️ 推测值, 未确认" )"
    echo "  确认后才会执行该平台的组件部署/清理(推测状态下一律不做破坏性清理)。"
    return 1
  fi
  _lock
  c_g "切换平台: $cur → $p"
  # 1) 先留快照。拿不到就别开始 —— 后面要改 nft、删/装 unit、重渲内核, 没有回退手段不能动手。
  cmd_snapshot --source cli --op platform >/dev/null 2>&1 || { echo "❌ 快照失败 → 中止切换(未改动任何东西)"; return 1; }
  # 2) 就地备份直接会被改写的几样(快照是整体回退, 这些用于精确还原)
  local wd; wd="$(mktemp -d)" || { echo "❌ 无法创建临时目录"; return 1; }
  local f
  for f in /etc/privdns-gateway/platform /etc/privdns-gateway/profile.env \
           /etc/privdns-gateway/mitm.json /etc/nftables.conf /etc/mihomo/config.yaml \
           /etc/mosdns/rules/mitm_hijack.txt; do
    [[ -e "$f" ]] && cp -a "$f" "$wd/$(basename "$f")" 2>/dev/null
  done
  # 2b) 平台专属文件也要能原样回去: 装上去的要删掉, 清掉的要放回来。
  # 只还原配置不管这些文件的话, 一次失败的 Android→iOS 会在盘上留下 probe81/描述文件模板/
  # MITM 模块和两个 unit —— 平台明明已经回滚成 android, 现场却是半个 iOS。
  # 备份**内容**而不只是记在不在: 文件本来就有(版本旧一点)时, install 会把它改写掉。
  local _PLAT_FILES=(
    /opt/pdg-bot/probe81.py
    /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
    /opt/pdg-bot/iosprofile.py
    /opt/pdg-bot/iosstate.py
    /opt/pdg-bot/mitm_ca.py
    /opt/pdg-bot/mitm_server.py
    /opt/pdg-bot/mitm_wloc.py
    /etc/systemd/system/pdg-probe81.service
    /etc/systemd/system/pdg-mitm.service
  )
  mkdir -p "$wd/plat"
  local _pf _key
  for _pf in "${_PLAT_FILES[@]}"; do
    _key="${_pf//\//_}"
    [[ -e "$_pf" ]] && cp -a "$_pf" "$wd/plat/$_key" 2>/dev/null
  done
  # 服务的启用/运行状态同样记下来(回滚后不能留下一个"unit 已删但还标着 enabled"的现场)
  # 只取第一行并在空值时兜底: systemctl 这些子命令是"既打印状态又用退出码表态", 拿
  # `cmd || echo disabled` 兜底会打印两遍, 多出来的那行会被下面的 read 当成新记录读走。
  local _psvc _pstate _pen _pac; _pstate=""
  for _psvc in pdg-probe81 pdg-mitm; do
    _pen="$(systemctl is-enabled "$_psvc" 2>/dev/null | head -1)"
    _pac="$(systemctl is-active  "$_psvc" 2>/dev/null | head -1)"
    _pstate="$_pstate$_psvc|${_pen:-disabled}|${_pac:-inactive}"$'\n'
  done
  _plat_rollback(){
    local g
    for g in platform profile.env mitm.json nftables.conf config.yaml mitm_hijack.txt; do
      case "$g" in
        platform|profile.env|mitm.json) [[ -e "$wd/$g" ]] && cp -a "$wd/$g" "/etc/privdns-gateway/$g";;
        nftables.conf) [[ -e "$wd/$g" ]] && { cp -a "$wd/$g" /etc/nftables.conf; nft -f /etc/nftables.conf 2>/dev/null || true; };;
        config.yaml)   [[ -e "$wd/$g" ]] && cp -a "$wd/$g" /etc/mihomo/config.yaml;;
        mitm_hijack.txt) [[ -e "$wd/$g" ]] && cp -a "$wd/$g" /etc/mosdns/rules/mitm_hijack.txt;;
      esac
    done
    # 平台专属文件: 有备份的放回去, 本来不存在的删掉(这次新装的)
    local pf key
    for pf in "${_PLAT_FILES[@]}"; do
      key="${pf//\//_}"
      if [[ -e "$wd/plat/$key" ]]; then
        install -d "$(dirname "$pf")" 2>/dev/null || true
        cp -a "$wd/plat/$key" "$pf" 2>/dev/null || true
      else
        rm -f "$pf" 2>/dev/null || true
      fi
    done
    systemctl daemon-reload 2>/dev/null || true
    # 服务状态回到切换前: unit 已经不在了就只停不启
    local svc en ac
    while IFS='|' read -r svc en ac; do
      [[ -n "$svc" ]] || continue
      if [[ -e "/etc/systemd/system/$svc.service" ]] && [[ "$en" == enabled || "$ac" == active ]]; then
        systemctl reset-failed "$svc" >/dev/null 2>&1 || true
        if [[ "$ac" == active ]]; then
          systemctl enable --now "$svc" >/dev/null 2>&1 || true
        else
          systemctl enable "$svc" >/dev/null 2>&1 || true      # 切换前就是"开机启动但没在跑"
        fi
      else
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
      fi
    done <<< "$_pstate"
    _plat_write_profile "$cur" >/dev/null 2>&1 || true
    systemctl restart "$(_pdg_core_svc)" mosdns >/dev/null 2>&1 || true
    c_y "已恢复到原平台 $cur 与原配置(含平台专属文件与服务状态; 快照仍在, 必要时可 sudo pdg rollback)。"
  }
  # 3) 落平台标记(platform 文件 + profile.env 同步)
  install -d -m700 /etc/privdns-gateway
  printf '%s\n' "$p" > /etc/privdns-gateway/platform || { _plat_rollback; rm -rf "$wd"; return 1; }
  rm -f /etc/privdns-gateway/platform.guessed
  _plat_write_profile "$p" || { c_y "profile.env 写入失败"; _plat_rollback; rm -rf "$wd"; return 1; }

  # 4) 按目标平台部署 / 清理组件
  if [[ "$p" == ios ]]; then
    if ! _plat_deploy_ios; then
      echo "❌ iOS 组件部署失败(probe81 / 描述文件模板 / pdg-probe81 服务)"
      _plat_rollback; rm -rf "$wd"; return 1
    fi
  else
    migrate_android_cleanup                     # 安全休眠 WLOC + 移除 iOS unit/模块/模板(保留地点与 CA)
  fi

  # 5) 防火墙按目标平台重建(Android 有 GMS 5228-5230, iOS 没有)。与迁移同一实现: 渲染 → 合并
  #    (用户其它表逐字节保留)→ nft -c → 应用, 任一步失败它自己会把现网还原。
  if ! _switchcore_nft mihomo; then
    echo "❌ 防火墙按新平台重建失败"
    _plat_rollback; rm -rf "$wd"; return 1
  fi

  # 6) 重渲内核配置: iOS→Android 要把 MITM-OUT 出站/路由去掉(接管域名已空), 反向则补上
  if ! ( cd /opt/pdg-bot && python3 -c 'import bot; bot._render_mihomo_file()' ) >/dev/null 2>&1; then
    echo "❌ 重新渲染 mihomo 配置失败"
    _plat_rollback; rm -rf "$wd"; return 1
  fi
  if command -v mihomo >/dev/null 2>&1 && ! mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1; then
    echo "❌ 新平台的 mihomo 配置校验(mihomo -t)未过"
    _plat_rollback; rm -rf "$wd"; return 1
  fi
  systemctl restart "$(_pdg_core_svc)" >/dev/null 2>&1 || true
  systemctl restart mosdns >/dev/null 2>&1 || true

  # 7) 校验: nft 配置、核心服务、平台必需服务
  # nft 的位置与扫描器同一份判据(_pdg_nft_bin): `command -v nft` 只看 PATH, 而 nft 装在
  # /usr/sbin —— PATH 里没有 sbin 时这条校验会被整条跳过, 等于不校验就放行。
  local _nftexe; _nftexe="$(_pdg_nft_bin)"
  if [[ -n "$_nftexe" ]] && ! "$_nftexe" -c -f /etc/nftables.conf >/dev/null 2>&1; then
    echo "❌ 切换后的 nftables 配置校验未过"
    _plat_rollback; rm -rf "$wd"; return 1
  fi
  if [[ "$(_pdg_bot_cred)" == partial ]]; then
    echo "❌ Bot 凭据只配了一项(token 与允许 id 必须成对)—— 这是配置错误, 先用 pdg-set-token"
    echo "   补齐或把两项都留空(彻底禁用 bot), 再切平台。"
    _plat_rollback; rm -rf "$wd"; return 1
  fi
  local svc bad=()
  # 必需服务集按凭据状态算: 没配 bot 的机器不该因为 pdg-bot 没跑而切不了平台
  for svc in $(_pdg_required_svcs); do
    _core_kernel_stable "$svc" || bad+=("$svc")
  done
  if [[ ${#bad[@]} -gt 0 ]]; then
    echo "❌ 切换后这些服务未稳定运行: ${bad[*]}"
    _plat_rollback; rm -rf "$wd"; return 1
  fi
  # 8) 返回 0 之前复核现场: 目标平台该有的都在、该没有的都清干净了
  if ! _plat_verify "$p"; then
    _plat_rollback; rm -rf "$wd"; return 1
  fi
  # 关键迁移必须在**删掉回滚材料、宣布成功之前**跑完: 它失败就走 _plat_rollback,
  # 而 _plat_rollback 依赖 $wd 里的材料 —— 顺序颠倒的话就只能 best-effort 了。
  if ! migrate_ios_gms_cleanup; then
    echo "❌ iOS GMS 残留清理失败(详见上方), 平台切换回退"
    _plat_rollback; rm -rf "$wd"; return 1
  fi
  rm -rf "$wd"
  run_all_migrations || true                    # 其余平台无关的幂等迁移照常跑(GMS 那步已单独跑过)
  c_g "平台已确认: $cur → $p"
  if [[ -x /opt/pdg-bot/doctor.py ]] || [[ -f /opt/pdg-bot/doctor.py ]]; then
    python3 /opt/pdg-bot/doctor.py || c_y "自检有未通过项(见上), 平台切换本身已完成。"
  fi
  return 0
}

# SIM/APN 链路诊断。6.1A 只有 `status` 一个子命令: **服务器准备状态**, 纯只读。
#
# 它不取全局配置写锁, 也不开事务 —— 这是有意的。这条命令是给"出事了想看看"的人用的,
# 它自己再去抢锁就会在最不该添乱的时候添乱: 读一次状态却挡住 pdg update 或定时的规则库
# 刷新, 代价远大于收益。cmd_detect_cidr 那种要写配置的才需要锁。
#
# 退出码由 linkstat.exit_code() 定: 服务器准备状态里有 FAIL → 2; 只有 WARN/NOT_OBSERVED/
# SKIP → 0; 模型损坏或没跑完 → 3。NOT_OBSERVED **不算故障**, 所以不影响退出码。
cmd_link(){
  local sub="${1:-status}"
  case "$sub" in
    status) shift || true;;
    -h|--help|help)
      echo "用法: pdg link status [--json]"
      echo "  只报告**服务器准备状态**(只读, 不改任何东西)。"
      echo "  手机/SIM 那条链路本轮还观测不到, 会明确显示为「未观察到」。"
      return 0;;
    *) echo "用法: pdg link status [--json]"; return 1;;
  esac
  local m; m="$(_pdg_module linkstat.py)" || { echo "❌ 找不到 linkstat.py"; return 1; }
  python3 "$m" "$@"
}

cmd_hijack_mode(){
  need_root hijack-mode
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/mosdns.sh" 2>/dev/null || { echo "❌ 读不到 lib/mosdns.sh"; return 1; }
  local mode="${1:-}" file
  if [[ "$mode" != all && "$mode" != gfw ]]; then
    echo "用法: pdg hijack-mode <all|gfw>"
    echo "  all = 不是国内域名就劫持进代理(默认, 排除式)"
    echo "  gfw = 只劫持 hijack_set 里的域名(GFWList + 你在 bot 里指到出口的域名);"
    echo "        其余海外域名返真实 IP 直连(修 SSH/直连走域名被劫持)。前提: 内网卡 SIM 能直达一般互联网"
    echo "  当前: $(cat /etc/privdns-gateway/profile.env 2>/dev/null | sed -n 's/^PDG_HIJACK_MODE=//p' | tail -1 || echo '?')"
    return 1
  fi
  [[ -f /etc/mosdns/config.yaml ]] || { echo "❌ 找不到 /etc/mosdns/config.yaml"; return 1; }
  if [[ "$mode" == gfw ]]; then
    file="geosite_gfw.txt"
    if [[ ! -s /etc/mosdns/rules/geosite_gfw.txt ]]; then
      c_g "生成 GFWList(geosite_gfw.txt)…"; bash /opt/pdg-bot/update-rules.sh >/dev/null 2>&1 || true
    fi
    [[ -s /etc/mosdns/rules/geosite_gfw.txt ]] || { echo "❌ geosite_gfw.txt 生成失败, 仍为原模式"; return 1; }
  else
    file="geosite_geolocation-!cn.txt"
  fi
  _pdg_hijack_transact "$mode" "$file"
}

# 劫持模式的两个目标 —— mosdns 配置与真源 profile.env —— 整笔走配置事务。
#
# 以前是就地改写 + `.hjbak` 局部还原 + `sed -i` 写 profile.env。三个毛病:
#   · 不上任何锁: `pdg snapshot` 在锁被占用时会被拦下, 这条却照写不误 —— 而 bot 与
#     pdg-rules-update.timer 都会对 mosdns_conf 开事务, 撞上就是两边互相盖;
#   · 不留事务记录: 没有 before-image、没有审计、事后 recover 不到;
#   · mosdns 与 profile.env 各写各的: mosdns 成了而 profile 没成时, 盘上的形态与真源
#     记录从此对不上, 而下一次迁移会按那个错的真源再归一一次。
#
# 锁的用法有个坑: 这里**不能**调 pdg.sh 的 `_lock`。它与事务核心那把是同一个文件, shell
# 先 flock 住, 子进程 python 再去 flock 同一个文件必然拿不到 → 每次都 TxBusy。
# cmd_detect_cidr 同样只靠事务核心那把锁, 这里照它。
_pdg_hijack_transact(){
  local mode="$1" file="$2" txm txid rc=0 wd shape
  txm="$(_pdg_module pdgtx.py)" || { c_y "❌ 找不到 pdgtx.py(事务核心缺失), 未改动任何文件。"; return 1; }
  local pend; pend="$(python3 "$txm" pending 2>/dev/null)"
  if [[ -n "$pend" ]]; then
    c_y "⛔ 有未完成的配置事务, 本次拒绝执行(未改动任何文件):"
    printf '%s\n' "$pend" | sed 's/^/    /'
    c_y "   请先 sudo pdg tx show <id> 查看, 再 sudo pdg tx recover <id> 收尾。"
    return 1
  fi
  wd="$(mktemp -d)" || { c_y "❌ 无法创建临时目录"; return 1; }

  # ── 候选一: mosdns。在**临时副本**上跑归一化器, 绝不碰生产路径。 ──
  python3 "$txm" read --target mosdns_conf > "$wd/mos.raw" 2>"$wd/err" || {
    c_y "❌ 读不到 mosdns 配置: $(tr -d '\n' < "$wd/err") → 未改动任何文件。"; rm -rf "$wd"; return 1; }
  local mos_sha; mos_sha="$(head -1 "$wd/mos.raw")"
  tail -n +2 "$wd/mos.raw" > "$wd/mos.new"
  if ! shape=$(_mosdns_hijack_shape "$mode" "$wd/mos.new" "$file"); then
    c_y "mosdns 配置是自定义形态, 未改动(不猜着改)。"; rm -rf "$wd"; return 1
  fi

  # ── 候选二: profile.env。在子 shell 里把 PROFILE_ENV 指到临时副本, 复用 _profile_set。 ──
  python3 "$txm" read --target profile_env > "$wd/prof.raw" 2>"$wd/err" || {
    c_y "❌ 读不到 profile.env: $(tr -d '\n' < "$wd/err") → 未改动任何文件。"; rm -rf "$wd"; return 1; }
  local prof_sha; prof_sha="$(head -1 "$wd/prof.raw")"
  tail -n +2 "$wd/prof.raw" > "$wd/prof.cur"
  cp "$wd/prof.cur" "$wd/prof.new"
  ( PROFILE_ENV="$wd/prof.new"; _profile_set PDG_HIJACK_MODE "$mode" ) || {
    c_y "❌ 生成 profile.env 候选失败 → 未改动任何文件。"; rm -rf "$wd"; return 1; }

  # ── 幂等: 两个候选都与现网一致就什么都不做。不开事务 —— 开了就会留下 PREPARING。 ──
  local mos_changed=0 prof_changed=0
  [[ "$shape" == changed ]] && mos_changed=1
  cmp -s "$wd/prof.cur" "$wd/prof.new" || prof_changed=1
  if [[ "$mos_changed" == 0 && "$prof_changed" == 0 ]]; then
    echo "  (配置已是 $mode 形态, 无需改动)"
    c_g "✅ 劫持模式 → $mode(无变化)"; rm -rf "$wd"; return 0
  fi

  txid="$(python3 "$txm" new --source cli --op hijack-mode 2>"$wd/err")" || {
    c_y "❌ 无法开始配置事务: $(tr -d '\n' < "$wd/err")"; rm -rf "$wd"; return 1; }
  # expect 用 read 时拿到的 sha: 生成候选期间有人改了同一个文件, 落盘阶段会当场撞出来,
  # 而不是把别人的修改静默盖掉。"-" = 读的时候它就不存在。
  local t
  for t in "mosdns_conf:$wd/mos.new:$mos_sha" "profile_env:$wd/prof.new:$prof_sha"; do
    # 分成四条 local: 同一条 `local a=… b=$a` 里后者取不到前者的值(bash 语义), 在 set -u
    # 下会直接炸成 unbound variable, 把整个 stage 循环打断。
    local tgt; tgt="${t%%:*}"
    local rest; rest="${t#*:}"
    local cand; cand="${rest%%:*}"
    local exp; exp="${rest#*:}"
    python3 "$txm" stage --tx "$txid" --target "$tgt" --file "$cand" --expect "$exp" 2>"$wd/err" || {
      c_y "❌ 暂存候选失败($tgt): $(tr -d '\n' < "$wd/err") → 未改动任何文件。"; rc=1; break; }
  done
  if [[ "$rc" != 0 ]]; then
    python3 "$txm" abort "$txid" >/dev/null 2>&1 || true   # 候选阶段放弃: 现网一字节没动
    rm -rf "$wd"; return 1
  fi
  # 只有 mosdns 真的变了才重启它 —— 光改真源记录不该顺手打断 DNS。
  [[ "$mos_changed" == 1 ]] && python3 "$txm" service --tx "$txid" --action restart:mosdns >/dev/null 2>&1
  local out
  out="$(python3 "$txm" apply --tx "$txid" 2>"$wd/err")"; rc=$?
  if [[ "$rc" == 0 ]]; then
    [[ "$mos_changed" == 1 ]] || echo "  (mosdns 形态已是 $mode, 本次只更新真源记录)"
    c_g "✅ 劫持模式 → $mode(mosdns 与真源同一笔事务落盘)"
    rm -rf "$wd"; return 0
  fi
  # 失败后顺手收掉这笔事务。abort 自己守着门: 只接受 PREPARING/VALIDATED(现网还没被碰过),
  # 已经动过现网的状态它会拒绝并保留原状 —— 所以这里无条件调是安全的, 既不会把
  # ROLLED_BACK/ROLLBACK_FAILED 抹成 ABORTED, 也不会让"被拒绝"的尝试堆一地 PREPARING。
  python3 "$txm" abort "$txid" >/dev/null 2>&1 || true
  case "$rc" in
    4) c_y "⛔ 已有配置操作在执行(锁被占用), 本次未改动任何文件。";;
    5) c_y "⛔ 拒绝执行(未改动任何文件):"
       [[ -s "$wd/err" ]] && sed 's/^/    /' "$wd/err";;
    *) c_y "❌ 劫持模式切换失败, 已按 before-image 回滚:"
       [[ -s "$wd/err" ]] && sed 's/^/    /' "$wd/err"
       [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /'
       c_y "   如显示回滚不完整(ROLLBACK_FAILED), 用 sudo pdg tx show $txid 查看后再 recover。";;
  esac
  rm -rf "$wd"; return 1
}

# 显式迁移: 先上锁、先快照, 再跑幂等迁移, 并记一笔审计(source=cli, op=migrate)。
# 边界说明(不夸大): 迁移内部仍是各自的就地改写 + 局部还原, 尚未逐文件走事务核心的
# before-image —— 那属于 5.1B。这里保证的是"迁移前一定有可回滚的快照, 且不会在用户
# 不知情时发生", 失败时明确指出用哪一份快照回退。
cmd_migrate(){
  need_root migrate; _lock
  c_g "迁移前留快照…"
  if ! cmd_snapshot --source cli --op migrate >/dev/null 2>&1 || [[ -z "$_PDG_SNAP_CREATED" ]]; then
    c_y "❌ 快照失败, 拒绝在无法回滚的前提下迁移。"; return 1
  fi
  local snap="$_PDG_SNAP_CREATED" rc=0
  run_all_migrations || rc=$?
  if [[ $rc == 0 ]]; then
    _tx_audit cli migrate COMMITTED "snapshot=$snap"
    c_g "✅ 迁移完成(快照: $snap)"
    return 0
  fi
  _tx_audit cli migrate ROLLBACK_FAILED "snapshot=$snap"
  c_y "❌ 迁移失败。快照仍在: $snap"
  c_y "   需要回退时: sudo pdg rollback --dir $snap"
  return 1
}

# 往事务审计里补一条记录 —— CLI 侧那些尚未逐文件事务化的操作, 至少要记在同一本账上。
_tx_audit(){
  local m
  for m in "$REPO_DIR/deploy/bot/pdgtx.py" /opt/pdg-bot/pdgtx.py; do
    [[ -f "$m" ]] || continue
    python3 - "$m" "$1" "$2" "$3" "${4:-}" <<'TXAUDIT' 2>/dev/null || true
import importlib.util, json, os, sys, time
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
tx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tx)
rec = {"ts": time.time(), "txid": tx.new_txid(), "source": sys.argv[2], "op": sys.argv[3],
       "mode": "normal", "state": sys.argv[4], "targets": [], "services": [], "error": "",
       "note": tx.redact(sys.argv[5]), "schema_version": tx.SCHEMA_VERSION}
try:
    os.makedirs(os.path.dirname(tx.AUDIT), mode=0o700, exist_ok=True)
    with open(tx.AUDIT, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
except OSError:
    pass
TXAUDIT
    return 0
  done
}

# pdg tx: 查看/恢复事务。list/show 是只读的(不取写锁); recover 自己在核心里取同一把锁。
cmd_tx(){
  need_root tx
  local m
  for m in "$REPO_DIR/deploy/bot/pdgtx.py" /opt/pdg-bot/pdgtx.py; do
    [[ -f "$m" ]] && { python3 "$m" "$@"; return $?; }
  done
  echo "❌ 找不到 pdgtx.py(事务核心缺失)"; return 1
}

# 5.1: **取消命令分派前的隐藏迁移**。
# 以前这里对所有管理类命令(含 update)先跑一遍 run_all_migrations —— 那发生在 _lock 之前、
# 也在 cmd_update 打快照之前: 迁移会改 unit / nft / mosdns, 于是"更新失败回滚"只能回到
# **已经被迁移改过**的现网, 而用户以为回到了操作前。菜单、restart 这类命令更不该在用户
# 不知情时改配置。
# 现在迁移只有两个入口, 都在锁与快照之后: cmd_update 装好新脚本后调用的 `pdg __migrate`,
# 以及用户显式运行的 `sudo pdg migrate`(先上锁、先快照, 并记一笔审计)。

# 收参数的分支一律 `shift || true` + "$@" —— 只传第一个参数会把后面的全丢掉, 而且丢得**没有
# 报错**。这个坑踩过两次: `pdg rescue bind 1.2.3.4` 拿不到地址、`pdg rescue rotate cert` 退化成
# 默认的 token 轮换(用户要求换证书, 实际换掉的是 token: 会话全断、指纹没变); 后来又是
# `pdg rollback --dir <快照目录> --git <ref>` 只递进去一个 `--dir`, 报"--dir 缺参数",
# 而 cmd_update 走内部直调不过这里, 所以内部路径一直是好的、故障只出现在用户手打的那条命令上。
# 默认值(rollback 的序号 0、log 的 40 行)由各自的函数兜底, 不在这里替它们塞 ——
# 分发器一塞, "有没有给参数"这件事在函数里就再也分辨不出来了。
# tests/test-cli-dispatch.py 把这段 case 抽出来逐条跑, 不是靠这条注释守着。
case "${1:-menu}" in
  menu|"")       menu;;
  __migrate)     need_root __migrate; run_all_migrations;;   # 内部: cmd_update 装好新脚本后据此跑"新版"迁移
  migrate)       cmd_migrate;;
  tx)            shift || true; cmd_tx "$@";;
  status|st)     cmd_status;;
  doctor|dr)     shift || true; cmd_doctor "$@";;
  update|up)     shift || true; cmd_update "$@";;
  migrate-fw)    need_root migrate-fw; migrate_firewall_to_pdg;;
  snapshot|snap) shift || true; cmd_snapshot "$@";;
  rollback)      shift || true; cmd_rollback "$@";;
  token)         cmd_token;;
  restart)       cmd_restart;;
  log|logs)      shift || true; cmd_log "$@";;
  traffic|tr)    cmd_traffic;;
  ios)           shift || true; cmd_ios "$@";;
  report)        shift || true; cmd_report "$@";;
  detect-cidr|cidr) shift || true; cmd_detect_cidr "$@";;
  platform)      shift || true; cmd_platform "$@";;
  hijack-mode)   shift || true; cmd_hijack_mode "$@";;
  link)          shift || true; cmd_link "$@";;
  uninstall|rm)  shift || true; cmd_uninstall "$@";;
  rescue)        shift || true; cmd_rescue "$@";;
  *) echo "用法: pdg [menu|status|doctor [--json|--deep]|update [--dry-run]|snapshot|rollback [n]|token|restart|log [n]|traffic|ios [status|diff|previous|ack|recover|repair](仅 iOS)|report [--redact-ip|--full]|detect-cidr|platform <ios|android>|hijack-mode <all|gfw>|link status|migrate|migrate-fw|tx <list|show|recover|abort>|rescue <enable|disable|status|fingerprint|bind <IPv4>|rotate-token|rotate-cert>|uninstall [--purge]]";;
esac
