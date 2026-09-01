#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 装机取件必须把"下载没成"和"下到的东西不对"分开报。
#
# 修之前 install.sh 的两处取件都是裸 curl, 没有自己的错误检查:
#
#     curl -fsSL "https://…/mosdns-linux-${MARCH}.zip" -o "$t/m.zip"
#     pdg_verify_sha256 "$t/m.zip" …
#
# 于是有两种很不一样的故障, 用户都看不出是取件出的问题:
#   · curl 真失败(DNS 不通 / 404 / 超时) → `set -euo pipefail` 在那一行直接中止 →
#     EXIT trap 跑 rollback。用户看到的是"回滚"和 curl 的数字退出码(6/22/28), 从头到尾
#     没有一行说"下载失败"。排错方向会被带偏到安装逻辑上。
#   · curl 返回 0 但内容不对(代理错误页 / 缓存 / curl 没察觉的截断) → 掉进 SHA 校验,
#     报"拒绝安装(供应链异常, 或版本与 lib/versions.sh 不符)" —— 读起来像被投毒, 实际
#     可能只是网络给了一份垃圾。
#
# 两个内核对称: mosdns 与 mihomo 的取件都要具名。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-dlerr.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

SRC="$ROOT/install.sh"
decom(){ sed -E 's/^[[:space:]]*#.*$//' "$SRC"; }

echo "══ 1. 两处取件都要有自己的错误检查 ══"
# 判据落在**去注释后的代码**上: 注释里出现 curl 不算数。
for comp in mosdns mihomo; do
  line="$(decom | grep -nE "curl -fsSL \"https://github\.com/[A-Za-z]+/$comp/releases" | head -1)"
  if [[ -z "$line" ]]; then bad "[$comp] 找不到取件那一行(install.sh 换写法了?)"; continue; fi
  n="${line%%:*}"
  # 只取 curl **这一条语句**(跟着反斜杠续行走), 不把下一条命令算进来。
  # 第一版取了固定 3 行, 于是 pdg_verify_sha256 那行的 `|| {` 被当成了 curl 的错误处置,
  # 在生产代码根本没改的情况下报 [OK]。
  # curl 这一条语句本身(跟着反斜杠续行走)—— 用来判"curl 有没有自己的错误处置"。
  # 不能取固定行数: 第一版取 3 行, 把下一条 pdg_verify_sha256 的 `|| {` 当成了 curl 的,
  # 于是生产代码没改也报 [OK]。
  stmt="$(decom | awk -v s="$n" 'NR>=s { print; if ($0 !~ /\\$/) exit }')"
  # 取件到校验**之间**的全部代码 —— 用来判"有没有检查产物非空"。非空检查是紧随其后的
  # 另一条语句, 落在 stmt 之外, 所以这两问要用两个窗口。
  blk="$(decom | awk -v s="$n" 'NR>=s { if ($0 ~ /pdg_verify_sha256/) exit; print }')"
  if grep -qE '\|\| *(die|\{)' <<<"$stmt"; then ok "[$comp] curl 有显式错误处置"
  else bad "[$comp] curl 后面没有错误处置 —— 失败时靠 set -e 静默中止, 用户看不到是取件挂了"; fi
  if grep -qE '下载|取件' <<<"$stmt"; then ok "[$comp] 失败文案点名「下载/取件」"
  else bad "[$comp] 失败文案没点名取件这一层"; fi
  if grep -qE '\-s "\$t/|\[\[ -s ' <<<"$blk"; then ok "[$comp] 检查产物非空(挡住 0 字节/截断成空)"
  else bad "[$comp] 没检查产物非空"; fi
done

echo
echo "══ 2. 行为: 三种故障必须报成三种话 ══"
# 把取件那一段原样抽出来跑, 不在测试里另抄一份。
extract(){   # $1=组件 → 打印"curl 行 + 后面 4 行"
  local comp="$1" n
  n="$(decom | grep -nE "curl -fsSL \"https://github\.com/[A-Za-z]+/$comp/releases" | head -1 | cut -d: -f1)"
  [[ -n "$n" ]] || return 1
  decom | sed -n "${n},$((n+5))p"
}
run(){       # $1=组件 $2=curl 行为(fail|empty|garbage) → 输出
  local comp="$1" mode="$2"
  local d="$WORK/$comp-$mode"
  rm -rf "$d"; mkdir -p "$d/bin"
  case "$mode" in
    fail)    printf '#!/bin/sh\nexit 6\n' > "$d/bin/curl";;
    empty)   printf '#!/bin/sh\no=""; p=""; for a in "$@"; do [ "$p" = -o ] && o="$a"; p="$a"; done; : > "$o"; exit 0\n' > "$d/bin/curl";;
    garbage) printf '#!/bin/sh\no=""; p=""; for a in "$@"; do [ "$p" = -o ] && o="$a"; p="$a"; done; printf garbage > "$o"; exit 0\n' > "$d/bin/curl";;
  esac
  chmod 755 "$d/bin/curl"
  { echo 'set -euo pipefail'
    echo 'die(){ echo "[x] $*" >&2; exit 1; }'
    echo 'c_g(){ echo "$*"; }'
    # 钉值取真的那一份, 于是 garbage 一定不符
    echo "source '$ROOT/lib/versions.sh'"
    echo 'MARCH=amd64'
    echo "t='$d'"
    echo '_stash_bin(){ return 0; }'
    echo 'install(){ return 0; }'
    echo 'unzip(){ return 0; }'
    echo 'gunzip(){ return 0; }'
    extract "$comp"
  } > "$d/run.sh"
  PATH="$d/bin:$PATH" bash "$d/run.sh" 2>&1
}
for comp in mosdns mihomo; do
  o="$(run "$comp" fail)"
  if grep -qE '下载|取件' <<<"$o"; then ok "[$comp] curl 失败 → 具名说是取件挂了"
  else bad "[$comp] curl 失败没有具名(实得: $(tr '\n' ' ' <<<"$o" | cut -c1-70))"; fi
  # 这一条不能在"输出为空"时也算过 —— 空输出当然不含 SHA 字样, 那是"什么都没说",
  # 不是"说对了"。必须先要求它真的说了话。
  if [[ -z "${o// /}" ]]; then bad "[$comp] curl 失败时一个字都没说(被 set -e 静默中止)"
  elif grep -qE 'SHA256 校验失败' <<<"$o"; then bad "[$comp] curl 失败却报成 SHA 校验失败(诊断被带偏)"
  else ok "[$comp] curl 失败: 说了话, 且不冒充摘要问题"; fi

  o="$(run "$comp" empty)"
  if grep -qE '空|截断|下载|取件' <<<"$o"; then ok "[$comp] 产物为空 → 具名"
  else bad "[$comp] 产物为空没有具名(实得: $(tr '\n' ' ' <<<"$o" | cut -c1-70))"; fi

  o="$(run "$comp" garbage)"
  if grep -qE 'SHA256 校验失败|校验未通过|不符' <<<"$o"; then ok "[$comp] 内容不对 → 仍然按摘要不符报(这一类没有被改掉)"
  else bad "[$comp] 内容不对时反而不报摘要问题了(实得: $(tr '\n' ' ' <<<"$o" | cut -c1-70))"; fi
done

echo "────────────────────────────────────────"
echo "$(basename "$0"): 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
