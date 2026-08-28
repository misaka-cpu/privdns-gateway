#!/usr/bin/env bash
# functional-test.sh 必须在**成功路径上也打印 mihomo 的输出**。
#
# 以前只有失败路径 cat 它, 而 cleanup 又 `rm -rf "$WORK"` 把整个工作目录删掉 —— 于是所有
# 绿的 run 里根本拿不到 mihomo 日志。HANDOFF §9.12 那个坑就是这么来的: 真出事时只能拿红
# run 去猜"正常的时候它是什么样", 而那正是最需要对照的东西。
#
# (本轮就撞过一次现成的例子: PR #40 的 functional 抖动, 错因 `Start Redir server error:
#  operation not permitted` 只在红 run 里看得到 —— 要判断它是不是常态, 得有绿 run 的日志比。)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){   echo "[OK]   $1"; pass=$((pass+1)); }
bad(){  echo "[FAIL] $1"; nfail=$((nfail+1)); }
F="$ROOT/tests/functional-test.sh"

# 真跑 dump_mihomo(抽函数, 不跑整支 —— 那要真起 mihomo)
mkclosure(){
  local c="$WORK/c.sh"
  { echo 'set -uo pipefail'
    sed -n '/^dump_mihomo()/,/^}/p' "$F"
  } > "$c"
  bash -n "$c" || { bad "抽不出 dump_mihomo 或语法坏了 —— 后面所有断言都不作数"; echo "通过 $pass, 失败 $nfail"; exit 1; }
  printf '%s' "$c"
}
C="$(mkclosure)"
run(){
  ( set +e
    WORK="$1"; _MH_DUMPED="${2:-0}"; export WORK
    # shellcheck source=/dev/null
    source "$C"
    dump_mihomo ) 2>&1
}

echo "══ 1. 有日志就打出来 ══"
B="$WORK/b1"; mkdir -p "$B"; printf 'line-A\nline-B\n' > "$B/mh.out"
out="$(run "$B")"
grep -q 'line-A' <<<"$out" && grep -q 'line-B' <<<"$out" \
  && ok "日志内容被打出来了" || bad "没打出内容: $(head -c 120 <<<"$out")"
grep -q 'mihomo 输出' <<<"$out" && ok "带了可辨认的分隔头" || bad "没有分隔头"

echo
echo "══ 2. 幂等: 失败路径已经打过就不再重复 ══"
out2="$(run "$B" 1)"
[[ -z "$out2" ]] && ok "_MH_DUMPED=1 时不重复打印" || bad "重复打印了: $(head -c 80 <<<"$out2")"

echo
echo "══ 3. 没有日志时安静退出(不打空的分隔头)══"
B2="$WORK/b2"; mkdir -p "$B2"; : > "$B2/mh.out"
out3="$(run "$B2")"
[[ -z "$out3" ]] && ok "空日志时什么都不打" || bad "空日志也打了: $(head -c 80 <<<"$out3")"
B3="$WORK/b3"; mkdir -p "$B3"
out4="$(run "$B3")"
[[ -z "$out4" ]] && ok "日志文件不存在时什么都不打" || bad "无文件也打了"

echo
echo "══ 4. 超长日志截断, 而且**说清楚截断了** ══"
# 不说就是在撒谎: 读的人以为看到的是全部, 于是"日志里没有那条错误"成了一个错误的结论。
B4="$WORK/b4"; mkdir -p "$B4"
for i in $(seq 1 500); do echo "L$i"; done > "$B4/mh.out"
out5="$(run "$B4")"
grep -q 'L500' <<<"$out5" && ok "保留了最后几行(最新的那部分)" || bad "尾部丢了"
grep -q 'L1$' <<<"$out5" && bad "500 行全打了 —— 没截断" || ok "超长时确实截断了"
grep -qE '共 500 行' <<<"$out5" && ok "把真实总行数说出来了" || bad "没说总行数"
grep -q '只显示最后' <<<"$out5" && ok "明说了这是截断过的" || bad "截断了却不说 —— 读的人会以为看到了全部"

echo
echo "══ 5. cleanup 里必须调它(否则成功路径还是拿不到)══"
body="$(sed -n '/^cleanup()/,/^}/p' "$F")"
grep -q 'dump_mihomo' <<<"$body" \
  && ok "cleanup 调了 dump_mihomo(成功/失败/中断三条路都覆盖)" \
  || bad "cleanup 没调 —— 成功路径依旧拿不到日志"
# 顺序要紧: 必须在 rm -rf 之前
if grep -q 'dump_mihomo' <<<"$body"; then
  d="$(grep -n 'dump_mihomo' <<<"$body" | head -1 | cut -d: -f1)"
  r="$(grep -n 'rm -rf' <<<"$body" | head -1 | cut -d: -f1)"
  { [[ -n "$d" && -n "$r" ]] && (( d < r )); } \
    && ok "dump 在 rm -rf 之前(晚一步日志就已经被删了)" || bad "dump 排在 rm -rf 之后(d=$d r=$r)"
fi

echo
echo "══ 6. 失败路径不许再有裸 cat(两条路必须同一个入口)══"
# 两个入口就会漂: 一处改了格式/截断策略, 另一处还是老样子。
grep -nE 'cat "\$WORK/mh\.out"' "$F" | sed 's/^/    /' >&2
grep -qE 'cat "\$WORK/mh\.out"' "$F" \
  && bad "还有裸 cat mh.out —— 应统一走 dump_mihomo" || ok "失败路径也走 dump_mihomo"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail > 0 ? 1 : 0 ))
