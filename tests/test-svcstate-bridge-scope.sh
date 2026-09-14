#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 桥接版的**边界**: 它只补一件事 —— 在动手之前把服务前像存进本次快照, 回滚时按前像恢复,
# 并把本次句柄交给迁移子进程。除此之外一个字都不该多改。
#
# 尤其是: 桥接版**不退役 WLOC**、**不推进 iOS 记录格式**、**不删旧能力**、
# **不夹带 main 上的其它改动**。它存在的唯一理由是让"下一跳"有可靠的回滚能力。
#
# 断言都写成"哪一条边界没有被越过", 逐条对着冻结基线(v1.11.15)比。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
BASE="${PDG_BASELINE:-}"
# 没显式给基线就从仓库里取冻结基线那一版。取不到(浅克隆 / 对象被裁掉)就如实跳过对比项,
# 不拿"文件不在"冒充"没改过"。
if [[ -z "$BASE" ]]; then
  _b="$BOX/baseline.sh"
  if git -C "$ROOT" show 242602c17bd92900df81f468aae8c66e18c7a4ff:deploy/bot/pdg.sh > "$_b" 2>/dev/null && [[ -s "$_b" ]]; then
    BASE="$_b"
  fi
fi
pass=0; nfail=0; skip=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
na(){ echo "[SKIP] $1"; skip=$((skip+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

# 别写成 `sed … | grep -q`: grep -q 命中即退出, 上游 sed 吃 SIGPIPE, 在 pipefail 下
# 整条管线返回非 0, "找到了"会被读成"没找到"。一律先落盘再查。
fnfile(){ local o="$BOX/fn-$2.sh"; sed -n "/^$2(){/,/^}/p" "$1" > "$o"; echo "$o"; }

echo "══ 一. 只改了该改的那两个函数 ══"
if [[ -n "$BASE" && -f "$BASE" ]]; then
  changed=""
  while read -r fn; do
    diff -q <(sed -n "/^$fn(){/,/^}/p" "$BASE") <(sed -n "/^$fn(){/,/^}/p" "$PDG") >/dev/null || changed="$changed $fn"
  done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)\{' "$BASE" | sed 's/(){$//')
  exp=" cmd_rollback cmd_update"
  [[ "$changed" == "$exp" ]] && ok "A1: 基线里已有的函数只有 cmd_rollback 与 cmd_update 被改过" \
    || bad "A1: 被改过的函数是「$changed」, 预期「$exp」"
  # 新增的顶层函数必须只有前像那一组
  newfn="$(comm -13 <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)\{' "$BASE" | sed 's/(){$//' | sort) \
                    <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)\{' "$PDG"  | sed 's/(){$//' | sort) | tr '\n' ' ')"
  want="_pdg_kernel_converge _pdg_now_ac _pdg_now_en _pdg_restore_svcstate _pdg_save_svcstate _pdg_svc_known _pdg_svc_q _pdg_svcstate_plan _pdg_svcstate_units _pdg_svcstate_valid "
  [[ "$newfn" == "$want" ]] \
    && ok "A2: 新增函数就是前像那一组(保存/校验/解析/查询/恢复), 没有别的: $newfn" \
    || bad "A2: 新增函数超出范围: $newfn"
else
  na "A: 没给 PDG_BASELINE, 跳过与冻结基线的逐函数对比"
fi

echo
echo "══ 二. 不退役 WLOC、不推进记录格式、不删旧能力 ══"
for pat in 'migrate_wloc_retire' '_retire_caller_gate' '_retire_ios_schema' '_PLAT_RETIRED'; do
  grep -q "$pat" "$PDG" && bad "B: 桥接版里出现了退役相关的 $pat" || ok "B: 没有 $pat(桥接版不做退役)"
done
if [[ -n "$BASE" && -f "$BASE" ]]; then
  for cap in 'mitm_server.py' 'mitm_wloc.py' 'pdg-mitm.service' 'wloc'; do
    b="$(grep -c "$cap" "$BASE")"; c="$(grep -c "$cap" "$PDG")"
    [[ "$b" == "$c" ]] && ok "B: 旧能力 $cap 的出现次数没变($c 处)" || bad "B: $cap 次数从 $b 变成 $c(动了旧能力)"
  done
else na "B: 没给基线, 跳过旧能力计数对比"; fi

echo
echo "══ 三. 恢复只发生在 cmd_rollback 的显式调用处 ══"
n="$(grep -c '_pdg_restore_svcstate "' "$PDG")"
[[ "$n" == 1 ]] && ok "C1: 恢复只有 1 处调用点" || bad "C1: 有 $n 处"
grep -q '_pdg_restore_svcstate' "$(fnfile "$PDG" cmd_rollback)" && ok "C2: 就在 cmd_rollback 里" || bad "C2: 不在 cmd_rollback 里"
for f in $(cd "$ROOT" && ls lib/*.sh 2>/dev/null); do
  grep -q '_pdg_restore_svcstate\|_pdg_save_svcstate' "$ROOT/$f" && bad "C3: 被 source 的 $f 里出现了前像动作" || true
done
ok "C3: lib/*.sh 里没有前像动作(不是常量、不是 unit 生成器、不是后台守护、不是隐式救援钩子)"

echo
echo "══ 四. 存前像排在一切副作用之前; 存不下就中止 ══"
ln_save="$(grep -n 'if ! _pdg_save_svcstate "$snap_dir"; then' "$PDG" | head -1 | cut -d: -f1)"
ln_mig="$(grep -n '^\s*if ! .*bash /usr/local/bin/pdg __migrate' "$PDG" | head -1 | cut -d: -f1)"
ln_inst="$(grep -n 'install -m755 "$REPO_DIR"\|install -m644 "$REPO_DIR"' "$PDG" | head -1 | cut -d: -f1)"
[[ -n "$ln_save" ]] && ok "D1: cmd_update 里有存前像这一步" || bad "D1: 没有"
[[ -n "$ln_mig" && "$ln_save" -lt "$ln_mig" ]] && ok "D2: 排在 __migrate 子进程之前" || bad "D2: 顺序不对($ln_save vs $ln_mig)"
[[ -n "$ln_inst" && "$ln_save" -lt "$ln_inst" ]] && ok "D3: 排在第一处 install 之前(记的确实是动手前的状态)" || bad "D3: 顺序不对($ln_save vs $ln_inst)"
grep -q 'PDG_UPDATE_SVCSTATE="$snap_dir/svcstate.tsv" bash /usr/local/bin/pdg __migrate' "$PDG" \
  && ok "D4: 把本次句柄交给了迁移子进程" || bad "D4: 没交句柄"
{ echo 'set -uo pipefail'
  echo 'c_y(){ echo "$*"; }'
  echo '_pdg_save_svcstate(){ return 1; }'
  echo 'launched=0'
  echo 'bash(){ launched=1; }'
  echo 'guard(){'
  echo "  local snap_dir=\"$BOX/snap\""   # 用本用例的一次性目录, 不写死 /tmp 路径
  sed -n "${ln_save},$((ln_save+2))p" "$PDG"
  echo '  bash /usr/local/bin/pdg __migrate'
  echo '  return 0'
  echo '}'
  echo 'guard; echo "RC=$?"; echo "LAUNCHED=$launched"'
} > "$BOX/guard.sh"
o="$(bash "$BOX/guard.sh" 2>&1)"
grep -q 'RC=1' <<<"$o" && ok "D5: 存前像失败 → 中止" || { bad "D5: 没中止"; echo "$o" | sed 's/^/      /'; }
grep -q 'LAUNCHED=0' <<<"$o" && ok "D6: 且没有启动迁移子进程" || bad "D6: 仍然启动了"

echo
echo "══ 五. 回滚里的恢复不吞掉既有的未恢复项汇总 ══"
rb="$(fnfile "$PDG" cmd_rollback)"
grep -q '_pdg_restore_svcstate "$target" || true' "$rb" \
  && ok "E1: 恢复失败不打断回滚其余步骤(未恢复项由数组带到最后统一报)" || bad "E1: 调用形式不对"
awk '/_pdg_restore_svcstate/{r=NR} /unrestored\[@\]/{u=NR} END{exit !(r&&u&&r<u)}' "$rb" \
  && ok "E2: 恢复排在未恢复项汇总之前(这一轮登记的项目进得了那份报告)" || bad "E2: 顺序不对"
grep -q 'unrestored' "$rb" && ok "E3: cmd_rollback 里确有 unrestored 汇总" || bad "E3: 没有"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail, 跳过 $skip"
[[ "$nfail" == 0 ]]
