#!/usr/bin/env bash
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 测试用真 Caddy 的唯一解析入口(供 source)。tests/lan-fixture.sh 的 lan_fx_caddy 与
# tests/test-lan-location-live.sh 都走这里, 不再各写一份"本地 → PATH → 现场下载"。
#
#   pdg_test_caddy <仓库根> <工作目录>
#     stdout: 可用 caddy 的路径; 拿不到返回非 0, 原因写在 stderr(调用方原样透出, 不丢)。
#
# 取件顺序:
#   ① $PDG_TEST_CADDY(显式指定) → ② <仓库根>/tests/.bin/caddy(CI 由取件 job 经 artifact 供件,
#      tests/install-caddy-artifact.sh 复核后装到这里)。两者都要自报版本**精确等于**钉值。
#   ③ 严格模式(PDG_TEST_STRICT 或 CI=true)到此为止: 只认经复核的那一份, 不认 runner 上偶然
#      存在的 caddy, 也**不现场下载** —— 现场下载正是 2026-11-08 那次 lint 中断的来源, 而
#      "下不到就 curl 一把"会把每 run 一次取件的约束放开成每用例一次。拿不到就具名失败。
#   ④ 开发机: /usr/local/bin/caddy → PATH 上的 caddy(既有行为) → 走唯一取件入口
#      tests/prepare-caddy.sh 下到<工作目录>, 它的报错(含 curl 退出码与原始错误)原样留在 stderr。
# ─────────────────────────────────────────────────────────────────────────────

_pdg_test_caddy_strict(){
  [[ -n "${PDG_TEST_STRICT:-}" && "${PDG_TEST_STRICT}" != "0" ]] || [[ "${CI:-}" == "true" ]]
}

pdg_test_caddy(){
  local root="${1:?pdg_test_caddy 需要仓库根}" wd="${2:?pdg_test_caddy 需要工作目录}" c got want
  # shellcheck source=lib/versions.sh
  source "$root/lib/versions.sh" 2>/dev/null \
    || { echo "caddy 夹具: 读不到 $root/lib/versions.sh" >&2; return 1; }
  want="${CADDY_VER:-}"
  [[ -n "$want" ]] || { echo "caddy 夹具: lib/versions.sh 里没有 CADDY_VER" >&2; return 1; }
  for c in "${PDG_TEST_CADDY:-}" "$root/tests/.bin/caddy"; do
    [[ -n "$c" ]] || continue
    if [[ ! -x "$c" ]]; then
      [[ "$c" == "${PDG_TEST_CADDY:-}" ]] && echo "caddy 夹具: PDG_TEST_CADDY=$c 不可执行" >&2
      continue
    fi
    got="$("$c" version 2>/dev/null | head -1 | awk '{print $1}')"
    if [[ "$got" == "$want" ]]; then echo "$c"; return 0; fi
    echo "caddy 夹具: $c 自报 [${got:-读不出}] 不是钉值 $want, 不用它" >&2
  done
  if _pdg_test_caddy_strict; then
    echo "caddy 夹具: 严格模式(PDG_TEST_STRICT/CI)下只认经复核的钉死版, 不现场下载 ——" \
         "这里没拿到($root/tests/.bin/caddy 不在或版本不对)。CI 由取件 job 经 artifact 供件、" \
         "lint 的「校验并安装钉定 caddy」步骤装到位; 本地先跑 bash tests/prepare-caddy.sh" >&2
    return 1
  fi
  if [[ -x /usr/local/bin/caddy ]]; then echo /usr/local/bin/caddy; return 0; fi
  if command -v caddy >/dev/null 2>&1; then command -v caddy; return 0; fi
  if ! PDG_TEST_CADDY_DIR="$wd" bash "$root/tests/prepare-caddy.sh" >/dev/null; then
    echo "caddy 夹具: 本地/PATH 都没有 caddy, 唯一取件入口也没拿到(原因见上一行)" >&2
    return 1
  fi
  echo "$wd/caddy"
}
