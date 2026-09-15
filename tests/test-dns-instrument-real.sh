#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DNS 仪器的**真二进制**验证: 真钉版 mosdns + 真 dig + 自有 DNS 上游。
# 没有字符串桩 —— mosdns、配置加载、真实查询都是真的; 只把**外围上游**设成可控端。
#
# 全程在自有临时根 + 回环高位端口上跑: 不碰宿主的 systemd / DNS / nft / 路由 / sysctl,
# 也不占 53。mosdns 二进制只**执行**, 不改不装。
#
# 它回答四件事(上一轮的归因就是栽在没问这几句):
#   1. 当前 all 形态下, 标定名/见证名/对照名各命中哪条分支、答什么、上游有没有收到查询;
#   2. force_hijack 与普通劫持是不是同一个地址;
#   3. 不重启 mosdns 时, 缓存会不会让第二次查询绕过刚改的规则;
#   4. 把名字放进 geosite_cn(既有合法输入)之后, 同一查询名能不能精确走出 U→H→U。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
P=0; F=0
ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MOSDNS="${MOSDNS_BIN:-/usr/local/bin/mosdns}"
for c in "$MOSDNS" dig openssl; do
  command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]] || { echo "[未执行] 缺 $c —— 真二进制验证跑不了, 不冒充通过"; exit 1; }
done
WANT_VER="$(grep -m1 '^MOSDNS_VER=' "$ROOT/lib/versions.sh" | cut -d'"' -f2)"
GOT_VER="$("$MOSDNS" version 2>&1 | head -1)"
case "$GOT_VER" in
  "$WANT_VER"*) ok "前提: mosdns 是钉死的那一版($GOT_VER, 期望 $WANT_VER)";;
  *) echo "[未执行] mosdns 版本是 $GOT_VER, 不是钉死的 $WANT_VER —— 换个版本测不算数"; exit 1;;
esac

W="$(mktemp -d "${TMPDIR:-/tmp}/dnsreal.XXXXXX")" || exit 1
cleanup(){ for f in "$W"/*.pid; do [[ -f "$f" ]] && { kill "$(cat "$f")" 2>/dev/null; }; done; rm -rf "$W"; }
trap cleanup EXIT
R="$W/rules"; mkdir -p "$R" "$W/certs" "$W/adblock"
PORT=15353; LPORT=15301; RPORT=15302; DOTPORT=15853
SIP=203.0.113.1; U=198.51.100.7; UR=198.51.100.9

for f in geosite_cn geosite_apple custom_direct custom_hijack ruleset_hijack unlock mitm_hijack \
         geosite_gfw adblock_allow adblock_block 'geosite_geolocation-!cn'; do : > "$R/$f.txt"; done
printf 'domain:baidu.com\n' > "$R/geosite_cn.txt"
printf 'domain:blocked.test\n' > "$R/geosite_gfw.txt"
for f in infra_allow effective_block effective_list; do : > "$W/adblock/$f.txt"; done
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/certs/privkey.pem" \
  -out "$W/certs/fullchain.pem" -days 30 -subj "/CN=e2e.example" >/dev/null 2>&1

# 与 e2e_seed_mosdns 同一套渲染 + 同一个 all 形态
sed -e "s|__SERVER_IP__|$SIP|g" -e "s|__INTERNAL_CIDR__|127.0.0.0/8|g" \
    -e "s|__CERT_DIR__|$W/certs|g" -e 's|__SSH_PORT__|22|g' -e 's|__SSH_MATCH__||g' \
    -e 's|__TAILNET_DIRECT__||g' -e 's|__MOSDNS_CACHE__|1024|g' \
    -e 's|__HIJACK_SET_FILE__|geosite_geolocation-!cn.txt|g' -e 's|__DOT_DOMAIN__|dot.e2e.test|g' \
    "$ROOT/deploy/mosdns/config.yaml" > "$W/config.yaml"
# shellcheck source=/dev/null
( cd "$ROOT" && . lib/mosdns.sh && _mosdns_hijack_shape all "$W/config.yaml" 'geosite_geolocation-!cn.txt' ) >/dev/null
grep -q '!qname \$hijack_set' "$W/config.yaml" \
  && bad "前提: all 形态没把劫持门移掉" || ok "前提: all 形态已移除 '!qname \$hijack_set → 上游' 那道门"
# 形态改完**之后**才本地化(shape 会插入带 /etc 绝对路径的 hijack_set 插件)
sed -i "s|/etc/mosdns/rules/|$R/|g; s|/var/lib/privdns-gateway/adblock/|$W/adblock/|g" "$W/config.yaml"
sed -i "s|listen: \"0.0.0.0:53\"|listen: \"127.0.0.1:$PORT\"|g; s|listen: \"0.0.0.0:853\"|listen: \"127.0.0.1:$DOTPORT\"|g" "$W/config.yaml"
python3 - "$W/config.yaml" "$LPORT" "$RPORT" <<'PYUP'
import re, sys
p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(p, encoding="utf-8").read().split("\n"); tag = None
for i, ln in enumerate(lines):
    m = re.match(r'  - tag: (local_upstream|remote_upstream)$', ln)
    if m: tag = m.group(1); continue
    if tag and ln.startswith("    args: "):
        lines[i] = '    args: { concurrent: 1, upstreams: [ {addr: "udp://127.0.0.1:%s"} ] }' % (l if tag == "local_upstream" else r)
        tag = None
open(p, "w", encoding="utf-8").write("\n".join(lines))
PYUP

stub(){ python3 "$ROOT/tests/helpers/dns-stub.py" --port "$1" --count "$W/$2.count" --log "$W/$2.log" \
          --mode answer-a --answer "$3" > "$W/$2.out" 2>&1 & echo $! > "$W/$2.pid"; }
stub "$LPORT" local "$U"; stub "$RPORT" remote "$UR"; sleep 1
boot(){
  [[ -f "$W/mosdns.pid" ]] && { kill "$(cat "$W/mosdns.pid")" 2>/dev/null; sleep 0.5; }
  "$MOSDNS" start -c "$W/config.yaml" > "$W/mosdns.out" 2>&1 & echo $! > "$W/mosdns.pid"
  local _n=0; while (( _n < 40 )); do ss -lnu 2>/dev/null | grep -q "127.0.0.1:$PORT" && return 0; sleep 0.25; _n=$((_n+1)); done
  return 1
}
boot || { echo "[未执行] mosdns 没起来: $(tail -3 "$W/mosdns.out")"; exit 1; }
ok "前提: 真 mosdns 已在 127.0.0.1:$PORT 起来(自有根, 不碰宿主 53)"

ans(){ dig +short +time=3 +tries=1 +retry=0 @127.0.0.1 -p "$PORT" "$1" A 2>/dev/null | head -1; }
hit(){ grep -c " q=$1 " "$W/$2.log" 2>/dev/null | tr -d '\n'; }

echo; echo "══ 1. 当前 all 形态: 同答反例, 且查询根本没到上游 ══"
L0="$(wc -l < "$W/local.count")"; R0="$(wc -l < "$W/remote.count")"
A1="$(ans dns-calib-x.e2e.test)"; A2="$(ans gs-loc.apple.com)"; A3="$(ans control-not-hijacked.e2e.test)"
L1="$(wc -l < "$W/local.count")"; R1="$(wc -l < "$W/remote.count")"
{ [[ "$A1" == "$SIP" && "$A2" == "$SIP" && "$A3" == "$SIP" ]]; } \
  && ok "1a: 三个名字都答 $SIP(标定名/见证名/对照名 全同) —— 复现了同答反例" \
  || bad "1a: 实得 $A1 / $A2 / $A3"
{ [[ "$L1" == "$L0" && "$R1" == "$R0" ]]; } \
  && ok "1b: 这三次查询**两个自有上游一次都没收到** —— 同答不是'上游对谁都一样', 是压根没问上游" \
  || bad "1b: 上游收到了(local $L0→$L1, remote $R0→$R1)"

echo; echo "══ 2. force_hijack 与普通劫持是不是同一个地址 ══"
printf 'full:gs-loc.apple.com\n' > "$R/mitm_hijack.txt"; boot
BH="$(ans gs-loc.apple.com)"; BP="$(ans plain-hijack.e2e.test)"
[[ "$BH" == "$BP" && -n "$BH" ]] \
  && ok "2a: 两条分支同一个地址($BH) ⇒ '往 mitm_hijack 加一条看答案变不变'在 all 形态下先天测不出东西" \
  || bad "2a: 不同($BH vs $BP) —— 本支的前提要重新核"

echo; echo "══ 3. 不重启时缓存会不会让查询绕过刚改的规则(在答案可区分的设计下)══"
CN=dns-cache-probe.e2e.test
printf 'domain:baidu.com\nfull:%s\n' "$CN" > "$R/geosite_cn.txt"; : > "$R/mitm_hijack.txt"; boot
C1="$(ans "$CN")"
printf 'full:%s\n' "$CN" > "$R/mitm_hijack.txt"          # 只改规则文件, 不重启
C2="$(ans "$CN")"
boot; C3="$(ans "$CN")"
[[ "$C1" == "$U" ]] && ok "3a: 未接管时确实从自有上游拿到 U=$U" || bad "3a: 实得 $C1"
[[ "$C2" == "$C1" ]] && ok "3b: 只改规则不重启 ⇒ 第二次仍是旧答案($C2) —— **缓存/未重载会绕过刚改的规则**" \
                     || bad "3b: 第二次已经变成 $C2"
[[ "$C3" == "$SIP" ]] && ok "3c: 重启之后才变成 H=$SIP ⇒ 两次测量之间必须重启" || bad "3c: 重启后是 $C3"

echo; echo "══ 4. 待测设计: 三个名字进 geosite_cn, 只让那一条接管条目变 ══"
NAME=dns-calib-real.e2e.test; CTRL=dns-ctrl-real.e2e.test
printf 'domain:baidu.com\nfull:%s\nfull:%s\n' "$NAME" "$CTRL" > "$R/geosite_cn.txt"
: > "$R/mitm_hijack.txt"; boot
n0="$(hit "$NAME" local)"
D1="$(ans "$NAME")"; K1="$(ans "$CTRL")"; n1="$(hit "$NAME" local)"
printf 'full:%s\n' "$NAME" > "$R/mitm_hijack.txt"; boot
D2="$(ans "$NAME")"; K2="$(ans "$CTRL")"; n2="$(hit "$NAME" local)"
: > "$R/mitm_hijack.txt"; boot
D3="$(ans "$NAME")"; K3="$(ans "$CTRL")"; n3="$(hit "$NAME" local)"
[[ "$D1" == "$U" && "$D2" == "$SIP" && "$D3" == "$U" ]] \
  && ok "4a: 同一查询名精确走出 U→H→U($D1 → $D2 → $D3)" || bad "4a: 实得 $D1 → $D2 → $D3"
[[ "$K1" == "$U" && "$K2" == "$U" && "$K3" == "$U" ]] \
  && ok "4b: 对照名两种配置下都保持 U($K1/$K2/$K3)" || bad "4b: 对照名变了 $K1/$K2/$K3"
[[ "$U" != "$SIP" ]] && ok "4c: U 与 H 明确不同($U vs $SIP)" || bad "4c: U 与 H 相同"
{ [[ "$n1" -gt "$n0" && "$n2" == "$n1" && "$n3" -gt "$n2" ]]; } \
  && ok "4d: 上游按名关联的记录对得上 —— 甲/还原甲问了上游, 乙**没问**(累计 $n0→$n1→$n2→$n3)" \
  || bad "4d: 上游命中序列不对($n0→$n1→$n2→$n3)"
[[ "$(hit "$NAME" remote)" == 0 ]] && ok "4e: 全程没有走 remote_upstream" || bad "4e: 走了 remote_upstream"

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
