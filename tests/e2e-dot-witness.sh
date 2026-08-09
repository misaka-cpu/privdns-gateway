#!/usr/bin/env bash
# 6.2A E2E: 真 mosdns v5.3.4 + 真 TLS + 真 UDP/TCP socket, 验 DoT 证据源的传输矩阵。
#
# 要证明的那条命题:
#   只有「qname 落在探测命名空间」且「TLS SNI 等于 DoT 域名」的查询才会到达证据端;
#   明文 UDP/TCP 53、错误 SNI、无 SNI、普通域名、不合规 label、只握手不发查询, 一律不产生证据。
#
# 两个纪律, 都是上一轮踩出来的:
#   · 证据端与普通上游各有**自己的**端口、计数文件和日志。共用一个日志时, "命中了谁"
#     根本分不出来 —— 上一轮就因此得出过"四种传输全命中"的错误结论。
#   · 配置不由本脚本自己拼: 走 install.sh 里那个正式 render 闭包。自己替换占位符的话,
#     测试绿了只能说明我的替换和我的期望一致, 真机上照样可能是死的。
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

# ── 隔离硬门: 宿主上默认不跑 ────────────────────────────────────────────────
# 这支会起真 mosdns 与真监听。开发机上直接跑等于往宿主塞进程和端口, 所以除非明确身处
# 一次性隔离环境(容器 E2E job)且是 root, 一律 SKIP —— 不静默降级、也不"尽量跑一点"。
if [[ "${PDG_E2E_ISOLATED:-}" != 1 || "$(id -u)" != 0 ]]; then
  skip "非一次性隔离环境(需 PDG_E2E_ISOLATED=1 且 root) —— 不在宿主上起 mosdns/监听"
  summary; exit 0
fi

DOT_DOMAIN="dot.e2e.test"
SUFFIX="probe.$DOT_DOMAIN"
LABEL="a1b2c3d4e5f6a7b8c9d0e1f2"                  # 12 字节 → 24 个小写 hex
MOSDNS_BIN="$(command -v mosdns || true)"

# ── 进程账本: 只杀自己起的, 绝不 pkill -f ──────────────────────────────────
PIDS=()
track(){ PIDS+=("$1"); }
stop_all(){
  local p
  for p in "${PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    kill "$p" 2>/dev/null
  done
  for p in "${PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    local i=0
    while kill -0 "$p" 2>/dev/null && [[ $i -lt 30 ]]; do sleep 0.1; i=$((i+1)); done
    kill -9 "$p" 2>/dev/null
  done
  PIDS=()
}
_cleanup(){
  stop_all
  if e2e_keep_tmp; then echo "[PDG_KEEP_TMP] 现场保留: ${WORK:-$E2E_TMP}" >&2; fi
}
# 走 lib 的登记式钩子, **不要**自己 `trap ... EXIT` —— 那会把 lib 注册的
# e2e_tmp_cleanup 顶掉, 临时目录就再也没人清(这一条是实测踩出来的: 容器里留下了
# 两个 e2e-tmp.* 目录)。先登记本脚本的进程清理, 再 e2e_tmp_init 登记目录清理,
# 顺序即执行顺序: 先停进程, 再删目录。
e2e_add_exit_hook _cleanup || { echo "[FAIL] 注册清理钩子失败"; exit 1; }
e2e_tmp_init || { bad "临时目录初始化失败"; summary; exit 1; }
WORK="$E2E_TMP/dotw"; mkdir -p "$WORK/rt" "$WORK/rules"; chmod 700 "$WORK/rt"

freeport(){ python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
CLIENT="$E2E_ROOT/tests/helpers/dns-client.py"
STUB="$E2E_ROOT/tests/helpers/dns-stub.py"

# ── 前提 ────────────────────────────────────────────────────────────────────
sec "0. 前提"
[[ -n "$MOSDNS_BIN" ]] || { bad "隔离环境里没有 mosdns 二进制 —— 这支必须有真内核"; summary; exit 1; }
ok "mosdns: $("$MOSDNS_BIN" version 2>&1 | head -1)"
for f in "$CLIENT" "$STUB" "$E2E_ROOT/deploy/bot/dotwitness.py"; do
  [[ -f "$f" ]] || { bad "缺文件: $f"; summary; exit 1; }
done

# 供应链: 用项目自己的钉版与哈希核一遍手上这个二进制的来源包(能取到就核, 取不到记 SKIP)
# shellcheck source=lib/versions.sh
source "$E2E_ROOT/lib/versions.sh"
ok "钉定版本: mosdns $MOSDNS_VER"
case "$("$MOSDNS_BIN" version 2>&1 | head -1)" in
  *"${MOSDNS_VER#v}"*) ok "运行的二进制就是钉定版本" ;;
  *) bad "二进制版本与 lib/versions.sh 钉定的 $MOSDNS_VER 不一致" ;;
esac

# ── 1. 正式 render 闭包 ─────────────────────────────────────────────────────
sec "1. 走正式 render 闭包生成配置"
RENDER_SH="$WORK/render.sh"
{
  echo 'set -u'
  echo 'die(){ echo "$*" >&2; exit 1; }'
  sed -n '/^DOTWITNESS_PORT=/,/^render(){/p' "$E2E_ROOT/install.sh" | sed '$d'
  sed -n '/^render(){/,/"\$1"; }$/p' "$E2E_ROOT/install.sh"
} > "$RENDER_SH"
grep -q '__DOT_DOMAIN__' "$RENDER_SH" && ok "抽到的闭包包含 __DOT_DOMAIN__ 替换" \
  || bad "抽到的 render 闭包里没有 __DOT_DOMAIN__ 替换 —— 抽错了或产品回退了"

UPPORT="$(freeport)"; WPORT_REAL=""; DNSP="$(freeport)"; DOTP="$(freeport)"
RENDERED="$WORK/config.yaml"
( set -u
  SERVER_IP=203.0.113.1; INTERNAL_CIDR=127.0.0.0/8; CERT_DIR="$WORK"
  SSH_PORT=22; MOSDNS_CACHE=8192; JOURNALD_MAXUSE=200M
  HIJACK_SET_FILE='geosite_geolocation-!cn.txt'
  PDG_RESCUE_PORT=8446; RESCUE_BIND=203.0.113.1
  DOT_DOMAIN="$DOT_DOMAIN"; REPO_DIR="$E2E_ROOT"
  export SERVER_IP INTERNAL_CIDR CERT_DIR SSH_PORT MOSDNS_CACHE JOURNALD_MAXUSE
  export HIJACK_SET_FILE PDG_RESCUE_PORT RESCUE_BIND DOT_DOMAIN REPO_DIR
  # shellcheck disable=SC1090
  source "$RENDER_SH" 2>/dev/null || true
  render "$E2E_ROOT/deploy/mosdns/config.yaml"
) > "$RENDERED" 2>"$WORK/render.err"
[[ -s "$RENDERED" ]] && ok "render 产出配置($(wc -l <"$RENDERED") 行)" \
  || { bad "render 没产出: $(tail -2 "$WORK/render.err")"; summary; exit 1; }

left="$(grep -oE '__[A-Z0-9_]+__' "$RENDERED" | sort -u | tr '\n' ' ')"
[[ -z "$left" ]] && ok "渲染产物无残留占位符" || bad "残留占位符: $left"
grep -q "qname suffix probe\.$DOT_DOMAIN\b" "$RENDERED" && ok "qname 判据是渲染后的域名" || bad "qname 判据没拿到域名"
grep -q "string_exp server_name eq $DOT_DOMAIN\b" "$RENDERED" && ok "SNI 判据是渲染后的域名" || bad "SNI 判据没拿到域名"

WPORT_REAL="$(grep -oE 'udp://127\.0\.0\.1:[0-9]+' "$RENDERED" | head -1 | sed 's/.*://')"
SRC_PORT="$(sed -n 's/^DOTWITNESS_PORT[[:space:]]*=[[:space:]]*\([0-9]\{1,5\}\).*/\1/p' "$E2E_ROOT/deploy/bot/dotwitness.py" | head -1)"
[[ "$WPORT_REAL" == "$SRC_PORT" ]] && ok "witness 端口取自 dotwitness.py 单一真源($SRC_PORT)" \
  || bad "端口不一致: 渲染=$WPORT_REAL 真源=$SRC_PORT"

# dotwitness.env: 用 install.sh 里那句同款生成, 验 suffix 与权限
ENVF="$WORK/dotwitness.env"
( umask 022; printf 'PDG_DOTWITNESS_SUFFIX=probe.%s\n' "$DOT_DOMAIN" > "$ENVF" )
grep -qx "PDG_DOTWITNESS_SUFFIX=$SUFFIX" "$ENVF" && ok "dotwitness.env 的 suffix 精确为 $SUFFIX" || bad "suffix 不对: $(cat "$ENVF")"
[[ "$(stat -c %a "$ENVF")" == 644 ]] && ok "dotwitness.env mode=644(非机密, 只是命名空间)" || bad "dotwitness.env mode=$(stat -c %a "$ENVF")"
h1="$(sha256sum "$ENVF" | cut -d' ' -f1)"
( umask 022; printf 'PDG_DOTWITNESS_SUFFIX=probe.%s\n' "$DOT_DOMAIN" > "$ENVF" )
[[ "$h1" == "$(sha256sum "$ENVF" | cut -d' ' -f1)" ]] && ok "重复生成 dotwitness.env 内容一致" || bad "重复生成结果不一致"

# 把配置改成本轮可用: 规则文件指到临时目录、监听换高位端口、证书指到临时证书
for n in $(grep -oE '/etc/mosdns/rules/[A-Za-z0-9_.!-]+' "$RENDERED" | sed 's#.*/##' | sort -u); do : > "$WORK/rules/$n"; done
sed -i -e "s#/etc/mosdns/rules/#$WORK/rules/#g" \
       -e "s#listen: \"0.0.0.0:53\"#listen: \"127.0.0.1:$DNSP\"#g" \
       -e "s#listen: \"0.0.0.0:853\"#listen: \"127.0.0.1:$DOTP\"#g" \
       -e "s#args: {.*1\.1\.1\.1.*}#args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UPPORT\"} ] }#" \
       -e "s#args: {.*223\.5\.5\.5.*}#args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UPPORT\"} ] }#" \
       -e "s#args: {.*22\.22\.22\.22.*}#args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UPPORT\"} ] }#" \
       "$RENDERED"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$WORK/privkey.pem" \
  -out "$WORK/fullchain.pem" -subj "/CN=$DOT_DOMAIN" -addext "subjectAltName=DNS:$DOT_DOMAIN" \
  >/dev/null 2>&1 && ok "真 TLS 证书 CN=$DOT_DOMAIN" || bad "证书生成失败"

# ── 2. 起两个**互相独立**的观察端 + 真 witness ──────────────────────────────
sec "2. 起观察端(各自独立的端口/计数/日志)"
UPCNT="$WORK/upstream.count"; UPLOG="$WORK/upstream.log"
python3 "$STUB" --port "$UPPORT" --count "$UPCNT" --log "$UPLOG" --mode answer >"$WORK/up.out" 2>&1 &
track $!
PDG_DOTWITNESS_PORT="$WPORT_REAL" PDG_DOTWITNESS_SUFFIX="$SUFFIX" RUNTIME_DIRECTORY="$WORK/rt" \
  python3 "$E2E_ROOT/deploy/bot/dotwitness.py" >"$WORK/witness.log" 2>&1 &
WPID=$!; track "$WPID"
sleep 1
kill -0 "$WPID" 2>/dev/null && ok "witness 存活(127.0.0.1:$WPORT_REAL)" || bad "witness 起不来: $(tail -3 "$WORK/witness.log")"
[[ "$UPCNT" != "$WORK/rt/evidence.json" ]] && ok "两个观察端的状态文件不是同一个" || bad "观察端状态文件重合"

"$MOSDNS_BIN" start -c "$RENDERED" >"$WORK/mosdns.log" 2>&1 &
MPID=$!; track "$MPID"
sleep 2
kill -0 "$MPID" 2>/dev/null && ok "mosdns 存活 (53=$DNSP, 853=$DOTP)" \
  || { bad "mosdns 起不来: $(tail -5 "$WORK/mosdns.log")"; summary; exit 1; }

# ── 3. 防假绿自检 ───────────────────────────────────────────────────────────
sec "3. 防假绿自检"
upc(){ wc -l < "$UPCNT" 2>/dev/null || echo 0; }
evsum(){ sha256sum "$WORK/rt/evidence.json" 2>/dev/null | cut -d' ' -f1; }
evexists(){ [[ -f "$WORK/rt/evidence.json" ]] && echo 1 || echo 0; }

b="$(upc)"
python3 "$CLIENT" --mode udp --port "$DNSP" --qname selftest.example.com >/dev/null 2>&1
[[ "$(upc)" -gt "$b" ]] && ok "普通上游计数器确实会增长($b→$(upc))" || bad "上游计数器不动 —— 计数不可信"
b="$(upc)"
python3 "$CLIENT" --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" >/dev/null 2>&1
[[ "$(evexists)" == 1 ]] && ok "witness 计数(evidence)确实会产生" || bad "witness 不产生 evidence —— 计数不可信"
[[ "$(upc)" -eq "$b" ]] && ok "合法 probe 没有同时打到普通上游" || bad "合法 probe 同时打到了上游"
rm -f "$WORK/rt/evidence.json"

# ── 4. 传输矩阵 ─────────────────────────────────────────────────────────────
sec "4. 传输矩阵(每格独立清 evidence, 两边同时核对)"
# cell <名字> <期望witness增量> <期望上游增量> <client 参数...>
cell(){
  local name="$1" we="$2" ue="$3"; shift 3
  rm -f "$WORK/rt/evidence.json"
  local u0; u0="$(upc)"
  kill -0 "$MPID" 2>/dev/null || { bad "$name: mosdns 已死"; return; }
  kill -0 "$WPID" 2>/dev/null || { bad "$name: witness 已死"; return; }
  local out; out="$(timeout 12 python3 "$CLIENT" "$@" 2>&1)"
  local wg; wg="$(evexists)"
  local ug=$(( $(upc) - u0 ))
  if [[ "$wg" == "$we" && "$ug" == "$ue" ]]; then
    ok "$name → witness=$wg 上游=$ug"
  else
    bad "$name → witness=$wg(期望 $we) 上游=$ug(期望 $ue) [$out]"
  fi
  LAST_OUT="$out"
}
D(){ echo "--mode $1 --port $2 --sni $DOT_DOMAIN --qname $3"; }

cell "正确SNI+合法A probe"      1 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" --qtype 1
RESP_A="$LAST_OUT"
cell "正确SNI+合法AAAA probe"   1 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" --qtype 28
cell "正确SNI+HTTPS(65) probe"  1 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" --qtype 65
cell "正确SNI+普通域名"         0 1 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname www.example.com
cell "错误SNI+probe"            0 1 --mode dot --port "$DOTP" --sni wrong.example.net --qname "$LABEL.$SUFFIX"
cell "无SNI+probe"              0 1 --mode dot-nosni --port "$DOTP" --qname "$LABEL.$SUFFIX"
cell "UDP53+probe"              0 1 --mode udp --port "$DNSP" --qname "$LABEL.$SUFFIX"
cell "TCP53+probe"              0 1 --mode tcp --port "$DNSP" --qname "$LABEL.$SUFFIX"
cell "只握手不发query"          0 0 --mode dot-handshake --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX"
# 下面 6 格是"落在探测命名空间、但 label 不合规"。它们的期望是 witness=0 / 上游=0,
# **不是** 上游+1 —— 钉定的 mosdns v5.3.4 只能按 qname 后缀 + SNI 路由(qname 匹配器不支持
# regexp, domain_set 里的 `regexp:` 也是 unsupported), 所以这些查询一定会被转到证据端,
# 不可能再回到普通上游。证据端认不出 label 就只回 NOERROR/NODATA: 不留证据、不外发、
# 有界返回。改成"转普通上游"需要换 mosdns 二进制, 不在 6.2A 范围内。
BOUNDED_MS=2000
bounded(){ local n="$1"; local ms; ms="$(sed -n 's/.*elapsed_ms=\([0-9]*\).*/\1/p' <<<"$LAST_OUT")"
  local rc; rc="$(sed -n 's/.*\brc=\([0-9]*\).*/\1/p' <<<"$LAST_OUT")"
  local rcode; rcode="$(sed -n 's/.*rcode=\([0-9]*\).*/\1/p' <<<"$LAST_OUT")"
  if [[ "$rc" == 0 && "$rcode" == 0 && -n "$ms" && "$ms" -lt "$BOUNDED_MS" ]]; then
    ok "  $n 有界应答 NOERROR/NODATA(${ms}ms)"
  else ok_or_bad_bounded "$n" "$ms" "$rc" "$rcode"; fi; }
ok_or_bad_bounded(){ bad "  $1 未在 ${BOUNDED_MS}ms 内拿到 NOERROR(rc=$3 rcode=$4 ${2}ms)"; }

cell "23位hex"                  0 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "${LABEL:0:23}.$SUFFIX"
bounded "23位hex"
cell "25位hex"                  0 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "${LABEL}f.$SUFFIX"
bounded "25位hex"
cell "24位大写hex"              0 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$(echo "$LABEL" | tr 'a-f' 'A-F').$SUFFIX"
bounded "24位大写hex"
cell "24位非hex"                0 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "zzzzc3d4e5f6a7b8c9d0e1f2.$SUFFIX"
bounded "24位非hex"
cell "多一层子域"               0 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "extra.$LABEL.$SUFFIX"
bounded "多一层子域"
cell "probe根本身无label"       0 0 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$SUFFIX"
bounded "probe根本身无label"
cell "错误后缀"                 0 1 --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.probe.other.test"

# ── 5. 合法 probe 的应答形态 ────────────────────────────────────────────────
sec "5. NOERROR/NODATA 应答核对"
kv(){ sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$RESP_A"; }
[[ "$(kv rc)"             == 0 ]] && ok "客户端拿到应答"        || bad "没拿到应答: $RESP_A"
[[ "$(kv qid_echo)"       == 1 ]] && ok "transaction ID 原样返回" || bad "ID 没回显"
[[ "$(kv qr)"             == 1 ]] && ok "QR=1"                   || bad "QR 不是 1"
[[ "$(kv rcode)"          == 0 ]] && ok "RCODE=NOERROR"          || bad "RCODE=$(kv rcode)"
[[ "$(kv ancount)"        == 0 ]] && ok "answer count=0"         || bad "ancount=$(kv ancount)"
[[ "$(kv has_addr)"       == 0 ]] && ok "不返回 A/AAAA 地址"     || bad "返回了地址"
[[ "$(kv question_match)" == 1 ]] && ok "question 段与请求一致"  || bad "question 段不一致"
[[ "$(grep -c . "$UPLOG")" -gt 0 ]] && ok "普通上游桩有留痕(证明没走公网)" || bad "上游桩无留痕"

# ── 6. evidence 内容与幂等 ──────────────────────────────────────────────────
sec "6. evidence 内容、权限与幂等"
rm -f "$WORK/rt/evidence.json"
python3 "$CLIENT" --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" >/dev/null 2>&1
EV="$WORK/rt/evidence.json"
if [[ ! -f "$EV" ]]; then
  bad "没有生成 evidence, 后续内容断言全部跳过"
else
  python3 - "$EV" "$LABEL" "$DOT_DOMAIN" <<'PY' && ok "evidence 字段与隐私约束全部满足" || bad "evidence 字段/隐私约束不满足(见上)"
import hashlib, json, sys
p, label, dom = sys.argv[1], sys.argv[2], sys.argv[3]
rec = json.load(open(p))
blob = json.dumps(rec, ensure_ascii=False)
want = {"schema_version", "probe_label_sha256", "observed_at", "qtype", "transport", "expires_at"}
errs = []
if set(rec) != want: errs.append("字段集合=%s" % sorted(rec))
if rec.get("probe_label_sha256") != hashlib.sha256(label.encode()).hexdigest(): errs.append("哈希对不上")
if label in blob: errs.append("含 label 明文")
if dom in blob: errs.append("含 DoT 域名")
if ("%s" % dom) in blob or ".probe." in blob: errs.append("含 qname 片段")
if any(k in rec for k in ("source_ipv4_16", "client_ip", "source")): errs.append("含来源字段")
if rec.get("transport") != "dot": errs.append("transport=%s" % rec.get("transport"))
for e in errs: print("       ✗ %s" % e)
sys.exit(1 if errs else 0)
PY
  [[ "$(stat -c %a "$EV")" == 600 ]] && ok "evidence mode=0600" || bad "mode=$(stat -c %a "$EV")"
  [[ "$(basename "$EV")" == evidence.json ]] && ok "固定文件名(label 不入路径)" || bad "文件名异常"
  [[ "$(stat -c %s "$EV")" -le 4096 ]] && ok "JSON ≤ 4096 字节($(stat -c %s "$EV"))" || bad "JSON 过大"
  [[ "$(ls -1 "$WORK/rt" | wc -l)" == 1 ]] && ok "状态目录里只有一份状态" || bad "状态目录有 $(ls -1 "$WORK/rt" | wc -l) 个文件"

  s1="$(evsum)"; o1="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["observed_at"])' "$EV")"
  sleep 1
  python3 "$CLIENT" --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$LABEL.$SUFFIX" >/dev/null 2>&1
  o2="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["observed_at"])' "$EV")"
  [[ "$o1" == "$o2" ]] && ok "同 label 重复查询不刷新 observed_at" || bad "observed_at 被刷新($o1→$o2)"
  [[ "$s1" == "$(evsum)" ]] && ok "同 label 重复查询内容摘要不变" || bad "内容摘要变了"
  [[ "$(ls -1 "$WORK/rt" | wc -l)" == 1 ]] && ok "重复查询没有产生第二份状态" || bad "多出状态文件"

  old="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["probe_label_sha256"])' "$EV")"
  L2="0f1e2d3c4b5a69788796a5b4"
  python3 "$CLIENT" --mode dot --port "$DOTP" --sni "$DOT_DOMAIN" --qname "$L2.$SUFFIX" >/dev/null 2>&1
  new="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["probe_label_sha256"])' "$EV")"
  want2="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$L2")"
  [[ "$new" == "$want2" && "$new" != "$old" ]] && ok "新 label 原子替换, 旧哈希消失" || bad "新 label 没替换($old→$new)"
  python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$EV" && ok "替换后 JSON 完整可解析" || bad "出现半写 JSON"
  shopt -s nullglob dotglob
  leftovers=("$WORK/rt"/.ev-*)
  shopt -u nullglob dotglob
  [[ "${#leftovers[@]}" == 0 ]] && ok "原子替换没留临时文件" || bad "留下 ${#leftovers[@]} 个 .ev- 临时文件"
fi

# ── 7. 收尾 ─────────────────────────────────────────────────────────────────
sec "7. 收尾"
kill -0 "$MPID" 2>/dev/null && ok "mosdns 全程存活(PID $MPID)" || bad "mosdns 中途死了"
kill -0 "$WPID" 2>/dev/null && ok "witness 全程存活(PID $WPID)" || bad "witness 中途死了"
grep -qiE "panic|fatal" "$WORK/mosdns.log" && bad "mosdns 日志有 panic/fatal" || ok "mosdns 日志无 panic/fatal"
for f in "$WORK/witness.log" "$WORK/mosdns.log"; do
  if grep -qE "$LABEL|$SUFFIX" "$f" 2>/dev/null; then bad "$(basename "$f") 里出现了 label/qname"; else ok "$(basename "$f") 未泄露 label/qname"; fi
done

summary
[[ "$nfail" -gt 0 ]] && exit 1 || exit 0
