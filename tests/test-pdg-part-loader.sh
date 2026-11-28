#!/usr/bin/env bash
# pdg.sh 拆分段的载入器(建议 4 第一步): _pdg_part 去哪找段, 缺段 / 坏段时怎么表现。
#
# 一、抽出 _pdg_part 与 _pdg_part_missing, 替掉 _pdg_entry_src, 三种入口形态与每种坏法逐条验:
#     退出码、给出的路径、提示里要有段名 / 应在的位置 / 不依赖 pdg 的修补命令。
# 二、在临时树里真跑整份入口(走分派的默认分支 __probe, 只打印用法, 不要 root、不碰系统):
#     段在 → 打印用法、返回 0; 段缺 / 截断成语法错误 → 提示、返回 1、不进分派;
#     截断在两个函数之间 / 换成别的版本 → 能载入(内容配不配套交给安装清单, 见 STEP1.md 3.3)。
# 三、拼回的整份(tests/pdg_source.py)本身是能独立运行的完整脚本; 段里的常量在入口载入后就有。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENTRY="$ROOT/deploy/bot/pdg.sh"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-part-loader.XXXXXX")" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "══ 一、_pdg_part 的找段规则(抽出函数) ══"
for fn in _pdg_part _pdg_part_missing; do sed -n "/^$fn(){/,/^}/p" "$ENTRY"; done > "$WORK/fn.sh"
if [[ "$(grep -c '^_pdg_part(){' "$WORK/fn.sh")" == 1 && "$(grep -c '^_pdg_part_missing(){' "$WORK/fn.sh")" == 1 ]]; then
  ok "从入口抽到 _pdg_part 与 _pdg_part_missing(测的是生产代码本身)"
else
  bad "入口里抽不到载入器的两个函数"; echo; echo "通过 $pass, 失败 $nfail"; exit 1
fi
# $1=伪造的入口路径 → 输出 "rc|stdout", stderr 落到 $WORK/err
probe(){
  local rc=0 out
  out="$(FAKE_SRC="$1" PARTS="$WORK/parts" FN="$WORK/fn.sh" bash -c '
    set -u
    _PDG_INSTALLED_CLI=/usr/local/bin/pdg; _PDG_PART_DIR="$PARTS"; REPO_DIR=/opt/privdns-gateway
    _pdg_entry_src(){ printf "%s\n" "$FAKE_SRC"; }
    source "$FN"; _pdg_part adblock' 2>"$WORK/err")" || rc=$?
  printf '%s|%s' "$rc" "$out"
}
mkdir -p "$WORK/parts" "$WORK/tree/deploy/bot" "$WORK/tree/lib/pdg"
printf 'x(){ :; }\n' > "$WORK/parts/pdg-adblock.sh"
r="$(probe /usr/local/bin/pdg)"
[[ "$r" == "0|$WORK/parts/pdg-adblock.sh" && ! -s "$WORK/err" ]] \
  && ok "已安装形态: 给出 \$_PDG_PART_DIR/pdg-adblock.sh, 不出声" || bad "已安装形态: 实得 $r / $(head -c 160 "$WORK/err")"
rm -f "$WORK/parts/pdg-adblock.sh"
r="$(probe /usr/local/bin/pdg)"; e="$(cat "$WORK/err")"
if [[ "$r" == "1|" && "$e" == *"「adblock」"* && "$e" == *"$WORK/parts/pdg-adblock.sh(不存在)"* \
      && "$e" == *"sudo install -m644 /opt/privdns-gateway/lib/pdg/adblock.sh $WORK/parts/pdg-adblock.sh"* \
      && "$e" == *"pdg update、pdg rollback、覆盖重装都跑不起来"* && "$e" == *"sudo pdg doctor"* ]]; then
  ok "已安装形态缺段: 返回 1、不给路径; 提示里有段名、应在的位置、不依赖 pdg 的修补命令、事后核对办法"
else
  bad "已安装形态缺段: 实得 $r / $e"
fi
: > "$WORK/parts/pdg-adblock.sh"
r="$(probe /usr/local/bin/pdg)"
[[ "$r" == "1|" ]] && grep -q '(是空文件)' "$WORK/err" && ok "空文件当缺段: 返回 1, 提示「是空文件」" || bad "空文件: 实得 $r / $(head -c 160 "$WORK/err")"
rm -f "$WORK/parts/pdg-adblock.sh"; mkdir "$WORK/parts/pdg-adblock.sh"
r="$(probe /usr/local/bin/pdg)"
[[ "$r" == "1|" ]] && grep -q '(不是普通文件)' "$WORK/err" && ok "是个目录: 返回 1, 提示「不是普通文件」" || bad "目录: 实得 $r / $(head -c 160 "$WORK/err")"
rmdir "$WORK/parts/pdg-adblock.sh"
if [[ "$(id -u)" != 0 ]]; then
  printf 'x(){ :; }\n' > "$WORK/parts/pdg-adblock.sh"; chmod 000 "$WORK/parts/pdg-adblock.sh"
  r="$(probe /usr/local/bin/pdg)"
  [[ "$r" == "1|" ]] && grep -q '(读不了)' "$WORK/err" && ok "读不了: 返回 1, 提示「读不了」" || bad "读不了: 实得 $r / $(head -c 160 "$WORK/err")"
  chmod 644 "$WORK/parts/pdg-adblock.sh"; rm -f "$WORK/parts/pdg-adblock.sh"
else
  echo "[NOTE] 以 root 运行, 权限挡不住读, 「读不了」那一格不验"
fi
printf 'y(){ :; }\n' > "$WORK/tree/lib/pdg/adblock.sh"
r="$(probe "$WORK/tree/deploy/bot/pdg.sh")"
[[ "$r" == "0|$WORK/tree/lib/pdg/adblock.sh" && ! -s "$WORK/err" ]] \
  && ok "树内形态: 给出同一棵树的 lib/pdg/adblock.sh(不碰 \$_PDG_PART_DIR)" || bad "树内形态: 实得 $r"
rm -f "$WORK/tree/lib/pdg/adblock.sh"
r="$(probe "$WORK/tree/deploy/bot/pdg.sh")"
[[ "$r" == "1|" ]] && grep -q "这棵树不完整" "$WORK/err" && grep -qF "$WORK/tree/lib/pdg/adblock.sh(不存在)" "$WORK/err" \
  && ok "树内形态缺段: 返回 1, 说清是这棵树不完整、缺哪个文件" || bad "树内形态缺段: 实得 $r / $(head -c 160 "$WORK/err")"
printf 'x(){ :; }\n' > "$WORK/parts/pdg-adblock.sh"   # 已安装那份在, 也不许拿来顶
for src in "$WORK/elsewhere/pdg.sh" "(未知)" "$WORK/tree/deploy/pdg.sh"; do
  r="$(probe "$src")"
  [[ "$r" == "1|" ]] && grep -q "认不出配套的段在哪" "$WORK/err" && grep -q "install.sh" "$WORK/err" \
    && ok "认不出的形态($src): 返回 1, 不回退到已安装的那份" || bad "认不出的形态($src): 实得 $r / $(head -c 160 "$WORK/err")"
done

echo
echo "══ 二、真跑整份入口(临时树, __probe 走默认分支) ══"
T="$WORK/real"; mkdir -p "$T/deploy/bot" "$T/lib/pdg"
cp "$ENTRY" "$T/deploy/bot/pdg.sh"
cp "$ROOT"/lib/pdg/*.sh "$T/lib/pdg/" 2>/dev/null
n_parts="$(find "$T/lib/pdg" -name '*.sh' | wc -l)"
(( n_parts >= 1 )) && ok "临时树里放了 $n_parts 个段" || bad "lib/pdg/ 下一个段都没有"
run_entry(){ local rc=0; bash "$T/deploy/bot/pdg.sh" "$@" > "$WORK/out" 2> "$WORK/err" || rc=$?; echo "$rc"; }
rc="$(run_entry __probe)"
[[ "$rc" == 0 ]] && grep -q '^用法: pdg ' "$WORK/out" && [[ ! -s "$WORK/err" ]] \
  && ok "段齐: 打印用法、返回 0、stderr 为空" || bad "段齐: rc=$rc / $(head -c 160 "$WORK/err")"
rc="$(bash -c 'source "$1" __probe >/dev/null; printf "%s|%s|%s" "$(declare -F cmd_adblock)" "$(declare -F migrate_adblock)" "$ADB_STATE_DIR"' _ "$T/deploy/bot/pdg.sh" 2>"$WORK/err")"
[[ "$rc" == "cmd_adblock|migrate_adblock|/var/lib/privdns-gateway/adblock" ]] \
  && ok "载入后段里的函数与常量都在(cmd_adblock、migrate_adblock、ADB_STATE_DIR)" || bad "载入后缺东西: $rc"
cp "$T/lib/pdg/adblock.sh" "$WORK/adblock.good"
rm -f "$T/lib/pdg/adblock.sh"
rc="$(run_entry __probe)"
[[ "$rc" == 1 ]] && grep -q '缺少拆出去的一段「adblock」' "$WORK/err" && ! grep -q '^用法' "$WORK/out" \
  && ok "段缺: 返回 1、提示缺段、没进分派" || bad "段缺: rc=$rc / out=$(head -c 60 "$WORK/out") / err=$(head -c 120 "$WORK/err")"
rc="$(run_entry status)"
[[ "$rc" == 1 ]] && grep -q '缺少拆出去的一段「adblock」' "$WORK/err" && [[ ! -s "$WORK/out" ]] \
  && ok "段缺时 status 照旧停在缺段提示上(只有卸载提前分派)" || bad "段缺时 status: rc=$rc / out=$(head -c 60 "$WORK/out") / err=$(head -c 120 "$WORK/err")"
# 卸载不靠段: 段缺时 uninstall / uninstall --purge / rm 照样走到 cmd_uninstall。测试不是 root 时,
# cmd_uninstall 第一步 need_root 就停在「请用 root: sudo pdg uninstall」—— 这正好证明走到了, 也不会
# 真去跑 /opt/privdns-gateway/uninstall.sh。root 下这几格会真的卸载本机, 所以只在非 root 时跑。
if [[ "$(id -u)" != 0 ]]; then
  for argv in "uninstall" "uninstall --purge" "rm"; do
    read -ra a <<<"$argv"
    rc="$(run_entry "${a[@]}")"
    [[ "$rc" == 1 && "$(cat "$WORK/out")" == "请用 root: sudo pdg uninstall" ]] && ! grep -q '缺少拆出去的一段' "$WORK/err" \
      && ok "段缺时 pdg $argv 照样走到卸载(停在要 root 那一步, 没有缺段提示)" \
      || bad "段缺时 pdg $argv: rc=$rc / out=$(head -c 80 "$WORK/out") / err=$(head -c 120 "$WORK/err")"
  done
else
  echo "[NOTE] 以 root 运行: 段缺时的 uninstall 那几格会真的卸载本机, 不跑"
fi
early_re='^case "\$\{1:-\}" in uninstall\|rm\) '
n_early="$(grep -cE "$early_re" "$ENTRY")"
l_early="$(grep -nE "$early_re" "$ENTRY" | head -1 | cut -d: -f1)"
l_mark="$(grep -n -m1 '^# @pdg-part ' "$ENTRY" | cut -d: -f1)"
l_def="$(grep -n -m1 '^cmd_uninstall(){' "$ENTRY" | cut -d: -f1)"
[[ "$n_early" == 1 && -n "$l_mark" && -n "$l_def" ]] && (( l_def < l_early && l_early < l_mark )) \
  && ok "入口里提前分派卸载的那一行恰 1 处, 在 cmd_uninstall 定义之后、第一个段之前(第 $l_def < $l_early < $l_mark 行)" \
  || bad "提前分派卸载的那一行: 共 ${n_early:-0} 处, 行号 定义=${l_def:-?} 分派=${l_early:-?} 第一个段=${l_mark:-?}"
mid="$(grep -n '^cmd_adblock(){' "$WORK/adblock.good" | cut -d: -f1)"
head -n "$((mid + 3))" "$WORK/adblock.good" > "$T/lib/pdg/adblock.sh"
rc="$(run_entry __probe)"
[[ "$rc" == 1 ]] && grep -q '载入 .*adblock.sh 失败' "$WORK/err" && ! grep -q '^用法' "$WORK/out" \
  && ok "段截断成语法错误: 返回 1、提示载入失败、没进分派" || bad "段截断(语法错): rc=$rc / err=$(head -c 160 "$WORK/err")"
cut_at="$(grep -n '^migrate_adblock(){' "$WORK/adblock.good" | cut -d: -f1)"
head -n "$((cut_at - 1))" "$WORK/adblock.good" > "$T/lib/pdg/adblock.sh"
rc="$(bash -c 'source "$1" __probe >/dev/null; declare -F migrate_adblock >/dev/null && echo HAS || echo MISSING' _ "$T/deploy/bot/pdg.sh" 2>"$WORK/err")"
[[ "$rc" == MISSING ]] \
  && ok "段截断在两个函数之间: 能载入, 缺的函数到用时才报错(内容不配套交给安装清单 / doctor)" || bad "截断在函数之间: $rc"
{ cat "$WORK/adblock.good"; printf '_pdg_part_other_version(){ :; }\n'; } > "$T/lib/pdg/adblock.sh"
rc="$(bash -c 'source "$1" __probe >/dev/null; declare -F _pdg_part_other_version >/dev/null && echo LOADED' _ "$T/deploy/bot/pdg.sh" 2>"$WORK/err")"
[[ "$rc" == LOADED ]] && ok "段换成别的版本: 照样载入(版本配不配套由安装清单判, 入口不另比摘要)" || bad "别的版本: $rc"
cp "$WORK/adblock.good" "$T/lib/pdg/adblock.sh"

echo
echo "══ 三、拼回的整份 ══"
REND="$(bash "$ROOT/tests/pdg-source-lib.sh" path "$ROOT")" || REND=""
if [[ -n "$REND" && -f "$REND" ]]; then
  ! grep -q '^# @pdg-part ' "$REND" && ! grep -q '_pdg_part_f=' "$REND" \
    && ok "拼回的整份里没有标记与载入语句" || bad "拼回的整份里还有标记或载入语句"
  rc=0; bash "$REND" __probe > "$WORK/out" 2> "$WORK/err" || rc=$?
  [[ "$rc" == 0 ]] && grep -q '^用法: pdg ' "$WORK/out" && [[ ! -s "$WORK/err" ]] \
    && ok "拼回的整份放在缓存目录里也能独立运行(不去找段)" || bad "拼回的整份独立运行: rc=$rc / $(head -c 160 "$WORK/err")"
else
  bad "取不到拼回的整份"
fi

echo
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail ? 1 : 0 ))
