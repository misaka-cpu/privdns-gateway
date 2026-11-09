#!/usr/bin/env bash
# 消费者侧: 把取件 job 留下的 mihomo **官方归档**放进升级类 E2E 的离线镜像, 并**自己重新验一遍**。
#
# 谁要它: e2e-upgrade-from-release / e2e-rescue-migration-lock(含 iOS 变体)的两跳升级。
#   · 旧版→桥接: 冻结桥接钉 v1.19.30, 夹具预装的是现钉值 → 桥接自己的 _update_core_binary 换核;
#   · 桥接→本版: 本版再换回现钉值。
# 两跳要的都是官方 Release 上的 .gz 归档(被测代码自己核归档 SHA、解压、再核二进制 SHA)。以前它们
# 每次都现场 curl GitHub; 2026-11-08 下载失败时这一跳以「内核收敛: 按本次前像恢复 mihomo」回滚。
# 夹具只把字节一模一样的归档放到本地(tests/e2e-lib.sh 的 e2e_release_mirror), 校验仍归被测代码。
#
# 每份归档四层:
#   ① 自己算归档 SHA256, 与钉值比(现钉值读当前 checkout 的 lib/versions.sh; 桥接钉值读
#      tests/legacy-pins.sh —— 那份抄自冻结桥接对象, tests/test-bridge-mihomo-pins.sh 逐字核对);
#   ② manifest 交叉核对(不能替代 ①);
#   ③ 解压产物 SHA256 与钉值比;
#   ④ 解压产物自报版本精确等于钉的版本。
# 过了才放进镜像目录。这里**没有任何联网动作**, 缺件或验不过就硬失败, 不 SKIP。
#
# 用法: install-release-mirror-artifact.sh <artifact 解包目录> [架构] [镜像目录(缺省 tests/.bin/release-mirror)]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIR="${1:?用法: install-release-mirror-artifact.sh <目录> [架构] [镜像目录]}"
DEST="${3:-$ROOT/tests/.bin/release-mirror}"
die(){ echo "[FAIL] $*" >&2; exit 1; }

# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || die "读不到 lib/versions.sh"
# shellcheck source=tests/legacy-pins.sh
source "$HERE/legacy-pins.sh" || die "读不到 tests/legacy-pins.sh"
arch="${2:-}"
if [[ -z "$arch" ]]; then
  arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
  [[ -n "$arch" ]] || case "$(uname -m)" in
    x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) die "不支持的架构 $(uname -m)";;
  esac
fi
MAN="$DIR/manifest.json"
[[ -f "$MAN" ]] || die "artifact 里没有 manifest.json"
SRC="$DIR/release-mirror"
[[ -d "$SRC" ]] || die "artifact 里没有 release-mirror/ 目录"

T="$(mktemp -d)" || die "建不出临时目录"
trap 'rm -rf "$T"' EXIT
_mf(){ python3 -c 'import json,sys
m=json.load(open(sys.argv[1])).get("release_mirror") or {}
print((m.get(sys.argv[2]) or {}).get(sys.argv[3],""))' "$MAN" "$1" "$2" 2>/dev/null; }

# check <标签> <版本> <归档钉值> <二进制钉值> → 验过的归档放到 $T/ok/
check(){
  local label="$1" ver="$2" want_a="$3" want_b="$4" name f got m got_ver
  [[ -n "$ver" && -n "$want_a" && -n "$want_b" ]] || die "$label: 缺版本或钉值(架构 $arch)"
  name="mihomo-linux-${arch}-${ver}.gz"
  f="$SRC/$name"
  [[ -f "$f" ]] || die "$label: artifact 的离线镜像里没有 $name —— 这一跳没有件可用"
  # ① 自算归档摘要
  got="$(sha256sum "$f" | awk '{print $1}')"
  [[ "$got" == "$want_a" ]] \
    || die "$label: $name 归档 SHA256 与钉值不符: 实得 ${got:0:12}…, 钉死 ${want_a:0:12}…"
  # ② manifest 交叉
  m="$(_mf "$name" archive_sha256)"
  [[ "$m" == "$got" ]] || die "$label: manifest 记的 $name 归档摘要与实算不符(${m:-空} ≠ $got)"
  m="$(_mf "$name" version)"
  [[ "$m" == "$ver" ]] || die "$label: manifest 记的 $name 版本与钉值不符(${m:-空} ≠ $ver)"
  # ③ 解压产物摘要
  gunzip -c "$f" > "$T/bin" 2>/dev/null && [[ -s "$T/bin" ]] || die "$label: $name 解压失败或产物为空"
  got="$(sha256sum "$T/bin" | awk '{print $1}')"
  [[ "$got" == "$want_b" ]] \
    || die "$label: $name 解压产物 SHA256 与钉值不符: 实得 ${got:0:12}…, 钉死 ${want_b:0:12}…"
  m="$(_mf "$name" binary_sha256)"
  [[ "$m" == "$got" ]] || die "$label: manifest 记的 $name 解压产物摘要与实算不符(${m:-空} ≠ $got)"
  # ④ 自报版本(内容已证过, 才轮到执行)
  chmod 755 "$T/bin"
  got_ver="$("$T/bin" -v 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [[ "$got_ver" == "$ver" ]] || die "$label: $name 自报版本 [${got_ver:-未知}] 与钉的 [$ver] 不符"
  rm -f "$T/bin"
  mkdir -p "$T/ok" && cp "$f" "$T/ok/$name" || die "$label: 暂存 $name 失败"
  echo "  [OK] $label $name(自算归档 + manifest 交叉 + 解压产物 + 自报版本 四层过)"
}

check "现钉值(lib/versions.sh)" "${MIHOMO_VER:-}" \
      "${PDG_SHA256[mihomo-$arch]:-}" "${PDG_SHA256[mihomo-bin-$arch]:-}"
[[ "$arch" == amd64 ]] \
  || die "桥接钉值(tests/legacy-pins.sh)只备了 amd64(本机 $arch) —— 不拿别的架构冒充"
if [[ "${PDG_BRIDGE_MIHOMO_VER:-}" == "${MIHOMO_VER:-}" ]]; then
  # 同一个资产名: 两份钉值必须一字不差, 否则就是钉值表本身互相矛盾
  [[ "${PDG_LEGACY_SHA256[mihomo-bridge-$arch]:-}" == "${PDG_SHA256[mihomo-$arch]:-}" \
     && "${PDG_LEGACY_SHA256[mihomo-bridge-bin-$arch]:-}" == "${PDG_SHA256[mihomo-bin-$arch]:-}" ]] \
    || die "桥接与现钉值是同一版本 $MIHOMO_VER, 两份摘要却不同 —— 钉值表自相矛盾"
else
  check "桥接钉值(tests/legacy-pins.sh)" "${PDG_BRIDGE_MIHOMO_VER:-}" \
        "${PDG_LEGACY_SHA256[mihomo-bridge-$arch]:-}" "${PDG_LEGACY_SHA256[mihomo-bridge-bin-$arch]:-}"
fi

install -d -m755 "$DEST" || die "建目录失败: $DEST"
n=0
for f in "$T"/ok/*.gz; do
  install -m644 "$f" "$DEST/${f##*/}" || die "放入镜像失败: $DEST/${f##*/}"
  n=$((n+1))
done
echo "[OK] 离线镜像 $DEST 就位: $n 份 mihomo 官方归档($MIHOMO_VER${PDG_BRIDGE_MIHOMO_VER:+ / 桥接 $PDG_BRIDGE_MIHOMO_VER}, $arch)"
