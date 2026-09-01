#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 两条**运行时换核**取件路径的工作区与边界: _update_core_binary(mihomo) /
# _update_mosdns_binary(mosdns)。
#
# 盯两件事, 都是 fail-closed 的前提:
#
# ① **临时目录建不出来时必须就地停住。** 两条路径原本都是裸的 `tmp=$(mktemp -d)`,
#    不看返回值。pdg.sh 是 `set -uo pipefail`(**没有 -e**), 所以 mktemp 失败之后
#    $tmp 只是个空串, 执行照常往下走 —— 下载目标于是从 "$tmp/m.zip" 退化成 **/m.zip**、
#    "$tmp/m.gz" 退化成 **/m.gz**。函数最终仍会返回非零(下载/校验会失败), 但它是在
#    **往根目录写过一把之后**才失败的, 而且报出来的原因是"下载失败", 排错方向整个偏掉。
#    这台机器上跑这段的是 root。
#
# ② **下载必须有界。** 两条 curl 都只有 -fsSL, 没有连接超时也没有总时长上限。一个不回包
#    的中间设备就能把 `pdg update` 挂住 —— 而这条路径跑在换核事务里。超时之后的文案还得
#    与"版本与发布不一致"分开: 那是两种完全不同的现场, 混成一句话等于把排错引到错误的
#    方向(去查 Release 有没有这个版本, 而实际上是网络不通)。
#
# 全程离线、不写根目录: curl 由**只记录 argv 的假桩**接管, 它一个字节都不落盘。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-coredl.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
: > "$WORK/notfound.log"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

xt(){  sed -n "/^$1(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"; }
xtv(){ sed -n "/^$1(){/,/^}/p" "$ROOT/lib/versions.sh"; }

# 闭包清单。少抽一个就是 127, 而 127 会被下游判据当成普通返回值吞掉 —— 见 HANDOFF §9.11。
# 末尾还有一条 command not found 的运行期记账兜底。
for f in _update_core_binary _update_mosdns_binary _core_bindir _pdg_mktemp_dir; do
  [[ -n "$(xt "$f")" ]] || { echo "[FAIL] pdg.sh 里抽不到 $f"; echo "通过 0, 失败 1"; exit 1; }
done
ok "从 deploy/bot/pdg.sh 抽到两条换核取件函数与 _core_bindir / _pdg_mktemp_dir"
# 超时常量从 pdg.sh 原样取, 不在测试里另写一份数值(写两份迟早漂开)
TMO="$(grep -E '^PDG_CORE_(CONNECT_TIMEOUT|MAX_TIME)=' "$ROOT/deploy/bot/pdg.sh")"

# ── 夹具 ─────────────────────────────────────────────────────────────────────
BIN="$WORK/bin"; mkdir -p "$BIN"
# 自报版本对得上、内容是钉死那一份的假内核(只用来做"已是钉死版"的短路格)
mkcore(){ printf '#!/bin/sh\ncase "${1:-}" in version|-v) echo "%s %s";; esac\nexit 0\n' "$2" "$1"; }
mkcore v9.9.9 mosdns > "$WORK/mosdns.pinned"; chmod 755 "$WORK/mosdns.pinned"
mkcore v9.9.9 mihomo > "$WORK/mihomo.pinned"; chmod 755 "$WORK/mihomo.pinned"
MOS_PIN="$(sha256sum "$WORK/mosdns.pinned" | cut -d' ' -f1)"
MIH_PIN="$(sha256sum "$WORK/mihomo.pinned" | cut -d' ' -f1)"
ZERO=0000000000000000000000000000000000000000000000000000000000000000

mkrepo(){ # $1=目录 $2=mosdns-bin 钉值 $3=mihomo-bin 钉值
  mkdir -p "$1/lib"
  { echo 'MOSDNS_VER="v9.9.9"'; echo 'MIHOMO_VER="v9.9.9"'
    echo "declare -A PDG_SHA256=( [mosdns-amd64]=\"$ZERO\" [mosdns-arm64]=\"$ZERO\" \\"
    echo "                        [mihomo-amd64]=\"$ZERO\" [mihomo-arm64]=\"$ZERO\" \\"
    echo "                        [mosdns-bin-amd64]=\"$2\" [mosdns-bin-arm64]=\"$2\" \\"
    echo "                        [mihomo-bin-amd64]=\"$3\" [mihomo-bin-arm64]=\"$3\" )"
    xtv pdg_mosdns_version; xtv pdg_mosdns_is_version; xtv pdg_mosdns_binary_ok
    xtv pdg_mihomo_version; xtv pdg_mihomo_is_version; xtv pdg_mihomo_binary_ok
    xtv pdg_verify_sha256
  } > "$1/lib/versions.sh"
}
mkrepo "$WORK/repo-need" "$ZERO" "$ZERO"          # 钉值对不上盘上的 → 必须进取件分支
mkrepo "$WORK/repo-have" "$MOS_PIN" "$MIH_PIN"    # 已经是钉死版 → 必须短路

# 跑一次换核取件函数。
#   $1=仓库目录 $2=函数名 $3=mktemp 行为(ok|fail) $4=curl 返回码
# curl 是**纯记录桩**: 把 argv 逐个 NUL 分隔写进 argv.log, 一个字节都不落盘。
run(){
  local repo="$1" fn="$2" mtmode="$3" crc="$4" rc=0 out
  : > "$WORK/argv.log"; : > "$WORK/calls.log"
  out=$(
    REPO_DIR="$repo" PDG_CORE_BINDIR="$BIN" MTMODE="$mtmode" CRC="$crc" \
    ARGV="$WORK/argv.log" CALLS="$WORK/calls.log" \
    bash -c '
      set -uo pipefail
      c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
      dpkg(){ echo amd64; }
      mktemp(){ echo "mktemp $*" >> "$CALLS"
                if [[ "$MTMODE" == fail ]]; then return 1; fi
                command mktemp "$@"; }
      curl(){ echo "curl" >> "$CALLS"; printf "%s\0" "$@" >> "$ARGV"; return "$CRC"; }
      unzip(){ echo "unzip" >> "$CALLS"; return 1; }
      gunzip(){ echo "gunzip" >> "$CALLS"; return 1; }
      _core_swap_verify(){ echo "swap" >> "$CALLS"; return 0; }
      '"$TMO"'
      '"$(xt _core_bindir)"'
      '"$(xt _pdg_mktemp_dir)"'
      '"$(xt _core_dl_reason)"'
      '"$(xt _update_core_binary)"'
      '"$(xt _update_mosdns_binary)"'
      "$1"' _ "$fn" 2>&1
  ) || rc=$?
  printf '%s\n' "$rc"
  printf '%s' "$out" > "$WORK/out.txt"
  grep -F 'command not found' <<<"$out" >> "$WORK/notfound.log" 2>/dev/null || true
}
ncalls(){ local n; n="$(grep -c "^$1" "$WORK/calls.log" 2>/dev/null)"; printf '%s\n' "${n:-0}"; }
argv(){ tr '\0' '\n' < "$WORK/argv.log" 2>/dev/null; }
outp(){ cat "$WORK/out.txt" 2>/dev/null; }

echo
echo "══ A. mktemp 失败: 必须在取件之前就地停住 ══"
for spec in "mosdns|_update_mosdns_binary|/m.zip" "mihomo|_update_core_binary|/m.gz"; do
  IFS='|' read -r nm fn rootpath <<<"$spec"
  cp "$WORK/$nm.pinned" "$BIN/$nm"; chmod 755 "$BIN/$nm"
  before="$(sha256sum "$BIN/$nm" | cut -d' ' -f1)"
  rc="$(run "$WORK/repo-need" "$fn" fail 0)"

  [[ "$(ncalls curl)" == 0 ]] \
    && ok "[$nm] 临时目录失败后 curl 一次都没被调到" \
    || bad "[$nm] 临时目录失败后仍然发起了取件($(ncalls curl) 次), 落盘目标: $(argv | grep -m1 '^/' || echo 未知)"
  if [[ "$(ncalls curl)" != 0 ]]; then
    argv | grep -qx -- "$rootpath" \
      && bad "[$nm] 下载目标退化成根目录 $rootpath(空 \$tmp 拼出来的)" \
      || ok "[$nm] 取件目标没有退化到根目录"
  else
    ok "[$nm] 取件目标没有退化到根目录(压根没取件)"
  fi
  [[ "$(sha256sum "$BIN/$nm" | cut -d' ' -f1)" == "$before" ]] \
    && ok "[$nm] 现有二进制一字节未变" || bad "[$nm] 现有二进制被动过了"
  [[ "$rc" != 0 ]] && ok "[$nm] 返回非零" || bad "[$nm] 临时目录失败却返回 0"
  if grep -q '无法创建临时目录' <<<"$(outp)"; then
    ok "[$nm] 文案点名「无法创建临时目录」"
  else
    bad "[$nm] 文案没点名临时目录, 实得: $(outp | tr '\n' ' ' | head -c 160)"
  fi
  grep -qE '下载失败|SHA 校验失败|摘要' <<<"$(outp)" \
    && bad "[$nm] 临时目录失败被冒充成网络/摘要失败" \
    || ok "[$nm] 没有把临时目录失败冒充成网络或摘要失败"
  [[ ! -e "$rootpath" ]] && ok "[$nm] 根目录没有留下 $rootpath" || bad "[$nm] 根目录残留 $rootpath"
done

echo
echo "══ A2. mihomo 的「已是钉死版」短路必须发生在建临时目录之前 ══"
cp "$WORK/mihomo.pinned" "$BIN/mihomo"; chmod 755 "$BIN/mihomo"
rc="$(run "$WORK/repo-have" _update_core_binary fail 0)"
[[ "$rc" == 0 ]] && ok "已是钉死版 + 临时目录不可用 → 仍然返回 0(本来就无事可做)" \
                 || bad "已是钉死版却因为临时目录失败而判失败(rc=$rc)"
[[ "$(ncalls mktemp)" == 0 ]] \
  && ok "已是钉死版时压根没去建临时目录" \
  || bad "先建了临时目录才判短路 —— 无事可做的路径不该申请工作区($(ncalls mktemp) 次)"

echo
echo "══ B. 下载必须有界(连接超时 + 总时长)══"
for spec in "mosdns|_update_mosdns_binary" "mihomo|_update_core_binary"; do
  IFS='|' read -r nm fn <<<"$spec"
  cp "$WORK/$nm.pinned" "$BIN/$nm"; chmod 755 "$BIN/$nm"
  run "$WORK/repo-need" "$fn" ok 0 >/dev/null
  A="$(argv)"
  grep -qx -- '--connect-timeout' <<<"$A" \
    && ok "[$nm] curl 带有界连接超时 --connect-timeout" \
    || bad "[$nm] curl 没有连接超时 —— 连不上的对端可以把 pdg update 挂住"
  grep -qx -- '--max-time' <<<"$A" \
    && ok "[$nm] curl 带有界总时长 --max-time" \
    || bad "[$nm] curl 没有总时长上限 —— 慢速回包可以无限拖住换核事务"
  grep -qE -- '^-fsSL$|^-fSL$' <<<"$A" \
    && ok "[$nm] 保留 -fSL 语义(失败即非零 / 跟随重定向)" \
    || bad "[$nm] -fSL 语义被改掉了, 实得: $(grep '^-' <<<"$A" | tr '\n' ' ')"
  grep -qx -- '--retry' <<<"$A" \
    && bad "[$nm] 引入了重试 —— 本轮不加重试(会与总时长叠加成不可预期的时长)" \
    || ok "[$nm] 没有引入重试"
done

echo
echo "══ C. 超时必须与「版本与发布不一致」分开 ══"
for spec in "mosdns|_update_mosdns_binary" "mihomo|_update_core_binary"; do
  IFS='|' read -r nm fn <<<"$spec"
  cp "$WORK/$nm.pinned" "$BIN/$nm"; chmod 755 "$BIN/$nm"
  rc="$(run "$WORK/repo-need" "$fn" ok 28)"      # 28 = curl 的 operation timed out
  [[ "$rc" != 0 ]] && ok "[$nm] curl 超时 → 返回非零" || bad "[$nm] curl 超时却返回 0"
  if grep -qE '超时|网络|连不上|timed out' <<<"$(outp)"; then
    ok "[$nm] 超时被说成网络/超时问题"
  else
    bad "[$nm] 超时没被识别出来, 实得: $(outp | tr '\n' ' ' | head -c 160)"
  fi
  grep -q '版本与发布不一致' <<<"$(outp)" \
    && bad "[$nm] 把网络超时冒充成「版本与发布不一致」—— 排错方向整个偏掉" \
    || ok "[$nm] 没有把超时冒充成版本问题"
done


[[ ! -s "$WORK/notfound.log" ]] \
  && ok "闭包完整: 一条 command not found 都没有(127 不会被判据当普通返回值吞掉)" \
  || bad "闭包漏桩: $(grep -oE '[A-Za-z0-9_]+: command not found' "$WORK/notfound.log" | sort -u | tr '\n' ' ')"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
