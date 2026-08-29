#!/usr/bin/env bash
# 消费者侧: 把 producer 上传的 mosdns artifact 装到位, 并**自己重新验一遍**。
#
# 为什么不能信 artifact 服务端给的摘要: 那是"传输没坏"的证明, 不是"内容是官方那一份"的证明。
# 这个脚本按当前 checkout 的 lib/versions.sh 重算 SHA256、重核自报版本, 最后再走一次生产判据
# pdg_mosdns_binary_ok —— 与 install.sh 的严格短路、doctor 的完整性判据是同一个函数。
#
# 这里**没有任何联网动作**: 取不到或验不过就硬失败。加"下不到就 curl 一把"的回退, 等于把
# 每 run 一次取件的约束又放开成每 job 一次(而那正是这一轮要修的东西)。
# 也不 SKIP —— 静默跳过会让"夹具用了真二进制"这条契约变回一句空话。
#
# 用法: install-mosdns-artifact.sh <artifact 解包目录> [架构] [安装目标]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIR="${1:?用法: install-mosdns-artifact.sh <目录> [架构] [目标]}"
DEST="${3:-/usr/local/bin/mosdns}"
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
want_sha="${PDG_SHA256[mosdns-bin-$arch]:-}"
[[ -n "$want_sha" ]] || die "lib/versions.sh 里没有 mosdns-bin-$arch 的钉值"

BIN="$DIR/mosdns"
[[ -f "$BIN" ]] || die "artifact 里没有 mosdns($BIN)"

# ① 自己算摘要 —— 不认服务端摘要, 也不认 manifest 里的数字
got_sha="$(sha256sum "$BIN" | awk '{print $1}')"
[[ "$got_sha" == "$want_sha" ]] \
  || die "artifact 二进制 SHA256 与 lib/versions.sh 钉值不符: 实得 ${got_sha:0:12}…, 钉死 ${want_sha:0:12}…"

# ② manifest 只做交叉核对, 不能替代上面那一步。它说的和我们算的不一致 = 供应链有问题。
MAN="$DIR/manifest.json"
if [[ -f "$MAN" ]]; then
  m_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("binary_sha256",""))' "$MAN" 2>/dev/null)"
  m_ver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$MAN" 2>/dev/null)"
  m_arch="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("arch",""))' "$MAN" 2>/dev/null)"
  [[ "$m_sha"  == "$got_sha"     ]] || die "manifest 记的摘要与实算不符($m_sha ≠ $got_sha)"
  [[ "$m_ver"  == "$MOSDNS_VER"  ]] || die "manifest 记的版本与钉值不符($m_ver ≠ $MOSDNS_VER)"
  [[ "$m_arch" == "$arch"        ]] || die "manifest 记的架构与本机不符($m_arch ≠ $arch)"
else
  die "artifact 里没有 manifest.json"
fi

# ③ 装到位, 再核一次自报版本
chmod 755 "$BIN" 2>/dev/null || true
install -m 755 "$BIN" "$DEST" || die "安装到 $DEST 失败"
got_ver="$("$DEST" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ "v${got_ver:-}" == "$MOSDNS_VER" ]] \
  || die "$DEST 自报版本 v${got_ver:-未知} 与钉值 $MOSDNS_VER 不符"

# ④ 最后走生产判据 —— 与 install.sh 的短路、doctor 的完整性判据同一个函数
pdg_mosdns_binary_ok "$arch" "$MOSDNS_VER" "$DEST" \
  || die "生产判据 pdg_mosdns_binary_ok 未通过($arch $MOSDNS_VER $DEST)"

echo "[OK] $DEST  $MOSDNS_VER  $arch  sha256 ${got_sha:0:12}…(自算 + manifest 交叉 + 自报版本 + 生产判据 四层过)"
