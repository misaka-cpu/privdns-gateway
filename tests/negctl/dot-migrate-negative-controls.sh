#!/usr/bin/env bash
# 状态机负控: 逐条把 migrate_dotwitness 的判据改坏, 证明**至少有一条断言会因此转红**。
#
# 为什么要有它: 故障矩阵现在 77/0, 但"全绿"本身不说明它有牙齿 —— 一条写错的判据、
# 一个永远命中不了的注入, 在什么都没坏的时候也是绿的。负控是唯一能回答
# "如果状态机真的退化了, 我们会不会知道"这个问题的东西。
#
# 每条流程固定五步, 缺一不算有效:
#   1. 锚点精确命中(多了少了都说明改坏器没打在预期位置);
#   2. 改坏后 bash -n 仍通过(语法错导致的红不算"测试抓住了");
#   3. 指定的测试里至少一条断言转红;
#   4. 0 条转红 → 这条负控无效, runner 整体非零;
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
head(){ echo; echo "── $* ──"; }

[[ "${PDG_E2E_ISOLATED:-}" == 1 && "$(id -u)" == 0 ]] || { echo "需要 PDG_E2E_ISOLATED=1 且 root"; exit 1; }

WC="$(mktemp -d -t pdg-smnc-XXXXXX)/wc"   # 不用默认 tmp.* 前缀: 会被矩阵的残留判据数进去
cp -a "$REPO" "$WC"
BASE_SHA="$(sha256sum "$REPO/$TARGET" | cut -d' ' -f1)"
WC_SHA="$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)"

run_matrix(){   # 在工作副本上跑故障矩阵, 返回是否有失败
  PDG_E2E_ISOLATED=1 PDG_DOTW_REPO="$WC" bash "$WC/$MATRIX" </dev/null >/tmp/nc.out 2>&1
  local rc=$?
  return $rc
}

head "基线: 未改坏时矩阵必须全绿"
if run_matrix; then
  ok "基线绿: $(tail -1 /tmp/nc.out)"
else
  bad "基线就红了, 后面每一条都无从判断: $(tail -3 /tmp/nc.out | tr '\n' ' ')"
  exit 1
fi

# $1=编号 $2=名字 $3=原文 $4=替换 $5=预期命中次数(默认 1)
cell(){
  local n="$1" name="$2" old="$3" new="$4" want="${5:-1}"
  local got; got="$(grep -cF -- "$old" "$WC/$TARGET" || true)"
  if [[ "$got" != "$want" ]]; then
    bad "NC-SM-$n $name → 锚点命中 $got 次, 预期 $want(改坏器没打在预期位置)"
    return
  fi
  python3 - "$WC/$TARGET" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p).read()
open(p, "w").write(t.replace(old, new))
PY
  if ! bash -n "$WC/$TARGET" 2>/dev/null; then
    bad "NC-SM-$n $name → 改坏后语法不合法, 这条不算有效负控"
    cp -f "$REPO/$TARGET" "$WC/$TARGET"; return
  fi
  if run_matrix; then
    bad "NC-SM-$n $name → 矩阵**仍然全绿**, 这条判据没有牙齿"
  else
    ok "NC-SM-$n $name → 转红($(grep -c '^\[FAIL' /tmp/nc.out) 条断言)"
  fi
  cp -f "$REPO/$TARGET" "$WC/$TARGET"
  [[ "$(sha256sum "$WC/$TARGET" | cut -d' ' -f1)" == "$WC_SHA" ]] || bad "NC-SM-$n 恢复后摘要不一致"
}

head "12 类"
# 2. 吞掉候选 mosdns 校验失败
cell 2 "吞掉候选校验失败" \
  '        rm -rf "$work"; return 1
      fi
    fi
  fi' \
  '        :
      fi
    fi
  fi'
# 3. 吞掉原子安装失败
cell 3 "吞掉原子安装失败" \
  '  if [[ "$rc" != 0 ]]; then
    c_y "  ❌ 写入 witness 的 unit/env/mosdns 配置失败, 正在回滚。"' \
  '  if false; then
    c_y "  ❌ 写入 witness 的 unit/env/mosdns 配置失败, 正在回滚。"'
# 4. 吞掉 daemon-reload 失败
cell 4 "吞掉 daemon-reload 失败" \
  '  [[ "$need_reload" == 1 ]] && { systemctl daemon-reload >/dev/null 2>&1 || {' \
  '  [[ "$need_reload" == 1 ]] && { systemctl daemon-reload >/dev/null 2>&1 || true; { false && {'
# 5. 吞掉 mosdns restart 失败
cell 5 "吞掉 mosdns restart 失败" \
  '  [[ "$need_mos" == 1 ]] && { systemctl restart mosdns >/dev/null 2>&1 || {' \
  '  [[ "$need_mos" == 1 ]] && { systemctl restart mosdns >/dev/null 2>&1 || true; { false && {'
# 6. 吞掉 witness enable 失败
cell 6 "吞掉 witness enable 失败" \
  '    if ! systemctl enable --now pdg-dotwitness >/dev/null 2>&1; then' \
  '    if false; then'
# 7. 去掉 5399 监听验证
cell 7 "去掉 5399 监听验证" \
  "  if ! ss -lun 2>/dev/null | grep -q '127\.0\.0\.1:5399'; then" \
  '  if false; then'
# 8. 内容相同就跳过 disabled/inactive 修复
cell 8 "内容相同就不修服务状态" \
  '  if [[ "$e1" != enabled || "$a1" != active || "$need_wit" == 1 ]]; then' \
  '  if [[ "$need_wit" == 1 ]]; then'
# 9. 无变化时仍无条件 restart
cell 9 "无变化也无条件 restart" \
  '  local changed=$((need_reload + need_mos + need_wit))' \
  '  systemctl restart pdg-dotwitness >/dev/null 2>&1
  local changed=$((need_reload + need_mos + need_wit))'
# 10. partial route 被当完整(让 render 直接原样返回)
cell 10 "partial route 被当完整" \
  '  if ! python3 "$router" render "$DW_MOS" "$dom" > "$work/candidate.yaml" 2>"$work/mos.err"; then' \
  '  cp -f "$DW_MOS" "$work/candidate.yaml"; if false; then'
# 11a/b/c. before-image 少一项
cell 11 "before-image 少采 unit" \
  '  _dw_snap_file "$DW_UNIT" "$bi" unit || { c_y "  ❌ 采集 unit before-image 失败"; rm -rf "$work"; return 1; }' \
  '  : '
# 12. 回滚不完整仍返回 0 / 不报警
cell 12 "回滚不完整不报警" \
  '      c_y "  ⚠️  回滚不完整 —— unit/env/mosdns 配置或服务状态可能没有完全复原。"' \
  '      : '
# 1. 去掉 || rc=1(这条改的是迁移链, 单独用静态判据验)
head "1. 去掉 migrate_dotwitness || rc=1"
python3 - "$WC/$TARGET" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
old = "  migrate_dotwitness || rc=1"
assert t.count(old) == 1, t.count(old)
open(p, "w").write(t.replace(old, "  migrate_dotwitness || true"))
PY
if PDG_DOTW_REPO="$WC" python3 - "$WC" <<'PY'
import re, sys
s = open(sys.argv[1] + "/deploy/bot/pdg.sh").read()
m = re.search(r"^run_all_migrations\(\)\{(?:.*\n)*?^\}", s, re.M)
sys.exit(0 if re.search(r"migrate_dotwitness \|\| rc=1", m.group(0)) else 1)
PY
then bad "NC-SM-1 去掉 || rc=1 后静态判据仍认为在(没有牙齿)"
else ok "NC-SM-1 去掉 || rc=1 → test-dot-lifecycle 的迁移链判据转红"; fi
cp -f "$REPO/$TARGET" "$WC/$TARGET"

head "runner 自检"
_p0=$p; _f0=$f
cell 90 "自检:锚点不存在" "THIS_ANCHOR_DOES_NOT_EXIST" "x"
[[ $f -gt $_f0 ]] && { p=$_p0; f=$_f0; ok "自检 1: 锚点不存在 → runner 判红"; } \
                  || { p=$_p0; f=$_f0; bad "自检 1: 锚点不存在却没判红"; }
_f0=$f; _p0=$p
cell 91 "自检:锚点多重" "local" "local" 1
[[ $f -gt $_f0 ]] && { p=$_p0; f=$_f0; ok "自检 2: 锚点多重 → runner 判红"; } \
                  || { p=$_p0; f=$_f0; bad "自检 2: 锚点多重却没判红"; }

head "收尾"
[[ "$(sha256sum "$REPO/$TARGET" | cut -d' ' -f1)" == "$BASE_SHA" ]] \
  && ok "正式树 $TARGET 逐字节一致" || bad "正式树被改动了"
rm -rf "$(dirname "$WC")"

echo
echo "──────────────────────────────────────────────────────────────"
echo "有效 $p, 失败 $f"
exit $(( f ? 1 : 0 ))
