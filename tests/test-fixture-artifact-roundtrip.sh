#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# caddy 与升级类 E2E 离线镜像这两样 artifact 件: 消费者复核、测试侧解析器、唯一取件入口。
#
# 由来(2026-11-08): lint 的 LAN 回滚负控每格在测试里现场 curl caddy, run 42482967890 三格没拿到,
# 整条串行链中断, 而错误被 2>/dev/null 丢了; 升级类 E2E 的「旧版→桥接」一跳每次现场 curl 桥接
# 钉的 mihomo v1.19.30, 下载失败就回滚。两样都改成取件 job 每 run 取一次、消费者离线复核 ——
# 这一支在本地把消费者那半钉死(跨 job 的 upload/download 本机证明不了, 只能看 exact-head CI):
#
#   1-3  install-caddy-artifact.sh: 两个独立消费者 / 七种坏件全部硬失败且不落盘 / 不联网;
#   4-6  install-release-mirror-artifact.sh: 同上, 缺桥接那一份时点名 v1.19.30;
#   7    tests/caddy-fixture.sh: 严格模式只认经复核的那一份, 拿不到就具名失败且**一次都不 curl**;
#   8    tests/prepare-caddy.sh(开发机才走到的唯一取件入口): curl 的原始报错与退出码留在输出里,
#        坏档不落盘, 好档按钉值装好。curl 一律由桩接管, 不碰公网。
#
# 用法: test-fixture-artifact-roundtrip.sh <artifact 目录>(或设 PDG_FIXTURE_ARTIFACT_DIR)。CI 传 lint 下载
# artifact 的那个目录; 本地先按 ci.yml 取件 job 的两个 run 块造一份。拿不到件判失败, 不是通过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# 件的目录由调用方给(CI: lint 下载 artifact 的那个目录), 不在这里写死一个共享路径。
ART="${1:-${PDG_FIXTURE_ARTIFACT_DIR:-}}"
W="$(mktemp -d "${TMPDIR:-/tmp}/pdg-fixtrip.XXXXXX")" || { echo "[FAIL] 建不出临时目录"; exit 1; }
trap 'rm -rf "$W"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
summary(){ echo "────────────────────────────────────────"; echo "test-fixture-artifact-roundtrip.sh: 通过 $pass, 失败 $nfail"; [[ "$nfail" == 0 ]]; }
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || { bad "读不到 lib/versions.sh"; summary; exit 1; }
# shellcheck source=tests/legacy-pins.sh
source "$HERE/legacy-pins.sh" || { bad "读不到 tests/legacy-pins.sh"; summary; exit 1; }
ARCH=amd64
CADDY_ARC="caddy_${CADDY_VER#v}_linux_${ARCH}.tar.gz"
M_CUR="mihomo-linux-${ARCH}-${MIHOMO_VER}.gz"
M_BRG="mihomo-linux-${ARCH}-${PDG_BRIDGE_MIHOMO_VER}.gz"

[[ -n "$ART" ]] || { bad "没给 artifact 目录(参数 1 或 PDG_FIXTURE_ARTIFACT_DIR) —— 这一支未验(不是通过)"; summary; exit 1; }
for f in "$ART/manifest.json" "$ART/$CADDY_ARC" "$ART/release-mirror/$M_CUR" "$ART/release-mirror/$M_BRG"; do
  if [[ ! -f "$f" ]]; then
    bad "拿不到 artifact 件 $f —— 这一支未验(不是通过)。CI 由 lint 的 download-artifact 供件"
    summary; exit 1
  fi
done
ok "artifact 件齐: $CADDY_ARC / $M_CUR / $M_BRG / manifest.json"

# 拒绝联网的桩: 被调到就记一笔(标记文件), 判据看标记而不只看退出码。
NONET="$W/nonet"; mkdir -p "$NONET"
for c in curl wget; do
  printf '#!/bin/sh\necho "禁止联网: %s $*" >&2\n: > "%s/called-%s"\nexit 97\n' "$c" "$W" "$c" > "$NONET/$c"
  chmod 755 "$NONET/$c"
done
nonet_clean(){ rm -f "$W"/called-curl "$W"/called-wget; }
nonet_called(){ [[ -e "$W/called-curl" || -e "$W/called-wget" ]]; }

# 从真件拼一个消费者下载目录: $1=目录 $2…=要放的相对路径
stage(){
  local d="$1" rel; shift
  rm -rf "$d"; mkdir -p "$d/release-mirror"
  for rel in "$@"; do cp "$ART/$rel" "$d/$rel" || return 1; done
}
mf_set(){   # $1=manifest $2=python 表达式(对 d 求值改写)
  python3 -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); exec(sys.argv[2]); json.dump(d,open(p,"w"))' "$1" "$2"
}
sha(){ sha256sum "$1" | awk '{print $1}'; }

echo
echo "══ 1. caddy: 两个独立消费者各自复核后装好 ══"
for c in A B; do
  D="$W/caddy$c"; stage "$D/dl" manifest.json "$CADDY_ARC"
  out="$(bash "$ROOT/tests/install-caddy-artifact.sh" "$D/dl" "$ARCH" "$D/bin/caddy" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "消费者 $c 复核全过并装好" || bad "消费者 $c 失败 rc=$rc: $(tail -2 <<<"$out")"
  [[ "$(stat -c%a "$D/bin/caddy" 2>/dev/null)" == 755 ]] && ok "消费者 $c 安装 mode=755" \
    || bad "消费者 $c mode=$(stat -c%a "$D/bin/caddy" 2>/dev/null || echo 无文件)"
  v="$("$D/bin/caddy" version 2>/dev/null | head -1 | awk '{print $1}')"
  [[ "$v" == "$CADDY_VER" ]] && ok "消费者 $c 装上的 caddy 自报 $v" || bad "消费者 $c 装上的 caddy 自报 [${v:-空}]"
  grep -q '四层过' <<<"$out" && ok "消费者 $c 报出了四层复核" || bad "消费者 $c 没报四层: $out"
done

echo
echo "══ 2. caddy: 坏件一律硬失败, 且不落盘 ══"
neg_caddy(){ # $1=场景 $2=期望出现在 [FAIL] 里的词 $3=准备命令(对 $D/dl 动手)
  local D="$W/cneg" out rc=0
  stage "$D/dl" manifest.json "$CADDY_ARC"; rm -rf "$D/bin"
  eval "$3"
  out="$(bash "$ROOT/tests/install-caddy-artifact.sh" "$D/dl" "$ARCH" "$D/bin/caddy" 2>&1)" || rc=$?
  if [[ "$rc" != 0 ]] && grep -q "^\[FAIL\].*$2" <<<"$out"; then
    ok "$1 → 硬失败并点名「$2」"
  else
    bad "$1 → rc=$rc, 没按预期失败: $(tail -1 <<<"$out")"
  fi
  [[ ! -e "$D/bin/caddy" ]] && ok "$1 → 没有把坏件装上去" || bad "$1 → 坏件被装上了"
}
neg_caddy "归档追加一个字节" "钉值不符" 'printf "\x00" >> "$D/dl/$CADDY_ARC"'
neg_caddy "manifest 归档摘要写错" "manifest 记的 caddy 归档摘要" 'mf_set "$D/dl/manifest.json" "d[\"caddy_archive_sha256\"]=\"0\"*64"'
neg_caddy "manifest 版本写错" "manifest 记的 caddy 版本" 'mf_set "$D/dl/manifest.json" "d[\"caddy_version\"]=\"v0.0.1\""'
neg_caddy "manifest 解包产物摘要写错" "解包产物摘要" 'mf_set "$D/dl/manifest.json" "d[\"caddy_binary_sha256\"]=\"0\"*64"'
# 这一格隔离"与仓库钉值比"那一层: 归档被换、manifest 也同步成与新内容一致 —— 只剩钉值能抓。
neg_caddy "归档被换 + manifest 同步改成一致(只有仓库钉值能抓)" "钉值不符" \
  'printf "\x00" >> "$D/dl/$CADDY_ARC"; mf_set "$D/dl/manifest.json" "d[\"caddy_archive_sha256\"]=\"$(sha "$D/dl/$CADDY_ARC")\""'
neg_caddy "manifest 缺失" "没有 manifest.json" 'rm -f "$D/dl/manifest.json"'
neg_caddy "归档缺失" "没有 caddy 归档" 'rm -f "$D/dl/$CADDY_ARC"'

echo
echo "══ 3. caddy: 消费者不联网 ══"
D="$W/cnonet"; stage "$D/dl" manifest.json "$CADDY_ARC"; nonet_clean
out="$(PATH="$NONET:$PATH" bash "$ROOT/tests/install-caddy-artifact.sh" "$D/dl" "$ARCH" "$D/bin/caddy" 2>&1)"; rc=$?
{ [[ "$rc" == 0 ]] && ! nonet_called; } \
  && ok "curl/wget 换成拒绝桩后仍然成功, 且桩一次都没被调到" \
  || bad "消费者路径上有联网动作(rc=$rc): $(tail -2 <<<"$out")"
CADDY_OK="$D/bin/caddy"       # 后面解析器那几格用这一份经复核的真件

echo
echo "══ 4. 离线镜像: 两个独立消费者各自复核后放好 ══"
for c in A B; do
  D="$W/mir$c"; stage "$D/dl" manifest.json "release-mirror/$M_CUR" "release-mirror/$M_BRG"
  out="$(bash "$ROOT/tests/install-release-mirror-artifact.sh" "$D/dl" "$ARCH" "$D/mirror" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "消费者 $c 两份归档复核全过" || bad "消费者 $c 失败 rc=$rc: $(tail -2 <<<"$out")"
  for n in "$M_CUR" "$M_BRG"; do
    cmp -s "$D/mirror/$n" "$ART/release-mirror/$n" && [[ "$(stat -c%a "$D/mirror/$n")" == 644 ]] \
      && ok "消费者 $c: $n 逐字节等于取件 job 的那份, mode=644" \
      || bad "消费者 $c: $n 没放好(内容或 mode 不对)"
  done
done

echo
echo "══ 5. 离线镜像: 坏件一律硬失败, 且不放进镜像 ══"
neg_mir(){ # $1=场景 $2=期望出现在 [FAIL] 里的词 $3=准备命令
  local D="$W/mneg" out rc=0
  stage "$D/dl" manifest.json "release-mirror/$M_CUR" "release-mirror/$M_BRG"; rm -rf "$D/mirror"
  eval "$3"
  out="$(bash "$ROOT/tests/install-release-mirror-artifact.sh" "$D/dl" "$ARCH" "$D/mirror" 2>&1)" || rc=$?
  if [[ "$rc" != 0 ]] && grep -q "^\[FAIL\].*$2" <<<"$out"; then
    ok "$1 → 硬失败并点名「$2」"
  else
    bad "$1 → rc=$rc, 没按预期失败: $(tail -1 <<<"$out")"
  fi
  [[ ! -e "$D/mirror" ]] && ok "$1 → 镜像目录一个件都没放" || bad "$1 → 镜像目录里放进了东西: $(ls "$D/mirror")"
}
neg_mir "拿掉桥接那一份(v1.19.30)" "没有 $M_BRG" 'rm -f "$D/dl/release-mirror/$M_BRG"'
neg_mir "拿掉现钉值那一份" "没有 $M_CUR" 'rm -f "$D/dl/release-mirror/$M_CUR"'
neg_mir "桥接归档追加一个字节" "$M_BRG 归档 SHA256 与钉值不符" 'printf "\x00" >> "$D/dl/release-mirror/$M_BRG"'
neg_mir "现钉值归档追加一个字节" "$M_CUR 归档 SHA256 与钉值不符" 'printf "\x00" >> "$D/dl/release-mirror/$M_CUR"'
neg_mir "桥接归档被换 + manifest 同步(只有钉值能抓)" "$M_BRG 归档 SHA256 与钉值不符" \
  'printf "\x00" >> "$D/dl/release-mirror/$M_BRG"; mf_set "$D/dl/manifest.json" "d[\"release_mirror\"][\"$M_BRG\"][\"archive_sha256\"]=\"$(sha "$D/dl/release-mirror/$M_BRG")\""'
neg_mir "manifest 里没有桥接那一条" "manifest 记的 $M_BRG 归档摘要" 'mf_set "$D/dl/manifest.json" "d[\"release_mirror\"].pop(\"$M_BRG\")"'
neg_mir "manifest 解压产物摘要写错" "manifest 记的 $M_CUR 解压产物摘要" 'mf_set "$D/dl/manifest.json" "d[\"release_mirror\"][\"$M_CUR\"][\"binary_sha256\"]=\"0\"*64"'
neg_mir "manifest 缺失" "没有 manifest.json" 'rm -f "$D/dl/manifest.json"'

echo
echo "══ 6. 离线镜像: 消费者不联网 ══"
D="$W/mnonet"; stage "$D/dl" manifest.json "release-mirror/$M_CUR" "release-mirror/$M_BRG"; nonet_clean
out="$(PATH="$NONET:$PATH" bash "$ROOT/tests/install-release-mirror-artifact.sh" "$D/dl" "$ARCH" "$D/mirror" 2>&1)"; rc=$?
{ [[ "$rc" == 0 ]] && ! nonet_called; } \
  && ok "curl/wget 换成拒绝桩后仍然成功, 且桩一次都没被调到" \
  || bad "消费者路径上有联网动作(rc=$rc): $(tail -2 <<<"$out")"

echo
echo "══ 7. 测试侧解析器 tests/caddy-fixture.sh ══"
# 造一个最小"仓库根": 解析器只读 lib/versions.sh、tests/.bin/caddy, 取件时调 tests/prepare-caddy.sh。
R="$W/root"; mkdir -p "$R/lib" "$R/tests/.bin" "$R/fakebin"
cp "$ROOT/lib/versions.sh" "$R/lib/"; cp "$ROOT/tests/caddy-fixture.sh" "$ROOT/tests/prepare-caddy.sh" "$R/tests/"
# PATH 上放一个"自报版本对"的假 caddy: 严格模式不许认它(它不是经复核的那一份)
printf '#!/bin/sh\necho "%s h1:fake"\n' "$CADDY_VER" > "$R/fakebin/caddy"; chmod 755 "$R/fakebin/caddy"
resolve(){ # $1=strict(1/0) → 打印 "rc|stdout|stderr 一行"
  local s="$1" o e rc
  nonet_clean
  o="$(env -u CI -u PDG_TEST_STRICT ${s:+PDG_TEST_STRICT=$s} PATH="$NONET:$R/fakebin:$PATH" \
        bash -c '. "$1/tests/caddy-fixture.sh" && pdg_test_caddy "$1" "$2"' _ "$R" "$W/rwd" 2>"$W/resolve.err")"; rc=$?
  e="$(tr '\n' ' ' < "$W/resolve.err")"
  printf '%s|%s|%s\n' "$rc" "$o" "$e"
}
mkdir -p "$W/rwd"
cp "$CADDY_OK" "$R/tests/.bin/caddy"
IFS='|' read -r rc o e <<<"$(resolve 1)"
[[ "$rc" == 0 && "$o" == "$R/tests/.bin/caddy" ]] \
  && ok "严格模式 + 经复核的 tests/.bin/caddy → 用它(不认 PATH 上的假 caddy)" \
  || bad "严格模式下没选中 tests/.bin/caddy: rc=$rc 选中=[$o] $e"
rm -f "$R/tests/.bin/caddy"
IFS='|' read -r rc o e <<<"$(resolve 1)"
if [[ "$rc" != 0 && -z "$o" && "$e" == *严格模式* ]] && ! nonet_called; then
  ok "严格模式 + 没有 tests/.bin/caddy → 具名失败(「严格模式」), PATH 上的假 caddy 不认, curl 一次都没调"
else
  bad "严格模式缺件时没有按预期具名失败: rc=$rc 选中=[$o] curl被调=$(nonet_called && echo 是 || echo 否) $e"
fi
printf '#!/bin/sh\necho "v0.0.1 h1:old"\n' > "$R/tests/.bin/caddy"; chmod 755 "$R/tests/.bin/caddy"
IFS='|' read -r rc o e <<<"$(resolve 1)"
[[ "$rc" != 0 && "$e" == *不是钉值* ]] \
  && ok "严格模式 + tests/.bin/caddy 版本不对 → 不用它并点名「不是钉值」" \
  || bad "版本不对的 tests/.bin/caddy 被放过了: rc=$rc 选中=[$o] $e"
rm -f "$R/tests/.bin/caddy"
IFS='|' read -r rc o e <<<"$(PDG_TEST_CADDY="$CADDY_OK" resolve 1)"
[[ "$rc" == 0 && "$o" == "$CADDY_OK" ]] \
  && ok "PDG_TEST_CADDY 显式指定 → 用它" || bad "PDG_TEST_CADDY 没被采用: rc=$rc 选中=[$o] $e"

echo
echo "══ 8. 唯一取件入口 tests/prepare-caddy.sh(curl 由桩接管, 不碰公网) ══"
# 桩: 按模式行为 —— fail28 学 curl 的超时报错; serve 交出真归档; corrupt 交出坏一个字节的归档
STUB="$W/stubbin"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'EOF'
#!/bin/sh
o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { o="$2"; shift; }; shift; done
case "$STUB_MODE" in
  fail28) echo "curl: (28) Operation timed out after 120000 milliseconds with 0 bytes received" >&2; exit 28;;
  serve) cp "$STUB_SRC" "$o";;
  corrupt) cp "$STUB_SRC" "$o" && printf 'x' >> "$o";;
esac
EOF
chmod 755 "$STUB/curl"
prep(){ # $1=模式 $2=落点目录 [$3=归档留存目录]
  env STUB_MODE="$1" STUB_SRC="$ART/$CADDY_ARC" PATH="$STUB:$PATH" PDG_TEST_CADDY_DIR="$2" \
      ${3:+PDG_TEST_CADDY_ARCHIVE_DIR=$3} bash "$R/tests/prepare-caddy.sh" 2>&1
}
out="$(prep fail28 "$W/p1")"; rc=$?
if [[ "$rc" != 0 && "$out" == *"Operation timed out"* && "$out" == *"curl 退出码 28"* ]]; then
  ok "下载失败 → 硬失败, curl 的原始报错与退出码 28 都留在输出里(下次能直接读出首因)"
else
  bad "下载失败时首因没留下来(rc=$rc): $out"
fi
[[ ! -e "$W/p1/caddy" ]] && ok "下载失败 → 没有落盘任何 caddy" || bad "下载失败却落了盘"
out="$(prep corrupt "$W/p2")"; rc=$?
[[ "$rc" != 0 && "$out" == *"归档 SHA256 不符"* && ! -e "$W/p2/caddy" ]] \
  && ok "坏一个字节的归档 → 拒绝解包、不落盘" || bad "坏归档没被拒(rc=$rc): $out"
out="$(prep serve "$W/p3" "$W/p3keep")"; rc=$?
v="$("$W/p3/caddy" version 2>/dev/null | head -1 | awk '{print $1}')"
[[ "$rc" == 0 && "$v" == "$CADDY_VER" ]] && ok "官方归档 → 按钉值装好(自报 $v)" || bad "好归档没装好(rc=$rc): $out"
cmp -s "$W/p3keep/$CADDY_ARC" "$ART/$CADDY_ARC" \
  && ok "PDG_TEST_CADDY_ARCHIVE_DIR → 校验过的归档原样留存(取件 job 靠它把归档交给消费者)" \
  || bad "归档没有原样留存"
out="$(prep fail28 "$W/p3" "$W/p3keep")"; rc=$?
[[ "$rc" == 0 && "$out" != *"Operation timed out"* ]] \
  && ok "已就位(版本与留存归档都对) → 直接复用, 不再取件" || bad "已就位却又去取件了(rc=$rc): $out"

echo
summary
