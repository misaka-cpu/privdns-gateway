#!/usr/bin/env bash
# 备好测试用的钉死版 mihomo, 放到 tests/.bin/mihomo。
#
# 为什么单独一个脚本: 需要真内核的测试不止一个, 让它们各自下载一遍既慢又容易各写各的版本。
# 这里下一次、按 lib/versions.sh 的 SHA256 校验一次, 之后所有测试经 tests/mihomobin.py 共用。
# 已经备好且版本正确 → 直接返回, 不重复下载(CI 上也能靠缓存目录复用)。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh"
# shellcheck source=lib/checksum.sh
[[ -f "$ROOT/lib/checksum.sh" ]] && source "$ROOT/lib/checksum.sh"

DEST="${PDG_TEST_BIN_DIR:-$ROOT/tests/.bin}"
BIN="$DEST/mihomo"
fail(){ echo "❌ $*" >&2; exit 1; }

_ver_of(){ "$1" -v 2>/dev/null | head -1 | sed -n 's/.*v\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/v\1/p'; }

if [[ -x "$BIN" && "$(_ver_of "$BIN")" == "$MIHOMO_VER" ]]; then
  echo "$BIN"; exit 0                      # 已就位, 版本对得上 → 不重下
fi

case "$(uname -m)" in
  x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;;
  *) fail "不支持的架构 $(uname -m) —— 请自行准备 $MIHOMO_VER 并设 PDG_TEST_MIHOMO";;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-${ARCH}-${MIHOMO_VER}.gz"
echo "[*] 下载钉死版 mihomo $MIHOMO_VER ($ARCH)…" >&2
curl -fsSL "$URL" -o "$WORK/m.gz" || fail "下载失败: $URL"
# 供应链校验复用装机那一套(哈希表在 lib/versions.sh), 不在这里另立一份判据
if declare -F pdg_verify_sha256 >/dev/null; then
  pdg_verify_sha256 "$WORK/m.gz" "${PDG_SHA256[mihomo-$ARCH]:-}" "mihomo $MIHOMO_VER ($ARCH)" \
    || fail "SHA256 校验失败 —— 拒绝使用"
else
  got="$(sha256sum "$WORK/m.gz" | awk '{print $1}')"
  [[ "$got" == "${PDG_SHA256[mihomo-$ARCH]:-x}" ]] || fail "SHA256 不符(实得 $got)"
fi
gunzip -c "$WORK/m.gz" > "$WORK/mihomo" || fail "解压失败"
chmod 755 "$WORK/mihomo"
# 校验完哈希还要再核一次自称的版本: 哈希对得上说明文件没被换, 版本核对防的是哈希表本身贴错
got="$(_ver_of "$WORK/mihomo")"
[[ "$got" == "$MIHOMO_VER" ]] || fail "下载到的是 $got, 不是钉死版 $MIHOMO_VER"
install -d -m755 "$DEST" || fail "建目录失败: $DEST"
install -m755 "$WORK/mihomo" "$BIN" || fail "安装失败: $BIN"
echo "$BIN"
