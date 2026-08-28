#!/usr/bin/env bash
# `pdg adblock status` 的条数在「0 条」时会断成两行。
#
#     用户 allow: 0
#     0 条   用户 block: 0
#     0 条
#
# 根因是 `grep -c … || echo 0`:**`grep -c` 无匹配时既打印 0、又返回退出码 1**, 于是
# `|| echo 0` 又追加一个 0, 得到 "0\n0"。也就是说这个 bug **只在某类规则为 0 条时出现** ——
# 而那正是绝大多数机器的默认状态(没加过自定义规则)。
#
# 这一支同时钉住一件更要紧的事: 这几个数字是**表的大小**, 不是命中次数。文案不许让人以为
# 它是"拦了多少次" —— 本项目没有命中统计(四条实现路径都调查过并否决, 见 HANDOFF)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){   echo "[OK]   $1"; pass=$((pass+1)); }
bad(){  echo "[FAIL] $1"; nfail=$((nfail+1)); }
PDG="$ROOT/deploy/bot/pdg.sh"

echo "══ 0. 先证明这个陷阱真的存在(否则下面几格证明不了什么)══"
: > "$WORK/empty.txt"
n="$(grep -vce '^$|^#' "$WORK/empty.txt" 2>/dev/null || echo 0)"
lines="$(printf '%s' "$n" | grep -c . )"
[[ "$lines" == 2 ]] \
  && ok "\`grep -c … || echo 0\` 在空文件上确实产出两行(实得 $lines 行)" \
  || bad "复现不出这个陷阱, 这一支的前提不成立(实得 $lines 行)"

echo
echo "══ 1. 产品里不许再有这个写法 ══"
body="$(sed -n "/^_adb_count_rules()/,/^}/p;/^_adblock_status()/,/^}/p" "$PDG")"
[[ -n "$body" ]] && ok "抽得到 _adblock_status" || bad "抽不到函数体, 后面不作数"
hits="$(grep -c 'grep -vce[^)]*|| echo 0' <<<"$body" || true)"
[[ "$hits" == 0 ]] \
  && ok "_adblock_status 里没有 \`grep -c … || echo 0\`" \
  || bad "还有 $hits 处 \`grep -c … || echo 0\` —— 0 条时会断行"

echo
echo "══ 2. 真跑一次: 空文件时输出必须是干净的单行 ══"
CL="$WORK/c.sh"
{
  echo 'set -uo pipefail'
  echo 'c_g(){ echo "$*"; }; c_y(){ echo "CY:$*"; }'
  echo '_adblock_intent(){ echo 1; }'
  echo '_pdg_module(){ return 1; }'
  sed -n "/^_adb_count_rules()/,/^}/p;/^_adblock_status()/,/^}/p" "$PDG"
} > "$CL"
bash -n "$CL" || { bad "闭包语法坏了 —— 后面所有断言都不作数"; echo "通过 $pass, 失败 $nfail"; exit 1; }
mkdir -p "$WORK/state"
: > "$WORK/allow.txt"; : > "$WORK/block.txt"
: > "$WORK/state/effective_block.txt"; printf 'a.example\nb.example\n' > "$WORK/state/effective_list.txt"
out="$(
  ADB_STATE_DIR="$WORK/state" ADB_USER_ALLOW="$WORK/allow.txt" ADB_USER_BLOCK="$WORK/block.txt" \
  ACME_HOME="$WORK/acme" PROFILE_ENV="$WORK/p.env" \
  bash -c "source '$CL'; _adblock_status" 2>/dev/null
)"
# 每一行都必须自成一句, 不能出现"孤零零一个数字开头"的行
orphan="$(grep -cE '^[0-9]+ 条' <<<"$out" || true)"
[[ "$orphan" == 0 ]] \
  && ok "没有以裸数字开头的断行(实得 $orphan 行)" \
  || bad "有 $orphan 行是断出来的: $(grep -E '^[0-9]+ 条' <<<"$out" | head -2 | tr '\n' ' ')"
grep -qE '用户 allow: 0 条 +用户 block: 0 条' <<<"$out" \
  && ok "0 条时「用户 allow / block」在同一行且数字正确" \
  || bad "那一行不对: $(grep '用户 allow' <<<"$out" | head -1)"
grep -qE '生效中的表: block 0 条 / list 2 条' <<<"$out" \
  && ok "「生效中的表」两个数都对(block 0 / list 2)" \
  || bad "那一行不对: $(grep '生效中的表' <<<"$out" | head -1)"

echo
echo "══ 3. 非空文件仍然数得对(别修坏了)══"
printf 'x.example\n# 注释\n\ny.example\nz.example\n' > "$WORK/block.txt"
out2="$(
  ADB_STATE_DIR="$WORK/state" ADB_USER_ALLOW="$WORK/allow.txt" ADB_USER_BLOCK="$WORK/block.txt" \
  ACME_HOME="$WORK/acme" PROFILE_ENV="$WORK/p.env" \
  bash -c "source '$CL'; _adblock_status" 2>/dev/null
)"
grep -qE '用户 block: 3 条' <<<"$out2" \
  && ok "3 条规则数成 3(注释与空行不计)" \
  || bad "数错了: $(grep '用户 block' <<<"$out2" | head -1)"

echo
echo "══ 4. 文件不存在时也不能断行 ══"
out3="$(
  ADB_STATE_DIR="$WORK/nope" ADB_USER_ALLOW="$WORK/nope.txt" ADB_USER_BLOCK="$WORK/nope2.txt" \
  ACME_HOME="$WORK/acme" PROFILE_ENV="$WORK/p.env" \
  bash -c "source '$CL'; _adblock_status" 2>/dev/null
)"
orphan3="$(grep -cE '^[0-9]+ 条' <<<"$out3" || true)"
[[ "$orphan3" == 0 ]] && ok "文件缺失时也没有断行" || bad "文件缺失时断了 $orphan3 行"
grep -qE '用户 allow: 0 条' <<<"$out3" && ok "文件缺失时报 0 条" || bad "文件缺失时那一行不对"
# 上面两条在"没有文件存在性判断"时也能过 —— grep 对不存在的文件同样打印 0。所以再直接
# 测一次那个判断本身: 它是这个函数唯一的早退, 少了它就要靠 grep 的报错行为兜底, 而那
# 是在依赖别人的实现细节。
CNT="$WORK/cnt.sh"; sed -n '/^_adb_count_rules()/,/^}/p' "$PDG" > "$CNT"
bash -n "$CNT" || bad "抽不出 _adb_count_rules"
gone="$(bash -c "source '$CNT'; _adb_count_rules '$WORK/definitely-not-here.txt'" 2>&1)"
[[ "$gone" == 0 ]] \
  && ok "文件不存在时直接返回 0(不依赖 grep 的报错行为; 实得 '$gone')" \
  || bad "文件不存在时返回了 '$gone'"
body_cnt="$(cat "$CNT")"
grep -q '\[\[ -f' <<<"$body_cnt" \
  && ok "函数里有显式的文件存在性判断" \
  || bad "没有存在性判断 —— 靠 grep 的行为兜底是在依赖别人的实现细节"

echo
echo "══ 5. 文案不许把「表的大小」说成「命中次数」 ══"
# 本项目**没有**命中统计(四条实现路径都调查过并否决)。status 里这些数字全是表的大小,
# 措辞一旦让人以为是"拦了多少次", 那就是一个看着像数据、其实不是的数字。
for w in 命中 拦截次数 已拦 阻断次数; do
  grep -q "$w" <<<"$body" \
    && bad "status 文案里出现「$w」—— 这些数字是表的大小, 不是次数" \
    || ok "文案里没有「$w」"
done

echo
echo "══ 6. 全仓守卫: 这两个坑不许再出现第三次 ══"
# 救援平面那边**早就踩过并写下了**这个坑(pdg.sh 里 _rescue_nft_count_kernel 上方那段注释:
# "grep -c 计数为 0 时退出码是 1 —— 调用处若写了 || echo ?, 就会在数字后面再打一个 ?"),
# 而去广告这边照样犯了一遍。光写注释挡不住第三次, 所以立一条判据。
scan(){ grep -rnE "$1" "$ROOT/deploy" "$ROOT/lib" "$ROOT/install.sh" "$ROOT/uninstall.sh" 2>/dev/null \
        | grep -vE ':[0-9]+: *#' || true; }
h1="$(scan 'grep -[a-z]*c[a-z]* [^|]*\|\| *echo')"
[[ -z "$h1" ]] \
  && ok "没有 \`grep -c … || echo\` 这种会多打一个数字的写法" \
  || bad "还有: $(head -2 <<<"$h1" | tr '\n' ' ')"
# 基本正则里 | 是字面竖线, 不是"或" —— 用它排除注释/空行的模式从来不生效
h2="$(scan "grep -[a-z]*e '[^']*\\^\\\$\\|")"
[[ -z "$h2" ]] \
  && ok "没有在基本正则里拿 | 当「或」用的模式" \
  || bad "还有: $(head -2 <<<"$h2" | tr '\n' ' ')"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail > 0 ? 1 : 0 ))
