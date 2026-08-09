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
: > "$WORK/rules/custom_hijack.txt"
echo "domain:unlktest.example" > "$WORK/rules/unlock.txt"
echo "example.com" > "$WORK/rules/geosite_geolocation-!cn.txt"   # 劫持集(all 模式=geolocation-!cn): 代理域名在集内 → 被劫持
: > "$WORK/rules/mitm_hijack.txt"                                # MITM 接管域名(force_hijack): 本测试无, 留空
: > "$WORK/rules/ruleset_hijack.txt"                             # 规则集所需劫持域名(explicit_proxy 的第二个文件)
echo "blocked.example" > "$WORK/rules/geosite_gfw.txt"           # gfw 模式的劫持集(只含真被墙域名)

# ── 渲染真实 config.yaml → 测试版(上游指 mock, 端口换高位, 去掉 DoT server 省证书)──
MOCK_UP="{addr: \"udp://127.0.0.1:$MOCKP\"}"
render_conf(){   # $1=内网段  $2=local 上游内联(默认=单 mock; 故障转移测试传 好+坏)  $3=劫持集文件(默认 all 模式)
  local local_ups="${2:-$MOCK_UP}"
  local hijack_file="${3:-geosite_geolocation-!cn.txt}"
  # 按上游里的特征 IP 区分 remote(1.1.1.1)/local(223.5.5.5) 整行替换(兼容 concurrent: 前缀)。
  # __DOT_DOMAIN__ / __DOTWITNESS_PORT__ 也要替换: 这支末尾有"渲染后不许残留占位符"的
  # 通用断言, 漏一个就说明真机上那处会留着字面量。端口取自 dotwitness.py 的单一事实源。
  local dotw_port; dotw_port="$(sed -n 's/^DOTWITNESS_PORT[[:space:]]*=[[:space:]]*\([0-9]\{1,5\}\).*/\1/p' \
                                  "$ROOT/deploy/bot/dotwitness.py" | head -1)"
  : "${dotw_port:?读不到 dotwitness.py 的 DOTWITNESS_PORT}"
  sed -e "s/__SERVER_IP__/$SERVER_IP/g" -e "s#__INTERNAL_CIDR__#$1#g" -e "s#__CERT_DIR__#$WORK#g" \
      -e "s#__MOSDNS_CACHE__#8192#g" -e "s#__HIJACK_SET_FILE__#$hijack_file#g" \
      -e "s#__DOT_DOMAIN__#dot.policy.test#g" -e "s#__DOTWITNESS_PORT__#$dotw_port#g" \
      "$ROOT/deploy/mosdns/config.yaml" \
    | sed -e "s#^\([[:space:]]*\)args: {.*1\.1\.1\.1.*}#\1args: { concurrent: 2, upstreams: [ $MOCK_UP ] }#" \
          -e "s#^\([[:space:]]*\)args: {.*223\.5\.5\.5.*}#\1args: { concurrent: 2, upstreams: [ $local_ups ] }#" \
          -e "s#^\([[:space:]]*\)args: {.*22\.22\.22\.22.*}#\1args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$UNLOCKP\"} ] }#" \
          -e "s#/etc/mosdns/rules/#$WORK/rules/#g" \
          -e "s#0.0.0.0:53#127.0.0.1:$DNSP#g" \
          -e "/- tag: dot_server/,\$d" \
      > "$WORK/config.yaml"
  if [[ "${PDG_NC_DROP_EXPLICIT_GATE:-0}" == 1 ]]; then
    grep -q 'qname \$explicit_proxy' "$WORK/config.yaml" \
      || fail "负控失效: 渲染产物里本来就没有 explicit_proxy 判断(删了个不存在的东西=空跑)"
    sed -i '/matches: qname \$explicit_proxy/,+1d' "$WORK/config.yaml"
    grep -q 'qname \$explicit_proxy' "$WORK/config.yaml" \
      && fail "负控失效: 判断没被删掉"
    grep -q 'tag: explicit_proxy_seq' "$WORK/config.yaml" \
      || fail "负控过头: 连序列插件都删了(要删的只是那道判断)"
    echo "[NC] 已从渲染产物里删除「明确代理优先于 geosite_cn」判断(序列插件保留)"
  fi
  # 通用断言: 渲染后不得残留任何 __XXX__ 占位符(漏渲染=mosdns 加载失败/规则错位)
  local leftover; leftover="$(grep -oE '__[A-Z_]+__' "$WORK/config.yaml" | sort -u | tr '\n' ' ')"
  [[ -z "$leftover" ]] || fail "渲染后残留占位符: $leftover"
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

# ── 5. 明确代理优先级: 用户点名指到出口的域名, 必须先于 geosite_cn 判断 ─────────
#
# 现场故障(`.200`): 上游 geosite 把**整个 byte-test.com 归进 CN**, 而 hijack_set 那道门排在
# CN 判断之后 —— 于是 bot 里加的 `perfops2.byte-test.com → hk` 从没生效过: DNS 先返了真实
# 地址, 流量根本不进 mihomo, 内核里那条 route 规则永远匹配不到。doctor 全绿, 规则也确实在。
#
# 这里用的 byte-test.com / perfops2 只是**复刻那次现场的测试夹具**, 项目默认规则里没有、
# 也不该有它们(字节跳动国内/海外业务不是靠域名后缀能自动分的)。
note "种明确代理相关规则(byte-test.com 整站被上游判 CN, 只有 perfops2 被点名指到出口)…"
{ echo "qq.com"; echo "byte-test.com"; echo "example.cn"; } > "$WORK/rules/geosite_cn.txt"
{ echo "# pdg-bot 显式出口域名劫持表"
  echo "domain:perfops2.byte-test.com"
  echo "domain:mixed.example.cn"; } > "$WORK/rules/custom_hijack.txt"
echo "domain:rs.example.cn"   > "$WORK/rules/ruleset_hijack.txt"
echo "mixed.example.cn"       > "$WORK/rules/custom_direct.txt"    # 同时在直连表: 谁赢?
echo "domain:wloc.example.cn" > "$WORK/rules/mitm_hijack.txt"      # WLOC/MITM 接管
: > "$WORK/rules/unlock.txt"
render_conf "127.0.0.0/8"; start_mosdns

expect_eq      "明确代理: 被上游判 CN 的点名域名 A → 仍劫持到网关"  "$(q perfops2.byte-test.com A)" "$SERVER_IP"
expect_empty   "明确代理: AAAA → 置空(mock 本会回 AAAA)"           "$(q perfops2.byte-test.com AAAA)"
expect_empty   "明确代理: HTTPS(65) → 置空"                        "$(q perfops2.byte-test.com TYPE65)"
# 兄弟域名必须不受影响 —— 这是"定向规则"而不是"把整个 zone 劫了"的分界线。
expect_eq      "同 zone 未点名的兄弟域名 A → 仍走直连上游"          "$(q perfops.byte-test.com A)"  "$UPSTREAM_IP"
expect_eq      "规则集劫持表(ruleset_hijack)里的 CN 域名 A → 进网关" "$(q rs.example.cn A)"          "$SERVER_IP"
expect_empty   "规则集劫持表: AAAA → 置空"                          "$(q rs.example.cn AAAA)"
expect_eq      "普通 geosite_cn 域名 A → 真实地址(不退化)"          "$(q www.qq.com A)"             "$UPSTREAM_IP"
expect_nonempty "普通 geosite_cn 域名 AAAA → 不被置空"              "$(q www.qq.com AAAA)"
expect_eq      "WLOC/MITM force_hijack 仍高于 geosite_cn"           "$(q wloc.example.cn A)"        "$SERVER_IP"
# 直连表 + 劫持表同时有 → 劫持赢。所以 bot 把域名改判直连时**必须**同时清掉旧劫持记录,
# 否则"设为直连"会静默失效。下一条就是清掉之后的对照。
expect_eq      "既在直连表又在劫持表 → 劫持赢(故改直连必须清旧记录)" "$(q mixed.example.cn A)"      "$SERVER_IP"
note "模拟 bot「改判直连」: 从 custom_hijack 移除该域名后重载…"
{ echo "# pdg-bot 显式出口域名劫持表"; echo "domain:perfops2.byte-test.com"; } > "$WORK/rules/custom_hijack.txt"
start_mosdns
expect_eq      "清除旧劫持记录后 → 真的回到直连"                    "$(q mixed.example.cn A)"       "$UPSTREAM_IP"
expect_eq      "清除后: 另一条点名规则不受牵连"                     "$(q perfops2.byte-test.com A)" "$SERVER_IP"

# ── 6. gfw 模式: 劫持集只含真被墙域名, 明确代理仍须优先 ────────────────────────
note "渲染(gfw 模式: 劫持集=geosite_gfw.txt)并重起 mosdns…"
render_conf "127.0.0.0/8" "" "geosite_gfw.txt"; start_mosdns
expect_eq      "gfw 模式: 点名的 CN 域名 A → 仍劫持到网关"          "$(q perfops2.byte-test.com A)" "$SERVER_IP"
expect_empty   "gfw 模式: 点名域名 AAAA → 置空"                     "$(q perfops2.byte-test.com AAAA)"
expect_eq      "gfw 模式: 被墙域名 A → 劫持到网关"                  "$(q blocked.example A)"        "$SERVER_IP"
expect_eq      "gfw 模式: 非墙海外域名 A → 真实地址(SSH/直连不被劫)" "$(q example.com A)"           "$UPSTREAM_IP"
expect_nonempty "gfw 模式: 非墙海外域名 AAAA → 不被置空"            "$(q example.com AAAA)"
expect_eq      "gfw 模式: 普通国内域名 A → 直连上游"                "$(q www.qq.com A)"             "$UPSTREAM_IP"
expect_eq      "gfw 模式: WLOC/MITM 仍最高优先级"                   "$(q wloc.example.cn A)"        "$SERVER_IP"

# ── 7. all 模式复核(第 4a 段已验非CN劫持; 这里确认换回 all 后明确代理依旧成立)──
note "渲染(all 模式: 劫持集=geolocation-!cn)并重起 mosdns…"
render_conf "127.0.0.0/8"; start_mosdns
expect_eq      "all 模式: 点名的 CN 域名 A → 劫持到网关"            "$(q perfops2.byte-test.com A)" "$SERVER_IP"
expect_eq      "all 模式: 非CN 域名 A → 劫持到网关(原语义不变)"     "$(q example.com A)"            "$SERVER_IP"
expect_empty   "all 模式: 非CN 域名 AAAA → 置空(原语义不变)"        "$(q example.com AAAA)"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" -eq 0 ]] || exit 1
echo "✅ DNS 层功能测试全过"
