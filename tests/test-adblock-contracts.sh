#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DNS 去广告的行为契约,全部跑**真 mosdns** + **生产模板**。
#
# 已裁决的优先级(从高到低):
#   1 基础设施强制放行 → 2 用户 allow → 3 用户 block → 4 用户显式分流
#   → 5 第三方广告表 → 6 自动批量规则 / geosite / 默认出口
# 其中两条最容易写反,单独点名:
#   · 用户 block **可以**压过用户自己的显式分流(custom_hijack);
#   · 第三方表**不得**压过显式分流 —— 那是 test-rule-precedence.py 那条
#     "用户点名 > 自动生成的批量规则" 契约在 DNS 侧的延续。
#
# 域名一律用 .invalid(RFC 6761 保留),不含任何真实广告域名或生产域名。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ADB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ADB_ROOT
# shellcheck source=tests/adblock-lib.sh
source "$ADB_ROOT/tests/adblock-lib.sh"

PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)" || exit 1
cleanup(){ adb_stop; [[ -n "${PDG_KEEP_TMP:-}" ]] && { echo "现场保留: $WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT

MOSDNS="$(adb_mosdns "$WORK")" || { echo "[FAIL] 拿不到钉死版 mosdns —— 这一组测的就是真 mosdns 的行为, 不能跳过"; exit 1; }
adb_rules_dir "$WORK"
adb_cert "$WORK" || { echo "[FAIL] 生成自签证书失败(缺 openssl?) —— DoT 那一路测不了, 不跳过"; exit 1; }

R="$WORK/etc/mosdns/rules"
V="$WORK/var/adblock"
CONF="$WORK/config.yaml"
UPLOG="$WORK/upstream.log"

# ── 合成规则 ────────────────────────────────────────────────────────────────
# infra: 基础设施(DoT / 面板 / WLOC / 更新源 / ACME), 谁都压不过
printf 'domain:dot.adb.invalid\ndomain:panel.adb.invalid\ndomain:wloc.adb.invalid\ndomain:updates.adb.invalid\n' > "$V/infra_allow.txt"
# 用户 allow
printf 'domain:allowme.ads.invalid\ndomain:bothlists.invalid\n' > "$R/adblock_allow.txt"
# 用户 block(其中 routed-blocked 同时是显式分流域名 → 用户 block 必须压过它)
printf 'domain:userblocked.invalid\ndomain:bothlists.invalid\ndomain:routed-blocked.invalid\n' > "$R/adblock_block.txt"
# 第三方表(其中 routed-listed 同时是显式分流域名 → 第三方**不得**压过它;
#           infra 那几个也塞进来 → 必须压不过基础设施白名单)
printf 'domain:ads.invalid\ndomain:allowme.ads.invalid\ndomain:routed-listed.invalid\ndomain:dot.adb.invalid\ndomain:panel.adb.invalid\ndomain:wloc.adb.invalid\ndomain:updates.adb.invalid\n' > "$V/effective_list.txt"
# 用户显式分流(custom_hijack.txt 是生产里 explicit_proxy 的真源)
printf 'domain:routed-blocked.invalid\ndomain:routed-listed.invalid\n' > "$R/custom_hijack.txt"

adb_render "$CONF" "$WORK" || { echo "[FAIL] 渲染生产模板失败"; exit 1; }
# 把沙盒里的规则路径接上(生产模板写的是 /etc/mosdns/... 与 /var/lib/... 的字面路径)
sed -i -e "s|/etc/mosdns/rules|$R|g" -e "s|/var/lib/privdns-gateway/adblock|$V|g" "$CONF"

adb_start "$MOSDNS" "$CONF" "$UPLOG" || { echo "[FAIL] mosdns 起不来(配置不合法?):"; tail -5 "$WORK"/*.log 2>/dev/null; exit 1; }

echo "══ 一、优先级逐格(真查询)══"

chk(){ # chk <域名> <期望rcode> <说明>
  local got; got="$(adb_q "$1" A udp)"
  [[ "$got" == "$2" ]] && ok "$3($1 → $got)" || bad "$3: $1 期望 $2, 实得 ${got:-无响应}"
}
chk dot.adb.invalid       NOERROR  "infra allow 压过第三方表"
chk panel.adb.invalid     NOERROR  "面板域名不被第三方表阻断"
chk wloc.adb.invalid      NOERROR  "WLOC 域名不被第三方表阻断"
chk updates.adb.invalid   NOERROR  "更新源域名不被第三方表阻断"
chk bothlists.invalid     NOERROR  "user allow 压过 user block"
chk allowme.ads.invalid   NOERROR  "user allow 压过第三方表"
chk userblocked.invalid   NXDOMAIN "user block 生效"
chk routed-blocked.invalid NXDOMAIN "user block 压过用户显式分流"
chk routed-listed.invalid NOERROR  "第三方表**不得**压过用户显式分流"
chk ads.invalid           NXDOMAIN "第三方表阻断"
chk deep.sub.ads.invalid  NXDOMAIN "第三方表的后缀匹配覆盖子域"
chk nothing.invalid       NOERROR  "无命中 → 现有解析行为"

echo "══ 二、三协议一致(UDP / TCP / DoT)══"
for d in ads.invalid userblocked.invalid; do
  u="$(adb_q "$d" A udp)"; t="$(adb_q "$d" A tcp)"; o="$(adb_qdot "$d" 1)"
  [[ "$u" == NXDOMAIN && "$t" == NXDOMAIN && "$o" == NXDOMAIN ]] \
    && ok "三协议一致 NXDOMAIN($d: udp=$u tcp=$t dot=$o)" \
    || bad "三协议不一致($d: udp=$u tcp=$t dot=$o)"
done
for qt in 28 65; do
  o="$(adb_qdot ads.invalid "$qt")"
  [[ "$o" == NXDOMAIN ]] && ok "DoT 上 qtype=$qt 同样阻断" || bad "DoT qtype=$qt 未阻断(实得 $o)"
done

echo "══ 三、被阻断的查询不得访问上游 ══"
for d in ads.invalid userblocked.invalid routed-blocked.invalid; do
  adb_upstream_saw "$d" "$UPLOG" \
    && bad "被阻断的 $d 仍到达了上游(阻断成功但泄漏)" \
    || ok "被阻断的 $d 未到达上游"
done
# 上游账本的**在场对照**只能用"既没被阻断、也没被显式分流"的域名。
# routed-listed 不合格: 它在 custom_hijack 里, A 记录会被 explicit_proxy_seq 劫持到网关,
# 本来就不该到上游 —— 拿它当证人, "没到上游"证明不了账本有效(第一版就选错了这个证人)。
adb_upstream_saw nothing.invalid "$UPLOG" \
  && ok "未阻断的 nothing.invalid 正常到达上游(证明上游账本有效)" \
  || bad "未阻断的 nothing.invalid 没到上游 —— 上游账本可能是空的, 上面那几条无从谈起"

# 显式分流的域名应当"按显式路由解析": A 记录被劫持到网关地址, 而不是上游给的真实地址。
routed_ip="$(dig @127.0.0.1 -p "$ADB_UDP_PORT" +short +timeout=3 +tries=1 routed-listed.invalid A 2>/dev/null | head -1)"
[[ "$routed_ip" == "127.0.0.9" ]] \
  && ok "第三方表未干扰显式路由(routed-listed 仍解析到网关 $routed_ip)" \
  || bad "显式路由被破坏: routed-listed 解析到 ${routed_ip:-无}, 期望网关 127.0.0.9"

echo "══ 四、阻断判据必须排在 cache 命中终止点之前 ══"
# 按**执行顺序**判, 不是 grep 字面先后 —— 与 test-dot-witness.py:180 同一手法(文本 index
# 比较, 不引第三方 YAML 库: 这台机器上就没有 pyyaml, 而 CI 有没有不该由判据来赌)。
#
# 为什么这条要紧: internal_sequence 里 $lazy_cache 之后紧跟 `jump has_resp`, 缓存命中即
# accept 并终止整个序列; 排在其后的判据在缓存命中时**根本不会被执行**, 而 lazy_cache_ttl
# 是 86400 —— 一旦出现"不重启就换表"的路径, 就有最长 24h 的绕过窗口。
seq_body(){ awk '/^  - tag: internal_sequence$/{f=1} f&&/^  - tag: /&&!/internal_sequence/{exit} f' "$CONF"; }
body="$(seq_body)"
if [[ -z "$body" ]]; then
  bad "抽不到 internal_sequence —— 位置判据无从谈起"
elif ! grep -q 'adblock' <<<"$body"; then
  bad "internal_sequence 里没有任何 adblock 判据"
else
  b=$(grep -n 'adblock' <<<"$body" | head -1 | cut -d: -f1)
  c=$(grep -n '\$lazy_cache' <<<"$body" | head -1 | cut -d: -f1)
  if [[ -z "$c" ]]; then
    bad "抽不到 lazy_cache —— 位置判据无从谈起"
  elif [[ "$b" -lt "$c" ]]; then
    ok "adblock 判据(行#$b)排在 lazy_cache(行#$c)之前"
  else
    bad "adblock 判据(行#$b)排在 lazy_cache(行#$c)之后 —— 缓存命中会绕过阻断"
  fi
fi

echo "══ 五、DoT 探测命名空间不受影响 ══"
main_body(){ awk '/^  - tag: main_sequence$/{f=1} f&&/^  - tag: /&&!/main_sequence/{exit} f' "$CONF"; }
mb="$(main_body)"
pr=$(grep -n 'goto probe_seq' <<<"$mb" | head -1 | cut -d: -f1)
it=$(grep -n 'goto internal_sequence' <<<"$mb" | head -1 | cut -d: -f1)
if [[ -n "$pr" && -n "$it" && "$pr" -lt "$it" ]]; then
  ok "probe 命名空间仍排在 goto internal_sequence 之前(阻断到不了证据端)"
else
  bad "probe 命名空间的位置被破坏 —— DoT 证据链受影响(probe=#${pr:-无} internal=#${it:-无})"
fi

echo "─────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" == 0 ]]
