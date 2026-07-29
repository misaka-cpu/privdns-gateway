#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 负控: 证明 dns-policy-test.sh 里那批「明确代理优先于 geosite_cn」的断言确实在**验这件事**。
#
# 为什么需要单独一个脚本: 一批断言全绿, 说明不了它们载荷在哪。本项目已经踩过两次 ——
# 断言绿是因为被测代码根本没跑、以及"负控补丁其实是惰性的"。所以这里同时验三件事:
#   1. 原样跑 → 必须 0;
#   2. 删掉那道判断后跑 → 必须非 0, 且**恰好**是明确代理那几条变红;
#   3. 与之无关的对照断言(WLOC/MITM、普通国内域名、gfw 非墙域名)必须仍然绿 ——
#      否则"变红"可能只是把 mosdns 整个弄坏了, 证明不了优先级。
#
# 删的是**渲染产物里的那道判断**(行为), 不是源码里的某个字面量: 删掉后 mosdns 照常启动、
# 照常应答, 只是分流结论变了。grep 源码的写法验不出这个。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/dns-policy-test.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

[[ -f "$TARGET" ]] || { bad "找不到被测用例: $TARGET"; echo "通过 $pass, 失败 $nfail"; exit 1; }

# 被测用例本身要真内核 + dig。缺了就不是"负控不成立", 而是前提没有 —— 按全项目惯例,
# CI/严格模式下判失败(零断言退 0 才是假绿), 本地允许跳过。
missing=""
command -v dig >/dev/null 2>&1 || missing="dig"
[[ -x /usr/local/bin/mosdns ]] || command -v mosdns >/dev/null 2>&1 || missing="${missing:+$missing, }mosdns"
if [[ -n "$missing" ]]; then
  echo "[SKIP] 缺前提: $missing"
  if [[ -n "${PDG_TEST_STRICT:-}" && "${PDG_TEST_STRICT}" != "0" ]] || [[ "${CI:-}" == "true" ]]; then
    echo "严格模式(PDG_TEST_STRICT/CI): 缺必需前提 → 判失败"
    echo "通过 0, 失败 1(前提缺失)"; exit 1
  fi
  echo "通过 0, 失败 0(已跳过)"; exit 0
fi

# ── 1. 原样跑: 必须全绿 ──
echo "[*] 基线: 原样跑 dns-policy-test.sh…"
timeout 900 bash "$TARGET" > "$WORK/base.log" 2>&1; base_rc=$?
if [[ "$base_rc" == 0 ]]; then
  ok "基线: 原样跑通过(rc=0)"
else
  bad "基线: 原样跑就没通过(rc=$base_rc) —— 负控无从谈起"
  sed 's/^/    base| /' "$WORK/base.log" | tail -40
  echo "通过 $pass, 失败 $nfail"; exit 1
fi

# ── 2. 删掉那道判断后跑: 必须非 0 ──
echo "[*] 负控: 删掉「明确代理优先于 geosite_cn」判断后再跑…"
PDG_NC_DROP_EXPLICIT_GATE=1 timeout 900 bash "$TARGET" > "$WORK/nc.log" 2>&1; nc_rc=$?
[[ "$nc_rc" != 0 ]] && ok "负控: 删掉判断后用例变红(rc=$nc_rc)" \
                    || bad "负控: 删掉判断后用例**仍然通过** —— 那批断言没在验优先级"

# 补丁真的落地了吗(惰性补丁 = 假负控)
grep -q '^\[NC\] 已从渲染产物里删除' "$WORK/nc.log" \
  && ok "负控补丁确实落地(渲染产物里的判断被删且被复核)" \
  || bad "负控补丁没落地: 日志里没有 [NC] 行"

# ── 3. 变红的**恰好**是明确代理那批, 对照断言仍绿 ──
# 期望变红的(FAIL) —— 每条都必须在 nc.log 里以 [FAIL] 出现
must_fail=(
  "明确代理: 被上游判 CN 的点名域名 A → 仍劫持到网关"
  "明确代理: AAAA → 置空"
  "明确代理: HTTPS(65) → 置空"
  "规则集劫持表(ruleset_hijack)里的 CN 域名 A → 进网关"
  "gfw 模式: 点名的 CN 域名 A → 仍劫持到网关"
  "all 模式: 点名的 CN 域名 A → 劫持到网关"
)
# 期望**不变**的(仍 OK) —— 证明红的是优先级, 不是 mosdns 被整个弄坏
must_stay=(
  "WLOC/MITM force_hijack 仍高于 geosite_cn"
  "普通 geosite_cn 域名 A → 真实地址(不退化)"
  "同 zone 未点名的兄弟域名 A → 仍走直连上游"
  "gfw 模式: 非墙海外域名 A → 真实地址"
  "gfw 模式: 被墙域名 A → 劫持到网关"
  "all 模式: 非CN 域名 A → 劫持到网关"
)
for a in "${must_fail[@]}"; do
  if grep -qF "[FAIL] $a" "$WORK/nc.log"; then ok "负控命中: 「$a」变红"
  else bad "负控未命中: 「$a」在删掉判断后没有变红"; fi
done
for a in "${must_stay[@]}"; do
  if grep -qF "[OK]   $a" "$WORK/nc.log"; then ok "对照未受影响: 「$a」仍绿"
  else bad "对照被波及: 「$a」也红了 —— 负控可能是把 mosdns 整个弄坏了"; fi
done

# 基线里这些断言本来都是绿的(否则上面的对比没有意义)
for a in "${must_fail[@]}"; do
  grep -qF "[FAIL] $a" "$WORK/base.log" && bad "基线里「$a」本来就是红的"
done

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" -eq 0 ]] || exit 1
echo "✅ 负控成立: 那批断言确实由「明确代理优先于 geosite_cn」这道判断承载"
