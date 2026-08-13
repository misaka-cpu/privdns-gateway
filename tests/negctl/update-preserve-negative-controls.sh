#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test-update-preserve-userdata.sh 的负控: 把产品的保全真的打坏, 证明它会转红并点名。
#
# 为什么非有不可: 那支测的是"更新之后用户数据还在", 而"还在"是**默认状态** —— 更新
# 路径不去碰它就自动成立。这种判据天生容易变成永远绿的摆设: 写宽一点、比错一个字段,
# 在接线正确时照样全绿。所以必须反过来问一次 —— 哪天真有人在部署阶段把 /opt/pdg-bot
# 整个清了, 或者把它从快照清单里摘掉, 我们会不会当场知道。
#
# 两格分别咬住两条独立的链:
#   NC-UD-1 部署阶段整目录清空 → 收口那条"回滚后还能再更新一次"必须红。这一格的形态
#           很能说明问题: 两条 verify **仍绿**(快照里有, 回滚真把数据还回来了), 红的
#           是**后果** —— 每次更新都在部署阶段自毁, 于是每次都 fail-closed 回滚, 机器
#           从此卡死在"永远更新不了"。只比前后像是看不见这个的, 所以那条收口不是凑数。
#           同格还验证防空转守卫("模块没换成新版, 那这次'没动用户数据'不算数")能拦住
#           verify 的假绿 —— 部署压根没发生时, "数据没被动"是废话。
#   NC-UD-2 再把 opt/pdg-bot 从 snapshot 清单摘掉 → 失败回滚那条也必须红。
#
# 改坏落在容器内的工作副本, 正式树一个字节不动。每格四步缺一不可:
# 锚点唯一命中 → 摘要确实变化 → bash -n 通过 → 新增可点名失败。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
NC_ROOT="${NC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TEST=tests/e2e-update-preserve-userdata.sh
TARGET=deploy/bot/pdg.sh

npass=0; nfail=0
ok(){  npass=$((npass+1)); echo "[OK]   $*"; }
bad(){ nfail=$((nfail+1)); echo "[FAIL] $*"; }

command -v git >/dev/null 2>&1 || { echo "[SKIP] 无 git"; exit 0; }
[[ "$(id -u)" == 0 ]] || { echo "[SKIP] 这支要在一次性容器里以 root 跑(被测 E2E 要真装机)"; exit 0; }
[[ -n "${PDG_E2E_ISOLATED:-}" ]] || {
  echo "[SKIP] 缺 PDG_E2E_ISOLATED —— 被测 E2E 会真改这台机器, 不在一次性环境里绝不跑"; exit 0; }

WC="$(mktemp -d "${TMPDIR:-/tmp}/pdg-udnc.XXXXXX")/wc"
cp -a "$NC_ROOT" "$WC"
rm -rf "$WC/.git"
PRISTINE="$(mktemp "${TMPDIR:-/tmp}/pdg-udnc-pristine.XXXXXX")"
cp -a "$WC/$TARGET" "$PRISTINE"
MODE="$(stat -c %a "$WC/$TARGET")"
BASE_SHA="$(sha256sum "$NC_ROOT/$TARGET" | cut -d' ' -f1)"

restore(){ cat "$PRISTINE" > "$WC/$TARGET"; chmod "$MODE" "$WC/$TARGET"; }

# 被测 E2E 会真装机, 每格都得在自己的一次性沙箱里跑
run_test(){
  PDG_E2E_ISOLATED=1 E2E_ROOT="$WC" bash "$WC/$TEST" 2>&1
}

echo "── 基线: 保全完好时必须全绿 ──"
BASE_OUT="$(run_test)"
BASE_FAILS="$(grep '^\[FAIL\]' <<<"$BASE_OUT" | sort)"
if [[ -n "$BASE_FAILS" ]]; then
  bad "基线就红了, 后面每格都无从判断:"; head -3 <<<"$BASE_FAILS" | sed 's/^/      /'
  echo "有效 $npass, 失败 $nfail"; exit 1
fi
ok "基线绿: 通过 $(grep -c '^\[OK\]' <<<"$BASE_OUT"), 失败 0"

# want_red_in: 期望哪一节转红(成功路径 / 失败回滚后); want_green_in: 期望哪一节仍绿
cell(){
  local n="$1" name="$2" want_red="$3" want_green="${4:-}"
  local out fails added
  out="$(run_test)"
  fails="$(grep '^\[FAIL\]' <<<"$out")"
  added="$(comm -13 <(echo "$BASE_FAILS") <(sort <<<"$fails") 2>/dev/null)"
  if [[ -z "$added" ]]; then
    bad "NC-UD-$n $name → **没有新增失败**, 这条判据没有守卫"
  elif ! grep -q "$want_red" <<<"$added"; then
    bad "NC-UD-$n $name → 转红但没点名 '$want_red': $(head -1 <<<"$added" | cut -c1-90)"
  elif [[ -n "$want_green" ]] && grep -q "^\[FAIL\].*$want_green" <<<"$fails"; then
    bad "NC-UD-$n $name → '$want_green' 那节**不该红却红了**, 两条路径没分开判"
  else
    ok "NC-UD-$n $name → 新增 $(grep -c . <<<"$added") 条: $(head -1 <<<"$added" | cut -c8-92)"
    [[ -n "$want_green" ]] && ok "NC-UD-$n 同格反向: '$want_green' 仍绿(两条路径独立判定)"
  fi
}

echo
echo "── 两格 ──"

# 1) 部署阶段把 /opt/pdg-bot 整个清空再装模块 —— 用户数据随之陪葬。
#    这正是 e2e-update.sh 第 2 节曾经干过的事, 只不过这次让**产品**来干。
A1='  if   ! pdg_install_runtime_modules "$REPO_DIR" /opt/pdg-bot "$(_pdg_platform)" \'
B1='  rm -rf /opt/pdg-bot; mkdir -p /opt/pdg-bot
  if   ! pdg_install_runtime_modules "$REPO_DIR" /opt/pdg-bot "$(_pdg_platform)" \'
hits=$(grep -cF "$A1" "$WC/$TARGET")
if [[ "$hits" != 1 ]]; then
  bad "NC-UD-1 锚点命中 $hits 次, 预期 1"
else
  before=$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)
  python3 - "$WC/$TARGET" "$A1" "$B1" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(s.replace(a, b, 1))
PY
  if [[ "$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)" == "$before" ]]; then
    bad "NC-UD-1 摘要没变, mutation 没生效"; restore
  elif ! bash -n "$WC/$TARGET" 2>/dev/null; then
    bad "NC-UD-1 改坏后语法不合法, 这格不算有效负控"; restore
  else
    cell 1 "部署阶段整目录清空" "回滚后再也更新不了" "失败回滚后"
  fi
fi

# 2) 在第 1 格基础上再把 opt/pdg-bot 从快照清单摘掉 → 回滚也救不回来
A2='  local cand=(etc/mosdns etc/sing-box etc/mihomo opt/pdg-bot etc/privdns-gateway etc/nftables.conf'
B2='  local cand=(etc/mosdns etc/sing-box etc/mihomo etc/privdns-gateway etc/nftables.conf'
hits=$(grep -cF "$A2" "$WC/$TARGET")
if [[ "$hits" != 1 ]]; then
  bad "NC-UD-2 锚点命中 $hits 次, 预期 1"; restore
else
  before=$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)
  python3 - "$WC/$TARGET" "$A2" "$B2" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(s.replace(a, b, 1))
PY
  if [[ "$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)" == "$before" ]]; then
    bad "NC-UD-2 摘要没变, mutation 没生效"
  elif ! bash -n "$WC/$TARGET" 2>/dev/null; then
    bad "NC-UD-2 改坏后语法不合法, 这格不算有效负控"
  else
    cell 2 "快照清单摘掉 opt/pdg-bot" "失败回滚后"
  fi
  restore
fi

echo
echo "── 收尾 ──"
[[ "$(sha256sum "$NC_ROOT/$TARGET" | cut -d' ' -f1)" == "$BASE_SHA" ]] \
  && ok "正式树 $TARGET 逐字节一致" || bad "正式树 $TARGET 被动过"
[[ "$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)" == "$BASE_SHA" ]] \
  && ok "工作副本已从 pristine 逐字节恢复" || bad "工作副本没恢复干净"
rm -rf "$(dirname "$WC")" "$PRISTINE"

echo "──────────────────────────────────────────────────────────────────"
echo "有效 $npass, 失败 $nfail"
[[ "$nfail" == 0 ]]
