#!/usr/bin/env bash
# 备好跨版本换核 E2E 的**旧版** mosdns。与 tests/prepare-mosdns.sh 同构, 只是钉值来自
# tests/legacy-pins.sh。**唯一的取件入口** —— CI 里由 producer 调一次, 之后经 artifact 扇出。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/legacy-pins.sh
source "$HERE/legacy-pins.sh"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" 2>/dev/null || true
DEST="${PDG_TEST_LEGACY_DIR:-$ROOT/tests/.bin}"
BIN="$DEST/mosdns-legacy"
fail(){ echo "❌ $*" >&2; exit 1; }
_ver(){ "$1" version 2>/dev/null | head -1 | sed -n 's/.*v\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/v\1/p'; }

# 已就位且内容对得上 → 不重下(判据是**内容**, 不是自报版本)
if [[ -x "$BIN" ]] \
   && [[ "$(sha256sum "$BIN" | cut -d' ' -f1)" == "${PDG_LEGACY_SHA256[mosdns-bin-amd64]}" ]]; then
  echo "$BIN"; exit 0
fi
case "$(uname -m)" in
  x86_64) ARCH=amd64;;
  *) fail "旧版钉值目前只备了 amd64(本机 $(uname -m)) —— 不拿别的架构冒充";;
esac
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
URL="https://github.com/IrineSistiana/mosdns/releases/download/${PDG_LEGACY_MOSDNS_VER}/mosdns-linux-${ARCH}.zip"
echo "[*] 下载旧版 mosdns ${PDG_LEGACY_MOSDNS_VER} ($ARCH)…" >&2
curl -fsSL --connect-timeout 10 --max-time 180 "$URL" -o "$W/m.zip" || fail "下载失败: $URL"
got="$(sha256sum "$W/m.zip" | cut -d' ' -f1)"
[[ "$got" == "${PDG_LEGACY_SHA256[mosdns-$ARCH]}" ]] \
  || fail "归档 SHA256 不符(实得 $got) —— 拒绝使用"
( cd "$W" && unzip -qo m.zip mosdns ) || fail "解压失败"
chmod 755 "$W/mosdns"
got="$(sha256sum "$W/mosdns" | cut -d' ' -f1)"
[[ "$got" == "${PDG_LEGACY_SHA256[mosdns-bin-$ARCH]}" ]] \
  || fail "解压产物 SHA256 不符(实得 $got) —— 归档过了但落盘的不是钉死那一份"
got="$("$W/mosdns" version 2>/dev/null | head -1)"
[[ "$got" == "$PDG_LEGACY_MOSDNS_SELFVER" ]] \
  || fail "自报版本 [${got:-未知}] 与钉死的 [$PDG_LEGACY_MOSDNS_SELFVER] 不符(比的是整行, 不是前缀)"
install -d -m755 "$DEST" || fail "建目录失败: $DEST"
install -m755 "$W/mosdns" "$BIN" || fail "安装失败: $BIN"
echo "$BIN"
