#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mosdns 的**运行时换版路径**(_update_mosdns_binary)。
#
# 由来: _update_core_binary 从来只管 mihomo, mosdns 只有 install.sh 里那一条下载路径。
# 于是 MOSDNS_VER 一旦上调, 存量机器的 `pdg update` 会照常走完全程, 最后被 doctor 的
# check_mosdns_binary(拿**新**钉值比**旧**二进制)判红, 再整个回滚 —— 每次都翻, 而且
# 越是按流程走的机器翻得越准。这条路径就是来补这个缺口的。
#
# 它比 mihomo 那条多两层, 两层都要钉死:
#   ① 官方产物是 zip, 项目对它钉了**两份**哈希(压缩包 + 解压后的二进制), 两份都要过;
#   ② 解压产物**落盘之前**就要核完 —— 换核是在一台正在服务的机器上覆盖运行文件,
#      没有理由先把一个没核过的文件放进 /usr/local/bin 再回头补票。
#
# 全程离线: curl 由夹具接管, zip 用 python3 现造。不碰真网、不碰真 /usr/local/bin。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-mosbin.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
command -v unzip >/dev/null 2>&1 || { echo "[SKIP] 无 unzip"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] 无 python3"; exit 0; }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

xt(){ sed -n "/^$1(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"; }
xtv(){ sed -n "/^$1(){/,/^}/p" "$ROOT/lib/versions.sh"; }

echo "══ 1. 函数存在, 且判据/钉值都取自单一真源 ══"
FN="$(xt _update_mosdns_binary)"
if [[ -n "$FN" ]]; then ok "pdg.sh 里有 _update_mosdns_binary"; else
  bad "pdg.sh 里没有 _update_mosdns_binary —— mosdns 仍然没有换版路径"; exit 1; fi
grep -q 'pdg_mosdns_binary_ok' <<<"$FN" \
  && ok "短路判据走 pdg_mosdns_binary_ok(与 install.sh / doctor / 更新前预检同一份)" \
  || bad "短路判据另立了一套 —— 迟早与安装器和 doctor 漂开"
grep -q 'lib/versions.sh' <<<"$FN" && ok "版本与钉值从 lib/versions.sh 读" || bad "没读 lib/versions.sh"
grep -q 'mosdns-bin-' <<<"$FN" \
  && ok "用到了**解压后二进制**的钉值(不是只核压缩包)" \
  || bad "只核了压缩包 —— 那正是当初 mosdns-bin-* 钉值要补的那个洞"

echo
echo "══ 2. 造一套离线夹具(真 zip / 真 sha / 假 curl)══"
BIN="$WORK/bin"; mkdir -p "$BIN"
mkmosdns(){ printf '#!/bin/sh\ncase "$1" in version) echo "mosdns %s-0-g%s";; esac\nexit 0\n' "$1" "${2:-abc}"; }
mkmosdns v9.9.9 pinned > "$WORK/mosdns.pinned"; chmod 755 "$WORK/mosdns.pinned"
mkmosdns v8.8.8 old    > "$WORK/mosdns.old";    chmod 755 "$WORK/mosdns.old"
PIN_BIN_SHA="$(sha256sum "$WORK/mosdns.pinned" | cut -d' ' -f1)"

mkzip(){ # $1=输出 zip  $2=放进去的二进制  [$3=成员名, 默认 mosdns]
  python3 - "$1" "$2" "${3:-mosdns}" <<'PY'
import sys, zipfile, os
z, src, name = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(z, "w") as f:
    zi = zipfile.ZipInfo(name); zi.external_attr = 0o755 << 16
    f.writestr(zi, open(src, "rb").read())
PY
}
mkzip "$WORK/good.zip"  "$WORK/mosdns.pinned"
mkzip "$WORK/wrong.zip" "$WORK/mosdns.old"                  # zip 本身合法, 里面装的是别的二进制
mkzip "$WORK/noname.zip" "$WORK/mosdns.pinned" other-name   # 里面没有叫 mosdns 的成员
PIN_ZIP_SHA="$(sha256sum "$WORK/good.zip" | cut -d' ' -f1)"
WRONG_ZIP_SHA="$(sha256sum "$WORK/wrong.zip" | cut -d' ' -f1)"
ok "夹具就绪(压缩包钉值 ${PIN_ZIP_SHA:0:12}…, 二进制钉值 ${PIN_BIN_SHA:0:12}…)"

mkrepo(){ # $1=目录 $2=压缩包钉值(可为 bogus)
  mkdir -p "$1/lib"
  { echo 'MOSDNS_VER="v9.9.9"'
    echo "declare -A PDG_SHA256=( [mosdns-amd64]=\"$2\" [mosdns-arm64]=\"$2\" \\"
    echo "                        [mosdns-bin-amd64]=\"$PIN_BIN_SHA\" [mosdns-bin-arm64]=\"$PIN_BIN_SHA\" )"
    xtv pdg_mosdns_version; xtv pdg_mosdns_is_version
    xtv pdg_mosdns_binary_ok; xtv pdg_verify_sha256
  } > "$1/lib/versions.sh"
}
mkrepo "$WORK/repo"  "$PIN_ZIP_SHA"
mkrepo "$WORK/repo-badzip" "0000000000000000000000000000000000000000000000000000000000000000"
# 关键的一格: 压缩包钉值**对得上** wrong.zip, 但它里面装的不是钉死的那个二进制。
# 只有这样才能走到"解压产物校验"那一层 —— 而那正是 mosdns-bin-* 钉值存在的理由。
mkrepo "$WORK/repo-wrongbin" "$WRONG_ZIP_SHA"

# 跑一次 _update_mosdns_binary。$1=仓库目录 $2=curl 要吐出来的 zip(或 FAIL)
# 换核那步打桩: 这支测的是"取件与校验", 换核本体归 test-core-swap.sh。
run(){
  local repo="$1" zip="$2" rc=0 out
  : > "$WORK/calls.log"
  out=$(
    REPO_DIR="$repo" PDG_CORE_BINDIR="$BIN" ZIPSRC="$zip" CALLS="$WORK/calls.log" \
    bash -c '
      c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
      '"$(grep -E '^PDG_CORE_(CONNECT_TIMEOUT|MAX_TIME)=' "$ROOT/deploy/bot/pdg.sh")"'
      '"$(xt _core_bindir)"'
      '"$(xt _pdg_mktemp_dir)"'
      '"$(xt _core_dl_reason)"'
      curl(){ echo "curl" >> "$CALLS"
              [[ "$ZIPSRC" == FAIL ]] && return 1
              local o=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { o="$2"; shift; }; shift; done
              cp "$ZIPSRC" "$o"; }
      _core_swap_verify(){ echo "swap $1 $4" >> "$CALLS"
                           command install -m755 "$2" "$3/$1"; }
      '"$(xt _update_mosdns_binary)"'
      _update_mosdns_binary' 2>&1
  ) || rc=$?
  printf '%s\n' "$rc|$out"
}
called(){ grep -qF "$1" "$WORK/calls.log" 2>/dev/null; }

echo
echo "══ 3. 已经是钉死版 → 短路, 一个字节都不下载 ══"
cp "$WORK/mosdns.pinned" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
r=$(run "$WORK/repo" "$WORK/good.zip"); rc="${r%%|*}"
{ [[ "$rc" == 0 ]] && ! called curl; } \
  && ok "版本+内容都已是钉死版 → rc=0 且从未取件" \
  || bad "短路失效: rc=$rc curl=$(called curl && echo 调了 || echo 没调)"

echo
echo "══ 3-bis. 自报版本对、内容不对 → **不许**短路 ══"
# 这就是 mosdns-bin-* 钉值当初要补的洞: 版本是二进制自报的, 只比版本的话, 一个
# 内容被换掉、版本串照抄的文件就能让整段换版被跳过, 而日志上连"下载"都不会出现。
mkmosdns v9.9.9 tampered > "$BIN/mosdns"; printf '# extra\n' >> "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
r=$(run "$WORK/repo" "$WORK/good.zip"); rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" == 0 ]] && called curl && called "swap mosdns" \
  && [[ "$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)" == "$PIN_BIN_SHA" ]]; } \
  && ok "自报版本相同但内容不符 → 照样取件换核, 落盘回到钉值" \
  || bad "内容不符却被短路跳过了(rc=$rc curl=$(called curl && echo 调了 || echo 没调)) —— 只比版本的老毛病回来了: $out"

echo
echo "══ 4. 版本漂了 → 取件、校验、换核 ══"
cp "$WORK/mosdns.old" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
r=$(run "$WORK/repo" "$WORK/good.zip"); rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" == 0 ]] && called "swap mosdns v9.9.9" \
  && [[ "$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)" == "$PIN_BIN_SHA" ]]; } \
  && ok "旧版 → 下载/双重校验/换核, 落盘内容等于钉值" \
  || bad "正常换版路径没走通: rc=$rc calls=$(tr '\n' ' ' < "$WORK/calls.log") out=$out"
grep -q 'v9.9.9' <<<"$out" && ok "日志里点出了目标版本" || bad "日志没说升到哪一版: $out"

echo
echo "══ 5. 四类故障: 一律非 0, 且**绝不换核** ══"
# 关键不只是"返回非0" —— 是坏件不许落到 /usr/local/bin。前三格分别卡在取件、
# 压缩包校验、解压产物校验, 每一格都必须在 _core_swap_verify 之前就停住。
declare -a CASES=(
  "下载失败|$WORK/repo|FAIL"
  "压缩包摘要不符|$WORK/repo-badzip|$WORK/good.zip"
  "解压产物摘要不符|$WORK/repo-wrongbin|$WORK/wrong.zip"
  "压缩包里没有 mosdns|$WORK/repo|$WORK/noname.zip"
)
for c in "${CASES[@]}"; do
  IFS='|' read -r nm repo zip <<<"$c"
  # 每格都从"旧版在跑"开始, 这样"没换核"才能用内容证明, 而不是靠日志自称
  cp "$WORK/mosdns.old" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
  OLDSHA="$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)"
  r=$(run "$repo" "$zip"); rc="${r%%|*}"; out="${r#*|}"
  [[ "$rc" != 0 ]] && ok "[$nm] 返回非 0(rc=$rc)" || bad "[$nm] 竟然返回 0: $out"
  called "swap " && bad "[$nm] 走到换核了 —— 坏件已经落盘" || ok "[$nm] 换核从未发生"
  [[ "$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)" == "$OLDSHA" ]] \
    && ok "[$nm] /usr/local/bin 上那个文件逐字节没动" \
    || bad "[$nm] 二进制被改了 —— 这正是不该发生的事"
done

echo
echo "══ 6. 无从对照时不动手(fail-closed)══"
cp "$WORK/mosdns.old" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
r=$(run "$WORK/nosuch-repo" "$WORK/good.zip"); rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" != 0 ]] && ! called curl; } \
  && ok "读不到 versions.sh → 非 0 且不取件(不在存疑时换核)" \
  || bad "读不到 versions.sh 却继续了: rc=$rc out=$out"
grep -q 'versions.sh' <<<"$out" && ok "说清了是读不到 versions.sh" || bad "原因不具名: $out"

echo
echo "══ 7. cmd_update 里的位置与处置 ══"
UPD="$(sed -n '/^cmd_update(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
grep -q '_update_mosdns_binary' <<<"$UPD" \
  && ok "cmd_update 真的调了它(不是只定义不用)" || bad "cmd_update 没调用 —— 定义了等于没有"
P_MOS="$(grep -n '_update_mosdns_binary' <<<"$UPD" | head -1 | cut -d: -f1)"
P_CORE="$(grep -n '_update_core_binary' <<<"$UPD" | head -1 | cut -d: -f1)"
P_DOC="$(grep -n 'doctor.py' <<<"$UPD" | head -1 | cut -d: -f1)"
{ [[ -n "$P_MOS" && -n "$P_DOC" ]] && [[ "$P_MOS" -lt "$P_DOC" ]]; } \
  && ok "换版排在 doctor 自检门**之前**($P_MOS < $P_DOC) —— 否则每次升版都必被判红回滚" \
  || bad "换版不在自检门之前(mosdns=$P_MOS doctor=$P_DOC)"
{ [[ -n "$P_MOS" && -n "$P_CORE" ]] && [[ "$P_MOS" -lt "$P_CORE" ]]; } \
  && ok "mosdns 排在 mihomo 之前(先让解析器回到钉死版)" \
  || bad "顺序不对(mosdns=$P_MOS mihomo=$P_CORE)"
# 失败要回滚, 不能 `|| true` 掉
sed -n '/if ! _update_mosdns_binary; then/,/fi/p' <<<"$UPD" | grep -q 'cmd_rollback' \
  && ok "换版失败 → 回滚整次更新(不降级成警告)" || bad "换版失败没有回滚"

echo
echo "══ 8. 快照必须收进 mosdns 二进制 ══"
# 换核成功、后面某一步失败 → cmd_rollback 得能把旧二进制放回去。快照不收它的话,
# 机器会停在"新二进制 + 旧仓库"这个既不是前也不是后的状态。
sed -n '/local cand=(/,/)$/p' "$ROOT/deploy/bot/pdg.sh" | grep -q 'usr/local/bin/mosdns' \
  && ok "cmd_snapshot cand 含 usr/local/bin/mosdns(回滚退得回去)" \
  || bad "快照不含 mosdns 二进制 —— 换核后回滚会退不干净"

echo "────────────────────────────────────────"
echo "$(basename "$0"): 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
