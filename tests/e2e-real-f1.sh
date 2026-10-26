#!/usr/bin/env bash
# shellcheck disable=SC2034  # 全文件: 大量全局变量由运行时按标记抽进来的共享函数(S-1 / ③ / ② / ⑤ 原文)按名字读取, 静态看不到
# ────────────────────────────────────────────────────────────────────────────
# 真实验收 F-1: **已安装桥接 → 新候选的首次升级中, pdg-dotwitness 遇到"5399 被别的进程占"这一类真实启动失败**。
#     bash /usr/local/bin/pdg update --to <候选的合成 tag>(同一 job 里 ② 刚装上的现役桥接 CLI)
# 构造(研究与替身实测见 Q13 的 F1-RESEARCH / PROBE-SETTLE): 调用前装一个**产品之外**的 runtime unit f1-occupant.service,
#   PartOf=mosdns.service、Before=pdg-dotwitness.service、Type=notify; 它的程序(tests/helpers/f1-occupant.py)启动时只在
#   "接管表 /etc/mosdns/rules/mitm_hijack.txt 存在且为空"时才先绑 UDP 127.0.0.1:5399。候选里清空接管表的只有 migrate_wloc_retire
#   (紧接着重启 mosdns)与 migrate_android_cleanup, 两者都排在 migrate_dotwitness 之后; 于是 WLOC 退役那次 mosdns 重启经 PartOf 传播时,
#   占用者先占住端口, pdg-dotwitness 这次启动绑不上(exit 4)。不改产品任何文件, 不给 pdg-dotwitness 加 drop-in, 不靠时间竞态。
# 两个变体(PDG_F1_VARIANT):
#   a  调用前做一次 ③ 的准备阶段静置(r3_quiesce 原文, 303 s), 让此前的启动移出 300 s 窗口 ⇒ 目标是新步骤的"非 start-limit-hit"分支;
#   b  不静置(S-1 的条件) ⇒ 目标是"观察到启动限额命中 → 定向恢复一次 → 端口仍被占 → 恢复后确认未就绪"分支。
# 前像: 同一 job、同一 runner 上一步原样跑完的 tests/e2e-real-bridge-hop.sh(②); 门与 S-1 相同, 另加占用者的两道门(18 / 19)。
# 受监视服务: ⑤ 的 SVC_WATCH 去掉 pdg-dotwitness(恰这一项); 运行态判据 = ③ r3_post_runtime 原文只去掉 pdg-dotwitness 的 active 检查 ——
#   pdg-dotwitness 按构造本来就该起不来, 它由本支的分层结算单独处理(服务是否健康 与 产品是否守政策 分开判定、分开报告)。
# 不做: 由验收器 reset-failed / start / restart / stop pdg-dotwitness、改启动限额、在 systemctl 外加包装、直接运行 _dw_settle、同一 runner 上重试。
# 动作次数没有直接记录: journal 只给事件, 显式启动 / 自动重启 / 重启任务按消息序列**推定**; 产品报告只是自述。
# 只证明"外来进程占 5399"这一类; 不外推到"进程起不来""缺配置", 也不外推到别的 systemd 版本或别的前像。只许在一次性 GitHub runner 上跑。
# ────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

_hard(){ echo "[HARD-STOP] $1" >&2
  if declare -F r3_count_read >/dev/null && [[ -n "${R3_COUNT:-}" ]] && r3_count_read; then echo "升级调用次数(计数文件) = $R3_VAL" >&2
  else echo "升级调用次数: 计数还没建或读不出${R3_WHY:+($R3_WHY)}" >&2; fi
  exit 1; }
[[ "${PDG_REAL_MIGRATION_OK:-}" == 1 ]] || _hard "缺 PDG_REAL_MIGRATION_OK=1 —— 这支会真的改本机 systemd 与 /etc。"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || _hard "不在 GitHub Actions 里 —— 拒绝在开发机/生产机上执行。"
[[ "${RUNNER_OS:-}" == "Linux" ]] || _hard "RUNNER_OS=${RUNNER_OS:-<空>}, 只支持 Linux runner。"
[[ "$(id -u)" == 0 ]] || _hard "需要 root。"
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || _hard "需要 PDG_E2E_ISOLATED=1。"
F1_VARIANT="${PDG_F1_VARIANT:-}"
[[ "$F1_VARIANT" == a || "$F1_VARIANT" == b ]] || _hard "PDG_F1_VARIANT 必须是 a 或 b(现在是 [${F1_VARIANT}])"
EVID="${PDG_F1_EVID:-}"
[[ "$EVID" == /* ]] || _hard "必须显式给出证据目录的绝对路径(PDG_F1_EVID)"
{ mkdir -p "$EVID" && chmod 700 "$EVID"; } 2>/dev/null || _hard "证据目录 $EVID 建不出来 —— 调用计数无处可落, 不调用"

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
F1_TMP="$(mktemp -d "${TMPDIR:-/tmp}/f1.XXXXXX")" || _hard "建不出本支临时目录"
R3_TMP="$F1_TMP"; E2E_TMP="$F1_TMP"; S1_TMP="$F1_TMP"   # 被抽取的函数按 $R3_TMP / $E2E_TMP / $S1_TMP 落临时物 —— 落在本支自己的目录
export E2E_TMP
R3_SRC="$E2E_ROOT/tests/e2e-real-retire-hop.sh"; HOP2_SRC="$E2E_ROOT/tests/e2e-real-bridge-hop.sh"; PLAT_SRC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
S1_SRC="$E2E_ROOT/tests/e2e-real-first-upgrade.sh"

# >>> PDG-EXTRACT-BEGIN f1_seed
# 引导的引导(与 S-1 的 s1_seed 同文, 只换函数名; 契约核): 先把 ③ / S-1 的块原文取出来, 之后一律用 ③ 的 r3_bootstrap 与 ② 的抽取器按标记抽。
f1_seed(){   # $1=名字 $2=来源 → 打印标记之间的原文; 标记不是唯一成对或之间为空 ⇒ 非 0
  local n="$1" src="$2" b e
  [[ -f "$src" ]] || { echo "引导: 找不到 $src" >&2; return 2; }
  [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] \
    || { echo "引导: $n 的标记不是唯一成对" >&2; return 1; }
  b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
  e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
  (( e - b >= 2 )) || { echo "引导: $n 的标记之间是空的" >&2; return 1; }
  sed -n "$((b+1)),$((e-1))p" "$src"
}
# <<< PDG-EXTRACT-END f1_seed
# >>> PDG-EXTRACT-BEGIN f1_lists
# 本支在 S-1 的抽取表(s1_lists 原文)之外另取的共享输入。F1_FORBID 里的函数不抽进来、不得调用;
# r3_quiesce 及其 r3_q_* 在 S-1 的不得调用表里, 本支要它(只在变体 a 调用一次), 所以运行时核的是本支自己的不得调用表。
F1_S1_FNS=(s1_dw s1_journal s1_report s1_precall)
F1_S1_CONST=s1_r3_const; F1_S1_INLINE=s1_r3_inline
F1_R3_EXTRA=(r3_quiesce)
F1_FORBID=(r3_gated_invoke s1_gated_invoke s1_after_call s1_settle s1_verdict_say s1_dw_post _dw_settle)
# <<< PDG-EXTRACT-END f1_lists

# 调用计数最先: 任何门之前先落 0 并读回(③ r3_count 原文, 计数文件换成本支自己的)
f1_seed r3_count "$R3_SRC" > "$F1_TMP/r3count.sh" && bash -n "$F1_TMP/r3count.sh" || _hard "调用计数块抽取失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$F1_TMP/r3count.sh"
R3_COUNT="$EVID/00-f1-invoke-count.txt"
r3_count_init || _hard "调用计数初始化失败: $R3_WHY —— 不调用"
f1_seed s1_lists "$S1_SRC" > "$F1_TMP/s1lists.sh" && bash -n "$F1_TMP/s1lists.sh" || _hard "S-1 抽取表取不到 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$F1_TMP/s1lists.sh"
f1_seed r3_bootstrap "$R3_SRC" > "$F1_TMP/boot.sh" && bash -n "$F1_TMP/boot.sh" || _hard "③ 抽取器引导失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$F1_TMP/boot.sh"
r3_bootstrap "$HOP2_SRC" "$F1_TMP/extractor.sh" extract_marked_fns extract_marked_decls || _hard "② 抽取器引导失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$F1_TMP/extractor.sh"
extract_marked_fns "$PLAT_SRC" "$F1_TMP/plat-fns.sh" "${S1_PLAT_FNS[@]}" || _hard "⑤ 函数抽取没通过 —— 还没碰任何服务"
extract_marked_decls "$PLAT_SRC" "$F1_TMP/plat-deps.sh" "${S1_PLAT_DECLS[@]}" || _hard "⑤ 依赖抽取没通过"
extract_marked_fns "$HOP2_SRC" "$F1_TMP/hop2-fns.sh" "${S1_HOP2_FNS[@]}" || _hard "② 函数抽取没通过 —— 还没碰任何服务"
r3_bootstrap "$R3_SRC" "$F1_TMP/r3fns.sh" "${S1_R3_BLOCKS[@]}" "${F1_R3_EXTRA[@]}" || _hard "③ 判据段抽取没通过 —— 还没碰任何服务"
: > "$F1_TMP/s1fns.sh" || _hard "建不出 S-1 函数抽取文件"
for _n in "${F1_S1_FNS[@]}"; do f1_seed "$_n" "$S1_SRC" >> "$F1_TMP/s1fns.sh" || _hard "S-1 的 $_n 抽取失败 —— 还没碰任何服务"; done
f1_seed "$F1_S1_CONST" "$S1_SRC" > "$F1_TMP/s1const.sh" || _hard "S-1 的环境常量块抽取失败"
f1_seed "$F1_S1_INLINE" "$S1_SRC" > "$F1_TMP/s1inline.sh" || _hard "S-1 的内联判据块抽取失败"
for _f in s1fns s1const s1inline; do bash -n "$F1_TMP/$_f.sh" || _hard "抽出的 $_f 语法不过"; done
# shellcheck source=/dev/null
source "$F1_TMP/plat-fns.sh"; source "$F1_TMP/plat-deps.sh"; source "$F1_TMP/hop2-fns.sh"; source "$F1_TMP/r3fns.sh"; source "$F1_TMP/s1fns.sh"
for _f in "${F1_FORBID[@]}"; do declare -F "$_f" >/dev/null && _hard "不得调用的 $_f 被抽进来了 —— 停在一切服务动作之前"; done
declare -F r3_quiesce >/dev/null || _hard "r3_quiesce 没抽到 —— 变体 a 无从静置"

# >>> PDG-EXTRACT-BEGIN f1_watch
f1_watch(){   # 受监视服务 = ⑤ 的 SVC_WATCH 恰去掉 pdg-dotwitness 这一项 → 0 / 1 原表里它不是恰好一项(不改表)
  local u n=0
  local -a w=()
  for u in "${SVC_WATCH[@]}"; do if [[ "$u" == pdg-dotwitness ]]; then n=$((n+1)); else w+=("$u"); fi; done
  (( n == 1 )) || return 1
  SVC_WATCH=("${w[@]}")
}
# <<< PDG-EXTRACT-END f1_watch
f1_watch || _hard "⑤ 的受监视服务表里 pdg-dotwitness 不是恰好一项"
JBOUND_TAG="pdg-e2e-jbound-f1"
J_ERR=""
E2E_NOTRUN=0

# ── 本支自己的读取器、门与判据(契约按标记抽出来用受控输入驱动) ─────────────────────
# >>> PDG-EXTRACT-BEGIN f1_occ
F1_OCC_UNIT=f1-occupant.service; F1_OCC_FILE=/run/systemd/system/f1-occupant.service
F1_OCC_PY="$E2E_ROOT/tests/helpers/f1-occupant.py"; F1_OCC_LOG="$EVID/10-f1-occupant.log"
F1_OCC_N_IDLE=0; F1_OCC_N_HELD=0; F1_OCC_N_HF=0; F1_OCC_N_AU=0; F1_OCC_HELD1=""; F1_OCC_HELD_PID=""   # 读到记录之前的初值(set -u 下不留未定义)
f1_occ_text(){   # 占用者 unit 的全文(契约逐行核)。读 HIJ / F1_OCC_PY / F1_OCC_LOG
  printf '%s\n' "[Unit]" \
    "Description=F-1 acceptance occupant of 127.0.0.1:5399 (test fixture, not part of the product)" \
    "PartOf=mosdns.service" "Before=pdg-dotwitness.service" "" \
    "[Service]" "Type=notify" "NotifyAccess=main" "TimeoutStartSec=20" \
    "ExecStart=/usr/bin/python3 $F1_OCC_PY --port 5399 --arm $HIJ --log $F1_OCC_LOG"
}
f1_occ_log(){   # 读占用者记录 → 0 读出且每行都认得(F1_OCC_N_IDLE / _HELD / _HF / _AU, F1_OCC_HELD1 = 第一次 held 的纳秒, F1_OCC_HELD_PID) / 2 读不了或有不认的行(F1_WHY)
  local raw rc l
  F1_OCC_N_IDLE=0; F1_OCC_N_HELD=0; F1_OCC_N_HF=0; F1_OCC_N_AU=0; F1_OCC_HELD1=""; F1_OCC_HELD_PID=""; F1_WHY=""
  raw="$(cat -- "$F1_OCC_LOG" 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then F1_WHY="占用者记录 $F1_OCC_LOG 读不了(cat 退出 $rc; 已输出的不采信)"; return 2; fi
  while IFS= read -r l; do
    [[ -n "$l" ]] || { F1_WHY="占用者记录里有空行"; return 2; }
    if [[ "$l" =~ ^([1-9][0-9]*)\ idle\ pid=[0-9]+$ ]]; then F1_OCC_N_IDLE=$((F1_OCC_N_IDLE+1))
    elif [[ "$l" =~ ^([1-9][0-9]*)\ held\ pid=([0-9]+)$ ]]; then
      F1_OCC_N_HELD=$((F1_OCC_N_HELD+1))
      [[ -n "$F1_OCC_HELD1" ]] || { F1_OCC_HELD1="${BASH_REMATCH[1]}"; F1_OCC_HELD_PID="${BASH_REMATCH[2]}"; }
    elif [[ "$l" =~ ^[1-9][0-9]*\ hold-failed\ errno=[0-9]+\ pid=[0-9]+$ ]]; then F1_OCC_N_HF=$((F1_OCC_N_HF+1))
    elif [[ "$l" =~ ^[1-9][0-9]*\ arm-unreadable\ errno=[0-9]+\ pid=[0-9]+$ ]]; then F1_OCC_N_AU=$((F1_OCC_N_AU+1))
    else F1_WHY="占用者记录里有不认的行 [${l:0:60}]"; return 2; fi
  done <<< "$raw"
  return 0
}
f1_occ_say(){ printf 'idle %s / held %s / hold-failed %s / arm-unreadable %s' "$F1_OCC_N_IDLE" "$F1_OCC_N_HELD" "$F1_OCC_N_HF" "$F1_OCC_N_AU"; }
f1_occ_install(){   # 门 18 → 0 成立 / 1 不成立或观测无效(逐项打印); unit 原文与读数进 10-f1-occupant-*.txt
  local st=0 rc r a
  if [[ -e "$F1_OCC_FILE" ]]; then echo "  O $F1_OCC_FILE 已经存在 —— 不覆盖, 前提不成立"; return 1; fi
  if [[ ! -s "$HIJ" ]]; then echo "  O 接管表 $HIJ 不存在或为空 —— 占用者会一装上就占端口, 前提不成立"; return 1; fi
  if [[ ! -f "$F1_OCC_PY" ]]; then echo "  O 找不到占用者程序 $F1_OCC_PY"; return 1; fi
  if [[ -e "$F1_OCC_LOG" ]]; then echo "  O 占用者记录 $F1_OCC_LOG 已经存在 —— 不是本次的干净起点"; return 1; fi
  if ! { f1_occ_text > "$F1_OCC_FILE" && chmod 644 "$F1_OCC_FILE"; } 2>/dev/null; then echo "  O 写不出 $F1_OCC_FILE"; rm -f -- "$F1_OCC_FILE"; return 1; fi
  cp -- "$F1_OCC_FILE" "$EVID/10-f1-occupant-unit.txt" 2>/dev/null || { echo "  O unit 原文没能留进证据目录"; st=1; }
  systemctl daemon-reload >/dev/null 2>&1; rc=$?
  if (( rc != 0 )); then echo "  O daemon-reload 退出 $rc"; return 1; fi
  systemctl start "$F1_OCC_UNIT" >/dev/null 2>&1; rc=$?
  if (( rc != 0 )); then echo "  O 占用者启动失败(start 退出 $rc)"; return 1; fi
  a="$(systemctl is-active "$F1_OCC_UNIT" 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ "$a" != active ]]; then echo "  O 占用者装出后不是 active([$a], 退出 $rc)"; return 1; fi
  if f1_occ_log; then
    if (( F1_OCC_N_IDLE == 1 && F1_OCC_N_HELD == 0 && F1_OCC_N_HF == 0 && F1_OCC_N_AU == 0 )); then echo "  O 占用者已装出且 active, 记录恰 1 条 idle(没有占端口)"
    else echo "  O 占用者记录不是恰 1 条 idle: $(f1_occ_say)"; st=1; fi
  else echo "  O 占用者记录观测无效: $F1_WHY"; st=1; fi
  if s1_dw_show; then
    s1_listen_owner; r=$?
    if (( r == 0 )); then echo "  O 127.0.0.1:5399 的监听者全部在 pdg-dotwitness 的 cgroup($S1_LISTEN)"
    else echo "  O 5399 监听者核对不成立或观测无效(rc=$r): $S1_WHY"; st=1; fi
  else echo "  O pdg-dotwitness 读数观测无效: $S1_WHY"; st=1; fi
  if systemctl cat "$F1_OCC_UNIT" > "$EVID/10-f1-occupant-cat.txt" 2>/dev/null; then :; else echo "  O systemctl cat $F1_OCC_UNIT 没取得"; st=1; fi
  return "$st"
}
f1_occ_check(){   # 门 19(紧挨调用前观测之前)→ 0 成立 / 1 不成立或观测无效
  local a rc st=0
  a="$(systemctl is-active "$F1_OCC_UNIT" 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ "$a" != active ]]; then echo "  O 调用前占用者不是 active([$a], 退出 $rc)"; st=1; fi
  if f1_occ_log; then
    if (( F1_OCC_N_IDLE == 1 && F1_OCC_N_HELD == 0 && F1_OCC_N_HF == 0 && F1_OCC_N_AU == 0 )); then echo "  O 调用前占用者记录仍是恰 1 条 idle(装出之后没被重启过, 没占端口)"
    else echo "  O 调用前占用者记录不是恰 1 条 idle: $(f1_occ_say)"; st=1; fi
  else echo "  O 调用前占用者记录观测无效: $F1_WHY"; st=1; fi
  if [[ -s "$HIJ" ]]; then echo "  O 接管表仍非空(占用者不会被提前激活)"; else echo "  O 接管表不存在或为空 —— 前提不成立"; st=1; fi
  return "$st"
}
# <<< PDG-EXTRACT-END f1_occ
# >>> PDG-EXTRACT-BEGIN f1_gated
f1_gated_invoke(){   # 门全过、调用前观测全部取得、计数恰为 0 才调用。返回(10–19 都**没有**调用):
                     #   10=② 结果门 11=桥接身份门 15=DNS 仪器 18=占用者装出门 16=准备阶段静置(只有变体 a) 12=运行态 / WLOC 前像门
                     #   17=pdg-dotwitness 调用前门 19=占用者调用前门 13=调用前观测 14=计数读不出 / 不为 0 / 单调时钟 / 退出码留档不可用; 0=已调用
  local g
  r3_real2_gate "$R3_REAL2_LOG"; g=$?
  echo "  R2 $R3_WHY"
  (( g == 0 )) || return 10
  r3_bridge_identity_gate; g=$?
  (( g == 0 )) || return 11
  r3_dns_instrument || return 15
  f1_occ_install || return 18
  if [[ "$F1_VARIANT" == a ]]; then r3_quiesce || return 16; fi
  r3_runtime_gate || return 12
  s1_dw_precall || return 17
  f1_occ_check || return 19
  r3_precapture || return 13
  if ! r3_count_read; then echo "  调用前停止: 调用计数读不出($R3_WHY)"; return 14; fi
  if [[ "$R3_VAL" != 0 ]]; then echo "  调用前停止: 调用计数已是 $R3_VAL(只许调用一次)"; return 14; fi
  if ! F1_T0="$(s1_mono)"; then echo "  调用前停止: 单调时钟读不了"; return 14; fi
  r3_invoke || { echo "  调用前停止: $R3_WHY"; return 14; }
  F1_T1="$(s1_mono)" || F1_T1=""
  return 0
}
# <<< PDG-EXTRACT-END f1_gated
# >>> PDG-EXTRACT-BEGIN f1_post_runtime
# ③ r3_post_runtime 原文逐行照抄, 只改两处: 函数名; `for u in pdg-dotwitness pdg-health.timer; do` → `for u in pdg-health.timer; do`(契约逐行核)。
# shellcheck disable=SC2043  # 照抄 ③ 的循环, 去掉 pdg-dotwitness 之后只剩一项; 有意保留循环写法, 便于逐行对照原文
f1_post_runtime(){   # 调用后 ③-4: 运行 / 自启态与真实功能; 观测无效或命令失败 ⇒ 本项判失败 / 未取得, 不输出功能成立
  local u
  r3_stable_assert mosdns      running "③-4 运行态: mosdns 持续运行" 5
  r3_stable_assert mihomo      running "③-4 运行态: mihomo 持续运行" 5
  r3_stable_assert pdg-probe81 running "③-4 运行态: pdg-probe81 持续运行" 5
  for u in mosdns mihomo pdg-probe81; do
    if r3_unit_q enabled "$u"; then [[ "$R3_VAL" == enabled ]] && ok "③-4 自启态: $u = enabled" || bad "③-4 自启态: $u = $R3_VAL"
    else bad "③-4 自启态观测无效: $R3_WHY"; fi
  done
  for u in pdg-health.timer; do
    if r3_unit_q active "$u"; then [[ "$R3_VAL" == active ]] && ok "③-4 $u 仍 active" || bad "③-4 $u = $R3_VAL"
    else bad "③-4 运行态观测无效: $R3_WHY"; fi
  done
  if r3_http_code http://127.0.0.1:81/; then
    [[ "$R3_VAL" == 200 ]] && ok "③-4 F1 实际功能: :81 HTTP 200" || bad "③-4 F1 :81 查询成功但状态码是 $R3_VAL(要 200)"
  else bad "③-4 F1 功能观测未取得: $R3_WHY —— 不算通过"; fi
  r3_dns_phase post                        # 先核仪器条件仍成立, 再判 W→U / C→U / P→H 与各自来源; 条件或观测失效 ⇒ 该功能结论未取得
}
# <<< PDG-EXTRACT-END f1_post_runtime
# >>> PDG-EXTRACT-BEGIN f1_classify
f1_rep_form(){   # $1=s1_report 的归类留证文件 → 0 取得(F1_FORM F1_R_ACT F1_R_SUB F1_R_RES F1_R_PIDS) / 2 读不了或结构不对(F1_WHY)
  local out rc k v l seen=" "
  F1_FORM=""; F1_R_ACT=""; F1_R_SUB=""; F1_R_RES=""; F1_R_PIDS=""; F1_WHY=""
  out="$(python3 - "$1" 2>/dev/null <<'PY'
import ast, re, sys
cls, lines = None, []
for raw in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if raw.startswith("CLASS="):
        if cls is not None:
            sys.exit(3)
        cls = raw[6:]
    elif raw.startswith("LINE\t"):
        p = raw.split("\t", 2)
        if len(p) != 3:
            sys.exit(3)
        lines.append((p[1], ast.literal_eval(p[2])))
if cls is None:
    sys.exit(3)
form, act, sub, res, pids = cls, "", "", "", ""
def tail(ln):
    m = re.fullmatch("\x1b\\[1;3([23])m(.*)\x1b\\[0m", ln, re.S)
    if not m:
        return None
    pre = "  DoT 证据端: " if m.group(1) == "2" else "  ⚠️  DoT 证据端: "
    return m.group(2)[len(pre):] if m.group(2).startswith(pre) else None
def state(s):
    m = re.search(r"ActiveState=([a-z-]+), SubState=([a-z-]+), Result=([a-z-]+)", s)
    return m.groups() if m else ("", "", "")
END = r", 本步不重置、不启动。查看 journalctl -u pdg-dotwitness。"
if len(lines) == 1 and lines[0][0] == cls:
    s = tail(lines[0][1]) or ""
    if cls == "NOTREADY":
        m1 = re.fullmatch(r"未就绪\(ActiveState=([a-z-]+), SubState=([a-z-]+), Result=([a-z-]+)\)" + END, s)
        m2 = re.fullmatch(r"未就绪\(观察期内没能确认就绪; (.*)\)" + END, s)
        if m1:
            form, (act, sub, res) = "N6430", m1.groups()
        elif m2:
            form, (act, sub, res) = "N6407", state(m2.group(1))
        else:
            form = "NOTREADY_OTHER"
    elif cls == "FOREIGN":
        m = re.fullmatch(r"服务 active, 但 127\.0\.0\.1:5399 由别的进程持有\(unit: .*; 监听者:(.*)\); 本步不处理。", s)
        form = "FOREIGN" if m else "FOREIGN_OTHER"
        if m:
            pids = " ".join(re.findall(r"(?:^|\s)(\d+):/", m.group(1)))
    elif cls == "SLH_POST_NOTREADY":
        m = re.search(r"但恢复后确认未就绪\((.*)\); 不再重试。", s)
        form = "SLHNR"
        if m:
            act, sub, res = state(m.group(1))
print("FORM=%s" % form); print("ACT=%s" % act); print("SUB=%s" % sub); print("RES=%s" % res); print("PIDS=%s" % pids)
PY
)"; rc=$?
  if (( rc != 0 )); then F1_WHY="报告细分失败(python 退出 $rc; 已输出的不采信)"; return 2; fi
  while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    if [[ "$seen" == *" $k "* ]]; then F1_WHY="报告细分字段 $k 重复"; F1_FORM=""; return 2; fi
    seen="$seen$k "
    case "$k" in FORM) F1_FORM="$v";; ACT) F1_R_ACT="$v";; SUB) F1_R_SUB="$v";; RES) F1_R_RES="$v";; PIDS) F1_R_PIDS="$v";;
                 *) F1_WHY="报告细分多出字段 $k"; F1_FORM=""; return 2;; esac
  done <<< "$out"
  for k in FORM ACT SUB RES PIDS; do [[ "$seen" == *" $k "* ]] || { F1_WHY="报告细分缺字段 $k"; F1_FORM=""; return 2; }; done
  [[ -n "$F1_FORM" ]] || { F1_WHY="报告细分没有给出句式"; return 2; }
  return 0
}
f1_jclass(){   # $1=pdg-dotwitness 窗口 TSV(s1_jwin 原文产出) $2=占用者第一次 held 的纳秒(可空)→ 0 取得(F1_J_*) / 2 结构不对(F1_WHY)
               # 启动事件按它前面最近的两条管理器事件(不计 Starting)推定来源:
               #   Scheduled restart → Stopped, 或紧挨 Scheduled restart ⇒ 自动重启;
               #   Stopping → Stopped, 或失败类 → Stopped ⇒ 重启任务(产品或 PartOf 传播, 后者是对已失败 / 等待自动重启的 unit 发的重启);
               #   紧挨失败 / 限额 / 主进程退出 / Failed to start / Deactivated ⇒ 显式启动; 其它(含窗口里第一条就是启动)⇒ 归不了类。
  local out rc k v l seen=" "
  F1_WHY=""
  out="$(python3 - "$1" "${2:-}" 2>/dev/null <<'PY'
import re, sys
held = sys.argv[2]
held_us = int(held) // 1000 if re.fullmatch(r"[1-9][0-9]*", held or "") else None
MGR = {"start", "stopping", "stopped", "deactivated", "slh_repeat", "slh_result", "fail_result", "fail_start", "main_exit", "sched_restart"}
hist, n = [], {"start": 0, "auto": 0, "jobr": 0, "expl": 0, "unk": 0, "expl_after_slh": 0, "slh": 0, "bf": 0, "fail_after_expl": 0}
first_bf = None; seen_slh = False; seen_expl = False; fails = []
for raw in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if not raw:
        continue
    f = raw.split("\t")
    if len(f) != 10:
        sys.exit(3)
    _, _, mono, attr, unit, pid, _, _, kind, msg = f
    if attr != "target":
        continue
    if pid != "1":
        if re.fullmatch(r"dotwitness: bind failed \([A-Za-z]+\)", msg):
            n["bf"] += 1
            if first_bf is None:
                if not re.fullmatch(r"[0-9]+", mono):
                    sys.exit(4)
                first_bf = int(mono)
        continue
    if kind not in MGR:
        continue
    if kind in ("slh_repeat", "slh_result"):
        n["slh"] += 1; seen_slh = True
    if kind == "fail_result":
        m = re.search(r"Failed with result '([a-z-]+)'", msg)
        if m:
            fails.append(m.group(1))
        if seen_expl:
            n["fail_after_expl"] += 1
    if kind == "start":
        n["start"] += 1
        p1 = hist[-1] if hist else None
        p2 = hist[-2] if len(hist) >= 2 else None
        FAILK = ("fail_result", "slh_result", "fail_start", "slh_repeat", "main_exit", "deactivated")
        if (p1 == "stopped" and p2 == "sched_restart") or p1 == "sched_restart":
            n["auto"] += 1
        elif p1 == "stopped" and (p2 == "stopping" or p2 in FAILK):
            n["jobr"] += 1
        elif p1 in FAILK:
            n["expl"] += 1; seen_expl = True
            if seen_slh:
                n["expl_after_slh"] += 1
        else:
            n["unk"] += 1
    hist.append(kind)
after = "na" if (first_bf is None or held_us is None) else ("yes" if first_bf > held_us else "no")
for k in ("start", "auto", "jobr", "expl", "unk", "expl_after_slh", "slh", "bf", "fail_after_expl"):
    print("%s=%d" % (k.upper(), n[k]))
print("BF_AFTER_HELD=%s" % after)
print("FAILRES=%s" % ",".join(sorted(set(fails))))
PY
)"; rc=$?
  if (( rc != 0 )); then F1_WHY="窗口归类失败(python 退出 $rc: 3 = 列数不对, 4 = 单调时间不是数; 已输出的不采信)"; return 2; fi
  F1_J_START=""; F1_J_AUTO=""; F1_J_JOBR=""; F1_J_EXPL=""; F1_J_UNK=""; F1_J_EXPL_AFTER_SLH=""; F1_J_SLH=""; F1_J_BF=""; F1_J_FAIL_AFTER_EXPL=""
  F1_J_BF_AFTER_HELD=""; F1_J_FAILRES=""
  while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    if [[ "$seen" == *" $k "* ]]; then F1_WHY="窗口归类字段 $k 重复"; return 2; fi
    seen="$seen$k "
    case "$k" in
      START|AUTO|JOBR|EXPL|UNK|EXPL_AFTER_SLH|SLH|BF|FAIL_AFTER_EXPL)
        [[ "$v" =~ ^[0-9]+$ ]] || { F1_WHY="窗口归类字段 $k 不是数"; return 2; }
        printf -v "F1_J_$k" '%s' "$v";;
      BF_AFTER_HELD) F1_J_BF_AFTER_HELD="$v";; FAILRES) F1_J_FAILRES="$v";;
      *) F1_WHY="窗口归类多出字段 $k"; return 2;;
    esac
  done <<< "$out"
  for k in START AUTO JOBR EXPL UNK EXPL_AFTER_SLH SLH BF FAIL_AFTER_EXPL BF_AFTER_HELD FAILRES; do
    [[ "$seen" == *" $k "* ]] || { F1_WHY="窗口归类缺字段 $k"; return 2; }
  done
  return 0
}
# <<< PDG-EXTRACT-END f1_classify
# >>> PDG-EXTRACT-BEGIN f1_post
f1_listen_pids(){   # → 0 取得(F1_LPIDS = 127.0.0.1:5399 的监听 pid, 空格分隔, 空 = 没有监听) / 2 观测无效(F1_WHY)。
                    # 与 s1_listen_owner 的读法相同, 但不需要 unit 的 ControlGroup(失败 / 停着的 unit 没有 cgroup)
  local raw rc line p
  local -a pa=()
  F1_LPIDS=""; F1_WHY=""
  raw="$(ss -lunp 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then F1_WHY="ss -lunp 退出 $rc(已输出的不采信)"; return 2; fi
  if [[ "$raw" != *"Local Address"* ]]; then F1_WHY="ss 输出不像 ss(没有表头)"; return 2; fi
  while IFS= read -r line; do
    [[ "$line" =~ (^|[[:space:]])127\.0\.0\.1:5399[[:space:]] ]] || continue
    if ! p="$(grep -o 'pid=[0-9]*' <<< "$line" | cut -d= -f2 | sort -u | tr '\n' ' ')"; then
      F1_WHY="127.0.0.1:5399 的监听行取 pid 的管道失败(已输出的不采信)"; F1_LPIDS=""; return 2; fi
    if [[ -z "${p// /}" ]]; then F1_WHY="127.0.0.1:5399 的监听行里取不到 pid"; F1_LPIDS=""; return 2; fi
    F1_LPIDS="$F1_LPIDS $p"
  done <<< "$raw"
  read -r -a pa <<< "$F1_LPIDS"; F1_LPIDS="${pa[*]}"     # 压掉多余空白
  return 0
}
f1_dw_post(){   # 调用返回后的 pdg-dotwitness 读数(只记录; 按政策它本来就该保持故障)。F1_POST ∈ HEALTHY DOWN UNOBT; 读数进 09-f1-dw-post.txt
  local rec="$EVID/09-f1-dw-post.txt" r
  F1_POST=UNOBT; F1_POST_WHY=""; F1_POST_OCC=""
  if ! s1_dw_show; then F1_POST_WHY="调用后读数观测无效: $S1_WHY"; s1_rec "$rec" "$F1_POST_WHY"; return 0; fi
  s1_rec "$rec" "show: $(s1_dw_line)"
  if ! f1_listen_pids; then F1_POST_WHY="5399 监听观测无效: $F1_WHY"; s1_rec "$rec" "$F1_POST_WHY"; return 0; fi
  s1_rec "$rec" "5399 监听 pid: [${F1_LPIDS}]"
  if [[ -n "${F1_OCC_HELD_PID:-}" && " $F1_LPIDS " == *" $F1_OCC_HELD_PID "* ]]; then F1_POST_OCC=yes; else F1_POST_OCC=no; fi
  if [[ "${S1_DW[LoadState]}" == loaded && "${S1_DW[UnitFileState]}" == enabled && "${S1_DW[ActiveState]}" == active && "${S1_DW[SubState]}" == running ]]; then
    s1_listen_owner; r=$?
    s1_rec "$rec" "归属: rc=$r 监听者=${S1_LISTEN:-无} ${S1_WHY:-}"
    if (( r == 0 )); then F1_POST=HEALTHY; F1_POST_WHY="loaded / enabled / active / running, 5399 监听者都在它的 cgroup"
    elif (( r == 2 )); then F1_POST_WHY="active, 但 5399 归属观测无效: $S1_WHY"; s1_rec "$rec" "归类: UNOBT($F1_POST_WHY)"; return 0
    else F1_POST=DOWN; F1_POST_WHY="active / running, 但 $S1_WHY(占用者 held pid ${F1_OCC_HELD_PID:-未取得} 在监听者里: $F1_POST_OCC)"; fi
  else
    F1_POST=DOWN
    F1_POST_WHY="${S1_DW[ActiveState]} / ${S1_DW[SubState]}, Result=${S1_DW[Result]}, NRestarts=${S1_DW[NRestarts]}; 5399 监听 pid [${F1_LPIDS:-无}](占用者 held pid ${F1_OCC_HELD_PID:-未取得} 在其中: $F1_POST_OCC)"
  fi
  s1_rec "$rec" "归类: $F1_POST($F1_POST_WHY)"
  return 0
}
# <<< PDG-EXTRACT-END f1_post
# >>> PDG-EXTRACT-BEGIN f1_settle
# 分层结算。输入: F1_VARIANT F1_G F1_GATE_NAME F1_CNT F1_UPG F1_UPG_CORE_N F1_UPG_RT_N F1_OCCL F1_OCC_* F1_WIN F1_WIN_WHY F1_J F1_J_WHY F1_J_*
#   F1_7B(0 = 升级日志里没有 ⑦b 的回滚句 / 1 = 有 / 2 = 未取得) S1_REP S1_REP_N F1_RF F1_RF_WHY F1_FORM F1_R_* F1_POST F1_POST_WHY F1_POST_OCC
# 输出: 逐层一行; F1_VERDICT ∈ PASS UNCOVERED UNOBTAINED POLICY_VIOLATION PRECOND UPGRADE_FAILED, 原因在 F1_VERDICT_WHY。
# 优先级: 前提 → 调用次数 → 升级层 → 构造有效性(含返回后构造失效)→ 分支 → 政策 → 报告一致性 → PASS。每层事实照记, 结论取最先不成立的那层。
f1_settle(){
  local l3 l4 l5 l6 l7 l8 c4 c5="" c6="" c7="" w4="" w5="" w6="" w7="" tgt form="${F1_FORM:-}"
  F1_VERDICT=""; F1_VERDICT_WHY=""
  [[ "${F1_VARIANT:-}" == a ]] && tgt="N6430 N6407 FOREIGN NOLISTEN" || tgt="SLHNR"
  if [[ "${F1_G:-}" != 0 ]]; then
    echo "  F1 层1 前提: 不成立(门 ${F1_G:-?}: ${F1_GATE_NAME:-未登记}) —— 本场景未执行"
    echo "  F1 层2 调用次数: ${F1_CNT:-未取得}(计数文件; 门未过时应为 0)"
    echo "  F1 层3–8: 未执行(没有调用)"
    F1_VERDICT=PRECOND; F1_VERDICT_WHY="前提不成立(门 ${F1_G:-?}: ${F1_GATE_NAME:-未登记}), 零调用 —— 不计入升级结论"; return 0
  fi
  echo "  F1 层1 前提: 成立(变体 ${F1_VARIANT}; ② 结果门、桥接身份门、DNS 仪器、占用者装出门、$([[ "${F1_VARIANT}" == a ]] && echo "准备阶段静置、")运行态 / WLOC 前像门、pdg-dotwitness 调用前门、占用者调用前门、调用前观测、计数门全过)"
  echo "  F1 层2 调用次数: ${F1_CNT:-未取得}(计数文件)"
  if [[ "${F1_UPG_CORE_N:-}" =~ ^[0-9]+$ && "${F1_UPG_RT_N:-}" =~ ^[0-9]+$ ]]; then
    l3="进程 / 目标到达 / 撤除·迁移·保留判据失败 ${F1_UPG_CORE_N} 项; 运行态 / 服务对账失败 ${F1_UPG_RT_N} 项(共享判据, 不含 pdg-dotwitness)"
  else l3="两段失败数未取得"; fi
  case "${F1_UPG:-}" in OK) echo "  F1 层3 升级与目标到达: 成立($l3)";; FAIL) echo "  F1 层3 升级与目标到达: 不成立($l3; 逐项见上面 F1-2 / F1-4)";; *) echo "  F1 层3 升级与目标到达: 未取得($l3)";; esac
  # 层4 构造有效性
  if [[ "${F1_OCCL:-}" != OK ]]; then c4=UNOBT; l4="未取得(占用者记录: ${F1_OCC_WHY:-读不了})"
  elif [[ "${F1_WIN:-}" != OK ]]; then c4=UNOBT; l4="未取得(pdg-dotwitness 窗口: ${F1_WIN_WHY:-无效})"
  elif [[ "${F1_J:-}" != OK ]]; then c4=UNOBT; l4="未取得(窗口归类: ${F1_J_WHY:-无效})"
  elif [[ "${F1_7B:-2}" == 1 ]]; then c4=BAD; l4="不成立(升级日志里有 ⑦b 的「被别的进程占着」—— 占用者在 migrate_dotwitness 核验时就占了端口)"
  elif [[ "${F1_7B:-2}" != 0 ]]; then c4=UNOBT; l4="未取得(升级日志里 ⑦b 回滚句的有无查不清)"
  elif (( ${F1_OCC_N_HELD:-0} < 1 )); then c4=BAD; l4="不成立(占用者一次也没有占住 5399; 记录: $(f1_occ_say))"
  elif (( ${F1_OCC_N_HF:-0} > 0 || ${F1_OCC_N_AU:-0} > 0 )); then c4=BAD; l4="不成立(占用者有绑不上 / 判不了的记录: $(f1_occ_say))"
  elif (( ${F1_J_BF:-0} < 1 )); then c4=BAD; l4="不成立(窗口里没有 pdg-dotwitness 的 bind failed)"
  elif [[ "${F1_J_BF_AFTER_HELD:-}" != yes ]]; then c4=BAD; l4="不成立(第一条 bind failed 不晚于占用者第一次 held: ${F1_J_BF_AFTER_HELD:-未取得})"
  else c4=OK; l4="成立(占用者 $(f1_occ_say), 第一次 held 在 ${F1_OCC_HELD1} ns、pid ${F1_OCC_HELD_PID}; 窗口里 bind failed ${F1_J_BF} 条, 第一条晚于 held(journal 单调时间, 直接); 升级日志里没有 ⑦b 回滚句)"; fi
  w4="构造$([[ "$c4" == BAD ]] && echo 不成立 || echo 未取得): $l4"
  case "${F1_POST:-}" in
    HEALTHY) l8="健康(${F1_POST_WHY:-}) —— 端口不在占用者手里, 构造在返回后已失效";;
    DOWN) l8="不健康, 按政策本该如此(${F1_POST_WHY:-})";;
    *) l8="未取得(${F1_POST_WHY:-})";;
  esac
  [[ "$c4" == OK && "${F1_POST:-}" == HEALTHY ]] && { c4=BAD; w4="构造在调用返回后已失效: $l8"; }
  # 层5 分支
  case "${S1_REP:-}" in
    ""|NONE|DUPLICATE|CONFLICT|UNRECOGNIZED) c5=UNOBT; l5="未取得(新步骤报告类别 ${S1_REP:-未取得}, ${S1_REP_N:-?} 条)";;
    *) if [[ "${F1_RF:-}" != OK ]]; then c5=UNOBT; l5="未取得(报告句式细分: ${F1_RF_WHY:-失败})"
       elif [[ " $tgt " == *" $form "* ]]; then c5=HIT; l5="命中目标分支(报告类别 ${S1_REP}, 句式 $form; 本变体的目标: $tgt)"
       else c5=MISS; l5="没有进入目标分支(报告类别 ${S1_REP}, 句式 $form; 本变体的目标: $tgt)"; fi;;
  esac
  case "$c5" in UNOBT) w5="$l5";; MISS) w5="$l5 —— 本变体的目标分支未覆盖(不重试)";; esac
  # 层6 政策(只在命中目标分支时判)
  if [[ "$c5" != HIT ]]; then l6="不判(没有命中目标分支)"
  elif [[ "${F1_J:-}" != OK ]]; then c6=UNOBT; l6="未取得(窗口归类无效)"
  elif (( ${F1_J_UNK:-0} > 0 )); then c6=UNOBT; l6="未取得(窗口里有 ${F1_J_UNK} 次启动事件按消息序列归不了类)"
  elif [[ "${F1_VARIANT}" == a ]]; then
    if (( ${F1_J_EXPL:-0} == 0 )); then c6=OK; l6="守政策(报告自述本步不重置、不启动 / 不处理; journal 推定的显式启动 0 次)"
    else c6=VIOL; l6="违反政策(报告自述没有恢复动作, 但 journal 推定的显式启动 ${F1_J_EXPL} 次)"; fi
  else
    if (( ${F1_J_EXPL:-0} == 1 && ${F1_J_EXPL_AFTER_SLH:-0} == 1 )); then c6=OK; l6="守政策(报告自述 reset-failed 与 start 各一次、不再重试; journal 推定的显式启动恰 1 次, 在限额命中之后)"
    elif (( ${F1_J_EXPL:-0} > 1 )); then c6=VIOL; l6="违反政策(journal 推定的显式启动 ${F1_J_EXPL} 次, 多于新步骤允许的 1 次)"
    else c6=UNOBT; l6="未取得(报告自述执行过 start, 但 journal 推定的显式启动 ${F1_J_EXPL:-?} 次 / 其中限额命中之后 ${F1_J_EXPL_AFTER_SLH:-?} 次)"; fi
  fi
  l6="$l6; 启动事件 ${F1_J_START:-?} 次 = 自动重启 ${F1_J_AUTO:-?} + 重启任务 ${F1_J_JOBR:-?} + 显式 ${F1_J_EXPL:-?} + 归不了类 ${F1_J_UNK:-?}(按消息序列推定, 不是动作记录); reset-failed 的次数: 未取得(systemd 不记)"
  case "$c6" in VIOL) w6="$l6";; UNOBT) w6="政策层未取得: $l6";; esac
  # 层7 报告与当刻状态(只在命中目标分支时判)
  if [[ "$c5" != HIT ]]; then l7="不判(没有命中目标分支)"
  else
    case "$form" in
      N6430|N6407|SLHNR)
        if [[ -z "${F1_R_RES:-}" ]]; then
          if [[ "$form" == SLHNR && "${F1_J_SLH:-0}" -ge 1 && "${F1_J_FAIL_AFTER_EXPL:-0}" -ge 1 ]]; then c7=OK; l7="一致(报告恢复后未就绪; 窗口里有限额命中、显式启动之后有失败结果; 报告没带结果字段)"
          else c7=UNOBT; l7="未取得(报告没带 Result 字段, 对照无从谈起)"; fi
        elif [[ ",${F1_J_FAILRES:-}," == *",${F1_R_RES},"* && ( "$form" != N6430 || "${F1_R_ACT}" == activating || "${F1_R_ACT}" == failed ) ]] \
             && [[ "$form" != SLHNR || ( "${F1_J_SLH:-0}" -ge 1 && "${F1_J_FAIL_AFTER_EXPL:-0}" -ge 1 ) ]]; then
          c7=OK; l7="一致(报告 ActiveState=${F1_R_ACT}, Result=${F1_R_RES}; 窗口里出现过的失败结果: ${F1_J_FAILRES})"
        else c7=MISMATCH; l7="对不上(报告 ActiveState=${F1_R_ACT}, Result=${F1_R_RES}; 窗口里出现过的失败结果: ${F1_J_FAILRES:-无}; 限额命中 ${F1_J_SLH:-?} 次, 显式启动之后的失败 ${F1_J_FAIL_AFTER_EXPL:-?} 次)"; fi;;
      FOREIGN)
        if [[ -n "${F1_OCC_HELD_PID:-}" && " ${F1_R_PIDS:-} " == *" ${F1_OCC_HELD_PID} "* ]]; then c7=OK; l7="一致(报告的监听者 [${F1_R_PIDS}] 含占用者 held 记录的 pid ${F1_OCC_HELD_PID})"
        else c7=MISMATCH; l7="对不上(报告的监听者 [${F1_R_PIDS:-}], 占用者 held 记录的 pid ${F1_OCC_HELD_PID:-未取得})"; fi;;
      NOLISTEN) c7=OK; l7="可对照的字段没有(报告说 active 但没有监听; 只记录)";;
      *) c7=UNOBT; l7="未取得(句式 $form 没有登记的对照)";;
    esac
  fi
  case "$c7" in MISMATCH) w7="报告与 journal 推定的当刻状态对不上: $l7";; UNOBT) w7="报告一致性未取得: $l7";; esac
  # 结论
  if [[ -z "${F1_CNT:-}" || "${F1_CNT}" != 1 ]]; then F1_VERDICT=UNOBTAINED; F1_VERDICT_WHY="调用次数 ${F1_CNT:-未取得}(应为 1)"
  elif [[ "${F1_UPG:-}" == FAIL ]]; then F1_VERDICT=UPGRADE_FAILED; F1_VERDICT_WHY="升级层不成立($l3)"
  elif [[ "${F1_UPG:-}" != OK ]]; then F1_VERDICT=UNOBTAINED; F1_VERDICT_WHY="升级层未取得($l3)"
  elif [[ "$c4" != OK ]]; then F1_VERDICT=UNOBTAINED; F1_VERDICT_WHY="$w4"
  elif [[ "$c5" == UNOBT ]]; then F1_VERDICT=UNOBTAINED; F1_VERDICT_WHY="$w5"
  elif [[ "$c5" == MISS ]]; then F1_VERDICT=UNCOVERED; F1_VERDICT_WHY="$w5"
  elif [[ "$c6" == VIOL ]]; then F1_VERDICT=POLICY_VIOLATION; F1_VERDICT_WHY="$w6"
  elif [[ "$c6" != OK ]]; then F1_VERDICT=UNOBTAINED; F1_VERDICT_WHY="$w6"
  elif [[ "$c7" != OK ]]; then F1_VERDICT=UNOBTAINED; F1_VERDICT_WHY="$w7"
  else F1_VERDICT=PASS; F1_VERDICT_WHY="变体 ${F1_VARIANT}: 外来进程占住 5399 之后, 新步骤走了目标分支(句式 $form), 守政策, 报告与当刻状态一致; 升级照常完成。动作次数按 journal 推定"; fi
  echo "  F1 层4 构造有效性: $l4"
  echo "  F1 层5 分支: $l5"
  echo "  F1 层6 政策: $l6"
  echo "  F1 层7 报告与当刻状态: $l7"
  echo "  F1 层8 调用返回后 pdg-dotwitness: $l8"
  return 0
}
f1_verdict_say(){   # 按 F1_VERDICT 给一个判词(PASS 之外一律 bad, 判词写明类别)
  case "${F1_VERDICT:-}" in
    PASS) ok "F1 结论: 目标分支证据取得 —— ${F1_VERDICT_WHY}";;
    UNCOVERED) bad "F1 结论: 未覆盖 —— ${F1_VERDICT_WHY}";;
    UNOBTAINED) bad "F1 结论: 未取得 —— ${F1_VERDICT_WHY}";;
    POLICY_VIOLATION) bad "F1 结论: 违反政策 —— ${F1_VERDICT_WHY}";;
    PRECOND) bad "F1 结论: 前提不成立 —— ${F1_VERDICT_WHY}";;
    UPGRADE_FAILED) bad "F1 结论: 升级失败 —— ${F1_VERDICT_WHY}";;
    *) bad "F1 结论: 结算没有给出登记的类别([${F1_VERDICT:-}]) —— 按未取得处理";;
  esac
}
# <<< PDG-EXTRACT-END f1_settle

# shellcheck source=/dev/null
source "$F1_TMP/s1const.sh"                  # S-1 的 s1_r3_const 原文(= ③ 681–707 照抄): 两个 SHA 的显式核对与全部环境常量
SECT "F1-0 前置: ② 的结果与桥接前像(任一不成立就停在调用之前; 变体 $F1_VARIANT)"
for c in git python3 ss dig curl sha256sum timeout comm cmp stat diff journalctl systemctl; do command -v "$c" >/dev/null || _hard "缺命令: $c"; done
for s in "$BRIDGE_SHA" "$RETIRE_SHA"; do
  [[ "$(git -C "$R3_OBJ" cat-file -t "$s" 2>/dev/null)" == commit ]] || _hard "本 job 的检出里取不到对象 $s"
done
mkdir -p "$R3_BRSRC" "$R3_RTSRC"
git -C "$R3_OBJ" archive "$BRIDGE_SHA" | tar -x -C "$R3_BRSRC" || _hard "展开桥接树失败"
git -C "$R3_OBJ" archive "$RETIRE_SHA" | tar -x -C "$R3_RTSRC" || _hard "展开候选树失败"
S1_RECBAD=0
# shellcheck source=/dev/null
source "$F1_TMP/s1inline.sh"                 # S-1 的 s1_inline_post(= ③ 1456–1527 的内联判据, 判词前缀 S1-)

snap_state "f1-before"      # 仅留档, 不参与任何判据

# ── 门 + 调用前观测 + 唯一升级入口 ─────────────────────────────────────────────
SECT "F1-1 门全过、调用前观测取全才调用: 现役桥接 CLI 执行 update --to $RETIRE_TAG(变体 $F1_VARIANT$([[ "$F1_VARIANT" == a ]] && echo ": 先静置 303 s" || echo ": 不静置"))"
_cnt_say(){ if r3_count_read; then printf '%s' "$R3_VAL"; else printf '读不出(%s)' "$R3_WHY"; fi; }
F1_T0=""; F1_T1=""
f1_gated_invoke; F1_G=$?
case "$F1_G" in
  0)  F1_GATE_NAME="";;
  10) F1_GATE_NAME="② 结果门";;
  11) F1_GATE_NAME="桥接身份门";;
  15) F1_GATE_NAME="DNS 仪器条件 / 标定 / 还原核验";;
  18) F1_GATE_NAME="占用者装出门";;
  16) F1_GATE_NAME="准备阶段静置";;
  12) F1_GATE_NAME="运行态 / WLOC 前像门";;
  17) F1_GATE_NAME="pdg-dotwitness 调用前门";;
  19) F1_GATE_NAME="占用者调用前门";;
  13) F1_GATE_NAME="调用前观测没取全";;
  14) F1_GATE_NAME="调用计数 / 单调时钟 / 退出码留档不可用";;
  *)  F1_GATE_NAME="门返回了未登记的值 $F1_G";;
esac
if [[ "$F1_G" != 0 ]]; then
  if r3_count_read; then F1_CNT="$R3_VAL"; else F1_CNT=""; fi
  SECT "F1-5 分层结算"
  f1_settle > "$F1_TMP/settle.out"; cat "$F1_TMP/settle.out"; s1_rec "$EVID/99-f1-summary.txt" "$(cat "$F1_TMP/settle.out")"
  f1_verdict_say
  nrun "场景 F-1$F1_VARIANT: $F1_GATE_NAME(调用计数 $(_cnt_say))"; e2e_summary; exit 1
fi
ok "F1-0 ② 结果门、桥接身份门、DNS 仪器、占用者装出门、$([[ "$F1_VARIANT" == a ]] && echo "准备阶段静置、")运行态 / WLOC 前像门、pdg-dotwitness 调用前门、占用者调用前门全部成立且调用前观测取全后才调用(调用计数 $(_cnt_say))"
F1_C1="$(_j_mark f1-end)" || { F1_C1=""; note "阶段记账: 止界桩没建成($(_j_why)) —— 窗口将判观测无效"; }
cp "$R3_LOG" "$EVID/04-f1-update.log" 2>/dev/null && chmod 600 "$EVID/04-f1-update.log" 2>/dev/null \
  || note "升级日志没能复制进证据目录"
cp "$R3_RCFILE" "$EVID/04-f1-update.rc" 2>/dev/null; cp "$R3_TOERR" "$EVID/04-f1-update.timeout-stderr" 2>/dev/null
s1_rec "$EVID/07-f1-dw-window.txt" "调用前一刻 CLOCK_MONOTONIC = ${F1_T0:-未取得} ns; 调用返回后一刻 = ${F1_T1:-未取得} ns(只用于排序, 不作阶段边界)"
tail -40 "$R3_LOG" 2>/dev/null | sed 's/^/    /'

# >>> PDG-EXTRACT-BEGIN f1_main
# 调用返回之后的主流程(F1-2 … F1-5)原样包成函数, 主流程只调用一次。层3 另记两段失败数, 只作层3 的子项写出。
f1_after_call(){
F1_UPG_FAIL0="$E2E_FAIL"
SECT "F1-2 逐维验收(共享判据沿用原判词前缀 S1- / ③-)"
r3_arrival_verdict && ok "F1-2 进程状态 / 目标到达 / 观测有效性分别成立" \
                   || bad "F1-2 进程 $R3_PROC / 目标到达 $R3_ARRIVE / 观测 $R3_OBS —— 不成立"
_evn 03-f1-identity.txt "workflow checkout = ${GITHUB_SHA:-<非 CI>}; 变体 = $F1_VARIANT"
_evn 03-f1-identity.txt "桥接 = $BRIDGE_TAG → $BRIDGE_SHA; 候选 = $RETIRE_TAG → $RETIRE_SHA; 取件源 = $R3_ORIGIN"
_evn 03-f1-identity.txt "调用 = bash $R3_CLI update --to $RETIRE_TAG(经 timeout --verbose $R3_TIMEOUT); 调用计数 = $(_cnt_say); 包装器(timeout)返回码 = ${R3_WRAP_RC:-未取得}; 产品原始退出码 = ${R3_RC:-未取得}"
s1_inline_post
F1_UPG_FAIL1="$E2E_FAIL"

SECT "F1-4 服务与真实功能(不含 pdg-dotwitness)"
f1_post_runtime
snap_state "f1-after"; bridge_svc_sample "$R3_TMP/svc-retire-after.tsv" || note "调用后服务采样写不出来 —— 对账将判集合不全"
WIN_TSV="$R3_TMP/svc-retire-window.tsv"; : > "$WIN_TSV"
for _u in "${SVC_WATCH[@]}"; do
  if [[ -z "${C3_0:-}" || -z "${F1_C1:-}" ]]; then printf '%s\tINVALID\t界桩没建成: %s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"; continue; fi
  if _n="$(_j_interval "$_u" "$C3_0" "$F1_C1")" && [[ -n "$_n" ]]; then printf '%s\t%s\t-\n' "$_u" "$_n" >> "$WIN_TSV"
  else printf '%s\tINVALID\t%s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"; fi
done
sed 's/^/    /' "$WIN_TSV"
r3_svc_verdict "$R3_TMP/svc-retire-before.tsv" "$R3_TMP/svc-retire-after.tsv" retire "$WIN_TSV"
cp "$R3_TMP/svc-retire-before.tsv" "$R3_TMP/svc-retire-after.tsv" "$WIN_TSV" "$EVID/" 2>/dev/null
if [[ "${R3_OBS:-}" != VALID || "${R3_ARRIVE:-}" == UNKNOWN ]]; then F1_UPG=UNKNOWN
elif (( E2E_FAIL > F1_UPG_FAIL0 )); then F1_UPG=FAIL
else F1_UPG=OK; fi
F1_UPG_CORE_N=$((F1_UPG_FAIL1 - F1_UPG_FAIL0)); F1_UPG_RT_N=$((E2E_FAIL - F1_UPG_FAIL1))

SECT "F1-5 pdg-dotwitness 与占用者: 构造、分支、政策、报告与返回后状态(分层结算)"
if f1_occ_log; then F1_OCCL=OK; F1_OCC_WHY=""; echo "  占用者记录: $(f1_occ_say); 第一次 held ${F1_OCC_HELD1:-无} ns, pid ${F1_OCC_HELD_PID:-无}"
else F1_OCCL=BAD; F1_OCC_WHY="$F1_WHY"; echo "  占用者记录观测无效: $F1_WHY"; fi
F1_WIN=INVALID; F1_WIN_WHY=""; F1_J=INVALID; F1_J_WHY=""
if [[ -z "${S1_BOOT:-}" ]]; then s1_boot_id || true; fi
if s1_jwin pdg-dotwitness.service "${C3_0:-}" "${F1_C1:-}" "$EVID/07-f1-dw-window.tsv"; then
  F1_WIN=OK
  if f1_jclass "$EVID/07-f1-dw-window.tsv" "${F1_OCC_HELD1:-}"; then F1_J=OK; else F1_J_WHY="$F1_WHY"; fi
else F1_WIN_WHY="$S1_WHY"; fi
sed 's/^/    /' "$EVID/07-f1-dw-window.tsv" 2>/dev/null   # 整行打印, 不按字节截断
s1_jwin "$F1_OCC_UNIT" "${C3_0:-}" "${F1_C1:-}" "$EVID/07-f1-occupant-window.tsv" || note "占用者的窗口事件没取得($S1_WHY) —— 只作背景留证"
s1_jwin mosdns.service "${C3_0:-}" "${F1_C1:-}" "$EVID/07-f1-mosdns-window.tsv" || note "mosdns 窗口事件没取得($S1_WHY) —— 只作背景留证"
r3_grepq -F "被别的进程占着" "$R3_LOG"; case $? in 0) F1_7B=1;; 1) F1_7B=0;; *) F1_7B=2;; esac
if s1_report "$R3_LOG" "$EVID/08-f1-settle-report.txt"; then
  echo "  报告: 类别 $S1_REP, ${S1_REP_N} 条; 迁移链 $S1_CHAIN"
  if f1_rep_form "$EVID/08-f1-settle-report.txt"; then F1_RF=OK; F1_RF_WHY=""; echo "  报告句式: $F1_FORM(ActiveState=${F1_R_ACT:-} SubState=${F1_R_SUB:-} Result=${F1_R_RES:-} 监听者 pid=[${F1_R_PIDS:-}])"
  else F1_RF=BAD; F1_RF_WHY="$F1_WHY"; echo "  报告句式细分失败: $F1_WHY"; fi
else S1_REP=""; S1_REP_N=""; S1_CHAIN=""; F1_RF=BAD; F1_RF_WHY="报告未取得"; echo "  报告未取得: $S1_WHY"; fi
f1_dw_post
if r3_count_read; then F1_CNT="$R3_VAL"; else F1_CNT=""; fi
f1_settle > "$F1_TMP/settle.out"; cat "$F1_TMP/settle.out"; s1_rec "$EVID/99-f1-summary.txt" "$(cat "$F1_TMP/settle.out")"
f1_verdict_say
(( S1_RECBAD == 0 )) || bad "F1 留证: 有记录写不进证据目录(S1_RECBAD) —— 相关原文不完整"
}
# <<< PDG-EXTRACT-END f1_main
f1_after_call

SECT "F1-6 收尾"
{
  echo "# 本支在这台一次性 runner 上的动作: 装出并启动一个产品之外的 runtime unit $F1_OCC_UNIT(没有停、没有删, 留给留证步看), 与一次 bash $R3_CLI update --to $RETIRE_TAG(调用计数 $(_cnt_say))"
  echo "# 变体 $F1_VARIANT: $([[ "$F1_VARIANT" == a ]] && echo "调用前做了一次 303 s 准备阶段静置(06-quiesce-dotwitness.txt)" || echo "没有施加准备阶段静置")"
  echo "# 前像来源: 同一 job 上一步 ② 的真实现场(本支调用前逐项现查), 调用前经 DNS 仪器调整(05-dns-instrument-adjustments.txt); 取件源 $R3_ORIGIN"
  echo "# 退出码: 包装器(timeout)返回码 ${R3_WRAP_RC:-未取得}; 产品原始退出码 ${R3_RC:-未取得}"
  echo "# F1 结论: ${F1_VERDICT:-未给出} —— ${F1_VERDICT_WHY:-}"
  echo "# 动作次数与调用者: 未取得(没有 systemctl 动作记录); 启动来源按 journal 消息序列推定, 产品报告只是自述(见 99 文件的层6)"
  echo "# 只证明'外来进程占 5399'这一类; 不覆盖'进程起不来''缺配置'、Android 首次升级、别的 systemd 版本; 不外推到桥接后续所有分支"
  echo "# 证据文件"; ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-f1-summary.txt
chmod 600 "$EVID"/* 2>/dev/null || true
echo; echo "未执行(前像/前置不成立而跳过)的场景数: $E2E_NOTRUN"
e2e_summary
