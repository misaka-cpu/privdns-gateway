#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 规则计数只做**局部** ASCII 优化: LC_ALL=C 只挂在 _adb_count_rules 那一次 grep 上。
#
# 由来: 二十多万条的第三方表上, UTF-8 locale 里 `grep -vcE '^[[:space:]]*(#|$)'` 要为每个
# 字节做多字节解码, 而规则文件的内容契约是**纯 ASCII**(adblock.py 的 _DOMAIN_RE 只放行
# [a-z0-9_-] 与点)。那笔解码开销是白花的。
#
# 但"快"不是这一支要钉的东西 —— 时间阈值会随机器和 grep 版本抖, 钉在 CI 里只会变成一条
# 定期误报的判据。这里钉的是**语义**: 同一份输入, C 与 UTF-8 两种 locale 下必须数出同一个
# 数; 以及优化没有偷偷换掉计数口径(不缓存、不改格式、不拿 meta.json 冒充盘上真实条数)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-adbloc.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

SRC="$ROOT/deploy/bot/pdg.sh"
sed -n '/^_adb_count_rules(){/,/^}/p' "$SRC" > "$WORK/cnt.sh"

echo "══ 1. 优化是局部的 ══"
if grep -q "LC_ALL=C grep" "$WORK/cnt.sh"; then
  ok "_adb_count_rules 的 grep 前挂了 LC_ALL=C"
else
  bad "_adb_count_rules 的 grep 没有 LC_ALL=C"
fi
# 要禁的是**赋值/导出**(它会改掉后面所有命令), 不是命令前缀 `LC_ALL=C <cmd>`(只影响那一条)。
# 第一版正则把 `LC_ALL=C sort -u …` 这种前缀也算进去了 —— 那是 pdg.sh 里早就有的同一个
# 惯用法, 判它红等于禁掉正确写法。判据要看 `LC_ALL=…` 后面还有没有命令。
if grep -qE '^[[:space:]]*(export[[:space:]]+LC_ALL=|LC_ALL=[^[:space:]]*[[:space:]]*$)' "$SRC"; then
  bad "pdg.sh 里出现了全局 LC_ALL 赋值/导出 —— 那会改掉整个脚本里所有命令的 locale"
else
  ok "没有全局 LC_ALL 赋值/导出(只有命令前缀形式, 影响范围就是那一条命令)"
fi
# 计数口径不许被换成别的来源
# 只扫**代码**: 注释里提到 meta.json 是在说明"不拿它冒充", 不是在用它。
sed 's/#.*//' "$WORK/cnt.sh" > "$WORK/cnt.code"
if grep -qE 'meta\.json|_ADB_COUNT_CACHE|cache' "$WORK/cnt.code"; then
  bad "计数函数里出现了缓存/meta.json —— 盘上到底有多少条必须只有一个答案"
else
  ok "没有引入计数缓存, 也没拿 meta.json 冒充盘上条数"
fi

echo
echo "══ 2. 输入契约确实是 ASCII ══"
# 优化成立的前提。契约不在这里, 优化就不成立 —— 所以先证明它。
if grep -qE '_DOMAIN_RE = re\.compile\(r"\^\(\?=\.\{1,253\}\$\)\[a-z0-9_\]' "$ROOT/deploy/bot/adblock.py"; then
  ok "adblock.py 的 _DOMAIN_RE 只放行 ASCII 字符类(落盘的每一条都过它)"
else
  bad "找不到 ASCII 字符集契约 —— 没有它, LC_ALL=C 这一步就没有依据"
fi

echo
echo "══ 3. 双 locale 对拍: 同一份输入必须数出同一个数 ══"
# 可用的 UTF-8 locale。一个都没有就说清楚"这一格没验到", 不冒充通过。
UTF=""
for c in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
  if LC_ALL="$c" true 2>/dev/null && LC_ALL="$c" locale charmap 2>/dev/null | grep -qi utf; then UTF="$c"; break; fi
done

mk(){ printf '%b' "$2" > "$WORK/$1"; }
mk plain        'a.example\nb.example\n'
mk comments     '# head\n\na.example\n   # indented comment\n\nb.example\n'
mk leading_ws   '  a.example\n\t b.example\n'
mk crlf         'a.example\r\nb.example\r\n'
mk no_final_nl  'a.example\nb.example'
mk only_comment '# just a comment\n'
mk empty        ''
mk hash_inside  'a.example\nb.example#notacomment\n'
: > "$WORK/big"
{ echo '# comment'; echo; for i in $(seq 1 20000); do echo "x$i.example.com"; done; } > "$WORK/big"

count_with(){ LC_ALL="$1" bash -c "source '$WORK/cnt.sh'; _adb_count_rules '$2'"; }

# 期望值写死: 这一格同时是"计数口径没被优化改掉"的正控
declare -A WANT=( [plain]=2 [comments]=2 [leading_ws]=2 [crlf]=2 [no_final_nl]=2
                  [only_comment]=0 [empty]=0 [hash_inside]=2 [big]=20000 )
for f in plain comments leading_ws crlf no_final_nl only_comment empty hash_inside big; do
  c=$(count_with C "$WORK/$f")
  if [[ "$c" == "${WANT[$f]}" ]]; then ok "计数口径不变 [$f] = ${WANT[$f]}"
  else bad "计数口径变了 [$f]: 期望 ${WANT[$f]}, 实得 $c"; fi
  if [[ -n "$UTF" ]]; then
    u=$(count_with "$UTF" "$WORK/$f")
    if [[ "$c" == "$u" ]]; then ok "双 locale 一致 [$f]: C=$c $UTF=$u"
    else bad "双 locale 不一致 [$f]: C=$c $UTF=$u —— 这个模式依赖了 locale"; fi
  fi
done
if [[ -z "$UTF" ]]; then
  bad "本机没有可用的 UTF-8 locale —— 对拍那一半没验到(不是通过)。装一个 en_US.UTF-8 再跑。"
else
  ok "对拍用的 UTF-8 locale: $UTF"
fi

echo
echo "══ 4. 缺文件 / 不是文件 仍然走既有分支, 不受 locale 影响 ══"
for L in C ${UTF:-C}; do
  c=$(count_with "$L" "$WORK/no-such-file")
  [[ "$c" == 0 ]] && ok "[$L] 缺文件 → 0(既有语义)" || bad "[$L] 缺文件实得 $c"
done
# `grep -c` 数到 0 时**退出码是 1**。以前这里跟着一个 `|| echo 0`, 于是输出变成两行 "0"
# (状态页上就是那两行 0)。这一格钉住它不会回来。
out=$(count_with C "$WORK/only_comment")
[[ "$out" == "0" && "$(printf '%s' "$out" | wc -l)" == 0 ]] \
  && ok "全是注释 → 单个 0, 不是两行(grep -c 返回 1 那个老坑)" \
  || bad "实得 %q: $(printf '%q' "$out")"

echo "────────────────────────────────────────"
echo "test-adblock-count-locale.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
