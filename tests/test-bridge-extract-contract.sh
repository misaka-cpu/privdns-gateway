#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 桥接验收(tests/e2e-real-bridge-hop.sh)复用来源函数原文时, **抽取必须正确, 抽不对必须阻断**。
#
# run 34976950055 就栽在这: 旧抽法"从 name(){ 读到第一行顶格 }"被 build_preimage 里写
# mitm.json 的 heredoc 正文骗到(那段 JSON 有一行顶格 }), 片段被截断 → eval 语法错 →
# build_preimage 根本没定义 → 前像硬停, ② 一步没跑。
#
# 这一支只用自有临时文件, 不装机、不碰宿主绝对路径与服务, 也**不**取消真实验收脚本的
# runner 安全闸(被测的是那支脚本里的抽取函数原文, 不是整支脚本)。
# 抽取与语法通过**不等于**前像合法: 完整前像的自证仍在真实验收里。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOP="$HERE/e2e-real-bridge-hop.sh"
PLAT="$HERE/e2e-real-platform-fail.sh"
for f in "$HOP" "$PLAT"; do [[ -f "$f" ]] || { echo "[未执行] 找不到 $f"; exit 1; }; done
WORK="$(mktemp -d)" || { echo "[未执行] 建不出临时目录"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

P=0; F=0; ALOG="$WORK/assert.log"; : > "$ALOG"
ok(){  printf '[OK]   %s\n' "$1"; P=$((P+1)); printf 'OK\t%s\n' "$1" >> "$ALOG"; }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); printf 'FAIL\t%s\n' "$1" >> "$ALOG"; }
note(){ printf '[NOTE] %s\n' "$1"; }

# 被测的抽取函数: 按它自己的标记从桥接验收脚本里取原文(不 source 整支)
sed -n '/^# >>> PDG-EXTRACT-BEGIN extract_marked_fns$/,/^# <<< PDG-EXTRACT-END extract_marked_fns$/p' "$HOP" \
  | sed '1d;$d' > "$WORK/ext.sh"
[[ -s "$WORK/ext.sh" ]] || { echo "[未执行] 从 $HOP 取不到 extract_marked_fns 原文"; exit 1; }
bash -n "$WORK/ext.sh" || { echo "[未执行] 抽取函数原文语法就不过"; exit 1; }
# shellcheck source=/dev/null
source "$WORK/ext.sh"
ok "0: 抽取函数原文取自桥接验收脚本(按它自己的成对标记), 语法通过并加载成功"

# 桥接验收实际要抽的那一串(从脚本原文读, 不在本支另写一份)
mapfile -t NAMES < <(sed -n '/^EXTRACT_NAMES=(/,/)$/p' "$HOP" | tr ' ' '\n' \
  | sed 's/^EXTRACT_NAMES=(//; s/)$//' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$')
[[ "${#NAMES[@]}" -ge 20 ]] \
  && ok "0b: 读到桥接验收实际抽取的 ${#NAMES[@]} 个函数名(来源与名单都不是本支另写的)" \
  || bad "0b: 只读到 ${#NAMES[@]} 个名字"

echo; echo "══ 1. 冻结版那种抽法: 必须能重现 heredoc 截断 ══"
_fn_old(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
_fn_old "$PLAT" build_preimage > "$WORK/old-bp.sh"
OLD_LINES="$(wc -l < "$WORK/old-bp.sh")"
if bash -n "$WORK/old-bp.sh" 2>"$WORK/old.err"; then
  bad "1a: 旧抽法居然没截断(抽到 $OLD_LINES 行) —— 这一格失去意义, 需要重新确认反例"
else
  grep -qE 'here-document|unexpected end of file' "$WORK/old.err" \
    && ok "1a: 旧抽法($OLD_LINES 行)确实把 heredoc 截断了: $(head -1 "$WORK/old.err" | sed 's/.*warning: //')" \
    || bad "1a: 旧抽法失败但不是 heredoc 截断: $(head -1 "$WORK/old.err")"
fi
# build_preimage 里有两个 heredoc(mosdns.service 与 mitm.json): 旧抽法截在**第二个**里,
# 所以片段里会剩第一个的 EOF, 少第二个的 EOF, 也没有它之后那行代码。
# 判据不靠找某一行"关键字", 直接比形状: 旧片段应当是完整片段的**真前缀**(被从中间切断)。
_OLD_EOF="$(grep -c '^EOF$' "$WORK/old-bp.sh")"
extract_marked_fns "$PLAT" "$WORK/good-bp.sh" build_preimage 2>/dev/null \
  || bad "1b: 取不到完整的 build_preimage 片段作对照"
_OLDN="$(wc -l < "$WORK/old-bp.sh")"; _GOODN="$(wc -l < "$WORK/good-bp.sh")"
{ (( _OLDN < _GOODN )) && diff -q <(head -n "$_OLDN" "$WORK/good-bp.sh") "$WORK/old-bp.sh" >/dev/null; } \
  && ok "1b: 旧片段($_OLDN 行)正是完整片段($_GOODN 行)的**真前缀** —— 从 heredoc 中间被切断, 只剩 $_OLD_EOF 个 EOF" \
  || bad "1b: 形状对不上(旧 $_OLDN 行 / 完整 $_GOODN 行; 是否前缀: $(diff -q <(head -n "$_OLDN" "$WORK/good-bp.sh") "$WORK/old-bp.sh" >/dev/null && echo 是 || echo 否))"

echo; echo "══ 2. 修后: 完整保留真实函数, 片段与组合单元都语法通过 ══"
if extract_marked_fns "$PLAT" "$WORK/unit.sh" "${NAMES[@]}" 2>"$WORK/e2.err"; then
  ok "2a: 按标记抽取 ${#NAMES[@]} 个函数成功(组合单元 $(wc -l < "$WORK/unit.sh") 行)"
else
  bad "2a: 抽取失败: $(head -2 "$WORK/e2.err" | tr '\n' ' ')"
fi
bash -n "$WORK/unit.sh" && ok "2b: 组合加载单元 bash -n 通过" || bad "2b: 组合单元语法不过"
_MISS=0
for n in "${NAMES[@]}"; do grep -q "^$n(){" "$WORK/unit.sh" || { _MISS=$((_MISS+1)); echo "       缺 $n"; }; done
[[ "$_MISS" == 0 ]] && ok "2c: ${#NAMES[@]} 个函数定义在单元里一个不少" || bad "2c: 缺 $_MISS 个"
( set +u; source "$WORK/unit.sh" >/dev/null 2>&1
  for n in "${NAMES[@]}"; do declare -F "$n" >/dev/null || exit 1; done ) \
  && ok "2d: 单元能 source, 且每个函数都真的定义出来了" || bad "2d: source 之后有函数没定义"
# 内容完整性: heredoc 正文、闭合符、函数尾部都在
grep -q 'chmod 600 /etc/privdns-gateway/mitm.json' "$WORK/unit.sh" \
  && ok "2e: heredoc **之后**的代码还在(mitm.json 的 chmod)" || bad "2e: heredoc 之后被切了"
[[ "$(grep -c '^EOF$' "$WORK/unit.sh")" -ge 2 ]] \
  && ok "2f: heredoc 闭合符齐全($(grep -c '^EOF$' "$WORK/unit.sh") 个 EOF)" || bad "2f: 闭合符不齐"
grep -q 'iosstate.generate' "$WORK/unit.sh" && ok "2g: build_preimage 的后半段(iOS 记录生成)也在" || bad "2g: 后半段没抽到"
# 不含来源脚本的顶层执行入口/相邻函数
for _x in 'SECT "① 真实环境硬门"' '^build_preimage ios on$' '^set -uo pipefail$' 'assert_preimage_A(){' 'switch_repo_to_candidate(){'; do
  grep -qE "$_x" "$WORK/unit.sh" && bad "2h: 单元里混进了不该有的东西: $_x" || ok "2h: 单元里没有 [$_x]"
done

echo; echo "══ 3. 像函数、像结尾的 heredoc 正文, 不许提前截断 ══"
cat > "$WORK/tricky.sh" <<'TRICKY'
#!/usr/bin/env bash
top_side_effect_marker(){ :; }
echo "顶层副作用哨兵" > "${SENTINEL:-/dev/null}"
# >>> PDG-EXTRACT-BEGIN tricky_fn
tricky_fn(){
  cat > /dev/null <<'JSON'
{
  "a": {
    "b": 1
  }
}
fake_fn(){
  echo "这只是 heredoc 正文里长得像函数定义的文本"
}
JSON
  echo "heredoc 之后还有代码"
  local x="}"
  printf '%s\n' "$x"
}
# <<< PDG-EXTRACT-END tricky_fn
another_top_fn(){ echo "相邻函数, 不该被抽进来"; }
TRICKY
SENT="$WORK/sentinel.txt"
if SENTINEL="$SENT" extract_marked_fns "$WORK/tricky.sh" "$WORK/tricky-unit.sh" tricky_fn 2>"$WORK/e3.err"; then
  ok "3a: heredoc 正文里有顶格 } 与看起来像函数定义的文本, 仍然抽得完整"
else
  bad "3a: 被骗了: $(head -1 "$WORK/e3.err")"
fi
grep -q '^JSON$' "$WORK/tricky-unit.sh" && ok "3b: heredoc 闭合符 JSON 在片段里" || bad "3b: 闭合符被切了"
grep -q 'heredoc 之后还有代码' "$WORK/tricky-unit.sh" && ok "3c: heredoc 之后的代码在片段里" || bad "3c: 之后的代码被切了"
grep -q 'another_top_fn' "$WORK/tricky-unit.sh" && bad "3d: 相邻函数被抽进来了" || ok "3d: 相邻函数没被抽进来"
grep -q 'top_side_effect_marker' "$WORK/tricky-unit.sh" && bad "3e: 顶层函数被抽进来了" || ok "3e: 顶层函数没被抽进来"
[[ ! -e "$SENT" ]] && ok "3f: 抽取过程**没有**执行来源脚本的顶层副作用(哨兵文件没出现)" || bad "3f: 哨兵被执行了"
bash -n "$WORK/tricky-unit.sh" && ok "3g: 这份片段本身语法通过" || bad "3g"

echo; echo "══ 4. 边界不对就拒绝(具名) ══"
rejcase(){   # $1=说明 $2=脚本内容(文件) $3=函数名 $4=期望原因关键字
  local out="$WORK/rej.$RANDOM.sh"
  if extract_marked_fns "$2" "$out" "$3" 2>"$WORK/rej.err"; then
    bad "4: $1 —— 居然通过了"
  else
    grep -qE "$4" "$WORK/rej.err" \
      && ok "4: $1 ⇒ 拒绝并具名($(head -1 "$WORK/rej.err"))" \
      || bad "4: $1 拒绝了但理由不对: $(head -1 "$WORK/rej.err")"
  fi
}
printf '%s\n' 'x(){ :; }' > "$WORK/m-missing.sh"
rejcase "标记缺失" "$WORK/m-missing.sh" x '不是唯一成对'
{ echo '# >>> PDG-EXTRACT-BEGIN x'; echo 'x(){ :; }'; echo '# <<< PDG-EXTRACT-END x';
  echo '# >>> PDG-EXTRACT-BEGIN x'; echo 'x(){ :; }'; echo '# <<< PDG-EXTRACT-END x'; } > "$WORK/m-dup.sh"
rejcase "标记重复" "$WORK/m-dup.sh" x '不是唯一成对'
{ echo '# <<< PDG-EXTRACT-END x'; echo 'x(){ :; }'; echo '# >>> PDG-EXTRACT-BEGIN x'; } > "$WORK/m-inv.sh"
rejcase "标记倒置" "$WORK/m-inv.sh" x '顺序不对'
{ echo '# >>> PDG-EXTRACT-BEGIN x'; echo '# <<< PDG-EXTRACT-END x'; } > "$WORK/m-empty.sh"
rejcase "标记之间是空的" "$WORK/m-empty.sh" x '空的'
{ echo '# >>> PDG-EXTRACT-BEGIN x'; echo 'echo 不是函数定义'; echo '}'; echo '# <<< PDG-EXTRACT-END x'; } > "$WORK/m-notfn.sh"
rejcase "片段不是函数定义" "$WORK/m-notfn.sh" x '不是以 x\(\)\{ 开头'
{ echo '# >>> PDG-EXTRACT-BEGIN x'; echo 'x(){'; echo '  if [[ 1 == 1 ]]; then'; echo '}'; echo '# <<< PDG-EXTRACT-END x'; } > "$WORK/m-broken.sh"
rejcase "片段语法损坏" "$WORK/m-broken.sh" x '语法检查不过'
# 组合层: 单个片段都合法, 拼起来重复定义同一个函数也要能看出来(语法仍通过, 靠名单去重)
{ echo '# >>> PDG-EXTRACT-BEGIN y'; echo 'y(){ :; }'; echo '# <<< PDG-EXTRACT-END y'; } > "$WORK/m-ok.sh"
extract_marked_fns "$WORK/m-ok.sh" "$WORK/ok-unit.sh" y 2>/dev/null \
  && [[ "$(grep -c '^y(){' "$WORK/ok-unit.sh")" == 1 ]] \
  && ok "4: 健康用例(唯一成对)照常通过, 片段只出现一次" || bad "4: 健康用例不该失败"

echo; echo "══ 5. 抽取失败 ⇒ 前像构造与服务动作一步都不许开始 ══"
# 行为: 抽取失败时不写加载单元之外的任何东西, 也不执行来源脚本
SENT2="$WORK/sentinel2.txt"
SENTINEL="$SENT2" extract_marked_fns "$WORK/tricky.sh" "$WORK/u5.sh" no_such_fn >/dev/null 2>&1
{ [[ ! -e "$SENT2" ]] && [[ ! -s "$WORK/u5.sh" ]]; } \
  && ok "5a: 抽取失败时既没执行来源脚本(哨兵没出现), 加载单元也是空的" || bad "5a: 有副作用或写了半截单元"
# 静态: 桥接验收里, 抽取在前像构造之前, 且失败走 _hard
_LN_EXT="$(grep -n '^extract_marked_fns "\$PLAT_SRC"' "$HOP" | head -1 | cut -d: -f1)"
_LN_SRC="$(grep -n '^source "\$EXTRACT_UNIT"' "$HOP" | head -1 | cut -d: -f1)"
_LN_PRE="$(grep -n '^build_preimage ios on' "$HOP" | head -1 | cut -d: -f1)"
{ [[ -n "$_LN_EXT" && -n "$_LN_PRE" ]] && (( _LN_EXT < _LN_PRE )) && (( _LN_SRC < _LN_PRE )); } \
  && ok "5b: 桥接验收里抽取(第 $_LN_EXT 行)与加载(第 $_LN_SRC 行)都排在前像构造(第 $_LN_PRE 行)之前" \
  || bad "5b: 顺序不对(抽取 $_LN_EXT / 加载 $_LN_SRC / 前像 $_LN_PRE)"
sed -n "${_LN_EXT},$((_LN_EXT+1))p" "$HOP" | grep -q '_hard' \
  && ok "5c: 抽取失败直接 _hard(硬停), 不是记一条失败接着往下走" || bad "5c: 抽取失败没有硬停"
grep -q '^source "\$PLAT_SRC"' "$HOP" && bad "5d: 竟然 source 了整支来源脚本" || ok "5d: 没有 source 整支来源脚本(它有运行副作用)"
grep -q 'PDG_REAL_MIGRATION_OK' "$HOP" && ok "5e: 真实验收脚本的 runner 安全闸仍在(本支没有为了跑测试把它摘掉)" || bad "5e: 安全闸不见了"

echo; echo "══ N. 撤销对照 ══"
# N1 换回旧抽法 ⇒ 真实截断反例重新失败
_fn_old "$PLAT" build_preimage > "$WORK/n1.sh"
bash -n "$WORK/n1.sh" 2>/dev/null \
  && bad "N1: 换回旧抽法居然没出问题 —— 反例失去区分力" \
  || ok "N1: 换回旧抽法 ⇒ 真实 build_preimage 又被截断(语法不过), 反例有区分力"
# N2 无关注释对照: 在来源脚本里加一行无关注释, 抽取结论不变
awk 'NR==1{print; print "# 本行仅为无关注释对照"; next} {print}' "$PLAT" > "$WORK/plat-cmt.sh"
if extract_marked_fns "$WORK/plat-cmt.sh" "$WORK/unit-cmt.sh" "${NAMES[@]}" 2>/dev/null; then
  if diff -q "$WORK/unit.sh" "$WORK/unit-cmt.sh" >/dev/null; then
    ok "N2: 无关注释对照 —— 抽出来的加载单元逐字节相同, 零新增失败"
  else bad "N2: 加一行注释改变了抽取结果"; fi
else bad "N2: 加注释之后抽取失败了"; fi

A_ALL="$(awk 'END{print NR}' "$ALOG" 2>/dev/null)"; A_ALL="${A_ALL:-0}"
if [[ "$((P+F))" == "$A_ALL" ]]; then ok "计数对账: 打印 $A_ALL 条断言, 全部进了总数"
else bad "计数对账: 打印 $A_ALL 条, 只有 $((P+F)) 条进了总数"; fi
note "本支只证明「抽取正确且抽不对会阻断」; **前像是否合法**由真实验收自证, 两者不互相替代。"
echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]
