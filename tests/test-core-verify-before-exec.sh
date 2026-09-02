#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 内核完整性判据必须**先证明内容, 再执行**。
#
# pdg_mosdns_binary_ok / pdg_mihomo_binary_ok 是全项目的单一判据: 装机短路、doctor、
# 更新前预检、两条运行期换核路径都问它。它原来的顺序是
#     可执行? → 有钉值? → **执行它读版本** → 比版本 → 算摘要 → 比摘要
# 也就是说: 一个**内容还没被证明**的文件, 会先被这台机器以 root 跑起来一次。
#
# 这个顺序把判据自己变成了执行入口。判据存在的理由正是"盘上这个文件可能不是官方那一份";
# 在还没排除这件事之前先运行它, 等于假设结论。而且判据一定跑在最坏的现场 —— doctor 和
# 更新前预检就是专门去看"这台机器是不是被动过手脚"的。
#
# 正确顺序:
#     可执行? → 有钉值? → **算摘要并比对** → 摘要精确一致后才执行 → 版本仍须精确相等
#
# 判据靠 marker: 待验文件一旦被执行就写一行。摘要不符的那格里, marker 必须**不存在**。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-vbe.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

xtv(){ sed -n "/^$1(){/,/^}/p" "$ROOT/lib/versions.sh"; }
for f in pdg_mosdns_binary_ok pdg_mihomo_binary_ok; do
  [[ -n "$(xtv "$f")" ]] || { echo "[FAIL] lib/versions.sh 里抽不到 $f"; echo "通过 0, 失败 1"; exit 1; }
done
ok "从 lib/versions.sh 抽到两个内核完整性判据"

# 待验文件: 被执行就留痕, 同时会自报一个版本(所以"先执行"的实现能走通版本那一关)
mkprobe(){ # $1=输出 $2=自报版本 $3=marker 路径
  printf '#!/bin/sh\nprintf "x\\n" >> "%s"\ncase "${1:-}" in version|-v) echo "core %s linux amd64";; esac\nexit 0\n' \
    "$3" "$2" > "$1"
  chmod 755 "$1"
}

# 跑一次判据。$1=函数名 $2=期望版本 $3=钉值 $4=文件 → 回 rc
callpred(){
  local fn="$1" want="$2" pin="$3" bin="$4"
  bash -c '
    set -uo pipefail
    declare -A PDG_SHA256=( [mosdns-bin-amd64]="'"$pin"'" [mihomo-bin-amd64]="'"$pin"'" )
    '"$(xtv pdg_mosdns_binary_ok)"'
    '"$(xtv pdg_mihomo_binary_ok)"'
    '"$fn"' amd64 "'"$want"'" "'"$bin"'"' >/dev/null 2>&1
  echo $?
}

ZERO=0000000000000000000000000000000000000000000000000000000000000000
for spec in "mosdns|pdg_mosdns_binary_ok" "mihomo|pdg_mihomo_binary_ok"; do
  IFS='|' read -r nm fn <<<"$spec"
  echo
  echo "══ $nm ══"
  M="$WORK/$nm.marker"; B="$WORK/$nm.bin"

  # ── 1. 摘要不符: 必须拒绝, 而且**不许执行它** ──────────────────────────
  rm -f "$M"; mkprobe "$B" v9.9.9 "$M"
  rc="$(callpred "$fn" v9.9.9 "$ZERO" "$B")"
  [[ "$rc" != 0 ]] && ok "[$nm] 摘要不符 → 判据非零" || bad "[$nm] 摘要不符却判过了"
  [[ ! -e "$M" ]] \
    && ok "[$nm] 摘要不符时**没有执行**待验文件(判据不是执行入口)" \
    || bad "[$nm] 内容还没被证明就先把它跑起来了 —— 判据在摘要之前执行了待验二进制"

  # ── 2. 摘要相符 + 版本相符: 放行, 此时才允许执行 ────────────────────────
  rm -f "$M"; mkprobe "$B" v9.9.9 "$M"
  PIN="$(sha256sum "$B" | cut -d' ' -f1)"
  rc="$(callpred "$fn" v9.9.9 "$PIN" "$B")"
  [[ "$rc" == 0 ]] && ok "[$nm] 摘要与版本都对 → 放行" || bad "[$nm] 完全合规却被拒(rc=$rc)"
  [[ -e "$M" ]] \
    && ok "[$nm] 摘要过关之后才执行它读版本(版本判据没有被架空)" \
    || bad "[$nm] 根本没读版本 —— 版本这一关被跳过了"

  # ── 3. 摘要相符但期望版本不同: 仍须拒绝(不能因为内容对了就免掉版本) ──────
  rm -f "$M"; rc="$(callpred "$fn" v8.8.8 "$PIN" "$B")"
  [[ "$rc" != 0 ]] \
    && ok "[$nm] 摘要对、版本不对 → 仍然拒绝" \
    || bad "[$nm] 内容对上就不看版本了 —— 钉值表贴错行时没有第二道门"

  # ── 4. 版本必须精确相等, 不是子串 ──────────────────────────────────────
  rm -f "$M"; mkprobe "$B" v1.19.10 "$M"; PIN2="$(sha256sum "$B" | cut -d' ' -f1)"
  rc="$(callpred "$fn" v1.19.1 "$PIN2" "$B")"
  [[ "$rc" != 0 ]] \
    && ok "[$nm] v1.19.10 不冒充 v1.19.1(精确比较, 没退回子串)" \
    || bad "[$nm] 子串判断回来了 —— 版本进位到两位数时会误判成已是钉死版"

  # ── 5. 不可执行 / 没钉值: 拒绝且不执行 ──────────────────────────────────
  rm -f "$M"; mkprobe "$B" v9.9.9 "$M"; chmod 644 "$B"
  rc="$(callpred "$fn" v9.9.9 "$(sha256sum "$B" | cut -d' ' -f1)" "$B")"
  { [[ "$rc" != 0 ]] && [[ ! -e "$M" ]]; } \
    && ok "[$nm] 文件不可执行 → 拒绝且未执行" || bad "[$nm] 不可执行的文件没被拦住(rc=$rc)"
  chmod 755 "$B"
  rm -f "$M"; rc="$(callpred "$fn" v9.9.9 "" "$B")"
  { [[ "$rc" != 0 ]] && [[ ! -e "$M" ]]; } \
    && ok "[$nm] 该架构没有钉值 → 拒绝且未执行(无从对照时不动手)" \
    || bad "[$nm] 没有钉值也放行/仍然执行了(rc=$rc)"
done

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
