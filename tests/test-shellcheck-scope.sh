#!/usr/bin/env bash
# ShellCheck 必须按 **CI 的原样范围** 跑, 而不是手挑几个文件。
#
# 这支的由来: 我本地一直只查 install.sh / pdg.sh / detect-internal-range.sh 三个文件,
# 于是新加的 tests/*.sh 从没进过门 —— 本地全绿、CI 的 lint job 直接判红。少查的那部分
# 恰恰是新增代码最集中的地方, 这种"门比被测面小"的缺口, 只会在推上去之后才暴露。
#
# 范围从 ci.yml **读出来**, 不在这里抄一份: 抄一份就会和 CI 各自漂移, 那时这支测试
# 反而会给出"本地绿"的假保证。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

command -v shellcheck >/dev/null 2>&1 || {
  echo "[SKIP] 没装 shellcheck"; echo; echo "通过 0, 失败 0, 跳过 1"; exit 0; }

# 从 ci.yml 里取那条命令的文件范围(紧跟 `shellcheck --severity=...` 的续行)
scope="$(awk '/shellcheck --severity=warning/{getline; print; exit}' "$CI" | sed 's/^[[:space:]]*//')"
[[ -n "$scope" ]] || { bad "从 ci.yml 读不出 ShellCheck 范围"; echo; echo "通过 $pass, 失败 $nfail"; exit 1; }
ok "范围取自 ci.yml: $scope"

cd "$ROOT" || exit 1
# shellcheck disable=SC2086  # scope 是有意按空格拆成多个 glob 的
out="$(shellcheck --severity=warning -e SC1091 $scope 2>&1)"
rc=$?
if [[ "$rc" == 0 ]]; then
  ok "CI 原样范围下 ShellCheck 无 warning"
else
  bad "CI 原样范围下有 warning(CI 的 lint job 会据此判红):"
  echo "$out" | grep -E '^In |SC[0-9]{4}' | head -12 | sed 's/^/       /'
fi

echo
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail ? 1 : 0 ))
