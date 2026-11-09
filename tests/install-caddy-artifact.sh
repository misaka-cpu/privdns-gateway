#!/usr/bin/env bash
# 消费者侧: 把取件 job 留下的 **Caddy 官方归档**解出来装到位, 并**自己重新验一遍**。
# 与 install-mihomo-artifact.sh 同一个 artifact、同一套复核纪律。
#
# 为什么传归档而不传解压产物: lib/versions.sh 钉的是官方归档 caddy_<ver>_linux_<arch>.tar.gz
# 的 SHA256(生产 _lan_install_caddy 用的也是它), 没有单独钉二进制。拿归档过来、这里自己核
# 归档摘要再解, 信任锚就与生产同一个, 不必为测试另立一份钉值。
#
# 四层:
#   ① 自己算归档 SHA256, 与当前 checkout 的 lib/versions.sh 钉值比 —— 不认 artifact 服务端摘要,
#      也不认 manifest 里的数字;
#   ② manifest 交叉核对(归档摘要 / 版本 / 架构 / 取件 job 解出的二进制摘要), 不能替代 ①;
#   ③ 解包产物的摘要必须等于取件 job 记下的那一份(两边解的是同一个东西);
#   ④ 装到位后自报版本**整段精确**等于钉值(不是子串)。
#
# 这里**没有任何联网动作**: 取不到或验不过就硬失败, 不 SKIP。加"下不到就 curl 一把"的回退,
# 等于把每 run 一次取件的约束又放开成每 job 一次。
#
# 用法: install-caddy-artifact.sh <artifact 解包目录> [架构] [安装目标(缺省 tests/.bin/caddy)]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIR="${1:?用法: install-caddy-artifact.sh <目录> [架构] [目标]}"
DEST="${3:-$ROOT/tests/.bin/caddy}"
die(){ echo "[FAIL] $*" >&2; exit 1; }

# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || die "读不到 lib/versions.sh"
arch="${2:-}"
if [[ -z "$arch" ]]; then
  arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
  [[ -n "$arch" ]] || case "$(uname -m)" in
    x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) die "不支持的架构 $(uname -m)";;
  esac
fi
[[ -n "${CADDY_VER:-}" ]] || die "lib/versions.sh 里没有 CADDY_VER"
want_sha="${PDG_SHA256[caddy-$arch]:-}"
[[ -n "$want_sha" ]] || die "lib/versions.sh 里没有 caddy-$arch 的钉值"

ARC="$DIR/caddy_${CADDY_VER#v}_linux_${arch}.tar.gz"
[[ -f "$ARC" ]] || die "artifact 里没有 caddy 归档($ARC)"

# ① 自己算归档摘要, 与仓库钉值比
got_sha="$(sha256sum "$ARC" | awk '{print $1}')"
[[ "$got_sha" == "$want_sha" ]] \
  || die "artifact 里的 caddy 归档 SHA256 与 lib/versions.sh 钉值不符: 实得 ${got_sha:0:12}…, 钉死 ${want_sha:0:12}…"

# ② manifest 交叉核对 —— 它说的和我们算的不一致 = 供应链有问题
MAN="$DIR/manifest.json"
[[ -f "$MAN" ]] || die "artifact 里没有 manifest.json"
_m(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$MAN" "$1" 2>/dev/null; }
m_asha="$(_m caddy_archive_sha256)"; m_ver="$(_m caddy_version)"; m_arch="$(_m arch)"; m_bsha="$(_m caddy_binary_sha256)"
[[ "$m_asha" == "$got_sha"    ]] || die "manifest 记的 caddy 归档摘要与实算不符($m_asha ≠ $got_sha)"
[[ "$m_ver"  == "$CADDY_VER"  ]] || die "manifest 记的 caddy 版本与钉值不符($m_ver ≠ $CADDY_VER)"
[[ "$m_arch" == "$arch"       ]] || die "manifest 记的架构与本机不符($m_arch ≠ $arch)"
[[ -n "$m_bsha" ]] || die "manifest 里没有 caddy_binary_sha256"

# ③ 解包(归档已过 ①, 才轮到它被展开), 产物摘要要与取件 job 记下的一致
T="$(mktemp -d)" || die "建不出临时目录"
trap 'rm -rf "$T"' EXIT
tar -xzf "$ARC" -C "$T" caddy 2>/dev/null || die "解包失败(归档里没有 caddy?)"
[[ -s "$T/caddy" ]] || die "解包产物为空"
got_bin="$(sha256sum "$T/caddy" | awk '{print $1}')"
[[ "$got_bin" == "$m_bsha" ]] || die "解包产物摘要与 manifest 记的不符(${got_bin:0:12}… ≠ ${m_bsha:0:12}…)"

# ④ 自报版本整段精确比对(内容已在 ①③ 证过, 才轮到执行它), 过了才装到位
chmod 755 "$T/caddy" 2>/dev/null || true
got_ver="$("$T/caddy" version 2>/dev/null | head -1 | awk '{print $1}')"
[[ "$got_ver" == "$CADDY_VER" ]] \
  || die "caddy 自报版本 [${got_ver:-未知}] 与钉值 $CADDY_VER 不符"
install -d -m755 "$(dirname "$DEST")" || die "建目录失败: $(dirname "$DEST")"
install -m 755 "$T/caddy" "$DEST" || die "安装到 $DEST 失败"

echo "[OK] $DEST  $CADDY_VER  $arch  归档 sha256 ${got_sha:0:12}…(自算归档 + manifest 交叉 + 解包产物对账 + 自报版本 四层过)"
