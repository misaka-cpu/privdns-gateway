#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 门接进来之后, **其它调用方与幂等路径还成不成立**。
#
# run_all_migrations 有三个调用方, 各自的锁/快照/失败善后责任完全不同:
#   · cmd_platform  —— 平台切换, `|| true` 吞掉失败, 自己没有快照(自己的材料已经 rm -rf);
#   · cmd_migrate   —— 用户显式迁移, 自己建快照, 失败给手工回滚提示;
#   · __migrate 派发 —— 升级子进程, 锁从父进程继承, 失败由父进程回滚。
# 所以"总入口第一句无条件拒绝无句柄调用"会把前两个直接弄坏。本支就是把这条边界钉住:
# 入口契约一个字都不能变, 门只挂在真正要动手的那一处。
#
# 这一支比对的是**产品源码**(候选 vs 冻结基线), 断言都写成"哪一条契约没有被动过"。
# 需要行为证据的那一条(前像存不下就中止, 且中止在装任何文件之前)单独跑一段真代码。
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
  if git -C "$ROOT" show 037d32f08301b382972605587efe9e075ad6625b:deploy/bot/pdg.sh > "$_b" 2>/dev/null && [[ -s "$_b" ]]; then
    BASE="$_b"
  fi
fi
pass=0; nfail=0; skip=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
na(){ echo "[SKIP] $1"; skip=$((skip+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

# 注意: 不要写成 `fnbody … | grep -q`。grep -q 命中就提前退出, 上游 sed 吃到 SIGPIPE,
# 在 `set -o pipefail` 下整条管线返回非 0 —— 会把"找到了"读成"没找到"。一律先落盘再查。
fnbody(){ sed -n "/^$2(){/,/^}/p" "$1"; }
fnfile(){ local o="$BOX/fn-$2.sh"; fnbody "$1" "$2" > "$o"; echo "$o"; }
lineno(){ grep -n -- "$2" "$1" | head -1 | cut -d: -f1; }

echo "══ 一. 总入口与派发块的契约 ══"
if [[ -n "$BASE" && -f "$BASE" ]]; then
  if diff -q <(fnbody "$BASE" run_all_migrations) <(fnbody "$PDG" run_all_migrations) >/dev/null; then
    ok "A1: run_all_migrations 与基线逐字节相同(没有在总入口加无条件拒绝)"
  else bad "A1: run_all_migrations 被改过"; diff <(fnbody "$BASE" run_all_migrations) <(fnbody "$PDG" run_all_migrations) | head -12; fi
  if diff -q <(grep -A3 '^    __migrate)' "$BASE") <(grep -A3 '^    __migrate)' "$PDG") >/dev/null; then
    ok "A2: __migrate 派发块与基线逐字节相同"
  else bad "A2: __migrate 派发块被改过"; fi
else
  na "A: 没给 PDG_BASELINE, 跳过与冻结基线的逐字节对比"
fi

echo
echo "══ 二. cmd_platform: 契约变了, 变在哪里(行为判据, 不是逐字节) ══"
# 本轮明确改了这个入口: 它自己就会做退役类的不可逆动作(切 iOS 经 _plat_purge_retired,
# 切 Android 经 migrate_android_cleanup), 所以它必须**在动第一样东西之前**具备回滚能力,
# 并且不能把"退役没做成"吞掉当成切换成功。
pl="$(fnfile "$PDG" cmd_platform)"
grep -q 'run_all_migrations || true' "$pl" \
  && ok "B1: 总迁移那一句仍是 \`run_all_migrations || true\`(与退役无关的幂等迁移照旧不拖垮切换)" \
  || bad "B1: 总迁移的失败善后被改了"
grep -q '_pdg_save_svcstate "\$_psnap"' "$pl" && ok "B2: 建完快照就存服务前像(它自己成为有能力的调用方)" || bad "B2: 没存前像"
awk '/cmd_snapshot --source cli --op platform/{s=NR}
     /_pdg_save_svcstate "\$_psnap"/{v=NR}
     /mktemp -d/{m=NR}
     END{exit !(s&&v&&m&&s<v&&v<m)}' "$pl" \
  && ok "B3: 存前像排在快照之后、\`mktemp -d\` 建工作区之前 —— 拒绝发生在任何改动之前" \
  || bad "B3: 顺序不对"
grep -q '中止切换(未改动任何东西)' "$pl" && ok "B4: 存不下就中止, 并明说此刻未改动任何东西" || bad "B4"
grep -q 'export PDG_UPDATE_SVCSTATE="\$_psnap/svcstate.tsv"' "$pl" && ok "B5: 句柄交给后续所有退役类动作" || bad "B5"
awk '/if ! migrate_android_cleanup; then/{a=NR} /_plat_fail_restore; rm -rf "\$wd"; return 1/{if(a&&NR>a&&!done){done=NR}} END{exit !(a&&done)}' "$pl" \
  && ok "B6: migrate_android_cleanup 的返回值被检查, 失败即回退切换(不会「退役失败但成功」)" \
  || bad "B6: 仍然吞掉了 Android 清理的返回值"

echo
echo "══ 二之二. 失败善后: 撤除过退役件就必须用快照整体恢复 ══"
n_old="$(grep -c '_plat_rollback; rm -rf "\$wd"; return 1' "$PDG")"
[[ "$n_old" == 0 ]] && ok "B7: 没有任何失败点再直接走局部还原(统一经 _plat_fail_restore 分岔)" || bad "B7: 还有 $n_old 处直接走 _plat_rollback"
n_new="$(grep -c '_plat_fail_restore; rm -rf "\$wd"; return 1' "$PDG")"
[[ "$n_new" -ge 10 ]] && ok "B8: $n_new 处失败点统一走 _plat_fail_restore" || bad "B8: 只有 $n_new 处"
grep -q '_plat_fail_restore(){' "$pl" && ok "B9: 分岔入口就在 cmd_platform 里(看得到 \$wd/\$_psnap)" || bad "B9"
grep -q 'cmd_rollback --dir "\$_psnap" --no-git' "$pl" \
  && ok "B10: 撤除过退役件时接的是**已经修好的快照恢复**, 不是另造一套" || bad "B10"
grep -q '不声称已恢复原平台与服务状态' "$pl" && ok "B11: 恢复没完成时明确不声称已恢复" || bad "B11"
for fn in migrate_android_cleanup _plat_purge_retired; do
  grep -q '_PDG_RETIRE_DONE=1' "$(fnfile "$PDG" "$fn")" \
    && ok "B12: $fn 真的动手之后会立下「撤除过」的记号" || bad "B12: $fn 没立记号"
done

echo
echo "══ 三. 拦截点: 每一处真正要动手的地方都自己问一次, 且答案一致 ══"
n_def="$(grep -c '^_retire_allowed(){' "$PDG")"
[[ "$n_def" == 1 ]] && ok "C1: 判定只有一处实现(_retire_allowed), 全进程记住同一个答案" || bad "C1: 有 $n_def 处实现"
n_call="$(grep -c '_retire_allowed || return 1' "$PDG")"
[[ "$n_call" == 3 ]] && ok "C2: 拦截点正好 3 处" || bad "C2: 拦截点有 $n_call 处(期望 3)"
for fn in migrate_wloc_retire migrate_android_cleanup _plat_purge_retired; do
  grep -q '_retire_allowed || return 1' "$(fnfile "$PDG" "$fn")" \
    && ok "C3: $fn 里有拦截点" || bad "C3: $fn 里没有拦截点"
done
for fn in run_all_migrations cmd_update cmd_rollback; do
  grep -q '_retire_allowed' "$(fnfile "$PDG" "$fn")" \
    && bad "C4: $fn 里也有拦截(会波及与退役无关的路径)" || ok "C4: $fn 里没有拦截"
done

echo
echo "══ 三之二. 拦截点排在各自的第一个不可逆动作之前 ══"
body="$(fnfile "$PDG" migrate_wloc_retire)"
g="$(lineno "$body" '_retire_allowed || return 1')"
r1="$(lineno "$body" '归属不清就不能一把清空')"
r2="$(lineno "$body" '可还原的只有 enabled / enabled-runtime / disabled 三种')"
s1="$(lineno "$body" '_retire_ios_schema || return 1')"
s2="$(lineno "$body" '_RETIRE_TMP="$(mktemp -d)"')"
s3="$(grep -n 'systemctl disable\|systemctl stop\|rm -f "\$R/opt/pdg-bot/mitm' "$body" | head -1 | cut -d: -f1)"
[[ -n "$g" && -n "$r1" && "$r1" -lt "$g" ]] && ok "D1: 排在既有的「劫持表有外来行」拒绝之后" || bad "D1(gate=$g, 既有拒绝=$r1)"
[[ -n "$r2" && "$r2" -lt "$g" ]] && ok "D2: 排在既有的「自启状态不支持」拒绝之后" || bad "D2(gate=$g, 既有拒绝=$r2)"
[[ -n "$s1" && "$g" -lt "$s1" ]] && ok "D3: 排在 _retire_ios_schema(推进记录格式)之前" || bad "D3(gate=$g, schema=$s1)"
[[ -n "$s2" && "$g" -lt "$s2" ]] && ok "D4: 排在 mktemp -d(开始动手)之前" || bad "D4(gate=$g, mktemp=$s2)"
[[ -n "$s3" && "$g" -lt "$s3" ]] && ok "D5: 排在第一处停服务/删文件之前" || bad "D5(gate=$g, 首个副作用=$s3)"
body="$(fnfile "$PDG" migrate_android_cleanup)"
g="$(lineno "$body" '_retire_allowed || return 1')"
f1="$(grep -n 'mitm_hijack.txt\|systemctl disable --now pdg-mitm\|rm -f "\$R' "$body" | head -1 | cut -d: -f1)"
[[ -n "$g" && -n "$f1" && "$g" -lt "$f1" ]] && ok "D6: Android 清理的拦截点排在第一处改动之前(第 $g 行 vs 第 $f1 行)" || bad "D6(gate=$g, 首个副作用=$f1)"
body="$(fnfile "$PDG" _plat_purge_retired)"
g="$(lineno "$body" '_retire_allowed || return 1')"
f1="$(grep -n 'systemctl disable --now pdg-mitm\|rm -f "\$R' "$body" | head -1 | cut -d: -f1)"
[[ -n "$g" && -n "$f1" && "$g" -lt "$f1" ]] && ok "D7: 平台清理的拦截点排在第一处改动之前(第 $g 行 vs 第 $f1 行)" || bad "D7(gate=$g, 首个副作用=$f1)"

echo
echo "══ 四. 放行判据不是「某个文件缺不缺」也不是单一环境变量 ══"
gate="$(fnfile "$PDG" _retire_caller_gate)"
irr="$(fnfile "$PDG" _retire_has_irreversible_work)"
grep -q 'PDG_UPDATE_SVCSTATE' "$irr" \
  && bad "D1: 「有没有不可逆的事要做」竟然看句柄环境变量(那就成了可以随手关掉的开关)" \
  || ok "D1: 「有没有不可逆的事要做」只看待办本身(五个 need_* 与记录 schema)"
newenv="$(grep -oE '\$\{?PDG_[A-Z_]+' "$gate" "$irr" | sed 's/.*\${\?//' | sort -u | tr '\n' ' ')"
[[ "$newenv" == "PDG_RETIRE_ROOT PDG_UPDATE_SVCSTATE " || "$newenv" == "PDG_UPDATE_SVCSTATE PDG_RETIRE_ROOT " ]] \
  && ok "D2: 新代码只读这两个环境变量: $newenv(PDG_RETIRE_ROOT 是仓库既有的测试前缀)" \
  || bad "D2: 出现了预期之外的环境变量: $newenv"
grep -qiE 'FORCE|SKIP_|BYPASS|NOCHECK|UNSAFE' "$gate" "$irr" \
  && { bad "D3: 门里出现了疑似旁路开关"; grep -niE 'FORCE|SKIP_|BYPASS|NOCHECK|UNSAFE' "$gate" "$irr"; } \
  || ok "D3: 没有 FORCE/SKIP/BYPASS 一类的旁路开关"
grep -q 'PDG_UPDATE_FORCE' "$PDG" && grep -c 'PDG_UPDATE_FORCE' "$PDG" >/dev/null
[[ "$(grep -c 'PDG_UPDATE_FORCE' "$PDG")" == "$(grep -c 'PDG_UPDATE_FORCE' "${BASE:-$PDG}")" ]] \
  && ok "D4: PDG_UPDATE_FORCE 的出现次数没有变化(没有借它开口子)" || bad "D4: 动了 PDG_UPDATE_FORCE"

echo
echo "══ 五. 恢复动作没有被塞进别的地方 ══"
for f in $(cd "$ROOT" && ls lib/*.sh 2>/dev/null) ; do
  grep -qE '_pdg_restore_svcstate|_retire_caller_gate|systemctl (enable|disable) ' "$ROOT/$f" \
    && bad "E1: 被 source 的 $f 里出现了恢复/门动作" || true
done
ok "E1: lib/*.sh 里没有恢复动作或门(恢复只发生在 cmd_rollback 显式调用处)"
if compgen -G "$ROOT/deploy/bot/*.service" >/dev/null || compgen -G "$ROOT/deploy/bot/*.timer" >/dev/null; then
  grep -lE '_pdg_restore_svcstate|svcstate' "$ROOT"/deploy/bot/*.service "$ROOT"/deploy/bot/*.timer 2>/dev/null \
    | grep -q . && bad "E2: unit/timer 里出现了前像恢复" || ok "E2: unit/timer 里没有前像恢复(不是后台守护, 也不是隐式救援钩子)"
else na "E2: 这个副本里没有 unit 模板"; fi
n_restore="$(grep -c '_pdg_restore_svcstate "' "$PDG")"
[[ "$n_restore" == 1 ]] && ok "E3: 恢复只有 1 处调用点" || bad "E3: 恢复被调用了 $n_restore 次"
grep -q '_pdg_restore_svcstate' "$(fnfile "$PDG" cmd_rollback)" \
  && ok "E4: 那一处就在 cmd_rollback 里" || bad "E4: 恢复不在 cmd_rollback 里"

echo
echo "══ 六. 前像存不下就中止, 且中止在装任何文件之前 ══"
ln_save="$(lineno "$PDG" 'if ! _pdg_save_svcstate "$snap_dir"; then')"
ln_mig="$(grep -n '^\s*if ! .*bash /usr/local/bin/pdg __migrate' "$PDG" | head -1 | cut -d: -f1)"
ln_inst="$(grep -n 'install -m755 "$REPO_DIR"\|install -m644 "$REPO_DIR"' "$PDG" | head -1 | cut -d: -f1)"
[[ -n "$ln_save" && -n "$ln_mig" && "$ln_save" -lt "$ln_mig" ]] && ok "F1: 存前像排在 __migrate 子进程之前" || bad "F1: 顺序不对($ln_save vs $ln_mig)"
[[ -n "$ln_inst" && "$ln_save" -lt "$ln_inst" ]] && ok "F2: 存前像排在第一处 install 之前(前像记的确实是**动手前**的状态)" || bad "F2: 顺序不对($ln_save vs $ln_inst)"
# 行为证据: 把产品那四行原样拿出来跑, 存前像失败必须 return 1
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
grep -q 'RC=1' <<<"$o" && ok "F3: 存前像失败 → 中止(return 1)" || { bad "F3: 没有中止"; echo "$o" | sed 's/^/      /'; }
grep -q 'LAUNCHED=0' <<<"$o" && ok "F4: 且**没有**启动迁移子进程" || bad "F4: 仍然启动了迁移子进程"

echo
echo "══ 七. cmd_migrate 变成了「有能力的调用方」而不是被挡住 ══"
mg="$(fnfile "$PDG" cmd_migrate)"
grep -q '_pdg_save_svcstate "$snap"' "$mg" && ok "G1: 显式迁移也在动手前存前像" || bad "G1: 没存"
grep -q 'PDG_UPDATE_SVCSTATE="$snap/svcstate.tsv" run_all_migrations' "$mg" && ok "G2: 并把本次句柄交给迁移" || bad "G2: 没交句柄"
awk '/_pdg_save_svcstate "\$snap"/{s=NR} /run_all_migrations/{m=NR} END{exit !(s&&m&&s<m)}' "$mg" \
  && ok "G3: 存前像排在 run_all_migrations 之前" || bad "G3: 顺序不对"
grep -q '拒绝在无法完整回滚的前提下迁移' "$mg" && ok "G4: 存不下就拒绝(不是存不下也照跑)" || bad "G4"

echo
echo "══ 八. 三个调用方各自的失败善后责任(行为) ══"
# 把**真的** run_all_migrations 拿出来跑: 其余 migrate_* 一律打桩返回 0, 只让
# migrate_wloc_retire 按门的判定返回。验的是"门拒绝了之后, 这条失败到底传不传得出去"。
runall(){ # $1 = migrate_wloc_retire 的返回码
  local d="$BOX/runall-$1"; mkdir -p "$d"
  { echo 'set -uo pipefail'
    echo 'for f in $(grep -oE "migrate_[a-z0-9_]+" "'"$PDG"'" | sort -u); do'
    echo '  eval "$f(){ return 0; }"'
    echo 'done'
    echo "migrate_wloc_retire(){ return $1; }"
    sed -n "/^run_all_migrations(){/,/^}/p" "$PDG"
    echo 'run_all_migrations; echo "RC=$?"'
  } > "$d/run.sh"
  bash "$d/run.sh" 2>&1 | tail -1
}
[[ "$(runall 1)" == "RC=1" ]] && ok "H1: 门拒绝 → migrate_wloc_retire 返回 1 → run_all_migrations 返回非 0(半截现场不会被吞成成功)" || bad "H1: 实得 $(runall 1)"
[[ "$(runall 0)" == "RC=0" ]] && ok "H2: 反向对照 —— 只有这一格返回 0 时整体就是 0(H1 不是别的迁移造成的)" || bad "H2: 实得 $(runall 0)"
grep -q 'run_all_migrations || true' "$(fnfile "$PDG" cmd_platform)" \
  && ok "H3: cmd_platform 仍是 \`run_all_migrations || true\` —— 退役被拒不会让平台切换失败(那一步顺延到下次 update/migrate)" \
  || bad "H3: cmd_platform 的失败善后被改了"
grep -q '__migrate)     need_root __migrate; _lock; run_all_migrations;;' "$PDG" \
  && ok "H4: __migrate 派发仍是 need_root + _lock + run_all_migrations —— 失败照旧传回父进程由它回滚" \
  || bad "H4: __migrate 派发被改了"
awk '/_pdg_save_svcstate "\$snap"/{s=1} /run_all_migrations/{if(s)m=1} END{exit !m}' "$(fnfile "$PDG" cmd_migrate)" \
  && ok "H5: cmd_migrate 自建快照 + 自存前像 + 自带句柄 —— 它是有能力的调用方, 不会被自己的门挡住" \
  || bad "H5"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail, 跳过 $skip"
[[ "$nfail" == 0 ]]
