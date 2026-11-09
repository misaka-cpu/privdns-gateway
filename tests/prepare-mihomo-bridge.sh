#!/usr/bin/env bash
# 备好冻结桥接钉的 mihomo **归档**(mihomo-linux-amd64-v1.19.30.gz), 放进升级类 E2E 的离线镜像。
#
# 为什么要归档而不是解压产物: 桥接那一跳里换核的是**冻结桥接自己的** _update_core_binary,
# 它要的是官方 Release 上那个 .gz, 拿到后自己核归档 SHA、解压、再核二进制 SHA。夹具只负责
# 把那个字节一模一样的归档放在本地, 校验与换核仍全部由被测代码做 —— 重新 gzip 一份解压产物
# 对不上归档摘要, 也等于替被测代码跳过了第一道门。
#
# **唯一的取件入口** —— CI 里由取件 job 调一次, 之后经 artifact 扇出(消费者复核见
# tests/install-release-mirror-artifact.sh)。与 tests/prepare-mosdns-legacy.sh 同构, 钉值来自
# tests/legacy-pins.sh(抄自冻结桥接对象, tests/test-bridge-mihomo-pins.sh 逐字核对)。
#
# 落点: $PDG_TEST_MIRROR_DIR(缺省 tests/.bin/release-mirror), 文件名 = 官方资产名。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/legacy-pins.sh
source "$HERE/legacy-pins.sh" || { echo "❌ 读不到 tests/legacy-pins.sh" >&2; exit 1; }
MIRROR="${PDG_TEST_MIRROR_DIR:-$ROOT/tests/.bin/release-mirror}"
fail(){ echo "❌ $*" >&2; exit 1; }
_ver(){ "$1" -v 2>/dev/null | head -1 | sed -n 's/.*v\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/v\1/p'; }

case "$(uname -m)" in
  x86_64) ARCH=amd64;;
  *) fail "桥接钉值目前只备了 amd64(本机 $(uname -m)) —— 不拿别的架构冒充";;
esac
VER="$PDG_BRIDGE_MIHOMO_VER"
WANT_A="${PDG_LEGACY_SHA256[mihomo-bridge-$ARCH]:-}"
WANT_B="${PDG_LEGACY_SHA256[mihomo-bridge-bin-$ARCH]:-}"
[[ -n "$VER" && -n "$WANT_A" && -n "$WANT_B" ]] || fail "tests/legacy-pins.sh 里缺桥接 mihomo 的版本或钉值"
NAME="mihomo-linux-${ARCH}-${VER}.gz"
OUT="$MIRROR/$NAME"

# 已就位且归档内容对得上 → 不重下(判据是**内容**)
if [[ -f "$OUT" ]] && [[ "$(sha256sum "$OUT" | cut -d' ' -f1)" == "$WANT_A" ]]; then
  echo "$OUT"; exit 0
fi

W="$(mktemp -d)" || fail "建不出临时目录"
trap 'rm -rf "$W"' EXIT
URL="https://github.com/MetaCubeX/mihomo/releases/download/${VER}/${NAME}"
echo "[*] 下载桥接钉的 mihomo ${VER} ($ARCH) 归档…" >&2
# 错误输出不丢: 下次红在这里时, 首因(超时 / 连接被重置 / HTTP 错误)要能从日志里直接读出来。
curl -fsSL --connect-timeout 10 --max-time 180 "$URL" -o "$W/m.gz"
crc=$?
[[ "$crc" == 0 ]] || fail "下载失败(curl 退出码 $crc): $URL"
got="$(sha256sum "$W/m.gz" | cut -d' ' -f1)"
[[ "$got" == "$WANT_A" ]] || fail "归档 SHA256 不符(实得 $got) —— 拒绝使用"
gunzip -c "$W/m.gz" > "$W/mihomo" 2>/dev/null && [[ -s "$W/mihomo" ]] || fail "解压失败或产物为空"
chmod 755 "$W/mihomo"
got="$(sha256sum "$W/mihomo" | cut -d' ' -f1)"
[[ "$got" == "$WANT_B" ]] || fail "解压产物 SHA256 不符(实得 $got) —— 归档过了但解出来的不是钉死那一份"
got="$(_ver "$W/mihomo")"
[[ "$got" == "$VER" ]] || fail "自报版本 [${got:-未知}] 与钉死的 [$VER] 不符"
install -d -m755 "$MIRROR" || fail "建目录失败: $MIRROR"
install -m644 "$W/m.gz" "$OUT" || fail "放入离线镜像失败: $OUT"
echo "$OUT"
