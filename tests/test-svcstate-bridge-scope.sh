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
  # 新增的顶层函数必须**恰好**是下面这份允许集合 —— 判据是精确相等, 不是前缀泛放行,
  # 也不从当前候选自动生成期望(那等于让被测对象自己定义"正确")。
  a2_newfn(){   # $1=基线 $2=候选 → 打印"候选相对基线新增的顶层函数名", 空格分隔
    comm -13 <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)\{' "$1" | sed 's/(){$//' | sort) \
             <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)\{' "$2" | sed 's/(){$//' | sort) | tr '\n' ' '
  }
  newfn="$(a2_newfn "$BASE" "$PDG")"
  # 允许集合 = 前像那一组 + **已批准的三个正式入口函数**。
  #
  # 前像那一组(保存/校验/解析/查询/恢复): 桥接版存在的理由本身。其中 _pdg_set_enable_state
  # 是这一组里的一员 —— 自启恢复要分别撤"持久"与"运行时"两层链接(真 systemd 上
  # `enable --runtime` 撤不掉持久链接、`disable` 撤不掉运行时链接), 这段逻辑从
  # _pdg_restore_svcstate 里提出来单独成函数, 两条线共用同一份。它不是新能力。
  #
  # 入口那三个(_update_pin_resolve / _update_pin_still / _pdg_entry_src): 属于 `pdg update
  # --to <版本tag>` 这个已批准的正式入口 —— 解析并固定钉版目标、每次用前复核 tag 没被挪走、
  # 如实打印当前进程执行的是哪一份 pdg.sh。它们同样**不是**退役面, 也不推进任何格式。
  #
  # 这条边界没有被取消: 集合仍然是逐名精确的, 多一个、少一个都判红(见本节末的区分力自检)。
  want="_pdg_entry_src _pdg_kernel_converge _pdg_now_ac _pdg_now_en _pdg_restore_svcstate _pdg_save_svcstate _pdg_set_enable_state _pdg_svc_known _pdg_svc_q _pdg_svcstate_plan _pdg_svcstate_units _pdg_svcstate_valid _update_pin_resolve _update_pin_still "
  [[ "$newfn" == "$want" ]] \
    && ok "A2: 新增函数恰好是「前像那一组 + 已批准的三个入口函数」, 没有别的: $newfn" \
    || bad "A2: 新增函数超出范围: $newfn"

  # ── A2 的区分力自检: 在**自有副本**上造反例, 不改正式产品 ────────────────────
  # 只更新允许集合而不验区分力的话, 万一哪天判据被写松(比如改成前缀匹配), 这一节照样全绿。
  _a2_probe(){ # $1=说明 $2=副本路径 $3=expect(pass|reject)
    local got; got="$(a2_newfn "$BASE" "$2")"
    if [[ "$3" == pass ]]; then
      [[ "$got" == "$want" ]] && ok "  A2-区分力[$1]: 结论不变(仍恰好等于允许集合)" \
                              || bad "  A2-区分力[$1]: 结论变了: $got"
    else
      [[ "$got" != "$want" ]] && ok "  A2-区分力[$1]: **被拒**(实得: $got)" \
                              || bad "  A2-区分力[$1]: 竟然通过了"
    fi
  }
  # ① 多一个未授权函数
  cp "$PDG" "$BOX/a2-extra.sh"; printf '\n_a2_unauthorized_probe(){ :; }\n' >> "$BOX/a2-extra.sh"
  _a2_probe "多一个未授权函数" "$BOX/a2-extra.sh" reject
  # ② 少一个应有函数: **真的把定义整段删掉**。
  #    以前这里是 `sed 's/^_update_pin_still(){/_update_pin_still() {/'` —— 只在括号和大括号
  #    之间加了个空格, 函数其实还在(独立跑 bash -n 与 declare -F 都成功), 那只是在考守卫
  #    那条正则对空格敏不敏感, 不是"少了一个函数"。
  awk 'BEGIN{skip=0}
       /^_update_pin_still\(\)\{/{skip=1; next}
       skip && /^\}$/{skip=0; next}
       !skip{print}' "$PDG" > "$BOX/a2-missing.sh"
  # 删干净了吗 + 其余内容有没有被误删
  _gone=$(grep -c '^_update_pin_still' "$BOX/a2-missing.sh" || true)
  _fnlen=$(sed -n '/^_update_pin_still(){/,/^}$/p' "$PDG" | wc -l)
  _delta=$(( $(wc -l < "$PDG") - $(wc -l < "$BOX/a2-missing.sh") ))
  [[ "$_gone" == 0 ]] && ok "  A2-区分力[删除自检]: 副本里确实**没有** _update_pin_still 的定义了" \
                      || bad "  A2-区分力[删除自检]: 副本里还剩 $_gone 处定义"
  [[ "$_delta" == "$_fnlen" ]] \
    && ok "  A2-区分力[删除自检]: 只少了这一个函数的 $_fnlen 行, 其余未被误删" \
    || bad "  A2-区分力[删除自检]: 行数少了 $_delta, 但该函数只有 $_fnlen 行 —— 误删了别的"
  bash -n "$BOX/a2-missing.sh" 2>/dev/null \
    && ok "  A2-区分力[删除自检]: 删后语法仍有效" || bad "  A2-区分力[删除自检]: 删后语法不过"
  _a2_probe "少一个应有函数(_update_pin_still, 真删除)" "$BOX/a2-missing.sh" reject
  # ③ 无关注释: 结论必须不变
  sed '1a\# 对照: 这行注释不参与任何判定' "$PDG" > "$BOX/a2-comment.sh"
  _a2_probe "无关注释对照" "$BOX/a2-comment.sh" pass
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
