#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DNS 仪器的**真 systemd 定点验收**。只验仪器与它的收尾 ——
# 不装 pdg、不装 bot 模块、不跑 update / 迁移 / 平台切换。
#
# 上一次(run 34927398571)这一支在 GitHub 上显示 success, 而日志里有 6 条 [FAIL] ——
# 那是**执行器假绿**: 脚本先自定义 ok/bad(记 P/F), 之后才 source e2e-lib.sh, 而后者
# 重定义 ok/bad 改记 E2E_PASS/E2E_FAIL, 于是汇总只看见 source 之前那两条。
# 这一版的第一条纪律就是: **计数只有一个来源** —— 先 source, 全程用库的 ok/bad 与
# E2E_PASS/E2E_FAIL, 自己一个计数器都不建; 退出码统一由 _final_verdict 给,
# 并且把"零断言 / 执行异常 / 收尾未完成"都算进去。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_ROOT="${E2E_ROOT:-$(cd "$HERE/.." && pwd)}"
# ── 计数唯一来源: **先**加载夹具, 再开始任何断言 ─────────────────────────────
# shellcheck source=tests/e2e-lib.sh
source "$HERE/e2e-lib.sh" || { echo "[FAIL] 读不到 e2e-lib.sh"; echo "通过 0, 失败 1"; exit 1; }
note(){ echo "[NOTE] $1"; }

ACC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dnsinst.XXXXXX")"
EVID="${PDG_REAL_MIG_EVID:-${TMPDIR:-/tmp}/dns-instrument-evidence}"; mkdir -p "$EVID"; chmod 700 "$EVID"
_evn(){ printf '%s\n' "$2" >> "$EVID/$1"; chmod 600 "$EVID/$1" 2>/dev/null || true; }

# ── 归属登记: 只对**本轮登记过**的资源动手 ──────────────────────────────────
OWN_UNIT=""          # 本轮自建的 unit 名(建出来才登记)
OWN_UNIT_PATH=""
OWN_TMP="$E2E_TMP"   # 本轮自建的临时目录
DNS_STUB_PID=""      # 由 dns_fix_conditions 起的自有上游(它自己登记到这个变量)
KEEP_MATERIAL=0      # 恢复无法确认 ⇒ 保留材料, 不删临时目录
CLEANUP_RC=-1        # -1 没跑过 / 0 成功 / 1 失败
REACHED_END=0

# ── 收尾: 结果要进最终判定, 不能"先打印全通过, 再由 EXIT trap 静默失败" ──────
_cleanup(){
  local rc=0 st _urc
  # ① 自建服务: 停 + 复核 + 撤 unit。只动本轮登记的那一个, 不按名字宽杀。
  if [[ -n "$OWN_UNIT" ]]; then
    systemctl stop "$OWN_UNIT" >/dev/null 2>&1
    st="$(systemctl is-active "$OWN_UNIT" 2>/dev/null)"
    if [[ "$st" == active || "$st" == activating ]]; then
      echo "[FAIL] 收尾: 自建服务 $OWN_UNIT 停不下来(is-active=$st)"; rc=1
    fi
    # 本轮从来没给它设过自启(下面起服务时用的是 start, 不是 enable), 这里核一次
    st="$(systemctl is-enabled "$OWN_UNIT" 2>/dev/null)"
    [[ "$st" == enabled || "$st" == enabled-runtime ]] && { echo "[FAIL] 收尾: $OWN_UNIT 竟然是 $st(本轮不该给它加自启)"; rc=1; }
    if [[ -n "$OWN_UNIT_PATH" && -e "$OWN_UNIT_PATH" ]]; then
      rm -f "$OWN_UNIT_PATH" || { echo "[FAIL] 收尾: 撤不掉自建 unit 文件 $OWN_UNIT_PATH"; rc=1; }
      systemctl daemon-reload >/dev/null 2>&1
      [[ -e "$OWN_UNIT_PATH" ]] && { echo "[FAIL] 收尾: $OWN_UNIT_PATH 还在"; rc=1; }
    fi
  fi
  # ② 自有上游: 退出并回收, 监听要真的放掉
  if [[ -n "$DNS_STUB_PID" ]]; then
    kill "$DNS_STUB_PID" 2>/dev/null; wait "$DNS_STUB_PID" 2>/dev/null
    kill -0 "$DNS_STUB_PID" 2>/dev/null && { echo "[FAIL] 收尾: 自有上游 PID $DNS_STUB_PID 还活着"; rc=1; }
    # 同一套口径: 地址与端口精确, 查询出错**不算**已释放。
    sock_conflict udp 127.0.0.1 "${DNS_UP_PORT:-15301}"; _urc=$?
    case "$_urc" in
      0) echo "[FAIL] 收尾: 自有上游的监听 127.0.0.1:${DNS_UP_PORT:-15301} 没放掉 —— $SOCK_WHY"; rc=1;;
      1) : ;;
      *) echo "[FAIL] 收尾: 无法确认自有上游的监听是否释放 —— $SOCK_WHY"; rc=1;;
    esac
  fi
  # ③ 临时物: **只有正常完成才删**; 恢复没确认就留着
  if (( KEEP_MATERIAL )); then
    echo "[NOTE] 收尾: 恢复无法确认 → 保留本轮材料, **不删** $OWN_TMP"
    ls -la "$OWN_TMP" 2>/dev/null | sed 's/^/    /'
    cp -a "$OWN_TMP"/. "$EVID/keep-material/" 2>/dev/null && \
      echo "[NOTE] 收尾: 材料已另存一份到 $EVID/keep-material(可实际取用, 不只打印路径)"
  elif (( rc == 0 )); then
    rm -rf "$OWN_TMP" || { echo "[FAIL] 收尾: 删不掉 $OWN_TMP"; rc=1; }
  else
    echo "[NOTE] 收尾: 前面有失败 → 保留 $OWN_TMP 供查"
  fi
  CLEANUP_RC="$rc"
  return "$rc"
}

_final_verdict(){
  local n=$((E2E_PASS + E2E_FAIL)) rc=0
  echo "────────────────────────────────────────"
  if (( n == 0 )); then
    echo "[FAIL] 零断言: 一条判据都没跑到 —— 不拿'没红'冒充通过"; E2E_FAIL=$((E2E_FAIL+1)); rc=1
  fi
  if (( REACHED_END == 0 )); then
    echo "[FAIL] 执行异常: 脚本没有走到正常收尾点"; E2E_FAIL=$((E2E_FAIL+1)); rc=1
  fi
  if [[ "$CLEANUP_RC" != 0 ]]; then
    echo "[FAIL] 收尾未完成(CLEANUP_RC=$CLEANUP_RC) —— 收尾结果计入最终判定"; E2E_FAIL=$((E2E_FAIL+1)); rc=1
  fi
  echo "通过 $E2E_PASS, 失败 $E2E_FAIL"
  [[ "$E2E_FAIL" == 0 ]] || rc=1
  return "$rc"
}
on_exit(){
  local rc=$?
  trap - EXIT
  [[ "$CLEANUP_RC" == -1 ]] && _cleanup
  _final_verdict; exit $?
}
trap on_exit EXIT
# 硬门不成立是一次**有定义的**停止, 不是"执行异常": 用 bad 计一条真失败(唯一计数源),
# 同时标记已到达停止点, 免得再叠一条"没走到收尾"。退出码仍由 on_exit → _final_verdict 给。
_hard(){ bad "硬门不成立: $1"; REACHED_END=1; exit 1; }
# 准备阶段的硬停。**必须**发生在创建 unit / daemon-reload / start 之前 ——
# 这是一次有定义的停止: 计一条真失败, 保留材料, 退出码仍由 on_exit → _final_verdict 给。
_prep_fail(){ bad "准备未完成: $1"; KEEP_MATERIAL=1; REACHED_END=1; exit 1; }

# ── 统一的 socket 观测口径(三态)────────────────────────────────────────────
# 上一次(run 34936173665)栽在这: 两处都写 `ss -lnup | awk '$5==地址'`, 而
# **只 UDP(不带 -t)时 ss 不打印 Netid 列** —— 本地地址是 $4, $5 是对端 0.0.0.0:*,
# 于是归属检查永远匹配不到; 同一个错列还让"端口空闲"检查**永远查不出占用**(假绿)。
# 所以不是把 $5 换成 $4 就完事 —— 固定一套选项, 并用**实际输出**校准字段:
#   `-H`         不打表头; `-l -n` 只看监听、不解析名字;
#   `-t -u` 一起 ⇒ Netid 恒为 $1、本地地址恒为 $5(单协议时列会少一个, 就是上次的坑);
#   `-p`         带进程; `sport = :<端口>` 用 ss **自带的过滤**, 端口精确匹配
#                (实测 `sport = :1535` 不会命中 :15353, 相近端口前缀不误报)。
# 三态分开: 0=查到相关监听 / 1=查询成功但没有 / 2=查询失败或字段对不上。
# 第三种**绝不**当成"空闲""已释放""归属成立"。原始输出/stderr/退出码一并留作诊断。
SOCK_ROWS=""; SOCK_WHY=""; SOCK_RAW=""; SOCK_ERR=""; SOCK_HIT_PIDS=""
sock_query(){   # $1=端口 → 0 有行 / 1 无行 / 2 查询或解析不可靠
  local port="$1" raw errf rc line n a
  SOCK_ROWS=""; SOCK_WHY=""; SOCK_RAW=""; SOCK_ERR=""
  errf="$(mktemp "${TMPDIR:-/tmp}/sockq.XXXXXX")"
  raw="$(ss -H -l -n -t -u -p "sport = :$port" 2>"$errf")"; rc=$?
  SOCK_RAW="$raw"; SOCK_ERR="$(head -3 "$errf" | tr '\n' ' ')"; rm -f "$errf"
  if [[ "$rc" != 0 ]]; then
    SOCK_WHY="ss 退出码 $rc: ${SOCK_ERR:-（无 stderr）}; 原始输出: ${SOCK_RAW:-（空）}"; return 2
  fi
  [[ -n "$raw" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line// /}" ]] || continue
    n="$(awk '{print $1}' <<<"$line")"; a="$(awk '{print $5}' <<<"$line")"
    case "$n" in tcp|udp) ;; *) SOCK_WHY="字段口径对不上(第 1 列不是 tcp/udp): $line"; return 2;; esac
    [[ "$a" == *:"$port" ]] || { SOCK_WHY="字段口径对不上(第 5 列不像 :$port 的本地地址): $line"; return 2; }
    SOCK_ROWS+="$n	$a	$(grep -o 'pid=[0-9]*' <<<"$line" | sed 's/pid=//' | tr '\n' ',')
"
  done <<<"$raw"
  return 0
}
# 某 endpoint 上有没有**会冲突**的监听。冲突 = 同一地址, 或会覆盖它的通配绑定。
# 127.0.0.53 / 127.0.0.54 上的现有解析器与它不冲突, 不算占用; 端口必须精确相等。
sock_conflict(){   # $1=tcp|udp $2=地址 $3=端口 → 0 冲突 / 1 不冲突 / 2 查不清
  local n a pids ip pt hit=""
  SOCK_HIT_PIDS=""
  sock_query "$3"; local q=$?
  [[ "$q" == 2 ]] && return 2
  [[ "$q" == 1 ]] && return 1
  while IFS=$'\t' read -r n a pids; do
    [[ -n "$n" ]] || continue
    [[ "$n" == "$1" ]] || continue
    ip="${a%:*}"; pt="${a##*:}"
    [[ "$pt" == "$3" ]] || continue
    case "$ip" in
      "$2"|'0.0.0.0'|'*'|'[::]'|'::') hit="$hit $a"; SOCK_HIT_PIDS="$SOCK_HIT_PIDS,${pids%,},";;
    esac
  done <<<"$SOCK_ROWS"
  [[ -n "$hit" ]] || return 1
  SOCK_WHY="$1 $2:$3 上有冲突监听:$hit (pid:${SOCK_HIT_PIDS})"
  return 0
}
# 归属: 目标 endpoint 上的监听是不是**本轮服务**的。PID 用带边界的比法 ——
# 裸 `pid=123` 子串会把 pid=1234 认成同一个进程。
sock_owned_by(){   # $1=tcp|udp $2=地址 $3=端口 $4=期望 PID → 0 是 / 1 不是 / 2 查不清
  sock_conflict "$1" "$2" "$3"; local c=$?
  [[ "$c" == 2 ]] && return 2
  [[ "$c" == 1 ]] && { SOCK_WHY="$1 $2:$3 上没有监听"; return 1; }
  [[ -n "$4" && "$4" != 0 ]] || { SOCK_WHY="没有可用的 MainPID"; return 1; }
  [[ "$SOCK_HIT_PIDS" == *",$4,"* ]] && return 0
  SOCK_WHY="$1 $2:$3 上的监听不属于 PID $4(实得 pid:${SOCK_HIT_PIDS})"
  return 1
}

# 监听残留检查, **三态**。上一次(run 34934021143)就是栽在这条上:
# 原来写 `grep -c … | grep -qx 0`, 而 grep 在**零匹配**时退出码是 1, 脚本开头的
# `set -uo pipefail` 把整条管道拖成非零 —— 于是配置正确的时候反而判红。
# 修法不是改成 `! grep -q`(那会把 grep 的**执行错误**也一并当成"没有违规"),
# 也不是 `|| true`(那等于不判)。这里显式取 grep 的退出码, 三种情况分开处理:
#   0  = 找到了禁止的通配监听 → 具名拒绝
#   1  = 正常跑完且零匹配     → 放行
#   其它 = 读取/执行出错      → 具名说明"无法完成监听检查", 同样拒绝
# 匹配范围只针对**真正的 listen 配置**: `listen: "0.0.0.0:…`。
# ECS 插件那句 `preset: "0.0.0.0"` 不是监听, 不能判成违规。
_LISTEN_WHY=""
_listen_wildcard_check(){   # $1=配置文件 → 0 放行 / 1 有违规 / 2 检查本身没做成
  local f="$1" out rc errf
  errf="$(mktemp "${TMPDIR:-/tmp}/lsnchk.XXXXXX")"
  out="$(grep -nE 'listen:[[:space:]]*"0\.0\.0\.0:' "$f" 2>"$errf")"; rc=$?
  case "$rc" in
    0) _LISTEN_WHY="还有通配监听: $(head -2 <<<"$out" | tr '\n' ' ')"; rm -f "$errf"; return 1;;
    1) _LISTEN_WHY=""; rm -f "$errf"; return 0;;
    *) _LISTEN_WHY="grep 退出码 $rc: $(head -1 "$errf")"; rm -f "$errf"; return 2;;
  esac
}

# 负控专用: 在**子 shell**里跑, 它的 ok/bad 一律不影响主计数(独立计账, 不清零也不覆盖)
NEG_OUT="$E2E_TMP/negctl.out"
negctl(){ ( "$@" ) > "$NEG_OUT" 2>&1; return 0; }

# ── 硬门 ────────────────────────────────────────────────────────────────────
[[ "$(cat /proc/1/comm)" == systemd ]] || _hard "PID 1 不是 systemd"
[[ "$(id -u)" == 0 ]] || _hard "要 root(要起 unit、改 /etc)"
SCTL="$(command -v systemctl)"; [[ -x "$SCTL" ]] || _hard "没有 systemctl"
[[ -x /usr/local/bin/mosdns ]] || _hard "没装 mosdns"
WANT_VER="$(grep -m1 '^MOSDNS_VER=' "$E2E_ROOT/lib/versions.sh" | cut -d'"' -f2)"
GOT_VER="$(/usr/local/bin/mosdns version 2>&1 | head -1)"
case "$GOT_VER" in "$WANT_VER"*) ok "硬门: mosdns 是钉死的那一版($GOT_VER)";; *) _hard "mosdns 版本 $GOT_VER ≠ 钉死的 $WANT_VER";; esac
command -v dig >/dev/null 2>&1 || _hard "没有 dig"
[[ -f "$ACC" ]] || _hard "找不到 $ACC"
ok "硬门: PID1=systemd / root / 真 systemctl / 真 dig 全部成立"

# ── 最小环境: **只**准备 mosdns 要的东西 ────────────────────────────────────
# 不调 e2e_seed_install —— 它会 cp 整个仓库到 /opt/privdns-gateway、装 /usr/local/bin/pdg
# 与全部 bot 模块, 对本支一件都用不上。只调 e2e_seed_mosdns(既有最小函数)。
echo; echo "══ 一. 最小环境准备(逐项列明本轮实际生成的文件)══"
# ── 前置目录: 从 e2e_seed_mosdns 的**实际读写**推导, 不照搬完整安装器 ──────────
# 它开头就往 /etc/mosdns/rules/ 里 `: > 各规则文件`, 末尾往 /etc/privdns-gateway/profile.env
# 写 —— 两个目录都**假定已存在**。过去是 e2e_seed_install 顺手建的(e2e-lib.sh 那句
# `mkdir -p /opt/pdg-bot /etc/mosdns/rules /etc/privdns-gateway`), 本 job 不调那个安装器,
# 所以这里显式补上, 而且**只补这两个** —— 不建 /opt/pdg-bot, 不 cp 仓库, 不装 bot 模块。
# 权限沿用夹具约定: e2e-lib.sh 里就是 mkdir -p(755)。
for _d in /etc/mosdns/rules /etc/privdns-gateway; do
  if [[ -e "$_d" && ! -d "$_d" ]]; then _prep_fail "$_d 已存在但不是目录, 归属不明 —— 不覆盖"; fi
  if [[ -d "$_d" && -n "$(ls -A "$_d" 2>/dev/null)" ]]; then
    _prep_fail "$_d 已存在且非空, 归属不明 —— 本支只在一次性隔离验收环境里跑, 不覆盖现有对象"
  fi
  mkdir -p "$_d" || _prep_fail "建不出 $_d"
  [[ -d "$_d" && -w "$_d" ]] || _prep_fail "$_d 建出来了却不可写"
done
ok "一-0: 前置目录已按夹具约定建好 —— /etc/mosdns/rules($(stat -c %a /etc/mosdns/rules)) 与 /etc/privdns-gateway($(stat -c %a /etc/privdns-gateway))"

# ── 播种: 诊断留着, 但**不拿它的返回码当准备完成** ──────────────────────────
# 上一次(run 34932738273)就是栽在这: 目录不在, 函数中途一路写失败, 而它最后一句是
# `chmod … || true`, 于是整体返回 0, `|| _hard` 根本没触发 —— 配置压根没生成。
SEED_LOG="$E2E_TMP/seed.log"
e2e_seed_mosdns all > "$SEED_LOG" 2>&1; SEED_RC=$?
note "一-1: e2e_seed_mosdns all 退出码 = $SEED_RC(**只作诊断** —— 下面按实际产物判)"
if [[ -s "$SEED_LOG" ]]; then note "  播种输出(末 20 行):"; tail -20 "$SEED_LOG" | sed 's/^/    /'; fi
cp "$SEED_LOG" "$EVID/00-seed-output.txt" 2>/dev/null && chmod 600 "$EVID/00-seed-output.txt"

# ── 产物门: 运行真正需要的东西在不在, 在 unit / daemon-reload / start **之前**判 ──
MC=/etc/mosdns/config.yaml
[[ -s "$MC" ]] || _prep_fail "播种之后 $MC 不存在或为空(播种退出码=$SEED_RC —— 它返回 0 也不等于准备完成)"
# 只管 e2e_seed_mosdns **负责渲染**的那几个。__DOT_DOMAIN__ 不归它管(由 dotwitness 那条
# 迁移渲染), 在本夹具里留着是正常形态, mosdns 照样加载 —— 不能一律判错。
_left="$(grep -oE '__(SERVER_IP|INTERNAL_CIDR|CERT_DIR|MOSDNS_CACHE|HIJACK_SET_FILE)__' "$MC" | sort -u | tr '\n' ' ')"
[[ -z "${_left// /}" ]] || _prep_fail "配置里还留着播种本该渲染掉的占位符: $_left"
for _t in 'tag: force_hijack' 'tag: internal_sequence' 'tag: udp_server' 'tag: local_upstream'; do
  grep -q "$_t" "$MC" || _prep_fail "配置形态不成立: 缺 $_t"
done
ok "一-2: config.yaml 非空、播种负责的占位符全部渲染、关键插件齐(force_hijack / internal_sequence / udp_server / local_upstream)"
# 配置**实际引用**的规则与集合文件必须存在。按夹具契约它们**允许为空** ——
# 空文件是"该功能休眠"的正常形态, 不能因为空就判错。
_miss=""; _n=0
while read -r _p; do
  [[ -n "$_p" ]] || continue
  _n=$((_n+1)); [[ -e "$_p" ]] || _miss="$_miss $_p"
done < <(grep -vE '^[[:space:]]*#' "$MC" \
         | grep -oE '/etc/mosdns/rules/[A-Za-z0-9_.!@+-]+\.txt|/var/lib/privdns-gateway/adblock/[A-Za-z0-9_]+\.txt' \
         | sort -u)
[[ "$_n" -gt 0 ]] || _prep_fail "从配置里一个规则文件路径都没解析到 —— 产物门等于没判"
[[ -z "$_miss" ]] || _prep_fail "配置引用的规则/集合文件缺失:$_miss"
ok "一-3: 配置实际引用的 $_n 个规则/集合文件全部就位(按契约允许为空, 没因为空判错)"
[[ -s /etc/privdns-gateway/profile.env ]] || _prep_fail "profile.env 缺失或为空"
[[ -s /etc/mosdns/certs/fullchain.pem && -s /etc/mosdns/certs/privkey.pem ]] || _prep_fail "DoT 证书或私钥不全"
[[ "$(stat -c %a /etc/mosdns/certs/privkey.pem)" == 600 ]] \
  || _prep_fail "私钥权限是 $(stat -c %a /etc/mosdns/certs/privkey.pem), 约定是 600"
ok "一-4: profile.env 与 DoT 证书/私钥就位, 私钥权限 600(符合夹具约定)"

SEEDED=(/etc/mosdns/config.yaml /etc/privdns-gateway/profile.env
        /etc/mosdns/certs/fullchain.pem /etc/mosdns/certs/privkey.pem)
for f in /etc/mosdns/rules/*.txt; do SEEDED+=("$f"); done
for f in /var/lib/privdns-gateway/adblock/*.txt; do SEEDED+=("$f"); done
{ echo "本轮实际生成/写入的文件(e2e_seed_mosdns all):"
  for f in "${SEEDED[@]}"; do [[ -e "$f" ]] && printf '  %-56s %s\n' "$f" "$(stat -c '%a %u:%g %s字节' "$f")"; done
} | tee -a "$EVID/00-seeded-files.txt" | sed 's/^/    /'
chmod 600 "$EVID/00-seeded-files.txt"
[[ -f /usr/local/bin/pdg ]] && bad "一-1: /usr/local/bin/pdg 竟然被装上了(本支不该装产品)" \
                            || ok "一-1: **没有**安装 /usr/local/bin/pdg"
[[ -d /opt/privdns-gateway ]] && bad "一-2: /opt/privdns-gateway 竟然被铺开了" \
                              || ok "一-2: **没有**复制仓库到 /opt/privdns-gateway"
compgen -G "/opt/pdg-bot/*.py" >/dev/null 2>&1 && bad "一-3: bot 模块被装上了" \
                                               || ok "一-3: **没有**安装任何 bot 模块"
[[ -s /etc/mosdns/config.yaml ]] && ok "一-4: mosdns 配置已生成" || bad "一-4: 没有 mosdns 配置"

# ── 端口: 先实读占用, 再把监听收窄到与查询端一致的回环地址 ──────────────────
echo; echo "══ 二. 监听地址与归属 ══"
LISTEN_IP=127.0.0.1; LISTEN_PORT=53; DOT_PORT=8853
note "启动前实读 :53 / :$DOT_PORT 的占用情况:"
ss -lntup 2>/dev/null | awk 'NR==1 || /:53 |:53$|:8853 /' | sed 's/^/    /' | tee -a "$EVID/01-ports-before.txt"
chmod 600 "$EVID/01-ports-before.txt" 2>/dev/null || true
# 逐个核**本轮实际要用的三个 endpoint**。只观察 —— 不停、不覆盖、不杀占用者;
# 冲突或查不清都在建 unit / daemon-reload / start **之前**拒绝。
for _ep in "udp $LISTEN_IP $LISTEN_PORT" "tcp $LISTEN_IP $LISTEN_PORT" "tcp $LISTEN_IP $DOT_PORT"; do
  # shellcheck disable=SC2086
  set -- $_ep
  sock_conflict "$1" "$2" "$3"; _sc=$?
  case "$_sc" in
    0) bad "二-0($1 $2:$3): 已被占用 —— $SOCK_WHY(只观察, 不停也不杀)"
       KEEP_MATERIAL=1; REACHED_END=1; exit 1;;
    1) ok "二-0($1 $2:$3): 查询成功且没有会冲突的监听";;
    *) bad "二-0($1 $2:$3): **无法可靠观测** —— $SOCK_WHY(不把查不清当成空闲)"
       KEEP_MATERIAL=1; REACHED_END=1; exit 1;;
  esac
done
# 现有解析器在 127.0.0.53/54 上, 与 127.0.0.1 不冲突 —— 看见了, 但一个字都不动它。
sock_query "$LISTEN_PORT" >/dev/null 2>&1 || true
note "二-0(旁证): :$LISTEN_PORT 上现有的监听如下, 本轮只观察不动:"
printf '%s\n' "${SOCK_ROWS:-（无）}" | sed 's/^/    /'
# 只把监听从 0.0.0.0 收窄到**查询端用的同一个地址** —— dns_probe 问的就是 @127.0.0.1,
# 不另写一条"容易通过"的查询路径, 也不改被测的 DNS 函数。
sed -i "s|listen: \"0.0.0.0:53\"|listen: \"$LISTEN_IP:$LISTEN_PORT\"|g; s|listen: \"0.0.0.0:853\"|listen: \"$LISTEN_IP:$DOT_PORT\"|g" /etc/mosdns/config.yaml
# 监听改不成功同样要在建 unit / daemon-reload / start **之前**停 —— 不带着一份没改成的
# 配置去起服务, 那只会把真因埋到 journal 里。
grep -q "listen: \"$LISTEN_IP:$LISTEN_PORT\"" /etc/mosdns/config.yaml \
  && ok "二-1: 配置里的监听已收窄到 $LISTEN_IP:$LISTEN_PORT(与 dns_probe 的查询端一致)" \
  || _prep_fail "监听没改成 $LISTEN_IP:$LISTEN_PORT"
_listen_wildcard_check /etc/mosdns/config.yaml; _lrc=$?
case "$_lrc" in
  0) ok "二-2: 配置里没有 0.0.0.0 通配监听(grep 正常跑完且零匹配)";;
  1) _prep_fail "$_LISTEN_WHY";;
  *) _prep_fail "无法完成监听检查 —— $_LISTEN_WHY";;
esac
# 三处 server(udp/tcp/dot)**都**要收窄到位, 不是"有一个正确监听就算全部正确"。
_n53="$(grep -cE "listen:[[:space:]]*\"$LISTEN_IP:$LISTEN_PORT\"" /etc/mosdns/config.yaml || true)"
_ndot="$(grep -cE "listen:[[:space:]]*\"$LISTEN_IP:$DOT_PORT\"" /etc/mosdns/config.yaml || true)"
{ [[ "$_n53" == 2 && "$_ndot" == 1 ]]; } \
  && ok "二-2b: 三处 server 全部收窄(udp/tcp 各一条 $LISTEN_IP:$LISTEN_PORT, dot 一条 $LISTEN_IP:$DOT_PORT)" \
  || _prep_fail "收窄不全: $LISTEN_IP:$LISTEN_PORT 有 $_n53 条(应 2), $LISTEN_IP:$DOT_PORT 有 $_ndot 条(应 1)"
# ECS 插件的 preset 不是监听, 必须原样留着 —— 收窄不该误伤它。
grep -q 'preset: "0.0.0.0"' /etc/mosdns/config.yaml \
  && ok "二-2c: ECS 插件的 preset: \"0.0.0.0\" 原样保留(没被当成违规监听改掉)" \
  || _prep_fail "ECS preset 被改掉了 —— 收窄误伤了非监听配置"

# ── 自建 unit: 登记归属之后再起 ─────────────────────────────────────────────
OWN_UNIT=mosdns.service; OWN_UNIT_PATH=/etc/systemd/system/mosdns.service
[[ -e "$OWN_UNIT_PATH" ]] && { bad "二-3: $OWN_UNIT_PATH 本来就存在, 归属不明 —— 停止, 不覆盖现有对象"; OWN_UNIT=""; OWN_UNIT_PATH=""; KEEP_MATERIAL=1; REACHED_END=1; exit 1; }
cat > "$OWN_UNIT_PATH" <<'EOF'
[Unit]
Description=mosdns (DNS instrument pinpoint, this run only)
[Service]
ExecStart=/usr/local/bin/mosdns start -d /etc/mosdns
Restart=no
EOF
ok "二-3: 自建 unit $OWN_UNIT_PATH 已登记归属(Restart=no —— 崩溃就是崩溃, 不靠重启循环遮掩)"
systemctl daemon-reload
systemctl start "$OWN_UNIT" >/dev/null 2>&1

# ── 稳定就绪: 状态 + 实例 + 监听归属 + 真实 DNS 行为, 四样一起判 ────────────
# 瞬时 active 不算就绪。预算是既有的那个上限, 不靠延长等待或反复重启碰绿。
dns_ready(){   # $1=期望能答出预期答案的域名 $2=期望答案(空=只要有效观测)
  local u="$OWN_UNIT" i=0 lim="${DNS_READY_BUDGET:-20}" st pid inv nr0 nr1 inv0
  inv0=""; nr0=""
  while (( i < lim )); do
    st="$(systemctl is-active "$u" 2>/dev/null)"
    pid="$(systemctl show -p MainPID --value "$u" 2>/dev/null)"
    inv="$(systemctl show -p InvocationID --value "$u" 2>/dev/null)"
    nr1="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
    if [[ "$st" == active && -n "$pid" && "$pid" != 0 && -n "$inv" ]]; then
      if [[ -z "$inv0" ]]; then inv0="$inv"; nr0="$nr1"
      elif [[ "$inv" == "$inv0" && "$nr1" == "$nr0" ]]; then
        # 观察窗内没有实例更替、没有 NRestarts 增长 → 再看监听归属与真实行为
        # 监听归属只是**必要条件**: 下面还要真实 DNS 查询有效且答案符合预期。
        sock_owned_by udp "$LISTEN_IP" "$LISTEN_PORT" "$pid"; local _own=$?
        if [[ "$_own" == 2 ]]; then
          DNS_READY_WHY="无法可靠观测监听 —— $SOCK_WHY(不当成归属成立)"
        elif [[ "$_own" == 0 ]]; then
          local p; p="$(dns_probe "$1")"
          if dns_probe_ok "$p"; then
            if [[ -z "${2:-}" || "$(dns_answer_of "$p")" == "$2" ]]; then
              DNS_READY_WHY="active pid=$pid inv=$inv NRestarts=$nr1 监听归属=本轮 answer=$(dns_answer_of "$p")"
              return 0
            fi
          fi
          DNS_READY_WHY="服务看着正常(pid=$pid)且监听归属本轮, 但 DNS 还没就绪: $p"
        else
          DNS_READY_WHY="$SOCK_WHY"
        fi
      else
        DNS_READY_WHY="观察窗内实例更替或重启计数增长(inv $inv0→$inv, NRestarts $nr0→$nr1)"
        inv0="$inv"; nr0="$nr1"
      fi
    else
      DNS_READY_WHY="服务不在预期运行态(is-active=$st MainPID=${pid:-?})"
    fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# ── 抽验收脚本里那几个 DNS 函数的原文 ───────────────────────────────────────
_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
for f in dns_probe dns_probe_ok dns_answer_of _dns_reload dns_expect \
         dns_fix_conditions dns_instrument_calibrate dns_feature_probe dns_verdict; do
  b="$(_fn "$ACC" "$f")"; [[ -n "$b" ]] || _hard "抽不到 $f"
  eval "$b"
done
eval "$(grep -E '^DNS_(U|H|UP_PORT|WITNESS|CONTROL)=' "$ACC")"
# 这几个由被测函数写回来, 本支只读。DNS_CALIB_NAME 在下面的"标定后仍满足预期"里用到。
DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""; DNS_CALIB_NAME=""
DNS_RESTORE_DISK=0; DNS_RESTORE_RUN=0; DNS_READY_WHY=""
c_keep_note(){ KEEP_MATERIAL=1; note "  恢复无法确认 → 本轮材料保留(收尾时会另存一份到 $EVID/keep-material)"; }
wait_stable(){ systemctl is-active "$1" 2>/dev/null; }   # _dns_reload 用它; 真正的就绪判据是 dns_ready
ok "二-4: 九个 DNS 函数都从验收脚本原文抽到(不是本支自己写的一份)"

echo; echo "══ 三. 健康前像: 见证=H / 对照=U / 标定域起初=U ══"
HIJ=/etc/mosdns/rules/mitm_hijack.txt
printf 'full:%s\n' "$DNS_WITNESS" > "$HIJ"; chmod 640 "$HIJ"
ok "三-0: 接管表里放入业务见证域 $DNS_WITNESS(它的预期就是 H=$DNS_H)"
if dns_ready "$DNS_WITNESS" "$DNS_H"; then
  ok "三-1: 服务稳定就绪 —— $DNS_READY_WHY"
else
  bad "三-1: 没能稳定就绪 —— $DNS_READY_WHY"
  journalctl -u "$OWN_UNIT" -n 30 --no-pager 2>&1 | tail -20 | sed 's/^/    /'
  KEEP_MATERIAL=1; REACHED_END=1; exit 1
fi

echo; echo "══ 四. 标定: 甲→乙→还原甲 ══"
if dns_instrument_calibrate; then ok "四-1: 标定通过"; else bad "四-1: 标定没过 —— $DNS_CALIB_WHY"; fi
[[ "$DNS_INSTRUMENT_OK" == 1 ]] && ok "四-2: 同一查询名精确走出 U=$DNS_U → H=$DNS_H" || bad "四-2: 没走出 U→H"
[[ "$DNS_RESTORE_DISK" == 1 ]] && ok "四-3: 磁盘还原已确认" || bad "四-3: 磁盘还原未确认(DISK=$DNS_RESTORE_DISK)"
[[ "$DNS_RESTORE_RUN"  == 1 ]] && ok "四-4: **运行配置**还原已用真实查询确认" || bad "四-4: 运行配置还原未确认(RUN=$DNS_RESTORE_RUN)"
[[ "$(sha256sum "$HIJ" | awk '{print $1}')" == "$(printf 'full:%s\n' "$DNS_WITNESS" | sha256sum | awk '{print $1}')" ]] \
  && ok "四-5: 标定结束后接管表回到健康前像(只剩见证域那一条)" || bad "四-5: 接管表没回到前像: $(cat "$HIJ")"

echo; echo "══ 五. 标定之后, 见证与对照仍各自满足预期 ══"
dns_expect "$DNS_WITNESS" "$DNS_H" && ok "五-1: 见证域仍是 H=$DNS_H" || bad "五-1: $DNS_CALIB_WHY"
dns_expect "$DNS_CONTROL" "$DNS_U" && ok "五-2: 对照域仍是 U=$DNS_U" || bad "五-2: $DNS_CALIB_WHY"
dns_expect "$DNS_CALIB_NAME" "$DNS_U" && ok "五-2b: 标定域($DNS_CALIB_NAME)也回到 U=$DNS_U" || bad "五-2b: $DNS_CALIB_WHY"
grep -q " q=$DNS_CONTROL " "$E2E_TMP/dns-up.log" 2>/dev/null \
  && ok "五-3: 对照域的答案确实来自自有上游(按名有记录)" || bad "五-3: 上游日志里没有对照域"
grep -q " q=$DNS_WITNESS " "$E2E_TMP/dns-up.log" 2>/dev/null \
  && bad "五-4: 见证域竟然问过上游 —— 与'接管优先'不符" || ok "五-4: 见证域**没有**问过上游(答案来自接管分支)"

echo; echo "══ 六. 正式取证 ══"
BEF="$(dns_feature_probe systemd-before)"
[[ "$BEF" == VALID* ]] && ok "六-1: 前像观测有效" || bad "六-1: 前像观测无效 —— $BEF"
systemctl restart "$OWN_UNIT" >/dev/null 2>&1
dns_ready "$DNS_WITNESS" "$DNS_H" || bad "六-2: 重启之后没能稳定就绪 —— $DNS_READY_WHY"
AFT="$(dns_feature_probe systemd-after)"
dns_verdict "六" "$BEF" "$AFT"

echo; echo "══ 七. 负控(**独立计账**: 在子 shell 里跑, 不动主计数)══"
systemctl stop "$OWN_UNIT" >/dev/null 2>&1
negctl bash -c 'true'   # 占位: 下面直接在子 shell 里取观测
D1="$(dns_feature_probe systemd-dead-1)"; D2="$(dns_feature_probe systemd-dead-2)"
[[ "$D1" == INVALID* && "$D2" == INVALID* ]] \
  && ok "七-1: 解析器停掉时两次取证都判 INVALID" || bad "七-1: 实得 $D1 / $D2"
( dns_verdict "七-负控" "$D1" "$D2" ) > "$NEG_OUT" 2>&1
grep -q '观测\*\*无效\*\*' "$NEG_OUT" \
  && ok "七-2: 两份**逐字相等**的无效观测仍以'观测无效'为由判红" \
  || { bad "七-2: 没有以观测无效为由判红"; sed 's/^/      /' "$NEG_OUT"; }
NEG_FAIL_SEEN="$(grep -c '^\[FAIL\]' "$NEG_OUT")"
(( NEG_FAIL_SEEN > 0 )) && ok "七-3: 负控自己确实产生了 $NEG_FAIL_SEEN 条失败, 但它跑在子 shell 里 —— 主计数未受影响" \
                        || bad "七-3: 负控没产生失败, 这一格没验到东西"
# 再起回来, 让收尾在一个正常现场上做
systemctl start "$OWN_UNIT" >/dev/null 2>&1
dns_ready "$DNS_WITNESS" "$DNS_H" >/dev/null 2>&1 || note "七: 负控之后服务没能再就绪(不影响上面的判据, 收尾照做)"

echo; echo "══ 八. 瞬时 active 的具名反例(与健康对照)══"
# 造一个"起来就退"的 unit: is-active 会有一瞬间是 active, 但它不是就绪。
PROBE_UNIT=pdg-dnsinst-flap-TESTONLY.service; PROBE_PATH="/etc/systemd/system/$PROBE_UNIT"
if [[ -e "$PROBE_PATH" ]]; then
  bad "八-0: $PROBE_PATH 本来就存在, 归属不明 —— 跳过这一格, 不覆盖现有对象"
else
  printf '[Unit]\nDescription=flap probe (this run only)\n[Service]\nExecStart=/bin/sh -c "sleep 0.3; exit 1"\nRestart=no\n' > "$PROBE_PATH"
  systemctl daemon-reload; systemctl start "$PROBE_UNIT" >/dev/null 2>&1
  ST_FLAP="$(systemctl is-active "$PROBE_UNIT" 2>/dev/null)"
  OWN_UNIT_SAVE="$OWN_UNIT"; OWN_UNIT="$PROBE_UNIT"
  DNS_READY_BUDGET=4
  if dns_ready "$DNS_WITNESS" "$DNS_H"; then
    bad "八-1: 一个起来就退的服务竟然被判成'稳定就绪'"
  else
    ok "八-1: 瞬时 is-active=$ST_FLAP 的崩溃服务**没有**被判成就绪 —— $DNS_READY_WHY"
  fi
  unset DNS_READY_BUDGET; OWN_UNIT="$OWN_UNIT_SAVE"
  systemctl stop "$PROBE_UNIT" >/dev/null 2>&1; rm -f "$PROBE_PATH"; systemctl daemon-reload
  [[ -e "$PROBE_PATH" ]] && bad "八-2: 反例 unit 没撤干净" || ok "八-2: 反例 unit 已撤除(本轮自建, 按路径收)"
fi
if dns_ready "$DNS_WITNESS" "$DNS_H"; then
  ok "八-3: 健康对照 —— 真正就绪的服务仍然判得过($DNS_READY_WHY)"
else
  bad "八-3: 健康对照没过 —— $DNS_READY_WHY"
fi

REACHED_END=1
