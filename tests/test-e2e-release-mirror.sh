#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 升级类 E2E 的离线镜像(tests/e2e-lib.sh 的 e2e_release_mirror + 它生成的 curl 前置壳)。
#
# 两支升级类 E2E 的「旧版→桥接」「桥接→本版」两跳里, 被测代码自己的 _update_core_binary 会去
# github.com/MetaCubeX/mihomo/releases 取归档。以前那是真联网, 2026-11-08 下载失败时 hop1 回滚、
# 整支红。现在夹具按两份钉值(本版工作树 / 冻结桥接对象自己的 lib/versions.sh)核过两份官方归档,
# 由前置壳本地供件。这一支不跑整支 E2E(那要 30 分钟级), 只把夹具本身的契约钉死:
#
#   1  件齐 → 就位; 前置壳对精确资产 URL 交出逐字节相同的归档, 不调真 curl;
#   2  没预置的 mihomo 资产(版本不在钉值里 / tag 与文件名对不上) → 22 失败并具名, 真 curl 一次不调,
#      e2e_summary 给出具名失败;
#   3  其它 URL 原样透传给真 curl(参数不变), 并记账;
#   4  负控: 拿掉桥接那一份 / 拿掉现钉值那一份 / 归档坏一个字节 / 两份对调名字 / 桥接对象取不到 ——
#      都在**就位时**具名失败, 且不挂壳(不会半截供件)。("归档对、解压产物不对"用真件造不出来:
#      那要求钉值表自相矛盾, 由 tests/test-bridge-mihomo-pins.sh 在钉值层面挡。)
#
# 用法: test-e2e-release-mirror.sh <artifact 目录>(或设 PDG_FIXTURE_ARTIFACT_DIR), 件在其 release-mirror/ 下。
# CI 传 lint 下载 artifact 的那个目录。拿不到件判失败, 不是通过。冻结桥接对象要在本仓库历史里(lint 是 fetch-depth 0)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# 件的目录由调用方给(CI: lint 下载 artifact 的那个目录), 不在这里写死一个共享路径。
ART="${1:-${PDG_FIXTURE_ARTIFACT_DIR:-}}"
W="$(mktemp -d "${TMPDIR:-/tmp}/pdg-e2emirror.XXXXXX")" || { echo "[FAIL] 建不出临时目录"; exit 1; }
trap 'rm -rf "$W"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
summary(){ echo "────────────────────────────────────────"; echo "test-e2e-release-mirror.sh: 通过 $pass, 失败 $nfail"; [[ "$nfail" == 0 ]]; }
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || { bad "读不到 lib/versions.sh"; summary; exit 1; }
# shellcheck source=tests/legacy-pins.sh
source "$HERE/legacy-pins.sh" || { bad "读不到 tests/legacy-pins.sh"; summary; exit 1; }
BRIDGE="$PDG_BRIDGE_PIN_COMMIT"
M_CUR="mihomo-linux-amd64-${MIHOMO_VER}.gz"
M_BRG="mihomo-linux-amd64-${PDG_BRIDGE_MIHOMO_VER}.gz"
PRE="https://github.com/MetaCubeX/mihomo/releases/download"
[[ -n "$ART" ]] || { bad "没给 artifact 目录(参数 1 或 PDG_FIXTURE_ARTIFACT_DIR) —— 这一支未验(不是通过)"; summary; exit 1; }
for f in "$ART/release-mirror/$M_CUR" "$ART/release-mirror/$M_BRG"; do
  [[ -f "$f" ]] || { bad "拿不到 artifact 件 $f —— 这一支未验(不是通过)"; summary; exit 1; }
done
git -C "$ROOT" cat-file -e "${BRIDGE}^{commit}" 2>/dev/null \
  || { bad "取不到冻结桥接对象 $BRIDGE(浅克隆?) —— 这一支未验(不是通过)"; summary; exit 1; }
ok "件与冻结桥接对象都在: $M_CUR / $M_BRG / ${BRIDGE:0:12}"

# "真 curl" 用一个记账桩顶替: 被调到就把参数记下来 —— 前置壳绝不能在供件路径上调到它。
REAL="$W/realbin"; mkdir -p "$REAL"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/real-calls"\nexit 0\n' "$W" > "$REAL/curl"
chmod 755 "$REAL/curl"

# drive <源镜像目录> <桥接提交> <动作…> → 在干净子进程里 source e2e-lib.sh 再执行动作。
# 子进程: e2e-lib.sh 会定义自己的 ok/bad 与计数器, 不能和本支的混在一起。
drive(){
  local src="$1" br="$2"; shift 2
  rm -f "$W/real-calls"
  env -u PDG_TEST_RELEASE_MIRROR PATH="$REAL:$PATH" E2E_ROOT="$ROOT" PDG_TEST_RELEASE_MIRROR="$src" \
      DRIVE_BR="$br" DRIVE_TMP="$W/e2etmp" bash -c '
    set -uo pipefail
    . "$E2E_ROOT/tests/e2e-lib.sh" || exit 90
    rm -rf "$DRIVE_TMP"; mkdir -p "$DRIVE_TMP"; E2E_TMP="$DRIVE_TMP"
    e2e_release_mirror "$DRIVE_BR"; echo "MIRROR_RC=$?"
    echo "CURL_IS=$(command -v curl)"
    for act in "$@"; do eval "$act"; done
  ' _ "$@" 2>&1
}
real_calls(){ [[ -f "$W/real-calls" ]] && grep -c . "$W/real-calls" || echo 0; }

echo
echo "══ 1. 件齐: 就位并按精确资产 URL 本地供件 ══"
out="$(drive "$ART/release-mirror" "$BRIDGE" \
  'curl -fsSL --connect-timeout 10 --max-time 180 "'"$PRE/$PDG_BRIDGE_MIHOMO_VER/$M_BRG"'" -o "$E2E_TMP/b.gz"; echo "GET_B=$?"' \
  'curl -fsSL --connect-timeout 10 --max-time 180 "'"$PRE/$MIHOMO_VER/$M_CUR"'" -o "$E2E_TMP/c.gz"; echo "GET_C=$?"' \
  'cmp -s "$E2E_TMP/b.gz" "$PDG_TEST_RELEASE_MIRROR/'"$M_BRG"'" && echo SAME_B=1' \
  'cmp -s "$E2E_TMP/c.gz" "$PDG_TEST_RELEASE_MIRROR/'"$M_CUR"'" && echo SAME_C=1' \
  'e2e_summary >/dev/null; echo "SUMMARY_RC=$?"; cut -f1 "$E2E_TMP/release-mirror/calls.log" | sort | uniq -c | tr -s " \n" " "; echo' \
  'E2E_MIRROR_DIR="$E2E_TMP/release-mirror"; e2e_release_mirror_verdict')"
grep -q '^MIRROR_RC=0' <<<"$out" && grep -q '^\[OK\]   离线镜像就位' <<<"$out" \
  && ok "就位: 两份归档按各自钉值核过" || bad "件齐却没就位: $(grep -m2 '\[FAIL\]\|MIRROR_RC' <<<"$out")"
grep -q "^CURL_IS=$W/e2etmp/release-mirror/bin/curl$" <<<"$out" \
  && ok "PATH 上最先命中的 curl 是前置壳" || bad "前置壳没挂到 PATH 最前面: $(grep CURL_IS <<<"$out")"
for k in B C; do
  grep -q "^GET_$k=0" <<<"$out" && grep -q "^SAME_$k=1" <<<"$out" \
    && ok "精确资产 URL($k) → rc=0, 交出的字节与镜像里的官方归档逐字节相同" \
    || bad "精确资产 URL($k) 没按预期供件: $(grep "GET_$k\|SAME_$k" <<<"$out")"
done
[[ "$(real_calls)" == 0 ]] && ok "供件路径上真 curl 一次都没被调" || bad "供件时调到了真 curl: $(cat "$W/real-calls")"
grep -q '^SUMMARY_RC=0' <<<"$out" && grep -q '2 SERVED' <<<"$out" \
  && ok "调用记录: 2 次 SERVED, e2e_summary 不判失败" || bad "调用记录不对: $(grep -A1 SUMMARY_RC <<<"$out")"
grep -q '^\[OK\]   离线镜像: mihomo 官方取件 2 次全部由本地钉值归档供件, 0 次联网' <<<"$out" \
  && ok "结论如实: 2 次全部本地供件" || bad "结论不对: $(grep '离线镜像:' <<<"$out" | tail -1)"

echo
echo "══ 2. 未预置的 mihomo 资产: 22 失败并具名, 不联网兜底 ══"
out="$(drive "$ART/release-mirror" "$BRIDGE" \
  'curl -fsSL "'"$PRE"'/v1.19.99/mihomo-linux-amd64-v1.19.99.gz" -o "$E2E_TMP/x.gz"; echo "GET_X=$?"' \
  'curl -fsSL "'"$PRE/$PDG_BRIDGE_MIHOMO_VER"'/'"$M_CUR"'" -o "$E2E_TMP/y.gz"; echo "GET_Y=$?"' \
  'e2e_summary; echo "SUMMARY_RC=$?"')"
grep -q '^GET_X=22' <<<"$out" && grep -q '未预置 .*v1.19.99' <<<"$out" \
  && ok "版本不在钉值里 → rc=22 且点名「未预置 …v1.19.99…」" || bad "未预置版本没按预期失败: $(grep 'GET_X\|未预置' <<<"$out")"
grep -q '^GET_Y=22' <<<"$out" \
  && ok "tag 与文件名对不上(download/$PDG_BRIDGE_MIHOMO_VER/$M_CUR) → 不供件, rc=22" \
  || bad "tag 与文件名不一致却被供件了: $(grep GET_Y <<<"$out")"
[[ "$(real_calls)" == 0 ]] && ok "未预置时真 curl 一次都没被调(没有联网兜底)" || bad "未预置时调到了真 curl: $(cat "$W/real-calls")"
grep -q '^\[FAIL\] 离线镜像: 2 次 mihomo 官方取件没有预置件' <<<"$out" && grep -q '^SUMMARY_RC=1' <<<"$out" \
  && ok "e2e_summary 给出具名失败(2 次未预置)并判失败" || bad "e2e_summary 没有点名未预置: $(grep 'SUMMARY_RC\|离线镜像:' <<<"$out")"

echo
echo "══ 3. 其它 URL 原样透传给真 curl ══"
out="$(drive "$ART/release-mirror" "$BRIDGE" \
  'curl -fsS --max-time 5 "https://example.invalid/geo.dat" -o "$E2E_TMP/g"; echo "GET_G=$?"' \
  'E2E_MIRROR_DIR="$E2E_TMP/release-mirror"; e2e_release_mirror_verdict')"
grep -q '^GET_G=0' <<<"$out" && grep -qx -- '-fsS --max-time 5 https://example.invalid/geo.dat -o .*/g' "$W/real-calls" 2>/dev/null \
  && ok "非 mihomo 资产 → 交给真 curl, 参数原样" || bad "透传不对: $(cat "$W/real-calls" 2>/dev/null) / $(grep GET_G <<<"$out")"
grep -q '透传给真 curl 的其它请求 1 次' <<<"$out" && ok "透传的请求记了账" || bad "透传没记账: $(grep 透传 <<<"$out")"

echo
echo "══ 4. 负控: 件不齐 / 件不对 → 就位时具名失败, 不挂壳 ══"
neg(){ # $1=场景 $2=期望出现在 [FAIL] 里的词 $3=准备命令(对 $M 目录动手) [$4=桥接提交]
  local M="$W/negsrc" o
  rm -rf "$M"; mkdir -p "$M"
  cp "$ART/release-mirror/$M_CUR" "$ART/release-mirror/$M_BRG" "$M/"
  eval "$3"
  o="$(drive "$M" "${4:-$BRIDGE}")"
  if grep -q '^MIRROR_RC=1' <<<"$o" && grep -q "^\[FAIL\] 离线镜像: .*$2" <<<"$o" \
     && ! grep -q "^CURL_IS=$W/e2etmp/release-mirror/bin/curl$" <<<"$o"; then
    ok "$1 → 就位失败并点名「$2」, 前置壳没挂上"
  else
    bad "$1 → 没按预期失败: $(grep -m1 '\[FAIL\]\|MIRROR_RC' <<<"$o") / $(grep CURL_IS <<<"$o")"
  fi
}
neg "拿掉桥接钉的那一份" "缺 冻结桥接 ${BRIDGE:0:12}.*$M_BRG" 'rm -f "$M/$M_BRG"'
neg "拿掉现钉值那一份" "缺 本版.*$M_CUR" 'rm -f "$M/$M_CUR"'
neg "桥接归档坏一个字节" "$M_BRG 归档摘要" 'printf "\x00" >> "$M/$M_BRG"'
# 两份对调名字: 每一份都是真的官方归档, 只是不是**这个名字的钉值**那一份 —— 归档摘要那一关拦。
neg "两份归档对调名字" "归档摘要" 'mv "$M/$M_BRG" "$M/t"; mv "$M/$M_CUR" "$M/$M_BRG"; mv "$M/t" "$M/$M_CUR"'
neg "冻结桥接对象取不到" "取不到冻结桥接" ':' 0000000000000000000000000000000000000000

echo
summary
