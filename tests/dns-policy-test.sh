#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DNS 层功能测试(非静态): 真起 mosdns + 渲染真实 deploy/mosdns/config.yaml,
# 验证本项目的另一半核心 ——「DNS as policy」:
#   内网来源(client_ip ∈ 内网段):
#     • 代理域名(非 geosite_cn)A  → 劫持到网关 IP(black_hole)
#     • 代理域名 AAAA / HTTPS(65) → 置空(reject 0)
#     • 国内域名(geosite_cn)A     → 直连走上游(不劫持)
#   非内网来源:
#     • 代理域名 A → 不劫持, 走上游(证明按来源 IP 门控)
#
# 全本地: 上游用 mock_dns.py, 不出网, 可在 CI / 干净机跑。
# 退出码 0=通过, 非 0=失败。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh"

WORK="$(mktemp -d)"
PIDS=()
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
fail(){ echo "[FAIL] $*" >&2; [[ -f "$WORK/mosdns.out" ]] && sed 's/^/    mosdns| /' "$WORK/mosdns.out" >&2; exit 1; }
note(){ echo "[*] $*"; }

SERVER_IP="10.99.99.99"      # 劫持目标(标记 IP)
UPSTREAM_IP="198.51.100.7"   # mock 上游对 A 查询的固定应答(代表"真实直连结果")
UNLOCK_IP="203.0.113.55"     # mock 解锁上游(代表 WDA 中继 IP, 区别于普通上游)
MOCKP=15300; DNSP=15353; UNLOCKP=15301

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;;
  *) fail "不支持的架构: $(uname -m)" ;;
esac

# ── 依赖: dig ──
if ! command -v dig >/dev/null; then
  note "装 dnsutils(dig)…"
  if [[ $EUID -eq 0 ]]; then S=""; else S="sudo"; fi
  $S apt-get update -qq && { $S apt-get install -y -qq dnsutils >/dev/null 2>&1 \
    || $S apt-get install -y -qq bind9-dnsutils >/dev/null 2>&1; }
fi
command -v dig >/dev/null || fail "需要 dig(dnsutils/bind9-dnsutils)"

# ── 1. 取 mosdns(优先 PATH; 否则按钉死 SHA256 下载)──
if command -v mosdns >/dev/null; then
  MD="$(command -v mosdns)"; note "用现有 mosdns: $MD"
else
  note "下载 mosdns $MOSDNS_VER ($ARCH)…"
  curl -fsSL "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-${ARCH}.zip" \
       -o "$WORK/m.zip" || fail "mosdns 下载失败"
  pdg_verify_sha256 "$WORK/m.zip" "${PDG_SHA256[mosdns-$ARCH]:-}" "mosdns $MOSDNS_VER ($ARCH)" \
    || fail "mosdns SHA256 校验失败"
  (cd "$WORK" && unzip -q m.zip) || fail "解压 mosdns 失败"
  MD="$WORK/mosdns"; chmod +x "$MD"
fi

# ── 2. mock 上游(普通 + 解锁两套, 答不同 IP 以区分走了哪条)──
python3 "$HERE/mock_dns.py" "$MOCKP"   "$UPSTREAM_IP" & PIDS+=($!)
python3 "$HERE/mock_dns.py" "$UNLOCKP" "$UNLOCK_IP"   & PIDS+=($!)

# ── 3. 规则: geosite_cn 放一个国内域名, unlock 放一个解锁测试域名, 其余留空 ──
mkdir -p "$WORK/rules"
echo "qq.com" > "$WORK/rules/geosite_cn.txt"
: > "$WORK/rules/geosite_apple.txt"
: > "$WORK/rules/custom_direct.txt"
echo "domain:unlktest.example" > "$WORK/rules/unlock.txt"

# ── 渲染真实 config.yaml → 测试版(上游指 mock, 端口换高位, 去掉 DoT server 省证书)──
MOCK_UP="{addr: \"udp://127.0.0.1:$MOCKP\"}"
render_conf(){   # $1=内网段  $2=local 上游内联(默认=单 mock; 故障转移测试传 好+坏)
  local local_ups="${2:-$MOCK_UP}"
  # 按上游里的特征 IP 区分 remote(1.1.1.1)/local(223.5.5.5) 整行替换(兼容 concurrent: 前缀)。
  sed -e "s/__SERVER_IP__/$SERVER_IP/g" -e "s#__INTERNAL_CIDR__#$1#g" -e "s#__CERT_DIR__#$WORK#g" \
      -e "s#__MOSDNS_CACHE__#8192#g" \
      "$ROOT/deploy/mosdns/config.yaml" \
    | sed -e "s#^\([[:space:]]*\)args: {.*1\.1\.1\.1.*}#\1args: { concurrent: 2, upstreams: [ $MOCK_UP ] }#" \
          -e "s#^\([[:space:]]*\)args: {.*223\.5\.5\.5.*}#\1args: { concurrent: 2, upstreams: [ $local_ups ] }#" \
          -e "s#^\([[:space:]]*\)args: {.*22\.22\.22\.22.*}#\1args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UNLOCKP\"} ] }#" \
          -e "s#/etc/mosdns/rules/#$WORK/rules/#g" \
          -e "s#0.0.0.0:53#127.0.0.1:$DNSP#g" \
          -e "/- tag: dot_server/,\$d" \
      > "$WORK/config.yaml"
}

start_mosdns(){   # 重启 mosdns 加载当前 config
  for p in "${PIDS[@]:-}"; do
    [[ "$(cat /proc/$p/comm 2>/dev/null)" == mosdns ]] && kill "$p" 2>/dev/null
  done
  "$MD" start -d "$WORK" > "$WORK/mosdns.out" 2>&1 & PIDS+=($!)
  for _ in $(seq 1 50); do
    dig +short +time=1 +tries=1 "@127.0.0.1" -p "$DNSP" ready.probe A >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "mosdns :$DNSP 未就绪"
}

q(){ dig +short +time=2 +tries=1 "@127.0.0.1" -p "$DNSP" "$1" "$2" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
ko(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
expect_eq(){ [[ "$2" == "$3" ]] && ok "$1 ($2)" || ko "$1: 期望「$3」实得「$2」"; }
expect_empty(){ [[ -z "$2" ]] && ok "$1 (空)" || ko "$1: 期望空, 实得「$2」"; }
expect_nonempty(){ [[ -n "$2" ]] && ok "$1 ($2)" || ko "$1: 期望非空, 实得空"; }

# ── 4a. 内网来源(内网段=127.0.0.0/8, 故本机 dig 即"内网")──
# 注意: mock 上游对 AAAA/HTTPS **会返回非空记录**, 所以"代理域名被置空"证明的是 mosdns 抑制逻辑(非 mock 巧合)。
note "渲染(内网段=127.0.0.0/8)并起 mosdns…"
render_conf "127.0.0.0/8"; start_mosdns
expect_eq      "代理域名 A → 劫持到网关IP"            "$(q example.com A)"     "$SERVER_IP"
expect_empty   "代理域名 AAAA → mosdns 置空(mock 本会回 AAAA)"   "$(q example.com AAAA)"
expect_empty   "代理域名 HTTPS(65) → mosdns 置空"     "$(q example.com TYPE65)"
expect_eq      "国内域名 A → 直连走上游"              "$(q www.qq.com A)"      "$UPSTREAM_IP"
expect_nonempty "国内域名 AAAA → 不被置空(走上游)"    "$(q www.qq.com AAAA)"

# ── 4b. 非内网来源(内网段不含 127, 故本机 dig 视为"外部")──
note "渲染(内网段=10.200.0.0/16, 本机=外部来源)并重起 mosdns…"
render_conf "10.200.0.0/16"; start_mosdns
expect_eq      "外部来源: 代理域名 A 不劫持, 走上游"  "$(q example.com A)"     "$UPSTREAM_IP"
# WDA 解锁支: 本机(sing-box 直出源)查解锁域名 → 走解锁 DNS(非普通上游)。
# 若 main_sequence 漏了 `jump has_resp`, 解锁答案会被 remote_upstream 覆盖成 $UPSTREAM_IP → 此断言即失败。
expect_eq      "WDA解锁支: 解锁域名 → 解锁DNS(非普通上游)" "$(q unlktest.example A)" "$UNLOCK_IP"
# 落地模式回归: 清空 unlock.txt → 解锁支休眠, 解锁域名回落普通上游(关 WDA 必须清空 unlock.txt 才彻底)
note "清空 unlock.txt(= 落地模式)…"; : > "$WORK/rules/unlock.txt"; start_mosdns
expect_eq      "落地(空 unlock.txt): 解锁域名 → 普通上游" "$(q unlktest.example A)" "$UPSTREAM_IP"

# ── 4c. 上游故障转移(concurrent=2): local = [好 mock, 死端口], 连查多个不同国内子域都应成功 ──
# (用不同子域绕开缓存; 若 concurrent 退回默认 1=随机选 1 个不转移, 约半数会命中死端口而失败)
note "渲染(local=好+坏上游)验证一台上游挂掉仍可解析…"
render_conf "127.0.0.0/8" "$MOCK_UP, {addr: \"udp://127.0.0.1:15999\"}"; start_mosdns
down=0
for i in $(seq 1 8); do
  [[ "$(q "t$i.qq.com" A)" == "$UPSTREAM_IP" ]] || down=$((down+1))
done
[[ "$down" -eq 0 ]] && ok "上游故障转移: 坏上游在列时 8/8 国内查询仍成功" \
  || ko "上游故障转移: $down/8 失败(concurrent 没生效 → 退回随机选 1 不转移?)"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" -eq 0 ]] || exit 1
echo "✅ DNS 层功能测试全过"
