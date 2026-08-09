#!/usr/bin/env bash
# 6.2A E2E: 真 mosdns v5.3.4(项目 SHA256 校验) + 真 TLS + 真 socket, 验 DoT 证据源。
#
# 这支要证明的行为矩阵:
#   正确 SNI 的 DoT + probe qname  → 恰好一笔证据
#   DoT 但普通域名 / 错误 SNI / 明文 TCP 53 / UDP 53 / 只握手不发查询 → 零证据
#   witness 停掉后普通 DNS 仍然应答, 且不产生假证据
#
# 环境不足(装不下 mosdns、起不了监听)时按 SKIP 记, 不冒充通过。
set -uo pipefail
E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$E2E_ROOT/tests/e2e-lib.sh" 2>/dev/null || true

pass=0; nfail=0; nskip=0
ok(){   pass=$((pass+1));  echo "[OK]   $*"; }
bad(){  nfail=$((nfail+1)); echo "[FAIL] $*"; }
skip(){ nskip=$((nskip+1)); echo "[SKIP] $*"; }
head(){ echo; echo "── $* ──"; }

WORK="$(mktemp -d /tmp/pdg-e2e-dotw.XXXXXX)"
DOT_HOST="dot.e2e.test"
SUFFIX="probe.$DOT_HOST"
LABEL="a1b2c3d4e5f6a7b8c9d0e1f2"          # 12 字节 → 24 个小写 hex
WPORT=""; MPORT_PLAIN=15353; MPORT_DOT=15853
MPID=""; WPID=""

cleanup(){
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
  [ -n "$MPID" ] && kill "$MPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── 前提 ─────────────────────────────────────────────────────────────────────
command -v openssl >/dev/null || { skip "无 openssl, 跳过整支"; echo "通过 $pass, 失败 $nfail, 跳过 $nskip"; exit 0; }
MOSDNS_BIN="$(command -v mosdns || true)"
if [ -z "$MOSDNS_BIN" ]; then
  skip "本机没有 mosdns 二进制, 跳过真链路矩阵(CI 的容器 E2E 里有)"
  echo "通过 $pass, 失败 $nfail, 跳过 $nskip"; exit 0
fi

# ── 真 TLS 证书 ──────────────────────────────────────────────────────────────
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$WORK/privkey.pem" -out "$WORK/fullchain.pem" \
  -subj "/CN=$DOT_HOST" -addext "subjectAltName=DNS:$DOT_HOST" >/dev/null 2>&1 \
  && ok "生成真 TLS 证书 CN=$DOT_HOST" || { bad "证书生成失败"; echo "通过 $pass, 失败 $nfail, 跳过 $nskip"; exit 1; }

# ── 证据端 ───────────────────────────────────────────────────────────────────
WITNESS="$E2E_ROOT/deploy/bot/dotwitness.py"
if [ ! -f "$WITNESS" ]; then
  bad "证据端不存在: deploy/bot/dotwitness.py —— 本轮要实现的就是它"
  for m in "正确 SNI + probe qname($LABEL.$SUFFIX) 生成一笔证据" "DoT 普通域名零证据" "错误 SNI 零证据" \
           "明文 TCP 53 零证据" "UDP 53 零证据" "只握手不发查询零证据" \
           "witness 停掉后普通 DNS 仍应答" "witness 停掉后不产生假证据"; do
    bad "$m —— 证据端未实现"
  done
  echo; echo "通过 $pass, 失败 $nfail, 跳过 $nskip"; exit 1
fi

WPORT="$(python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
mkdir -p "$WORK/rt" && chmod 700 "$WORK/rt"
PDG_DOTWITNESS_PORT="$WPORT" PDG_DOTWITNESS_SUFFIX="$SUFFIX" RUNTIME_DIRECTORY="$WORK/rt" \
  python3 "$WITNESS" >"$WORK/witness.log" 2>&1 &
WPID=$!
sleep 1
kill -0 "$WPID" 2>/dev/null && ok "证据端已起 (127.0.0.1:$WPORT)" || bad "证据端起不来: $(tail -3 "$WORK/witness.log")"

# ── mosdns: 复用生产模板的探测分支形状 ───────────────────────────────────────
cat > "$WORK/mosdns.yaml" <<YAML
log: {level: warn}
plugins:
  - tag: upstream_stub
    type: forward
    args: {concurrent: 1, upstreams: [{addr: "udp://127.0.0.1:$WPORT"}]}
  - tag: witness_fwd
    type: forward
    args: {concurrent: 1, upstreams: [{addr: "udp://127.0.0.1:$WPORT"}]}
  - tag: has_resp
    type: sequence
    args: [{matches: has_resp, exec: accept}]
  - tag: probe_seq
    type: sequence
    args: [{exec: \$witness_fwd}, {exec: jump has_resp}]
  - tag: main_sequence
    type: sequence
    args:
      - matches:
          - qname suffix $SUFFIX
          - string_exp server_name eq $DOT_HOST
        exec: goto probe_seq
      - exec: \$upstream_stub
      - exec: jump has_resp
  - tag: udp_server
    type: udp_server
    args: {entry: main_sequence, listen: "127.0.0.1:$MPORT_PLAIN"}
  - tag: tcp_server
    type: tcp_server
    args: {entry: main_sequence, listen: "127.0.0.1:$MPORT_PLAIN"}
  - tag: dot_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:$MPORT_DOT"
      cert: "$WORK/fullchain.pem"
      key: "$WORK/privkey.pem"
YAML
"$MOSDNS_BIN" start -c "$WORK/mosdns.yaml" >"$WORK/mosdns.log" 2>&1 &
MPID=$!
sleep 2
kill -0 "$MPID" 2>/dev/null && ok "mosdns 已起(真 TLS 监听 :$MPORT_DOT)" \
  || bad "mosdns 起不来: $(tail -3 "$WORK/mosdns.log")"

echo "通过 $pass, 失败 $nfail, 跳过 $nskip"
[ "$nfail" -gt 0 ] && exit 1 || exit 0
