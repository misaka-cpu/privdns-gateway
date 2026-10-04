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

echo "══ D0 健康 ══"
timeout 30 systemctl enable --now "$U" >/dev/null 2>&1 || die "替身 enable --now 失败"
wait_for 15 owned || die "替身没在 15 s 内接管 5399"
chk D0 "健康 ⇒ 核验通过" "核验通过 —— 运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有" 0/0/0

echo "══ D1 真实 start-limit-hit ══"
: > "$RUN/fail"
timeout 30 systemctl restart "$U" >/dev/null 2>&1
if wait_for 40 is_slh; then
  ok "D1 注入命中: 真实 Result=start-limit-hit(NRestarts=$(prop NRestarts))"
  rm -f "$RUN/fail"
  chk D1 "start-limit-hit ⇒ 一次定向恢复后核验已恢复" "本次核验已恢复" 1/1/0
  is_active && owned && ok "D1b: 独立复核 —— 恢复后 active, 5399 的监听者在这个 unit 的 cgroup 里" \
    || bad "D1b: 独立复核不成立(ActiveState=$(prop ActiveState), 监听者 $(listen_pids | tr '\n' ' '))"
else
  rm -f "$RUN/fail"
  bad "D1 注入未命中: 40 s 内没有进 start-limit-hit(ActiveState=$(prop ActiveState) Result=$(prop Result)), 不判定恢复"
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
[[ "$nfail" == 0 ]]
