#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 把内核换版里唯一容易出错的那一步做掉: 取件 + 算钉值 + 改写 lib/versions.sh。
#
#   tools/bump-kernel.sh <mihomo|mosdns> <版本>      例: tools/bump-kernel.sh mihomo v1.19.30
#
# 为什么要它: 换版本身只是改三行, 但其中两行是 **64 位十六进制**, 两个架构各一份(mosdns
# 还多一份解压后二进制)。手工粘错一位的后果不是"少了点什么", 而是装机直接 die 在 SHA
# 校验上 —— 而报错指向供应链异常, 现场看不出那是笔误。这一步机器做比人做可靠。
#
# 它**只改钉值**。不提交、不推送、不打 tag、不发版、不碰系统 —— 后面那一整套(全量 +
# E2E + PR + exact-head CI + 合并 + main CI + tag + Release)一步都不省。原因不是流程洁癖:
# E2E 矩阵是按 *_VER 取件的, 钉值一改, 二十多格 E2E 就真跑在新内核上, 分流、嗅探、出口
# 规则、事务、回滚全走一遍 —— 那才是"这一版会不会弄坏什么"的答案来源。sing-box 1.13 砍掉
# sniff_override_destination 那次, 正是这一层看见的。
#
# 信任锚仍是上游官方 Release 页(两家都不发布校验和文件, 所以是 TOFU: 首次下载即信任)。
# 这个脚本不改变信任模型, 只是把"下载→核对→誊写"这条链自动化, 并在誊写前多做两道核对:
#   · 本机架构那份: 真跑一次二进制, 比对它自报的版本 —— 防"哈希算对了但对象贴错了";
#   · 跑不动的那份: 读 ELF 头的机器类型 —— 防"两次都下成了同一个架构"。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PDG_BUMP_ROOT:-$(cd "$HERE/.." && pwd)}"     # 测试可指向沙箱副本
VERSIONS="$ROOT/lib/versions.sh"

die(){ echo "❌ $*" >&2; exit 1; }
say(){ echo "$*" >&2; }

usage(){
  cat >&2 <<'U'
用法: tools/bump-kernel.sh <mihomo|mosdns> <版本>

  例: tools/bump-kernel.sh mihomo v1.19.30
      tools/bump-kernel.sh mosdns v5.4.0

只改写 lib/versions.sh 的版本常量与对应 SHA256 钉值, 然后打印 diff。
不提交、不推送、不发版 —— 改完请照常走: 全量测试 → E2E → PR → CI → 合并 → tag/Release。
U
}

[[ $# -eq 2 ]] || { usage; exit 2; }
COMP="$1"; VER="$2"

case "$COMP" in
  mihomo|mosdns) ;;
  *) usage; die "不认识的组件 '$COMP' —— 目前只支持 mihomo 与 mosdns";;
esac
# 版本号形态必须严格: 它会被拼进 URL 与文件名, 松一点就等于把命令行交给参数
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "版本号形态不对: '$VER'(要 vX.Y.Z, 例 v1.19.30)"

[[ -f "$VERSIONS" ]] || die "找不到 $VERSIONS"

# 工作树必须干净 —— 否则这次改写会和别人的改动混进同一笔, 事后分不清哪行是谁写的
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -n "$(git -C "$ROOT" status --porcelain=v1 -- lib/versions.sh 2>/dev/null)" ]]; then
    die "lib/versions.sh 已有未提交改动 —— 先处理干净再来, 免得混成一笔"
  fi
fi

VER_KEY="$(printf '%s' "$COMP" | tr '[:lower:]' '[:upper:]')_VER"
CUR="$(sed -n "s/^${VER_KEY}=\"\\([^\"]*\\)\".*/\\1/p" "$VERSIONS" | head -1)"
[[ -n "$CUR" ]] || die "在 $VERSIONS 里找不到 $VER_KEY"
[[ "$CUR" != "$VER" ]] || die "$VER_KEY 已经是 $VER —— 无需改动"
say "== $COMP: $CUR → $VER =="

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null)" || HOST_ARCH=""
[[ -n "$HOST_ARCH" ]] || case "$(uname -m)" in
  x86_64) HOST_ARCH=amd64;; aarch64|arm64) HOST_ARCH=arm64;; *) HOST_ARCH="";;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 默认取件器: 从官方 Release 下载, 产出 <dir>/archive 与 <dir>/binary。
# 抽成可替换的入口(PDG_BUMP_FETCHER)是为了让"改写"这一半能离线测 —— 取件那一半要真网络,
# 由使用者在真实环境跑一次来验证。
_fetch(){                       # $1=组件 $2=版本 $3=架构 $4=输出目录
  local comp="$1" ver="$2" arch="$3" out="$4" url
  mkdir -p "$out"
  case "$comp" in
    mihomo) url="https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${arch}-${ver}.gz";;
    mosdns) url="https://github.com/IrineSistiana/mosdns/releases/download/${ver}/mosdns-linux-${arch}.zip";;
  esac
  say "  下载 $url"
  # -f: HTTP 错误不当成成功(404 会写出一个"成功下载的错误页", 那正是要防的)
  curl -fsSL --retry 2 -m 600 "$url" -o "$out/archive" || return 1
  case "$comp" in
    mihomo) gunzip -c "$out/archive" > "$out/binary" || return 1;;
    mosdns) ( cd "$out" && unzip -qo archive mosdns && mv mosdns binary ) || return 1;;
  esac
  chmod 755 "$out/binary" 2>/dev/null || true
}
FETCH="${PDG_BUMP_FETCHER:-}"

# ELF 头里的 e_machine(偏移 18, 小端 2 字节): amd64=0x3E, arm64=0xB7。
# 跑不动的那个架构就靠它 —— 光信 URL 的话, "两次都下成同一个架构"不会被发现。
_elf_machine_ok(){
  local f="$1" want="$2" m
  m="$(od -An -tx1 -j18 -N2 "$f" 2>/dev/null | tr -d ' \n')"
  case "$want" in amd64) [[ "$m" == "3e00" ]];; arm64) [[ "$m" == "b700" ]];; *) return 1;; esac
}

declare -A ARCHIVE_SHA BIN_SHA
for arch in amd64 arm64; do
  d="$WORK/$arch"
  if [[ -n "$FETCH" ]]; then
    "$FETCH" "$COMP" "$VER" "$arch" "$d" || die "取件失败($arch)"
  else
    _fetch "$COMP" "$VER" "$arch" "$d" || die "取件失败($arch) —— 版本不存在? 网络不通?"
  fi
  [[ -s "$d/archive" && -s "$d/binary" ]] || die "取件产物为空($arch)"

  if [[ -z "${PDG_BUMP_SKIP_VERIFY:-}" ]]; then
    if [[ "$arch" == "$HOST_ARCH" ]]; then
      # 本机能跑: 直接问它自己是哪一版 —— 这是"哈希是否贴错对象"唯一的硬证据
      got="$("$d/binary" -v 2>/dev/null || "$d/binary" version 2>/dev/null || true)"
      got="$(printf '%s' "$got" | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      [[ "v${got#v}" == "$VER" ]] \
        || die "$arch 自报版本是 ${got:-读不出}, 不是 $VER —— 拒绝把这份哈希写进去"
      say "  $arch 自报版本 ✓ $VER"
    else
      _elf_machine_ok "$d/binary" "$arch" \
        || die "$arch 的产物不是该架构的 ELF —— 可能两次下成了同一个架构"
      say "  $arch ELF 机器类型 ✓(本机跑不动, 只能验到这一层)"
    fi
  fi

  ARCHIVE_SHA[$arch]="$(sha256sum "$d/archive" | cut -d' ' -f1)"
  BIN_SHA[$arch]="$(sha256sum "$d/binary" | cut -d' ' -f1)"
  say "  $arch 归档 sha256 = ${ARCHIVE_SHA[$arch]}"
  [[ "$COMP" == mosdns ]] && say "  $arch 二进制 sha256 = ${BIN_SHA[$arch]}"
done

# ── 改写: 逐行**替换**, 不追加 ────────────────────────────────────────────────
_sub(){                          # $1=正则(整行) $2=新行
  local pat="$1" new="$2" n
  n=$(grep -cE "$pat" "$VERSIONS")
  [[ "$n" == 1 ]] || die "锚点命中 $n 次(期望 1): $pat —— versions.sh 换写法了, 工具要跟着改"
  local tmp; tmp="$(mktemp)"
  awk -v pat="$pat" -v new="$new" '$0 ~ pat { print new; next } { print }' "$VERSIONS" > "$tmp" \
    && cat "$tmp" > "$VERSIONS" && rm -f "$tmp"
}
_sub "^${VER_KEY}=" "$(awk -v k="$VER_KEY" -v v="$VER" '
  $0 ~ "^"k"=" { sub(/"[^"]*"/, "\""v"\""); print; exit }' "$VERSIONS")"
for arch in amd64 arm64; do
  _sub "^  \\[${COMP}-${arch}\\]=" "  [${COMP}-${arch}]=\"${ARCHIVE_SHA[$arch]}\""
  if [[ "$COMP" == mosdns ]]; then
    _sub "^  \\[${COMP}-bin-${arch}\\]=" "  [${COMP}-bin-${arch}]=\"${BIN_SHA[$arch]}\""
  fi
done

bash -n "$VERSIONS" || die "改写后 $VERSIONS 语法坏了 —— 请 git checkout 还原后报告"

say ""
say "== 改动 =="
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$ROOT" --no-pager diff -- lib/versions.sh >&2 || true
else
  grep -nE "^${VER_KEY}=|^  \\[${COMP}(-bin)?-(amd64|arm64)\\]=" "$VERSIONS" >&2
fi
say ""
say "== 接下来(工具不代劳)=="
say "  1) 本地全量 + E2E —— 钉值一改, E2E 就真跑在新内核上, 那才是兼容性的答案"
say "  2) 一笔提交, 逐文件暂存"
say "  3) PR → exact-head CI → PR CI → 合并 → main CI"
say "  4) tag + Release, 然后才是部署"
