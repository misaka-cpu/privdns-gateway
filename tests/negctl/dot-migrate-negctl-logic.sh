#!/usr/bin/env bash
# 负控 runner 两块核心逻辑的**秒级**自检: 恢复闭包与失败集合差集。
#
# 为什么单独拆出来: runner 的每一项自检原来都要完整跑一遍 126 断言的矩阵(约 10 分钟),
# 十项就是一百分钟 —— 于是这些自检实际上从来没被完整跑过。而这两块恰恰是纯逻辑,
# 不需要真 systemd 也不需要 mosdns, 秒级就能验完。
#
# 它们各自挡住的东西:
#   · 恢复闭包 —— 旧版 restore() 只写回 pdg.sh, 矩阵改过的 dotwroute.py 会留在改坏状态,
#     后面每一格都在污染过的地基上跑。NC-SM-2 在 runner 里时红时绿, 最可能就是这么来的。
#   · 失败集合差集 —— lifecycle 本来就有 6 条待办红灯。只比失败**条数**的话, 一个把某条
#     从红变绿、又新增一条红的 mutation 会被判成"没新增失败"; 反过来也会拿旧红灯充数。
set -u
P=0; F=0
ok(){ P=$((P+1)); echo "[OK]   $*"; }
bad(){ F=$((F+1)); echo "[FAIL] $*"; }

echo "── A. 恢复闭包: 旧版只写回 pdg.sh 必须被 verify_restore 抓住 ──"
WCROOT="$(mktemp -d -t pdg-logic-XXXXXX)"; WC="$WCROOT/wc"
git clone -q --shared --no-checkout /home/codex/privdns-gateway "$WC"
git -C "$WC" checkout -q HEAD
TOUCHED=("deploy/bot/pdg.sh" "deploy/bot/dotwroute.py" "deploy/mosdns/config.yaml"
         "tests/e2e-dot-migrate.sh" "tests/test-dot-lifecycle.py")
PRISTINE="$WCROOT/pristine"; mkdir -p "$PRISTINE"
declare -A P_SHA P_MODE
for rel in "${TOUCHED[@]}"; do
  install -D -m 600 "$WC/$rel" "$PRISTINE/$rel"
  P_SHA[$rel]="$(sha256sum "$WC/$rel"|cut -d' ' -f1)"; P_MODE[$rel]="$(stat -c %a "$WC/$rel")"
done
verify_restore(){ local rel b=0
  for rel in "${TOUCHED[@]}"; do
    [[ "$(sha256sum "$WC/$rel"|cut -d' ' -f1)" == "${P_SHA[$rel]}" ]] || { echo "    ↳ $rel 摘要不一致"; b=1; }
  done
  local d; d="$(git -C "$WC" status --short 2>/dev/null|wc -l)"
  [[ "$d" == 0 ]] || { echo "    ↳ 工作副本还有 $d 项"; b=1; }
  return $b; }
# 模拟: mutation 改了 dotwroute.py, 旧版 restore 只写回 pdg.sh
printf '\n# mutated\n' >> "$WC/deploy/bot/dotwroute.py"
cp -f "$PRISTINE/deploy/bot/pdg.sh" "$WC/deploy/bot/pdg.sh"     # 旧版 restore
if verify_restore >/dev/null 2>&1; then bad "A 旧版 restore 漏掉 dotwroute.py 却没被抓住"
else ok "A 旧版 restore(只写回 pdg.sh) → verify_restore 判非零"; fi
# 新版 restore: 全量写回
for rel in "${TOUCHED[@]}"; do cp -f "$PRISTINE/$rel" "$WC/$rel"; chmod "${P_MODE[$rel]}" "$WC/$rel"; done
if verify_restore; then ok "A 新版 restore(全量 pristine 写回) → 全部精确复原, git status 为空"
else bad "A 新版 restore 仍不干净"; fi
rm -rf "$WCROOT"

echo "── B. 失败集合差集: 6 条基线红灯不得充数 ──"
fail_set(){ grep '^\[FAIL' "$1" 2>/dev/null | sed 's/[0-9]\{3,\}/N/g' | sort; }
new_fails(){ comm -13 <(fail_set "$1") <(fail_set "$2"); }
B=$(mktemp); M=$(mktemp)
printf '[FAIL] install.sh 安装 witness unit\n[FAIL] install.sh enable witness\n[FAIL] uninstall 处理 pdg-dotwitness\n[FAIL] uninstall disable --now 它\n[FAIL] uninstall 删 unit 文件\n[FAIL] doctor 有独立的 witness 检查项\n' > "$B"
cp "$B" "$M"
[[ -z "$(new_fails "$B" "$M")" ]] && ok "B 基线 6 条 + mutation 后完全相同 → 新增失败 0(判无效)" \
  || bad "B 相同集合却算出了新增"
echo '[FAIL] 11 回滚后 witness 未恢复 disabled/inactive' >> "$M"
n="$(new_fails "$B" "$M" | wc -l)"
[[ "$n" == 1 ]] && ok "B 新增第 7 条 → 差集恰好 1 条: $(new_fails "$B" "$M")" || bad "B 差集算成 $n 条"
# 反向: 只比数量会漏掉的情形 —— 去掉一条基线红灯 + 新增一条
cp "$B" "$M"; sed -i '1d' "$M"; echo '[FAIL] 新的真失败' >> "$M"
n2="$(new_fails "$B" "$M" | wc -l)"
[[ "$n2" == 1 ]] && ok "B 一减一增(总数不变) → 差集仍抓到 1 条新增(只比数量会漏)" || bad "B 一减一增判成 $n2"
# 归一化不能把不同断言合并
printf '[FAIL] 格 4 残留 /tmp/tmp.AAAAAA\n' > "$B"; printf '[FAIL] 格 5 残留 /tmp/tmp.BBBBBB\n' > "$M"
[[ "$(new_fails "$B" "$M" | wc -l)" == 1 ]] && ok "B 窄归一化没把不同断言合并(格 4 vs 格 5 仍算新增)" \
  || bad "B 归一化过宽, 不同断言被合并了"
rm -f "$B" "$M"

echo "── C. mutate() 的四种拒绝(最小 fixture, 不跑矩阵) ──"
# runner 的 mutate() 判据原来只能靠跑十次完整矩阵来证明。这里用一个几行的假目标文件
# 直接喂它四种输入 —— 同样的判据, 秒级, 于是每次都真的会跑。
FX="$(mktemp -d -t pdg-fx-XXXXXX)"
cat > "$FX/target.sh" <<'EOT'
#!/usr/bin/env bash
f(){ local x=1; echo "$x"; }
g(){ local x=2; echo "$x"; }
EOT
cp "$FX/target.sh" "$FX/pristine.sh"
mut(){ python3 - "$FX/target.sh" "$1" "$2" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read(); n = t.count(old)
if n != 1: print("锚点出现 %d 次, 预期 1" % n, file=sys.stderr); sys.exit(2)
out = t.replace(old, new, 1)
want_old = 1 if old in new else 0
if out.count(old) != want_old: print("替换后不合预期", file=sys.stderr); sys.exit(3)
if new not in out: print("替换后找不到新内容", file=sys.stderr); sys.exit(3)
if out == t: print("替换没有改变文件", file=sys.stderr); sys.exit(3)
open(path, "w").write(out)
PY
}
mut "THIS_DOES_NOT_EXIST" "x" 2>/dev/null; [[ $? == 2 ]] && ok "C1 锚点不存在 → rc=2" || bad "C1 未拒绝"
mut "local x=" "local x=" 2>/dev/null;    [[ $? == 2 ]] && ok "C2 锚点多重(命中 2 次) → rc=2" || bad "C2 未拒绝"
mut 'f(){ local x=1; echo "$x"; }' 'f(){ local x=1; echo "$x"; }' 2>/dev/null
[[ $? == 3 ]] && ok "C3 mutation 未改变文件 → rc=3" || bad "C3 未拒绝"
cmp -s "$FX/target.sh" "$FX/pristine.sh" && ok "C1-C3 被拒后目标文件一个字节没动" || bad "C1-C3 却改了文件"
# 语法损坏: mutate 本身会成功, 但语法门必须拦住
mut 'g(){ local x=2; echo "$x"; }' 'g(){ local x=2; echo "$x"; ' >/dev/null 2>&1
if bash -n "$FX/target.sh" 2>/dev/null; then bad "C4 语法已损坏却通过 bash -n"
else ok "C4 改坏后语法不合法 → 语法门拦住(不算有效负控)"; fi
cp -f "$FX/pristine.sh" "$FX/target.sh"

echo "── D. trap 清理与无害改动 ──"
# trap: 起一个子 shell, 中途 exit, 工作副本目录必须已被清掉
TD="$(mktemp -d -t pdg-trapchk-XXXXXX)"
bash -c 'WCROOT="'"$TD"'/wc"; mkdir -p "$WCROOT"; cleanup(){ rm -rf "$WCROOT"; }
         trap cleanup EXIT INT TERM; echo x > "$WCROOT/f"; exit 7' >/dev/null 2>&1
[[ ! -d "$TD/wc" ]] && ok "D1 中途 exit → trap 清掉了工作副本" || bad "D1 工作副本残留"
rmdir "$TD" 2>/dev/null
# 无害改动: 追加一行注释, 失败集合不变 → 差集为空 → 判无效
B2=$(mktemp); M2=$(mktemp)
printf '[FAIL] 甲\n[FAIL] 乙\n' > "$B2"; cp "$B2" "$M2"
[[ -z "$(new_fails "$B2" "$M2")" ]] && ok "D2 无害改动(失败集合不变) → 新增 0, 判该负控无效" \
  || bad "D2 无害改动却算出新增"
rm -f "$B2" "$M2"; rm -rf "$FX"

echo; echo "通过 $P, 失败 $F"; exit $((F?1:0))
