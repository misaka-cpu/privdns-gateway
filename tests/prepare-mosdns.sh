#!/usr/bin/env bash
# 备好测试用的钉死版 mosdns, 装到 /usr/local/bin/mosdns。
#
# 为什么需要它: 事务的 mosdns_probe 校验器会**真的启动 mosdns** 去解析候选配置 —— 拿不到
# 二进制就整笔事务 REFUSED。tests/test-cidr-transaction.py 走的正是这条路。
#
# 这个缺口是 v1.7.0 发布前的 CI 上暴露的: 本地一直绿, 是因为开发机上有早前 E2E 留下的
# mosdns; CI 的 lint job 里没有, 于是"正常路径没提交/真源没更新/服务动作没执行"一串失败。
# 本地绿不等于 CI 绿, 差别就在这种没人声明过的前提上。
#
# 版本与 SHA256 复用 lib/versions.sh 那一份真源, 不在这里另立判据。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh"
# shellcheck source=lib/checksum.sh
[[ -f "$ROOT/lib/checksum.sh" ]] && source "$ROOT/lib/checksum.sh"

BIN="${PDG_TEST_MOSDNS:-/usr/local/bin/mosdns}"
fail(){ echo "❌ $*" >&2; exit 1; }

_ver_of(){ "$1" version 2>/dev/null | head -1 | sed -n 's/^\(v[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p'; }

if [[ -x "$BIN" && "$(_ver_of "$BIN")" == "$MOSDNS_VER" ]]; then
  echo "$BIN"; exit 0                      # 已就位且版本对得上 → 不重下
fi

case "$(uname -m)" in
  x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;;
  *) fail "不支持的架构 $(uname -m) —— 请自行准备 $MOSDNS_VER 并设 PDG_TEST_MOSDNS";;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
URL="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-${ARCH}.zip"
echo "[*] 下载钉死版 mosdns $MOSDNS_VER ($ARCH)…" >&2
curl -fsSL --retry 2 -m 180 "$URL" -o "$WORK/m.zip" || fail "下载失败: $URL"
if declare -F pdg_verify_sha256 >/dev/null; then
  pdg_verify_sha256 "$WORK/m.zip" "${PDG_SHA256[mosdns-$ARCH]:-}" "mosdns $MOSDNS_VER ($ARCH)" \
    || fail "SHA256 校验失败 —— 拒绝使用"
else
  got="$(sha256sum "$WORK/m.zip" | awk '{print $1}')"
  [[ "$got" == "${PDG_SHA256[mosdns-$ARCH]:-x}" ]] || fail "SHA256 不符(实得 $got)"
fi
(cd "$WORK" && unzip -qo m.zip mosdns) || fail "解压失败"
chmod 755 "$WORK/mosdns"
# 哈希对得上说明文件没被换; 再核一次它自称的版本, 防的是哈希表本身贴错。
got="$(_ver_of "$WORK/mosdns")"
[[ "$got" == "$MOSDNS_VER" ]] || fail "下载到的是 ${got:-未知}, 不是钉死版 $MOSDNS_VER"
install -m755 "$WORK/mosdns" "$BIN" || fail "安装失败: $BIN"
echo "$BIN"
