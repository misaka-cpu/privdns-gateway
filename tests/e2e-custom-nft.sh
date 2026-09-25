#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 迁移不得让**不属于本项目**的防火墙配置失效(P0)。
#
# 上一轮只做到"文本保留": 把用户的表原样留在 /etc/nftables.conf 里。但那不等于规则还有效 ——
# PDG 自己的 `table inet pdg` 带 `hook input priority 0; policy drop`, 而 nftables 里**同一
# hook 上的多个 base chain 都会执行**, 任何一条判 drop 包就没了。于是用户 chain 里对 9443 /
# WireGuard 的 accept 形同虚设: 配置看着还在, 端口实际已经不通, 而迁移还报"成功"。
#
# 保守方案: 除 pdg 外还存在挂 `hook input` 的 base chain(**配置文件或当前运行 ruleset 任一**)
# → 在动防火墙与内核之前中止迁移, 让用户自己合并。没挂 input hook 的 NAT/forward/VPN 表不受影响,
# 照常保留。这道门在迁移链上靠后的环节(migrate_drop_singbox): 经公开入口进入时, 链上排在它前面的步骤
# (退役清理、模块部署、若干服务重启等)照常先执行 —— 本用例只断言防火墙与两个核心服务, 不断言"整台机器未动"。
#
# 三次迁移都走公开入口 `pdg migrate`: 快照、服务前像与句柄由产品自己建立。目标到达(门的完整原句 / 迁移完成原句
# + 原始退出码)之后才计现场判据; 判定前提未成立或未取得(含观测失败)时具名判失败, 现场判据记"未执行"。拒绝场景两类证据分开:
# 前后净状态(配置哈希 + 运行规则 + 服务状态), 与本次调用窗口内桩调用记录里的 nft 加载 / 核心服务写动作。
# nft 桩维护**真的 ruleset 状态**; 桩的 `nft -c` 恒返回 0, 不做真校验。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
printf 'android\n' > /etc/privdns-gateway/platform
# 真 mihomo: 钉值、版本与真内核探针都由夹具核; 拿不到走 e2e_skip(严格模式判失败, SKIP 不算通过)。
# 以前这里写一个 sh 假内核 —— 它过不了迁移里的内容完整性检查(先比摘要再执行), 迁移会去下载或直接失败。
e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制"

# ── 带**真状态**的 nft 桩 ────────────────────────────────────────────────────
# 只记调用的桩证明不了"运行规则没变"。这里维护一份"已加载 ruleset":
#   nft -f FILE      → 把 FILE 内容装载为当前 ruleset(模拟真的生效)
#   nft -c -f FILE   → 只校验, 不改状态
#   nft list ruleset → 打印当前 ruleset
NFT_STATE=$E2E_TMP/e2e-nft-ruleset
# nft 桩走 e2e-lib.sh 的唯一实现。原来这里是一份私有的简化桩, **没有 `-j` 分支** ——
# 被测路径一旦走到 nftlive(它读的正是 `nft -j list table`), 桩会静默返回空, 于是断言
# 读到一个"看着健康"的空表。共享桩把 -j 接到 tests/nftjson.py 上, 表不在就非零退出。
e2e_write_nft_stub

# ── 目标原句(与 deploy/bot/pdg.sh 的输出逐字一致) ─────────────────────────────
CN_CALLS="$E2E_TMP/e2e-calls.log"      # 共享桩的调用记录: nft / systemctl 每调用一次记一行
CN_GATE1='检测到自定义 input base chain, 无法保证与 PDG 默认拒绝策略(policy drop)兼容 → 中止迁移。'
CN_GATE3='无法确认现场是否存在其它 input base chain → 中止迁移(现场未做任何改动)。'
CN_DONE2='已迁移到 mihomo 内核, sing-box 运行时已移除。'
CN_DONE2B='✅ 迁移完成(快照: '

# 一次公开入口调用, 连同紧贴它的桩调用记录窗口。设置:
#   rc = 产品原始退出码; out = 完整输出(只在 lrc=0 时可用); lrc = 读日志的退出码;
#   win = 窗口内的记录行; wbad = 窗口观测无效的原因(空 = 有效)。
# 窗口 = 调用前后各读一次记录行数, 取其间的行。行数读不到、不是数字、调用后变短、截取失败、截出行数与差值不符,
# 都判观测无效 —— 不当成"零动作"。
cn_migrate(){   # $1=日志名
  local n0 n1 k=0
  local -a _l
  wbad=""; win=""
  n0="$(wc -l < "$CN_CALLS")" || wbad="调用前读不到桩调用记录行数"
  bash /usr/local/bin/pdg migrate > "$E2E_TMP/$1.log" 2>&1; rc=$?
  n1="$(wc -l < "$CN_CALLS")" || wbad="${wbad:-调用后读不到桩调用记录行数}"
  echo "   [记录] $1: pdg migrate 原始退出码 = $rc(完整输出在 $1.log)"
  out="$(cat "$E2E_TMP/$1.log")"; lrc=$?
  [[ -n "$wbad" ]] && return 0
  if [[ ! "$n0" =~ ^[0-9]+$ || ! "$n1" =~ ^[0-9]+$ ]]; then wbad="记录行数不是数字([$n0] / [$n1])"; return 0; fi
  if (( n1 < n0 )); then wbad="调用后桩调用记录变短($n0 → $n1), 窗口边界不成立"; return 0; fi
  (( n1 == n0 )) && return 0
  win="$(sed -n "$((n0 + 1)),${n1}p" "$CN_CALLS")" || { wbad="截取窗口失败"; win=""; return 0; }
  [[ -n "$win" ]] && { mapfile -t _l <<<"$win"; k=${#_l[@]}; }
  [[ "$k" == $((n1 - n0)) ]] || { wbad="截出 $k 行, 与行数差 $((n1 - n0)) 不符"; win=""; }
}

# 按桩记下的实际调用格式分拣窗口里的写动作:
#   nft: 带 -f / --file 且不带 -c / --check 的是加载; 子命令 add / delete / flush / … 是改动; list、-c -f 是读或校验。
#   systemctl: 查询动词(is-active / is-enabled / show / status / cat / list-*)不算写; 其余动词里, 单元参数有
#     sing-box 或 mihomo(可带 .service、可多单元、可带选项)的是核心服务写动作, 其它记为"其它服务 / 全局动作"。
cn_classify(){
  cn_nftw=(); cn_corew=(); cn_otherw=()
  local line t verb u fl ck cmd skip core
  local -a a units
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -ra a <<<"$line"
    case "${a[0]}" in
      nft)
        fl=0; ck=0; cmd=""; skip=0
        for t in "${a[@]:1}"; do
          if (( skip )); then skip=0; continue; fi
          case "$t" in
            --check) ck=1 ;;
            --file) fl=1; skip=1 ;;
            --*) ;;
            -*) [[ "$t" == *c* ]] && ck=1; [[ "$t" == *f* ]] && { fl=1; skip=1; } ;;
            *) cmd="$t"; break ;;
          esac
        done
        if (( fl && !ck )) || [[ "$cmd" =~ ^(add|create|insert|replace|delete|destroy|flush|reset|rename|import)$ ]]; then
          cn_nftw+=("$line")
        fi ;;
      systemctl)
        verb=""; units=()
        for t in "${a[@]:1}"; do
          [[ "$t" == -* ]] && continue
          if [[ -z "$verb" ]]; then verb="$t"; else units+=("$t"); fi
        done
        case "$verb" in
          is-active|is-enabled|is-failed|is-system-running|show|status|cat|list-*|get-default|"") ;;
          *) core=0
             for u in "${units[@]}"; do [[ "$u" =~ ^(sing-box|mihomo)(\.service)?$ ]] && core=1; done
             if (( core )); then cn_corew+=("$line"); else cn_otherw+=("$line"); fi ;;
        esac ;;
    esac
  done <<<"$win"
}

# 门的原句之后, 产品用四个空格缩进逐行列出冲突; 点名只在这几行里找。
cn_gate_block(){   # $1=门原句
  local l on=0
  while IFS= read -r l; do
    if (( on )); then
      if [[ "$l" == "    "* ]]; then printf '%s\n' "$l"; else break; fi
    elif [[ "$l" == *"$1"* ]]; then on=1; fi
  done <<<"$out"
}

# 拒绝场景的过程证据: 只说桩记下的调用里有没有这两类写动作, 不说"整台机器未动"、也不说"文件从未写过"。
cn_window_verdict(){   # $1=场景标签
  local n=0
  local -a _l
  if [[ -n "$wbad" ]]; then bad "$1 过程证据观测无效: $wbad —— 不当成零动作, 不下结论"; return 0; fi
  cn_classify
  [[ -n "$win" ]] && { mapfile -t _l <<<"$win"; n=${#_l[@]}; }
  echo "   [记录] $1 调用窗口: 桩调用记录 $n 行; 其它服务 / 全局动作 ${#cn_otherw[@]} 条${cn_otherw[0]:+: $(printf '[%s] ' "${cn_otherw[@]}")}"
  if (( ${#cn_nftw[@]} == 0 )); then ok "$1 本次调用窗口内, 桩记下的调用里没有 nft 加载或改动(nft -c -f 校验不算)"
  else bad "$1 本次调用窗口内有 nft 加载或改动: $(printf '[%s] ' "${cn_nftw[@]}")"; fi
  if (( ${#cn_corew[@]} == 0 )); then ok "$1 本次调用窗口内, 桩记下的调用里没有针对 sing-box / mihomo 的服务写动作(状态查询不算)"
  else bad "$1 本次调用窗口内有针对 sing-box / mihomo 的服务写动作: $(printf '[%s] ' "${cn_corew[@]}")"; fi
}

seed_sb(){   # 造出"仍在跑 sing-box 的老机器"(unit 用老版真实形态 + 归属标记, 迁移才会走完整路径)
  printf 'singbox\n' > /etc/privdns-gateway/backend
  printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/sing-box; chmod 755 /usr/local/bin/sing-box
  cat > /etc/systemd/system/sing-box.service <<'SBU'
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
SBU
  : > /etc/privdns-gateway/singbox.pdg-owned      # 可信归属标记: 确属本项目所装
  echo 1 > $E2E_TMP/e2e-svc/sing-box.ac; echo 1 > $E2E_TMP/e2e-svc/sing-box.en
  rm -f $E2E_TMP/e2e-svc/mihomo.ac $E2E_TMP/e2e-svc/mihomo.en
}

svc_state(){ printf '%s/%s|%s/%s' \
  "$(systemctl is-active sing-box 2>/dev/null)" "$(systemctl is-enabled sing-box 2>/dev/null)" \
  "$(systemctl is-active mihomo 2>/dev/null)"   "$(systemctl is-enabled mihomo 2>/dev/null)"; }

# ══ 场景 1: 存在**外部 input base chain** → 迁移必须在动防火墙与内核之前中止 ════
echo "── 1. 用户有自己的 input base chain(与 PDG 的 policy drop 不兼容) ──"
seed_sb
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
# 用户自己的过滤表: 放行业务端口与 WireGuard
table inet myfilter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 9443, 9444 } accept
        udp dport 51820 accept
    }
}

table ip mynat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.66.0.0/24 oifname "eth0" masquerade
    }
}

table inet pdg
delete table inet pdg

table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        tcp dport { 22 } accept
    }
}
NFT
nft -f /etc/nftables.conf                       # 让"当前运行 ruleset"= 这份配置
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA="$(nft list ruleset | sha256sum | cut -d' ' -f1)"
SVC_BEFORE="$(svc_state)"

cn_migrate cn1
# 目标 = 外部 input 链门的拒绝: 门的完整原句 + 原始退出码 1。非零、泛化的"无法确认"、没有成功文案、没有前置报错,
# 都证明不了到达。判定前提未成立或未取得(含观测失败, 那时也不能认定目标未执行)就具名判失败, 点名、净状态与窗口判据记"未执行"。
reach=no
if (( lrc != 0 )); then
  bad "1 观测无效: 日志读取失败(cat 退出码 $lrc), 不据可能已吐出的半截内容判到达(产品原始退出码 $rc 已单独记录)"
else
  grep -qF -- "$CN_GATE1" <<<"$out"; g=$?          # 0 有 / 1 确认没有 / ≥2 查询执行失败
  if (( g >= 2 )); then
    bad "1 观测无效: 到达查询执行失败(grep 退出码 $g), 不归为'没到达'(产品原始退出码 $rc 已单独记录)"
  elif [[ "$g" == 0 && "$rc" == 1 ]]; then
    reach=yes; ok "1: 到达外部 input 链门并由它拒绝(门的完整原句 + 原始退出码 1)"
  elif [[ "$g" == 0 ]]; then
    bad "1: 出现了门的原句, 但原始退出码 $rc(应为 1)—— 执行异常, 不算目标拒绝"
  elif [[ "$rc" == 0 ]]; then
    bad "1: 外部 input 链现场居然迁移成功了(原始退出码 0)"
  else
    bad "1: 原始退出码 $rc, 但没到达外部 input 链门 —— 提前停止不能顶替目标拒绝: $(grep -E '❌|⛔' <<<"$out" | head -2 | tr '\n' ' ')"
  fi
fi
if [[ "$reach" == yes ]]; then
  blk="$(cn_gate_block "$CN_GATE1")"
  grep -qF 'myfilter' <<<"$blk"; g=$?
  if (( g >= 2 )); then bad "1c 观测无效: 点名查询执行失败(grep 退出码 $g)"
  elif (( g == 0 )); then ok "门列出的冲突里点名了 myfilter, 便于用户手工合并"
  else bad "1c: 门列出的冲突里没点名 myfilter: [$blk]"; fi
  # 前后净状态: 只说明终态与调用前相同, 证明不了过程中没动过(过程看下面的调用窗口)
  [[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA" ]] \
    && ok "拒绝后 /etc/nftables.conf 与调用前逐字节相同" || bad "1d: 配置被改写了"
  [[ "$(nft list ruleset | sha256sum | cut -d' ' -f1)" == "$RULESET_SHA" ]] \
    && ok "拒绝后运行 ruleset 与调用前相同" || bad "1e: 运行规则被改了"
  [[ "$(svc_state)" == "$SVC_BEFORE" ]] \
    && ok "拒绝后 sing-box / mihomo 的运行与自启状态与调用前相同" || bad "1f: 服务状态变了: $SVC_BEFORE → $(svc_state)"
  [[ "$(cat /etc/privdns-gateway/backend)" == singbox ]] \
    && ok "拒绝后 backend 标记仍是 singbox" || bad "1g: backend=$(cat /etc/privdns-gateway/backend)"
  [[ -e /usr/local/bin/sing-box && -e /etc/systemd/system/sing-box.service ]] \
    && ok "拒绝后 sing-box 运行时文件仍在" || bad "1h: sing-box 被动了"
  cn_window_verdict 1
else
  echo "   [未执行] 1 的点名、前后净状态(配置 / 运行 ruleset / 两个核心服务 / backend / sing-box 文件)与调用窗口判据: 本格判定前提未成立或未取得, 相关判据未执行(观测失败不能证明目标未执行); 不据此推断现场损坏"
fi

# ══ 场景 2: 只有 NAT/forward(不挂 input hook)→ 迁移照常进行且原样保留 ════════
echo; echo "── 2. 用户只有 NAT/forward/VPN 表(不挂 input hook) ──"
seed_sb
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table ip mynat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.66.0.0/24 oifname "eth0" masquerade   # VPN 出网 NAT
    }
}

table inet myfwd {
    chain forward {
        type filter hook forward priority 0; policy accept;
        iifname "wg0" oifname "eth0" accept
        oifname "wg0" iifname "eth0" ct state established,related accept
    }
}

table inet pdg
delete table inet pdg

table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        tcp dport { 22 } accept
        ip saddr 127.0.0.0/8 tcp dport { 53, 80, 81, 443, 853, 8445 } accept
    }
}
NFT
nft -f /etc/nftables.conf
CUSTOM_BEFORE="$(awk '/table inet pdg/{exit} {print}' /etc/nftables.conf)"
CUSTOM_SHA="$(printf '%s' "$CUSTOM_BEFORE" | sha256sum | cut -d' ' -f1)"

cn_migrate cn2
# 目标 = 迁移完成: 原始退出码 0 + 产品的两句完成原句。成立之后, 原有现场判据逐条单独核, 不把它们当成前提。
ran2=no
if (( lrc != 0 )); then
  bad "2 观测无效: 日志读取失败(cat 退出码 $lrc), 不据可能已吐出的半截内容判迁移完成(产品原始退出码 $rc 已单独记录)"
else
  grep -qF -- "$CN_DONE2" <<<"$out"; d1=$?
  grep -qF -- "$CN_DONE2B" <<<"$out"; d2=$?
  if (( d1 >= 2 || d2 >= 2 )); then
    bad "2 观测无效: 完成原句查询执行失败(grep 退出码 $d1 / $d2)(产品原始退出码 $rc 已单独记录)"
  elif [[ "$rc" == 0 && "$d1" == 0 && "$d2" == 0 ]]; then
    ran2=yes; ok "无 input hook 冲突 → 迁移完成(原始退出码 0 + '已迁移到 mihomo 内核…' 与 '✅ 迁移完成' 原句)"
  else
    bad "2: 迁移未完成: 原始退出码 $rc, 完成原句 $([[ $d1 == 0 ]] && echo 有 || echo 无) / $([[ $d2 == 0 ]] && echo 有 || echo 无): $(tail -5 <<<"$out")"
  fi
fi
if [[ "$ran2" == yes ]]; then
  CUSTOM_AFTER="$(awk '/table inet pdg/{exit} {print}' /etc/nftables.conf)"
  [[ "$(printf '%s' "$CUSTOM_AFTER" | sha256sum | cut -d' ' -f1)" == "$CUSTOM_SHA" ]] \
    && ok "项目管理区之外的内容逐字节未变" \
    || { bad "2b: 自定义区被改写"; diff <(printf '%s\n' "$CUSTOM_BEFORE") <(printf '%s\n' "$CUSTOM_AFTER") | head -8; }
  # 运行 ruleset 里也要真的还有这些规则(而不是只留在文件里)
  rs="$(nft list ruleset)"; rsrc=$?
  if (( rsrc != 0 )); then
    bad "2c/2d 观测无效: 读不到运行 ruleset(nft 退出码 $rsrc)"
  else
    for probe in 'table ip mynat' 'masquerade' 'table inet myfwd' 'wg0'; do
      grep -qF "$probe" <<<"$rs" && ok "运行 ruleset 仍含: $probe" || bad "2c: 运行规则里没了 $probe"
    done
    grep -q 'redirect to :7893' <<<"$rs" \
      && ok "运行 ruleset 已换成 mihomo REDIRECT 入站(迁移真做了事)" || bad "2d: pdg 区没生效"
  fi
  [[ "$(grep -c '^table inet pdg {' /etc/nftables.conf)" == 1 ]] \
    && ok "pdg 表只有一份(没有重复拼接)" || bad "2e: pdg 表重复"
  grep -q 'tcp dport { 22 } accept' /etc/nftables.conf \
    && ok "SSH 端口仍放行(没把自己锁在门外)" || bad "2f: SSH 放行没了"
else
  echo "   [未执行] 2b 自定义区 / 2c 运行规则里的 NAT·forward·wg0 / 2d REDIRECT / 2e 单份 pdg 表 / 2f SSH 放行: 本格判定前提未成立或未取得, 相关判据未执行(观测失败不能证明迁移未执行); 不据此推断现场损坏"
fi

# ══ 场景 3: `nft list ruleset` 读不到 → 不能当成"现场干净"就往下切 ═══════════
# 配置文件干净、但内存里可能还挂着 input 链(非 root / nft 不可用时根本看不到)。
# 旧实现把读失败静默当成没有冲突, 于是照常迁移 —— "配置保留、端口不通"换个入口又回来了。
echo; echo "── 3. 运行 ruleset 读不到(权限不足/nft 不可用) ──"
seed_sb
# 场景二若真迁完, 这里重新播种只补回 sing-box 侧(backend / sing-box 文件 / 桩服务状态); mihomo 侧的 unit、配置与二进制
# 会留下, 形成混合现场。如实记下, 不清理; 与门相关的前提(backend=singbox、sing-box 文件都在)不成立就具名停止本格。
echo "   [记录] 3 播种后的现场: backend=$(cat /etc/privdns-gateway/backend 2>&1); mihomo.service $([[ -e /etc/systemd/system/mihomo.service ]] && echo 在 || echo 不在); /etc/mihomo/config.yaml $([[ -e /etc/mihomo/config.yaml ]] && echo 在 || echo 不在)"
pre3=yes
[[ "$(cat /etc/privdns-gateway/backend 2>/dev/null)" == singbox && -e /usr/local/bin/sing-box && -e /etc/systemd/system/sing-box.service ]] || pre3=no
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table inet pdg
delete table inet pdg

table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        tcp dport { 22 } accept
    }
}
NFT
nft -f /etc/nftables.conf
CONF_SHA3="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA3="$(nft list ruleset | sha256sum | cut -d' ' -f1)"
SVC_BEFORE3="$(svc_state)"
if [[ "$pre3" != yes ]]; then
  bad "3 前置不成立: 重新播种后 sing-box 侧不完整(backend / sing-box 文件), 迁移会在门之前短路 —— 本格停止"
  echo "   [未执行] 3 的迁移调用、到达判据、前后净状态与调用窗口判据"
else
# 只让 `list ruleset` 失败(真实形态: nft 在, 但读 ruleset 要 CAP_NET_ADMIN), 其余子命令照旧。
# 每拦下一次就在本格自己的目录里记一行: 这是"产品确实尝试过读 ruleset"的证据(拦下的读取不进共享桩的调用记录)。
CN3_DIR="$E2E_TMP/cn3"; mkdir -p "$CN3_DIR"; : > "$CN3_DIR/intercepts.log"
cp /usr/local/bin/nft /usr/local/bin/nft.real
{ printf '#!/bin/sh\nINTERCEPTS=%s\n' "$CN3_DIR/intercepts.log"
  cat <<'S'
if [ "$1" = list ] && [ "$2" = ruleset ]; then
  echo "list ruleset" >> "$INTERCEPTS"
  echo "Error: Could not process rule: Operation not permitted" >&2; exit 1
fi
exec /usr/local/bin/nft.real "$@"
S
} > /usr/local/bin/nft
chmod 755 /usr/local/bin/nft

cn_migrate cn3
ic="$(wc -l < "$CN3_DIR/intercepts.log")"; icrc=$?
cp -f /usr/local/bin/nft.real /usr/local/bin/nft      # 还原后再验现场
# 目标 = "无法确认"分支的拒绝: 门的完整原句 + 原始退出码 1, 且包装器确实拦下过读取。两者缺一不可、互不替代。
reach=no
if (( lrc != 0 )); then
  bad "3 观测无效: 日志读取失败(cat 退出码 $lrc), 不据可能已吐出的半截内容判到达(产品原始退出码 $rc 已单独记录)"
elif (( icrc != 0 )) || [[ ! "$ic" =~ ^[0-9]+$ ]]; then
  bad "3 观测无效: 读不到包装器的拦截记录(退出码 $icrc)"
else
  echo "   [记录] 3 包装器拦下 \`nft list ruleset\` $ic 次(这些读取不进共享桩的调用记录)"
  grep -qF -- "$CN_GATE3" <<<"$out"; g=$?
  if (( g >= 2 )); then
    bad "3 观测无效: 到达查询执行失败(grep 退出码 $g), 不归为'没到达'(产品原始退出码 $rc 已单独记录)"
  elif [[ "$g" == 0 && "$rc" == 1 ]] && (( ic >= 1 )); then
    reach=yes
    ok "3: 故障包装器确实拦下了读取($ic 次)"
    ok "3: 到达'无法确认'分支并由它拒绝(门的完整原句 + 原始退出码 1)"
  elif [[ "$g" == 0 && "$rc" == 1 ]]; then
    bad "3: 出现了门的原句, 但包装器一次都没拦到读取 —— 不能确认拒绝来自本格注入的故障"
  elif [[ "$g" == 0 ]]; then
    bad "3: 出现了门的原句, 但原始退出码 $rc(应为 1)—— 执行异常, 不算目标拒绝"
  elif [[ "$rc" == 0 ]]; then
    bad "3: 读不到运行 ruleset 居然照常迁移了(原始退出码 0)"
  else
    bad "3: 原始退出码 $rc, 但没到达'无法确认'分支(包装器拦下 $ic 次)—— 提前停止不能顶替目标拒绝: $(grep -E '❌|⛔' <<<"$out" | head -2 | tr '\n' ' ')"
  fi
fi
if [[ "$reach" == yes ]]; then
  [[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA3" ]] \
    && ok "拒绝后 /etc/nftables.conf 与调用前逐字节相同" || bad "3c: 配置被改写了"
  [[ "$(nft list ruleset | sha256sum | cut -d' ' -f1)" == "$RULESET_SHA3" ]] \
    && ok "拒绝后运行 ruleset 与调用前相同" || bad "3d: 运行规则被改了"
  [[ "$(svc_state)" == "$SVC_BEFORE3" ]] \
    && ok "拒绝后 sing-box / mihomo 的运行与自启状态与调用前相同" || bad "3e: 服务状态变了: $SVC_BEFORE3 → $(svc_state)"
  [[ "$(cat /etc/privdns-gateway/backend)" == singbox ]] \
    && ok "拒绝后 backend 标记仍是 singbox" || bad "3f: backend=$(cat /etc/privdns-gateway/backend)"
  cn_window_verdict 3
else
  echo "   [未执行] 3 的前后净状态(配置 / 运行 ruleset / 两个核心服务 / backend)与调用窗口判据: 本格判定前提未成立或未取得, 相关判据未执行(观测失败不能证明目标未执行); 不据此推断现场损坏"
fi
fi

# ══ 场景 4: 检查函数对当前现场有 / 无外部 input 链的判断 ═════════════════════
# 前置门只管迁移当时; 之后现场变了, 要靠 doctor 里的这项检查再提醒。这里调的是 deploy/bot/checks.py 的
# check_nft_input_chains() 本身, 不是 `pdg doctor` 命令验收; 它只看配置文件与运行 ruleset, 不看 backend。
# 现场沿用场景三留下的配置(可能是混合现场, 也可能从未迁移成功), 所以这里验证的是"有 / 无外部 input 链"时的判定,
# 不声称"迁移后"。检查函数进程异常时不据输出判。
echo; echo "── 4. 检查函数对当前现场有 / 无外部 input 链的判断 ──"
echo "   [记录] 4 现场: backend=$(cat /etc/privdns-gateway/backend 2>&1)"
cat >> /etc/nftables.conf <<'NFT'

table inet lateradd {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 9443 accept
    }
}
NFT
nft -f /etc/nftables.conf
d_out=$(python3 -c "
import sys; sys.path.insert(0,'/opt/pdg-bot')
import checks
print(checks.check_nft_input_chains())" 2>&1); drc=$?
if (( drc != 0 )); then
  bad "4: 检查函数进程异常(退出码 $drc), 不据输出判: $(tail -3 <<<"$d_out")"
elif grep -q "'fail'" <<<"$d_out" && grep -q 'lateradd' <<<"$d_out"; then
  ok "检查函数对后加的 input 链(inet lateradd)判 fail"
else
  bad "4: 检查函数没报: $d_out"
fi
# 去掉后应回到 ok(不是恒报警)
python3 - <<'PY'
txt = open("/etc/nftables.conf", encoding="utf-8").read()
open("/etc/nftables.conf", "w", encoding="utf-8").write(txt.split("table inet lateradd")[0])
PY
nft -f /etc/nftables.conf
d_out=$(python3 -c "
import sys; sys.path.insert(0,'/opt/pdg-bot')
import checks
print(checks.check_nft_input_chains())" 2>&1); drc=$?
if (( drc != 0 )); then
  bad "4b: 检查函数进程异常(退出码 $drc), 不据输出判: $(tail -3 <<<"$d_out")"
elif grep -q "'ok'" <<<"$d_out"; then
  ok "冲突链移除后检查函数回到 ok(不恒报警)"
else
  bad "4b: $d_out"
fi

rm -f "$NFT_STATE" /usr/local/bin/nft.real
e2e_summary
