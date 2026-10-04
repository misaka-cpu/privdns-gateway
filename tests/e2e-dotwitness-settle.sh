#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 迁移链成功之后的 dotwitness 核验(_dw_settle)—— 真 systemd。
#
# 只在 CI 的 core-startlimit job 里跑: 要 root、PID 1 = systemd、能写 unit。本机只做语法与 ShellCheck。
# 用一个替身服务冒名 pdg-dotwitness(与生产 unit 同样的 StartLimitIntervalSec=300 / StartLimitBurst=5 /
# PartOf=mosdns.service / Restart=on-failure), 执行 pdg.sh 里按标记抽出的 _dw_settle 原文;
# systemctl / ss / /proc 全是真的, systemctl 外面只包一层记录(数动作次数), 调用照样落到真 systemctl。
#   D0 健康 ⇒ 核验通过, reset-failed / start 都是 0 次
#   D1 真实 start-limit-hit ⇒ reset-failed 1 次 + start 1 次, 恢复后 active、5399 归这个 unit 的 cgroup
#      (375: 对已核实健康的替身连续发正常 restart 触限, 不再用"进程秒退 + 自动重启"; D1 / D1b 只用核过退出码的读取,
#       并在 D1 开始 / 注入结束 / 恢复结束三处把状态、生效限额与本次启动内的 journal 原样留进日志)
#   D2 替身真起不来(drop-in 关掉自动重启, Result=exit-code)⇒ 不 reset、不 start, 报未就绪
#   D3 另一个进程先占住 5399、替身 active 却绑不上 ⇒ 报 5399 由别的进程持有, 不动作, 占用者不被杀
#   D4 disabled ⇒ 只报观察, 不启动、不改自启
#   D5 收尾之后不留 unit / 进程 / 端口
# 这里只证明"产品原文在真 systemd 上的判定与动作"; 不回答任何一次真实升级里故障从哪来。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
die(){ echo "[FAIL] $1"; echo "通过 $pass, 失败 $((nfail+1))"; exit 1; }

U=pdg-dotwitness
UF="/etc/systemd/system/$U.service"
DROP="/etc/systemd/system/$U.service.d"
RUN=/run/pdg-e2e-dws
[[ $EUID -eq 0 ]] || die "需要 root(CI 里用 sudo -E 运行)"
[[ "$(ps -p 1 -o comm=)" == systemd ]] || die "PID 1 不是 systemd"
[[ ! -e "$UF" && ! -e "$DROP" && ! -e "$RUN" ]] || die "$UF / $DROP / $RUN 已存在 —— 不覆盖别人的现场"
[[ "$(systemctl show "$U" -p LoadState --value 2>/dev/null)" == not-found ]] || die "$U 已被加载, 不在它上面做实验"
_ss0="$(ss -lun 2>/dev/null)" || die "ss 读不出来"
grep -q '127\.0\.0\.1:5399' <<< "$_ss0" && die "127.0.0.1:5399 已被占用"
ok "前提: root + 真 systemd + 没有同名 unit + 5399 空闲"

BOX="$(mktemp -d)"
HOLD=""
cleanup(){
  if [[ -n "$HOLD" ]]; then kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""; fi
  timeout 30 systemctl stop "$U" >/dev/null 2>&1
  timeout 30 systemctl disable "$U" >/dev/null 2>&1
  rm -f "$UF"; rm -rf "$DROP" "$RUN"
  timeout 30 systemctl daemon-reload >/dev/null 2>&1
  systemctl reset-failed "$U" >/dev/null 2>&1
  return 0
}
trap 'cleanup; rm -rf "$BOX"' EXIT

# ── 抽产品原文(成对标记各恰一处; 抽不到就不往下走) ───────────────────────────
BLK="$BOX/dws.sh"
[[ "$(grep -c '^# >>> dw-settle' "$PDG")" == 1 && "$(grep -c '^# <<< dw-settle$' "$PDG")" == 1 ]] || die "dw-settle 标记不是各恰一处"
awk '/^# >>> dw-settle/{f=1} f{print} /^# <<< dw-settle$/{f=0}' "$PDG" > "$BLK"
grep -q '^_dw_settle(){$' "$BLK" || die "抽出的原文里没有 _dw_settle"
grep -E '^c_[gy]\(\)\{.*\}$' "$PDG" > "$BOX/color.sh"
[[ "$(grep -c . "$BOX/color.sh")" == 2 ]] || die "c_g / c_y 取不到唯一原文"
ok "抽到 _dw_settle 原文 $(wc -l < "$BLK") 行"

# ── 替身服务 ─────────────────────────────────────────────────────────────────
# 有 $RUN/fail 就立刻以 3 退出(制造真实的启动失败); 否则绑 127.0.0.1:5399, 绑不上就一直重试
# (于是"服务 active 但端口在别人手里"是真实可达的状态, 不是伪造的输出)。
mkdir -p "$RUN"
cat > "$RUN/stand.py" <<'PYEOF'
import os, socket, sys, time
if os.path.exists("/run/pdg-e2e-dws/fail"):
    sys.exit(3)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
while True:
    try:
        s.bind(("127.0.0.1", 5399))
        break
    except OSError:
        time.sleep(0.5)
while True:
    time.sleep(3600)
PYEOF
cat > "$UF" <<'UEOF'
[Unit]
Description=pdg e2e: _dw_settle 用的 pdg-dotwitness 替身
PartOf=mosdns.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/usr/bin/python3 /run/pdg-e2e-dws/stand.py
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
UEOF
timeout 30 systemctl daemon-reload || die "daemon-reload 失败"

prop(){ systemctl show "$U" -p "$1" --value 2>/dev/null; }
wait_for(){ # $1=最多等几秒 其余=条件命令; 0.25 s 一次, 到点就返回 1
  local n=$(( $1 * 4 )) i=0; shift
  while (( i < n )); do "$@" && return 0; sleep 0.25; i=$((i+1)); done
  return 1
}
listen_pids(){ ss -lunp 2>/dev/null | grep '127\.0\.0\.1:5399' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }
owned(){ # 5399 的监听者里有一个在这个 unit 的 cgroup 里
  local cg p pc; cg="$(prop ControlGroup)"; [[ "$cg" == /* ]] || return 1
  for p in $(listen_pids); do
    pc="$(sed -n 's/^0:://p' "/proc/$p/cgroup" 2>/dev/null)"; [[ "$pc" == "$cg" ]] && return 0
  done
  return 1
}
is_active(){ [[ "$(prop ActiveState)" == active ]]; }
is_slh(){ [[ "$(prop ActiveState)" == failed && "$(prop Result)" == start-limit-hit ]]; }
is_exitfail(){ [[ "$(prop ActiveState)" == failed && "$(prop Result)" == exit-code ]]; }
held_by(){ local l; l="$(listen_pids)"; [[ $'\n'"$l"$'\n' == *$'\n'"$1"$'\n'* ]]; }

# 跑一次 _dw_settle 原文。$1=格。留下 out / log; 返回生成脚本的退出码。
settle(){
  local d="$BOX/$1"; mkdir -p "$d"; : > "$d/log"
  { echo 'set -uo pipefail'; printf 'LOG=%q\n' "$d/log"
    cat "$BOX/color.sh"
    echo 'systemctl(){ printf "%s\n" "$*" >> "$LOG"; command systemctl "$@"; }'
    cat "$BLK"
    echo '_dw_settle --after-migrate; echo "SETTLE_RC=$?"'; } > "$d/run.sh"
  timeout 60 bash "$d/run.sh" > "$d/out" 2>&1
}
acts(){ # reset-failed / start / 其它改状态的动作
  local l="$BOX/$1/log"
  printf '%s/%s/%s' "$(grep -cx "reset-failed $U" "$l")" "$(grep -cx "start $U" "$l")" \
    "$(grep -cE '^(enable|disable|restart|stop|kill|mask|unmask|reload)( |$)' "$l")"
}
chk(){ # $1=格 $2=说明 $3=期望文字 $4=期望动作
  local c="$1" rc
  settle "$c"; rc=$?
  if [[ "$rc" == 0 ]] && grep -q '^SETTLE_RC=0$' "$BOX/$c/out" && grep -qF -- "$3" "$BOX/$c/out" && [[ "$(acts "$c")" == "$4" ]]; then
    ok "$c: $2(动作 $(acts "$c"))"
  else
    bad "$c: $2 —— 退出 $rc, 动作 $(acts "$c")(期望 $4), 输出: $(grep -v '^SETTLE_RC' "$BOX/$c/out" | head -3)"
  fi
}

# ── D1 / D1b 专用: 核过退出码的读取、单调时钟预算与取证(其它格照旧用上面的 prop / owned) ────────
# 每个查询先看原始退出码: 124 = 超时, 125–127 = 执行器失败, 其它非 0 = 查询失败; 非 0 时已经输出的内容一概不采信;
# 输出每个键恰一行、没有多余的键、格式合规。注入阶段的命令与查询共用一个统一截止点(d1_budget, 单调时钟)。
# 取证文件留在脚本自己的 $BOX/evidence, 同时带明确边界原样打进日志(CI 只留得下日志)。查询码、stdout 读取码、
# stderr 读取码分别核: 空 stderr 合法, 读取失败不算空; 部分输出记不完整。缺口记"[证据缺口]"并计数,
# 不中断其它留证, 也不碰下面的自有清理。
EV="$BOX/evidence"; EVN=0; EVGAP=0; D1_INJ=0; MONO_LAST=""
ev_gap(){ EVGAP=$((EVGAP+1)); echo "[证据缺口] $1"; }
mkdir -p "$EV" || { EV="$BOX"; ev_gap "evidence: 取证目录建不出来, 改用 $BOX"; }
qrc_why(){ case "$1" in 124) echo "超时(124)" ;; 125|126|127) echo "执行器失败($1)" ;; *) echo "退出 $1" ;; esac; }
ev_cat(){ # 原样打出一个文件, 返回 cat 的退出码; 之后无条件输出 1 个分隔换行(协议字节, 不属于原文), 下一标记行因此总在行首
  local r; cat "$1"; r=$?
  echo
  return "$r"
}
ev_cmd(){ # $1=点 $2=项 其余=命令(最多 30 s); 结果落 $EV/<点>.<项>.{out,err} 并原样打到日志; 要求有输出
  local pt="$1" nm="$2" f rc orc erc; shift 2; EVN=$((EVN+1)); f="$EV/$pt.$nm"
  timeout 30 "$@" > "$f.out" 2> "$f.err"; rc=$?
  echo "===== BEGIN D1-EVIDENCE $pt/$nm ====="
  ev_cat "$f.out"; orc=$?
  echo "----- stderr -----"
  ev_cat "$f.err"; erc=$?
  echo "===== END D1-EVIDENCE $pt/$nm 查询=$rc stdout读取=$orc stderr读取=$erc ====="
  (( rc == 0 )) || ev_gap "$pt/$nm: 查询$(qrc_why "$rc"), 未取得 / 不完整"
  (( orc == 0 )) || ev_gap "$pt/$nm: stdout 读取失败(退出 $orc), 已打印的部分不完整"
  (( erc == 0 )) || ev_gap "$pt/$nm: stderr 读取失败(退出 $erc), 不等于没有 stderr"
  if (( rc == 0 && orc == 0 )) && [[ ! -s "$f.out" ]]; then ev_gap "$pt/$nm: 查询退出 0 但没有输出, 不完整"; fi
  return 0
}
ev_file(){ # $1=点 $2=项 $3=已有文件; 原样打到日志(空文件允许, 例如 restart 的 stdout)
  local pt="$1" nm="$2" f="$3" crc; EVN=$((EVN+1))
  echo "===== BEGIN D1-EVIDENCE $pt/$nm file ====="
  ev_cat "$f"; crc=$?
  echo "===== END D1-EVIDENCE $pt/$nm 读取=$crc ====="
  (( crc == 0 )) || ev_gap "$pt/$nm: 读取 $f 失败(退出 $crc), 已打印的部分不完整"
  return 0
}
ev_point(){ # $1=点: boot ID / systemd 版本 / 实际 unit 与 drop-in / 生效限额 / 状态 / 本次启动内该 unit 的 journal(不截行)
  ev_cmd "$1" boot-id cat /proc/sys/kernel/random/boot_id
  ev_cmd "$1" systemd-version systemctl --version
  ev_cmd "$1" unit systemctl cat "$U"
  ev_cmd "$1" limits systemctl show "$U" -p FragmentPath -p DropInPaths -p StartLimitIntervalUSec -p StartLimitBurst -p StartLimitAction -p Restart -p RestartUSec
  ev_cmd "$1" state systemctl show "$U" -p ActiveState -p SubState -p Result -p MainPID -p InvocationID -p NRestarts -p ExecMainCode -p ExecMainStatus -p ControlGroup
  ev_cmd "$1" journal journalctl -b -u "$U.service" --no-pager -o short-iso-precise
}
mono_ms(){ # 单调时钟(毫秒, 取 /proc/uptime): 核读取退出码与格式, 发现倒退判无效; 0=有效(MONO) 1=无效(MONO_WHY)
  local raw rc v
  raw="$(cat /proc/uptime)"; rc=$?
  if (( rc != 0 )); then MONO_WHY="读 /proc/uptime 退出 $rc(已输出的不采信)"; return 1; fi
  if ! [[ "$raw" =~ ^([0-9]+)\.([0-9]{2})\ [0-9]+\.[0-9]{2}$ ]]; then MONO_WHY="/proc/uptime 格式不对: ${raw:0:40}"; return 1; fi
  v=$(( 10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]} * 10 ))
  if [[ -n "$MONO_LAST" ]] && (( v < MONO_LAST )); then MONO_WHY="单调时钟倒退($MONO_LAST → $v ms)"; return 1; fi
  MONO_LAST=$v; MONO=$v; return 0
}
d1_budget(){ # 统一截止点 D1_DL_MS 的剩余预算; 0=还有(D1_LEFT = 剩余的小数秒, 毫秒精度, 不向上取整) 1=时钟无效 2=预算耗尽; 原因放 D1_BWHY
  if ! mono_ms; then D1_BWHY="时钟无效: $MONO_WHY"; return 1; fi
  local left=$(( D1_DL_MS - MONO ))
  if (( left <= 0 )); then D1_BWHY="40 s 注入预算耗尽"; return 2; fi
  D1_LEFT="$(( left / 1000 )).$(printf '%03d' $(( left % 1000 )))"; return 0
}
q_pre(){ # 每个外部查询启动前: 注入阶段取当时的剩余预算作自己的 timeout(QT), 已到期就不启动; D1b(注入阶段之外)固定 10 s
  if (( D1_INJ == 0 )); then QT=10; return 0; fi
  d1_budget || return 1
  QT="$D1_LEFT"; return 0
}
q_post(){ # 每个外部查询返回后: 注入阶段再核一次, 恰在截止点或之后返回的结果不采信
  (( D1_INJ == 0 )) && return 0
  d1_budget
}
vstate(){ # 一次有效状态读取(注入阶段用当时的剩余预算, 其外 10 s); 0=有效 1=查询失败 / 超时 / 执行器失败 2=输出无效; 值放 VS_*, 原因 VS_WHY, 原文 VS_RAW
  local raw rc line k v seen=" "
  VS_LOAD="" VS_UFS="" VS_ACT="" VS_SUB="" VS_RES="" VS_PID="" VS_INV="" VS_WHY="" VS_RAW=""
  if ! q_pre; then VS_WHY="状态查询未启动: $D1_BWHY"; return 1; fi
  raw="$(timeout "$QT" systemctl show "$U" -p LoadState -p UnitFileState -p ActiveState -p SubState -p Result -p MainPID -p InvocationID 2>/dev/null)"; rc=$?
  VS_RAW="$raw"
  if ! q_post; then VS_WHY="状态查询返回时: $D1_BWHY, 结果不采信"; return 1; fi
  if (( rc != 0 )); then VS_WHY="状态查询$(qrc_why "$rc")(已输出的不采信)"; return 1; fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" != ?*=* ]]; then VS_WHY="状态输出有无法解析的行"; return 2; fi
    k="${line%%=*}"; v="${line#*=}"
    if [[ "$seen" == *" $k "* ]]; then VS_WHY="状态输出里 $k 重复"; return 2; fi
    seen="$seen$k "
    case "$k" in
      LoadState) VS_LOAD="$v" ;; UnitFileState) VS_UFS="$v" ;; ActiveState) VS_ACT="$v" ;; SubState) VS_SUB="$v" ;;
      Result) VS_RES="$v" ;; MainPID) VS_PID="$v" ;; InvocationID) VS_INV="$v" ;;
      *) VS_WHY="状态输出多出未请求的键 $k"; return 2 ;;
    esac
  done <<< "$raw"
  for k in LoadState UnitFileState ActiveState SubState Result MainPID InvocationID; do
    if [[ "$seen" != *" $k "* ]]; then VS_WHY="状态输出缺 $k"; return 2; fi
  done
  if ! [[ "$VS_LOAD" =~ ^[a-z-]+$ && "$VS_ACT" =~ ^[a-z-]+$ && "$VS_SUB" =~ ^[a-z-]+$ && "$VS_RES" =~ ^[a-z-]+$ && "$VS_PID" =~ ^[0-9]+$ ]] \
     || ! [[ "$VS_UFS" =~ ^[a-z-]*$ && "$VS_INV" =~ ^([0-9a-f]{32})?$ ]]; then
    VS_WHY="状态取值不合格式"; return 2
  fi
  return 0
}
vowned(){ # 5399 归属的有效读取(每个外部查询各自取当时的剩余预算); 0=全部监听者都读到且至少一个归该 unit 1=读取无效 2=没有监听 3=全部读到但都不归它
  local raw rc line f hit rest p cg pc l match=0
  local -a fs pids=()
  VO_WHY="" VO_RAW=""
  if ! q_pre; then VO_WHY="ss 未启动: $D1_BWHY"; return 1; fi
  raw="$(timeout "$QT" ss -lunp 2>/dev/null)"; rc=$?; VO_RAW="$raw"
  if ! q_post; then VO_WHY="ss 返回时: $D1_BWHY, 结果不采信"; return 1; fi
  if (( rc != 0 )); then VO_WHY="ss $(qrc_why "$rc")(已输出的不采信)"; return 1; fi
  while IFS= read -r line; do
    read -ra fs <<< "$line"; hit=0
    for f in "${fs[@]}"; do [[ "$f" == 127.0.0.1:5399 ]] && hit=1; done
    (( hit )) || continue
    rest="$line"; p=""
    while [[ "$rest" =~ pid=([0-9]+) ]]; do p="${BASH_REMATCH[1]}"; pids+=("$p"); rest="${rest#*pid="$p"}"; done
    if [[ -z "$p" ]]; then VO_WHY="127.0.0.1:5399 的监听行里取不到 pid"; return 1; fi
  done <<< "$raw"
  if (( ${#pids[@]} == 0 )); then VO_WHY="127.0.0.1:5399 没有监听"; return 2; fi
  if ! q_pre; then VO_WHY="ControlGroup 查询未启动: $D1_BWHY"; return 1; fi
  cg="$(timeout "$QT" systemctl show "$U" -p ControlGroup --value 2>/dev/null)"; rc=$?
  VO_RAW="$VO_RAW"$'\n'"ControlGroup=$cg(退出 $rc)"
  if ! q_post; then VO_WHY="ControlGroup 查询返回时: $D1_BWHY, 结果不采信"; return 1; fi
  if (( rc != 0 )) || [[ "$cg" != /* ]]; then VO_WHY="ControlGroup 查询$(qrc_why "$rc")或取值不是路径(已输出的不采信)"; return 1; fi
  for p in "${pids[@]}"; do
    if ! raw="$(cat "/proc/$p/cgroup" 2>/dev/null)"; then VO_WHY="读不到 /proc/$p/cgroup"; return 1; fi
    pc=""; while IFS= read -r l; do [[ "$l" == 0::* ]] && pc="${l#0::}"; done <<< "$raw"
    if [[ -z "$pc" ]]; then VO_WHY="/proc/$p/cgroup 没有 0:: 行"; return 1; fi
    VO_RAW="$VO_RAW"$'\n'"pid $p cgroup=$pc"
    [[ "$pc" == "$cg" ]] && match=1
  done
  (( match )) && return 0
  VO_WHY="5399 的监听者都不在该 unit 的 cgroup 里"; return 3
}
vhealthy(){ # 0=健康且归属成立 1=读取无效 2=有效但还不健康; 原因放 VH_WHY
  local r
  vstate; r=$?
  if (( r != 0 )); then VH_WHY="$VS_WHY"; return 1; fi
  if [[ "$VS_LOAD" != loaded || "$VS_UFS" != enabled || "$VS_ACT" != active || "$VS_SUB" != running ]]; then
    VH_WHY="LoadState=$VS_LOAD UnitFileState=$VS_UFS ActiveState=$VS_ACT SubState=$VS_SUB"; return 2
  fi
  vowned; r=$?
  case $r in 0) return 0 ;; 1) VH_WHY="$VO_WHY"; return 1 ;; *) VH_WHY="$VO_WHY"; return 2 ;; esac
}
d1_wait_healthy(){ # 统一截止点前等到健康; 0=确认 1=读取无效 / 超时 / 时钟无效(立即停) 2=预算耗尽(含查询返回时已过截止)
  local r b
  while :; do
    d1_budget; b=$?
    if (( b != 0 )); then VH_WHY="$D1_BWHY"; return $(( b == 1 ? 1 : 2 )); fi
    vhealthy; r=$?
    d1_budget; b=$?
    if (( b == 1 )); then VH_WHY="$D1_BWHY"; return 1; fi
    if (( b == 2 )); then VH_WHY="健康查询返回时已过 40 s 截止, 结果不采信"; return 2; fi
    (( r == 0 )) && return 0
    (( r == 1 )) && return 1
    sleep 0.25
  done
}
wall_now(){ # 墙钟(只作日志, 不参与预算): 秒.9 位纳秒; 取不到或格式不对就输出 na 并返回 1(调用方记缺口, 不伪造时间)
  local w
  if w="$(date +%s.%N)" && [[ "$w" =~ ^[0-9]+\.[0-9]{9}$ ]]; then echo "$w"; return 0; fi
  echo na; return 1
}
req_add(){ # 请求记录一行(恰好 6 列): 序号 / 退出码 / 单调起 / 单调止(ms, 取不到写 na)/ 墙钟起 / 墙钟止(只作日志, 取不到写 na); 每次追加都核状态
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$EV/requests.tsv" || ev_gap "d1-inject-end/requests: 第 $1 次请求的记录追加失败"
}
req_check(){ # 注入结束后读回: 末行完整、行数 = 请求数; 每行恰好 6 列、序号 1..N、退出码 0–255、单调字段为 0 / 无前导零的十进制整数或 na(都是整数时按十进制比较止 ≥ 起: 先比长度, 等长再按 C 排序规则比字符串, 不做算术, 超长也不溢出)、墙钟字段 秒.9 位 或 na
  local f="$EV/requests.tsv" last rc i n tabs f1 f2 f3 f4 f5 f6 why
  local -a R=()
  if [[ ! -f "$f" || ! -r "$f" ]]; then ev_gap "d1-inject-end/requests: 请求记录不存在或不可读"; return 0; fi
  last="$(tail -c1 "$f")"; rc=$?
  if (( rc != 0 )); then ev_gap "d1-inject-end/requests: 读记录末字节退出 $rc"; return 0; fi
  [[ -z "$last" ]] || ev_gap "d1-inject-end/requests: 末行不完整(部分写入)"
  mapfile -t R < "$f"; rc=$?
  if (( rc != 0 )); then ev_gap "d1-inject-end/requests: 读回退出 $rc"; return 0; fi
  (( ${#R[@]} == D1_N )) || ev_gap "d1-inject-end/requests: 读回 ${#R[@]} 行, 应为 $D1_N 行(请求数)"
  for ((i = 0; i < ${#R[@]}; i++)); do
    n=$((i + 1)); tabs="${R[i]//[!$'\t']/}"; why=""
    if (( ${#tabs} != 5 )); then why="有 $(( ${#tabs} + 1 )) 列, 应为 6 列"
    else
      IFS='|' read -r f1 f2 f3 f4 f5 f6 <<< "${R[i]//$'\t'/|}"
      if [[ "$f1" != "$n" ]]; then why="序号是 ${f1:0:12}, 应为 $n"
      elif ! [[ "$f2" =~ ^[0-9]{1,3}$ ]] || (( 10#$f2 > 255 )); then why="退出码 ${f2:0:12} 不在 0–255"
      elif ! [[ "$f3" =~ ^(0|[1-9][0-9]*|na)$ && "$f4" =~ ^(0|[1-9][0-9]*|na)$ ]]; then why="单调字段不是 0、无前导零的十进制整数或 na(起 ${f3:0:24} / 止 ${f4:0:24})"
      elif [[ "$f3" != na && "$f4" != na ]] && { (( ${#f4} < ${#f3} )) || { (( ${#f4} == ${#f3} )) && ( export LC_ALL=C; [[ "$f4" < "$f3" ]] ); }; }; then why="单调止 ${f4:0:40} < 单调起 ${f3:0:40}"
      elif ! [[ "$f5" =~ ^([0-9]+\.[0-9]{9}|na)$ && "$f6" =~ ^([0-9]+\.[0-9]{9}|na)$ ]]; then why="墙钟字段不是 秒.9 位纳秒 或 na"
      fi
    fi
    if [[ -n "$why" ]]; then ev_gap "d1-inject-end/requests: 第 $n 行$why: ${R[i]:0:60}"; break; fi
  done
  return 0
}
acts_strict(){ # 动作记录: 一次读取后在内存里逐行计数(不依赖 grep 的返回码约定); 读不了 / 结构无效 ⇒ "未取得…" 并返回 1(不补零)
  local l="$BOX/$1/log" last rc line a=0 b=0 c=0
  local -a L=()
  if [[ ! -f "$l" || ! -r "$l" ]]; then echo "未取得(记录不存在或不可读)"; return 1; fi
  last="$(tail -c1 "$l")"; rc=$?
  if (( rc != 0 )); then echo "未取得(读记录末字节退出 $rc)"; return 1; fi
  if [[ -n "$last" ]]; then echo "未取得(记录末行不完整)"; return 1; fi
  mapfile -t L < "$l"; rc=$?
  if (( rc != 0 )); then echo "未取得(读记录退出 $rc)"; return 1; fi
  if (( ${#L[@]} == 0 )); then echo "未取得(记录为空)"; return 1; fi
  for line in "${L[@]}"; do
    case "$line" in
      "reset-failed $U") a=$((a+1)) ;;
      "start $U") b=$((b+1)) ;;
      "show $U "*) ;;
      enable*|disable*|restart*|stop*|kill*|mask*|unmask*|reload*|reset-failed*|start*) c=$((c+1)) ;;
      *) echo "未取得(记录里有无法识别的行: ${line:0:40})"; return 1 ;;
    esac
  done
  printf '%s/%s/%s' "$a" "$b" "$c"
}

echo "══ D0 健康 ══"
timeout 30 systemctl enable --now "$U" >/dev/null 2>&1 || die "替身 enable --now 失败"
wait_for 15 owned || die "替身没在 15 s 内接管 5399"
chk D0 "健康 ⇒ 核验通过" "核验通过 —— 运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有" 0/0/0

echo "══ D1 真实 start-limit-hit(对已核实健康的替身连续发正常 restart; 最多 6 次, 注入总预算 40 s)══"
# 374 用"进程秒退 + 自动重启"制造故障, 40 s 内只看到 failed / exit-code, 恢复分支没有被验收。这里改成对健康替身
# 连续发正常 restart: 成功的启动同样计入 StartLimitBurst(5 次 / 300 s; D0 的 enable --now 已算 1 次)。
# 只有"restart 退出 1(systemd 作业失败)且其后在截止前有效读到 failed + start-limit-hit"才算命中; 超时(124)、
# 执行器失败(125–127)、其它退出码、读取无效、时钟无效或越过截止, 都停止注入, 不再读状态判命中, 也不调用产品。
# 预算: 单调时钟(/proc/uptime)上的一个截止点, 注入开始时只设一次; 每个命令 / 查询前后都核, 返回时已过截止就不采信。
# 墙钟只写进请求记录作日志时间。注入中不 reset-failed、不改额度、不启第二轮。
echo "===== D1-EVIDENCE 协议: 每段原文之后紧跟 1 个分隔换行(不属于原文); 取原文 = 去掉恰好这 1 个换行, 不做 strip / rstrip ====="
ev_point d1-start
D1_N=0; D1_HIT=0; D1_STOP=""; D1_DL_MS=0
if mono_ms; then D1_DL_MS=$(( MONO + 40000 )); else D1_STOP="注入前时钟无效: $MONO_WHY"; fi
D1_INJ=1
: > "$EV/requests.tsv" || ev_gap "d1-inject-end/requests: 请求记录文件建不出来"
if [[ -z "$D1_STOP" ]]; then
  d1_wait_healthy; r=$?
  case $r in
    1) D1_STOP="注入前的状态 / 归属读取无效: $VH_WHY" ;;
    2) D1_STOP="注入前没能在预算内确认健康: $VH_WHY" ;;
  esac
fi
while [[ -z "$D1_STOP" && "$D1_HIT" == 0 ]]; do
  if (( D1_N >= 6 )); then D1_STOP="已发 6 次 restart, 仍没有观测到 start-limit-hit"; break; fi
  d1_budget; b=$?
  if (( b != 0 )); then D1_STOP="发第 $((D1_N + 1)) 次 restart 之前: $D1_BWHY"; break; fi
  m1=$MONO; w1="$(wall_now)" || ev_gap "d1-inject-end/requests: 第 $((D1_N + 1)) 次请求的墙钟起取不到, 记 na"
  if ! { : > "$EV/restart.$((D1_N + 1)).out" && : > "$EV/restart.$((D1_N + 1)).err"; }; then
    D1_STOP="第 $((D1_N + 1)) 次 restart 的输出文件建不出来, 没有发请求(执行无效)"; break
  fi
  D1_N=$((D1_N+1))
  timeout "$D1_LEFT" systemctl restart "$U" > "$EV/restart.$D1_N.out" 2> "$EV/restart.$D1_N.err"; rc=$?
  d1_budget; b=$?; m2=na; (( b == 1 )) || m2=$MONO
  w2="$(wall_now)" || ev_gap "d1-inject-end/requests: 第 $D1_N 次请求的墙钟止取不到, 记 na"
  req_add "$D1_N" "$rc" "$m1" "$m2" "$w1" "$w2"
  if (( b == 1 )); then D1_STOP="第 $D1_N 次 restart 返回后: $D1_BWHY"; break; fi
  if (( b == 2 )); then D1_STOP="第 $D1_N 次 restart 返回时已过 40 s 截止(退出 $rc), 结果不采信"; break; fi
  case "$rc" in
    0) d1_wait_healthy; r=$?
       case $r in
         1) D1_STOP="第 $D1_N 次 restart 之后状态 / 归属读取无效: $VH_WHY" ;;
         2) D1_STOP="第 $D1_N 次 restart 之后: $VH_WHY" ;;
       esac
       continue ;;
    124) D1_STOP="第 $D1_N 次 restart 超时(124): 命令超时不等于服务拒绝, 不再读状态判命中"; break ;;
    125|126|127) D1_STOP="第 $D1_N 次 restart 执行器失败($rc), 不当作服务拒绝"; break ;;
    1) ;;
    *) D1_STOP="第 $D1_N 次 restart 退出 $rc, 不是 systemd 作业失败的退出码 1"; break ;;
  esac
  vstate; r=$?
  d1_budget; b=$?
  if (( b == 1 )); then D1_STOP="第 $D1_N 次 restart 被拒后的状态读取返回时: $D1_BWHY"; break; fi
  if (( b == 2 )); then D1_STOP="第 $D1_N 次 restart 被拒后的状态读取返回时已过 40 s 截止, 结果不采信"; break; fi
  if (( r != 0 )); then D1_STOP="第 $D1_N 次 restart 退出 1, 随后的状态读取无效: $VS_WHY"
  elif [[ "$VS_ACT" == failed && "$VS_RES" == start-limit-hit ]]; then D1_HIT=1
  else D1_STOP="第 $D1_N 次 restart 退出 1, 状态 ActiveState=$VS_ACT Result=$VS_RES, 不是 start-limit-hit"; fi
done
D1_INJ=0
echo "注入阶段结束: 已发 $D1_N 次 restart, 命中=$D1_HIT; 40 s 是接受结果的截止点(单调时钟), 不是整个 D1 的结束时刻 —— 之后的停止、留证、D1b 与清理不受它约束, 也不会再发 restart"
ev_point d1-inject-end
req_check
ev_file d1-inject-end requests "$EV/requests.tsv"
for ((i = 1; i <= D1_N; i++)); do
  ev_file d1-inject-end "restart$i.stdout" "$EV/restart.$i.out"
  ev_file d1-inject-end "restart$i.stderr" "$EV/restart.$i.err"
done
if (( D1_HIT == 1 )); then
  ok "D1 注入命中: 第 $D1_N 次 restart 被拒(退出 1), 截止前有效读到 ActiveState=failed、Result=start-limit-hit"
  settle D1; src=$?
  a="$(acts_strict D1)"; ar=$?
  if [[ "$src" == 0 && "$ar" == 0 && "$a" == 1/1/0 ]] && grep -q '^SETTLE_RC=0$' "$BOX/D1/out" && grep -qF -- "本次核验已恢复" "$BOX/D1/out"; then
    ok "D1: start-limit-hit ⇒ 一次定向恢复后核验已恢复(动作 $a)"
  else
    bad "D1: start-limit-hit ⇒ 恢复没有按期望结算 —— 退出 $src, 动作 $a(期望 1/1/0), 输出: $(grep -v '^SETTLE_RC' "$BOX/D1/out" 2>/dev/null | head -3)"
  fi
  # D1b: 两次读取各自留返回码; 原文先置为"未执行", 没执行到的查询不能拿注入阶段的旧读数补齐
  VS_RAW="(D1b 状态读取未执行)"; VO_RAW="(D1b 监听 / 归属读取未执行)"; so=未执行
  vstate; sr=$?
  if (( sr != 0 )); then bad "D1b: 独立复核的读取无效, 不判恢复成立: $VS_WHY"
  elif [[ "$VS_LOAD" != loaded || "$VS_UFS" != enabled || "$VS_ACT" != active || "$VS_SUB" != running ]]; then
    bad "D1b: 独立复核不成立: LoadState=$VS_LOAD UnitFileState=$VS_UFS ActiveState=$VS_ACT SubState=$VS_SUB"
  else
    vowned; so=$?
    case $so in
      0) ok "D1b: 独立复核 —— 恢复后 loaded / enabled / active / running, 5399 的监听者在这个 unit 的 cgroup 里(读取都核过退出码)" ;;
      1) bad "D1b: 独立复核的读取无效, 不判恢复成立: $VO_WHY" ;;
      *) bad "D1b: 独立复核不成立: $VO_WHY" ;;
    esac
  fi
  ev_point d1-recover-end
  ev_file d1-recover-end settle-record "$BOX/D1/log"
  ev_file d1-recover-end settle-output "$BOX/D1/out"
  ev_cmd d1-recover-end d1b-state printf '%s\n' "$VS_RAW"
  (( sr == 0 )) || ev_gap "d1-recover-end/d1b-state: 上面的原文来自无效的状态读取($VS_WHY), 不完整"
  if [[ "$so" == 未执行 ]]; then ev_gap "d1-recover-end/d1b-listen: D1b 监听 / 归属读取未执行(前一步已不成立), 不拿旧读数补"
  else
    ev_cmd d1-recover-end d1b-listen printf '%s\n' "$VO_RAW"
    (( so != 1 )) || ev_gap "d1-recover-end/d1b-listen: 上面的原文来自无效的监听 / 归属读取($VO_WHY), 不完整"
  fi
else
  bad "D1 未观测到目标状态, 恢复分支未验收: $D1_STOP"
  echo "[未执行] D1b: 没有命中 start-limit-hit, 不调用 _dw_settle, 不复核"
  echo "[未执行] D1-EVIDENCE d1-recover-end: 不适用(未命中)"
fi

echo "══ D2 替身真起不来(不是限额) ══"
timeout 30 systemctl stop "$U" >/dev/null 2>&1; systemctl reset-failed "$U" >/dev/null 2>&1
mkdir -p "$DROP"; printf '[Service]\nRestart=no\n' > "$DROP/e2e-norestart.conf"
timeout 30 systemctl daemon-reload >/dev/null 2>&1
: > "$RUN/fail"
timeout 30 systemctl start "$U" >/dev/null 2>&1
if wait_for 15 is_exitfail; then
  chk D2 "failed 且 Result=exit-code ⇒ 不 reset、不 start" "未就绪(ActiveState=failed" 0/0/0
  is_exitfail && ok "D2b: 结束后仍是 failed / exit-code(没有被悄悄拉起来)" || bad "D2b: 状态被改了($(prop ActiveState)/$(prop Result))"
else
  bad "D2 注入未命中: 没有停在 failed / exit-code($(prop ActiveState)/$(prop Result))"
fi
rm -f "$RUN/fail"; rm -rf "$DROP"; timeout 30 systemctl daemon-reload >/dev/null 2>&1

echo "══ D3 5399 先被别的进程占住 ══"
systemctl reset-failed "$U" >/dev/null 2>&1
python3 -c 'import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 5399))
time.sleep(600)' & HOLD=$!
if wait_for 10 held_by "$HOLD"; then
  timeout 30 systemctl restart "$U" >/dev/null 2>&1
  if wait_for 15 is_active; then
    chk D3 "active 但 5399 在别人手里 ⇒ 不动作" "由别的进程持有" 0/0/0
    kill -0 "$HOLD" 2>/dev/null && held_by "$HOLD" && ok "D3b: 占用者还活着、仍持有 5399(本步不杀占用者)" || bad "D3b: 占用者没了"
  else bad "D3: 替身没进 active($(prop ActiveState)), 不判定"; fi
else bad "D3 注入未命中: 占位进程没拿到 5399"; fi
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""

echo "══ D4 disabled ══"
timeout 30 systemctl restart "$U" >/dev/null 2>&1
wait_for 15 owned || bad "D4 前提: 替身没重新接管 5399"
timeout 30 systemctl disable "$U" >/dev/null 2>&1
chk D4 "disabled ⇒ 只报观察" "本次观察到自启态 disabled" 0/0/0
[[ "$(prop UnitFileState)" == disabled ]] && ok "D4b: 自启状态没被改" || bad "D4b: 自启状态变成了 $(prop UnitFileState)"

echo "══ D5 收尾 ══"
cleanup
[[ "$(prop LoadState)" == not-found ]] && ok "D5a: unit 已不存在" || bad "D5a: unit 仍在($(prop LoadState))"
_ss1="$(ss -lun 2>/dev/null)" || bad "D5b: ss 读不出来, 不判定"
[[ -z "$(listen_pids)" && -n "$_ss1" ]] && ! grep -q '127\.0\.0\.1:5399' <<< "$_ss1" && ok "D5b: 5399 没有监听" || bad "D5b: 5399 仍在监听或读不出来"
pgrep -f "$RUN/stand.py" >/dev/null && bad "D5c: 替身进程残留" || ok "D5c: 没有替身进程残留"

T="$(cat "$BOX"/D*/out 2>/dev/null)"
grep -qE '用尽|本次升级的重启|原因是' <<< "$T" && bad "T: 报告里出现了原因推断" || ok "T: 报告里没有原因推断"
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
# 留证缺口与功能判定分开报告; 有缺口就不以 0 退出, 不拿缺证据的运行冒充完整通过。
echo "留证: 共 $EVN 项, 未取得/不完整 $EVGAP 项"
[[ "$nfail" == 0 && "$EVGAP" == 0 ]]
