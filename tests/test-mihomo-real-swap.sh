#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实换核: 前像 v1.19.29 → 钉死版 v1.19.30, 走**真的** _update_core_binary。
#
# 为什么不能用桩糊过去: 换核路径上唯一有意义的断言是"落盘的那个文件等于官方钉值",
# 而放一个自报目标版本的桩, 短路判据当场返回 0 —— 整条路径根本不会被执行, 测试却是绿的。
# 所以这里: 目标二进制是**真的** v1.19.30(tests/.bin/mihomo, 由 prepare-mihomo.sh 按
# lib/versions.sh 的 SHA256 下载并校验, 每个 CI run 只下一次, 本测试**不新增公网下载**),
# 取件由本地桩喂那份真二进制, 内容钉值取**真的** lib/versions.sh。
#
# 容器/真 systemd 那一层不在这里: systemctl 由桩模拟(与 test-core-swap.sh 同一套)。
# 本支验的是"取件→双重校验→落盘→配置检查→稳定判定→失败逐字节还原"这条链。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-mihswap.XXXXXX")"
[[ -n "${PDG_KEEP_TMP:-}" ]] || trap 'rm -rf "$WORK"' EXIT
[[ -n "${PDG_KEEP_TMP:-}" ]] && echo "[i] 保留现场: $WORK"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh"

REAL="${PDG_TEST_MIHOMO:-$ROOT/tests/.bin/mihomo}"
if [[ ! -x "$REAL" ]]; then
  if [[ -n "${PDG_TEST_STRICT:-}${CI:-}" ]]; then
    bad "拿不到钉死版 mihomo —— 严格模式下这是失败, 不是跳过。备一份: bash tests/prepare-mihomo.sh"
    echo "通过 $pass, 失败 $nfail"; exit 1
  fi
  echo "[SKIP] 没有钉死版 mihomo(bash tests/prepare-mihomo.sh 可备好) —— 这是未验, 不是通过"; exit 0
fi
MARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
PIN_BIN="${PDG_SHA256[mihomo-bin-$MARCH]:-}"
[[ -n "$PIN_BIN" ]] || { bad "lib/versions.sh 里没有 [mihomo-bin-$MARCH]"; echo "通过 $pass, 失败 $nfail"; exit 1; }
[[ "$(sha256sum "$REAL" | cut -d' ' -f1)" == "$PIN_BIN" ]] \
  && ok "前提: tests/.bin/mihomo 就是钉死版(内容 == [mihomo-bin-$MARCH])" \
  || { bad "tests/.bin/mihomo 与钉值不符 —— 夹具本身不可信, 后面的断言都不算数"; echo "通过 $pass, 失败 $nfail"; exit 1; }

xt(){ sed -n "/^$1(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"; }
BIN="$WORK/bin"; CFG="$WORK/etc-mihomo"; mkdir -p "$BIN" "$CFG" "$WORK/shadow"
# 一份真 mihomo 认的最小配置(配置检查那一步跑的是**真内核**)
cat > "$CFG/config.yaml" <<'Y'
mixed-port: 17899
mode: rule
log-level: silent
external-controller: ''
rules:
  - MATCH,DIRECT
Y
printf 'BROKEN: [[[\n' > "$CFG/broken.yaml"
# PATH 影子: 自报目标版本、内容完全无关。它**不得**影响任何判定。
printf '#!/bin/sh\ncase "$1" in -v) echo "Mihomo Meta v1.19.30 linux amd64";; -t) exit 0;; esac\nexit 0\n' \
  > "$WORK/shadow/mihomo"; chmod 755 "$WORK/shadow/mihomo"
# 前像: 自报 v1.19.29 的旧核(内容与钉值无关) —— 短路判据必须因此**不**短路
mkold(){ printf '#!/bin/sh\n# OLD-v1.19.29\ncase "$1" in -v) echo "Mihomo Meta v1.19.29 linux amd64";; esac\nexit 0\n' > "$BIN/mihomo"; chmod 755 "$BIN/mihomo"; }
mkold; OLD_SHA="$(sha256sum "$BIN/mihomo" | cut -d' ' -f1)"; chmod 755 "$BIN/mihomo"
OLD_MODE="$(stat -c%a "$BIN/mihomo")"; OLD_OWN="$(stat -c%u:%g "$BIN/mihomo")"

# 取件桩: 把**真** mihomo 重新 gzip 成"下载物"。归档钉值随之算出来注入临时 versions.sh;
# 二进制钉值用**真的**那一份 —— 决定性断言("落盘内容 == 官方钉值")因此没有被稀释。
gzip -nc "$REAL" > "$WORK/m.gz"
ARCH_SHA="$(sha256sum "$WORK/m.gz" | cut -d' ' -f1)"
mkdir -p "$WORK/repo/lib"
{ echo "MIHOMO_VER=\"$MIHOMO_VER\""
  echo "declare -A PDG_SHA256=( [mihomo-$MARCH]=\"$ARCH_SHA\" [mihomo-bin-$MARCH]=\"$PIN_BIN\" )"
  sed -n '/^pdg_mihomo_version(){/,/^}/p'   "$ROOT/lib/versions.sh"
  sed -n '/^pdg_mihomo_is_version(){/,/^}/p' "$ROOT/lib/versions.sh"
  sed -n '/^pdg_mihomo_binary_ok(){/,/^}/p' "$ROOT/lib/versions.sh"
  sed -n '/^pdg_verify_sha256(){/,/^}/p'    "$ROOT/lib/versions.sh"
} > "$WORK/repo/lib/versions.sh"

# 夹具落盘再 source。**不能**把抽出来的函数塞进 bash -c 的单引号串 —— _core_listeners
# 与 _pdg_sha 里本身就有单引号(awk '...' / cut -d' '), 会当场撑破外层引号变成语法错。
# 第一版就是这么写的: bash -c 直接 rc=2 什么都没跑, 而"旧核没被动"那几条断言照样报绿 ——
# 又一格假绿。所以每一格现在都要先确认夹具**真的执行过**, 再谈还原。
# ⚠️ 顺序要紧: **先抽生产函数, 后写桩**。
# xt 用 `/^NAME(){/,/^}/` 抽取, 而 _core_bindir 在 pdg.sh 里是**单行函数** —— 它那一行没有
# 独立的 `}` 收尾, sed 的结束锚点于是跑到**下一个**函数的末尾, 把真的 _core_config_check
# (里面写死 /etc/mihomo)一起抽了进来。桩若写在前面就会被它覆盖, 表现是"真内核说配置不兼容"。
: > "$WORK/h.sh"
for f in _core_bindir _pdg_sha _core_stash_kernel _core_restore_prev _core_kernel_stable \
         _core_listeners _core_swap_verify _update_core_binary; do
  xt "$f" >> "$WORK/h.sh"
done
{
  echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; sleep(){ :; }'
  echo "curl(){ local o=\"\"; while [[ \$# -gt 0 ]]; do [[ \"\$1\" == -o ]] && { o=\"\$2\"; shift; }; shift; done; cp '$WORK/m.gz' \"\$o\"; }"
  echo "_core_config_check(){ \"\$2/mihomo\" -t -d '$CFG' -f \"$CFG/\$CFGF\" > '$WORK/cfgchk.log' 2>&1; }"
  echo "systemctl(){ if [[ \"\$1\" == is-active ]]; then"
  echo "               if grep -q OLD-v1.19.29 '$BIN/mihomo' 2>/dev/null; then echo active; else echo \"\$NEWACT\"; fi"
  echo "             elif [[ \"\$1\" == show ]]; then echo 0; fi; return 0; }"
} >> "$WORK/h.sh"
echo 'HARNESS_OK=1' >> "$WORK/h.sh"
bash -n "$WORK/h.sh" 2>/dev/null && ok "夹具可解析(函数抽取没被引号撑破)" \
  || bad "夹具本身语法错 —— 后面所有断言都不算数"

run(){ # $1=配置检查用哪份(config.yaml|broken.yaml) $2=新核起来后稳不稳(active|failed)
  : > "$WORK/log"
  # 用显式 env 而不是前缀赋值: 前缀里出现 WORK="$WORK" 时 shellcheck 会判 SC2097/SC2098
  # (它看不出右边的 $WORK 是父进程的值), 而 CI 的 lint 是 --severity=warning, 会红。
  env PATH="$WORK/shadow:$PATH" REPO_DIR="$WORK/repo" PDG_CORE_BINDIR="$BIN" \
      CFGF="$1" NEWACT="$2" WORK="$WORK" \
      bash -c "source '$WORK/h.sh'; [[ \"\${HARNESS_OK:-}\" == 1 ]] || exit 90; _update_core_binary" \
      > "$WORK/log" 2>&1
  echo $?
}
ran(){ [[ "$1" != 90 && "$1" != 2 && "$1" != 127 ]]; }   # 夹具自己没炸

echo
echo "══ 1. 成功换核: 前像 v1.19.29 → 钉死版 $MIHOMO_VER ══"
mkold; rc=$(run config.yaml active)
NEW_SHA="$(sha256sum "$BIN/mihomo" | cut -d' ' -f1)"
[[ "$rc" == 0 ]] && ok "返回 0" || bad "返回 $rc: $(tail -2 "$WORK/log" | tr '\n' ' ')"
[[ "$NEW_SHA" == "$PIN_BIN" ]] && ok "落盘内容 **== 官方钉值** ${PIN_BIN:0:12}…" || bad "落盘 ${NEW_SHA:0:12}… != 钉值 ${PIN_BIN:0:12}…"
[[ "$("$BIN/mihomo" -v 2>/dev/null | head -1)" == *"$MIHOMO_VER"* ]] \
  && ok "绝对路径上的版本变成 $MIHOMO_VER" || bad "版本没换过来"
compgen -G "$BIN/.mihomo.pdg-prev.*" >/dev/null && bad "旧核备份残留(应在确认可用后删掉)" || ok "旧核备份已清理"
grep -q '已装并重启' "$WORK/log" && ok "报了已装并重启" || bad "没报已装并重启"

echo
echo "══ 2. PATH 影子不得影响结果 ══"
# 影子自报的正是目标版本。若判据还问 PATH, 上面那次就会被短路成"已是最新", 根本不会换。
grep -q '更新 mihomo 内核' "$WORK/log" \
  && ok "尽管 PATH 上有自报 $MIHOMO_VER 的影子, 仍然真的走了取件换核" \
  || bad "被 PATH 影子短路了 —— 判据还在问 PATH"

echo
echo "══ 3. 新核配置检查失败 → 逐字节还原旧核 ══"
mkold; rc=$(run broken.yaml active)
ran "$rc" && ok "夹具确实执行了(rc=$rc)" || bad "夹具没能执行(rc=$rc) —— 这一节**未验**, 下面的还原断言不算数"
grep -q '更新 mihomo 内核' "$WORK/log" && ok "确实进了换核路径" || bad "根本没进换核路径"
[[ "$rc" != 0 ]] && ok "返回非 0(rc=$rc)" || bad "配置检查失败却返回 0"
[[ "$(sha256sum "$BIN/mihomo" | cut -d' ' -f1)" == "$OLD_SHA" ]] && ok "旧核内容逐字节还原" || bad "旧核内容没还原"
[[ "$(stat -c%a "$BIN/mihomo")" == "$OLD_MODE" ]] && ok "旧核 mode 还原($OLD_MODE)" || bad "mode 变了"
[[ "$(stat -c%u:%g "$BIN/mihomo")" == "$OLD_OWN" ]] && ok "旧核属主还原" || bad "属主变了"
compgen -G "$BIN/.mihomo.pdg-prev.*" >/dev/null && bad "留下了 .prev 半套状态" || ok "无 .prev 残留"
grep -q '已装并重启' "$WORK/log" && bad "失败却报了成功文案" || ok "没有错误的成功文案"

echo
echo "══ 4. 新核起来后不稳定 → 同样完整还原 ══"
mkold; rc=$(run config.yaml failed)
ran "$rc" && ok "夹具确实执行了(rc=$rc)" || bad "夹具没能执行(rc=$rc) —— 这一节**未验**, 下面的还原断言不算数"
grep -q '更新 mihomo 内核' "$WORK/log" && ok "确实进了换核路径" || bad "根本没进换核路径"
[[ "$rc" != 0 ]] && ok "返回非 0(rc=$rc)" || bad "不稳定却返回 0"
[[ "$(sha256sum "$BIN/mihomo" | cut -d' ' -f1)" == "$OLD_SHA" ]] && ok "旧核内容逐字节还原" || bad "旧核内容没还原"
compgen -G "$BIN/.mihomo.pdg-prev.*" >/dev/null && bad "留下了 .prev 半套状态" || ok "无 .prev 残留"
grep -q '已装并重启' "$WORK/log" && bad "失败却报了成功文案" || ok "没有错误的成功文案"

echo
echo "══ 5. 已是钉死版时短路(且是按**内容**短路, 不是按自报版本) ══"
install -m755 "$REAL" "$BIN/mihomo"
: > "$WORK/log"; rc=$(run config.yaml active)
{ [[ "$rc" == 0 ]] && ! grep -q '更新 mihomo 内核' "$WORK/log"; } \
  && ok "内容已等于钉值 → 短路, 不取件" || bad "已是钉死版却仍然取件(rc=$rc)"
printf '\n# tampered\n' >> "$BIN/mihomo"      # 版本仍自报 v1.19.30, 内容变了
: > "$WORK/log"; rc=$(run config.yaml active)
{ [[ "$rc" == 0 ]] && grep -q '更新 mihomo 内核' "$WORK/log" \
  && [[ "$(sha256sum "$BIN/mihomo" | cut -d' ' -f1)" == "$PIN_BIN" ]]; } \
  && ok "自报版本仍对但内容被改 → **不短路**, 重下并修回钉值" \
  || bad "内容漂移被当成已是最新跳过了(rc=$rc) —— 只比版本的老毛病回来了"

echo
echo "══ 6. 归档校验过了、解压产物却不是钉值 → 落盘**之前**就要拦住 ══"
# 这一格是"落盘前二次核验"唯一的牙齿。上面几格里归档与二进制天然一致(归档就是那个二进制
# 压出来的), 所以把落盘前那道校验整个删掉, 它们照样绿 —— 负控当场揭穿过。
# 这里造一个**内容不同但归档钉值对得上**的下载物: 归档那关会过, 只有二进制那关能拦。
printf '#!/bin/sh\n# IMPOSTOR\ncase "$1" in -v) echo "Mihomo Meta %s linux amd64";; -t) exit 0;; esac\nexit 0\n' \
  "$MIHOMO_VER" > "$WORK/impostor"; chmod 755 "$WORK/impostor"
gzip -nc "$WORK/impostor" > "$WORK/m.gz"
IMP_ARCH_SHA="$(sha256sum "$WORK/m.gz" | cut -d' ' -f1)"
{ echo "MIHOMO_VER=\"$MIHOMO_VER\""
  echo "declare -A PDG_SHA256=( [mihomo-$MARCH]=\"$IMP_ARCH_SHA\" [mihomo-bin-$MARCH]=\"$PIN_BIN\" )"
  sed -n '/^pdg_mihomo_version(){/,/^}/p'    "$ROOT/lib/versions.sh"
  sed -n '/^pdg_mihomo_is_version(){/,/^}/p' "$ROOT/lib/versions.sh"
  sed -n '/^pdg_mihomo_binary_ok(){/,/^}/p'  "$ROOT/lib/versions.sh"
  sed -n '/^pdg_verify_sha256(){/,/^}/p'     "$ROOT/lib/versions.sh"
} > "$WORK/repo/lib/versions.sh"
mkold; OLD2="$(sha256sum "$BIN/mihomo" | cut -d' ' -f1)"
rc=$(run config.yaml active)
[[ "$rc" != 0 ]] && ok "归档过、二进制不符 → 返回非 0(rc=$rc)" || bad "冒牌二进制被放行了"
[[ "$(sha256sum "$BIN/mihomo" | cut -d' ' -f1)" == "$OLD2" ]] \
  && ok "冒牌二进制**从未落盘**(旧核逐字节未动)" || bad "冒牌二进制已经写进 /usr/local/bin 了"
grep -qE '内容与钉值不符|二进制' "$WORK/log" && ok "报错点明是二进制内容不符" \
  || bad "报错没点明是哪一层: $(tail -2 "$WORK/log" | tr '\n' ' ')"

echo "────────────────────────────────────────"
echo "$(basename "$0"): 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
