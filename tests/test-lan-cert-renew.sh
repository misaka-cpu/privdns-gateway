#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 面板证书的续期: pdg-lan-cert.timer → `pdg lan renew` → acme.sh --cron → 让反代用上盘上那张。
#
# 为什么要有这一支: 面板证书由钉死的 acme.sh 签, 而安装只 git clone 它, 从来没跑过它的
# `--install`(那一步才装 cron)。于是**根本没有东西去续期** —— jp 上证书 08-24 签、acme 记的
# 续期时刻 10-22, 到 11-07 一次都没跑过; 那台机器连 cron 服务都没装。补上的是一个 systemd
# 定时器, 和一个"续完当场握手比一比"的收敛: acme.sh 续期时跑的是签发那天记下的 reloadcmd,
# 旧版记的是 reload 加 `|| true`(admin off 下必败、又被吞掉), 所以不能信它。
#
# 反代用的是**真的 TLS 服务端**(openssl s_server)扮演 Caddy: 它启动时读一次证书、之后一直
# 拿着内存里那张 —— 与 Caddy 不重启就不换证书是同一个形态。systemctl 桩的 restart pdg-lan
# 会按盘上的证书重新拉起它(stale 注入时按冻结的旧证书拉起, 扮演"重启了也没换上")。
# 判据一律看**握手拿到的那张**, 不看谁打印了什么。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
WORK="$(mktemp -d)"
SPID_FILE="$WORK/s_server.pid"
cleanup(){ [[ -s "$SPID_FILE" ]] && kill "$(cat "$SPID_FILE")" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
pass=0; nfail=0
ok(){  echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
finish(){ echo "─────────────────────────────────────────────"; echo "通过 $pass, 失败 $nfail"; [[ "$nfail" == 0 ]]; exit $?; }

command -v openssl >/dev/null 2>&1 || { bad "没有 openssl —— 这一支要真 TLS 握手, 不能跳过"; finish; }

# ── 证书: 旧(盘上 / 内存里的那张)、新(acme 续出来的)、临期(5 天) ─────────────
mkpem(){   # $1=目录 $2=天数
  mkdir -p "$1"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$1/panel.key" -out "$1/panel.crt" -days "$2" -subj "/CN=lan.test" \
    -addext "subjectAltName=DNS:a.lan.test,DNS:b.lan.test" >/dev/null 2>&1 \
    && [[ -s "$1/panel.crt" && -s "$1/panel.key" ]]
}
mkpem "$WORK/pem-old" 30 && mkpem "$WORK/pem-new" 90 && mkpem "$WORK/pem-soon" 5 \
  || { bad "造不出测试证书"; finish; }
fp(){ openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^[^=]*=//'; }
FP_OLD="$(fp "$WORK/pem-old/panel.crt")"; FP_NEW="$(fp "$WORK/pem-new/panel.crt")"
[[ -n "$FP_OLD" && -n "$FP_NEW" && "$FP_OLD" != "$FP_NEW" ]] || { bad "测试证书指纹取不出来或相同"; finish; }

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# ── 闭包: 生产函数原样抽出来(夹具处理单行函数与漏抽) ─────────────────────────
LAN_FX_SRC="$PDG"
# shellcheck source=tests/lan-fixture.sh
source "$ROOT/tests/lan-fixture.sh"
C="$WORK/closure.sh"
lan_fx_emit "$C" _pdg_timer_next_ok _kernel_host _platform_html \
  _lan_cert_fp _lan_served_fp _lan_cert_timer_install _lan_cert_timer_remove _lan_renew \
  migrate_lan_cert_timer || { bad "抽不出被测函数"; finish; }
# _kf 是发 Telegram 的出口(kernelfollow.py notify): 沙箱里只记下发了什么。
echo '_kf(){ printf "%s\n" "$*" >> "$FX_ROOT/notify.log"; }' >> "$C"
bash -n "$C" || { bad "闭包语法坏了 —— 后面所有断言都不作数"; finish; }

# ── 沙箱 ──────────────────────────────────────────────────────────────────────
W="$WORK/fx"
LAN_FX_PEM_DIR="$WORK/pem-old" lan_fx_sandbox "$W" || { bad "夹具沙箱建不起来"; finish; }
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" "pa:a.lan.test:192.168.50.10:80" "pb:b.lan.test:192.168.50.11:80"
mkdir -p "$W/opt/pdg-acme/data" "$W/frozen"
cp "$WORK/pem-old/panel.crt" "$WORK/pem-old/panel.key" "$W/frozen/"

# acme.sh 替身: 按 state/acme-mode 演 skip / renew / renew-restart / fail。renew 时像真 acme.sh 一样**覆盖写**
# 装好的两个文件, 然后跑签发那天记下的旧 reloadcmd —— 它什么都没换成(admin off 下必败、被吞)。
cat > "$W/opt/pdg-acme/acme.sh" <<'STUB'
#!/usr/bin/env bash
echo "acme.sh $* CF_Token=${CF_Token:-<unset>}" >> "$FX_ROOT/calls.log"
case "$(cat "$FX_ROOT/state/acme-mode" 2>/dev/null)" in
  renew) cat "$FX_ROOT/pem-next/panel.crt" > "$LAN_CERT_DIR/panel.crt"
         cat "$FX_ROOT/pem-next/panel.key" > "$LAN_CERT_DIR/panel.key"
         echo "Reload successful"; exit 0;;
  # 新记录的 reloadcmd(systemctl restart pdg-lan)的样子: 旧进程立刻没了, 新进程过一会儿才听。
  # pdg-lan 是 simple 型 unit, restart 一返回就算 active —— 这段空窗里握手拿不到证书。
  renew-restart)
         cat "$FX_ROOT/pem-next/panel.crt" > "$LAN_CERT_DIR/panel.crt"
         cat "$FX_ROOT/pem-next/panel.key" > "$LAN_CERT_DIR/panel.key"
         # shellcheck source=/dev/null
         source "$FX_ROOT/caddy.sh"
         kill "$(cat "$SPID_FILE")" 2>/dev/null
         ( sleep 2; caddy_start "$LAN_CERT_DIR" ) < /dev/null > /dev/null 2>&1 &
         echo "Reload successful"; exit 0;;
  fail)  echo "Error renewing a.lan.test" >&2; exit 1;;
  *)     echo "Skipping. Next renewal time is: 2099-01-01"; exit 0;;
esac
STUB
chmod 755 "$W/opt/pdg-acme/acme.sh"

# "Caddy": 起一个 s_server, 读一次证书后一直拿着内存里那张。
caddy_start(){   # $1=证书目录
  [[ -s "$SPID_FILE" ]] && { kill "$(cat "$SPID_FILE")" 2>/dev/null; wait "$(cat "$SPID_FILE")" 2>/dev/null; }
  # -www: 不读 stdin(普通模式下 stdin 一到 EOF 它就可能收工), 每次握手完继续等下一个连接
  openssl s_server -quiet -www -accept "127.0.0.1:$PORT" -cert "$1/panel.crt" -key "$1/panel.key" \
    < /dev/null > /dev/null 2>&1 &
  echo $! > "$SPID_FILE"
  local n=0
  while (( n < 50 )); do
    timeout 3 openssl s_client -connect "127.0.0.1:$PORT" < /dev/null > /dev/null 2>&1 && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
served(){ timeout 5 openssl s_client -connect "127.0.0.1:$PORT" -servername a.lan.test < /dev/null 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//'; }

# systemctl 桩: pdg-lan 的 active 看 state/active; restart pdg-lan 真的重拉 "Caddy"。
# 定时器的 enabled / active / 有没有下一次触发都按状态派生, 不返回恒定的"健康"。
cat > "$W/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FX_CALLS"
S="$FX_ROOT/state"
case "$1" in
  is-active)
    shift; [[ "${1:-}" == --quiet ]] && shift
    case "$1" in
      pdg-lan)  [[ -e "$S/active" ]] && { echo active; exit 0; }; echo inactive; exit 3;;
      *.timer)  [[ -e "$S/timer-active" ]] && { echo active; exit 0; }; echo inactive; exit 3;;
    esac; echo inactive; exit 3;;
  is-enabled)
    [[ -e "$S/timer-enabled" ]] && { echo enabled; exit 0; }
    [[ -e "$FX_TIMER" ]] && { echo disabled; exit 1; }; echo not-found; exit 4;;
  enable)  [[ -e "$S/enable-fails" ]] && exit 1; touch "$S/timer-enabled"; exit 0;;
  disable) rm -f "$S/timer-enabled" "$S/timer-active" "$S/timer-armed"; exit 0;;
  daemon-reload) [[ -e "$S/reload-fails" ]] && exit 1; exit 0;;
  restart)
    case "$2" in
      pdg-lan)
        [[ -e "$S/restart-fails" ]] && exit 1
        if [[ -e "$S/stale" ]]; then src="$FX_ROOT/frozen"; else src="$(dirname "$LAN_CERT_DIR/x")"; fi
        bash -c "source '$FX_ROOT/caddy.sh'; caddy_start '$src'" || exit 1
        touch "$S/active"; exit 0;;
      *.timer)
        [[ -e "$S/timer-dead" ]] || touch "$S/timer-armed"
        touch "$S/timer-active"; exit 0;;
    esac; exit 0;;
  show)
    # _pdg_timer_next_ok 问 NextElapseUSecMonotonic / Realtime: 排得出下一次才给有限值
    [[ -e "$S/timer-armed" ]] && { echo "1h 2min"; exit 0; }; echo infinity; exit 0;;
  *) exit 0;;
esac
STUB
chmod 755 "$W/bin/systemctl"
# 桩里重拉 "Caddy" 要用同一份函数: 写成可 source 的文件
{ declare -p PORT SPID_FILE; declare -f caddy_start; } > "$W/caddy.sh"

lan_fx_bind "$W" "$ROOT"
cp -r "$WORK/pem-new" "$W/pem-next"
LAN_CERT_SVC="$W/etc/systemd/system/pdg-lan-cert.service"
LAN_CERT_TIMER="$W/etc/systemd/system/pdg-lan-cert.timer"
LAN_LISTEN="127.0.0.1:$PORT"
FX_TIMER="$LAN_CERT_TIMER"
export LAN_CERT_SVC LAN_CERT_TIMER LAN_LISTEN FX_TIMER

keep_notify(){ [[ -s "$W/notify.log" ]] && cat "$W/notify.log" >> "$WORK/notify-all.log"; true; }
reset_case(){   # 每一格从同一个前像开始: 盘上旧证书、Caddy 拿着旧证书、反代在跑
  keep_notify     # 上一格发出的通知留一份, 最后统一核 Telegram 能不能收(HTML)
  cp "$WORK/pem-old/panel.crt" "$WORK/pem-old/panel.key" "$LAN_CERT_DIR/"
  rm -f "$W/state/"* "$W/notify.log"; : > "$FX_CALLS"
  cp -r "$WORK/pem-new/." "$W/pem-next/"
  touch "$W/state/active"
  caddy_start "$W/frozen" || { bad "\"Caddy\" 起不来(端口 $PORT)"; finish; }
}
run(){   # 在子 shell 里跑被测函数, 打印输出, 返回它的退出码; 输出另记进 run.log 给 127 守卫看
  local f="$WORK/last.out" rc
  ( set +e
    # shellcheck source=/dev/null
    source "$C"
    "$@" ) > "$f" 2>&1
  rc=$?
  cat "$f" >> "$WORK/run.log"; cat "$f"
  return "$rc"
}
calls(){ grep -c -- "$1" "$FX_CALLS" 2>/dev/null; true; }

# ══ ① unit 的形态 ══════════════════════════════════════════════════════════════
# shellcheck source=lib/units.sh
source "$ROOT/lib/units.sh"
svc="$(pdg_unit_lan_cert_service)"; tmr="$(pdg_unit_lan_cert_timer)"
grep -qx 'Type=oneshot' <<<"$svc" && grep -qx 'ExecStart=/usr/local/bin/pdg lan renew --notify' <<<"$svc" \
  && ok "service: oneshot, ExecStart = pdg lan renew --notify" || bad "service 形态不对: $svc"
grep -qx 'ExecCondition=/usr/local/bin/pdg lan renew --supported' <<<"$svc" \
  && ok "service: ExecCondition 认子命令(回滚到旧版后残留的定时器只跳过, 不每天报失败)" \
  || bad "service 缺 ExecCondition —— 回滚到旧版后它会每天失败一次"
grep -qE '^OnCalendar=' <<<"$tmr" && grep -qx 'Persistent=true' <<<"$tmr" && grep -qx 'WantedBy=timers.target' <<<"$tmr" \
  && ok "timer: OnCalendar + Persistent(关机错过的那次开机补跑) + WantedBy=timers.target" || bad "timer 形态不对: $tmr"
grep -qiE 'cron' <<<"$svc$tmr" && bad "unit 里出现了 cron —— 续期不能靠 cron(jp 上连 cron 服务都没有)" \
  || ok "unit 不依赖 cron"
if command -v systemd-analyze >/dev/null 2>&1; then
  printf '%s\n' "$tmr" > "$WORK/pdg-lan-cert.timer"
  if systemd-analyze calendar "$(sed -n 's/^OnCalendar=//p' <<<"$tmr")" >/dev/null 2>&1; then
    ok "OnCalendar 被 systemd 自己认得($(sed -n 's/^OnCalendar=//p' <<<"$tmr"))"
  else bad "systemd-analyze calendar 不认这个 OnCalendar"; fi
fi

# ── 旧版残留: 新版 `renew --supported` 必须 0, 而且不需要 root、不碰 acme ───────
reset_case
out="$(run _lan_renew --supported 2>&1)"; rc=$?
[[ "$rc" == 0 && -z "$out" && "$(calls 'acme.sh')" == 0 ]] && ok "renew --supported → 0, 不出声、不调 acme.sh" \
  || bad "renew --supported: rc=$rc out=$out"
out="$(run _lan_renew --bogus 2>&1)"; rc=$?
[[ "$rc" == 2 && "$(calls 'acme.sh')" == 0 ]] && ok "未知参数 → 2, 不调 acme.sh" || bad "未知参数: rc=$rc out=$out"

# ══ ② 定时器的装 / 刷新 / 拆 ══════════════════════════════════════════════════
reset_case
out="$(run _lan_cert_timer_install 2>&1)"; rc=$?
if [[ "$rc" == 0 && -s "$LAN_CERT_SVC" && -s "$LAN_CERT_TIMER" && -e "$W/state/timer-enabled" && -e "$W/state/timer-armed" ]]; then
  ok "首次安装: 两个 unit 落盘、enable、启动并排出下一次触发"
else bad "首次安装: rc=$rc out=$out"; fi
cmp -s "$LAN_CERT_SVC" <(pdg_unit_lan_cert_service) && cmp -s "$LAN_CERT_TIMER" <(pdg_unit_lan_cert_timer) \
  && ok "落盘内容 = lib/units.sh 的生成函数" || bad "落盘内容与生成函数不一致"
[[ "$(stat -c %a "$LAN_CERT_TIMER")" == 644 ]] && ok "unit 权限 644" || bad "unit 权限是 $(stat -c %a "$LAN_CERT_TIMER")"

: > "$FX_CALLS"; m0="$(stat -c %Y.%i "$LAN_CERT_TIMER")"
out="$(run _lan_cert_timer_install 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(calls 'restart pdg-lan-cert.timer')" == 0 && "$(calls daemon-reload)" == 0 && "$m0" == "$(stat -c %Y.%i "$LAN_CERT_TIMER")" ]] \
  && ok "再装一次(内容没变、状态正常): 一个字节不写, 不 reload、不重启" || bad "幂等: rc=$rc 调用=$(tr '\n' ';' < "$FX_CALLS")"

echo "# 改过" >> "$LAN_CERT_TIMER"; : > "$FX_CALLS"
out="$(run _lan_cert_timer_install 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(calls daemon-reload)" == 1 && "$(calls 'restart pdg-lan-cert.timer')" == 1 ]] && cmp -s "$LAN_CERT_TIMER" <(pdg_unit_lan_cert_timer) \
  && ok "盘上内容被改过 → 重写、daemon-reload、重新 arm" || bad "内容漂移: rc=$rc 调用=$(tr '\n' ';' < "$FX_CALLS")"

rm -f "$W/state/timer-armed"; : > "$FX_CALLS"
out="$(run _lan_cert_timer_install 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(calls 'restart pdg-lan-cert.timer')" == 1 && -e "$W/state/timer-armed" ]] \
  && ok "内容没变但排不出下一次(elapsed+infinity 死角) → 重新 arm" || bad "死角: rc=$rc out=$out"

rm -f "$W/state/timer-armed"; touch "$W/state/timer-dead"
out="$(run _lan_cert_timer_install 2>&1)"; rc=$?
[[ "$rc" != 0 && "$out" == *"排不出下一次触发"* ]] && ok "重启后仍排不出下一次 → 失败并点名" || bad "排不出: rc=$rc out=$out"
rm -f "$W/state/timer-dead"

rm -f "$LAN_CERT_TIMER" "$LAN_CERT_SVC"; touch "$W/state/reload-fails"
out="$(run _lan_cert_timer_install 2>&1)"; rc=$?
[[ "$rc" != 0 && "$out" == *"daemon-reload 失败"* ]] && ok "daemon-reload 失败 → 失败, 不报装好了" || bad "reload 失败: rc=$rc out=$out"
rm -f "$W/state/reload-fails"

run _lan_cert_timer_install >/dev/null 2>&1
out="$(run _lan_cert_timer_remove 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$LAN_CERT_TIMER" && ! -e "$LAN_CERT_SVC" && ! -e "$W/state/timer-enabled" ]] \
  && ok "拆: disable --now、两个文件都删" || bad "拆: rc=$rc"
: > "$FX_CALLS"; run _lan_cert_timer_remove >/dev/null 2>&1
[[ "$(calls systemctl)" == 0 ]] && ok "本来就没有 → 拆的时候什么都不做" || bad "空拆也调了 systemctl"

# ══ ③ 存量机器的迁移 ════════════════════════════════════════════════════════════
reset_case; rm -f "$LAN_CERT_TIMER" "$LAN_CERT_SVC"
mv "$ACME_HOME/acme.sh" "$WORK/acme.sh.away"
out="$(run migrate_lan_cert_timer 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$LAN_CERT_TIMER" ]] && ok "迁移: 证书不是本项目签的(没有 acme.sh) → 不装" || bad "迁移(无 acme): rc=$rc"
mv "$WORK/acme.sh.away" "$ACME_HOME/acme.sh"
out="$(run migrate_lan_cert_timer 2>&1)"; rc=$?
[[ "$rc" == 0 && -s "$LAN_CERT_TIMER" && -e "$W/state/timer-armed" && "$out" == *"补上了"* ]] \
  && ok "迁移: 签过证书的存量机器 → 补装并说一声" || bad "迁移: rc=$rc out=$out"
rm -f "$W/state/active"      # 面板停用着也要装: 证书照样该续
rm -f "$LAN_CERT_TIMER" "$LAN_CERT_SVC" "$W/state/timer-"*
out="$(run migrate_lan_cert_timer 2>&1)"; rc=$?
[[ "$rc" == 0 && -s "$LAN_CERT_TIMER" ]] && ok "迁移: 面板停用着也补装(重新 enable 时证书不会已过期)" || bad "迁移(停用): rc=$rc"
out="$(run migrate_lan_cert_timer 2>&1)"; rc=$?
[[ "$rc" == 0 && "$out" != *"补上了"* ]] && ok "迁移: 已经装好 → 不重复报" || bad "迁移(重复): out=$out"
# 迁移不在更新里顺手续一次(会撞上更新后的 doctor 校验门): 一次都不该调 acme.sh
[[ "$(calls 'acme.sh')" == 0 ]] && ok "迁移不调 acme.sh、不重启反代" || bad "迁移里调了 acme.sh"

# ══ ④ 续期与收敛 ══════════════════════════════════════════════════════════════
# 正控: 前像确实是"Caddy 拿着旧证书"
reset_case
[[ "$(served)" == "$FP_OLD" ]] && ok "前像: \"Caddy\" 给出的是旧证书" || bad "前像不对, 后面都不作数"

# 4a 没到续期时刻: acme.sh 什么都不做, 反代给出的就是盘上那张 → 不重启、不通知
reset_case; echo skip > "$W/state/acme-mode"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$(calls 'restart pdg-lan$')" == 0 && ! -s "$W/notify.log" && "$out" == *"还不到续期时间"* && "$(calls 'acme.sh --home')" == 1 ]]; then
  ok "没到续期时刻 → rc 0, 不重启反代, 不发通知"
else bad "4a: rc=$rc out=$out 调用=$(tr '\n' ';' < "$FX_CALLS")"; fi
grep -q -- "acme.sh --home $ACME_HOME/data --cron" "$FX_CALLS" && ok "acme.sh 的调用是 --home <data> --cron" \
  || bad "acme.sh 调用形态不对: $(grep acme.sh "$FX_CALLS")"
# 凭据文件不是 600 root(沙箱里属主是当前用户)→ 不读它, 交给 acme.sh 存下的那份
grep -q 'CF_Token=<unset>' "$FX_CALLS" && ok "dns.env 不是 600 root → 不读(不把它的值带进 acme.sh)" || bad "读了一份属主不对的凭据"

# 4b 真机上出过的那个形态: 续出了新证书, 旧 reloadcmd 什么都没换 → 必须握手发现并重启
reset_case; echo renew > "$W/state/acme-mode"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$(served)" == "$FP_NEW" && "$(calls 'restart pdg-lan$')" == 1 ]]; then
  ok "续出新证书 + 反代还拿着旧的 → 重启一次, 握手拿到的变成新证书"
else bad "4b: rc=$rc served=$(served) out=$out"; fi
[[ "$out" == *"已续期"* && "$out" == *"已重启"* ]] && grep -q '已续期' "$W/notify.log" \
  && ok "续期成功 → 说清楚并发 Telegram" || bad "4b 通知: out=$out notify=$(cat "$W/notify.log" 2>/dev/null)"

# 4c 不带 --notify(手工跑): 同样收敛, 但不发 Telegram
reset_case; echo renew > "$W/state/acme-mode"
out="$(run _lan_renew 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(served)" == "$FP_NEW" && ! -s "$W/notify.log" ]] && ok "手工跑(不带 --notify) → 收敛, 不发通知" || bad "4c: rc=$rc"

# 4d 盘上早就是新的、内存里还是旧的(不管怎么来的) → 没续也要收敛
reset_case; cp "$WORK/pem-new/panel.crt" "$WORK/pem-new/panel.key" "$LAN_CERT_DIR/"; echo skip > "$W/state/acme-mode"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(served)" == "$FP_NEW" && "$out" == *"还在用旧证书"* ]] && grep -q '已重启' "$W/notify.log" \
  && ok "没续期但反代内存里是旧证书 → 重启收敛并通知" || bad "4d: rc=$rc out=$out"

# 4e acme.sh 失败 → 非 0(定时器那次记 failed)、点名、发通知; 反代给出的仍是盘上那张就不重启
reset_case; echo fail > "$W/state/acme-mode"
caddy_start "$LAN_CERT_DIR" || bad "\"Caddy\" 起不来"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
[[ "$rc" == 1 && "$out" == *"续期失败"* && "$(calls 'restart pdg-lan$')" == 0 ]] && grep -q '续期失败' "$W/notify.log" \
  && ok "acme.sh 失败 → rc 1, 点名并通知, 不乱重启" || bad "4e: rc=$rc out=$out"

# 4f 重启了也没换上(stale 注入) → 不许报成功
reset_case; echo renew > "$W/state/acme-mode"; touch "$W/state/stale"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
[[ "$rc" == 1 && "$out" == *"仍不是盘上那张"* ]] && grep -q '仍不是盘上那张' "$W/notify.log" \
  && ok "重启后握手仍是旧证书 → rc 1 并点名(不信重启的返回码)" || bad "4f: rc=$rc out=$out"

# 4g 重启失败
reset_case; echo renew > "$W/state/acme-mode"; touch "$W/state/restart-fails"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
[[ "$rc" == 1 && "$out" == *"重启失败"* ]] && ok "反代重启失败 → rc 1 并点名" || bad "4g: rc=$rc out=$out"

# 4h 反代没在跑: 续期照做, 不握手、不重启(下次启动读的就是盘上的)
reset_case; rm -f "$W/state/active"; echo renew > "$W/state/acme-mode"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(calls 'restart pdg-lan$')" == 0 && "$(fp "$LAN_CERT_DIR/panel.crt")" == "$FP_NEW" ]] \
  && ok "反代没在跑 → 照样续, 不重启" || bad "4h: rc=$rc out=$out"

# 4i acme.sh 说没事, 可证书已经进了 14 天 → 不能安静
reset_case; cp "$WORK/pem-soon/panel.crt" "$WORK/pem-soon/panel.key" "$LAN_CERT_DIR/"; echo skip > "$W/state/acme-mode"
caddy_start "$LAN_CERT_DIR" || bad "\"Caddy\" 起不来"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
[[ "$rc" == 1 && "$out" == *"14 天内"* ]] && grep -q '14 天内' "$W/notify.log" \
  && ok "没续、但已进 14 天 → rc 1 并通知" || bad "4i: rc=$rc out=$out"
# 这条正文带着「<dns插件名>」: 终端里照原文, 发给 Telegram 的必须转义(否则整条 400 拒收, 一条都收不到)
[[ "$out" == *"sudo pdg lan cert <dns插件名>"* ]] && grep -qF 'sudo pdg lan cert &lt;dns插件名&gt;' "$W/notify.log" \
  && ! grep -qF '<dns插件名>' "$W/notify.log" \
  && ok "4i: 终端里是原文 <dns插件名>, 发给 Telegram 的转义成 &lt;dns插件名&gt;" \
  || bad "4i 转义: out=$out notify=$(cat "$W/notify.log" 2>/dev/null)"

# 4j 不是本项目签的证书 / 还没签: 不归这里管
reset_case; mv "$ACME_HOME/acme.sh" "$WORK/acme.sh.away"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
[[ "$rc" == 0 && "$out" == *"不归这里续"* && "$(calls 'restart pdg-lan$')" == 0 && ! -s "$W/notify.log" ]] \
  && ok "没有 acme.sh → 不归这里续, rc 0" || bad "4j: rc=$rc out=$out"
mv "$WORK/acme.sh.away" "$ACME_HOME/acme.sh"

# ── 握手没拿到证书 ≠ 反代拿着旧证书 ────────────────────────────────────────────
# pdg-lan 是 simple 型 unit: restart 一返回就算 active, Caddy 这时可能还没在听。这几格让
# "Caddy" 在 active 的同时暂时不应答, 看 renew 会不会把"还没起来"当成"还拿着旧证书"。
caddy_stop(){ [[ -s "$SPID_FILE" ]] && { kill "$(cat "$SPID_FILE")" 2>/dev/null; wait "$(cat "$SPID_FILE")" 2>/dev/null; }; true; }

# 4k 续期当天的真实形态: acme.sh 续完按新 reloadcmd 重启了反代, 新进程 2 秒后才听 →
#    等它起来、握手拿到新证书, 不再多重启一次, 也不说"还在用旧证书"
reset_case; echo renew-restart > "$W/state/acme-mode"
out="$(run _lan_renew --notify 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$(served)" == "$FP_NEW" && "$(calls 'restart pdg-lan$')" == 0 \
      && "$out" == *"已续期"* && "$out" != *"已重启"* && "$out" != *"旧证书"* ]] \
   && grep -q '已续期' "$W/notify.log" && ! grep -q '已重启' "$W/notify.log"; then
  ok "续完反代刚重启、还没在听 → 等它起来再比, 不多重启、不误报旧证书"
else bad "4k: rc=$rc served=$(served) 重启=$(calls 'restart pdg-lan$') out=$out notify=$(cat "$W/notify.log" 2>/dev/null)"; fi

# 4l 没续, 反代在跑但这会儿还没在听(开机时 Persistent 补跑比反代先到), 2 秒后自己起来 → 安静收工
reset_case; echo skip > "$W/state/acme-mode"; caddy_stop
( sleep 2; caddy_start "$LAN_CERT_DIR" ) < /dev/null > /dev/null 2>&1 &
late=$!
out="$(run _lan_renew --notify 2>&1)"; rc=$?
wait "$late" 2>/dev/null
[[ "$rc" == 0 && "$(calls 'restart pdg-lan$')" == 0 && ! -s "$W/notify.log" && "$out" == *"反代给出的就是盘上这张"* ]] \
  && ok "反代一时没应答、随后自己起来 → 不重启、不通知" \
  || bad "4l: rc=$rc 重启=$(calls 'restart pdg-lan$') out=$out notify=$(cat "$W/notify.log" 2>/dev/null)"

# 4m 反代 active 却一直不应答 → 等满了才重启, 并照实说是"没有回应", 不说它拿着旧证书
reset_case; echo skip > "$W/state/acme-mode"; caddy_stop
out="$(run _lan_renew --notify 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$(served)" == "$FP_OLD" && "$(calls 'restart pdg-lan$')" == 1 \
      && "$out" == *"没有回应"* && "$out" != *"旧证书"* ]] && grep -q '没有回应' "$W/notify.log"; then
  ok "反代在跑却一直不应答 → 等满后重启一次, 说清是没有回应"
else bad "4m: rc=$rc served=$(served) 重启=$(calls 'restart pdg-lan$') out=$out"; fi

# ── 发给 Telegram 的每一条都要能被它收下 ────────────────────────────────────────
# 出口是 HTML 模式(调用方自己写 <b>): 只认下面这几种标签, 别的 < > & 必须是实体, 否则整条 400 拒收。
keep_notify; rm -f "$W/notify.log"
tg_html_bad(){   # $1=文件, 每行一次 _kf 调用("notify <正文>"); 打印收不下的行, 有就返回 1
  python3 -I - "$1" <<'PY'
import re, sys
TAGS = {"b", "strong", "i", "em", "u", "ins", "s", "strike", "del", "a", "code", "pre",
        "tg-spoiler", "span", "blockquote", "tg-emoji"}
bad = []
for ln in open(sys.argv[1], encoding="utf-8"):
    t = ln.rstrip("\n")
    body = t[len("notify "):] if t.startswith("notify ") else t
    s = re.sub(r"</?(%s)(\s[^<>]*)?>" % "|".join(map(re.escape, sorted(TAGS))), "", body)
    s = re.sub(r"&(amp|lt|gt|quot|#[0-9]+|#x[0-9a-fA-F]+);", "", s)
    if re.search(r"[<>&]", s):
        bad.append(t)
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}
# 仪器校准: 一条已知收不下的(带 <dns插件名>)、一条收得下的
printf 'notify <b>h</b> 手工重签: sudo pdg lan cert <dns插件名>。\nnotify <b>h</b> 手工重签: sudo pdg lan cert &lt;dns插件名&gt;。\n' > "$WORK/tg-cal.log"
[[ "$(tg_html_bad "$WORK/tg-cal.log")" == 'notify <b>h</b> 手工重签: sudo pdg lan cert <dns插件名>。' ]] \
  && ok "HTML 判据校准: 认出未转义的 <dns插件名>, 放过转义后的那条" || bad "HTML 判据不灵: $(tg_html_bad "$WORK/tg-cal.log")"
n_note="$(wc -l < "$WORK/notify-all.log" 2>/dev/null || echo 0)"
if (( n_note >= 8 )); then
  bad_lines="$(tg_html_bad "$WORK/notify-all.log")" && ok "④ 里发出的 $n_note 条通知都是 Telegram 收得下的 HTML" \
    || bad "有通知 Telegram 会拒收(未转义的 < > &): $bad_lines"
else bad "④ 里只记到 $n_note 条通知(应 ≥ 8) —— 判据没东西可判"; fi

# ══ ⑤ 接线: 入口、签发、清除、卸载、迁移链 ══════════════════════════════════════
grep -qE '^\s+renew\)\s+_lan_renew "\$@";;' "$PDG" && ok "cmd_lan 接上 renew" || bad "cmd_lan 没有 renew 分支"
sed -n '/^_lan_cert()/,/^}/p' "$PDG" | grep -q '_lan_cert_timer_install' && ok "pdg lan cert 签完就装续期定时器" \
  || bad "_lan_cert 不装续期定时器 —— 新签的证书又会没人续"
sed -n '/^_lan_purge()/,/^}/p' "$PDG" | grep -q '_lan_cert_timer_remove' && ok "pdg lan purge 拆定时器" || bad "_lan_purge 不拆定时器"
grep -q 'pdg-lan-cert.timer' "$ROOT/uninstall.sh" && grep -q '/etc/systemd/system/pdg-lan-cert.service' "$ROOT/uninstall.sh" \
  && ok "uninstall.sh 拆 pdg-lan-cert.{service,timer}" || bad "uninstall.sh 不拆续期定时器"
sed -n '/^run_all_migrations()/,/^}/p' "$PDG" | grep -q 'migrate_lan_cert_timer || true' \
  && ok "迁移链里有 migrate_lan_cert_timer(失败不拖垮更新)" || bad "迁移链没接 migrate_lan_cert_timer"
# 反代重启只走唯一入口(tests/test-lan-proxy-reload-chokepoint.sh 的规矩): renew 里不许裸调
sed -n '/^_lan_renew()/,/^}/p' "$PDG" | grep -qE 'systemctl +(restart|reload) +pdg-lan' \
  && bad "_lan_renew 裸调了 systemctl restart/reload pdg-lan(必须走 _lan_apply_proxy)" \
  || ok "_lan_renew 重启反代只走 _lan_apply_proxy"

lan_fx_guard127 "$WORK/run.log" || bad "闭包漏抽依赖"
finish
