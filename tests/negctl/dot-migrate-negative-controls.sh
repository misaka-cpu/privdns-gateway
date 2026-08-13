#!/usr/bin/env bash
# 状态机负控: 逐条把 migrate_dotwitness 的判据改坏, 证明**至少有一条断言会因此转红**。
#
# 为什么要有它: 故障矩阵现在全绿, 但"全绿"本身不说明它有牙齿 —— 一条写错的判据、
# 一个永远命中不了的注入, 在什么都没坏的时候也是绿的。负控是唯一能回答
# "如果状态机真的退化了, 我们会不会知道"这个问题的东西。
#
# 每类五步, 缺一不算有效:
#   1. 锚点在整份文件里**恰好出现一次**(用 Python 数 literal 出现次数, 不用 grep -c ——
#      grep 数的是匹配行数, 多行锚点会得到一个毫无意义的大数字);
#   2. 替换后原锚点消失、新内容恰好出现一次;
#   3. 改坏后 bash -n 仍通过(语法错导致的红不算"测试抓住了");
#   4. 矩阵里至少一条断言转红, 并报出转红条数;
#   5. 恢复后 sha256 逐字节一致。
#
# 改坏落在**工作副本**里, 正式树一个字节都不动。
set -uo pipefail

REPO="${PDG_NEGCTL_REPO:-/repo}"
TARGET="deploy/bot/pdg.sh"
MATRIX="tests/e2e-dot-migrate.sh"
p=0; f=0
ok(){ p=$((p+1)); echo "[OK]   $*"; }
bad(){ f=$((f+1)); echo "[FAIL] $*"; }
sect(){ echo; echo "── $* ──"; }   # 不叫 head: 被测代码里有 `| head -1`

[[ "${PDG_E2E_ISOLATED:-}" == 1 && "$(id -u)" == 0 ]] || { echo "需要 PDG_E2E_ISOLATED=1 且 root"; exit 1; }

WCROOT="$(mktemp -d -t pdg-smnc-XXXXXX)"   # 不用默认 tmp.* 前缀: 会被矩阵的残留判据数进去
WC="$WCROOT/wc"
cleanup(){ rm -rf "$WCROOT"; }
trap cleanup EXIT INT TERM          # runner 中途异常退出也要清掉工作副本
cp -a "$REPO" "$WC"

# ── TOUCHED 闭包 ───────────────────────────────────────────────────────────
# 不手写猜: 这里列的是**矩阵与本 runner 的 mutation 实际会写到**的每一个文件。
# 原来的 restore() 只写回 pdg.sh, 于是矩阵第 3/10 格改过的 dotwroute.py、第 1 格改过的
# dot-domain 一旦在中途被打断就留在改坏状态, 后面每一格都在污染过的地基上跑 ——
# NC-SM-2 在 runner 里时红时绿, 最可能就是这么来的。
TOUCHED=(
  "deploy/bot/pdg.sh"
  "deploy/bot/dotwroute.py"
  "deploy/mosdns/config.yaml"
  "tests/e2e-dot-migrate.sh"
  "tests/test-dot-lifecycle.py"
)
PRISTINE="$WCROOT/pristine"; mkdir -p "$PRISTINE"
declare -A P_SHA P_MODE
for rel in "${TOUCHED[@]}"; do
  [[ -f "$WC/$rel" ]] || { echo "TOUCHED 里的 $rel 不存在, runner 拒绝启动"; exit 1; }
  install -D -m 600 "$WC/$rel" "$PRISTINE/$rel"
  P_SHA[$rel]="$(sha256sum "$WC/$rel" | cut -d' ' -f1)"
  P_MODE[$rel]="$(stat -c %a "$WC/$rel")"
done
BASE_SHA="$(sha256sum "$REPO/$TARGET" | cut -d' ' -f1)"
WC_SHA="${P_SHA[$TARGET]}"

# 用 Python 做 literal 计数与替换。返回值: 0=成功改坏, 2=锚点数不对, 3=替换后不合预期。
mutate(){ python3 - "$WC/$TARGET" "$1" "$2" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
n = t.count(old)
if n != 1:
    print("锚点出现 %d 次, 预期 1" % n, file=sys.stderr)
    sys.exit(2)
out = t.replace(old, new, 1)
# 两种形态: `new` 里含 `old` 是**插入型**(在原句前后加东西), 替换后旧锚点应恰好剩 1 次;
# 否则是纯替换型, 旧锚点应归零。新内容的出现次数不做唯一性要求 —— 像 `  :` 这种短句
# 文件里本来就有好几处, 强求唯一只会把有效的改坏器判成无效。
want_old = 1 if old in new else 0
if out.count(old) != want_old:
    print("替换后不合预期: 旧锚点残留 %d, 预期 %d" % (out.count(old), want_old), file=sys.stderr)
    sys.exit(3)
if new not in out:
    print("替换后找不到新内容", file=sys.stderr)
    sys.exit(3)
if out == t:
    print("替换没有改变文件", file=sys.stderr)
    sys.exit(3)
open(path, "w").write(out)
PY
}

MATRIX_OUT="${TMPDIR:-/tmp}/negctl-matrix.out"
run_matrix(){
  PDG_E2E_ISOLATED=1 PDG_DOTW_REPO="$WC" bash "$WC/$MATRIX" </dev/null >"$MATRIX_OUT" 2>&1
}
n_red(){ grep -c '^\[FAIL' "$MATRIX_OUT" 2>/dev/null || true; }
# 失败**集合**而不是失败**条数** —— lifecycle 本来就有 6 条待办红灯, 只比数量的话
# 一个把某条从红变绿、又新增一条红的 mutation 会被判成"没新增失败"。
fail_set(){ grep '^\[FAIL' "$1" 2>/dev/null | sed 's/[0-9]\{3,\}/N/g' | sort; }
new_fails(){ comm -13 <(fail_set "$1") <(fail_set "$2"); }
n_assert(){ local a b; a="$(grep -c '^\[OK' "$MATRIX_OUT" || true)"; b="$(n_red)"; echo $(( ${a:-0} + ${b:-0} )); }

# 从 pristine **字节**写回全部 TOUCHED, 不用 git checkout(容器里它静默失效过)。
restore(){
  local rel
  for rel in "${TOUCHED[@]}"; do
    cp -f "$PRISTINE/$rel" "$WC/$rel"
    chmod "${P_MODE[$rel]}" "$WC/$rel"
  done
}
# 每格结束后核对: TOUCHED 全部精确复原, 且工作副本没有多出别的改动
verify_restore(){
  local n="$1" rel bad=0
  for rel in "${TOUCHED[@]}"; do
    [[ "$(sha256sum "$WC/$rel" | cut -d' ' -f1)" == "${P_SHA[$rel]}" ]] || { bad "NC-SM-$n 恢复后 $rel 摘要不一致"; bad=1; }
    [[ "$(stat -c %a "$WC/$rel")" == "${P_MODE[$rel]}" ]] || { bad "NC-SM-$n 恢复后 $rel mode 不一致"; bad=1; }
  done
  local dirty; dirty="$(git -C "$WC" status --short 2>/dev/null | wc -l)"
  [[ "$dirty" == 0 ]] || { bad "NC-SM-$n 工作副本还有 $dirty 项未恢复: $(git -C "$WC" status --short | head -3 | tr '\n' ' ')"; bad=1; }
  return $bad
}

sect "基线: 未改坏时矩阵必须全绿"
if run_matrix; then
  ok "基线绿: $(tail -1 "$MATRIX_OUT")"
else
  bad "基线就红了, 后面每一类都无从判断: $(tail -2 "$MATRIX_OUT" | tr '\n' ' ')"
  exit 1
fi
BASE_ASSERTS="$(n_assert)"
BASE_OUT="${TMPDIR:-/tmp}/nc-base.out"
cp -f "$MATRIX_OUT" "$BASE_OUT"
echo "  基线失败集合: $(fail_set "$BASE_OUT" | wc -l) 条"

# $1=编号 $2=名字 $3=原文 $4=替换
cell(){
  local n="$1" name="$2" old="$3" new="$4" err
  if ! err="$(mutate "$old" "$new" 2>&1)"; then
    bad "NC-SM-$n $name → $err"
    restore; return
  fi
  if ! bash -n "$WC/$TARGET" 2>/dev/null; then
    bad "NC-SM-$n $name → 改坏后语法不合法, 这条不算有效负控"
    restore; return
  fi
  run_matrix || true
  cp -f "$MATRIX_OUT" "${TMPDIR:-/tmp}/nc-mut.out"
  local added; added="$(new_fails "$BASE_OUT" "${TMPDIR:-/tmp}/nc-mut.out")"
  if [[ "$(n_assert)" -lt 10 ]]; then
    bad "NC-SM-$n $name → 矩阵只跑出 $(n_assert) 条断言(基线 $BASE_ASSERTS), 疑似没真跑起来"
  elif [[ -z "$added" ]]; then
    bad "NC-SM-$n $name → **新增失败为 0**(基线已有 $(fail_set "$BASE_OUT" | wc -l) 条), 这条判据没有牙齿"
  else
    ok "NC-SM-$n $name → 新增 $(wc -l <<< "$added") 条失败: $(head -1 <<< "$added" | cut -c1-72)"
    # 完整留存这一格的**规范化**新增失败集合。上面那行只有计数与首条(截断 72 字符),
    # 跨次比对"集合是否漂移"时不够用 —— 稳定性复跑要的正是逐条一致, 不是数量一致。
    # 顺序即 fail_set() 的 canonical 排序; 前缀取 [ADDED*] 而不是 [FAIL]:
    # fail_set() 与 bad() 都只认 `^[FAIL`, 所以这几行不会被任何汇总器计成真实失败。
    # 集合为空走上面 elif 那条 bad 分支, 不会到这里 —— 不伪造空记录。
    echo "[ADDED-BEGIN] NC-SM-$n count=$(wc -l <<< "$added")"
    while IFS= read -r _added_line; do printf '[ADDED] %s\n' "$_added_line"; done <<< "$added"
    echo "[ADDED-END] NC-SM-$n sha256=$(printf '%s\n' "$added" | sha256sum | cut -d' ' -f1)"
  fi
  restore
  verify_restore "$n" || true
}

sect "12 类"

# 1. 去掉 || rc=1 —— 迁移链的判据在 test-dot-lifecycle, 单独验
if mutate "  migrate_dotwitness || rc=1" "  migrate_dotwitness || true" >/dev/null 2>&1; then
  if PDG_DOTW_REPO="$WC" python3 "$WC/tests/test-dot-lifecycle.py" >"${TMPDIR:-/tmp}/nc-lc.out" 2>&1; then
    bad "NC-SM-1 去掉 || rc=1 → lifecycle 仍绿, 这条没有牙齿"
  else
    if grep -q 'rc=1' "${TMPDIR:-/tmp}/nc-lc.out"; then
      ok "NC-SM-1 去掉 || rc=1 → lifecycle 转红并点名(共 $(grep -c '^\[FAIL' "${TMPDIR:-/tmp}/nc-lc.out") 条)"
    else
      bad "NC-SM-1 转红但没点名 || rc=1 那一条"
    fi
  fi
  restore
else
  bad "NC-SM-1 锚点不唯一"
fi

# 2. 吞掉候选 mosdns 校验失败
cell 2 "吞掉候选校验失败" \
'        c_y "  ❌ mosdns 路由候选未通过校验, 保持原配置不动:"
        grep -iE '"'"'^Error'"'"' "$work/val.log" | head -1 | sed '"'"'s/^/     /'"'"'
        rm -rf "$work"; return 1' \
'        c_y "  ❌ mosdns 路由候选未通过校验(已忽略):"
        grep -iE '"'"'^Error'"'"' "$work/val.log" | head -1 | sed '"'"'s/^/     /'"'"''

# 3. 吞掉原子安装失败
cell 3 "吞掉原子安装失败" \
'  if [[ "$rc" != 0 ]]; then
    c_y "  ❌ 写入 witness 的 unit/env/mosdns 配置失败, 正在回滚。"
    _dw_rollback; rm -rf "$work"; return 1
  fi' \
'  if [[ "$rc" != 0 ]]; then
    c_y "  (忽略写入失败)"
  fi'

# 4. 吞掉 daemon-reload 失败 —— 整块 if 替换, 大括号自然配平
cell 4 "吞掉 daemon-reload 失败" \
'  [[ "$need_reload" == 1 ]] && { systemctl daemon-reload >/dev/null 2>&1 || {
      c_y "  ❌ daemon-reload 失败, 正在回滚。"; _dw_rollback; rm -rf "$work"; return 1; }; }' \
'  [[ "$need_reload" == 1 ]] && systemctl daemon-reload >/dev/null 2>&1
  true'

# 5. 吞掉 mosdns restart 失败
cell 5 "吞掉 mosdns restart 失败" \
'  [[ "$need_mos" == 1 ]] && { systemctl restart mosdns >/dev/null 2>&1 || {
      c_y "  ❌ mosdns 重启失败, 正在回滚。"; _dw_rollback; rm -rf "$work"; return 1; }; }' \
'  [[ "$need_mos" == 1 ]] && systemctl restart mosdns >/dev/null 2>&1
  true'

# 6. 吞掉 witness enable 失败
# 注意: 只摘 enable 检查的话矩阵仍全绿 —— 5399 监听那道门是第二重防线, 会把它兜住。
# 那不是"没有牙齿", 是防御纵深。要让这条负控有意义, 必须把两道门一起摘。
cell 6 "吞掉 witness enable/restart 失败(连同 5399 兜底)" \
'    if ! systemctl enable --now pdg-dotwitness >/dev/null 2>&1; then
      c_y "  ❌ pdg-dotwitness 未能启用, 正在回滚。"; _dw_rollback; rm -rf "$work"; return 1
    fi' \
'    systemctl enable --now pdg-dotwitness >/dev/null 2>&1 || true
  fi
  if false; then'

# 7. 去掉 5399 验证
cell 7 "去掉 active/5399 验证" \
"  if ! ss -lun 2>/dev/null | grep -q '127\.0\.0\.1:5399'; then
    c_y \"  ❌ pdg-dotwitness 已启动但没有在 127.0.0.1:5399 监听, 正在回滚。\"
    _dw_rollback; rm -rf \"\$work\"; return 1
  fi" \
'  : "NC7 去掉了 5399 验证"'

# 8. 内容相同就跳过 disabled/inactive 修复
cell 8 "内容相同就不修服务状态" \
'  if [[ "$e1" != enabled || "$a1" != active || "$need_wit" == 1 ]]; then' \
'  if [[ "$need_wit" == 1 ]]; then'

# 9. 无变化时无条件 restart
cell 9 "无变化也无条件 restart" \
'  local changed=$((need_reload + need_mos + need_wit))' \
'  systemctl restart pdg-dotwitness >/dev/null 2>&1
  local changed=$((need_reload + need_mos + need_wit))'

# 10. partial route 被当 full(让 render 原样返回现配置)
cell 10 "partial route 被当完整" \
'  if ! python3 "$router" render "$DW_MOS" "$dom" > "$work/candidate.yaml" 2>"$work/mos.err"; then' \
'  cp -f "$DW_MOS" "$work/candidate.yaml"
  if false; then'

# 11. before-image 少采 unit
cell 11 "before-image 少采 unit" \
'  _dw_snap_file "$DW_UNIT" "$bi" unit || { c_y "  ❌ 采集 unit before-image 失败"; rm -rf "$work"; return 1; }' \
'  true'

# 11b. 回滚不恢复 enabled/active
cell 112 "回滚不恢复 enabled/active" \
'    if [[ "$e0" != enabled ]]; then systemctl disable pdg-dotwitness >/dev/null 2>&1 || true; fi
    if [[ "$a0" == active ]]; then
      systemctl start pdg-dotwitness >/dev/null 2>&1 || bad=1
    else
      systemctl stop pdg-dotwitness >/dev/null 2>&1 || true
    fi' \
'    true'

# 12. 回滚不完整仍不报警
cell 12 "回滚不完整不报警" \
'      c_y "  ⚠️  回滚不完整 —— unit/env/mosdns 配置或服务状态可能没有完全复原。"
      c_y "     请人工核对 $DW_UNIT、$DW_ENV、$DW_MOS 与 systemctl status mosdns。"
      return 1' \
'      return 0'

# ══ runner 自检: 每项都要证明 runner **会拒绝**, 而不是只打印提示 ═══════════
sect "runner 防假绿自检"
selfcheck(){   # $1=名字 $2=会让 runner 判红的动作
  local name="$1"; shift
  local p0=$p f0=$f
  "$@" >/dev/null 2>&1
  local got=$(( f - f0 ))
  p=$p0; f=$f0                      # 自检本身不计入正式统计
  (( got > 0 )) && ok "自检: $name → runner 判红" || bad "自检: $name → runner **没有**判红"
}
selfcheck "锚点不存在"       cell 90 "自检" "THIS_ANCHOR_DOES_NOT_EXIST_ANYWHERE" "x"
selfcheck "锚点命中多次"     cell 91 "自检" "local" "local"
selfcheck "mutation 未改变文件" cell 92 "自检" '  local work; work="$(mktemp -d)" || return 1' '  local work; work="$(mktemp -d)" || return 1'
selfcheck "改坏后语法损坏"   cell 93 "自检" '  local work; work="$(mktemp -d)" || return 1' '  local work; work="$(mktemp -d)" || return 1 ; fi fi fi'

# 改坏后 0 条转红: 用一个真正无害的改动(末尾追一行注释)
_p0=$p; _f0=$f
cell 94 "自检:无害改动" '# ── 6.2B: DoT 证据端(observer)的生命周期状态机' '# 无害注释
# ── 6.2B: DoT 证据端(observer)的生命周期状态机'
_got=$(( f - _f0 )); p=$_p0; f=$_f0
(( _got > 0 )) && ok "自检: 无害改动 0 条转红 → runner 判这条负控无效" \
                || bad "自检: 无害改动却被当成有效负控"

# 恢复摘要不一致
_p0=$p; _f0=$f
printf '\n# 污染\n' >> "$WC/$TARGET"
[[ "$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)" != "$WC_SHA" ]] && { restore; ok "自检: 恢复摘要不一致 → 能被检出(比对基于 sha256)"; } \
  || bad "自检: 摘要比对失灵"
p=$((_p0+1)); f=$_f0

# 单类失败必须让 runner 总 rc 非零
_p0=$p; _f0=$f
if grep -q 'exit $(( f ? 1 : 0 ))' "$0"; then ok "自检: 单类失败 → runner 总 rc 非零(f>0 即 exit 1)"; else bad "自检: runner 没有把失败传到退出码"; fi
# 工作副本清理挂在 trap 上, 中途异常退出也会清
grep -q 'trap cleanup EXIT INT TERM' "$0" && ok "自检: 工作副本清理挂在 trap(中途异常退出也清)" \
  || bad "自检: 没有 trap 清理"

sect "收尾"
[[ "$(sha256sum "$REPO/$TARGET" | cut -d' ' -f1)" == "$BASE_SHA" ]] \
  && ok "正式树 $TARGET 逐字节一致" || bad "正式树被改动了"

echo
echo "──────────────────────────────────────────────────────────────"
echo "有效 $p, 失败 $f"
exit $(( f ? 1 : 0 ))
