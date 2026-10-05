#!/usr/bin/env bash
# shellcheck disable=SC2034  # 全文件: 大量全局变量由运行时按标记抽进来的共享函数(③ / ② / ⑤ 原文)按名字读取, 静态看不到
# ────────────────────────────────────────────────────────────────────────────
# 真实验收 S-1: **已安装桥接 → 新候选的首次升级**, 观测整次调用期间 pdg-dotwitness 的触限、恢复与桥接父进程收尾。
#     bash /usr/local/bin/pdg update --to <候选的合成 tag>(同一 job 里 ② 刚装上的现役桥接 CLI)
# 前像: 同一 job、同一 runner 上一步原样跑完的 tests/e2e-real-bridge-hop.sh(②); 起跑前逐项现查, 任一不成立就停在调用之前(调用计数 0)。
# 与 ③ 的区别只有两处: 不施加 ③ 的 303 s 准备阶段静置(不调用 r3_gated_invoke / r3_quiesce, 也不覆盖静置参数); 调用前多一道
#   pdg-dotwitness 调用前门(调用前已故障 ⇒ 前提不成立、零调用, 不记升级失败)。不施加静置也不预设一定触限。
# 保留: ② 结果门、桥接身份门、DNS 仪器(条件建立、三次 mosdns 重启、K 的 U→H→U 标定与还原核验)、运行态 / WLOC 前像门、调用前观测、
#   唯一入口 r3_invoke, 以及 ③ 的退出码 / 超时 / 目标身份、撤除、迁移、保留与 DNS 判据(③ 1456–1527 的内联判据逐字复制, 只换判词前缀)。
# 不做: 额外重启凑触限、改启动限额、由验收器 reset-failed / start / restart pdg-dotwitness、在 systemctl 外加包装、直接运行抽出的 _dw_settle、
#   同一 runner 上重试。没有 systemctl 动作记录 ⇒ reset-failed / start 的精确次数与调用者记未取得; journal 只给事件, 产品报告只是自述。
# 分层结算(s1_settle): 前提 / 调用次数 / 升级与目标到达 / 触限 / 恢复现象 / 报告与观测是否一致 / 返回后健康 / 动作次数与来源。
#   本 job 以取得新步骤恢复分支的证据为目标: 未观测到触限 ⇒ 未覆盖; 关键证据未取得 ⇒ 未取得; 直接观测到终态不健康 ⇒ 恢复失败 ——
#   三者都非零退出, 判词写明是哪一种; 恢复成立也只证明本次构造, 不外推到桥接后续所有分支, 不追认 324 / 374 的根因。
# 复用: 一律按唯一成对标记从 ③ / ② / ⑤ 抽原文(不 source 整支); 不得调用表里的函数不抽进来。
# 观测有效性: 每次读取先看它自己的退出码与格式; 读失败 / 半截输出不消费, 不当成"零""原样""不存在"或"健康"。
# 不覆盖: F-1(非 start-limit-hit 启动失败, 待定)、④、A-off、B / C2、v1.7.8、完整旧安装器、官方分发来源、发布。只许在一次性 GitHub runner 上跑。
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
EVID="${PDG_S1_EVID:-}"
[[ "$EVID" == /* ]] || _hard "必须显式给出证据目录的绝对路径(PDG_S1_EVID)"
{ mkdir -p "$EVID" && chmod 700 "$EVID"; } 2>/dev/null || _hard "证据目录 $EVID 建不出来 —— 调用计数无处可落, 不调用"

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
S1_TMP="$(mktemp -d "${TMPDIR:-/tmp}/s1.XXXXXX")" || _hard "建不出本支临时目录"
R3_TMP="$S1_TMP"; E2E_TMP="$S1_TMP"          # 被抽取的函数按 $R3_TMP / $E2E_TMP 落临时物 —— 落在本支自己的目录
export E2E_TMP
R3_SRC="$E2E_ROOT/tests/e2e-real-retire-hop.sh"; HOP2_SRC="$E2E_ROOT/tests/e2e-real-bridge-hop.sh"; PLAT_SRC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"

# >>> PDG-EXTRACT-BEGIN s1_seed
# 引导的引导: 先把 ③ 的块原文取出来(判据同 B / C2 的 bc_seed), 之后一律用 ③ 的 r3_bootstrap 与 ② 的抽取器按标记抽。
s1_seed(){   # $1=名字 $2=来源 → 打印标记之间的原文; 标记不是唯一成对或之间为空 ⇒ 非 0
  local n="$1" src="$2" b e
  [[ -f "$src" ]] || { echo "引导: 找不到 $src" >&2; return 2; }
  [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] \
    || { echo "引导: $n 的标记不是唯一成对" >&2; return 1; }
  b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
  e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
  (( e - b >= 2 )) || { echo "引导: $n 的标记之间是空的" >&2; return 1; }
  sed -n "$((b+1)),$((e-1))p" "$src"
}
# <<< PDG-EXTRACT-END s1_seed
# >>> PDG-EXTRACT-BEGIN s1_lists
# 本支实际抽取的共享输入(契约按这几张表从"现在"与 2982aa54 两侧各抽一次逐名逐字比对)。S1_FORBID 里的函数不抽进来、不得调用。
S1_PLAT_FNS=(_ev _evn SECT note sc_get sc_state nrun snap_state wait_stable unit_identify _unit_wants_mainpid svc_stable_window svc_stable_assert
             mitm_listen_verdict _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after _j_interval)
S1_PLAT_DECLS=(E2E_OWNED_UNITS SVC_WATCH)
S1_HOP2_FNS=(bridge_svc_sample bridge_row_valid)
S1_R3_BLOCKS=(r3_count r3_read r3_real2_gate r3_bridge_identity_gate r3_keep r3_precapture r3_invoke r3_arrival_verdict r3_svc_class r3_svc_verdict
              r3_stable r3_dns r3_runtime_gate r3_post)
S1_FORBID=(r3_gated_invoke r3_quiesce r3_q_prop r3_q_limits r3_q_sample r3_q_clock r3_q_rec r3_q_ns)
# <<< PDG-EXTRACT-END s1_lists

# 调用计数最先: 任何门之前先落 0 并读回(③ r3_count 原文, 计数文件换成本支自己的)
s1_seed r3_count "$R3_SRC" > "$S1_TMP/r3count.sh" && bash -n "$S1_TMP/r3count.sh" || _hard "调用计数块抽取失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$S1_TMP/r3count.sh"
R3_COUNT="$EVID/00-s1-invoke-count.txt"
r3_count_init || _hard "调用计数初始化失败: $R3_WHY —— 不调用"
s1_seed r3_bootstrap "$R3_SRC" > "$S1_TMP/boot.sh" && bash -n "$S1_TMP/boot.sh" || _hard "③ 抽取器引导失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$S1_TMP/boot.sh"
r3_bootstrap "$HOP2_SRC" "$S1_TMP/extractor.sh" extract_marked_fns extract_marked_decls || _hard "② 抽取器引导失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$S1_TMP/extractor.sh"
extract_marked_fns "$PLAT_SRC" "$S1_TMP/plat-fns.sh" "${S1_PLAT_FNS[@]}" || _hard "⑤ 函数抽取没通过 —— 还没碰任何服务"
extract_marked_decls "$PLAT_SRC" "$S1_TMP/plat-deps.sh" "${S1_PLAT_DECLS[@]}" || _hard "⑤ 依赖抽取没通过"
extract_marked_fns "$HOP2_SRC" "$S1_TMP/hop2-fns.sh" "${S1_HOP2_FNS[@]}" || _hard "② 函数抽取没通过 —— 还没碰任何服务"
r3_bootstrap "$R3_SRC" "$S1_TMP/r3fns.sh" "${S1_R3_BLOCKS[@]}" || _hard "③ 判据段抽取没通过 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$S1_TMP/plat-fns.sh"; source "$S1_TMP/plat-deps.sh"; source "$S1_TMP/hop2-fns.sh"; source "$S1_TMP/r3fns.sh"
for _f in "${S1_FORBID[@]}"; do declare -F "$_f" >/dev/null && _hard "不得调用的 $_f 被抽进来了 —— 停在一切服务动作之前"; done
JBOUND_TAG="pdg-e2e-jbound-s1"
J_ERR=""
E2E_NOTRUN=0

# ── 本支自己的读取器与判据(契约按标记抽出来用受控输入驱动) ─────────────────────────
# >>> PDG-EXTRACT-BEGIN s1_dw
# 读取器约定: 成功 ⇒ 0; 失败 ⇒ 非 0、原因放 S1_WHY。查询非零退出时已经输出的内容一概不采信。
S1_DW_KEYS=(LoadState UnitFileState ActiveState SubState Result MainPID InvocationID NRestarts StartLimitIntervalUSec StartLimitBurst FragmentPath DropInPaths ControlGroup)
s1_dw_show(){   # → 0 有效(键齐全、不重复、没有多余键; 值在 S1_DW) / 2 观测无效(S1_WHY)
  local raw rc line k v seen=" "
  local -a args=()
  declare -gA S1_DW=()
  S1_DW=(); S1_WHY=""
  for k in "${S1_DW_KEYS[@]}"; do args+=(-p "$k"); done
  raw="$(systemctl show pdg-dotwitness.service "${args[@]}" --no-pager 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then S1_WHY="systemctl show 退出 $rc(已输出的内容不采信)"; return 2; fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" != ?*=* ]]; then S1_WHY="systemctl show 输出有无法解析的行"; S1_DW=(); return 2; fi
    k="${line%%=*}"; v="${line#*=}"
    if [[ " ${S1_DW_KEYS[*]} " != *" $k "* ]]; then S1_WHY="systemctl show 多出未请求的键 $k"; S1_DW=(); return 2; fi
    if [[ "$seen" == *" $k "* ]]; then S1_WHY="systemctl show 的键 $k 重复"; S1_DW=(); return 2; fi
    seen="$seen$k "; S1_DW[$k]="$v"
  done <<< "$raw"
  for k in "${S1_DW_KEYS[@]}"; do
    if [[ "$seen" != *" $k "* ]]; then S1_WHY="systemctl show 缺 $k"; S1_DW=(); return 2; fi
  done
  if [[ ! "${S1_DW[NRestarts]}" =~ ^[0-9]+$ ]]; then S1_WHY="NRestarts=${S1_DW[NRestarts]} 不是非负整数"; S1_DW=(); return 2; fi
  return 0
}
s1_dw_line(){ local k o=""; for k in "${S1_DW_KEYS[@]}"; do o="$o $k=${S1_DW[$k]:-}"; done; printf '%s\n' "${o# }"; }
s1_boot_id(){   # → 0 取得(S1_BOOT = 32 位十六进制, 与 journal 的 _BOOT_ID 同格式) / 2 未取得
  local b rc
  S1_BOOT=""
  b="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ ! "$b" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    S1_WHY="boot ID 读不了或格式不对(cat 退出 $rc)"; return 2; fi
  S1_BOOT="${b//-/}"
}
s1_cg_of(){   # $1=pid → 0 打印该进程的 cgroup v2 路径 / 2 读不了、提取失败或不是唯一一行 v2 路径
  local raw rc p
  raw="$(cat "/proc/$1/cgroup" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || return 2
  p="$(sed -n 's/^0::\(\/.*\)$/\1/p' <<< "$raw")" || return 2   # 383: 提取先输出、再失败 ⇒ 已输出的不采信
  [[ -n "$p" && "$p" != *$'\n'* ]] || return 2
  printf '%s\n' "$p"
}
s1_listen_owner(){   # 读 S1_DW[ControlGroup] → 0 127.0.0.1:5399 有监听且监听者全部在该 unit 的 cgroup / 1 没有监听或有监听者不在(S1_WHY) / 2 观测无效
  local raw rc cg line pids="" p pc saw="" bad="" n=0
  S1_LISTEN=""
  cg="${S1_DW[ControlGroup]:-}"
  if [[ "$cg" != /* ]]; then S1_WHY="ControlGroup 取不到或不是路径([$cg])"; return 2; fi
  raw="$(ss -lunp 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then S1_WHY="ss -lunp 退出 $rc(已输出的不采信)"; return 2; fi
  if [[ "$raw" != *"Local Address"* ]]; then S1_WHY="ss 输出不像 ss(没有表头)"; return 2; fi
  while IFS= read -r line; do
    [[ "$line" =~ (^|[[:space:]])127\.0\.0\.1:5399[[:space:]] ]] || continue
    n=$((n+1))
    if ! p="$(grep -o 'pid=[0-9]*' <<< "$line" | cut -d= -f2 | sort -u | tr '\n' ' ')"; then   # 383: 管道任一段失败(pipefail)⇒ 部分输出不采信
      S1_WHY="127.0.0.1:5399 的监听行取 pid 的管道失败(已输出的不采信; 可能漏掉其它监听者)"; return 2; fi
    if [[ -z "${p// /}" ]]; then S1_WHY="127.0.0.1:5399 的监听行里取不到 pid"; return 2; fi
    pids="$pids $p"
  done <<< "$raw"
  if (( n == 0 )); then S1_WHY="127.0.0.1:5399 没有监听"; return 1; fi
  for p in $pids; do
    if ! pc="$(s1_cg_of "$p")"; then S1_WHY="读不到 5399 监听进程 $p 的 cgroup"; return 2; fi
    saw="$saw $p:$pc"
    [[ "$pc" == "$cg" ]] || bad="$bad $p:$pc"
  done
  S1_LISTEN="${saw# }"
  if [[ -n "$bad" ]]; then S1_WHY="127.0.0.1:5399 的监听者不在该 unit 的 cgroup(unit: $cg; 不在的:$bad)"; return 1; fi
  return 0
}
s1_mono(){   # → 0 打印 CLOCK_MONOTONIC 纳秒 / 2 读不了或不是正整数
  local v
  v="$(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))' 2>/dev/null)" || return 2
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || return 2
  printf '%s\n' "$v"
}
s1_rec(){ { printf '%s\n' "$2" >> "$1"; } 2>/dev/null || S1_RECBAD=1; }   # 记录写不进 ⇒ 粘性标志, 收尾时具名报出
# <<< PDG-EXTRACT-END s1_dw
# >>> PDG-EXTRACT-BEGIN s1_journal
# 调用窗口 = 起界桩(r3_precapture 建的 C3_0)之后、止界桩(调用返回后建)之后的差集, 按 journal 自己的游标取, 不比较游标字符串;
# 界桩先后由界桩自己的记录条数自证(同 ⑤ 的 _j_interval)。每条记录分别留: 游标、单调时间、boot、归属字段、实例字段、消息原文。
# 目标归属: 有 UNIT 字段用它(管理器关于该 unit 的消息); 没有 UNIT 且不是 PID 1 才用 _SYSTEMD_UNIT(服务进程自己的消息);
# PID 1 自身的 _SYSTEMD_UNIT 不当作目标服务身份。INVOCATION_ID 只在取到时用于实例对照, 缺了不等于"没有事件"。
s1_jdump(){   # $1=unit $2=游标 $3=输出文件 → 0 取得 / 2 观测无效(S1_WHY); 先输出后失败不采信
  local rc
  journalctl -u "$1" --after-cursor "$2" --no-pager -o json > "$3" 2> "$3.err"; rc=$?
  if (( rc != 0 )); then S1_WHY="journalctl -u $1 --after-cursor 退出 $rc($(head -c 160 "$3.err" 2>/dev/null | tr '\n' ' '))(已输出的不采信)"; return 2; fi
  return 0
}
s1_jwin(){   # $1=unit $2=起界桩游标 $3=止界桩游标 $4=输出 TSV → 0 窗口有效 / 2 观测无效(S1_WHY)
  local u="$1" a="$2" b="$3" out="$4" ta tb rc
  if [[ -z "$a" || -z "$b" ]]; then S1_WHY="界桩游标缺失"; return 2; fi
  if [[ ! "${S1_BOOT:-}" =~ ^[0-9a-f]{32}$ ]]; then S1_WHY="本次 boot ID 未取得, 窗口无法对应到本次 boot"; return 2; fi
  s1_jdump "$u" "$a" "$S1_TMP/jwin-a.json" || return 2
  s1_jdump "$u" "$b" "$S1_TMP/jwin-b.json" || return 2
  if ! ta="$(_j_tag_after "$a")"; then S1_WHY="起界桩核对失败: $(_j_why)"; return 2; fi
  if ! tb="$(_j_tag_after "$b")"; then S1_WHY="止界桩核对失败: $(_j_why)"; return 2; fi
  if [[ ! "$ta" =~ ^[0-9]+$ || ! "$tb" =~ ^[0-9]+$ ]] || (( ta <= tb )); then
    S1_WHY="界桩顺序不成立(起界桩之后 [$ta] 条界桩 / 止界桩之后 [$tb] 条)"; return 2; fi
  python3 - "$S1_TMP/jwin-a.json" "$S1_TMP/jwin-b.json" "$u" "$S1_BOOT" > "$out" 2> "$out.err" <<'PY'
import json, re, sys
fa, fb, unit, boot = sys.argv[1:5]
def load(f):
    out = []
    with open(f, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                d = json.loads(line)
            except Exception:
                sys.stderr.write("%s 第 %d 行不是 JSON\n" % (f, i)); sys.exit(3)
            if not isinstance(d, dict) or not isinstance(d.get("__CURSOR"), str) or not d["__CURSOR"]:
                sys.stderr.write("%s 第 %d 行缺 __CURSOR\n" % (f, i)); sys.exit(3)
            out.append(d)
    return out
A = load(fa); B = load(fb)
ca = [d["__CURSOR"] for d in A]; cb = [d["__CURSOR"] for d in B]
if len(cb) > len(ca) or ca[len(ca) - len(cb):] != cb:
    sys.exit(4)
W = A[:len(A) - len(cb)]
full = unit if unit.endswith(".service") else unit + ".service"
esc = re.escape(full)
def s(v):
    if v is None:
        return None
    if isinstance(v, list):
        try:
            return bytes(v).decode("utf-8", "replace")
        except Exception:
            return None
    return str(v)
KINDS = [("start", r"Started %s( - .*)?" % esc), ("starting", r"Starting %s( - .*)?" % esc),
         ("stopping", r"Stopping %s( - .*)?" % esc), ("stopped", r"Stopped %s( - .*)?" % esc),
         ("deactivated", r"%s: Deactivated successfully\." % esc),
         ("slh_repeat", r"%s: Start request repeated too quickly\." % esc),
         ("slh_result", r"%s: Failed with result 'start-limit-hit'\." % esc),
         ("fail_result", r"%s: Failed with result '[a-z-]+'\." % esc),
         ("fail_start", r"Failed to start %s( - .*)?" % esc),
         ("main_exit", r"%s: Main process exited.*" % esc), ("sched_restart", r"%s: Scheduled restart job.*" % esc)]
for i, d in enumerate(W, 1):
    b = s(d.get("_BOOT_ID"))
    if b != boot:
        sys.stderr.write("第 %d 条 _BOOT_ID=%s, 本次 boot=%s\n" % (i, b, boot)); sys.exit(5)
    pid = s(d.get("_PID"))
    tgt = s(d.get("UNIT"))
    if not tgt and pid != "1":
        tgt = s(d.get("_SYSTEMD_UNIT"))
    attr = "target" if tgt == full else ("missing" if not tgt else "other")
    msg = s(d.get("MESSAGE")) or ""
    kind = "other"
    for k, pat in KINDS:
        if re.fullmatch(pat, msg):
            kind = k
            break
    print("\t".join([str(i), d["__CURSOR"], s(d.get("__MONOTONIC_TIMESTAMP")) or "-", attr, tgt or "-", pid or "-",
                     s(d.get("INVOCATION_ID")) or "-", s(d.get("_SYSTEMD_INVOCATION_ID")) or "-", kind,
                     msg.replace("\t", " ").replace("\n", " ")]))
PY
  rc=$?
  case "$rc" in
    0) return 0;;
    3) S1_WHY="journal 输出不是逐行 JSON 对象或缺 __CURSOR($(head -c 160 "$out.err" 2>/dev/null | tr '\n' ' '))";;
    4) S1_WHY="窗口两侧对不上(止界桩之后的记录不是起界桩之后记录的尾段)";;
    5) S1_WHY="窗口里有记录不属于本次 boot($(head -c 160 "$out.err" 2>/dev/null | tr '\n' ' '))";;
    *) S1_WHY="窗口解析失败(python 退出 $rc)";;
  esac
  return 2
}
s1_jsum(){   # $1=s1_jwin 的 TSV → 0 汇总取得(S1_N_* / S1_LAST_KIND / S1_REFAIL / S1_INV_LAST) / 2 读不了或结构不对
  local out
  if ! out="$(awk -F'\t' '
    NF != 10 { bad = 1; exit }
    { n++ }
    $4 == "other" { otheru++ }
    $4 == "missing" { unattr++; if ($9 ~ /^(slh_repeat|slh_result|fail_start|fail_result)$/) crit++ }
    $4 == "target" {
      k = $9
      if (k == "slh_result") slh++
      if (k == "slh_repeat") rep++
      if (k == "fail_result") failx++
      if (k == "start") { start++; inv = $7 }
      if (k == "slh_repeat" || k == "slh_result") {
        if (state == "up") refail++
        lastslh = n; state = "slh"; anyslh++; after = 0; last = "slh"
      } else if (k == "start") {
        if (state == "slh" || state == "up") state = "up"
        if (anyslh) after++
        last = "start"
      } else if (k ~ /^(stopping|stopped|deactivated|fail_result|fail_start|main_exit)$/) {
        last = (k == "fail_result" || k == "fail_start") ? "fail" : k
      }
    }
    END { if (bad) exit 3
          printf "%d %d %d %d %d %d %d %d %d %d %d %s %s\n", n, anyslh, slh, rep, start, after, refail, failx, unattr, crit, otheru, (last == "" ? "-" : last), (inv == "" ? "-" : inv) }' "$1" 2>/dev/null)"; then
    S1_WHY="窗口 TSV 读不了或列数不对"; return 2; fi
  read -r S1_N_EV S1_N_SLHANY S1_N_SLH S1_N_SLHREP S1_N_START S1_N_START_AFTER S1_REFAIL S1_N_FAILX S1_N_UNATTR S1_N_UNATTR_CRIT S1_N_OTHERU S1_LAST_KIND S1_INV_LAST <<< "$out"
  [[ "${S1_N_EV:-}" =~ ^[0-9]+$ && "${S1_INV_LAST:-}" != "" ]] || { S1_WHY="窗口汇总结果不完整"; return 2; }
  return 0
}
# <<< PDG-EXTRACT-END s1_journal
# >>> PDG-EXTRACT-BEGIN s1_report
# 新步骤报告: 只认冻结源码 T′ 5804–5979 的固定句式。匹配副本只处理事先登记的显示前缀: 一个 \x1b[1;32m(绿)或 \x1b[1;33m(黄)开头、
# 一个 \x1b[0m 结尾、两个空格、黄色句式前的 "⚠️" 加两个空格; 颜色必须与句式对应。原始日志另行原样留证, 不做宽泛删除。
s1_report(){   # $1=升级日志 $2=归类留证文件 → 0 取得(S1_REP S1_REP_N S1_REP_NR S1_CHAIN) / 2 日志读不了或不是 UTF-8(S1_WHY)
  local log="$1" out="$2" rc k v l fl seen=" "
  S1_REP=""; S1_REP_N=""; S1_REP_NR=""; S1_CHAIN=""
  python3 - "$log" > "$out" 2> "$out.err" <<'PY'
import re, sys
txt = open(sys.argv[1], "rb").read().decode("utf-8")
H = r"观察到启动限额命中\(Result=start-limit-hit, NRestarts=(\d+)\)"
D = r"已做一次定向恢复\(reset-failed 退出 0, start 退出 0\)"
TAB = [("PASS", "g", r"核验通过 —— 运行中, 127\.0\.0\.1:5399 由 pdg-dotwitness 持有。"),
       ("RECOVERED", "g", H + "; " + D + r", 恢复后运行中, 127\.0\.0\.1:5399 由 pdg-dotwitness 持有 —— 本次核验已恢复。"),
       ("SLH_RESET_FAIL", "y", H + r"; 定向恢复的 reset-failed 退出 \d+, 未执行 start; 不再重试。"),
       ("SLH_START_FAIL", "y", H + r"; 定向恢复: reset-failed 退出 0, start 退出 \d+; 不再重试。"),
       ("SLH_POST_UNOBS", "y", H + "; " + D + r", 但恢复后观察未取得\(.*\), 不能确认已恢复; 不再重试。"),
       ("SLH_POST_NOTREADY", "y", H + "; " + D + r", 但恢复后确认未就绪\(.*\); 不再重试。查看 journalctl -u pdg-dotwitness。"),
       ("INCOMPLETE", "y", r"本次核验未完成\(核验过程异常退出, 退出码 \d+\); 不据此判断服务是否故障, 也不代表已恢复; 本步不再做任何动作。"),
       ("UNOBS", "y", r"状态未取得\(.*\), 本步不做任何动作。"),
       ("UFS", "y", r"本次观察到自启态 .*\(LoadState=.*, 运行态 .*\), 本步不启动、不改自启; 迁移链前面的步骤是否改动过它的自启状态, 本步不作结论。"),
       ("NOLISTEN", "y", r"服务 active, 但 127\.0\.0\.1:5399 没有监听; 本步不处理。"),
       ("FOREIGN", "y", r"服务 active, 但 127\.0\.0\.1:5399 由别的进程持有\(unit: .*; 监听者:.*\); 本步不处理。"),
       ("NOTREADY", "y", r"未就绪\(.*\), 本步不重置、不启动。查看 journalctl -u pdg-dotwitness。")]
reps = []
for ln in txt.split("\n"):
    if "DoT 证据端:" not in ln:
        continue
    cls, nr = "UNRECOGNIZED", ""
    m = re.fullmatch("\x1b\\[1;3([23])m(.*)\x1b\\[0m", ln, re.S)
    if m:
        col = "g" if m.group(1) == "2" else "y"
        pre = "  DoT 证据端: " if col == "g" else "  ⚠️  DoT 证据端: "
        body = m.group(2)
        if body.startswith(pre):
            sent = body[len(pre):]
            for c, want, pat in TAB:
                mm = re.fullmatch(pat, sent)
                if mm:
                    if want == col:
                        cls = c
                        if c.startswith("SLH") or c == "RECOVERED":
                            nr = mm.group(1)
                    break
    reps.append((cls, nr, ln))
chain = "failed" if "迁移(__migrate)失败, 回滚到更新前快照" in txt else "ok"
if not reps:
    c, nr = "NONE", ""
elif len(reps) == 1:
    c, nr = reps[0][0], reps[0][1]
elif all(r[2] == reps[0][2] for r in reps):
    c, nr = "DUPLICATE", ""
else:
    c, nr = "CONFLICT", ""
print("CLASS=%s" % c)
print("N=%d" % len(reps))
print("NR=%s" % nr)
print("CHAIN=%s" % chain)
for cls, _, ln in reps:
    print("LINE\t%s\t%r" % (cls, ln))
PY
  rc=$?
  if (( rc != 0 )); then S1_WHY="升级日志读不了或不是 UTF-8(python 退出 $rc: $(head -c 160 "$out.err" 2>/dev/null | tr '\n' ' '))"; return 2; fi
  # 383: 归类结果先整份取出并核读取的退出码(先输出后失败不采信); 四个字段各恰一行, 重复或缺失都不默认
  if ! fl="$(grep -E '^(CLASS|N|NR|CHAIN)=' "$out" 2>/dev/null)"; then S1_WHY="报告归类结果读不了(grep 失败或没有字段; 已输出的不采信)"; return 2; fi
  while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    if [[ "$seen" == *" $k "* ]]; then S1_WHY="报告归类结果里字段 $k 重复"; S1_REP=""; S1_REP_N=""; S1_REP_NR=""; S1_CHAIN=""; return 2; fi
    seen="$seen$k "
    case "$k" in CLASS) S1_REP="$v";; N) S1_REP_N="$v";; NR) S1_REP_NR="$v";; CHAIN) S1_CHAIN="$v";; esac
  done <<< "$fl"
  for k in CLASS N NR CHAIN; do
    if [[ "$seen" != *" $k "* ]]; then S1_WHY="报告归类结果缺字段 $k"; S1_REP=""; S1_REP_N=""; S1_REP_NR=""; S1_CHAIN=""; return 2; fi
  done
  if [[ -z "$S1_REP" || ! "$S1_REP_N" =~ ^[0-9]+$ || -z "$S1_CHAIN" ]]; then S1_WHY="报告归类结果不完整"; return 2; fi
  return 0
}
# <<< PDG-EXTRACT-END s1_report
# >>> PDG-EXTRACT-BEGIN s1_precall
s1_dw_precall(){   # 门 17 → 0 成立 / 1 不成立或观测无效(逐项打印); 读数与原文进 06-s1-dw-precall.txt / 06-s1-dw-unit.txt / 06-s1-dw-journal-boot.json
  local st=0 rc rec="$EVID/06-s1-dw-precall.txt" now
  s1_rec "$rec" "# S1 门 17: pdg-dotwitness 调用前读数(只读; 不 reset、不启动、不改限额)"
  if s1_boot_id; then echo "  D 本次 boot ID ${S1_BOOT:0:12}…"; s1_rec "$rec" "boot_id=$S1_BOOT"
  else echo "  D boot ID 未取得: $S1_WHY"; st=1; fi
  if s1_dw_show; then
    s1_rec "$rec" "show: $(s1_dw_line)"
    if [[ "${S1_DW[LoadState]}" == loaded && "${S1_DW[UnitFileState]}" == enabled && "${S1_DW[ActiveState]}" == active && "${S1_DW[SubState]}" == running ]]; then
      echo "  D 调用前 loaded / enabled / active / running(Result=${S1_DW[Result]}; NRestarts=${S1_DW[NRestarts]} 只记原值, 不当作启动次数)"
    else
      echo "  D 调用前 pdg-dotwitness 不是健康运行(${S1_DW[LoadState]} / ${S1_DW[UnitFileState]} / ${S1_DW[ActiveState]} / ${S1_DW[SubState]}, Result=${S1_DW[Result]}) —— 前提不成立"; st=1
    fi
    if [[ "${S1_DW[StartLimitIntervalUSec]}" == 5min && "${S1_DW[StartLimitBurst]}" == 5 ]]; then echo "  D 限额 StartLimitIntervalUSec=5min / StartLimitBurst=5"
    else echo "  D 限额是 ${S1_DW[StartLimitIntervalUSec]} / ${S1_DW[StartLimitBurst]}, 不是冻结前提 5min / 5"; st=1; fi
    if [[ "${S1_DW[FragmentPath]}" == /etc/systemd/system/pdg-dotwitness.service && -z "${S1_DW[DropInPaths]}" ]]; then
      echo "  D 实际 unit /etc/systemd/system/pdg-dotwitness.service, 没有 drop-in"
    else echo "  D 实际 unit 是 [${S1_DW[FragmentPath]}], drop-in [${S1_DW[DropInPaths]}] —— 与冻结前提不符"; st=1; fi
  else echo "  D 调用前读数观测无效: $S1_WHY"; st=1; fi
  if systemctl cat pdg-dotwitness.service > "$EVID/06-s1-dw-unit.txt" 2> "$S1_TMP/dwcat.err"; then echo "  D systemctl cat 原文已留"
  else rc=$?; echo "  D systemctl cat 退出 $rc —— 实际 unit 原文未取得"; st=1; fi
  if journalctl -b 0 -u pdg-dotwitness.service --no-pager -o json > "$EVID/06-s1-dw-journal-boot.json" 2> "$S1_TMP/dwjb.err"; then
    if now="$(s1_mono)" && python3 - "$EVID/06-s1-dw-journal-boot.json" "$now" >> "$rec" 2> "$S1_TMP/dwjb-sum.err" <<'PY'
import json, re, sys
f, now = sys.argv[1], int(sys.argv[2]) // 1000
n = {"start": 0, "slh": 0, "fail": 0}; recent = []
for line in open(f, encoding="utf-8"):
    if not line.strip():
        continue
    d = json.loads(line)
    if d.get("UNIT") != "pdg-dotwitness.service":
        continue
    m, mono = d.get("MESSAGE") or "", int(d.get("__MONOTONIC_TIMESTAMP") or 0)
    k = "start" if re.match(r"Started pdg-dotwitness\.service", m) else ("slh" if "start-limit-hit" in m or "repeated too quickly" in m else ("fail" if "Failed" in m else ""))
    if k:
        n[k] += 1
        if mono and now - mono <= 300 * 1000000:
            recent.append("%+.3fs %s" % ((mono - now) / 1e6, m))
print("本次 boot 的管理器消息(UNIT=pdg-dotwitness.service): 启动 %d 条, 触限 %d 条, 其它失败 %d 条" % (n["start"], n["slh"], n["fail"]))
print("调用前 300 s 内(相对此刻单调时间)的这些事件 %d 条 —— 只供推算额度, 不是 systemd 内部计数:" % len(recent))
for r in recent:
    print("  " + r)
PY
    then echo "  D 本次 boot 的时间线已留(06-s1-dw-journal-boot.json)"
    else echo "  D 时间线解析失败 —— 时间线未取得"; st=1; fi
  else rc=$?; echo "  D journalctl -b 0 -u pdg-dotwitness.service 退出 $rc —— 时间线未取得"; st=1; fi
  return "$st"
}
# <<< PDG-EXTRACT-END s1_precall
# >>> PDG-EXTRACT-BEGIN s1_gated
s1_gated_invoke(){   # 门全过、调用前观测全部取得、计数恰为 0 才调用。返回(10–17 都**没有**调用):
                     #   10=② 结果门 11=桥接身份门 15=DNS 仪器 12=运行态 / WLOC 前像门 17=pdg-dotwitness 调用前门 13=调用前观测
                     #   14=计数读不出 / 不为 0(第二次调用被阻断)/ 单调时钟 / 退出码留档不可用; 0=已调用
  local g
  r3_real2_gate "$R3_REAL2_LOG"; g=$?
  echo "  R2 $R3_WHY"
  (( g == 0 )) || return 10
  r3_bridge_identity_gate; g=$?
  (( g == 0 )) || return 11
  r3_dns_instrument || return 15
  r3_runtime_gate || return 12
  s1_dw_precall || return 17
  r3_precapture || return 13
  if ! r3_count_read; then echo "  调用前停止: 调用计数读不出($R3_WHY)"; return 14; fi
  if [[ "$R3_VAL" != 0 ]]; then echo "  调用前停止: 调用计数已是 $R3_VAL(只许调用一次)"; return 14; fi
  if ! S1_T0="$(s1_mono)"; then echo "  调用前停止: 单调时钟读不了"; return 14; fi
  r3_invoke || { echo "  调用前停止: $R3_WHY"; return 14; }
  S1_T1="$(s1_mono)" || S1_T1=""
  return 0
}
# <<< PDG-EXTRACT-END s1_gated
# >>> PDG-EXTRACT-BEGIN s1_post
s1_dw_post(){   # 调用返回后 → 0 健康 / 1 不健康(S1_POST_WHY) / 2 未取得; 读数进 09-s1-dw-post.txt
  local rec="$EVID/09-s1-dw-post.txt" r
  S1_POST_WHY=""; S1_POST_INV=""
  if ! s1_dw_show; then S1_POST_WHY="调用后读数观测无效: $S1_WHY"; s1_rec "$rec" "$S1_POST_WHY"; return 2; fi
  s1_rec "$rec" "show: $(s1_dw_line)"
  if [[ "${S1_DW[LoadState]}" != loaded || "${S1_DW[UnitFileState]}" != enabled || "${S1_DW[ActiveState]}" != active || "${S1_DW[SubState]}" != running ]]; then
    S1_POST_WHY="调用返回后不是健康运行(${S1_DW[LoadState]} / ${S1_DW[UnitFileState]} / ${S1_DW[ActiveState]} / ${S1_DW[SubState]}, Result=${S1_DW[Result]})"
    s1_rec "$rec" "$S1_POST_WHY"; return 1; fi
  S1_POST_INV="${S1_DW[InvocationID]}"
  s1_listen_owner; r=$?
  s1_rec "$rec" "5399: rc=$r 监听者=${S1_LISTEN:-无} ${S1_WHY:-}"
  if (( r != 0 )); then S1_POST_WHY="5399 监听: $S1_WHY"; (( r == 1 )) && return 1; return 2; fi
  r3_stable_assert pdg-dotwitness running "S1-7 返回后: pdg-dotwitness 持续运行" 5; r=$?
  s1_rec "$rec" "持续运行窗口: rc=$r"
  if (( r != 0 )); then S1_POST_WHY="返回后持续运行窗口 rc=$r(1 = 不稳定, 2 = 观测无效)"; (( r == 1 )) && return 1; return 2; fi
  return 0
}
# <<< PDG-EXTRACT-END s1_post
# >>> PDG-EXTRACT-BEGIN s1_settle
# 分层结算。输入: S1_G S1_GATE_NAME S1_CNT S1_UPG S1_WIN S1_WIN_WHY S1_N_SLHANY S1_N_SLH S1_N_SLHREP S1_N_START S1_N_START_AFTER S1_LAST_KIND
#   S1_REFAIL S1_N_UNATTR S1_N_UNATTR_CRIT S1_N_OTHERU S1_N_FAILX S1_INV_LAST S1_REP S1_REP_N S1_REP_NR S1_CHAIN S1_POST S1_POST_WHY S1_POST_INV
#   S1_UPG_CORE_N S1_UPG_RT_N(383: 层3 的两段失败数, 缺了只说未取得)
# 输出: 逐层一行; S1_VERDICT ∈ PASS UNCOVERED UNOBTAINED RECOVERY_FAILED PRECOND UPGRADE_FAILED, 原因在 S1_VERDICT_WHY。优先级见 382 登记第四节。
# 383: 层5 / 层6 一律按各自取得的事实结算, 不因层2 / 层3 的结论略去; 结论仍按 P → C → U → 恢复层的优先级取, 不放宽。
#   报告是新步骤那一刻的自述, 层7 是调用返回之后的观测: 两者状态不同只分别记录, 不判报告不实, 不推断中间过程; 观测无效不作为报告不实的证据。
s1_settle(){
  local l3 l4 l5 l6 l7 l8 act inv rep="${S1_REP:-}" rv rw
  S1_VERDICT=""; S1_VERDICT_WHY=""
  if [[ "${S1_G:-}" != 0 ]]; then
    echo "  S1 层1 前提: 不成立(门 ${S1_G:-?}: ${S1_GATE_NAME:-未登记}) —— 本场景未执行"
    echo "  S1 层2 调用次数: ${S1_CNT:-未取得}(计数文件; 门未过时应为 0)"
    echo "  S1 层3–8: 未执行(没有调用)"
    S1_VERDICT=PRECOND; S1_VERDICT_WHY="前提不成立(门 ${S1_G:-?}: ${S1_GATE_NAME:-未登记}), 零调用 —— 不计入升级结论"; return 0
  fi
  echo "  S1 层1 前提: 成立(② 结果门、桥接身份门、DNS 仪器、运行态 / WLOC 前像门、pdg-dotwitness 调用前门、调用前观测、计数门全过)"
  echo "  S1 层2 调用次数: ${S1_CNT:-未取得}(计数文件)"
  if [[ "${S1_UPG_CORE_N:-}" =~ ^[0-9]+$ && "${S1_UPG_RT_N:-}" =~ ^[0-9]+$ ]]; then
    l3="进程 / 目标到达 / 撤除·迁移·保留判据失败 ${S1_UPG_CORE_N} 项; 运行态 / 服务对账失败 ${S1_UPG_RT_N} 项(共享判据; 含 pdg-dotwitness 的 active 检查与终态对账行, 与层7 同一对象; 共享判据把观测无效也记为失败)"
  else l3="两段失败数未取得"; fi
  case "${S1_UPG:-}" in OK) echo "  S1 层3 升级与目标到达: 成立($l3)";; FAIL) echo "  S1 层3 升级与目标到达: 不成立($l3; 逐项见上面 S1-2 / S1-3 / S1-4)";; *) echo "  S1 层3 升级与目标到达: 未取得($l3)";; esac
  if [[ "${S1_WIN:-}" != OK ]]; then l4="未取得(${S1_WIN_WHY:-窗口无效})"
  elif (( ${S1_N_UNATTR_CRIT:-0} > 0 )); then l4="未取得(窗口里有 ${S1_N_UNATTR_CRIT} 条触限 / 失败类事件取不到目标归属字段)"
  elif (( ${S1_N_SLHANY:-0} > 0 )); then l4="调用窗口内观测到触限(Failed with result 'start-limit-hit' ${S1_N_SLH} 条、Start request repeated too quickly ${S1_N_SLHREP} 条; journal 直接)"
  else l4="调用窗口内未观测到触限(journal 直接; 窗口内目标事件 ${S1_N_EV:-0} 条)"; fi
  echo "  S1 层4 触限: $l4"
  case "${S1_POST:-}" in OK) l7="健康(loaded / enabled / active / running, 5399 监听者都在该 unit 的 cgroup, 持续运行窗口成立)";;
                         BAD) l7="不健康(${S1_POST_WHY:-})";; *) l7="未取得(${S1_POST_WHY:-})";; esac
  case "$rep" in
    RECOVERED) act="产品自述: 观察到限额命中, reset-failed 退出 0、start 退出 0(各一次; 自述, 不是动作记录)";;
    SLH_RESET_FAIL) act="产品自述: 观察到限额命中, reset-failed 失败、未执行 start";;
    SLH_START_FAIL) act="产品自述: 观察到限额命中, reset-failed 退出 0、start 失败";;
    SLH_POST_UNOBS|SLH_POST_NOTREADY) act="产品自述: 观察到限额命中, reset-failed 退出 0、start 退出 0, 但恢复后未确认";;
    INCOMPLETE) act="产品自述: 核验未完成(核验过程异常退出); 由该报告推不出是否执行过 reset-failed / start, 也推不出恢复分支是否进入";;
    PASS|UNOBS|UFS|NOLISTEN|FOREIGN|NOTREADY) act="产品自述: 本步没有做恢复动作(报告类别 $rep)";;
    *) act="产品自述未取得(报告类别 ${rep:-未取得})";;
  esac
  if [[ "${S1_INV_LAST:--}" != "-" && -n "${S1_POST_INV:-}" ]]; then
    [[ "$S1_INV_LAST" == "$S1_POST_INV" ]] && inv="是(窗口内最后一次启动事件的 INVOCATION_ID = 返回后的 InvocationID)" || inv="否(窗口内最后一次启动事件的 INVOCATION_ID ≠ 返回后的 InvocationID)"
  else inv="未取得(启动事件没有 INVOCATION_ID 字段或返回后读数未取得; 只影响实例对照)"; fi
  l8="$act; 源码上限: 新步骤 reset-failed ≤ 1、start ≤ 1, 迁移链内 migrate_dotwitness 也可 reset-failed / enable --now / restart, 桥接父进程对 dotwitness 无直接动作;"
  l8="$l8 journal: 窗口内目标启动事件 ${S1_N_START:-?} 条(末次触限之后 ${S1_N_START_AFTER:-?} 条), 来源未取得; reset-failed 的次数与调用者: 未取得(没有动作记录); 实例对照: $inv"
  (( ${S1_N_OTHERU:-0} > 0 )) && l8="$l8; 另有 ${S1_N_OTHERU} 条记录归属别的 unit(已排除, 见窗口留证)"
  (( ${S1_N_UNATTR:-0} > 0 )) && l8="$l8; ${S1_N_UNATTR} 条记录取不到归属字段(见窗口留证)"
  # 恢复层(层5 / 层6)与它自己的结论候选 rv / rw
  if [[ "${S1_WIN:-}" != OK ]] || (( ${S1_N_UNATTR_CRIT:-0} > 0 )); then
    l5="未取得(触限层未取得)"; l6="不判(触限层未取得; 报告类别 ${rep:-未取得})"
    rv=UNOBTAINED; rw="触限层未取得: $l4"
  elif (( ${S1_N_SLHANY:-0} == 0 )); then
    l5="未覆盖(调用窗口内没有观测到触限 —— 恢复分支的覆盖证据未取得)"
    case "$rep" in
      PASS) case "${S1_POST:-}" in
              OK) l6="一致(报告核验通过, 窗口内无触限, 返回后健康)";;
              BAD) l6="分别记录: 报告(新步骤时点)核验通过; 返回后观测不健康(${S1_POST_WHY:-}) —— 两个时点不同, 没有阶段证据, 不推断中间发生了什么, 不据此判报告不实";;
              *) l6="不判(返回后健康未取得; 观测无效不作为报告不实的证据)";;
            esac;;
      NONE|DUPLICATE|CONFLICT|UNRECOGNIZED|"") l6="报告未取得或无法采信(类别 ${rep:-未取得}, ${S1_REP_N:-?} 条)";;
      INCOMPLETE) l6="分别记录: 报告为核验未完成(推不出是否做过恢复动作); 返回后: $l7";;
      *) l6="分别记录: 报告(新步骤时点)类别 $rep; 返回后: $l7 —— 两个时点不同, 不据此判报告不实";;
    esac
    rv=UNCOVERED; rw="调用窗口内没有观测到触限 —— 新步骤的恢复分支未覆盖(不重试, 不计恢复通过)"
  elif [[ "${S1_POST:-}" == BAD ]]; then
    l5="恢复失败(调用返回后直接观测到不健康: ${S1_POST_WHY:-})"
    case "$rep" in
      SLH_RESET_FAIL|SLH_START_FAIL|SLH_POST_UNOBS|SLH_POST_NOTREADY) l6="一致(报告与返回后不健康都表明恢复没有成立; 两者是不同时点的观测)";;
      NONE|DUPLICATE|CONFLICT|UNRECOGNIZED|"") l6="报告未取得或无法采信(类别 ${rep:-未取得}, ${S1_REP_N:-?} 条); 返回后不健康";;
      INCOMPLETE) l6="分别记录: 报告为核验未完成(推不出是否做过恢复动作); 返回后不健康";;
      *) l6="分别记录: 报告(新步骤时点)类别 $rep; 返回后观测不健康 —— 两个时点不同, 没有阶段证据, 不推断中间发生了什么, 不判报告不实";;
    esac
    rv=RECOVERY_FAILED; rw="观测到触限, 调用返回后不健康: ${S1_POST_WHY:-}"
  elif [[ "${S1_POST:-}" != OK ]]; then
    l5="未取得(返回后健康未取得: ${S1_POST_WHY:-})"; l6="不判(返回后健康未取得)"
    rv=UNOBTAINED; rw="返回后健康未取得"
  elif (( ${S1_REFAIL:-0} > 0 )); then
    l5="未取得(窗口里出现 触限 → 启动 → 再次触限 ${S1_REFAIL} 次; 无法确定哪一次启动来自新步骤、恢复是否保持)"; l6="不判(恢复现象未取得)"
    rv=UNOBTAINED; rw="窗口里出现再次触限, 恢复的保持与来源未取得"
  elif (( ${S1_N_START_AFTER:-0} == 0 )) || [[ "${S1_LAST_KIND:-}" != start ]]; then
    l5="未取得(返回后健康, 但窗口里末次触限之后没有启动事件或末态事件不是启动: 末态 ${S1_LAST_KIND:-?})"; l6="不判(窗口与终态对不上)"
    rv=UNOBTAINED; rw="窗口与终态对不上"
  else
    l5="取得(末次触限之后有 ${S1_N_START_AFTER} 次启动事件, 调用返回后健康)"
    (( S1_N_START_AFTER > 1 )) && l5="$l5; 末次触限之后启动事件 ${S1_N_START_AFTER} 次 —— 来源未取得, 不判为重复恢复"
    case "$rep" in
      RECOVERED) l6="一致(报告已恢复, 与观测到的触限、其后的启动与返回后健康一致)"
                 rv=PASS; rw="本次调用窗口观测到触限后恢复, 调用返回后健康, 与新步骤报告一致; 精确动作次数和来源未直接取得";;
      PASS|UNOBS|UFS|NOLISTEN|FOREIGN|NOTREADY)
                 if [[ "$rep" == PASS ]]; then l6="部分一致(报告核验通过与返回后健康一致, 但没有提到窗口内的触限)"
                 else l6="分别记录: 报告(新步骤时点)类别 $rep, 自述本步未做恢复动作; 窗口内有触限、返回后健康 —— 两个时点不同, 其后启动的来源未取得"; fi
                 rv=UNCOVERED; rw="观测到触限后恢复, 但新步骤报告 $rep(没有做恢复动作) —— 新步骤的恢复分支未覆盖, 恢复来源未取得";;
      INCOMPLETE) l6="不判(报告为核验未完成: 推不出是否执行过 reset-failed / start, 也推不出恢复分支是否进入)"
                 rv=UNOBTAINED; rw="新步骤报告核验未完成 —— 恢复分支是否进入、恢复来源未取得";;
      SLH_RESET_FAIL|SLH_START_FAIL|SLH_POST_UNOBS|SLH_POST_NOTREADY)
                 l6="分别记录: 报告(新步骤时点)恢复未成立或未确认; 返回后健康 —— 两个时点不同, 中间发生了什么未取得"
                 rv=UNOBTAINED; rw="新步骤报告恢复未成立或未确认, 返回后健康 —— 新步骤的恢复是否成立未取得";;
      *)         l6="报告未取得或无法采信(类别 ${rep:-未取得}, ${S1_REP_N:-?} 条)"; rv=UNOBTAINED; rw="新步骤报告未取得或无法采信";;
    esac
  fi
  # 结论(优先级不变): C 调用次数 → U 升级层 → 恢复层
  if [[ -z "${S1_CNT:-}" || "${S1_CNT}" != 1 ]]; then
    S1_VERDICT=UNOBTAINED; S1_VERDICT_WHY="调用次数 ${S1_CNT:-未取得}(应为 1)"
  elif [[ "${S1_UPG:-}" != OK ]]; then
    [[ "${S1_CHAIN:-}" == failed && "$rep" == NONE ]] && l6="新步骤按路径不应执行(迁移链失败, 桥接父进程回滚)"
    if [[ "${S1_UPG:-}" == FAIL ]]; then S1_VERDICT=UPGRADE_FAILED; S1_VERDICT_WHY="升级层不成立($l3)"; else S1_VERDICT=UNOBTAINED; S1_VERDICT_WHY="升级层未取得($l3)"; fi
  else S1_VERDICT="$rv"; S1_VERDICT_WHY="$rw"; fi
  [[ "$S1_VERDICT" == "$rv" && "$S1_VERDICT_WHY" == "$rw" ]] || l5="$l5; 本层事实照记, 结论由层2 / 层3 优先给出"
  echo "  S1 层5 恢复现象: $l5"
  echo "  S1 层6 产品报告与观测: $l6"
  echo "  S1 层7 调用返回后健康: $l7"
  echo "  S1 层8 动作次数与来源: $l8"
  return 0
}
s1_verdict_say(){   # 按 S1_VERDICT 给一个判词(PASS 之外一律 bad, 判词写明类别)
  case "${S1_VERDICT:-}" in
    PASS) ok "S1 结论: 恢复分支证据取得 —— ${S1_VERDICT_WHY}";;
    UNCOVERED) bad "S1 结论: 未覆盖 —— ${S1_VERDICT_WHY}";;
    UNOBTAINED) bad "S1 结论: 未取得 —— ${S1_VERDICT_WHY}";;
    RECOVERY_FAILED) bad "S1 结论: 恢复失败 —— ${S1_VERDICT_WHY}";;
    PRECOND) bad "S1 结论: 前提不成立 —— ${S1_VERDICT_WHY}";;
    UPGRADE_FAILED) bad "S1 结论: 升级失败 —— ${S1_VERDICT_WHY}";;
    *) bad "S1 结论: 结算没有给出登记的类别([${S1_VERDICT:-}]) —— 按未取得处理";;
  esac
}
# <<< PDG-EXTRACT-END s1_settle
# >>> PDG-EXTRACT-BEGIN s1_r3_const
# ③ 681–707 原文逐行照抄(契约逐行核对); 本支的 R3_TMP 已指向自己的临时目录。
BRIDGE_SHA="${PDG_BRIDGE_SHA:-}"; RETIRE_SHA="${PDG_RETIRE_SHA:-}"
[[ "$BRIDGE_SHA" =~ ^[0-9a-f]{40}$ ]] || _hard "必须显式给出 40 位桥接 SHA(PDG_BRIDGE_SHA)"
[[ "$RETIRE_SHA" =~ ^[0-9a-f]{40}$ ]] || _hard "必须显式给出 40 位退役候选 SHA(PDG_RETIRE_SHA)"
BRIDGE_TAG="v9.9.8-bridge-TEST"; RETIRE_TAG="v9.9.9-retire-TEST"   # 与 ② 的合成 tag 同名; 身份由 B8 现查
R3_REAL2_LOG="${PDG_REAL2_LOG:-}"
R3_REPO=/opt/privdns-gateway; R3_CLI=/usr/local/bin/pdg; R3_MODDIR=/opt/pdg-bot; R3_ETC=/etc/privdns-gateway
R3_OBJ="$E2E_ROOT"                           # 本 job 检出的对象库(含取到的桥接 / 退役分支)
R3_LOG="$R3_TMP/retire-update.log"; R3_TIMEOUT="${PDG_RETIRE_HOP_TIMEOUT:-900}"
R3_RCFILE="$R3_TMP/retire-update.rc"; R3_TOERR="$R3_TMP/retire-update.timeout-stderr"
R3_BRSRC="$R3_TMP/brsrc"; R3_RTSRC="$R3_TMP/rtsrc"
SNAPROOT=/var/lib/privdns-gateway/backups
IOS_META=/etc/privdns-gateway/ios-profile.json; IOS_ART=/var/lib/privdns-gateway/ios-profile
MJ=/etc/privdns-gateway/mitm.json; HIJ=/etc/mosdns/rules/mitm_hijack.txt; MC=/etc/mihomo/config.yaml
CA_DIR=/etc/privdns-gateway/ca
R3_MITM_UNIT=/etc/systemd/system/pdg-mitm.service
KREQ=("$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$R3_ETC/platform")
KOPT=("$R3_ETC/bot.env" "$R3_MODDIR/dot-domain")
declare -A KFP=()                             # 调用前指纹; 由 r3_keep_capture 填
# DNS 仪器(见 r3_dns 段): U = 自有上游固定答案, H = 产品规定的劫持地址 E2E_SIP; 名字每次运行新造(W 除外)
R3_DNS_U=198.51.100.7; R3_DNS_PORT=15301; R3_DNS_W=gs-loc.apple.com
R3_STUB="$E2E_ROOT/tests/helpers/dns-stub.py"; R3_STUB_PID=""; R3_DNS_RESTARTS=0
R3_UPLOG="$R3_TMP/dns-up.log"; R3_UPCNT="$R3_TMP/dns-up.count"; R3_UPOUT="$R3_TMP/dns-up.out"
R3_MONO=(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')   # 准备阶段静置的实得时长以它(CLOCK_MONOTONIC)为准
R3_MOSCFG=/etc/mosdns/config.yaml; R3_GEOCN=/etc/mosdns/rules/geosite_cn.txt
_sfx="$$-$RANDOM"
R3_DNS_K="r3k-$_sfx.e2e.test"; R3_DNS_CPRE="r3c-pre-$_sfx.e2e.test"; R3_DNS_CPOST="r3c-post-$_sfx.e2e.test"
R3_DNS_PPRE="r3p-pre-$_sfx.e2e.test"; R3_DNS_PPOST="r3p-post-$_sfx.e2e.test"
# <<< PDG-EXTRACT-END s1_r3_const

SECT "S1-0 前置: ② 的结果与桥接前像(任一不成立就停在调用之前)"
for c in git python3 ss dig curl sha256sum timeout comm cmp stat diff journalctl systemctl; do command -v "$c" >/dev/null || _hard "缺命令: $c"; done
for s in "$BRIDGE_SHA" "$RETIRE_SHA"; do
  [[ "$(git -C "$R3_OBJ" cat-file -t "$s" 2>/dev/null)" == commit ]] || _hard "本 job 的检出里取不到对象 $s"
done
mkdir -p "$R3_BRSRC" "$R3_RTSRC"
git -C "$R3_OBJ" archive "$BRIDGE_SHA" | tar -x -C "$R3_BRSRC" || _hard "展开桥接树失败"
git -C "$R3_OBJ" archive "$RETIRE_SHA" | tar -x -C "$R3_RTSRC" || _hard "展开候选树失败"
S1_RECBAD=0

# >>> PDG-EXTRACT-BEGIN s1_r3_inline
# ③ 1456–1527 的内联判据原文逐字复制, 只把判词前缀 "③-" 换成 "S1-"(契约逐字核对); 包成函数, 由主流程调用一次。
s1_inline_post(){
if r3_modules "$R3_RTSRC" "$R3_MODDIR"; then
  _m="$R3_VAL"
  [[ "${_m#* }" == 0 ]] && ok "S1-2 A4 ios 模块 ${_m% *} 项逐字节 = 退役树" || bad "S1-2 A4 ios 模块有 ${_m#* } 项与退役树不同(共 ${_m% *})"
else bad "S1-2 A4 观测无效: $R3_WHY"; fi
if r3_lsdir "$SNAPROOT"; then
  SNAP_AFTER="$R3_VAL"
  if r3_snapdiff "$SNAP_BEFORE" "$SNAP_AFTER"; then
    _new="$R3_VAL"
    if [[ "$(grep -c . <<<"$_new")" == 1 && -s "$SNAPROOT/$_new/snap.tar.gz" && -s "$SNAPROOT/$_new/svcstate.tsv" ]]; then
      ok "S1-2 A6 本次升级由产品新建了 1 个快照($_new, 含 snap.tar.gz 与 svcstate.tsv)"
    else bad "S1-2 A6 新快照不是恰 1 个或缺件(新增: [$(tr '\n' ' ' <<<"$_new")])"; fi
  else bad "S1-2 A6 观测无效: $R3_WHY"; fi
else bad "S1-2 A6 观测无效: 调用后快照目录清单没取得($R3_WHY)"; fi

SECT "S1-3 WLOC 撤除 / 保留 / 迁移"
r3_post_w1
for _f in /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py; do
  [[ -e "$_f" ]] && bad "S1-3 W2 $_f 还在" || ok "S1-3 W2 $_f 已删"
done
if [[ ! -e "$HIJ" ]]; then ok "S1-3 W3 接管表不存在(无条目)"
elif _raw="$(cat -- "$HIJ" 2>/dev/null)"; then
  _hn=0
  while IFS= read -r _l; do
    _l="${_l#"${_l%%[![:space:]]*}"}"
    [[ -z "$_l" || "$_l" == \#* ]] || _hn=$((_hn+1))
  done <<<"$_raw"
  [[ "$_hn" == 0 ]] && ok "S1-3 W3 接管表无条目(文件在)" || bad "S1-3 W3 接管表仍有 $_hn 条"
else bad "S1-3 W3 观测无效: 接管表读不了"; fi
r3_grepq 'MITM-OUT' "$MC"; _g=$?
case "$_g" in 1) ok "S1-3 W4 内核配置里已无 MITM-OUT";; 0) bad "S1-3 W4 内核配置里仍有 MITM-OUT";; *) bad "S1-3 W4 观测无效: 内核配置读不了($R3_WHY)";; esac
if python3 - "$R3_TMP/ios-before.json" "$IOS_META" "$IOS_ART/current.mobileconfig" "$R3_TMP/mitm-before.json" "$MJ" \
     > "$R3_TMP/w56.txt" 2>&1 <<'PY'
import json, os, stat, sys
b = json.load(open(sys.argv[1], encoding="utf-8")); a = json.load(open(sys.argv[2], encoding="utf-8"))
cur = b["current"]
exp = dict(cur["inputs"]); exp.pop("wloc_enabled", None); exp.pop("wloc_ca_sha256", None); exp["schema"] = 2
checks = [
    ("W6 schema 1 → 2", b.get("schema") == 1 and a.get("schema") == 2),
    ("W6 instance_id 原样", a.get("instance_id") == b.get("instance_id")),
    ("W6 created_at 原样", a.get("created_at") == b.get("created_at")),
    ("W6 current / previous 都为 null(嵌 CA 的版本被退役)", a.get("current") is None and a.get("previous") is None),
    ("W6 retired_revision == 调用前 current.revision(%s)" % cur.get("revision"), a.get("retired_revision") == cur.get("revision")),
    ("W6 retired_inputs == 调用前 current.inputs 去掉 wloc 字段(用户名单原样)", a.get("retired_inputs") == exp),
    ("W6 current.mobileconfig 已删", not os.path.exists(sys.argv[3])),
]
mb = json.load(open(sys.argv[4], encoding="utf-8")); ma = json.load(open(sys.argv[5], encoding="utf-8"))
mb2 = json.loads(json.dumps(mb)); mb2.setdefault("wloc", {})["enabled"] = False
checks += [
    ("W5 mitm.json wloc.enabled == false", ma.get("wloc", {}).get("enabled") is False),
    ("W5 mitm.json 其余内容与调用前逐项相同", ma == mb2),
    ("W5 mitm.json mode 600", stat.S_IMODE(os.stat(sys.argv[5]).st_mode) == 0o600),
]
bad = 0
for name, good in checks:
    print(("OK   " if good else "FAIL ") + name); bad += 0 if good else 1
sys.exit(3 if bad else 0)          # 3 = 有核对不通过; 其它非零(含未捕获异常的 1)= 观测无效
PY
then _w56=0; else _w56=$?; fi
while IFS= read -r _l; do
  case "$_l" in "OK   "*) ok "S1-3 ${_l#OK   }";; "FAIL "*) bad "S1-3 ${_l#FAIL }";; *) note "S1-3 $_l";; esac
done < "$R3_TMP/w56.txt"
(( _w56 == 0 || _w56 == 3 )) || bad "S1-3 W5/W6 观测无效: 核对脚本异常退出($_w56) —— 记录读不了"
for _p in '✅ WLOC 位置改写及其专属 MITM 执行能力已退役|W7 产品自报 WLOC 执行能力已退役' \
          '✅ iOS 描述文件记录已迁移到新格式|W7 产品自报 iOS 记录已迁到新格式' \
          '盘上仍有 WLOC 时期的 CA 材料|K1 产品按保留策略报告 CA 材料仍在'; do
  r3_grepq -F "${_p%%|*}" "$R3_LOG"; _g=$?
  case "$_g" in 0) ok "S1-3 ${_p#*|}";; 1) bad "S1-3 ${_p#*|}: 日志里没有「${_p%%|*}」";; *) bad "S1-3 ${_p#*|}: 观测无效($R3_WHY)";; esac
done
r3_keep_verdict
if _p="$(cat -- "$R3_ETC/platform" 2>/dev/null)"; then
  [[ "$_p" == ios ]] && ok "S1-3 K2 平台标记仍是 ios" || bad "S1-3 K2 平台标记变了([$_p])"
else bad "S1-3 K2 观测无效: 平台标记读不了"; fi
}
# <<< PDG-EXTRACT-END s1_r3_inline

snap_state "s1-before"      # 仅留档, 不参与任何判据

# ── 门 + 调用前观测 + 唯一升级入口 ─────────────────────────────────────────────
SECT "S1-1 门全过、调用前观测取全才调用: 现役桥接 CLI 执行 update --to $RETIRE_TAG(不施加准备阶段静置)"
_cnt_say(){ if r3_count_read; then printf '%s' "$R3_VAL"; else printf '读不出(%s)' "$R3_WHY"; fi; }
S1_T0=""; S1_T1=""
s1_gated_invoke; S1_G=$?
case "$S1_G" in
  0)  S1_GATE_NAME="";;
  10) S1_GATE_NAME="② 结果门";;
  11) S1_GATE_NAME="桥接身份门";;
  15) S1_GATE_NAME="DNS 仪器条件 / 标定 / 还原核验";;
  12) S1_GATE_NAME="运行态 / WLOC 前像门";;
  17) S1_GATE_NAME="pdg-dotwitness 调用前门";;
  13) S1_GATE_NAME="调用前观测没取全";;
  14) S1_GATE_NAME="调用计数 / 单调时钟 / 退出码留档不可用";;
  *)  S1_GATE_NAME="门返回了未登记的值 $S1_G";;
esac
if [[ "$S1_G" != 0 ]]; then
  if r3_count_read; then S1_CNT="$R3_VAL"; else S1_CNT=""; fi
  SECT "S1-5 分层结算"
  s1_settle > "$S1_TMP/settle.out"; cat "$S1_TMP/settle.out"; s1_rec "$EVID/99-s1-summary.txt" "$(cat "$S1_TMP/settle.out")"
  s1_verdict_say
  nrun "场景 S-1: $S1_GATE_NAME(调用计数 $(_cnt_say))"; e2e_summary; exit 1
fi
ok "S1-0 ② 结果门、桥接身份门、DNS 仪器(条件 / 标定 / 还原)、运行态 / WLOC 前像门、pdg-dotwitness 调用前门全部成立且调用前观测取全后才调用(调用计数 $(_cnt_say))"
S1_C1="$(_j_mark s1-end)" || { S1_C1=""; note "阶段记账: 止界桩没建成($(_j_why)) —— 窗口将判观测无效"; }
cp "$R3_LOG" "$EVID/04-s1-update.log" 2>/dev/null && chmod 600 "$EVID/04-s1-update.log" 2>/dev/null \
  || note "升级日志没能复制进证据目录"
cp "$R3_RCFILE" "$EVID/04-s1-update.rc" 2>/dev/null; cp "$R3_TOERR" "$EVID/04-s1-update.timeout-stderr" 2>/dev/null
s1_rec "$EVID/07-s1-dw-window.txt" "调用前一刻 CLOCK_MONOTONIC = ${S1_T0:-未取得} ns; 调用返回后一刻 = ${S1_T1:-未取得} ns(只用于排序, 不作阶段边界)"
tail -40 "$R3_LOG" 2>/dev/null | sed 's/^/    /'

# >>> PDG-EXTRACT-BEGIN s1_main
# 383: 调用返回之后的主流程接线(S1-2 … S1-5)原样包成函数, 主流程只调用一次; 契约的组合格按这对标记抽出原样执行。
# 层3 另记两段失败数(进程 / 到达 / 撤除·迁移·保留; 运行态 / 服务对账), 只作层3 的子项写出, 不改 S1_UPG 的判法、不清零任何失败。
s1_after_call(){
S1_UPG_FAIL0="$E2E_FAIL"
SECT "S1-2 逐维验收"
r3_arrival_verdict && ok "S1-2 进程状态 / 目标到达 / 观测有效性分别成立" \
                   || bad "S1-2 进程 $R3_PROC / 目标到达 $R3_ARRIVE / 观测 $R3_OBS —— 不成立"
_evn 03-s1-identity.txt "workflow checkout = ${GITHUB_SHA:-<非 CI>}"
_evn 03-s1-identity.txt "桥接 = $BRIDGE_TAG → $BRIDGE_SHA; 候选 = $RETIRE_TAG → $RETIRE_SHA; 取件源 = $R3_ORIGIN"
_evn 03-s1-identity.txt "调用 = bash $R3_CLI update --to $RETIRE_TAG(经 timeout --verbose $R3_TIMEOUT); 调用计数 = $(_cnt_say); 包装器(timeout)返回码 = ${R3_WRAP_RC:-未取得}; 产品原始退出码 = ${R3_RC:-未取得}"
s1_inline_post
S1_UPG_FAIL1="$E2E_FAIL"

SECT "S1-4 服务与真实功能"
r3_post_runtime
snap_state "s1-after"; bridge_svc_sample "$R3_TMP/svc-retire-after.tsv" || note "调用后服务采样写不出来 —— 对账将判集合不全"
WIN_TSV="$R3_TMP/svc-retire-window.tsv"; : > "$WIN_TSV"
for _u in "${SVC_WATCH[@]}"; do
  if [[ -z "${C3_0:-}" || -z "${S1_C1:-}" ]]; then printf '%s\tINVALID\t界桩没建成: %s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"; continue; fi
  if _n="$(_j_interval "$_u" "$C3_0" "$S1_C1")" && [[ -n "$_n" ]]; then printf '%s\t%s\t-\n' "$_u" "$_n" >> "$WIN_TSV"
  else printf '%s\tINVALID\t%s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"; fi
done
sed 's/^/    /' "$WIN_TSV"
r3_svc_verdict "$R3_TMP/svc-retire-before.tsv" "$R3_TMP/svc-retire-after.tsv" retire "$WIN_TSV"
cp "$R3_TMP/svc-retire-before.tsv" "$R3_TMP/svc-retire-after.tsv" "$WIN_TSV" "$EVID/" 2>/dev/null
if [[ "${R3_OBS:-}" != VALID || "${R3_ARRIVE:-}" == UNKNOWN ]]; then S1_UPG=UNKNOWN
elif (( E2E_FAIL > S1_UPG_FAIL0 )); then S1_UPG=FAIL
else S1_UPG=OK; fi
S1_UPG_CORE_N=$((S1_UPG_FAIL1 - S1_UPG_FAIL0)); S1_UPG_RT_N=$((E2E_FAIL - S1_UPG_FAIL1))

SECT "S1-5 pdg-dotwitness: 触限、恢复、报告与返回后健康(分层结算)"
S1_WIN=INVALID; S1_WIN_WHY=""
if [[ -z "${S1_BOOT:-}" ]]; then s1_boot_id || true; fi
if s1_jwin pdg-dotwitness.service "${C3_0:-}" "${S1_C1:-}" "$EVID/07-s1-dw-window.tsv"; then
  if s1_jsum "$EVID/07-s1-dw-window.tsv"; then S1_WIN=OK; else S1_WIN_WHY="$S1_WHY"; fi
else S1_WIN_WHY="$S1_WHY"; fi
sed 's/^/    /' "$EVID/07-s1-dw-window.tsv" 2>/dev/null | cut -c1-260
s1_jwin mosdns.service "${C3_0:-}" "${S1_C1:-}" "$EVID/07-s1-mosdns-window.tsv" || note "mosdns 窗口事件没取得($S1_WHY) —— 只影响 PartOf 背景列举, 不作阶段边界"
if s1_report "$R3_LOG" "$EVID/08-s1-settle-report.txt"; then echo "  报告: 类别 $S1_REP, ${S1_REP_N} 条; 迁移链 $S1_CHAIN"
else S1_REP=""; S1_REP_N=""; S1_CHAIN=""; echo "  报告未取得: $S1_WHY"; fi
s1_dw_post; case $? in 0) S1_POST=OK;; 1) S1_POST=BAD;; *) S1_POST=UNOBT;; esac
if r3_count_read; then S1_CNT="$R3_VAL"; else S1_CNT=""; fi
s1_settle > "$S1_TMP/settle.out"; cat "$S1_TMP/settle.out"; s1_rec "$EVID/99-s1-summary.txt" "$(cat "$S1_TMP/settle.out")"
s1_verdict_say
(( S1_RECBAD == 0 )) || bad "S1 留证: 有记录写不进证据目录(S1_RECBAD) —— 相关原文不完整"
}
# <<< PDG-EXTRACT-END s1_main
s1_after_call

SECT "S1-6 收尾"
{
  echo "# 本支在这台一次性 runner 上的动作: 只有一次 bash $R3_CLI update --to $RETIRE_TAG(调用计数 $(_cnt_say)); 没有施加准备阶段静置"
  echo "# 前像来源: 同一 job 上一步 ② 的真实现场(本支调用前逐项现查), 调用前经 DNS 仪器调整(05-dns-instrument-adjustments.txt); 取件源 $R3_ORIGIN"
  echo "# DNS 仪器重启 $R3_DNS_RESTARTS 次(05-dns-instrument-restarts.txt), 都在调用前观测起界桩之前"
  echo "# 退出码: 包装器(timeout)返回码 ${R3_WRAP_RC:-未取得}; 产品原始退出码 ${R3_RC:-未取得}"
  echo "# S1 结论: ${S1_VERDICT:-未给出} —— ${S1_VERDICT_WHY:-}"
  echo "# 动作次数与调用者: 未取得(没有 systemctl 动作记录); journal 只给事件, 产品报告只是自述(见 99 文件的层8)"
  echo "# 不覆盖: F-1(待定)、④、A-off、B / C2、v1.7.8、完整旧安装器、官方分发来源、发布; 本次结果不外推到桥接后续所有分支, 不追认 324 / 374 的根因"
  echo "# 证据文件"; ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-s1-summary.txt
chmod 600 "$EVID"/* 2>/dev/null || true
echo; echo "未执行(前像/前置不成立而跳过)的场景数: $E2E_NOTRUN"
e2e_summary
