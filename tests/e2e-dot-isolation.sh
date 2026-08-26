#!/usr/bin/env bash
# 6.2A P0 硬门: 证据端出各种故障时, **普通 DNS 必须完全不受影响**。
#
# 这是 6.2A 能不能收口的判据。证据端是旁路: 它挂了、慢了、乱答了, 用户的 DNS 解析都
# 不许因此变慢或失败。任一格普通查询出现新增失败或明显变慢, 就是 P0。
#
# 判"没受影响"不能只跑一次 dig —— 每格连打 UDP53×3 / TCP53×3 / DoT 普通域名×3,
# 逐条记 rc、耗时、上游增量、mosdns PID, 再和健康基线比。
set -uo pipefail
E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/e2e-lib.sh
source "$E2E_ROOT/tests/e2e-lib.sh"

pass=0; nfail=0; nskip=0
ok(){   pass=$((pass+1));   echo "[OK]   $*"; }
bad(){  nfail=$((nfail+1)); echo "[FAIL] $*"; }
skip(){ nskip=$((nskip+1)); echo "[SKIP] $*"; }
sec(){  echo; echo "── $* ──"; }
summary(){ echo; echo "通过 $pass, 失败 $nfail, 跳过 $nskip"; }

if [[ "${PDG_E2E_ISOLATED:-}" != 1 || "$(id -u)" != 0 ]]; then
  skip "非一次性隔离环境(需 PDG_E2E_ISOLATED=1 且 root) —— 不在宿主上起 mosdns/监听"
  summary; exit 0
fi

DOT_DOMAIN="dot.e2e.test"; SUFFIX="probe.$DOT_DOMAIN"
LABEL="a1b2c3d4e5f6a7b8c9d0e1f2"
MOSDNS_BIN="$(command -v mosdns || true)"
[[ -n "$MOSDNS_BIN" ]] || { bad "隔离环境里没有 mosdns"; summary; exit 1; }

PIDS=()
track(){ PIDS+=("$1"); }
untrack(){ local o=() p; for p in "${PIDS[@]:-}"; do [[ "$p" == "$1" ]] || o+=("$p"); done; PIDS=("${o[@]:-}"); }
kill_one(){ local p="$1" i=0; [[ -n "$p" ]] || return 0
  kill "$p" 2>/dev/null
  while kill -0 "$p" 2>/dev/null && [[ $i -lt 30 ]]; do sleep 0.1; i=$((i+1)); done
  kill -9 "$p" 2>/dev/null; untrack "$p"; }
stop_all(){ local p; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  sleep 0.3; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done; PIDS=(); }
_cleanup(){ stop_all; e2e_keep_tmp && echo "[PDG_KEEP_TMP] 现场保留: ${WORK:-$E2E_TMP}" >&2; }
e2e_add_exit_hook _cleanup || { echo "[FAIL] 注册清理钩子失败"; exit 1; }
e2e_tmp_init || { bad "临时目录初始化失败"; summary; exit 1; }
WORK="$E2E_TMP/iso"; mkdir -p "$WORK/rt" "$WORK/rules"; chmod 700 "$WORK/rt"

freeport(){ python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
CLIENT="$E2E_ROOT/tests/helpers/dns-client.py"
STUB="$E2E_ROOT/tests/helpers/dns-stub.py"

# ── 起环境(与矩阵那支同一套渲染闭包) ────────────────────────────────────────
sec "0. 环境"
RENDER_SH="$WORK/render.sh"
{ echo 'set -u'; echo 'die(){ echo "$*" >&2; exit 1; }'
  sed -n '/^DOTWITNESS_PORT=/,/^render(){/p' "$E2E_ROOT/install.sh" | sed '$d'
  sed -n '/^render(){/,/"\$1"; }$/p' "$E2E_ROOT/install.sh"; } > "$RENDER_SH"

UPPORT="$(freeport)"; DNSP="$(freeport)"; DOTP="$(freeport)"
RENDERED="$WORK/config.yaml"
( set -u
  SERVER_IP=203.0.113.1; INTERNAL_CIDR=127.0.0.0/8; CERT_DIR="$WORK"; SSH_PORT=22
  MOSDNS_CACHE=8192; JOURNALD_MAXUSE=200M; HIJACK_SET_FILE='geosite_geolocation-!cn.txt'
  # 救援端口从 lib/rescue.sh 读 —— 那是它的单一事实源, 这里写死会被端口散落守卫判红。
  # shellcheck source=lib/rescue.sh
  source "$E2E_ROOT/lib/rescue.sh"
  RESCUE_BIND=203.0.113.1; DOT_DOMAIN="$DOT_DOMAIN"; REPO_DIR="$E2E_ROOT"
  export SERVER_IP INTERNAL_CIDR CERT_DIR SSH_PORT MOSDNS_CACHE JOURNALD_MAXUSE \
         HIJACK_SET_FILE PDG_RESCUE_PORT RESCUE_BIND DOT_DOMAIN REPO_DIR
  # shellcheck disable=SC1090
  source "$RENDER_SH" 2>/dev/null || true
  render "$E2E_ROOT/deploy/mosdns/config.yaml" ) > "$RENDERED" 2>"$WORK/render.err"
[[ -s "$RENDERED" ]] || { bad "render 失败: $(tail -2 "$WORK/render.err")"; summary; exit 1; }
WPORT="$(grep -oE 'udp://127\.0\.0\.1:[0-9]+' "$RENDERED" | head -1 | sed 's/.*://')"
for n in $(grep -oE '/etc/mosdns/rules/[A-Za-z0-9_.!-]+' "$RENDERED" | sed 's#.*/##' | sort -u); do : > "$WORK/rules/$n"; done
# 去广告受管块的 domain_set 输入在 /var/lib 下, 不在 rules 目录 —— 上面那句只推导 rules/,
# 漏掉它们的话 mosdns **缺一个文件就 FATAL**, 配置根本加载不了(exact-head run 32923836445
# 上 8 个 E2E job 就是这么一起红的)。同样**从配置里推导**, 不写死文件名。
mkdir -p "$WORK/adblock"
for n in $(grep -oE '/var/lib/privdns-gateway/adblock/[A-Za-z0-9_.!-]+' "$RENDERED" | sed 's#.*/##' | sort -u); do
  : > "$WORK/adblock/$n"; chmod 644 "$WORK/adblock/$n"
done
sed -i -e "s#/var/lib/privdns-gateway/adblock/#$WORK/adblock/#g" \
       -e "s#/etc/mosdns/rules/#$WORK/rules/#g" \
       -e "s#listen: \"0.0.0.0:53\"#listen: \"127.0.0.1:$DNSP\"#g" \
       -e "s#listen: \"0.0.0.0:853\"#listen: \"127.0.0.1:$DOTP\"#g" \
       -e "s#args: {.*1\.1\.1\.1.*}#args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UPPORT\"} ] }#" \
       -e "s#args: {.*223\.5\.5\.5.*}#args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UPPORT\"} ] }#" \
       -e "s#args: {.*22\.22\.22\.22.*}#args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UPPORT\"} ] }#" \
       "$RENDERED"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$WORK/privkey.pem" \
  -out "$WORK/fullchain.pem" -subj "/CN=$DOT_DOMAIN" -addext "subjectAltName=DNS:$DOT_DOMAIN" >/dev/null 2>&1

UPCNT="$WORK/upstream.count"
python3 "$STUB" --port "$UPPORT" --count "$UPCNT" --log "$WORK/upstream.log" --mode answer >/dev/null 2>&1 &
track $!
start_witness(){
  PDG_DOTWITNESS_PORT="$WPORT" PDG_DOTWITNESS_SUFFIX="$SUFFIX" RUNTIME_DIRECTORY="$WORK/rt" \
    python3 "$E2E_ROOT/deploy/bot/dotwitness.py" >>"$WORK/witness.log" 2>&1 &
  WPID=$!; track "$WPID"; sleep 0.8
}
start_witness
"$MOSDNS_BIN" start -c "$RENDERED" >"$WORK/mosdns.log" 2>&1 &
MPID=$!; track "$MPID"; sleep 2
kill -0 "$MPID" 2>/dev/null && ok "mosdns 起来了 (PID $MPID, 53=$DNSP, 853=$DOTP, witness=$WPORT)" \
  || { bad "mosdns 起不来: $(tail -5 "$WORK/mosdns.log")"; summary; exit 1; }

upc(){ wc -l < "$UPCNT" 2>/dev/null || echo 0; }
ev(){ [[ -f "$WORK/rt/evidence.json" ]] && echo 1 || echo 0; }

# ── 普通 DNS 三路各打 3 次, 回 "成功数/最大耗时ms" ──────────────────────────
probe_normal(){
  local okc=0 maxms=0 i out rc ms
  for i in 1 2 3; do
    out="$(timeout 12 python3 "$CLIENT" --mode "$1" --port "$2" ${3:+--sni "$3"} \
            --qname "normal-$RANDOM.example.com" --timeout 5 2>&1)"
    rc="$(sed -n 's/.*\brc=\([0-9]*\).*/\1/p' <<<"$out")"
    ms="$(sed -n 's/.*elapsed_ms=\([0-9]*\).*/\1/p' <<<"$out")"
    [[ "$rc" == 0 ]] && okc=$((okc+1))
    [[ -n "$ms" && "$ms" -gt "$maxms" ]] && maxms="$ms"
  done
  echo "$okc $maxms"
}

BASE_MAX=0
check_normal(){          # $1=格名  $2=允许的最大耗时(ms)
  local name="$1" lim="$2" u0 u1
  u0="$(upc)"
  local u_ok u_ms t_ok t_ms d_ok d_ms
  read -r u_ok u_ms < <(probe_normal udp "$DNSP")
  read -r t_ok t_ms < <(probe_normal tcp "$DNSP")
  read -r d_ok d_ms < <(probe_normal dot "$DOTP" "$DOT_DOMAIN")
  u1="$(upc)"
  local worst=$u_ms; [[ $t_ms -gt $worst ]] && worst=$t_ms; [[ $d_ms -gt $worst ]] && worst=$d_ms
  printf "       UDP53 %s/3(%sms)  TCP53 %s/3(%sms)  DoT %s/3(%sms)  上游+%s\n" \
    "$u_ok" "$u_ms" "$t_ok" "$t_ms" "$d_ok" "$d_ms" "$((u1-u0))"
  if [[ "$u_ok$t_ok$d_ok" == "333" ]]; then ok "$name: 普通 DNS 三路各 3/3 成功"
  else bad "$name: 普通 DNS 有失败 (UDP $u_ok/3, TCP $t_ok/3, DoT $d_ok/3) —— P0"; fi
  if [[ $((u1-u0)) -ge 9 ]]; then ok "$name: 上游计数正常增长(+$((u1-u0)))"
  else bad "$name: 上游增量只有 $((u1-u0)), 期望 ≥9"; fi
  if [[ "$worst" -le "$lim" ]]; then ok "$name: 普通查询未被拖慢(最慢 ${worst}ms ≤ ${lim}ms)"
  else bad "$name: 普通查询被拖慢到 ${worst}ms(上限 ${lim}ms) —— P0"; fi
  LAST_WORST="$worst"
}

check_mosdns(){  # mosdns 必须还是同一个进程
  local name="$1"
  if kill -0 "$MPID" 2>/dev/null; then ok "$name: mosdns PID 未变($MPID), 没有崩溃或重启"
  else bad "$name: mosdns 不在了 —— P0"; fi
}

check_probe_no_evidence(){   # 故障期间 probe 不许产生假证据, 且必须有界返回
  local name="$1" out rc ms
  rm -f "$WORK/rt/evidence.json"
  out="$(timeout 20 python3 "$CLIENT" --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" \
          --qname "$LABEL.$SUFFIX" --timeout 12 2>&1)"
  ms="$(sed -n 's/.*elapsed_ms=\([0-9]*\).*/\1/p' <<<"$out")"
  [[ "$(ev)" == 0 ]] && ok "$name: probe 没有生成假证据" || bad "$name: 故障期间生成了证据 —— 假阳性"
  if [[ -n "$ms" && "$ms" -le 12000 ]]; then ok "$name: probe 在 ${ms}ms 内有界收场"
  else bad "$name: probe 没有有界收场(${ms}ms)"; fi
}

# ── 1. 健康基线 ─────────────────────────────────────────────────────────────
sec "1. 健康基线"
check_normal "基线" 3000
BASE_MAX="$LAST_WORST"
check_mosdns "基线"
rm -f "$WORK/rt/evidence.json"
python3 "$CLIENT" --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" >/dev/null 2>&1
[[ "$(ev)" == 1 ]] && ok "基线: 合法 probe 能产生证据" || bad "基线: 合法 probe 产不出证据"
# 允许故障态比基线慢一些, 但不许量级变化
LIM=$(( BASE_MAX * 3 + 1500 ))
ok "基线最慢 ${BASE_MAX}ms → 故障态判定上限 ${LIM}ms"

fake_witness(){   # 用桩顶替真 witness 占住同一个端口
  local mode="$1"
  python3 "$STUB" --port "$WPORT" --count "$WORK/fake.count" --log "$WORK/fake.log" \
    --mode "$mode" >>"$WORK/fake.out" 2>&1 &
  FPID=$!; track "$FPID"; sleep 0.8
  kill -0 "$FPID" 2>/dev/null || { bad "假 witness($mode) 起不来"; return 1; }
  return 0
}

# ── 2. 八格故障注入 ─────────────────────────────────────────────────────────
sec "2. 故障格 1: witness 正常停止, 端口拒绝"
kill_one "$WPID"
python3 - "$WPORT" <<'PY' && ok "注入命中: 端口确实已拒绝" || bad "注入没命中: 端口还有人听"
import socket, sys
# 必须先 connect: Linux 上**未 connect 的 UDP socket 收不到 ICMP 端口不可达**,
# 直接 sendto+recvfrom 只会超时, 那样就分不出"没人听"和"有人听但不回"。
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    s.send(b"\x00" * 12)
    s.recv(64)
    sys.exit(1)
except ConnectionRefusedError: sys.exit(0)
except socket.timeout: sys.exit(1)
finally: s.close()
PY
check_normal "格1 端口拒绝" "$LIM"; check_mosdns "格1"; check_probe_no_evidence "格1"

sec "3. 故障格 2: 端口在, UDP 静默丢包(无人读)"
python3 - "$WORK/silent.pid" "$WPORT" <<'PY' &
import os, socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", int(sys.argv[2])))
open(sys.argv[1], "w").write(str(os.getpid()))
while True: time.sleep(3600)          # 绑住端口但从不 recv
PY
SPID=$!; track "$SPID"; sleep 0.8
kill -0 "$SPID" 2>/dev/null && ok "注入命中: 端口被占住且无人读" || bad "静默占位进程没起来"
check_normal "格2 静默丢包" "$LIM"; check_mosdns "格2"; check_probe_no_evidence "格2"
kill_one "$SPID"

sec "4. 故障格 3: 收包但不回复"
fake_witness silent && { c0=$(wc -l < "$WORK/fake.count" 2>/dev/null || echo 0)
  check_probe_no_evidence "格3"
  c1=$(wc -l < "$WORK/fake.count" 2>/dev/null || echo 0)
  [[ "$c1" -gt "$c0" ]] && ok "注入命中: 桩确实收到了 probe($c0→$c1)" || bad "桩没收到 probe, 注入未命中"
  check_normal "格3 收包不回" "$LIM"; check_mosdns "格3"; kill_one "$FPID"; }

sec "5. 故障格 4: 返回截断响应"
fake_witness truncate && { check_normal "格4 截断响应" "$LIM"; check_mosdns "格4"
  check_probe_no_evidence "格4"; kill_one "$FPID"; }

sec "6. 故障格 5: 返回错误 transaction ID"
fake_witness wrongid && { check_normal "格5 错误ID" "$LIM"; check_mosdns "格5"
  check_probe_no_evidence "格5"; kill_one "$FPID"; }

sec "7. 故障格 6: 处理中退出"
fake_witness die && { check_probe_no_evidence "格6"
  kill -0 "$FPID" 2>/dev/null && bad "注入未命中: 桩没有退出" || ok "注入命中: 桩处理中退出"
  untrack "$FPID"; check_normal "格6 处理中退出" "$LIM"; check_mosdns "格6"; }

sec "8. 故障格 7: 返回 SERVFAIL"
fake_witness servfail && { check_normal "格7 SERVFAIL" "$LIM"; check_mosdns "格7"
  check_probe_no_evidence "格7"; kill_one "$FPID"; }

sec "9. 故障格 8: witness 恢复"
start_witness
kill -0 "$WPID" 2>/dev/null && ok "witness 已恢复(PID $WPID)" || bad "witness 恢复失败"
check_normal "格8 恢复后" "$LIM"; check_mosdns "格8"
rm -f "$WORK/rt/evidence.json"
python3 "$CLIENT" --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" >/dev/null 2>&1
[[ "$(ev)" == 1 ]] && ok "格8: 恢复后合法 probe 再次产生证据" || bad "格8: 恢复后产不出证据"

# ── 3. 收尾 ─────────────────────────────────────────────────────────────────
sec "10. 收尾"
check_mosdns "全程"
grep -qiE "panic|fatal" "$WORK/mosdns.log" && bad "mosdns 日志有 panic/fatal" || ok "mosdns 日志无 panic/fatal"
n="$(grep -c "" "$WORK/mosdns.log" 2>/dev/null || echo 0)"
ok "mosdns 日志 $n 行(故障期的 upstream error 属预期)"

summary
[[ "$nfail" -gt 0 ]] && exit 1 || exit 0
