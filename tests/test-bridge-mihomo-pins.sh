#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 冻结桥接钉的 mihomo: tests/legacy-pins.sh 里那三个值必须**逐字等于**冻结桥接对象自己的
# lib/versions.sh, 且两支升级类 E2E 的默认桥接身份就是那个对象。
#
# 为什么要钉这一条: 取件 job 的 checkout 是浅克隆, 读不到冻结桥接对象, 只能按 legacy-pins.sh
# 去取 v1.19.30 的归档; 而 E2E 里真正去认这份归档的是**桥接自己的代码**, 它按的是桥接对象里的
# 钉值。两份要是分了家(换了桥接对象 / 抄错一位), 取件 job 会照常取到一份"自洽"的归档, E2E 的
# 离线镜像再按桥接钉值把它拒掉 —— 红在 E2E 里, 而原因在这里。这一支把它提前到 lint, 并点名。
#
# 末尾三格负控: 把副本里的版本 / 归档摘要 / 桥接身份各改一处, 判据都必须转红并点名。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/pdg-bridgepins.XXXXXX")" || { echo "[FAIL] 建不出临时目录"; exit 1; }
trap 'rm -rf "$W"' EXIT

# check <legacy-pins 文件> <E2E 脚本…> → stdout 每行一条 "OK …" / "FAIL …"; 有 FAIL 时返回 1
check(){
  local pins="$1" commit ver a b bv ba bb f def rc=0
  shift
  read -r commit ver a b < <(
    # shellcheck source=/dev/null
    . "$pins" >/dev/null 2>&1 || exit 0
    printf '%s %s %s %s\n' "${PDG_BRIDGE_PIN_COMMIT:-}" "${PDG_BRIDGE_MIHOMO_VER:-}" \
      "${PDG_LEGACY_SHA256[mihomo-bridge-amd64]:-}" "${PDG_LEGACY_SHA256[mihomo-bridge-bin-amd64]:-}")
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ || -z "$ver" || ! "$a" =~ ^[0-9a-f]{64}$ || ! "$b" =~ ^[0-9a-f]{64}$ ]]; then
    echo "FAIL legacy-pins 里桥接那组不完整(身份=[${commit:-空}] 版本=[${ver:-空}] 两份摘要各 ${#a}/${#b} 位)"
    return 1
  fi
  echo "OK legacy-pins: 冻结桥接 ${commit:0:12} 钉 mihomo $ver(归档 ${a:0:12}… / 解压产物 ${b:0:12}…)"
  if ! git -C "$ROOT" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    echo "FAIL 取不到冻结桥接对象 $commit(浅克隆?) —— 无从核对, 不当成通过"
    return 1
  fi
  if ! git -C "$ROOT" show "$commit:lib/versions.sh" > "$W/bridge-versions.sh" 2>/dev/null \
     || [[ ! -s "$W/bridge-versions.sh" ]]; then
    echo "FAIL 冻结桥接对象里读不出 lib/versions.sh"
    return 1
  fi
  read -r bv ba bb < <(
    # shellcheck source=/dev/null
    . "$W/bridge-versions.sh" >/dev/null 2>&1 || exit 0
    printf '%s %s %s\n' "${MIHOMO_VER:-}" "${PDG_SHA256[mihomo-amd64]:-}" "${PDG_SHA256[mihomo-bin-amd64]:-}")
  [[ "$bv" == "$ver" ]] && echo "OK 版本与冻结桥接对象一致: $ver" \
    || { echo "FAIL 版本: legacy-pins 写 $ver, 冻结桥接对象钉的是 ${bv:-读不出}"; rc=1; }
  [[ "$ba" == "$a" ]] && echo "OK 归档摘要与冻结桥接对象一致" \
    || { echo "FAIL 归档摘要: legacy-pins ${a:0:12}… ≠ 冻结桥接对象 ${ba:0:12}…"; rc=1; }
  [[ "$bb" == "$b" ]] && echo "OK 解压产物摘要与冻结桥接对象一致" \
    || { echo "FAIL 解压产物摘要: legacy-pins ${b:0:12}… ≠ 冻结桥接对象 ${bb:0:12}…"; rc=1; }
  for f in "$@"; do
    def="$(grep -oE 'BRIDGE_SHA="\$\{PDG_BRIDGE_SHA:-[0-9a-f]{40}\}"' "$f" | grep -oE '[0-9a-f]{40}' | head -1)"
    if [[ -z "$def" ]]; then
      echo "FAIL ${f##*/}: 找不到默认桥接身份 BRIDGE_SHA=\"\${PDG_BRIDGE_SHA:-…}\" —— 写法变了, 判据失效"; rc=1
    elif [[ "$def" == "$commit" ]]; then
      echo "OK ${f##*/} 的默认桥接身份就是 ${commit:0:12}"
    else
      echo "FAIL ${f##*/} 的默认桥接是 ${def:0:12}, legacy-pins 的钉值抄自 ${commit:0:12} —— 换桥接对象时两边没一起换"; rc=1
    fi
  done
  return "$rc"
}

E2ES=("$ROOT/tests/e2e-upgrade-from-release.sh" "$ROOT/tests/e2e-rescue-migration-lock.sh")

echo "══ 1. 正式钉值 ══"
out="$(check "$ROOT/tests/legacy-pins.sh" "${E2ES[@]}")"; rc=$?
while IFS= read -r ln; do
  case "$ln" in OK\ *) ok "${ln#OK }";; FAIL\ *) bad "${ln#FAIL }";; esac
done <<<"$out"
(( rc == 0 )) || bad "正式钉值没有全部对上(见上)"

echo
echo "══ 2. 负控: 副本里各改一处, 判据必须转红并点名 ══"
# neg <标签> <sed 表达式(作用于 legacy-pins 副本)> <期望出现在 FAIL 里的词> [对 E2E 副本的 sed]
neg(){
  local label="$1" expr="$2" want="$3" e2e_expr="${4:-}" o r f hit
  cp "$ROOT/tests/legacy-pins.sh" "$W/pins.sh"
  sed -i "$expr" "$W/pins.sh"
  if cmp -s "$ROOT/tests/legacy-pins.sh" "$W/pins.sh" && [[ -z "$e2e_expr" ]]; then
    bad "负控「$label」: 改坏器没改到任何东西 —— 这一格无效"; return
  fi
  local -a e2es=()
  for f in "${E2ES[@]}"; do
    cp "$f" "$W/${f##*/}"
    [[ -n "$e2e_expr" ]] && sed -i "$e2e_expr" "$W/${f##*/}"
    e2es+=("$W/${f##*/}")
  done
  o="$(check "$W/pins.sh" "${e2es[@]}")"; r=$?
  hit="$(grep -m1 "^FAIL .*$want" <<<"$o")"
  if (( r != 0 )) && [[ -n "$hit" ]]; then
    ok "负控「$label」→ 转红并点名: ${hit:5:90}"          # 按字符截, 不用按字节切的 cut -c
  else
    bad "负控「$label」→ 没有按预期转红(rc=$r): $(grep -m1 '^FAIL' <<<"$o" || echo 无 FAIL)"
  fi
}
neg "版本写错一位" 's/^PDG_BRIDGE_MIHOMO_VER="v1\.19\.30"/PDG_BRIDGE_MIHOMO_VER="v1.19.31"/' "版本"
neg "归档摘要改一位" 's/\(\[mihomo-bridge-amd64\]="\)c/\1d/' "归档摘要"
neg "E2E 默认桥接换了而钉值没跟" '' "默认桥接" \
    's/\(BRIDGE_SHA="${PDG_BRIDGE_SHA:-\)542cc9177fc35c9d413ff3b62a7dac8bc468c136/\10000000000000000000000000000000000000000/'

echo
echo "────────────────────────────────────────"
echo "test-bridge-mihomo-pins.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
