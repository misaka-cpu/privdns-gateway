#!/usr/bin/env bash
# 消费者侧: 把 producer 上传的**旧版** mosdns 装到位, 并自己重新验一遍。
# 与 install-mosdns-artifact.sh 同构 —— 同一个 artifact、同一套复核纪律。
#
# 证据等级要说清: v5.3.4 那份有 GitHub 资产 digest 可以交叉核对; v5.3.3 的 release 早于
# 该字段, 所以这里能做的是「实算 SHA + manifest 交叉 + 自报版本整行比对」三层, 没有第四层。
# 这不是偷工, 是上游的历史事实 —— 报告里不得把它说成与 v5.3.4 同级。
#
# 这里**没有任何联网动作**: 取不到或验不过就硬失败, 不 SKIP。加"下不到就 curl 一把"的回退,
# 等于把每 run 一次取件的约束放开成每 job 一次。
#
# 用法: install-mosdns-legacy-artifact.sh <artifact 解包目录> [架构] [安装目标]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:?用法: install-mosdns-legacy-artifact.sh <目录> [架构] [目标]}"
DEST="${3:-/usr/local/bin/mosdns-legacy}"
die(){ echo "[FAIL] $*" >&2; exit 1; }
# shellcheck source=tests/legacy-pins.sh
source "$HERE/legacy-pins.sh" || die "读不到 tests/legacy-pins.sh"

arch="${2:-}"
if [[ -z "$arch" ]]; then
  arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
  [[ -n "$arch" ]] || case "$(uname -m)" in
    x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) die "不支持的架构 $(uname -m)";;
  esac
fi
want_sha="${PDG_LEGACY_SHA256[mosdns-bin-$arch]:-}"
[[ -n "$want_sha" ]] || die "tests/legacy-pins.sh 里没有 mosdns-bin-$arch 的钉值"

BIN="$DIR/mosdns-legacy"
[[ -f "$BIN" ]] || die "artifact 里没有 mosdns-legacy($BIN)"

# ① 自己算摘要 —— 不认服务端摘要, 也不认 manifest 里的数字
got_sha="$(sha256sum "$BIN" | awk '{print $1}')"
[[ "$got_sha" == "$want_sha" ]] \
  || die "artifact 旧版二进制 SHA256 与钉值不符: 实得 ${got_sha:0:12}…, 钉死 ${want_sha:0:12}…"

# ② manifest 交叉核对(不能替代 ①): 它说的和我们算的不一致 = 供应链有问题
MAN="$DIR/manifest.json"
[[ -f "$MAN" ]] || die "artifact 里没有 manifest.json"
m_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("legacy_mosdns_binary_sha256",""))' "$MAN" 2>/dev/null)"
m_ver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("legacy_mosdns_version",""))' "$MAN" 2>/dev/null)"
[[ "$m_sha" == "$got_sha" ]] || die "manifest 记的旧版摘要与实算不符($m_sha ≠ $got_sha)"
[[ "$m_ver" == "$PDG_LEGACY_MOSDNS_VER" ]] || die "manifest 记的旧版版本与钉值不符($m_ver ≠ $PDG_LEGACY_MOSDNS_VER)"

# ③ 装到位, 再核一次自报版本(整行比对, 不是前缀)
chmod 755 "$BIN" 2>/dev/null || true
install -m 755 "$BIN" "$DEST" || die "安装到 $DEST 失败"
got_ver="$("$DEST" version 2>/dev/null | head -1)"
[[ "$got_ver" == "$PDG_LEGACY_MOSDNS_SELFVER" ]] \
  || die "$DEST 自报版本 [${got_ver:-未知}] 与钉值 [$PDG_LEGACY_MOSDNS_SELFVER] 不符"

echo "[OK] $DEST  $PDG_LEGACY_MOSDNS_VER  $arch  sha256 ${got_sha:0:12}…(自算 + manifest 交叉 + 自报版本 三层过; 该 release 无上游 digest 可交叉)"
