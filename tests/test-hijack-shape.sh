#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# issue #1 回归: `all` 模式必须是**排除式**(不是国内就劫持), 不是白名单。
#
# 背景: 加 gfw 劫持模式时, all 也被做成了白名单(hijack_set=geolocation-!cn), 并想当然
# 认为"非CN都在集内"。但 geolocation-!cn 是 geosite 的**策展分类**, 任意/个人域名根本
# 不在里面 —— 于是 all 静默退化成一个更窄的 gfw: 用户在 bot 里指到出口的域名照样直连。
# 网关本来的形态(线上老机器仍是这个)是排除式: force_hijack → geosite_cn 直连 → 其余全劫持。
#
# 覆盖: 归一化器双向幂等 / 老形态补 hijack_set / 自定义形态不猜着改 / 真起 mosdns 验证
# all 与 gfw 的实际解析行为。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# shellcheck source=lib/mosdns.sh
source "$ROOT/lib/mosdns.sh"

SIP=203.0.113.1
render(){ sed -e "s|__SERVER_IP__|$SIP|g" -e 's|__INTERNAL_CIDR__|127.0.0.0/8|g' \
              -e 's|__CERT_DIR__|/tmp/nocert|g' -e 's|__SSH_PORT__|22|g' \
              -e 's|__MOSDNS_CACHE__|1024|g' -e 's|__HIJACK_SET_FILE__|geosite_gfw.txt|g' \
              -e "s|__HIJACK_SET_FILE__|geosite_gfw.txt|g" "$ROOT/deploy/mosdns/config.yaml"; }
gate(){ grep -c '!qname \$hijack_set' "$1"; }
plug(){ grep -c '\- tag: hijack_set' "$1"; }

# ── 1. 归一化器: 双向切换 + 幂等 ──
C="$WORK/c.yaml"; render > "$C"
[[ "$(gate "$C")" == 2 ]] && ok "模板自带 gfw 劫持门" || bad "模板形态变了"
_mosdns_hijack_shape all "$C" 'geosite_geolocation-!cn.txt' >/dev/null
{ [[ "$(gate "$C")" == 0 ]] && [[ "$(plug "$C")" == 1 ]]; } \
  && ok "→ all: 去掉劫持门(排除式), 保留 hijack_set 插件" || bad "1a: 门=$(gate "$C")"
[[ "$(_mosdns_hijack_shape all "$C" 'geosite_geolocation-!cn.txt')" == nochange ]] \
  && ok "→ all 幂等" || bad "1b"
_mosdns_hijack_shape gfw "$C" geosite_gfw.txt >/dev/null
{ [[ "$(gate "$C")" == 2 ]] && grep -q 'geosite_gfw.txt' "$C"; } \
  && ok "→ gfw: 装回劫持门 + 切到 gfw 劫持集" || bad "1c"
[[ "$(_mosdns_hijack_shape gfw "$C" geosite_gfw.txt)" == nochange ]] && ok "→ gfw 幂等" || bad "1d"

# ── 2. 老形态(线上老机器: 无 hijack_set 插件)→ 补插件, all 语义不变 ──
O="$WORK/old.yaml"; render | grep -v 'hijack_set' > "$O"
{ [[ "$(plug "$O")" == 0 ]] && [[ "$(gate "$O")" == 0 ]]; } || bad "2 前置: 老形态构造失败"
_mosdns_hijack_shape all "$O" 'geosite_geolocation-!cn.txt' >/dev/null
{ [[ "$(plug "$O")" == 1 ]] && [[ "$(gate "$O")" == 0 ]]; } \
  && ok "老形态: 补上 hijack_set 插件, all 仍是排除式(不装门)" || bad "2a"
_mosdns_hijack_shape gfw "$O" geosite_gfw.txt >/dev/null
[[ "$(gate "$O")" == 2 ]] && ok "老形态: 切 gfw 时才装门(从此有 gfw 能力)" || bad "2b"

# ── 3. 自定义形态: 不猜着改 ──
X="$WORK/x.yaml"; render | sed 's/        exec: \$ecs_neutral/        exec: $my_custom_handler/' > "$X"
before="$(md5sum "$X" | cut -d' ' -f1)"
_mosdns_hijack_shape all "$X" 'geosite_geolocation-!cn.txt' >/dev/null 2>&1
[[ "$(md5sum "$X" | cut -d' ' -f1)" == "$before" ]] \
  && ok "自定义劫持门: 原样不动(不猜着改)" || bad "3: 改动了自定义配置"

# ── 4. 真起 mosdns: all 必须劫持"不在任何 geosite 分类里"的域名 ──
MOSDNS="$WORK/mosdns"
if ! command -v mosdns >/dev/null 2>&1 && [[ ! -x "$MOSDNS" ]]; then
  # 复用 dns-policy-test 的下载方式(有则用系统的)
  if ! bash -c 'source '"$ROOT"'/lib/versions.sh; curl -fsSL "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-amd64.zip" -o '"$WORK"'/m.zip' 2>/dev/null \
     || ! (cd "$WORK" && unzip -qo m.zip mosdns 2>/dev/null); then
    ok "真起 mosdns 验证(无法获取 mosdns 二进制, 跳过)"
    echo "────────────────────────────────────────"; echo "通过 $pass, 失败 $nfail"; [[ "$nfail" == 0 ]]; exit
  fi
fi
[[ -x "$MOSDNS" ]] || MOSDNS="$(command -v mosdns)"

mkrules(){ mkdir -p "$WORK/rules"
  printf 'domain:cn-site.test\n'  > "$WORK/rules/geosite_cn.txt"
  : > "$WORK/rules/geosite_apple.txt"; : > "$WORK/rules/custom_direct.txt"
  : > "$WORK/rules/custom_hijack.txt"; : > "$WORK/rules/mitm_hijack.txt"
  : > "$WORK/rules/unlock.txt"
  printf 'domain:blocked.test\n' > "$WORK/rules/geosite_gfw.txt"
  printf 'domain:listed-oversea.test\n' > "$WORK/rules/geosite_geolocation-!cn.txt"
}
mkrules
serve(){  # $1=mode $2=劫持集文件名
  local cfg="$WORK/config.yaml"
  # 先归一化(它写 /etc/mosdns/rules 绝对路径), 再按 dns-policy-test 那套配方落到沙箱
  render > "$cfg"
  _mosdns_hijack_shape "$1" "$cfg" "$2" >/dev/null
  sed -i -e "s#/etc/mosdns/rules/#$WORK/rules/#g" \
         -e "s#0.0.0.0:53#127.0.0.1:15353#g" \
         -e "s#^\([[:space:]]*\)args: {.*1\.1\.1\.1.*}#\1args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:15999\"} ] }#" \
         -e "s#^\([[:space:]]*\)args: {.*223\.5\.5\.5.*}#\1args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:15999\"} ] }#" \
         -e "s#^\([[:space:]]*\)args: {.*22\.22\.22\.22.*}#\1args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:15999\"} ] }#" \
         -e "/- tag: dot_server/,\$d" "$cfg"
  local leftover; leftover="$(grep -oE '__[A-Z_]+__' "$cfg" | sort -u | tr '\n' ' ')"
  [[ -z "$leftover" ]] || bad "渲染后残留占位符: $leftover"
  "$MOSDNS" start -d "$WORK" >"$WORK/mosdns.log" 2>&1 &
  echo $! > "$WORK/pid"
  for _ in $(seq 1 50); do
    dig +short +time=1 +tries=1 @127.0.0.1 -p 15353 ready.probe A >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 0
}
stop(){ [[ -f "$WORK/pid" ]] && kill "$(cat "$WORK/pid")" 2>/dev/null; sleep 0.3; rm -f "$WORK/pid"; }
q(){ dig +short +time=2 +tries=1 @127.0.0.1 -p 15353 "$1" A 2>/dev/null | head -1; }

if ! command -v dig >/dev/null 2>&1; then
  ok "真起 mosdns 验证(无 dig, 跳过)"
else
  serve all 'geosite_geolocation-!cn.txt'
  if grep -qE '^Error:|FATAL' "$WORK/mosdns.log"; then
    bad "4: all 模式 mosdns 起不来: $(tail -3 "$WORK/mosdns.log")"
  else
    [[ "$(q unlisted-personal.test)" == "$SIP" ]] \
      && ok "all: 不在任何 geosite 分类里的域名 → 劫持到网关(修复前会返真实解析)" \
      || bad "4a: unlisted → $(q unlisted-personal.test)"
    [[ "$(q listed-oversea.test)" == "$SIP" ]] && ok "all: 策展分类内的海外域名 → 同样劫持" || bad "4b"
  fi
  stop

  serve gfw geosite_gfw.txt
  if grep -qE '^Error:|FATAL' "$WORK/mosdns.log"; then
    bad "5: gfw 模式 mosdns 起不来: $(tail -3 "$WORK/mosdns.log")"
  else
    [[ "$(q blocked.test)" == "$SIP" ]] && ok "gfw: 劫持集内域名 → 劫持到网关" || bad "5a: blocked → $(q blocked.test)"
    [[ "$(q unlisted-personal.test)" != "$SIP" ]] \
      && ok "gfw: 集外海外域名 → 不劫持(走真实解析, 修 SSH/直连被劫持)" || bad "5b"
  fi
  stop
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
