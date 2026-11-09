#!/usr/bin/env bash
# 备好测试用的钉死版 Caddy(官方原版), 放到 $PDG_TEST_CADDY_DIR/caddy(缺省 tests/.bin/caddy)。
#
# **唯一的取件入口。** CI 里由取件 job 调一次(同时把校验过的官方归档原样留给 artifact), 之后
# 经 artifact 扇出, 消费者用 tests/install-caddy-artifact.sh 自己复核。以前内网面板那几支测试
# (tests/lan-fixture.sh 的 lan_fx_caddy、tests/test-lan-location-live.sh)各自在测试过程中现场
# curl GitHub, 九格负控每格重下一次; 2026-11-08 run 42482967890 里三格没拿到, 整条 lint 串行链
# 断在那里, 而 curl 的报错被 2>/dev/null 丢了, 首因无从判断。
#
# 校验口径与生产 _lan_install_caddy 相同(归档 SHA256 钉在 lib/versions.sh), 另加自报版本精确比对。
#   PDG_TEST_CADDY_DIR          解压产物落点目录(缺省 tests/.bin)
#   PDG_TEST_CADDY_ARCHIVE_DIR  可选: 把校验过的官方归档原样留在这里(取件 job 用)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || { echo "❌ 读不到 lib/versions.sh" >&2; exit 1; }
DEST="${PDG_TEST_CADDY_DIR:-$ROOT/tests/.bin}"
BIN="$DEST/caddy"
KEEP="${PDG_TEST_CADDY_ARCHIVE_DIR:-}"
fail(){ echo "❌ $*" >&2; exit 1; }
# `caddy version` 第一段形如 v2.11.4, 后面跟 h1: 模块摘要。比的是第一段整串, 不是子串。
_ver(){ "$1" version 2>/dev/null | head -1 | awk '{print $1}'; }

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ARCH=amd64;; arm64|aarch64) ARCH=arm64;;
  *) fail "不支持的架构 —— 钉值只有 amd64 / arm64";;
esac
WANT="${PDG_SHA256[caddy-$ARCH]:-}"
[[ -n "$CADDY_VER" && -n "$WANT" ]] || fail "lib/versions.sh 里缺 CADDY_VER 或 caddy-$ARCH 的钉值"
ANAME="caddy_${CADDY_VER#v}_linux_${ARCH}.tar.gz"

_archive_ok(){ [[ -f "$1" && "$(sha256sum "$1" | awk '{print $1}')" == "$WANT" ]]; }
if [[ -x "$BIN" && "$(_ver "$BIN")" == "$CADDY_VER" ]] \
   && { [[ -z "$KEEP" ]] || _archive_ok "$KEEP/$ANAME"; }; then
  echo "$BIN"; exit 0                      # 已就位, 版本对得上(要归档时归档也在) → 不重下
fi

W="$(mktemp -d)" || fail "建不出临时目录"
trap 'rm -rf "$W"' EXIT
URL="https://github.com/caddyserver/caddy/releases/download/${CADDY_VER}/${ANAME}"
echo "[*] 下载钉死版 caddy $CADDY_VER ($ARCH)…" >&2
# 错误输出不丢(-S): 下次红在这里时, 超时 / 连接被重置 / HTTP 错误要能从日志里直接读出来。
curl -fsSL --connect-timeout 10 --max-time 180 "$URL" -o "$W/caddy.tgz"
crc=$?
[[ "$crc" == 0 ]] || fail "下载失败(curl 退出码 $crc): $URL"
got="$(sha256sum "$W/caddy.tgz" | awk '{print $1}')"
[[ "$got" == "$WANT" ]] || fail "归档 SHA256 不符(实得 $got, 钉死 $WANT) —— 拒绝解包"
tar -xzf "$W/caddy.tgz" -C "$W" caddy || fail "解包失败(归档里没有 caddy?)"
[[ -s "$W/caddy" ]] || fail "解包产物为空"
chmod 755 "$W/caddy"
got="$(_ver "$W/caddy")"
[[ "$got" == "$CADDY_VER" ]] || fail "自报版本 [${got:-未知}] 与钉死的 [$CADDY_VER] 不符"
install -d -m755 "$DEST" || fail "建目录失败: $DEST"
install -m755 "$W/caddy" "$BIN" || fail "安装失败: $BIN"
if [[ -n "$KEEP" ]]; then
  install -d -m755 "$KEEP" || fail "建目录失败: $KEEP"
  install -m644 "$W/caddy.tgz" "$KEEP/$ANAME" || fail "留存归档失败: $KEEP/$ANAME"
fi
echo "$BIN"
