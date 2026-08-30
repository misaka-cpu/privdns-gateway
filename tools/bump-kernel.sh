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
# 信任模型(不要读成比实际更强):
#   · 两家上游**都不发布独立的签名校验文件**(没有 .asc / .sig / minisign / SHA256SUMS.asc)。
#   · GitHub 的 Release API 会给出**服务器侧计算的 sha256 asset digest**。这是一条
#     **额外的交叉证据** —— 它能挡住"传输途中被改""下错了资产""本地解压出了岔子"这几类,
#     但它**不构成独立的签名信任链**: 文件与摘要由同一方托管, 同一方被攻破时两者会一起变。
#   · 所以底子仍是 TOFU(首次下载即信任), 这个脚本不改变信任模型, 只是把"下载→核对→誊写"
#     自动化, 并在誊写前多做几道核对:
#       - 官方 asset digest 交叉核对(有就必须一致, 不一致直接拒绝写文件);
#       - 本机架构那份: 真跑一次二进制, 比对自报版本 —— 防"哈希算对了但对象贴错了";
#       - 跑不动的那份: 读**完整 ELF 头**(magic/class/endian/e_machine)—— 防"两次下成同一架构"。
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

# **目标文件**必须干净 —— 否则这次改写会和别人对同一文件的改动混进一笔, 事后分不清哪行是谁写的。
# 注意措辞: 这里查的**只有 lib/versions.sh 这一个文件**, 不是整个工作区 —— 工作区里同时
# 有别的改动是常态, 拿它当门会让工具在正常开发中根本用不了。旧注释把范围说大了, 与实现
# 不符; 现在文案与实现一致。
# 只在 $ROOT **就是某个仓库的顶层**时才查: 否则(比如测试把 ROOT 指到临时目录, 而那个
# 临时目录恰好落在另一个仓库里)git 会向上找到**无关的**仓库, 把沙箱自己的文件看成未跟踪,
# 于是工具拒绝干活 —— 判的根本不是同一件事。
if _top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" \
   && [[ "$(realpath -m "$_top")" == "$(realpath -m "$ROOT")" ]]; then
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

# PDG_BUMP_SKIP_VERIFY 只对**测试取件器**有效。正式的官方下载路径不得被它绕过 —— 否则它
# 就是一个"跳过全部证据"的环境变量后门, 而这个脚本的产出正是供应链钉值。
# 这一问必须在取件**之前**: 放在取件之后的话, 官方路径会先因为"取件失败"而 die, 守卫
# 永远不会被执行到, 看着有、实际等于没有。
if [[ -n "${PDG_BUMP_SKIP_VERIFY:-}" && -z "$FETCH" ]]; then
  die "PDG_BUMP_SKIP_VERIFY 只能与 PDG_BUMP_FETCHER(测试取件器)同时使用; 官方下载路径不接受跳过校验"
fi

# 跑不动的那个架构只能靠 ELF 头。**读完整的头**, 不是只读偏移 18 的两个字节:
#   0-3  magic      7f 45 4c 46  (\x7fELF)   —— 只看 e_machine 的话, 一个随手伪造 18-19
#   4    EI_CLASS   02 = ELF64                   两字节的**非 ELF 文件**就能过关
#   5    EI_DATA    01 = 小端
#   6    EI_VERSION 01
#   18-19 e_machine  小端: amd64=0x003e(3e00), arm64=0x00b7(b700)
_elf_header_ok(){
  local f="$1" want="$2" h magic cls endian ver mach
  h="$(od -An -tx1 -N20 "$f" 2>/dev/null | tr -d ' \n')"
  [[ "${#h}" -ge 40 ]] || { say "  ELF 头读不满 20 字节"; return 1; }
  magic="${h:0:8}"; cls="${h:8:2}"; endian="${h:10:2}"; ver="${h:12:2}"; mach="${h:36:4}"
  [[ "$magic"  == "7f454c46" ]] || { say "  不是 ELF(magic=$magic)"; return 1; }
  [[ "$cls"    == "02" ]]       || { say "  不是 ELF64(EI_CLASS=$cls)"; return 1; }
  [[ "$endian" == "01" ]]       || { say "  不是小端(EI_DATA=$endian)"; return 1; }
  [[ "$ver"    == "01" ]]       || { say "  EI_VERSION=$ver(期望 01)"; return 1; }
  case "$want" in
    amd64) [[ "$mach" == "3e00" ]] || { say "  e_machine=$mach, 不是 x86-64"; return 1; };;
    arm64) [[ "$mach" == "b700" ]] || { say "  e_machine=$mach, 不是 AArch64"; return 1; };;
    *) return 1;;
  esac
}

# ── ⑦ 官方 asset digest 交叉核对 ────────────────────────────────────────────
# 按**精确资产名**取。这一步不能用通配: mihomo 同一个 tag 下 amd64 家族就有 20+ 个相似名
# (-compatible- / -v1- / -v2- / -v3- / -go120- / -go123-, 外加 .deb/.rpm/.pkg.tar.zst),
# 通配一下就会抓到另一个文件, 而它同样"下载成功、哈希算得出来"。
_asset_name(){ case "$1" in mihomo) echo "mihomo-linux-$3-$2.gz";; mosdns) echo "mosdns-linux-$3.zip";; esac; }
_official_digest(){             # $1=组件 $2=版本 $3=架构 → stdout: sha256 十六进制(取不到则空)
  local comp="$1" ver="$2" arch="$3" repo name out
  case "$comp" in mihomo) repo=MetaCubeX/mihomo;; mosdns) repo=IrineSistiana/mosdns;; *) return 0;; esac
  name="$(_asset_name "$comp" "$ver" "$arch")"
  command -v gh >/dev/null 2>&1 || return 0
  # 精确匹配 tag 与资产名; 命中数必须恰好 1
  out="$(gh api "repos/$repo/releases/tags/$ver" \
        --jq "[.assets[] | select(.name==\"$name\") | .digest] | @tsv" 2>/dev/null)" || return 0
  [[ "$(wc -w <<<"$out")" == 1 ]] || return 0
  printf '%s\n' "${out#sha256:}"
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
    # 官方 digest 交叉核对(只在走官方下载、且 API 给得出 digest 时)
    if [[ -z "$FETCH" ]]; then
      _dg="$(_official_digest "$COMP" "$VER" "$arch")"
      if [[ -n "$_dg" ]]; then
        _got="$(sha256sum "$d/archive" | cut -d' ' -f1)"
        [[ "$_got" == "$_dg" ]] \
          || die "$arch 归档与官方 asset digest 不一致 —— 拒绝写文件。实得 $_got, 官方 $_dg"
        say "  $arch 官方 asset digest ✓ 交叉核对一致"
      else
        say "  $arch 官方 asset digest: 取不到(无 gh / 该资产未提供)—— 少一条交叉证据, 其余核对照做"
      fi
    fi
    if [[ "$arch" == "$HOST_ARCH" ]]; then
      # 本机能跑: 直接问它自己是哪一版 —— 这是"哈希是否贴错对象"唯一的硬证据
      got="$("$d/binary" -v 2>/dev/null || "$d/binary" version 2>/dev/null || true)"
      got="$(printf '%s' "$got" | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      [[ "v${got#v}" == "$VER" ]] \
        || die "$arch 自报版本是 ${got:-读不出}, 不是 $VER —— 拒绝把这份哈希写进去"
      say "  $arch 自报版本 ✓ $VER"
    else
      _elf_header_ok "$d/binary" "$arch" \
        || die "$arch 的产物不是该架构的 ELF64 —— 可能两次下成了同一个架构, 或根本不是 ELF"
      say "  $arch ELF 头 ✓ magic/class/endian/e_machine 全中(本机跑不动, 只能验到这一层)"
    fi
  fi

  ARCHIVE_SHA[$arch]="$(sha256sum "$d/archive" | cut -d' ' -f1)"
  BIN_SHA[$arch]="$(sha256sum "$d/binary" | cut -d' ' -f1)"
  say "  $arch 归档 sha256 = ${ARCHIVE_SHA[$arch]}"
  [[ "$COMP" == mosdns ]] && say "  $arch 二进制 sha256 = ${BIN_SHA[$arch]}"
done

# ── 改写: 全程在**同目录的暂存副本**上做, 验完再原子替换 ───────────────────
# 为什么不能逐次直写正式文件: 这个脚本要改 3~6 行, 其中大多数是 64 位十六进制。中途任何
# 一次替换失败(锚点没命中 / 磁盘满 / 被打断), 正式文件就停在"版本换了、第二个哈希没换"
# 这种半套状态 —— 而那正是最坏的一种: 装机会 die 在 SHA 校验上, 报错指向供应链异常,
# 现场根本看不出是工具写了一半。
#
# 暂存文件必须与目标**同目录**: mktemp 默认落 /tmp, 跨文件系统时 mv 不是原子的(会退化成
# 复制+删除, 中途被打断同样留下半个文件)。同目录 + mv 才有 rename(2) 的原子性。
#
# 锚点用**行首字面量**匹配(index), 不用正则 —— 这不是风格问题:
# `awk -v pat='^  \[mihomo-amd64\]='` 里的 `\[` 会被 awk 的 -v 当转义序列处理。gawk 把它
# 变成裸 `[`, 于是 pat 成了字符类, 什么都匹配不上; mawk 保持原样, 照常匹配。同一份脚本在
# Debian(mawk)上全绿、在 GitHub runner(gawk)上静默不改那两行 —— 版本号换了、哈希没换,
# 而且没有任何报错。ENVIRON[] 取值不做转义处理, index() 也不碰正则, 两头都堵上。
BEFORE_SHA="$(sha256sum "$VERSIONS" | cut -d' ' -f1)"     # ① 前像, 收尾要拿它对账
STAGE="$(mktemp "${VERSIONS}.pdg-bump.XXXXXX")" || die "建不出暂存文件(与目标同目录)"
# 任何非正常退出都不许留下暂存物, 也不许动正式文件
trap 'rm -f "$STAGE" 2>/dev/null; rm -rf "$WORK" 2>/dev/null' EXIT
cat "$VERSIONS" > "$STAGE" || die "拷贝前像到暂存失败"
chmod --reference="$VERSIONS" "$STAGE" 2>/dev/null || true

_sub(){                          # $1=行首字面量前缀 $2=整行新内容 —— **只改 $STAGE**
  local pre="$1" new="$2" n tmp
  n=$(P="$pre" awk 'index($0, ENVIRON["P"])==1 {c++} END{print c+0}' "$STAGE")
  [[ "$n" == 1 ]] || die "锚点命中 $n 次(期望 1): '$pre' —— versions.sh 换写法了, 工具要跟着改"
  tmp="$(mktemp "${STAGE}.step.XXXXXX")" || die "建不出中间文件"
  if ! P="$pre" N="$new" awk 'index($0, ENVIRON["P"])==1 { print ENVIRON["N"]; next } { print }' \
       "$STAGE" > "$tmp"; then rm -f "$tmp"; die "改写失败: '$pre'"; fi
  mv -f "$tmp" "$STAGE" || { rm -f "$tmp"; die "暂存替换失败: '$pre'"; }
}
# 版本常量那一行: 保留行尾原有注释, 只换引号里的值
_verline="$(K="$VER_KEY" V="$VER" awk '
  index($0, ENVIRON["K"] "=")==1 { sub(/"[^"]*"/, "\"" ENVIRON["V"] "\""); print; exit }' "$STAGE")"
[[ -n "$_verline" ]] || die "取不到 $VER_KEY 那一行"
_sub "${VER_KEY}=" "$_verline"
for arch in amd64 arm64; do
  _sub "  [${COMP}-${arch}]=" "  [${COMP}-${arch}]=\"${ARCHIVE_SHA[$arch]}\""
  # mihomo 与 mosdns 现在都钉解压后二进制(mihomo 的那两条是本轮补的)
  _sub "  [${COMP}-bin-${arch}]=" "  [${COMP}-bin-${arch}]=\"${BIN_SHA[$arch]}\""
done

# ── 全部验完, 才谈替换正式文件 ──────────────────────────────────────────────
bash -n "$STAGE" || die "改写后语法坏了 —— 正式文件未动"
_readback(){ grep -oE "^  \[$1\]=\"[0-9a-f]*\"" "$STAGE" | head -1 | grep -oE '[0-9a-f]{16,}' | head -1; }
_rb="$(grep -oE "^${VER_KEY}=\"[^\"]*\"" "$STAGE" | head -1 | sed -e 's/.*="//' -e 's/"$//')"
[[ "$_rb" == "$VER" ]] || die "回读 $VER_KEY = '${_rb:-<空>}', 期望 '$VER' —— 正式文件未动"
for arch in amd64 arm64; do
  _rb="$(_readback "${COMP}-${arch}")"
  [[ "$_rb" == "${ARCHIVE_SHA[$arch]}" ]] \
    || die "回读 [${COMP}-${arch}] = '${_rb:-<空>}', 期望 '${ARCHIVE_SHA[$arch]}' —— 正式文件未动"
  _rb="$(_readback "${COMP}-bin-${arch}")"
  [[ "$_rb" == "${BIN_SHA[$arch]}" ]] \
    || die "回读 [${COMP}-bin-${arch}] = '${_rb:-<空>}', 期望 '${BIN_SHA[$arch]}' —— 正式文件未动"
done
# 正式文件到这一刻必须仍然等于前像 —— 若不等, 说明有别的东西在改它, 停手
[[ "$(sha256sum "$VERSIONS" | cut -d' ' -f1)" == "$BEFORE_SHA" ]] \
  || die "改写期间 $VERSIONS 被别的东西动过 —— 拒绝覆盖"
mv -f "$STAGE" "$VERSIONS" || die "原子替换失败 —— 正式文件未动"
STAGE=""                       # 已经搬走, 别在 trap 里删掉正式文件
trap 'rm -rf "$WORK" 2>/dev/null' EXIT
say "  回读自查 ✓ 文件里的值与刚算的逐项一致"

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
