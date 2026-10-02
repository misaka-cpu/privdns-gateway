#!/usr/bin/env bash
# shellcheck disable=SC2034  # 全文件: 大量全局变量由运行时按标记抽进来的共享函数(③ / ② / ⑤ 原文)按名字读取, 静态看不到
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 B / C2 两跳: v1.11.15 前像 → 桥接入口(桥接候选 docs/BRIDGE-ENTRY.md 的成对标记段)→ 已装桥接 CLI 的
#     bash /usr/local/bin/pdg update --to <退役候选的合成 tag>
# 两跳在同一台一次性 runner 上由产品自己的入口完成; 本支不预装候选、不手造能力句柄或服务前像。
#
# 前像(PDG_BC_PREIMAGE):
#   b  = iOS、从未启用 WLOC、有一份 wloc=false 的描述文件。构造 = 夹具组装 + v1.11.15 自己的 `pdg migrate` 恰一次。
#        原始退出码、完成文字、新快照与收敛后的终态分别核验; 任一不成立就停止构造, 不换另一条路线补。
#        这不是完整旧安装器装出的现场, 也不是未经迁移的旧现场。
#   c2 = Android、仅 CA 残留(合法来路)。构造 = 共享 build_preimage ios on(原样调用, 不加首次启动包装)→ 防火墙加载
#        → v1.11.15 自己的 `pdg platform android` 恰一次。build_preimage 内部那几条首次启动命令的退出码被它自己吞掉:
#        本支只证明"构造结束时现场有效", 那几条命令的退出码记未取得; 函数返回 0 不单独作有效依据。
# C2 的保留维(360 选择甲): Android 上保留旧 schema-1 记录与含根证书的旧描述文件, 要求与前像一致。这是验收契约选择, 不是从
#   当前代码反推"理应通过"; 不宣称旧文件已清除、手机上的信任已撤销或任何分发渠道都不可用; 未来转回 iOS 的行为不外推。
# 两段 303 s 静置(第二跳前 / 第三跳前)是本验收人为规定的验收时序前提, 各自独立留证; 不证明它们必需, 不消除 324 的产品问题。
# DNS: 在本 runner 上做既有 K 的 U→H→U 标定(③ r3_dns_calibrate 原文), 磁盘与运行还原分别核实; 固定 W 只在第三跳之后查询;
#   C / P 前后各用新造的名字; 不要求 mosdns 在升级前后换实例, 只要求每次查询期间实例稳定。U 要求该次窗口内上游增量 ≥ 1,
#   H 要求为 0; 答案对但来源不足记未取得。仪器 / 标定 / 还原不成立 ⇒ 第三跳不调用。第二跳只给配置层结论。
# 复用: 一律按唯一成对标记从 ⑤ / ② / ③ 抽原文(不 source 整支); 359 复用表标为"仅参考结构"的函数不调用(新契约逐个核)。
# 观测有效性: 每次读取先看它自己的退出码与格式; 读失败 / 半截输出不消费, 不当成"零""原样"或"不存在"。
# 不覆盖: ④ 晚期失败恢复、A-off、C1、完整旧安装器、官方分发来源、发布。前提缺一即硬停, 只许在一次性 GitHub runner 上跑。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

_hard(){ echo "[HARD-STOP] $1" >&2
  if declare -F bc_counts_say >/dev/null; then echo "调用次数: $(bc_counts_say)" >&2
  else echo "调用次数: 计数还没建(读取器还没装好)" >&2; fi
  exit 1; }
[[ "${PDG_REAL_MIGRATION_OK:-}" == 1 ]] || _hard "缺 PDG_REAL_MIGRATION_OK=1 —— 这支会真的改本机 systemd 与 /etc。"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || _hard "不在 GitHub Actions 里 —— 拒绝在开发机/生产机上执行。"
[[ "${RUNNER_OS:-}" == "Linux" ]] || _hard "RUNNER_OS=${RUNNER_OS:-<空>}, 只支持 Linux runner。"
[[ "$(id -u)" == 0 ]] || _hard "需要 root。"
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || _hard "需要 PDG_E2E_ISOLATED=1。"
EVID="${PDG_BC_EVID:-}"
[[ "$EVID" == /* ]] || _hard "必须显式给出证据目录的绝对路径(PDG_BC_EVID)"
BC_PRE="${PDG_BC_PREIMAGE:-}"
case "$BC_PRE" in b) BC_PLAT=ios;; c2) BC_PLAT=android;; *) _hard "PDG_BC_PREIMAGE 必须是 b 或 c2(实得 [$BC_PRE])";; esac

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
BC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bc.XXXXXX")" || _hard "建不出本支临时目录"
R3_TMP="$BC_TMP"; E2E_TMP="$BC_TMP"          # 被抽取的函数按 $R3_TMP / $E2E_TMP 落临时物 —— 落在本支自己的目录
export E2E_TMP

# ── 复用: 只按唯一成对标记抽, 不 source 整支, 不复制函数正文 ──────────────────────
HOP2_SRC="$E2E_ROOT/tests/e2e-real-bridge-hop.sh"
PLAT_SRC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
R3_SRC="$E2E_ROOT/tests/e2e-real-retire-hop.sh"
# >>> PDG-EXTRACT-BEGIN bc_seed
# 引导的引导: 先把 ③ 的抽取器原文(r3_bootstrap)取出来, 之后一律用它与 ② 的抽取器按标记抽(判据同 ④ 的 r4_seed)。
bc_seed(){   # $1=名字 $2=来源 → 打印标记之间的原文; 标记不是唯一成对或之间为空 ⇒ 非 0
  local n="$1" src="$2" b e
  [[ -f "$src" ]] || { echo "引导: 找不到 $src" >&2; return 2; }
  [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] \
    || { echo "引导: $n 的标记不是唯一成对" >&2; return 1; }
  b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
  e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
  (( e - b >= 2 )) || { echo "引导: $n 的标记之间是空的" >&2; return 1; }
  sed -n "$((b+1)),$((e-1))p" "$src"
}
# <<< PDG-EXTRACT-END bc_seed
# >>> PDG-EXTRACT-BEGIN bc_lists
# 本支实际抽取的共享输入(新契约按这几张表逐字比对 3dcaee00 的同名块)。③ 的块里有本支不调用的函数(r3_modules、r3_precapture、
# r3_svc_verdict、r3_quiesce、r3_q_rec、r3_dns_adjust / instrument / phase): 随块抽进来, 但不得调用。
BC_PLAT_FNS=(_ev _evn SECT note sc_get sc_state nrun snap_state reset_units_strict reset_proof build_preimage
             wait_stable unit_identify _unit_wants_mainpid svc_stable_window svc_stable_assert mitm_listen_verdict
             _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after _j_interval)
BC_PLAT_DECLS=(E2E_OWNED_UNITS SVC_WATCH)
BC_HOP2_FNS=(bridge_svc_sample bridge_row_valid ios_slots)
BC_R3_BLOCKS=(r3_count r3_read r3_keep r3_precapture r3_invoke r3_arrival_verdict r3_svc_verdict r3_stable r3_dns r3_quiesce)
# <<< PDG-EXTRACT-END bc_lists
bc_seed r3_bootstrap "$R3_SRC" > "$BC_TMP/boot.sh" && bash -n "$BC_TMP/boot.sh" \
  || _hard "抽取器引导失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$BC_TMP/boot.sh"
r3_bootstrap "$HOP2_SRC" "$BC_TMP/extractor.sh" extract_marked_fns extract_marked_decls \
  || _hard "② 的抽取器没通过 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$BC_TMP/extractor.sh"
extract_marked_fns "$PLAT_SRC" "$BC_TMP/plat-fns.sh" "${BC_PLAT_FNS[@]}" || _hard "⑤ 函数抽取没通过 —— 还没碰任何服务"
extract_marked_decls "$PLAT_SRC" "$BC_TMP/plat-deps.sh" "${BC_PLAT_DECLS[@]}" || _hard "⑤ 依赖抽取没通过"
extract_marked_fns "$HOP2_SRC" "$BC_TMP/hop2-fns.sh" "${BC_HOP2_FNS[@]}" || _hard "② 函数抽取没通过"
r3_bootstrap "$R3_SRC" "$BC_TMP/r3fns.sh" "${BC_R3_BLOCKS[@]}" || _hard "③ 判据段抽取没通过 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$BC_TMP/plat-fns.sh"; source "$BC_TMP/plat-deps.sh"; source "$BC_TMP/hop2-fns.sh"; source "$BC_TMP/r3fns.sh"
JBOUND_TAG="pdg-e2e-jbound-bc"
J_ERR=""
E2E_NOTRUN=0; PREIMAGE_OK=1; BC_PRE_OK=0

# ── 本支自己的判据函数(新契约按标记抽出来用受控输入驱动) ─────────────────────────
# >>> PDG-EXTRACT-BEGIN bc_fs
# 文件查询只按 errno 区分: 存在 / 确认不存在(只有 ENOENT)/ 未取得(权限、I/O、结构错误等)。不解析本地化的 stat 错误文案。
# 悬空符号链接按"存在"(lstat 成功)。查询输出与进程退出码分别核: 进程非 0 时已打印的内容不采信。不扩成通用文件审计。
bc_fq(){   # $1=绝对路径 → 0 存在 / 3 确认不存在(ENOENT) / 2 未取得(原因在 BC_WHY)
  local out rc
  BC_WHY=""
  [[ "${1:-}" == /* ]] || { BC_WHY="文件查询: 没给绝对路径([${1:-}])"; return 2; }
  out="$(python3 - "$1" 2>/dev/null <<'PY'
import errno, os, sys
try:
    os.lstat(sys.argv[1])
except OSError as e:
    if e.errno == errno.ENOENT:
        print("ABSENT")
    else:
        print("ERRNO %d %s" % (e.errno, errno.errorcode.get(e.errno, "?")))
else:
    print("PRESENT")
PY
)"; rc=$?
  (( rc == 0 )) || { BC_WHY="文件查询 $1: 查询进程退出 $rc(已打印的 [${out:0:40}] 不采信)"; return 2; }
  case "$out" in
    PRESENT) return 0;;
    ABSENT) return 3;;
    "ERRNO "*) BC_WHY="文件查询 $1: lstat 失败 errno ${out#ERRNO }(不是 ENOENT ⇒ 未取得, 不当成不存在)"; return 2;;
    *) BC_WHY="文件查询 $1: 输出不认识([${out:0:40}])"; return 2;;
  esac
}
bc_unit_absent(){   # $1=unit $2=unit 文件路径 → 0 确认不存在(文件 ENOENT 且 LoadState=not-found) / 1 存在 / 2 未取得(BC_WHY)
  local r
  bc_fq "$2"; r=$?
  case "$r" in
    0) BC_WHY="$1 的 unit 文件 $2 在"; return 1;;
    3) ;;
    *) return 2;;
  esac
  r3_unit_q load "$1" || { BC_WHY="$1: unit 文件确认不在, 但 LoadState 没取得($R3_WHY)"; return 2; }
  [[ "$R3_VAL" == not-found ]] || { BC_WHY="$1: unit 文件不在, 但 LoadState=$R3_VAL(别处还有它)"; return 1; }
  BC_WHY="$1: unit 文件确认不在(ENOENT)且 LoadState=not-found"
}
bc_record_verdict(){   # $1=ios_slots 的输出 $2=记录路径 $3=期望 schema → 0 记录有效且自洽 / 1 记录在但不自洽 / 2 未取得 / 3 确认没有记录
                       # NOMETA 不直接当"没有记录": 记录路径经 bc_fq 确认 ENOENT 才算; 查询失败、记录在却 NOMETA 都算未取得
  local rep="$1" w rec fil st detail sch="" n=0 nbad=0 r why="" seen=" "
  BC_WHY=""
  while IFS=$'\t' read -r w rec _; do                   # 先整份扫失败行: 失败之前已打印的正常内容不采信
    case "$w" in IMPORTFAIL|LOADFAIL|RUNFAIL) BC_WHY="记录读取失败: $w(${rec:-无说明})"; return 2;; esac
  done <<<"$rep"
  while IFS=$'\t' read -r w rec fil st detail; do
    [[ -n "$w" ]] || continue
    case "$w" in
      NOMETA)
        bc_fq "$2"; r=$?
        case "$r" in
          3) BC_WHY="没有 iOS 记录($2 确认不存在)"; return 3;;
          0) BC_WHY="ios_slots 报 NOMETA, 但 $2 在 —— 读取口径对不上, 未取得"; return 2;;
          *) BC_WHY="ios_slots 报 NOMETA, 记录路径查询未取得: $BC_WHY"; return 2;;
        esac;;
      schema) sch="$rec"; continue;;
      current|previous)
        [[ "$seen" != *" $w "* ]] || { BC_WHY="槽位 $w 重复出现"; return 2; }
        seen="$seen$w ";;
      *) BC_WHY="ios_slots 输出有不认识的行([${w:0:30}])"; return 2;;
    esac
    n=$((n+1))
    if [[ "$rec" == 无记录 ]]; then
      [[ "$fil" == 文件不在 && "$st" == missing ]] || { nbad=$((nbad+1)); why="$why $w 无记录却 $fil / $st;"; }
    else
      [[ "$fil" == 文件在 && "$st" == healthy ]] || { nbad=$((nbad+1)); why="$why $w 有记录却 $fil / $st($detail);"; }
    fi
  done <<<"$rep"
  (( n == 2 )) || { BC_WHY="槽位行数 $n(应为 2: current + previous)"; return 2; }
  [[ "$sch" == "$3" ]] || { BC_WHY="schema 读到 [$sch], 应为 [$3]"; return 1; }
  (( nbad == 0 )) || { BC_WHY="槽位不自洽:$why"; return 1; }
  BC_WHY="schema $sch; current / previous 两个槽位按记录自洽(有效性走产品入口 artifact_health)"
}
bc_hij_entries(){   # → 0 取得(R3_VAL=接管表条目数; 文件确认不存在 = 0 条) / 2 未取得
  local raw r l n=0
  R3_VAL=""
  bc_fq "$HIJ"; r=$?
  case "$r" in 3) R3_VAL=0; return 0;; 0) ;; *) R3_WHY="接管表: $BC_WHY"; return 2;; esac
  raw="$(cat -- "$HIJ" 2>/dev/null)" || { R3_WHY="接管表 $HIJ 读不了"; return 2; }
  while IFS= read -r l; do
    l="${l#"${l%%[![:space:]]*}"}"
    [[ -z "$l" || "$l" == \#* ]] || n=$((n+1))
  done <<<"$raw"
  R3_VAL="$n"
}
# <<< PDG-EXTRACT-END bc_fs
# >>> PDG-EXTRACT-BEGIN bc_wrap
# 计数与包装: 计数文件复用 ③ r3_count 原文(这里只把 R3_COUNT 局部换成各自的文件); 包装器(timeout)返回码、timeout 自己的发信号记录、
# 产品原始退出码(内层单独写出)分开取、分开说(读取复用 ③ r3_prod_rc / r3_timeout_sig 原文)。
bc_count_init(){ local R3_COUNT="$1"; r3_count_init; }
bc_count_bump(){ local R3_COUNT="$1"; r3_count_bump; }
bc_count_read(){ local R3_COUNT="$1"; r3_count_read; }
bc_counts_say(){   # → "第二跳 n 次; 第三跳 n 次; 旧版 CLI n 次"(读不出的写明)
  local lbl f out=""
  for lbl in 第二跳 第三跳 旧版CLI; do
    case "$lbl" in 第二跳) f="${BC_CNT_HOP2:-}";; 第三跳) f="${BC_CNT_HOP3:-}";; *) f="${BC_CNT_OLD:-}";; esac
    if [[ -n "$f" ]] && bc_count_read "$f"; then out="$out $lbl $R3_VAL 次;"; else out="$out $lbl 读不出(${R3_WHY:-计数没建});"; fi
  done
  printf '%s' "${out# }"
}
bc_run(){   # $1=计数文件 $2=日志 $3=产品退出码文件 $4=timeout 的 stderr $5=上限秒 $6..=命令 → 0 已调用(BC_WRAP_RC) / 2 留档或计数不可用, 没有调用
  local cnt="$1" log="$2" rcf="$3" toe="$4" lim="$5"
  shift 5
  BC_WRAP_RC=""
  { : > "$log" && : > "$rcf" && : > "$toe"; } 2>/dev/null || { R3_WHY="留档准备不了($log / $rcf / $toe)"; return 2; }
  bc_count_bump "$cnt" || return 2
  BC_WRAP_RC=0
  # shellcheck disable=SC2016  # 单引号是有意的: $1.. 由内层 bash 展开
  timeout --verbose "$lim" bash -c 'l="$1"; r="$2"; shift 2; "$@" </dev/null >"$l" 2>&1; printf "%s\n" "$?" >"$r"' bcwrap "$log" "$rcf" "$@" 2>"$toe" || BC_WRAP_RC=$?
  return 0
}
bc_rc_settle(){   # $1=标签 $2=产品退出码文件 $3=timeout 的 stderr → 0 包装器 0、无发信号记录、产品原始退出码 0 / 1 失败 / 2 未取得(BC_WHY)
  local R3_RCFILE="$2" R3_TOERR="$3" r sig="" st=0
  BC_PROD_RC=""
  [[ "${BC_WRAP_RC:-}" =~ ^[0-9]+$ ]] || { BC_WHY="$1: 包装器(timeout)返回码未取得"; return 2; }
  r3_timeout_sig; r=$?
  case "$r" in
    0) sig="$R3_VAL"; st=1;;
    1) ;;
    *) BC_WHY="$1: $R3_WHY"; return 2;;
  esac
  r3_prod_rc; r=$?
  case "$r" in
    0) BC_PROD_RC="$R3_VAL"; (( BC_PROD_RC == 0 )) || st=1;;
    3) [[ -n "$sig" ]] || { BC_WHY="$1: 产品原始退出码未取得($R3_WHY); 包装器(timeout)返回码 $BC_WRAP_RC 不冒充"; return 2; };;
    *) BC_WHY="$1: $R3_WHY"; return 2;;
  esac
  (( BC_WRAP_RC == 0 )) || st=1
  BC_WHY="$1: 包装器(timeout)返回码 $BC_WRAP_RC; timeout 发信号记录 ${sig:-无}; 产品原始退出码 ${BC_PROD_RC:-未取得(被超时终止)}"
  return "$st"
}
bc_keep_ev(){   # $1=源 $2=证据文件名 → 复制进证据目录并收紧权限; 失败只具名提示(不改判据)
  { cp -- "$1" "$EVID/$2" && chmod 600 "$EVID/$2"; } 2>/dev/null || note "证据复制失败: $1 → $2"
}
# <<< PDG-EXTRACT-END bc_wrap
# >>> PDG-EXTRACT-BEGIN bc_fp
# 指纹集合: 按"集合名|路径"登记 r3_keepfp 原文的结果(sha256 mode uid:gid); 比对时读失败不当成原样。
bc_fp_take(){   # $1=集合名 $2..=文件 → 0 全部取得 / 1 有没取得(R3_WHY)
  local set="$1" f
  shift
  for f in "$@"; do
    r3_keepfp "$f" || { R3_WHY="$set 指纹没取得: $f(${R3_WHY})"; return 1; }
    BC_FP["$set|$f"]="$R3_VAL"
  done
}
bc_fp_same(){   # $1=集合名 $2=文件 → 0 与登记相同 / 1 被改或不在了 / 2 观测无效或没有登记(BC_WHY)
  local r want="${BC_FP["$1|$2"]:-}"
  [[ -n "$want" ]] || { BC_WHY="$2 没有 $1 指纹登记"; return 2; }
  r3_keepfp "$2"; r=$?
  case "$r" in
    0) [[ "$R3_VAL" == "$want" ]] && { BC_WHY="$2 与 $1 相同(内容 / mode / uid:gid)"; return 0; }
       BC_WHY="$2 被改(登记 [${want:0:16}… ${want#* }] 现在 [${R3_VAL:0:16}… ${R3_VAL#* }])"; return 1;;
    3) BC_WHY="$2 不在了"; return 1;;
    *) BC_WHY="$2 观测无效: $R3_WHY"; return 2;;
  esac
}
bc_fp_line(){   # $1=文件 → 打印"路径<TAB>指纹 / ABSENT / 未取得: 原因"(只作留档)
  local r
  bc_fq "$1"; r=$?
  case "$r" in
    3) printf '%s\tABSENT\n' "$1";;
    0) if r3_keepfp "$1"; then printf '%s\t%s\n' "$1" "$R3_VAL"; else printf '%s\t未取得: %s\n' "$1" "$R3_WHY"; fi;;
    *) printf '%s\t未取得: %s\n' "$1" "$BC_WHY";;
  esac
}
bc_listen_is(){   # $1=标签 $2=端口 $3=期望条数 → 0 相等 / 1 不等 / 2 观测无效(已打印)
  if ! r3_listen_count "$2"; then bad "$1: $2 监听观测无效: $R3_WHY"; return 2; fi
  [[ "$R3_VAL" == "$3" ]] && { ok "$1: $2 监听 $R3_VAL 条"; return 0; }
  bad "$1: $2 监听 $R3_VAL 条(应为 $3)"; return 1
}
bc_absent_say(){   # $1=标签 $2..=应当确认不存在的路径 → 0 全部确认不存在 / 1 有存在或未取得(逐项已打印)
  local lbl="$1" f r st=0
  shift
  for f in "$@"; do
    bc_fq "$f"; r=$?
    case "$r" in
      3) ok "$lbl: $f 确认不存在(ENOENT)";;
      0) bad "$lbl: $f 在"; st=1;;
      *) bad "$lbl: $f 未取得: $BC_WHY —— 不当成不存在"; st=1;;
    esac
  done
  return "$st"
}
bc_grep_say(){   # $1=标签 $2=期望 有|无 $3=说明 $4..=grep 参数 → 0 符合 / 1 不符或观测无效(已打印)
  local lbl="$1" want="$2" what="$3" r
  shift 3
  r3_grepq "$@"; r=$?
  case "$r:$want" in
    0:有|1:无) ok "$lbl: $what";;
    0:无) bad "$lbl: 不该有却有 —— $what"; return 1;;
    1:有) bad "$lbl: 该有却没有 —— $what"; return 1;;
    *) bad "$lbl: 观测无效($R3_WHY) —— $what 未取得"; return 1;;
  esac
}
bc_platform_is(){   # $1=标签 $2=期望平台 → 0 / 1(已打印)
  local p
  if ! p="$(cat -- "$R3_ETC/platform" 2>/dev/null)"; then bad "$1: 平台标记读不了 —— 未取得"; return 1; fi
  [[ "$p" == "$2" ]] && { ok "$1: 平台标记 = $2"; return 0; }
  bad "$1: 平台标记 [$p], 应为 $2"; return 1
}
bc_hij_none(){   # $1=标签 → 0 接管表无条目(文件确认不存在也算) / 1(已打印)
  if ! bc_hij_entries; then bad "$1: 接管表条目未取得: $R3_WHY"; return 1; fi
  [[ "$R3_VAL" == 0 ]] && { ok "$1: 接管表无条目"; return 0; }
  bad "$1: 接管表有 $R3_VAL 条"; return 1
}
# <<< PDG-EXTRACT-END bc_fp
# >>> PDG-EXTRACT-BEGIN bc_build
# 前像构造。首次启动: 每个 unit 先建 journal 界桩、再 `systemctl enable --now`、原始退出码逐个留; 随后逐个核 active /
# NRestarts=0 / 不是 failed / 界桩后恰 1 次 Started。任何一步不成立 ⇒ 前像不成立并停止: 不 reset-failed、不重试、不改限额。
bc_unit_fresh(){   # $1=标签 $2=unit $3=首次启动前的界桩 → 0 成立 / 1 不成立或未取得(已打印)
  local lbl="$1" u="$2" n
  r3_q_prop ActiveState "$u" || { bad "$lbl: $u 观测无效: $R3_WHY"; return 1; }
  [[ "$R3_VAL" == active ]] || { bad "$lbl: $u ActiveState=$R3_VAL(要 active)"; return 1; }
  r3_unit_q active "$u" || { bad "$lbl: $u is-active 观测无效: $R3_WHY"; return 1; }
  [[ "$R3_VAL" == active ]] || { bad "$lbl: $u is-active=$R3_VAL"; return 1; }
  r3_q_prop NRestarts "$u" || { bad "$lbl: $u 观测无效: $R3_WHY"; return 1; }
  [[ "$R3_VAL" == 0 ]] || { bad "$lbl: $u NRestarts=$R3_VAL(要 0)"; return 1; }
  if ! n="$(_j_starts_after "$u" "$3")" || [[ ! "$n" =~ ^[0-9]+$ ]]; then
    bad "$lbl: $u 界桩后的启动事件查不清($(_j_why))"; return 1
  fi
  [[ "$n" == 1 ]] || { bad "$lbl: $u 界桩后 Started $n 次(要恰 1 次)"; return 1; }
  ok "$lbl: $u active、NRestarts=0、界桩后恰 1 次 Started(口径只计 Started 事件)"
}
bc_firststart(){   # $1=标签 $2..=unit → 0 每个 unit 首次 enable --now 退出 0 且随后核验成立 / 1 不成立或未取得(不重试)
  local lbl="$1" u rc cur
  local -A cur_of=()
  shift
  systemctl daemon-reload > /dev/null 2>&1; rc=$?
  _evn "02-$BC_PRE-firststart.txt" "systemctl daemon-reload: 原始退出码 $rc"
  (( rc == 0 )) || { bad "$lbl: daemon-reload 退出 $rc —— 前像不成立, 停止"; return 1; }
  for u in "$@"; do
    if ! cur="$(_j_mark "firststart-$u")" || [[ -z "$cur" ]]; then
      bad "$lbl: $u 首次启动前的 journal 界桩没建成($(_j_why)) —— 首次启动结论无从谈起, 停止"; return 1
    fi
    cur_of[$u]="$cur"
    systemctl enable --now "$u" > /dev/null 2>&1; rc=$?
    _evn "02-$BC_PRE-firststart.txt" "systemctl enable --now $u: 原始退出码 $rc"
    (( rc == 0 )) || { bad "$lbl: systemctl enable --now $u 退出 $rc —— 前像不成立, 停止(不 reset-failed、不重试)"; return 1; }
  done
  for u in "$@"; do bc_unit_fresh "$lbl" "$u" "${cur_of[$u]}" || return 1; done
  ok "$lbl: $# 个 unit 首次启动的原始退出码都是 0, 随后逐个核验成立"
}
bc_old_cli(){   # $1=标签 $2=留档名前缀 $3..=子命令 → 0 已调用且产品原始退出码 0 / 1 不成立或未取得(已打印); 日志在 BC_OLD_LOG
  local lbl="$1" pfx="$2" r
  shift 2
  BC_OLD_LOG="$BC_TMP/$pfx.log"
  if ! bc_run "$BC_CNT_OLD" "$BC_OLD_LOG" "$BC_TMP/$pfx.rc" "$BC_TMP/$pfx.timeout-stderr" "$BC_OLD_TIMEOUT" \
         env -u PDG_UPDATE_SVCSTATE -u PDG_TAG_BOOTSTRAPPED -u PDG_PLATFORM bash "$R3_CLI" "$@"; then
    bad "$lbl: 调用前停止($R3_WHY) —— 没有调用"; return 1
  fi
  bc_keep_ev "$BC_OLD_LOG" "$pfx.log"; bc_keep_ev "$BC_TMP/$pfx.rc" "$pfx.rc"; bc_keep_ev "$BC_TMP/$pfx.timeout-stderr" "$pfx.timeout-stderr"
  bc_rc_settle "$lbl" "$BC_TMP/$pfx.rc" "$BC_TMP/$pfx.timeout-stderr"; r=$?
  case "$r" in
    0) ok "$BC_WHY";;
    1) bad "$BC_WHY —— 前像不成立"; return 1;;
    *) bad "$BC_WHY —— 未取得, 前像不成立"; return 1;;
  esac
}
bc_snap_new(){   # $1=标签 $2=调用前快照清单 $3=是否要求含 snap.tar.gz 与 svcstate.tsv(1/0) → 0 恰新增 1 个 / 1 不成立或未取得
  local nw
  r3_lsdir "$SNAPROOT" || { bad "$1: 调用后快照清单没取得($R3_WHY)"; return 1; }
  r3_snapdiff "$2" "$R3_VAL" || { bad "$1: 快照差集观测无效($R3_WHY)"; return 1; }
  nw="$R3_VAL"
  [[ -n "$nw" && "$nw" != *$'\n'* ]] || { bad "$1: 新快照不是恰 1 个(新增: [${nw//$'\n'/ }])"; return 1; }
  if [[ "$3" == 1 ]] && ! [[ -s "$SNAPROOT/$nw/snap.tar.gz" && -s "$SNAPROOT/$nw/svcstate.tsv" ]]; then
    bad "$1: 新快照 $nw 缺 snap.tar.gz 或 svcstate.tsv"; return 1
  fi
  ok "$1: 产品新建了恰 1 个快照($nw)"
}
bc_old_migrate(){   # B 构造第 4 步: v1.11.15 自己的公开入口 `pdg migrate` 恰一次 → 0 成立 / 1 不成立或未取得(构造停止)
  local s0
  r3_lsdir "$SNAPROOT" || { bad "B 构造: 迁移前快照清单没取得($R3_WHY)"; return 1; }
  s0="$R3_VAL"
  bc_old_cli "B 构造: 旧版 pdg migrate" 02-b-old-migrate migrate || return 1
  bc_grep_say "B 构造: 旧版 pdg migrate" 有 "输出有「✅ 迁移完成」" -F '✅ 迁移完成' "$BC_OLD_LOG" || return 1
  bc_grep_say "B 构造: 旧版 pdg migrate" 无 "输出没有「❌ 迁移失败」" -F '❌ 迁移失败' "$BC_OLD_LOG" || return 1
  bc_snap_new "B 构造: 旧版 pdg migrate 的快照" "$s0" 0 || return 1
}
bc_c2_switch(){   # C2 构造动作: v1.11.15 自己的 `pdg platform android` 恰一次 → 0 成立 / 1 不成立或未取得(构造停止)
  local s0
  r3_lsdir "$SNAPROOT" || { bad "C2 构造: 切换前快照清单没取得($R3_WHY)"; return 1; }
  s0="$R3_VAL"
  bc_old_cli "C2 构造: 旧版 pdg platform android" 02-c2-platform-android platform android || return 1
  bc_grep_say "C2 构造: 旧版 pdg platform android" 有 "输出有「平台已确认: ios → android」" -F '平台已确认: ios → android' "$BC_OLD_LOG" || return 1
  bc_grep_say "C2 构造: 旧版 pdg platform android" 有 "输出有「Android: 已清理 iOS 专属残留」" -F 'Android: 已清理 iOS 专属残留' "$BC_OLD_LOG" || return 1
  bc_grep_say "C2 构造: 旧版 pdg platform android" 无 "输出没有任何「❌」行" -F '❌' "$BC_OLD_LOG" || return 1
  bc_snap_new "C2 构造: 旧版 pdg platform android 的快照" "$s0" 0 || return 1
  bc_platform_is "C2 构造: 切换后平台文件" android || return 1
  bc_absent_say "C2 构造: 切换后" "$R3_ETC/platform.guessed" || return 1
}
bc_b_assemble(){   # B 夹具组装(调用方已把 E2E_ROOT 指到 v1.11.15 源码树)→ 0 / 1(已打印)
  e2e_seed_install > /dev/null 2>&1 || { bad "B 构造: e2e_seed_install 失败"; return 1; }
  e2e_seed_mosdns all > /dev/null 2>&1 || { bad "B 构造: e2e_seed_mosdns 失败"; return 1; }
  e2e_seed_singbox_model || { bad "B 构造: e2e_seed_singbox_model 失败"; return 1; }
  e2e_seed_nft mihomo > /dev/null 2>&1 || { bad "B 构造: e2e_seed_nft 失败"; return 1; }
  e2e_seed_cert > /dev/null 2>&1 || { bad "B 构造: e2e_seed_cert 失败"; return 1; }
  if ! { printf 'ios\n' > "$R3_ETC/platform" && printf 'mihomo\n' > "$R3_ETC/backend" \
         && printf 'PDG_BOT_TOKEN=\nPDG_BOT_ALLOWED=\n' > "$R3_ETC/bot.env" && chmod 600 "$R3_ETC/bot.env" \
         && mkdir -p /var/lib/privdns-gateway; } 2>/dev/null; then
    bad "B 构造: 平台 / 后端 / bot.env 写不进"; return 1
  fi
  rm -rf /opt/privdns-gateway                # e2e_seed_install 刚把源码树拷成了这个目录; 换成指向自有裸库的真 clone(同 build_preimage)
  git clone -q "$ORIGIN" "$R3_REPO" || { bad "B 构造: clone 裸库到 $R3_REPO 失败"; return 1; }
  e2e_guard_repo "$R3_REPO" || { bad "B 构造: $R3_REPO 没通过 ref 库守卫"; return 1; }
  e2e_git "$R3_REPO" checkout -q "$OLD_SHA" || { bad "B 构造: $R3_REPO 切不到 v1.11.15"; return 1; }
  e2e_git "$R3_REPO" tag -d "$TEST_TAG" > /dev/null 2>&1      # 新 tag 只留在 origin 上, 逼更新真的去 fetch(下一行核结果)
  r3_tagsha "$R3_REPO" "$TEST_TAG"; [[ $? == 1 ]] || { bad "B 构造: 现役仓库里仍有(或查不清)$TEST_TAG"; return 1; }
  install -m755 "$R3_REPO/deploy/bot/pdg.sh" "$R3_CLI" || { bad "B 构造: 旧版 CLI 装不上"; return 1; }
  e2e_reset_botdir > /dev/null 2>&1 || { bad "B 构造: e2e_reset_botdir 失败"; return 1; }
  # shellcheck source=/dev/null
  ( source "$R3_REPO/lib/modules.sh" && pdg_install_runtime_modules "$R3_REPO" "$R3_MODDIR" ios ) \
    || { bad "B 构造: 按旧版清单装 ios 运行模块失败"; return 1; }
  printf 'dot.e2e.test\n' > "$R3_MODDIR/dot-domain" || { bad "B 构造: dot-domain 写不进"; return 1; }
  if ! cat > /etc/systemd/system/mosdns.service <<'EOF'
[Unit]
Description=mosdns
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/mosdns start -d /etc/mosdns
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  then bad "B 构造: mosdns unit 写不进"; return 1; fi
  # shellcheck source=/dev/null
  ( source "$OLDSRC/lib/units.sh" && pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service \
      && pdg_write_unit pdg_unit_pdg_mitm /etc/systemd/system/pdg-mitm.service ) \
    || { bad "B 构造: 旧版 mihomo / pdg-mitm unit 写不进"; return 1; }
  install -m644 "$OLDSRC/deploy/bot/pdg-probe81.service" "$OLDSRC/deploy/bot/pdg-health.service" \
                "$OLDSRC/deploy/bot/pdg-health.timer" /etc/systemd/system/ || { bad "B 构造: probe81 / health unit 装不上"; return 1; }
  if ! { sed -e 's|__DOT_DOMAIN__|dot.e2e.test|g' -e "s|__SERVER_IP__|203.0.113.1|g" \
             -e 's|__INTERNAL_CIDR__|127.0.0.0/8|g' -e 's|__CERT_DIR__|/etc/mosdns/certs|g' \
             "$OLDSRC/deploy/bot/pdg-bot.service" > /etc/systemd/system/pdg-bot.service \
         && chmod 644 /etc/systemd/system/pdg-bot.service; } 2>/dev/null; then
    bad "B 构造: pdg-bot unit 写不进"; return 1
  fi
  bc_hij_none "B 构造: 渲染 mihomo 之前" || return 1
  # mihomo 配置: 照 v1.11.15 install.sh 的做法用旧版 sb2mihomo 从数据模型渲染, 接管域名取自(空的)接管表
  if ! ( cd "$R3_MODDIR" && python3 - "$R3_MODDIR" "$HIJ" "$MC" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import sb2mihomo
model = json.load(open("/etc/sing-box/config.json"))
mitm = []
try:
    with open(sys.argv[2], encoding="utf-8") as fh:
        for l in fh:
            l = l.strip()
            if l and not l.startswith("#"):
                mitm.append(l.split(":", 1)[1] if l.startswith("domain:") else l)
except OSError:
    pass
cfg, _ = sb2mihomo.singbox_to_mihomo(model, redir_port=7893, mitm_domains=mitm or None)
with open(sys.argv[3], "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
os.chmod(sys.argv[3], 0o600)
PY
     ) > "$BC_TMP/b-mihomo.log" 2>&1; then
    bad "B 构造: 旧版 sb2mihomo 渲染 mihomo 配置失败: $(tail -2 "$BC_TMP/b-mihomo.log" | tr '\n' ' ')"; return 1
  fi
  bc_grep_say "B 构造: mihomo 配置" 无 "没有 MITM-OUT" 'MITM-OUT' "$MC" || return 1
  # 描述文件: 旧版自己的 iosstate.generate(wloc_enabled=False), 随后逐项自证
  if ! ( cd "$R3_MODDIR" && python3 - "$R3_MODDIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import iosstate
assert iosstate.SCHEMA == 1, "加载的不是旧版 iosstate(SCHEMA=%r)" % iosstate.SCHEMA
iosstate.generate("dot.e2e.test", ["203.0.113.1"], ssids=["HomeWiFi"], ca_der=b"", wloc_enabled=False)
PY
     ) > "$BC_TMP/b-gen.log" 2>&1; then
    bad "B 构造: 旧版 iosstate.generate 失败: $(tail -2 "$BC_TMP/b-gen.log" | tr '\n' ' ')"; return 1
  fi
  if ! python3 - "$IOS_META" "$IOS_ART/current.mobileconfig" > "$BC_TMP/b-gencheck.log" 2>&1 <<'PY'
import hashlib, json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
cur = m.get("current") or {}
inp = cur.get("inputs") or {}
data = open(sys.argv[2], "rb").read()
fail = []
if m.get("schema") != 1: fail.append("schema=%r(应为 1)" % m.get("schema"))
if not m.get("instance_id"): fail.append("instance_id 为空")
if not cur.get("revision"): fail.append("revision 为空")
if cur.get("sha256") != hashlib.sha256(data).hexdigest(): fail.append("记录里的 sha256 与盘上产物对不上")
if inp.get("wloc_enabled") is not False: fail.append("inputs.wloc_enabled=%r(应为 False)" % inp.get("wloc_enabled"))
if inp.get("ssids") != ["HomeWiFi"]: fail.append("ssids=%r" % (inp.get("ssids"),))
if b"HomeWiFi" not in data: fail.append("产物里没有预置的 SSID")
if b"com.apple.security.root" in data: fail.append("未启用 WLOC 却嵌了根证书 payload")
if m.get("previous") is not None: fail.append("previous 不是 null")
if fail:
    sys.stderr.write("; ".join(fail) + "\n"); sys.exit(1)
print("schema=1 revision=%s wloc_enabled=False 无根证书 payload" % cur.get("revision"))
PY
  then bad "B 构造: 描述文件自证不通过: $(tail -2 "$BC_TMP/b-gencheck.log" | tr '\n' ' ')"; return 1; fi
  ok "B 构造: 旧版 iosstate.generate 生成的描述文件自证通过($(tail -1 "$BC_TMP/b-gencheck.log"))"
}
bc_b_identity_old(){   # B 构造: 现役仍是 v1.11.15(HEAD、CLI 逐字节、按旧版 ios 清单的模块)→ 0 / 1(已打印)
  local st=0 r
  if r3_head "$R3_REPO"; then
    [[ "$R3_VAL" == "$OLD_SHA" ]] && ok "B 构造: 现役 HEAD = v1.11.15" || { bad "B 构造: 现役 HEAD=$R3_VAL"; st=1; }
  else bad "B 构造: HEAD 观测无效: $R3_WHY"; st=1; fi
  if cmp -s -- "$R3_CLI" "$OLDSRC/deploy/bot/pdg.sh"; then ok "B 构造: 现役 CLI 逐字节 = v1.11.15 pdg.sh"
  else bad "B 构造: 现役 CLI 不是 v1.11.15 的那一份"; st=1; fi
  bc_modules "$OLDSRC" "$R3_MODDIR" ios; r=$?
  if (( r != 0 )); then bad "B 构造: 模块观测无效: $R3_WHY"; st=1
  elif [[ "${R3_VAL#* }" == 0 ]]; then ok "B 构造: 按旧版 ios 清单 ${R3_VAL% *} 项逐字节 = v1.11.15"
  else bad "B 构造: 有 ${R3_VAL#* } 项模块与 v1.11.15 不同:$BC_MOD_BAD"; st=1; fi
  return "$st"
}
bc_build_b(){   # B 前像构造 → BC_PRE_OK=1 成立; 任一步不成立 ⇒ BC_PRE_OK=0 并停止(不换路线补)
  local save f
  BC_PRE_OK=0
  echo "── B 构造: 夹具组装 + v1.11.15 自己的 pdg migrate 一次(不是完整旧安装器装出的现场) ──"
  reset_units_strict || { bad "B 构造: 逐项复位有动作未达预期 —— 停止构造"; return 1; }
  e2e_reset_box
  reset_proof "进入 B 之前"
  save="$E2E_ROOT"; E2E_ROOT="$OLDSRC"
  if ! bc_b_assemble; then E2E_ROOT="$save"; return 1; fi
  E2E_ROOT="$save"
  bc_b_identity_old || return 1
  bc_firststart "B 构造: 首次启动" mosdns mihomo pdg-probe81 pdg-mitm || return 1
  bc_fp_take b0 "$IOS_META" "$IOS_ART/current.mobileconfig" || { bad "B 构造: 迁移前记录指纹: $R3_WHY"; return 1; }
  for f in "${BC_B_MIGFILES[@]}"; do bc_fp_line "$f"; done > "$EVID/02-b-migrate-files.before.tsv" 2>/dev/null
  bc_old_migrate || return 1
  for f in "${BC_B_MIGFILES[@]}"; do bc_fp_line "$f"; done > "$EVID/02-b-migrate-files.after.tsv" 2>/dev/null
  nft -f /etc/nftables.conf > "$BC_TMP/b-nft-load.log" 2>&1 \
    || { bad "B 构造: nft -f /etc/nftables.conf 失败: $(head -3 "$BC_TMP/b-nft-load.log" | tr '\n' ' ')"; return 1; }
  ok "B 构造: 防火墙已按磁盘加载(安装器最后一步的同义)"
  BC_PRE_OK=1
}
bc_c2_base_valid(){   # $1=构造起界桩 → 0 A 型底座在构造结束时现场有效 / 1(已打印); 只核终态, 不倒推首次启动命令的退出码
  local u r st=0
  for u in mosdns mihomo pdg-probe81 pdg-mitm; do
    bc_unit_fresh "C2 构造结束时" "$u" "$1" || st=1
    if r3_unit_q enabled "$u"; then
      [[ "$R3_VAL" == enabled ]] && ok "C2 构造结束时: $u enabled" || { bad "C2 构造结束时: $u 自启是 $R3_VAL"; st=1; }
    else bad "C2 构造结束时: $u 自启观测无效: $R3_WHY"; st=1; fi
  done
  return "$st"
}
bc_a_base_gate(){   # C2 的 A 型底座(切 Android 之前): WLOC 开着的完整现场 → 0 / 1(已打印)
  local st=0 u w l n_ent=0 n_other=0
  for u in mosdns mihomo pdg-probe81 pdg-mitm; do r3_stable_assert "$u" running "C2 底座: $u 持续运行" 5 || st=1; done
  if r3_listen_count 7894; then
    (( R3_VAL > 0 )) && ok "C2 底座: 7894 有监听($R3_VAL)" || { bad "C2 底座: 7894 无监听"; st=1; }
  else bad "C2 底座: 7894 观测无效: $R3_WHY"; st=1; fi
  if python3 - "$IOS_META" "$IOS_ART/current.mobileconfig" "$MJ" <<'PY'
import json, os, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
cur = m.get("current") or {}
data = open(sys.argv[2], "rb").read()
ok = (m.get("schema") == 1 and cur.get("inputs", {}).get("wloc_enabled") is True and b"com.apple.security.root" in data
      and json.load(open(sys.argv[3], encoding="utf-8")).get("wloc", {}).get("enabled") is True)
sys.exit(0 if ok else 1)
PY
  then ok "C2 底座: 记录 schema 1、当前版 wloc_enabled=true 且产物嵌根证书; mitm.json wloc.enabled=true"
  else bad "C2 底座: 记录 / mitm.json 不是'WLOC 开着的 schema 1'形态(或读不了)"; st=1; fi
  if w="$(cat -- "$HIJ" 2>/dev/null)"; then
    while IFS= read -r l; do
      l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
      [[ -z "$l" || "$l" == \#* ]] && continue
      n_ent=$((n_ent+1))
      [[ "$l" =~ ^(domain:|full:)?gs-loc(-cn)?\.apple\.com$ ]] || n_other=$((n_other+1))
    done <<<"$w"
    (( n_ent > 0 && n_other == 0 )) && ok "C2 底座: 接管表只有 gs-loc 条目($n_ent 条)" || { bad "C2 底座: 接管表 $n_ent 条, gs-loc 以外 $n_other 条"; st=1; }
  else bad "C2 底座: 接管表读不了"; st=1; fi
  bc_grep_say "C2 底座" 有 "内核配置含 MITM-OUT" 'MITM-OUT' "$MC" || st=1
  return "$st"
}
bc_build_c2(){   # C2 前像构造 → BC_PRE_OK=1 成立; 任一步不成立 ⇒ BC_PRE_OK=0 并停止
  local cur0
  BC_PRE_OK=0
  echo "── C2 构造: 共享 build_preimage ios on(原样调用) → 防火墙加载 → v1.11.15 自己的 pdg platform android 一次 ──"
  if ! cur0="$(_j_mark c2-build-start)" || [[ -z "$cur0" ]]; then
    bad "C2 构造: 起界桩没建成($(_j_why)) —— 构造结束时的单次启动核不了, 不开始构造"; return 1
  fi
  build_preimage ios on
  note "C2 构造: build_preimage 内部首次启动命令(enable --now)的退出码 = 未取得(共享函数内部吞掉且恒 return 0); 函数返回值不作有效依据"
  _evn 02-c2-firststart.txt "build_preimage 内部首次启动命令的退出码: 未取得; 本支只核构造结束时现场有效(见运行输出)"
  [[ "${PREIMAGE_OK:-0}" == 1 ]] || { bad "C2 构造: build_preimage 置 PREIMAGE_OK=${PREIMAGE_OK:-?} —— 停止"; return 1; }
  bc_c2_base_valid "$cur0" || return 1
  nft -f /etc/nftables.conf > "$BC_TMP/c2-nft-load.log" 2>&1 \
    || { bad "C2 构造: nft -f /etc/nftables.conf 失败: $(head -3 "$BC_TMP/c2-nft-load.log" | tr '\n' ' ')"; return 1; }
  ok "C2 构造: A 型底座的防火墙已按磁盘加载"
  bc_a_base_gate || return 1
  if cmp -s -- "$R3_CLI" "$OLDSRC/deploy/bot/pdg.sh"; then ok "C2 构造: 切换前现役 CLI 逐字节 = v1.11.15 pdg.sh"
  else bad "C2 构造: 切换前现役 CLI 不是 v1.11.15 的那一份"; return 1; fi
  bc_platform_is "C2 构造: 切换前" ios || return 1
  bc_absent_say "C2 构造: 切换前" "$R3_ETC/platform.guessed" || return 1
  bc_fp_take a "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$IOS_META" "$IOS_ART/current.mobileconfig" \
    || { bad "C2 构造: 底座指纹: $R3_WHY"; return 1; }
  r3_copy_record "$MJ" "$BC_TMP/c2-a-mitm.json" || { bad "C2 构造: 底座 mitm.json 原文没取得($R3_WHY)"; return 1; }
  bc_c2_switch || return 1
  BC_PRE_OK=1
}
# <<< PDG-EXTRACT-END bc_build
# >>> PDG-EXTRACT-BEGIN bc_gate
# 前像门: 构造完成后、第二跳前的现场逐项现查; 任一不成立或未取得 ⇒ 两跳都不调用。
bc_svc_no_failed(){   # $1=阶段 → 0 本次新采样集合完整有效且没有 failed / 1(已打印)
  local u act bad_list=""
  bc_svc_phase "$1" || { bad "$1: 服务采样未取得: $R3_WHY"; return 1; }
  for u in "${SVC_WATCH[@]}"; do
    if ! bc_row_fields "${BC_SVC_ROWS[$u]:-}" || [[ "${BC_F[0]}" != "$u" ]]; then bad "$1: $u 的采样行拆不出 13 列 —— 观测无效"; return 1; fi
    act="${BC_F[5]}"
    case "$act" in
      failed) bad_list="$bad_list $u";;
      active|inactive|activating|deactivating|reloading|'<空>') ;;
      *) bad "$1: $u 的 ActiveState 不认识([$act])—— 观测无效"; return 1;;
    esac
  done
  [[ -z "$bad_list" ]] && { ok "$1: 受监视的 ${#SVC_WATCH[@]} 个 unit 采样齐全有效, 没有 failed"; return 0; }
  bad "$1: 有 failed 的 unit:$bad_list"; return 1
}
bc_gms_say(){   # $1=前缀 → 0 有效规则里已无 GMS 5228 / 1 有效规则仍有残留 / 2 未取得(读不了或结构认不出; 已打印)
                # 只看有效规则: 每行从第一个 # 起是注释(冻结模板的规则行里没有 #; 旧版清理只改规则、注释原样)。
                # 结构: 有效文本里要恰有一行 "table inet pdg {" 与恰一条含 "redirect to :7893" 的规则, 否则认不出 ⇒ 未取得。
  local raw l code i=0 n_tbl=0 n_red=0 hits=""
  if ! raw="$(cat -- "$BC_NFT_CONF" 2>/dev/null)"; then bad "$1: 磁盘防火墙 $BC_NFT_CONF 读不了 —— GMS 清理未取得"; return 2; fi
  while IFS= read -r l; do
    i=$((i+1)); code="${l%%#*}"
    [[ "$code" =~ ^[[:space:]]*table\ inet\ pdg\ \{[[:space:]]*$ ]] && n_tbl=$((n_tbl+1))
    [[ "$code" == *"redirect to :7893"* ]] && n_red=$((n_red+1))
    [[ "$code" == *5228* ]] && hits="$hits 第 $i 行"
  done <<<"$raw"
  if (( n_tbl != 1 || n_red != 1 )); then
    bad "$1: 磁盘防火墙结构认不出(\"table inet pdg {\" $n_tbl 行、含 redirect to :7893 的规则 $n_red 条, 都应恰 1)—— GMS 清理未取得"; return 2
  fi
  if [[ -n "$hits" ]]; then bad "$1: 磁盘防火墙的有效规则仍含 5228($hits)"; return 1; fi
  ok "$1: 磁盘防火墙的有效规则里已无 GMS 5228-5230(注释里的 5228 不算)"
}
bc_gate_b(){   # B 的前像门(收敛后) → 0 / 1(已打印)
  local st=0 u r
  for u in mosdns mihomo pdg-probe81 pdg-mitm pdg-dotwitness; do r3_stable_assert "$u" running "B 前像: $u 持续运行" 5 || st=1; done
  for u in mosdns mihomo pdg-probe81 pdg-mitm pdg-dotwitness pdg-health.timer; do
    if r3_unit_q enabled "$u"; then [[ "$R3_VAL" == enabled ]] && ok "B 前像: $u enabled" || { bad "B 前像: $u 自启是 $R3_VAL"; st=1; }
    else bad "B 前像: $u 自启观测无效: $R3_WHY"; st=1; fi
  done
  if r3_unit_q active pdg-health.timer; then [[ "$R3_VAL" == active ]] && ok "B 前像: pdg-health.timer active" || { bad "B 前像: pdg-health.timer = $R3_VAL"; st=1; }
  else bad "B 前像: pdg-health.timer 观测无效: $R3_WHY"; st=1; fi
  bc_svc_no_failed gate-b || st=1
  bc_platform_is "B 前像" ios || st=1
  bc_absent_say "B 前像(从未启用 WLOC)" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$MJ" || st=1
  bc_hij_none "B 前像" || st=1
  bc_grep_say "B 前像" 无 "内核配置没有 MITM-OUT" 'MITM-OUT' "$MC" || st=1
  bc_listen_is "B 前像(pdg-mitm 无条件 bind)" 7894 1 || st=1
  bc_record_verdict "$(ios_slots "$IOS_META" "$IOS_ART" "$OLDSRC/deploy/bot")" "$IOS_META" 1; r=$?
  (( r == 0 )) && ok "B 前像: iOS 记录 $BC_WHY" || { bad "B 前像: iOS 记录不成立(返回 $r): $BC_WHY"; st=1; }
  for u in "$IOS_META" "$IOS_ART/current.mobileconfig"; do
    bc_fp_same b0 "$u"; r=$?
    (( r == 0 )) && ok "B 前像: 旧版迁移前后 $BC_WHY" || { bad "B 前像: $BC_WHY"; st=1; }
  done
  bc_fw_compare gate-b || st=1
  bc_gms_say "B 前像" || st=1
  if (( st == 0 )); then
    bc_fp_take b "$IOS_META" "$IOS_ART/current.mobileconfig" || { bad "B 前像: 指纹登记: $R3_WHY"; st=1; }
  fi
  return "$st"
}
bc_c2_mitm_json_ok(){   # $1=标签 $2=参照 mitm.json → 0 wloc.enabled=false 且其余与参照(置 false 后)逐项相同 / 1(已打印)
  local r
  python3 - "$2" "$MJ" > /dev/null 2>&1 <<'PY'
import json, sys
b = json.load(open(sys.argv[1], encoding="utf-8")); a = json.load(open(sys.argv[2], encoding="utf-8"))
b2 = json.loads(json.dumps(b)); b2.setdefault("wloc", {})["enabled"] = False
sys.exit(0 if (a.get("wloc", {}).get("enabled") is False and a == b2) else 3)
PY
  r=$?
  case "$r" in
    0) ok "$1: mitm.json wloc.enabled=false, 地点等其余内容与参照相同";;
    3) bad "$1: mitm.json 不是'enabled=false 且其余与参照相同'"; return 1;;
    *) bad "$1: mitm.json 核对观测无效(退出 $r)"; return 1;;
  esac
}
bc_c2_root_kept(){   # $1=标签 → 0 记录仍是 schema 1、当前版 wloc=true 且产物嵌根证书 / 1(已打印)
  if python3 - "$IOS_META" "$IOS_ART/current.mobileconfig" > /dev/null 2>&1 <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
data = open(sys.argv[2], "rb").read()
sys.exit(0 if (m.get("schema") == 1 and (m.get("current") or {}).get("inputs", {}).get("wloc_enabled") is True
               and b"com.apple.security.root" in data) else 1)
PY
  then ok "$1: 记录仍是 schema 1、当前版 wloc_enabled=true, 产物仍嵌根证书"; return 0; fi
  bad "$1: 记录 / 产物不是'schema 1 且嵌根证书'的旧形态(或读不了)"; return 1
}
bc_gate_c2(){   # C2 的前像门(旧版切 Android 之后) → 0 / 1(已打印)
  local st=0 u r
  local -a m=()
  bc_platform_is "C2 前像" android || st=1
  bc_absent_say "C2 前像" "$R3_ETC/platform.guessed" || st=1
  bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; r=$?
  (( r == 0 )) && ok "C2 前像: $BC_WHY" || { bad "C2 前像: pdg-mitm 不是确认不存在(返回 $r): $BC_WHY"; st=1; }
  for u in "${BC_IOS_ONLY[@]}"; do m+=("$R3_MODDIR/$u"); done
  bc_absent_say "C2 前像(旧版切 Android 时删的 iOS 专属件)" "${m[@]}" || st=1
  bc_modules "$OLDSRC" "$R3_MODDIR" android; r=$?
  if (( r != 0 )); then bad "C2 前像: 模块观测无效: $R3_WHY"; st=1
  elif [[ "${R3_VAL#* }" == 0 ]]; then ok "C2 前像: 按旧版 android 清单 ${R3_VAL% *} 项逐字节 = v1.11.15"
  else bad "C2 前像: 有 ${R3_VAL#* } 项模块与 v1.11.15 不同:$BC_MOD_BAD"; st=1; fi
  for u in "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$IOS_META" "$IOS_ART/current.mobileconfig"; do
    bc_fp_same a "$u"; r=$?
    (( r == 0 )) && ok "C2 前像: 切换前后 $BC_WHY" || { bad "C2 前像: $BC_WHY"; st=1; }
  done
  bc_c2_mitm_json_ok "C2 前像(相对底座)" "$BC_TMP/c2-a-mitm.json" || st=1
  bc_c2_root_kept "C2 前像" || st=1
  bc_record_verdict "$(ios_slots "$IOS_META" "$IOS_ART" "$OLDSRC/deploy/bot")" "$IOS_META" 1; r=$?
  (( r == 0 )) && ok "C2 前像: iOS 记录 $BC_WHY" || { bad "C2 前像: iOS 记录不成立(返回 $r): $BC_WHY"; st=1; }
  bc_hij_none "C2 前像" || st=1
  bc_grep_say "C2 前像" 无 "内核配置没有 MITM-OUT" 'MITM-OUT' "$MC" || st=1
  for u in mosdns mihomo pdg-probe81 pdg-dotwitness; do r3_stable_assert "$u" running "C2 前像: $u 持续运行" 5 || st=1; done
  for u in pdg-dotwitness pdg-health.timer; do
    if r3_unit_q enabled "$u"; then [[ "$R3_VAL" == enabled ]] && ok "C2 前像: $u enabled" || { bad "C2 前像: $u 自启是 $R3_VAL"; st=1; }
    else bad "C2 前像: $u 自启观测无效: $R3_WHY"; st=1; fi
  done
  bc_svc_no_failed gate-c2 || st=1
  bc_listen_is "C2 前像" 7894 0 || st=1
  bc_fw_compare gate-c2 || st=1
  if (( st == 0 )); then
    bc_fp_take c2 "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$IOS_META" "$IOS_ART/current.mobileconfig" "$MJ" \
      || { bad "C2 前像: 指纹登记: $R3_WHY"; st=1; }
  fi
  return "$st"
}
# <<< PDG-EXTRACT-END bc_gate
# >>> PDG-EXTRACT-BEGIN bc_identity
bc_modules(){   # $1=源码树 $2=已安装目录 $3=平台 → 0 取得(R3_VAL="总数 不符数", BC_MOD_BAD=不符的目标名) / 2 清单取不到、格式不对、目标名重复、没有有效条目或比对出错
                # 清单每行必须是"源路径 目标名 mode"三列(源路径相对、目标名只含文件名字符、mode 是八进制), 目标名不许重复, 至少 1 项; 数量取该版本实际清单
  local src name _mode extra l n=0 i=0 badn=0 list rc r seen=" "
  R3_VAL=""; BC_MOD_BAD=""
  case "$3" in ios|android) ;; *) R3_WHY="模块核对: 不认识的平台 [$3]"; return 2;; esac
  # shellcheck source=/dev/null
  list="$( ( source "$1/lib/modules.sh" && pdg_platform_modules "$3" ) 2>/dev/null )"; rc=$?
  if (( rc != 0 )) || [[ -z "$list" ]]; then R3_WHY="$1 的 $3 模块清单取不到(rc=$rc)"; return 2; fi
  while IFS= read -r l; do
    i=$((i+1))
    read -r src name _mode extra <<<"$l"
    if [[ -z "$src" || "$src" == /* || ! "$name" =~ ^[A-Za-z0-9._-]+$ || ! "$_mode" =~ ^[0-7]{3,4}$ || -n "$extra" ]]; then
      R3_WHY="模块核对: $1 的 $3 模块清单第 $i 行格式不对(要三列: 源路径 目标名 mode; 实得 [${l:0:60}])"; return 2
    fi
    [[ "$seen" != *" $name "* ]] || { R3_WHY="模块核对: $1 的 $3 模块清单里目标名 $name 重复"; return 2; }
    seen="$seen$name "
    n=$((n+1))
    cmp -s -- "$1/$src" "$2/$name"; rc=$?
    case "$rc" in
      0) ;;
      1) badn=$((badn+1)); BC_MOD_BAD="$BC_MOD_BAD $name";;
      *) bc_fq "$1/$src"; r=$?
         (( r == 0 )) || { R3_WHY="模块核对: 源 $src 不在或查不清(${BC_WHY:-})"; return 2; }
         bc_fq "$2/$name"; r=$?
         case "$r" in
           3) badn=$((badn+1)); BC_MOD_BAD="$BC_MOD_BAD $name(不在)";;
           0) R3_WHY="模块核对: 比对 $name 出错(cmp rc=$rc)"; return 2;;
           *) R3_WHY="模块核对: $BC_WHY"; return 2;;
         esac;;
    esac
  done <<<"$list"
  (( n > 0 )) || { R3_WHY="模块核对: $1 的 $3 模块清单没有有效条目"; return 2; }
  R3_VAL="$n $badn"
}
bc_identity(){   # $1=标签 $2=源码树 $3=期望提交 → 0 HEAD / CLI / 当前平台模块清单都对得上 / 1 不符 / 2 观测无效(逐项已打印)
  local lbl="$1" src="$2" want="$3" st=0 a b p r
  if r3_head "$R3_REPO"; then
    if [[ "$R3_VAL" == "$want" ]]; then ok "$lbl 身份: 现役 HEAD = ${want:0:12}"
    else bad "$lbl 身份: 现役 HEAD=$R3_VAL, 不是 $want"; st=1; fi
  else bad "$lbl 身份观测无效(HEAD): $R3_WHY"; st=2; fi
  if r3_fsha "$R3_CLI" && a="$R3_VAL" && r3_fsha "$src/deploy/bot/pdg.sh" && b="$R3_VAL"; then
    if [[ "$a" == "$b" ]]; then ok "$lbl 身份: 现役 CLI 逐字节 = 该版 pdg.sh(${a:0:12})"
    else bad "$lbl 身份: 现役 CLI(${a:0:12}) ≠ 该版 pdg.sh(${b:0:12})"; (( st )) || st=1; fi
  else bad "$lbl 身份观测无效(CLI): $R3_WHY"; st=2; fi
  if p="$(cat -- "$R3_ETC/platform" 2>/dev/null)"; then
    [[ "$p" == "$BC_PLAT" ]] || { bad "$lbl 身份: 平台标记 [$p], 本前像应为 $BC_PLAT"; (( st )) || st=1; }
    bc_modules "$src" "$R3_MODDIR" "$p"; r=$?
    if (( r != 0 )); then bad "$lbl 身份观测无效(模块): $R3_WHY"; st=2
    elif [[ "${R3_VAL#* }" == 0 ]]; then ok "$lbl 身份: 按当前平台 $p 的清单 ${R3_VAL% *} 项模块逐字节 = 该版"
    else bad "$lbl 身份: 按当前平台 $p 的清单有 ${R3_VAL#* } 项模块与该版不同:$BC_MOD_BAD"; (( st )) || st=1; fi
  else bad "$lbl 身份观测无效: 平台标记读不了"; st=2; fi
  return "$st"
}
# <<< PDG-EXTRACT-END bc_identity
# >>> PDG-EXTRACT-BEGIN bc_svc
# 服务采样: 每个阶段一份**新**采样文件(已存在就拒绝, 不拿旧文件或部分结果顶); 采样退出码、集合完整、逐行有效分别核。
bc_row_fields(){   # $1=一行采样 → 0 按制表符拆成恰 13 列(BC_F[0..12]; 空列保留) / 2 列数不对(观测无效)
  local rest="$1" k TAB
  TAB="$(printf '\t')"; BC_F=()
  for ((k = 0; k < 12; k++)); do
    [[ "$rest" == *"$TAB"* ]] || return 2
    BC_F+=("${rest%%"$TAB"*}"); rest="${rest#*"$TAB"}"
  done
  [[ "$rest" != *"$TAB"* ]] || return 2
  BC_F+=("$rest")
}
bc_svc_phase(){   # $1=阶段名 → 0 本次新采样集合完整、逐行有效(BC_SVC_FILE / BC_SVC_ROWS) / 2 未取得(R3_WHY)
  local ph="$1" f r
  BC_SVC_FILE=""
  f="$BC_TMP/svc-$ph.tsv"
  bc_fq "$f"; r=$?
  case "$r" in
    3) ;;
    0) R3_WHY="服务采样($ph): 采样文件已存在 —— 旧文件不采用, 不覆盖"; return 2;;
    *) R3_WHY="服务采样($ph): 采样文件查询未取得($BC_WHY)"; return 2;;
  esac
  bridge_svc_sample "$f" || { R3_WHY="服务采样($ph): 采样写不出来(bridge_svc_sample 退出非 0)"; return 2; }
  declare -gA BC_SVC_ROWS=()
  r3_set_check "$f" "服务采样($ph)" BC_SVC_ROWS; r=$?
  (( r == 0 )) || return 2
  r3_rows_valid BC_SVC_ROWS || { R3_WHY="服务采样($ph): 有无效行: $R3_WHY"; return 2; }
  bc_keep_ev "$f" "07-svc-$ph.tsv"
  BC_SVC_FILE="$f"
}
bc_win_policy(){   # $1=跳(hop2|hop3) $2=前像(b|c2) $3=unit → "allow|来源" / "zero|理由"; 策略里没有 ⇒ 1(按窗口观测无效处理)
  case "$3" in
    pdg-mitm)
      if [[ "$2" == c2 ]]; then printf 'zero|C2 上 pdg-mitm 的 unit 前后都不存在, 不该有启动事件'
      elif [[ "$1" == hop2 ]]; then printf 'allow|桥接 cmd_update 收尾对 is-enabled 的 pdg-mitm reset-failed + restart; migrate_deploy_botfiles try-restart'
      else printf 'allow|退役候选 migrate_deploy_botfiles 在 iOS 且模块有变化时 try-restart pdg-mitm, 排在 migrate_wloc_retire 之前'; fi;;
    mosdns|mihomo|pdg-probe81|pdg-bot|pdg-dotwitness|pdg-health.timer) printf 'allow|桥接 cmd_update 与迁移链成功路径上有重启 / 启用';;
    sing-box|ssh|cron) printf 'zero|本现场两跳成功路径上不该启动它';;
    pdg-rescue.socket) printf 'zero|救援平面未启用; 注意 socket 激活在 journal 里记为 Listening on, 本计数口径看不到';;
    *) return 1;;
  esac
}
bc_svc_class(){   # $1=跳 $2=前像 $3=unit $4=前 $5=后 → "<类别>|<理由>"; 类别: 必需 / 正常 / 前后都不存在 / 意外 / 观测无效(行拆不出 13 列)
  local h="$1" p="$2" u="$3" b="$4" a="$5" b_act a_act b_ufs a_ufs b_load a_load rev=""
  if ! bc_row_fields "$b"; then printf '观测无效|%s 的调用前那一行拆不出 13 列' "$u"; return 0; fi
  b_load="${BC_F[4]}"; b_act="${BC_F[5]}"; b_ufs="${BC_F[7]}"
  if ! bc_row_fields "$a"; then printf '观测无效|%s 的调用后那一行拆不出 13 列' "$u"; return 0; fi
  a_load="${BC_F[4]}"; a_act="${BC_F[5]}"; a_ufs="${BC_F[7]}"
  [[ "$b_act" == active  && "$a_act" != active  ]] && rev="运行 $b_act→$a_act"
  [[ "$b_ufs" == enabled && "$a_ufs" != enabled ]] && rev="${rev:+$rev; }自启 $b_ufs→${a_ufs:-<空>}"
  case "$u" in
    pdg-mitm)
      if [[ "$p" == c2 ]]; then
        if [[ "$b_load" == not-found && "$a_load" == not-found && "$a_act" != active ]]; then
          printf '前后都不存在|C2: pdg-mitm 前后 LoadState 都是 not-found(旧版切 Android 时已禁用并删 unit)'
        else printf '意外|C2 上 pdg-mitm 应前后都不存在, 实得 %s/%s → %s/%s' "$b_load" "$b_act" "$a_load" "$a_act"; fi
      elif [[ "$h" == hop3 ]]; then
        if [[ "$a_load" == not-found && "$a_act" != active ]]; then
          printf '必需|退役 migrate_wloc_retire: disable --now / stop pdg-mitm, 删 unit 后 daemon-reload'
        else printf '意外|pdg-mitm 退役后仍是 %s/%s —— 退役链要求停、禁并删 unit' "$a_load" "$a_act"; fi
      else
        if [[ "$a_load" == loaded && "$a_act" == active && "$a_ufs" == enabled ]]; then
          printf '正常|B 第二跳: unit 在且 enabled ⇒ 桥接 migrate_pdg_mitm_service 直接返回, 收尾重启; 仍 active / enabled'
        else printf '意外|B 第二跳后 pdg-mitm 是 %s/%s/%s —— 桥接不该停 / 禁 / 删它' "$a_load" "$a_act" "${a_ufs:-<空>}"; fi
      fi;;
    mosdns|mihomo|pdg-probe81|pdg-bot|pdg-dotwitness|pdg-health.timer|pdg-health.service)
      if [[ -n "$rev" ]]; then printf '意外|%s 被停/禁(%s) —— 两跳成功路径上对它只有重启 / 启用' "$u" "$rev"
      else printf '正常|%s: 成功路径上的重启 / 启用(桥接 cmd_update 收尾与迁移链)' "$u"; fi;;
    *) printf '意外|%s 有变化 —— 本现场两跳成功路径上不该动它' "$u";;
  esac
}
bc_win_build(){   # $1=落点 $2=起界桩 $3=止界桩 → 每个受监视 unit 一行(启动事件条数或 INVALID); 0 / 1 落点写不进
  local f="$1" u n
  : > "$f" 2>/dev/null || return 1
  for u in "${SVC_WATCH[@]}"; do
    if [[ -z "$2" || -z "$3" ]]; then printf '%s\tINVALID\t界桩没建成: %s\n' "$u" "$(_j_why)" >> "$f"; continue; fi
    if n="$(_j_interval "$u" "$2" "$3")" && [[ -n "$n" ]]; then printf '%s\t%s\t-\n' "$u" "$n" >> "$f"
    else printf '%s\tINVALID\t%s\n' "$u" "$(_j_why)" >> "$f"; fi
  done
}
bc_svc_verdict(){   # $1=前 $2=后 $3=跳(hop2|hop3) $4=窗口结果 → 0 成立 / 1 不成立或未取得
  local h="$3" win="$4" u b a cls reason pol rc bi ai TAB
  local -A bc_rb=() bc_ra=()
  local n_req=0 n_norm=0 n_gone=0 n_un=0 n_inst=0 n_invalid=0 n_win=0 n_winbad=0 n_winviol=0 n_zero=0
  local unexpected="" invalid="" winbad="" winviol="" mitm_cls=""
  TAB="$(printf '\t')"
  r3_set_check "$1" "$h/前" bc_rb; rc=$?
  (( rc == 0 )) || { bad "$h 服务对账: $R3_WHY —— 集合不全或观测无效就不能谈'意外 0'"; return 1; }
  r3_set_check "$2" "$h/后" bc_ra; rc=$?
  (( rc == 0 )) || { bad "$h 服务对账: $R3_WHY —— 集合不全或观测无效就不能谈'意外 0'"; return 1; }
  r3_win_check "$win" || { bad "$h 服务对账: 窗口结果无效: $R3_WHY"; return 1; }
  echo "── 服务动作对账($h, 前像 $BC_PRE; 允许清单事先从桥接 cmd_update 与迁移链推导)──"
  for u in "${SVC_WATCH[@]}"; do
    b="${bc_rb[$u]}"; a="${bc_ra[$u]}"
    if ! pol="$(bc_win_policy "$h" "$BC_PRE" "$u")"; then n_winbad=$((n_winbad+1)); winbad="$winbad $u(窗口策略里没有它)"
    elif [[ "${WINV[$u]}" == INVALID ]]; then n_winbad=$((n_winbad+1)); winbad="$winbad $u(${WINWHY[$u]})"
    elif [[ "${pol%%|*}" == zero ]]; then
      n_zero=$((n_zero+1))
      if (( ${WINV[$u]} > 0 )); then n_winviol=$((n_winviol+1)); winviol="$winviol $u(${WINV[$u]} 条)"; fi
    elif (( ${WINV[$u]} > 0 )); then
      n_win=$((n_win+1)); printf '    %-20s [窗口内启动事件 · 允许] %s 条 —— %s\n' "$u" "${WINV[$u]}" "${pol#*|}"
    fi
    if ! bridge_row_valid "$b"; then n_invalid=$((n_invalid+1)); invalid="$invalid $u(前: $OBS_WHY)"; continue; fi
    if ! bridge_row_valid "$a"; then n_invalid=$((n_invalid+1)); invalid="$invalid $u(后: $OBS_WHY)"; continue; fi
    if ! bc_row_fields "$b"; then n_invalid=$((n_invalid+1)); invalid="$invalid $u(前: 拆不出 13 列)"; continue; fi
    bi="${BC_F[8]} ${BC_F[9]}"
    if ! bc_row_fields "$a"; then n_invalid=$((n_invalid+1)); invalid="$invalid $u(后: 拆不出 13 列)"; continue; fi
    ai="${BC_F[8]} ${BC_F[9]}"
    [[ "$bi" == "$ai" ]] || n_inst=$((n_inst+1))
    [[ "$b" != "$a" || "$u" == pdg-mitm ]] || continue        # pdg-mitm 每次都归类(C2 上前后相同也要确认"前后都不存在")
    cls="$(bc_svc_class "$h" "$BC_PRE" "$u" "$b" "$a")"; reason="${cls#*|}"; cls="${cls%%|*}"
    printf '    %-20s [%s]\n      前: %s\n      后: %s\n      依据: %s\n' "$u" "$cls" "${b#*"$TAB"}" "${a#*"$TAB"}" "$reason"
    [[ "$u" == pdg-mitm ]] && mitm_cls="$cls"
    case "$cls" in
      必需) n_req=$((n_req+1));;
      正常) n_norm=$((n_norm+1));;
      前后都不存在) n_gone=$((n_gone+1));;
      观测无效) n_invalid=$((n_invalid+1)); invalid="$invalid $u($reason)";;
      *) n_un=$((n_un+1)); unexpected="$unexpected $u";;
    esac
  done
  _evn "07-service-actions-$h.txt" "必需=$n_req 正常=$n_norm 前后都不存在=$n_gone 实例更替=$n_inst 意外=$n_un 观测无效=$n_invalid 窗口不允许启动却有启动事件=$n_winviol 窗口允许启动且有启动事件=$n_win 窗口无效=$n_winbad;$unexpected;$invalid;$winviol;$winbad"
  if (( n_invalid > 0 )); then bad "$h 服务对账: 有 $n_invalid 项观测无效:$invalid"; return 1; fi
  if (( n_winbad > 0 )); then bad "$h 服务对账: 有 $n_winbad 项窗口观测无效:$winbad"; return 1; fi
  if (( n_winviol > 0 )); then bad "$h 服务对账: 不允许启动的服务在窗口内有启动事件:$winviol"; return 1; fi
  if (( n_un > 0 )); then bad "$h 服务对账: 出现清单外的服务动作:$unexpected"; return 1; fi
  case "$BC_PRE:$h" in
    b:hop3) [[ "$mitm_cls" == 必需 ]] || { bad "$h 服务对账: 退役链必需的 pdg-mitm 停 / 禁 / 删没有发生"; return 1; };;
    b:hop2) [[ "$mitm_cls" == 正常 ]] || { bad "$h 服务对账: pdg-mitm 没有按第二跳预期保留"; return 1; };;
    c2:*)   [[ "$mitm_cls" == 前后都不存在 ]] || { bad "$h 服务对账: C2 上 pdg-mitm 没有确认前后都不存在"; return 1; };;
  esac
  ok "$h 服务对账: 终态落在事先推导的清单内(必需 $n_req / 正常 $n_norm / 前后都不存在 $n_gone; 意外 0, 观测无效 0; 实例更替 $n_inst 单列); 不允许启动的 $n_zero 个服务窗口内 0 条, 允许且出现启动事件的 $n_win 个单列 —— 窗口口径只是 journal 里 'Started <unit>' 的条数, 不是完整的服务动作审计"
}
bc_hop_svc(){   # $1=跳(hop2|hop3) $2=起界桩 $3=止界桩 → 0 成立 / 1 不成立或未取得(调用前采样由调用方在起界桩之前取)
  local h="$1" win="$BC_TMP/svc-$1-window.tsv"
  bc_svc_phase "$h-after" || { bad "$h 服务对账: 调用后采样未取得: $R3_WHY"; return 1; }
  bc_win_build "$win" "$2" "$3" || { bad "$h 服务对账: 窗口结果写不进"; return 1; }
  bc_keep_ev "$win" "07-svc-$h-window.tsv"
  bc_svc_verdict "$BC_TMP/svc-$h-before.tsv" "$BC_SVC_FILE" "$h" "$win"
}
# <<< PDG-EXTRACT-END bc_svc
# >>> PDG-EXTRACT-BEGIN bc_quiesce
# 分阶段静置: 判断同 ③ r3_quiesce(那个函数写死同一个记录文件与同名界桩, 本支不调用), 这里每个阶段自己的记录文件、界桩名与结论;
# 记录已存在就拒绝(不复用、不覆盖)。读取复用 ③ r3_q_prop / r3_q_limits / r3_q_sample / r3_q_clock / r3_q_ns 原文。
bc_q_rec(){ { printf '%s\n' "$2" >> "$1"; } 2>/dev/null || BC_Q_RECBAD=1; }   # 记录写不进 ⇒ 本阶段不成立
bc_quiesce(){   # $1=阶段名(pre-hop2 | pre-hop3) → 0 成立 / 1 不成立或观测无效(不重新计时, 不再等一轮)
  local ph="$1" rec r q0 q1 t0 t1 el="" els=未取得 sr n why="" lim k
  local -a id0 id1 idn=(MainPID InvocationID NRestarts)
  case "$ph" in pre-hop2|pre-hop3) ;; *) bad "静置: 不认识的阶段名 [$ph]"; return 1;; esac
  rec="$EVID/06-quiesce-$ph.txt"
  bc_fq "$rec"; r=$?
  case "$r" in
    3) ;;
    0) bad "$ph 静置: 记录文件 $rec 已存在 —— 不复用旧记录、不覆盖、不等待"; return 1;;
    *) bad "$ph 静置: 记录文件查询未取得($BC_WHY) —— 不等待"; return 1;;
  esac
  BC_Q_RECBAD=0
  bc_q_rec "$rec" "# $ph 静置: 本验收人为规定的验收时序前提(不证明它必需, 不消除 324 的产品问题)。$R3_Q_UNIT 计划一次 ${R3_Q_SECS} s(300 s 窗口 + 3 s 余量), 实得以 CLOCK_MONOTONIC 为准; 不循环、不重试、不 reset-failed、不启停服务"
  r3_q_limits; r=$?
  if (( r != 0 )); then
    (( r == 1 )) && why="$R3_WHY" || why="限额观测无效: $R3_WHY"
    bc_q_rec "$rec" "限额(静置前): $why; 结论: 不成立(没有等待)"; bad "$ph 静置: $why —— 不等待"; return 1
  fi
  lim="$R3_VAL"; bc_q_rec "$rec" "限额(静置前): $lim"; echo "  Q $ph 限额: $R3_Q_UNIT $lim"
  r3_q_sample 静置前; r=$?
  if (( r != 0 )); then
    (( r == 1 )) && why="$R3_WHY" || why="静置前采样观测无效: $R3_WHY"
    bc_q_rec "$rec" "静置前: $why; 结论: 不成立(没有等待)"; bad "$ph 静置: $why —— 直接阻断, 不等待"; return 1
  fi
  read -r -a id0 <<<"$R3_Q_ID"; bc_q_rec "$rec" "静置前: $R3_Q_S"; echo "  Q $ph 静置前: $R3_Q_S"
  if ! q0="$(_j_mark "quiesce-$ph-start")" || [[ -z "$q0" ]]; then
    why="起界桩 quiesce-$ph-start 没建成($(_j_why))"; bc_q_rec "$rec" "$why; 结论: 不成立(没有等待)"; bad "$ph 静置观测无效: $why —— 不等待"; return 1
  fi
  bc_q_rec "$rec" "起界桩: quiesce-$ph-start(游标 $q0)"
  if ! r3_q_clock; then
    why="t0: $R3_WHY"; bc_q_rec "$rec" "$why; 结论: 不成立(没有等待)"; bad "$ph 静置观测无效: $why —— 不等待"; return 1
  fi
  t0="$R3_VAL"
  sleep "$R3_Q_SECS"; sr=$?
  if r3_q_clock; then
    t1="$R3_VAL"
    if (( t1 < t0 )); then why="$why 观测无效: 单调时钟倒退(t0=$t0 t1=$t1);"
    else el=$(( t1 - t0 )); els="$(r3_q_ns "$el") s"; fi
  else why="$why 观测无效: t1: $R3_WHY;"; t1=""; fi
  bc_q_rec "$rec" "等待: 计划 ${R3_Q_SECS} s; sleep 退出 $sr; t0=$t0 ns t1=${t1:-未取得} ns 实得=$els"
  echo "  Q $ph 静置: 计划 ${R3_Q_SECS} s; sleep 退出 $sr; CLOCK_MONOTONIC 实得 $els"
  (( sr == 0 )) || why="$why 等待失败: sleep 退出 $sr;"
  if [[ -n "$el" ]] && (( el < R3_Q_NEED_NS )); then why="$why 实得 $els < ${R3_Q_SECS} s(sleep 返回 $sr 不作数);"; fi
  r3_q_sample 静置后; r=$?
  case "$r" in
    0) bc_q_rec "$rec" "静置后: $R3_Q_S"; echo "  Q $ph 静置后: $R3_Q_S"
       read -r -a id1 <<<"$R3_Q_ID"
       for k in 0 1 2; do [[ "${id1[k]}" == "${id0[k]}" ]] || why="$why 静置期间 ${idn[k]} ${id0[k]} → ${id1[k]};"; done;;
    1) bc_q_rec "$rec" "静置后: $R3_WHY"; why="$why $R3_WHY;";;
    *) bc_q_rec "$rec" "静置后采样观测无效: $R3_WHY"; why="$why 静置后采样观测无效: $R3_WHY;";;
  esac
  r3_q_limits; r=$?
  case "$r" in
    0) bc_q_rec "$rec" "限额(静置后): $R3_VAL";;
    1) bc_q_rec "$rec" "限额(静置后): $R3_WHY"; why="$why 静置后$R3_WHY;";;
    *) bc_q_rec "$rec" "限额(静置后)观测无效: $R3_WHY"; why="$why 静置后限额观测无效: $R3_WHY;";;
  esac
  if ! q1="$(_j_mark "quiesce-$ph-end")" || [[ -z "$q1" ]]; then
    why="$why 观测无效: 止界桩 quiesce-$ph-end 没建成($(_j_why));"; bc_q_rec "$rec" "止界桩 quiesce-$ph-end 没建成($(_j_why))"
  elif n="$(_j_interval "$R3_Q_UNIT" "$q0" "$q1")" && [[ "$n" =~ ^[0-9]+$ ]]; then
    bc_q_rec "$rec" "止界桩: quiesce-$ph-end(游标 $q1); 界桩区间 Started $R3_Q_UNIT: $n 次(口径只计 Started 事件; 并非 systemd 内部启动计数的直接读数)"
    echo "  Q $ph 界桩区间 Started $R3_Q_UNIT $n 次(口径只计 Started 事件)"
    (( n == 0 )) || why="$why 静置期间界桩区间内 Started $R3_Q_UNIT $n 次;"
  else
    why="$why 观测无效: 界桩区间的启动事件查不清($(_j_why));"; bc_q_rec "$rec" "界桩区间观测无效: $(_j_why)"
  fi
  bc_q_rec "$rec" "结论($ph): ${why:+不成立:}${why:-成立}"
  (( BC_Q_RECBAD == 0 )) || why="$why 静置记录写不进证据目录($rec);"
  if [[ -n "$why" ]]; then bad "$ph 静置不成立 ——${why%;}(不重新计时, 不再等一轮)"; return 1; fi
  ok "$ph 静置: $R3_Q_UNIT 限额仍为 $R3_Q_INT / $R3_Q_BURST; 一次静置 sleep 退出 0、单调时钟实得 $els(≥ ${R3_Q_SECS} s); 前后运行态、MainPID / InvocationID / NRestarts 与限额一致, 界桩区间内 Started 0 次 —— 人为规定的时序前提成立(不证明必需)"
}
# <<< PDG-EXTRACT-END bc_quiesce
# >>> PDG-EXTRACT-BEGIN bc_dns
# DNS 仪器: 调整步骤同 ③(留原文、改 local_upstream、geosite_cn 追加 W / K / C_pre / C_post、起自有上游、写回、重启一次),
# 但留证只写已完成的调整; 标定与还原核验用 ③ r3_dns_calibrate 原文(它事后写 05-dns-calibration.txt)。
# 固定 W 只在第三跳之后查询; 每个探针标签的原始记录文件已存在就拒绝(不覆盖)。
bc_dns_adjust(){   # 建立仪器条件(只做一次) → 0 成立 / 2 不成立(R3_WHY)
  local ln old rc sha
  [[ "$R3_DNS_U" != "$E2E_SIP" ]] || { R3_WHY="U 与 H 相同($R3_DNS_U), 这组预期没有区分力"; return 2; }
  R3_DNS_UPLINE="    args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$R3_DNS_PORT\"} ] }"
  r3_copy_record "$R3_MOSCFG" "$EVID/05-dns-mosdns-config.before.yaml" || return 2
  r3_copy_record "$R3_GEOCN" "$EVID/05-dns-geosite_cn.before.txt" || return 2
  r3_dns_cfgline "$EVID/05-dns-mosdns-config.before.yaml" "$R3_DNS_UPLINE" "$R3_TMP/moscfg.new" || return 2
  ln="${R3_VAL%%$'\t'*}"; old="${R3_VAL#*$'\t'}"
  r3_dns_append_full "$EVID/05-dns-geosite_cn.before.txt" "$R3_TMP/geocn.new" "$R3_DNS_W" "$R3_DNS_K" "$R3_DNS_CPRE" "$R3_DNS_CPOST" || return 2
  r3_fsha "$R3_STUB" || return 2
  sha="$R3_VAL"
  r3_dns_stub_start || { R3_WHY="自有上游: $R3_WHY"; return 2; }
  r3_dns_write "$R3_TMP/moscfg.new" "$R3_MOSCFG" || return 2
  r3_dns_write "$R3_TMP/geocn.new" "$R3_GEOCN" || return 2
  r3_copy_record "$R3_MOSCFG" "$EVID/05-dns-mosdns-config.after.yaml" || return 2
  r3_copy_record "$R3_GEOCN" "$EVID/05-dns-geosite_cn.after.txt" || return 2
  r3_fsha "$R3_GEOCN" || return 2
  R3_DNS_GEOSHA="$R3_VAL"
  diff -u "$EVID/05-dns-mosdns-config.before.yaml" "$EVID/05-dns-mosdns-config.after.yaml" > "$EVID/05-dns-mosdns-config.diff" 2>&1; rc=$?
  (( rc == 1 )) || { R3_WHY="配置调整前后差异取不到(diff 退出 $rc)"; return 2; }
  diff -u "$EVID/05-dns-geosite_cn.before.txt" "$EVID/05-dns-geosite_cn.after.txt" > "$EVID/05-dns-geosite_cn.diff" 2>&1; rc=$?
  (( rc == 1 )) || { R3_WHY="geosite_cn 调整前后差异取不到(diff 退出 $rc)"; return 2; }
  r3_dns_restart "仪器条件生效" || return 2
  { echo "# 第三跳前对第二跳现场所做的 DNS 仪器调整(本文件只记已经完成的调整)"
    echo "自有上游: python3 $R3_STUB(sha256 $sha)--port $R3_DNS_PORT --mode answer-a --answer $R3_DNS_U; PID $R3_STUB_PID; 日志 $R3_UPLOG; 计数 $R3_UPCNT"
    echo "$R3_MOSCFG 第 $ln 行(local_upstream 的 args):"; echo "  前: $old"; echo "  后: $R3_DNS_UPLINE"
    echo "$R3_GEOCN 末尾追加: full:$R3_DNS_W full:$R3_DNS_K full:$R3_DNS_CPRE full:$R3_DNS_CPOST(调整后 sha256 $R3_DNS_GEOSHA)"
    echo "普通劫持探针 $R3_DNS_PPRE / $R3_DNS_PPOST 不写进任何集合; 劫持模式、规则顺序、其它规则未动; 接管表未被本调整改动"
    echo "仪器条件生效的那次 mosdns 重启已完成(05-dns-instrument-restarts.txt)"
  } > "$EVID/05-dns-instrument-adjustments.txt" 2>/dev/null || { R3_WHY="仪器调整清单写不进证据目录"; return 2; }
  echo "  I 仪器调整: $R3_MOSCFG 第 $ln 行 local_upstream → 127.0.0.1:$R3_DNS_PORT; $R3_GEOCN 末尾追加 4 个 full: 名字(差异见 05-dns-*.diff)"
}
bc_dns_instrument(){   # 仪器条件建立 → 标定与还原核验(③ 原文) → 0 全成立 / 1 不成立(调用方据此不调用)
  if ! bc_dns_adjust; then bad "第三跳前 DNS 仪器条件没建立: $R3_WHY"; return 1; fi
  ok "第三跳前 DNS 仪器条件已建立: 自有上游(U=$R3_DNS_U)只接 local_upstream; geosite_cn 追加 W / K / 两个分阶段对照名; 劫持模式与规则顺序未动"
  if ! r3_dns_calibrate; then bad "第三跳前 DNS 仪器标定不成立: $R3_WHY"; return 1; fi
  ok "第三跳前 DNS 仪器标定(本 runner 上): 同一名字 K 在三个实例里按接管表那一行 U→H→U 精确切换, 来源各有上游记录为证; 接管表磁盘还原与运行还原分别已核实"
}
bc_dns_fresh(){   # $1=探针标签 → 0 该标签的原始记录文件确认不存在 / 1 已存在或查询未取得(拒绝, 不覆盖)
  local r
  bc_fq "$EVID/05-dns-probe-$1.txt"; r=$?
  case "$r" in
    3) return 0;;
    0) R3_WHY="探针标签 $1 的原始记录已存在 —— 不覆盖, 不再问";;
    *) R3_WHY="探针标签 $1 的原始记录查询未取得($BC_WHY)";;
  esac
  return 1
}
bc_dns_cond(){   # $1=前缀 → 0 仪器条件仍成立 / 1(已打印; 不做查询)
  local r
  r3_dns_conditions; r=$?
  case "$r" in
    0) ok "$1 仪器条件仍成立(自有上游同一进程; local_upstream 那一行与 geosite_cn 都是调整后的原样)"; return 0;;
    1) bad "$1 仪器条件被改动: $R3_WHY —— 该阶段 DNS 结论未取得, 不做查询";;
    *) bad "$1 仪器条件观测失效: $R3_WHY —— 该阶段 DNS 结论未取得, 不做查询";;
  esac
  return 1
}
bc_dns_ask(){   # $1=前缀 $2=名字 $3=标签 $4=U|H $5=说明 → 0 成立 / 1 不成立或未取得(已打印)
  if ! bc_dns_fresh "$3"; then bad "$1 $5 —— $R3_WHY; 结论未取得"; return 1; fi
  r3_dns_path "$2" "$3" "$4"
  r3_dns_say "$1" "$5" $?
}
bc_dns_p_ok(){   # $1=前缀 $2=P 名 → 0 P 不被任何规则匹配 / 1(已打印)
  if ! r3_dns_rulematch "$2"; then bad "$1 P 规则匹配判不了: $R3_WHY —— 普通劫持路径结论未取得"; return 1; fi
  if [[ -n "${R3_VAL#*$'\t'}" ]]; then bad "$1 P 探针 $2 被规则匹配(${R3_VAL#*$'\t'}) —— 不能代表普通劫持路径, 结论未取得"; return 1; fi
  ok "$1 P 探针 $2 不被任何 domain_set 规则或内联 qname 匹配(按 mosdns 语义求值)"
}
bc_dns_pre(){   # 第三跳前: C_pre 取得 U、P_pre 走 H(来源各自以本次窗口的上游增量为据); 不问 W → 0 成立 / 1 不成立或未取得
  local lb="第三跳前 DNS" st=0
  bc_dns_cond "$lb" || return 1
  bc_dns_ask "$lb" "$R3_DNS_CPRE" pre-c U "C(独立上游对照 $R3_DNS_CPRE)经 local_upstream 取得 U" || st=1
  if bc_dns_p_ok "$lb" "$R3_DNS_PPRE"; then
    bc_dns_ask "$lb" "$R3_DNS_PPRE" pre-p H "P(普通劫持探针 $R3_DNS_PPRE)走 H、自有上游未收到: 普通 DNS 代理劫持路径在" || st=1
  else st=1; fi
  return "$st"
}
bc_dns_post(){   # 第三跳后: W 第一次被问(只在这里问)取得 U、C_post 取得 U、P_post 走 H; 不要求 mosdns 换过实例 → 0 成立 / 1 不成立或未取得
  local lb="第三跳后 DNS" st=0
  bc_dns_cond "$lb" || return 1
  bc_dns_ask "$lb" "$R3_DNS_W" post-w U "W($R3_DNS_W, 本次第一次被问)经 local_upstream 由自有上游取得 U: 没有 WLOC 专属接管" || st=1
  bc_dns_ask "$lb" "$R3_DNS_CPOST" post-c U "C(独立上游对照 $R3_DNS_CPOST)经 local_upstream 取得 U" || st=1
  if bc_dns_p_ok "$lb" "$R3_DNS_PPOST"; then
    bc_dns_ask "$lb" "$R3_DNS_PPOST" post-p H "P(普通劫持探针 $R3_DNS_PPOST)走 H、自有上游未收到: 普通 DNS 代理劫持路径保留" || st=1
  else st=1; fi
  return "$st"
}
# <<< PDG-EXTRACT-END bc_dns
# >>> PDG-EXTRACT-BEGIN bc_fw
# 防火墙比较: 宿主内核 `nft -j list table inet pdg` 对照"同一台 runner 上临时命名空间里 nft -f /etc/nftables.conf 之后的同一张表"。
# 规范化只删三类: 顶层 metainfo; table / chain / rule 对象上的 handle 键; counter 语句的 packets / bytes 数值(保留"有 counter")。
# 端口、地址、前缀长度、优先级、range 两端、redirect 端口与规则顺序一律保留比较; 匿名集合元素排序后比。
# 不支持的对象或语句、JSON 结构不认识、任一步命令失败 ⇒ 未取得(既不判一致也不判不一致)。运行计数单列, 不进一致性判断。
bc_fw_norm(){   # $1=宿主 JSON $2=参照 JSON → 0 一致 / 1 不一致(逐项打印) / 2 未取得
  python3 - "$1" "$2" <<'PY'
import json, sys
STMT = {"match", "accept", "drop", "return", "reject", "redirect", "jump", "goto", "counter"}
LEFT = {"payload", "meta", "ct"}
class Unsup(Exception):
    pass
def scalar(v, w):
    if isinstance(v, bool) or not isinstance(v, (str, int)):
        raise Unsup("%s: 不认识的取值 %r" % (w, v))
    return v
def flat(d, w):
    if not isinstance(d, dict):
        raise Unsup("%s: 应为对象 %r" % (w, d))
    return {k: scalar(x, w) for k, x in d.items()}
def right(v, w):
    if isinstance(v, (str, int)) and not isinstance(v, bool):
        return v
    if isinstance(v, list):
        return [scalar(x, w) for x in v]
    if isinstance(v, dict) and len(v) == 1:
        k, x = next(iter(v.items()))
        if k == "set" and isinstance(x, list):
            return {"set": sorted((right(e, w) for e in x), key=lambda e: json.dumps(e, sort_keys=True))}
        if k == "range" and isinstance(x, list) and len(x) == 2:
            return {"range": [right(x[0], w), right(x[1], w)]}
        if k == "prefix" and isinstance(x, dict) and set(x) == {"addr", "len"}:
            return {"prefix": {"addr": scalar(x["addr"], w), "len": scalar(x["len"], w)}}
    raise Unsup("%s: 不认识的右值 %r" % (w, v))
def stmt(s, w, cnt):
    if not (isinstance(s, dict) and len(s) == 1):
        raise Unsup("%s: 语句结构不认识 %r" % (w, s))
    k, v = next(iter(s.items()))
    if k not in STMT:
        raise Unsup("%s: 不支持的语句 %s" % (w, k))
    if k == "match":
        if not (isinstance(v, dict) and set(v) == {"op", "left", "right"}):
            raise Unsup("%s: match 结构不认识" % w)
        l = v["left"]
        if not (isinstance(l, dict) and len(l) == 1 and next(iter(l)) in LEFT):
            raise Unsup("%s: match 左值不支持 %r" % (w, l))
        lk = next(iter(l))
        return {"match": {"op": scalar(v["op"], w), "left": {lk: flat(l[lk], w)}, "right": right(v["right"], w)}}
    if k in ("accept", "drop", "return"):
        if v is not None:
            raise Unsup("%s: %s 带了参数" % (w, k))
        return {k: None}
    if k in ("reject", "redirect"):
        return {k: None if v is None else flat(v, w)}
    if k in ("jump", "goto"):
        if not (isinstance(v, dict) and set(v) == {"target"}):
            raise Unsup("%s: %s 结构不认识" % (w, k))
        return {k: flat(v, w)}
    if v is None:
        cnt.append((w, None, None)); return {"counter": {}}
    if not (isinstance(v, dict) and set(v) <= {"packets", "bytes"}):
        raise Unsup("%s: counter 结构不认识 %r" % (w, v))
    cnt.append((w, v.get("packets"), v.get("bytes")))
    return {"counter": {}}
def norm(path, who):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    if not (isinstance(d, dict) and isinstance(d.get("nftables"), list)):
        raise Unsup("%s: 顶层不是 {nftables: [...]}" % who)
    tables, chains, rules, cnt = [], {}, {}, []
    for o in d["nftables"]:
        if not (isinstance(o, dict) and len(o) == 1):
            raise Unsup("%s: 对象结构不认识" % who)
        k, v = next(iter(o.items()))
        if k == "metainfo":
            continue
        if k not in ("table", "chain", "rule") or not isinstance(v, dict):
            raise Unsup("%s: 不支持的对象 %s" % (who, k))
        v = {x: y for x, y in v.items() if x != "handle"}
        if k == "table":
            tables.append(flat(v, who))
        elif k == "chain":
            c = flat(v, who)
            if c.get("name") in chains:
                raise Unsup("%s: 链 %s 重复" % (who, c.get("name")))
            chains[c.get("name")] = c
        else:
            if not isinstance(v.get("expr"), list) or set(v) - {"family", "table", "chain", "expr", "comment"}:
                raise Unsup("%s: 规则结构不认识(键 %s)" % (who, sorted(v)))
            ch = scalar(v.get("chain"), who)
            i = len(rules.setdefault(ch, []))
            w = "%s 链 %s 第 %d 条" % (who, ch, i + 1)
            r = {x: scalar(y, w) for x, y in v.items() if x != "expr"}
            r["expr"] = [stmt(s, w, cnt) for s in v["expr"]]
            rules[ch].append(r)
    if len(tables) != 1 or tables[0].get("family") != "inet" or tables[0].get("name") != "pdg":
        raise Unsup("%s: 表对象不是恰一张 inet pdg(%r)" % (who, tables))
    return tables[0], chains, rules, cnt
try:
    H = norm(sys.argv[1], "宿主")
    R = norm(sys.argv[2], "参照")
except Unsup as e:
    print("未取得: %s" % e); sys.exit(2)
except (OSError, ValueError) as e:
    print("未取得: 读不了或不是 JSON(%s)" % e); sys.exit(2)
diff = []
if H[0] != R[0]:
    diff.append("表属性不同: 宿主 %r / 参照 %r" % (H[0], R[0]))
for n in sorted(set(H[1]) | set(R[1])):
    if n not in H[1] or n not in R[1]:
        diff.append("链 %s 只在%s" % (n, "参照" if n not in H[1] else "宿主")); continue
    if H[1][n] != R[1][n]:
        diff.append("链 %s 属性不同: 宿主 %r / 参照 %r" % (n, H[1][n], R[1][n]))
for n in sorted(set(H[2]) | set(R[2])):
    a, b = H[2].get(n, []), R[2].get(n, [])
    if len(a) != len(b):
        diff.append("链 %s 规则条数 宿主 %d / 参照 %d" % (n, len(a), len(b)))
    for i, (x, y) in enumerate(zip(a, b), 1):
        if x != y:
            diff.append("链 %s 第 %d 条规则不同: 宿主 %s / 参照 %s" % (n, i, json.dumps(x, ensure_ascii=False, sort_keys=True), json.dumps(y, ensure_ascii=False, sort_keys=True)))
for who, c in (("宿主", H[3]), ("参照", R[3])):
    if c:
        print("运行计数(不进一致性判断, %s): %s" % (who, "; ".join("%s packets=%s bytes=%s" % t for t in c)))
if diff:
    for x in diff:
        print("不一致: " + x)
    sys.exit(1)
print("一致: 表 / %d 条链 / %d 条规则(按顺序)逐项相同(只去掉 metainfo、handle 与 counter 数值)" % (len(H[1]), sum(len(x) for x in H[2].values())))
sys.exit(0)
PY
}
bc_fw_compare(){   # $1=阶段名 → 0 一致 / 1 不一致 / 2 未取得(结论写 $EVID/03-fw-<阶段>.txt 并打印)
  local ph="$1" hf="$BC_TMP/fw-$1-host.json" rf="$BC_TMP/fw-$1-ref.json" ns="pdgbc-$1-$$" rc out r why=""
  nft -j list table inet pdg > "$hf" 2>/dev/null; rc=$?
  if (( rc != 0 )); then why="宿主 nft -j list table inet pdg 退出 $rc"
  elif ! ip netns add "$ns" > /dev/null 2>&1; then why="建不出临时命名空间 $ns"
  else
    if ! ip netns exec "$ns" nft -f /etc/nftables.conf > "$BC_TMP/fw-$ph-ref.load" 2>&1; then why="临时命名空间里 nft -f /etc/nftables.conf 失败"
    elif ! ip netns exec "$ns" nft -j list table inet pdg > "$rf" 2>/dev/null; then why="临时命名空间里 nft -j list table inet pdg 失败"; fi
    ip netns del "$ns" > /dev/null 2>&1 || note "防火墙比较($ph): 临时命名空间 $ns 删不掉(残留)"
  fi
  if [[ -n "$why" ]]; then
    printf '未取得: %s\n' "$why" > "$EVID/03-fw-$ph.txt" 2>/dev/null
    bad "防火墙($ph): 内核与磁盘一致性未取得 —— $why"; return 2
  fi
  out="$(bc_fw_norm "$hf" "$rf" 2>&1)"; r=$?
  printf '%s\n' "$out" > "$EVID/03-fw-$ph.txt" 2>/dev/null
  case "$r" in
    0) ok "防火墙($ph): 宿主内核 inet pdg 与磁盘配置(临时命名空间加载)$(grep -m1 '^一致' <<<"$out")"; return 0;;
    1) bad "防火墙($ph): 宿主内核与磁盘配置不一致 —— $(grep '^不一致' <<<"$out" | head -3 | tr '\n' ' ')"; return 1;;
    *) bad "防火墙($ph): 一致性未取得 —— $(head -2 <<<"$out" | tr '\n' ' ')"; return 2;;
  esac
}
# <<< PDG-EXTRACT-END bc_fw
# >>> PDG-EXTRACT-BEGIN bc_hop2
# 第二跳: 从桥接候选自己的文档按唯一成对标记抽入口流程, 在空的入口副本目录里执行恰一次(与 ② 同一抽法, 另写成本支的函数)。
bc_hop2(){   # → 0 已调用(结果在 BC_H2_*) / 2 调用前停止(没有调用; R3_WHY)
  local doc="$BRSRC/docs/BRIDGE-ENTRY.md" fb fe a b r
  BC_H2_FLOW="$BC_TMP/bridge-entry-flow.sh"; BC_H2_ENTRY="$BC_TMP/bridge-entry-copy"
  BC_H2_LOG="$BC_TMP/hop2.log"; BC_H2_RCF="$BC_TMP/hop2.rc"; BC_H2_TOE="$BC_TMP/hop2.timeout-stderr"
  BC_H2_C0=""; BC_H2_C1=""
  [[ -f "$doc" ]] || { R3_WHY="桥接候选里没有 docs/BRIDGE-ENTRY.md"; return 2; }
  fb="$(grep -c '^# --- pdg-bridge-entry-flow: BEGIN' "$doc")"; fe="$(grep -c '^# --- pdg-bridge-entry-flow: END' "$doc")"
  [[ "$fb" == 1 && "$fe" == 1 ]] || { R3_WHY="入口流程标记不是唯一成对(BEGIN=$fb END=$fe)"; return 2; }
  awk '/^# --- pdg-bridge-entry-flow: BEGIN/{f=1;next} /^# --- pdg-bridge-entry-flow: END/{exit} f' "$doc" > "$BC_H2_FLOW" \
    || { R3_WHY="抽取入口流程失败"; return 2; }
  [[ -s "$BC_H2_FLOW" ]] || { R3_WHY="抽出来的入口流程是空的"; return 2; }
  bash -n "$BC_H2_FLOW" 2>/dev/null || { R3_WHY="入口流程语法不过"; return 2; }
  r3_grepq -E 'pdg\.sh" update --to' "$BC_H2_FLOW"; r=$?
  (( r == 0 )) || { R3_WHY="入口流程里没有正式更新步(从副本运行 pdg.sh update --to; grep 返回 $r)"; return 2; }
  case "$BC_H2_ENTRY" in "$R3_REPO"|"$R3_REPO"/*) R3_WHY="入口副本落在现役仓库里($BC_H2_ENTRY)"; return 2;; esac
  bc_fq "$BC_H2_ENTRY"; r=$?
  (( r == 3 )) || { R3_WHY="入口副本目录不是确认不存在(${BC_WHY:-已存在}) —— 流程要求空目录"; return 2; }
  r3_fsha "$R3_CLI" || return 2
  a="$R3_VAL"
  r3_fsha "$OLDSRC/deploy/bot/pdg.sh" || return 2
  b="$R3_VAL"
  [[ "$a" == "$b" ]] || { R3_WHY="调用前现役 CLI 已经不是 v1.11.15(${a:0:12}) —— 桥接版被提前安装了"; return 2; }
  r3_grepq '^_pdg_save_svcstate(){' "$R3_CLI"; r=$?
  (( r == 1 )) || { R3_WHY="调用前现役 CLI 里已经有前像能力(或查不清, grep 返回 $r)"; return 2; }
  r3_fsha "$doc" || return 2
  _evn 03-hop2-identity.txt "入口来源 = $doc(sha256 $R3_VAL)"
  r3_fsha "$BC_H2_FLOW" || return 2
  _evn 03-hop2-identity.txt "入口流程原文 sha256 = $R3_VAL; 入口副本 = $BC_H2_ENTRY(独立于现役 $R3_REPO); 显式目标 = $BRIDGE_TAG → $BRIDGE_SHA"
  _evn 03-hop2-identity.txt "调用前现役 CLI sha256 = $a(= v1.11.15 pdg.sh)"
  bc_svc_phase hop2-before || return 2
  if ! BC_H2_C0="$(_j_mark hop2-start)" || [[ -z "$BC_H2_C0" ]]; then BC_H2_C0=""; R3_WHY="第二跳起界桩没建成($(_j_why))"; return 2; fi
  bc_run "$BC_CNT_HOP2" "$BC_H2_LOG" "$BC_H2_RCF" "$BC_H2_TOE" "$BC_HOP2_TIMEOUT" \
    env -u PDG_UPDATE_SVCSTATE -u PDG_TAG_BOOTSTRAPPED -u PDG_PLATFORM \
        TAG="$BRIDGE_TAG" WANT="$BRIDGE_SHA" ENTRY="$BC_H2_ENTRY" SRC="$ORIGIN" bash "$BC_H2_FLOW" || return 2
  BC_H2_C1="$(_j_mark hop2-end)" || { BC_H2_C1=""; note "第二跳止界桩没建成($(_j_why)) —— 窗口将判观测无效"; }
  bc_keep_ev "$BC_H2_LOG" 04-hop2-flow.log; bc_keep_ev "$BC_H2_RCF" 04-hop2.rc; bc_keep_ev "$BC_H2_TOE" 04-hop2.timeout-stderr
  tail -40 "$BC_H2_LOG" 2>/dev/null | sed 's/^/    /'
  return 0
}
bc_post2_b(){   # B 第二跳后的现场(桥接链只换模块与 CLI、不撤 WLOC 能力、不迁记录) → 0 / 1(已打印)
  local st=0 u r
  r3_stable_assert pdg-mitm running "第二跳后 B: pdg-mitm 持续运行" 5 || st=1
  if r3_unit_q enabled pdg-mitm; then [[ "$R3_VAL" == enabled ]] && ok "第二跳后 B: pdg-mitm enabled" || { bad "第二跳后 B: pdg-mitm 自启是 $R3_VAL"; st=1; }
  else bad "第二跳后 B: pdg-mitm 自启观测无效: $R3_WHY"; st=1; fi
  bc_listen_is "第二跳后 B" 7894 1 || st=1
  for u in "$IOS_META" "$IOS_ART/current.mobileconfig"; do
    bc_fp_same b "$u"; r=$?
    (( r == 0 )) && ok "第二跳后 B: 桥接未迁记录 —— $BC_WHY" || { bad "第二跳后 B: $BC_WHY"; st=1; }
  done
  bc_absent_say "第二跳后 B" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$MJ" || st=1
  bc_platform_is "第二跳后 B" ios || st=1
  if r3_unit_q active pdg-dotwitness; then [[ "$R3_VAL" == active ]] && ok "第二跳后 B: pdg-dotwitness active" || { bad "第二跳后 B: pdg-dotwitness = $R3_VAL"; st=1; }
  else bad "第二跳后 B: pdg-dotwitness 观测无效: $R3_WHY"; st=1; fi
  bc_hop2_dns_cfg "第二跳后 B" || st=1
  return "$st"
}
bc_post2_c2(){   # C2 第二跳后的现场(WLOC 残留与前像相同; 模块按 Android 清单) → 0 / 1(已打印)
  local st=0 u r m=()
  bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; r=$?
  (( r == 0 )) && ok "第二跳后 C2: $BC_WHY" || { bad "第二跳后 C2: pdg-mitm 不是确认不存在(返回 $r): $BC_WHY"; st=1; }
  bc_listen_is "第二跳后 C2" 7894 0 || st=1
  for u in "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$IOS_META" "$IOS_ART/current.mobileconfig" "$MJ"; do
    bc_fp_same c2 "$u"; r=$?
    (( r == 0 )) && ok "第二跳后 C2: 与 C2 前像一致 —— $BC_WHY" || { bad "第二跳后 C2: $BC_WHY"; st=1; }
  done
  for u in "${BC_IOS_ONLY[@]}"; do m+=("$R3_MODDIR/$u"); done
  bc_absent_say "第二跳后 C2" "${m[@]}" || st=1
  bc_platform_is "第二跳后 C2" android || st=1
  if r3_unit_q active pdg-dotwitness; then [[ "$R3_VAL" == active ]] && ok "第二跳后 C2: pdg-dotwitness active" || { bad "第二跳后 C2: pdg-dotwitness = $R3_VAL"; st=1; }
  else bad "第二跳后 C2: pdg-dotwitness 观测无效: $R3_WHY"; st=1; fi
  bc_hop2_dns_cfg "第二跳后 C2" || st=1
  return "$st"
}
bc_hop2_dns_cfg(){   # $1=前缀 → 第二跳只给配置层结论: 接管表无条目、mosdns 配置仍引用接管表、内核配置无 MITM-OUT
  local st=0
  bc_hij_none "$1 DNS 配置层" || st=1
  bc_grep_say "$1 DNS 配置层" 有 "mosdns 配置仍引用接管表 mitm_hijack.txt" -F 'mitm_hijack.txt' "$R3_MOSCFG" || st=1
  bc_grep_say "$1 DNS 配置层" 无 "内核配置没有 MITM-OUT" 'MITM-OUT' "$MC" || st=1
  (( st == 0 )) && note "$1: 第二跳的 DNS 结论只到配置层(不是 DNS 行为验收; 行为证据只在第三跳前后取)"
  return "$st"
}
bc_hop2_verdict(){   # → 0 第二跳成立 / 1 不成立或未取得(第三跳不调用)
  local st=0 r
  bc_rc_settle 第二跳 "$BC_H2_RCF" "$BC_H2_TOE"; r=$?
  case "$r" in
    0) ok "第二跳 进程: $BC_WHY";;
    1) bad "第二跳 进程不成立: $BC_WHY"; st=1;;
    *) bad "第二跳 进程观测未取得: $BC_WHY"; st=1;;
  esac
  _evn 03-hop2-identity.txt "第二跳调用计数 = $(bc_counts_say); $BC_WHY"
  bc_grep_say "第二跳 输出" 有 "入口副本的身份核对通过并留痕" -F '✅ 身份核对通过' "$BC_H2_LOG" || st=1
  bc_grep_say "第二跳 输出" 有 "产品的钉版贯穿门留痕($BRIDGE_TAG → $BRIDGE_SHA)" -F "钉版目标已贯穿到实际安装: $BRIDGE_TAG → $BRIDGE_SHA" "$BC_H2_LOG" || st=1
  bc_grep_say "第二跳 输出" 有 "产品自报「✅ 已更新。」" -F '✅ 已更新。' "$BC_H2_LOG" || st=1
  bc_identity 第二跳后 "$BRSRC" "$BRIDGE_SHA" || st=1
  "bc_post2_$BC_PRE" || st=1
  bc_hop_svc hop2 "$BC_H2_C0" "$BC_H2_C1" || st=1
  return "$st"
}
# <<< PDG-EXTRACT-END bc_hop2
# >>> PDG-EXTRACT-BEGIN bc_pre3
bc_runtime_gate(){   # 第三跳前一刻(静置之后)的运行态 → 0 / 1(已打印)
  local st=0 u
  for u in mosdns mihomo pdg-probe81 pdg-dotwitness; do r3_stable_assert "$u" running "第三跳前: $u 持续运行" 5 || st=1; done
  if [[ "$BC_PRE" == b ]]; then
    r3_stable_assert pdg-mitm running "第三跳前 B: pdg-mitm 持续运行" 5 || st=1
    bc_listen_is "第三跳前 B" 7894 1 || st=1
  else
    bc_listen_is "第三跳前 C2" 7894 0 || st=1
  fi
  if r3_http_code http://127.0.0.1:81/; then
    [[ "$R3_VAL" == 200 ]] && ok "第三跳前: :81 HTTP 200" || { bad "第三跳前: :81 状态码 $R3_VAL(要 200)"; st=1; }
  else bad "第三跳前: :81 观测无效: $R3_WHY"; st=1; fi
  return "$st"
}
bc_isactive_pair(){   # $1=同一次 is-active 查询的输出 $2=它的原始退出码 $3=已有效取得的 LoadState → 0 配对成立 / 2 不成立(BC_WHY)
                      # 规则与共享读取器 r3_unit_q 的 active 分支相同(不放宽): 输出恰一行且是状态词; active|reloading|refreshing 配 0;
                      # inactive 配 3, 只有 LoadState=not-found 时才可配 4; failed|activating|deactivating|maintenance 配 3; 其它都不成立
  local out="$1" rc="$2" ld="$3"
  [[ "$out" != *$'\n'* ]] || { BC_WHY="is-active 输出不止一行([${out//$'\n'/|}], rc=$rc)"; return 2; }
  case "$out" in
    active|reloading|refreshing) (( rc == 0 )) || { BC_WHY="is-active 打印 $out 却退出 $rc(应为 0)"; return 2; };;
    inactive) (( rc == 3 )) || { (( rc == 4 )) && [[ "$ld" == not-found ]]; } \
                || { BC_WHY="is-active 打印 inactive 却退出 $rc(应为 3; 只有 LoadState=not-found 时才可为 4, 实得 LoadState=[$ld])"; return 2; };;
    failed|activating|deactivating|maintenance) (( rc == 3 )) || { BC_WHY="is-active 打印 $out 却退出 $rc(应为 3)"; return 2; };;
    *) BC_WHY="is-active 输出不是状态词([${out:0:30}], rc=$rc)"; return 2;;
  esac
}
bc_precapture(){   # 第三跳调用前必须取得的观测, 逐项打印; 任一没取到 ⇒ 1(调用方据此不调用)
  local st=0 ld out rc
  if r3_copy_record "$IOS_META" "$BC_TMP/ios-before-hop3.json"; then echo "  E iOS 记录原文已留(逐字节核过)"
  else echo "  E 没取得: $R3_WHY"; st=1; fi
  if r3_copy_record "$IOS_ART/current.mobileconfig" "$BC_TMP/current-before-hop3.mobileconfig"; then echo "  E 当前描述文件原文已留(逐字节核过)"
  else echo "  E 没取得: $R3_WHY"; st=1; fi
  if [[ "$BC_PRE" == b ]]; then
    KREQ=("$R3_ETC/platform"); KOPT=("$R3_ETC/bot.env" "$R3_MODDIR/dot-domain")
    bc_absent_say "第三跳前 B(应当不存在)" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$MJ" || st=1
  else
    KREQ=("$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$R3_ETC/platform" "$MJ" "$IOS_META" "$IOS_ART/current.mobileconfig")
    KOPT=("$R3_ETC/bot.env" "$R3_MODDIR/dot-domain")
  fi
  r3_keep_capture || st=1
  BC_SNAP3=""
  if r3_lsdir "$SNAPROOT"; then BC_SNAP3="$R3_VAL"; echo "  E 快照目录清单已取得(${R3_NOTE:-$(grep -c . <<<"$BC_SNAP3") 项})"
  else echo "  E 快照目录清单没取得: $R3_WHY"; st=1; fi
  if bc_svc_phase hop3-before; then echo "  E 调用前服务采样 ${#SVC_WATCH[@]} 项齐全且逐行有效(新采样)"
  else echo "  E 调用前服务采样未取得: $R3_WHY"; st=1; fi
  # C4 的直接观测: 第三跳调用前一刻 pdg-mitm 的 is-active 只查一次, 这一次的输出与原始退出码按共享读取器同一规则核配对(不拿第二次查询背书), 连同 LoadState 记下
  if r3_unit_q load pdg-mitm; then
    ld="$R3_VAL"
    out="$(systemctl is-active pdg-mitm 2>/dev/null)"; rc=$?
    if bc_isactive_pair "$out" "$rc" "$ld"; then
      _evn 08-c4-observation.txt "第三跳调用前一刻(起界桩之前), 同一次 systemctl is-active pdg-mitm: 输出 [$out] 原始退出码 $rc, 配对成立; LoadState=$ld"
      echo "  E C4 直接观测: pdg-mitm is-active [$out]/$rc(同一次查询, 配对成立), LoadState=$ld"
    else
      _evn 08-c4-observation.txt "第三跳调用前一刻, 同一次 systemctl is-active pdg-mitm: 输出 [$out] 原始退出码 $rc, 配对不成立($BC_WHY); LoadState=$ld —— 不调用"
      echo "  E C4 直接观测无效: $BC_WHY(同一次查询的输出与退出码对不上; 不拿第二次查询背书)"; st=1
    fi
  else echo "  E C4 直接观测无效: $R3_WHY"; st=1; fi
  BC_H3_C0=""
  if BC_H3_C0="$(_j_mark hop3-start)" && [[ -n "$BC_H3_C0" ]]; then echo "  E journal 起界桩已建"
  else BC_H3_C0=""; echo "  E journal 起界桩没建成($(_j_why)) —— 窗口无从谈起"; st=1; fi
  return "$st"
}
# <<< PDG-EXTRACT-END bc_pre3
# >>> PDG-EXTRACT-BEGIN bc_gate3
bc_gated_invoke(){   # 第三跳: 门全过、调用前观测取全才调用(r3_invoke 原文)。返回(21–26 都**没有**调用):
                     #   21=桥接身份(HEAD / CLI / 当前平台模块) 22=DNS 仪器条件 / 标定 / 还原核验 24=第三跳前静置
                     #   25=运行态门 23=前阶段 DNS(C / P 的路径与来源) 26=调用前观测没取全或计数 / 退出码留档不可用; 0=已调用
  bc_identity 第三跳前 "$BRSRC" "$BRIDGE_SHA" || return 21
  bc_dns_instrument || return 22
  bc_quiesce pre-hop3 || return 24
  bc_runtime_gate || return 25
  bc_dns_pre || return 23
  bc_precapture || return 26
  r3_invoke || { echo "  调用前停止: $R3_WHY"; return 26; }
  return 0
}
# <<< PDG-EXTRACT-END bc_gate3
# >>> PDG-EXTRACT-BEGIN bc_post
bc_rec_settle(){   # $1=记录核对进程的原始退出码 → 0 十项齐全且全成立 / 1 有已证实的业务差异 / 2 观测无效(已打印; 失败行不当成已证实的差异)
                   # 退出状态、完整输出、逐项集合(R1–R10 各恰一次, 不许有别的行)与结论分别核: 0 ⇔ 全部 OK; 3 ⇔ 至少一项 FAIL; 其它退出码或矛盾都是观测无效
  local rc="$1" raw l why="" n_ok=0 n_fail=0 seen=" " i
  local -a st_of=() name_of=()
  if ! raw="$(cat -- "$BC_TMP/post-b-record.txt" 2>/dev/null)"; then
    bad "B 终态: 记录核对观测无效 —— 结果文件读不了(核对进程退出 $rc; 结果不采信)"; return 2
  fi
  while IFS= read -r l; do
    if [[ "$l" =~ ^(OK\ \ \ |FAIL\ )R([1-9]|10)\ (.+)$ ]]; then
      i="${BASH_REMATCH[2]}"
      if [[ "$seen" == *" $i "* ]]; then why="$why R$i 重复;"; continue; fi
      seen="$seen$i "; st_of[i]="${BASH_REMATCH[1]%% *}"; name_of[i]="${BASH_REMATCH[3]}"
      if [[ "${st_of[i]}" == OK ]]; then n_ok=$((n_ok+1)); else n_fail=$((n_fail+1)); fi
    else why="$why 不认识的行([${l:0:40}]);"; fi
  done <<<"$raw"
  (( n_ok + n_fail == 10 )) || why="$why 结果只有 $((n_ok + n_fail)) / 10 项;"
  case "$rc" in
    0) (( n_fail == 0 )) || why="$why 退出 0 却有 $n_fail 项失败;";;
    3) (( n_fail > 0 )) || why="$why 退出 3 却没有任何失败记录;";;
    *) why="$why 核对进程退出 $rc;";;
  esac
  if [[ -n "$why" ]]; then bad "B 终态: 记录核对观测无效 ——${why%;}(结果不采信, 不当成已证实的业务差异)"; return 2; fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ "${st_of[i]}" == OK ]]; then ok "B 终态: ${name_of[i]}"; else bad "B 终态: ${name_of[i]}"; fi
  done
  (( n_fail == 0 )) || return 1
}
bc_post_b(){   # B 第三跳后终态 → 0 成立 / 1 不成立或未取得(逐项已打印)
  local st=0 r
  bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; r=$?
  if (( r == 0 )); then
    ok "B 终态: $BC_WHY"
    if r3_unit_q active pdg-mitm not-found; then
      [[ "$R3_VAL" != active ]] && ok "B 终态: pdg-mitm is-active=$R3_VAL" || { bad "B 终态: pdg-mitm 仍 active"; st=1; }
    else bad "B 终态: pdg-mitm is-active 观测无效: $R3_WHY"; st=1; fi
  else bad "B 终态: pdg-mitm 不是确认不存在(返回 $r): $BC_WHY"; st=1; fi
  bc_absent_say "B 终态(执行件)" "$R3_MODDIR/mitm_server.py" "$R3_MODDIR/mitm_wloc.py" || st=1
  bc_listen_is "B 终态" 7894 0 || st=1
  bc_hij_none "B 终态" || st=1
  bc_grep_say "B 终态" 无 "内核配置没有 MITM-OUT" 'MITM-OUT' "$MC" || st=1
  python3 - "$BC_TMP/ios-before-hop3.json" "$IOS_META" "$IOS_ART/current.mobileconfig" "$BC_TMP/current-before-hop3.mobileconfig" \
    > "$BC_TMP/post-b-record.txt" 2>&1 <<'PY'
import json, sys
b = json.load(open(sys.argv[1], encoding="utf-8")); a = json.load(open(sys.argv[2], encoding="utf-8"))
bc = b.get("current") or {}; ac = a.get("current") or {}
checks = [
    ("记录 schema 1 → 2", b.get("schema") == 1 and a.get("schema") == 2),
    ("instance_id 原样", bool(b.get("instance_id")) and a.get("instance_id") == b.get("instance_id")),
    ("created_at 原样", a.get("created_at") == b.get("created_at")),
    ("current 仍在(wloc=false 的版本按迁移契约保留)", a.get("current") is not None),
    ("current.revision 不变(%s)" % bc.get("revision"), bc.get("revision") is not None and ac.get("revision") == bc.get("revision")),
    ("current.sha256 不变", bool(bc.get("sha256")) and ac.get("sha256") == bc.get("sha256")),
    ("previous 与第三跳前相同", a.get("previous") == b.get("previous")),
    ("retired_revision 为 None", a.get("retired_revision") is None),
]
try:
    now = open(sys.argv[3], "rb").read(); there = True
except FileNotFoundError:
    now = None; there = False
checks.append(("current.mobileconfig 仍在", there))
checks.append(("current.mobileconfig 与第三跳前逐字节相同", there and now == open(sys.argv[4], "rb").read()))
nbad = 0
for i, (name, good) in enumerate(checks, 1):
    print(("OK   " if good else "FAIL ") + "R%d %s" % (i, name)); nbad += 0 if good else 1
sys.exit(3 if nbad else 0)
PY
  r=$?
  bc_rec_settle "$r" || st=1
  bc_absent_say "B 终态(仍然从未启用 WLOC)" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$MJ" || st=1
  bc_grep_say "B 终态 日志" 有 "产品自报 WLOC 执行能力已退役" -F '✅ WLOC 位置改写及其专属 MITM 执行能力已退役' "$R3_LOG" || st=1
  bc_grep_say "B 终态 日志" 有 "产品自报 iOS 记录已迁到新格式" -F '✅ iOS 描述文件记录已迁移到新格式' "$R3_LOG" || st=1
  bc_grep_say "B 终态 日志" 无 "没有 CA 提示(B 上从未有 CA)" -F '盘上仍有 WLOC 时期的 CA 材料' "$R3_LOG" || st=1
  bc_platform_is "B 终态" ios || st=1
  return "$st"
}
bc_post_c2(){   # C2 第三跳后终态; 保留维按 360 选择(甲)判 → 0 成立 / 1 不成立或未取得(逐项已打印)
  local st=0 r u m=()
  bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; r=$?
  (( r == 0 )) && ok "C2 终态: $BC_WHY(前后都不存在)" || { bad "C2 终态: pdg-mitm 不是确认不存在(返回 $r): $BC_WHY"; st=1; }
  for u in "${BC_IOS_ONLY[@]}"; do m+=("$R3_MODDIR/$u"); done
  bc_absent_say "C2 终态" "${m[@]}" || st=1
  bc_listen_is "C2 终态" 7894 0 || st=1
  bc_hij_none "C2 终态" || st=1
  bc_grep_say "C2 终态" 无 "内核配置没有 MITM-OUT" 'MITM-OUT' "$MC" || st=1
  bc_grep_say "C2 终态 日志" 无 "没有'执行能力已退役'(Android 上没有可撤的执行能力)" -F '执行能力已退役' "$R3_LOG" || st=1
  bc_grep_say "C2 终态 日志" 无 "没有'记录已迁移到新格式'(Android 清单不装 iosstate)" -F '✅ iOS 描述文件记录已迁移到新格式' "$R3_LOG" || st=1
  bc_grep_say "C2 终态 日志" 有 "产品按保留策略报告 CA 材料仍在" -F '盘上仍有 WLOC 时期的 CA 材料' "$R3_LOG" || st=1
  for u in "$IOS_META" "$IOS_ART/current.mobileconfig" "$MJ" "$CA_DIR/ca.crt" "$CA_DIR/ca.key"; do
    bc_fp_same c2 "$u"; r=$?
    (( r == 0 )) && ok "C2 终态(按 360 选择(甲)): 与 C2 前像一致 —— $BC_WHY" || { bad "C2 终态(按 360 选择(甲)): $BC_WHY"; st=1; }
  done
  bc_c2_root_kept "C2 终态(按 360 选择(甲))" || st=1
  bc_platform_is "C2 终态" android || st=1
  note "C2 保留维按 360 选择(甲)判: 旧 schema-1 记录与含根证书的旧描述文件与前像一致即成立; 不宣称旧文件已清除、手机上的信任已撤销或任何分发渠道都不可用; 未来转回 iOS 的行为不外推"
  return "$st"
}
bc_post_runtime(){   # 第三跳后的运行 / 自启态与真实功能 → 0 / 1(已打印)
  local st=0 u
  for u in mosdns mihomo pdg-probe81; do r3_stable_assert "$u" running "第三跳后: $u 持续运行" 5 || st=1; done
  for u in mosdns mihomo pdg-probe81; do
    if r3_unit_q enabled "$u"; then [[ "$R3_VAL" == enabled ]] && ok "第三跳后: $u enabled" || { bad "第三跳后: $u 自启是 $R3_VAL"; st=1; }
    else bad "第三跳后: $u 自启观测无效: $R3_WHY"; st=1; fi
  done
  for u in pdg-dotwitness pdg-health.timer; do
    if r3_unit_q active "$u"; then [[ "$R3_VAL" == active ]] && ok "第三跳后: $u active" || { bad "第三跳后: $u = $R3_VAL"; st=1; }
    else bad "第三跳后: $u 观测无效: $R3_WHY"; st=1; fi
  done
  if r3_http_code http://127.0.0.1:81/; then
    [[ "$R3_VAL" == 200 ]] && ok "第三跳后: :81 HTTP 200" || { bad "第三跳后: :81 状态码 $R3_VAL(要 200)"; st=1; }
  else bad "第三跳后: :81 功能观测未取得: $R3_WHY —— 不算通过"; st=1; fi
  return "$st"
}
bc_hop3_verdict(){   # 第三跳逐维验收 → 0 全部成立 / 1 有不成立或未取得
  local st=0
  bc_keep_ev "$R3_LOG" 04-hop3-update.log; bc_keep_ev "$R3_RCFILE" 04-hop3-update.rc; bc_keep_ev "$R3_TOERR" 04-hop3-update.timeout-stderr
  tail -40 "$R3_LOG" 2>/dev/null | sed 's/^/    /'
  if r3_arrival_verdict; then ok "第三跳 进程状态 / 目标到达 / 观测有效性分别成立"
  else bad "第三跳 进程 $R3_PROC / 目标到达 $R3_ARRIVE / 观测 $R3_OBS —— 不成立"; st=1; fi
  _evn 03-hop3-identity.txt "桥接 = $BRIDGE_TAG → $BRIDGE_SHA; 退役 = $RETIRE_TAG → $RETIRE_SHA; 调用 = bash $R3_CLI update --to $RETIRE_TAG(经 timeout --verbose $R3_TIMEOUT)"
  _evn 03-hop3-identity.txt "调用计数 = $(bc_counts_say); 包装器(timeout)返回码 = ${R3_WRAP_RC:-未取得}; 产品原始退出码 = ${R3_RC:-未取得}"
  bc_identity 第三跳后 "$R3_RTSRC" "$RETIRE_SHA" || st=1
  bc_snap_new "第三跳 快照" "$BC_SNAP3" 1 || st=1
  "bc_post_$BC_PRE" || st=1
  r3_keep_verdict || st=1
  bc_post_runtime || st=1
  bc_dns_post || st=1
  bc_hop_svc hop3 "$BC_H3_C0" "$BC_H3_C1" || st=1
  return "$st"
}
# <<< PDG-EXTRACT-END bc_post
# >>> PDG-EXTRACT-BEGIN bc_main
bc_notrun(){ bad "$1 —— 场景未执行($(bc_counts_say))"; nrun "场景 $BC_PRE: $1"; }
bc_hardgate(){   # 真实环境硬门(不成立即硬停)
  local c sc
  [[ "$(cat /proc/1/comm 2>/dev/null)" == systemd ]] || _hard "PID 1 不是 systemd"
  sc="$(command -v systemctl || true)"; [[ -x "$sc" ]] || _hard "没有 systemctl"
  case "$sc" in /usr/local/bin/*) _hard "systemctl 解析到 $sc(本仓桩的落点), 拒绝";; esac
  [[ "$(head -c2 -- "$sc" 2>/dev/null)" != '#!' ]] || _hard "systemctl 是脚本, 不是真二进制"
  nft list ruleset > /dev/null 2>&1 || _hard "nft 读不到内核规则"
  [[ -f /usr/local/bin/mosdns && "$(stat -c %s /usr/local/bin/mosdns)" -gt 1000000 ]] || _hard "mosdns 不是真二进制"
  e2e_mihomo_is_real 2>/dev/null || _hard "mihomo 不是真钉死版"
  for c in git python3 openssl ss curl sha256sum dig timeout comm cmp stat diff ip nft logger journalctl awk sed tar; do
    command -v "$c" > /dev/null || _hard "缺命令: $c"
  done
  ok "硬门: 真 systemd / 真 systemctl / 真 nft / 钉死版 mosdns+mihomo / 基础命令齐备"
  if systemctl is-active systemd-resolved > /dev/null 2>&1; then
    systemctl disable --now systemd-resolved > /dev/null 2>&1
    note "已停用 runner 自带的 systemd-resolved(释放 :53; 一次性 runner 专属改动)"
  fi
  rm -f /etc/resolv.conf 2>/dev/null
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf || _hard "resolv.conf 写不进"
}
bc_source_map(){   # 自有一次性裸库: v1.11.15 / 桥接 / 退役三个真实对象(同 ② 的源映射, 另写成本支函数)
  local s sel br kind
  for s in "$OLD_SHA" "$BRIDGE_SHA" "$RETIRE_SHA"; do
    [[ "$(git -C "$E2E_ROOT" cat-file -t "$s" 2>/dev/null)" == commit ]] || _hard "本 job 的检出里取不到对象 $s"
  done
  [[ ! -e "$ORIGIN" ]] || _hard "裸库落点已存在($ORIGIN)"
  git clone --bare -q "$E2E_ROOT" "$ORIGIN" || _hard "建裸库失败"
  e2e_guard_repo "$ORIGIN" || _hard "裸库没通过 ref 库守卫"
  e2e_git "$ORIGIN" fetch -q "$E2E_ROOT" "+refs/tags/*:refs/tags/*" > /dev/null 2>&1 || note "从检出取 tag 失败(下面按需补建)"
  if [[ "$(git -C "$ORIGIN" rev-parse -q --verify "refs/tags/$OLD_TAG^{commit}" 2>/dev/null)" == "$OLD_SHA" ]]; then
    kind="$(git -C "$ORIGIN" cat-file -t "refs/tags/$OLD_TAG" 2>/dev/null)"
  else
    e2e_git "$ORIGIN" tag -f "$OLD_TAG" "$OLD_SHA" > /dev/null 2>&1 || _hard "补建 $OLD_TAG 失败"
    kind="lightweight(本轮补建)"
  fi
  e2e_git "$ORIGIN" tag -f "$BRIDGE_TAG" "$BRIDGE_SHA" > /dev/null 2>&1 || _hard "建桥接测试 tag 失败"
  e2e_git "$ORIGIN" tag -f "$RETIRE_TAG" "$RETIRE_SHA" > /dev/null 2>&1 || _hard "建退役测试 tag 失败"
  e2e_git "$ORIGIN" update-ref refs/heads/main "$BRIDGE_SHA" || _hard "裸库 main 指不过去"
  git -C "$ORIGIN" for-each-ref --format='%(refname)' refs/heads > "$BC_TMP/heads.txt" || _hard "列不出裸库分支"
  while IFS= read -r br; do
    [[ "$br" == refs/heads/main ]] && continue
    e2e_git "$ORIGIN" update-ref -d "$br" > /dev/null 2>&1 || _hard "删不掉裸库分支 $br"
  done < "$BC_TMP/heads.txt"
  e2e_git "$ORIGIN" symbolic-ref HEAD refs/heads/main || _hard "裸库 HEAD 指不过去"
  sel="$(git -C "$ORIGIN" tag -l 'v*' --sort=-v:refname | head -1)"
  [[ "$sel" == "$RETIRE_TAG" ]] || _hard "最高版本不是退役目标而是 $sel, 源映射无效"
  mkdir -p "$OLDSRC" "$BRSRC" "$R3_RTSRC" || _hard "源码树落点建不出来"
  git -C "$ORIGIN" archive "$OLD_SHA" | tar -x -C "$OLDSRC" || _hard "展开 v1.11.15 源码失败"
  git -C "$ORIGIN" archive "$BRIDGE_SHA" | tar -x -C "$BRSRC" || _hard "展开桥接源码失败"
  git -C "$ORIGIN" archive "$RETIRE_SHA" | tar -x -C "$R3_RTSRC" || _hard "展开退役源码失败"
  {
    echo "# 测试源映射(与正式发布路径的差异, 逐条)"
    echo "裸库              : $ORIGIN(本机自有, 一次性)"
    echo "$OLD_TAG          → $OLD_SHA(类型: $kind)"
    echo "$BRIDGE_TAG       → $BRIDGE_SHA(仅测试的合成 tag 名; 对象是真实桥接候选)"
    echo "$RETIRE_TAG       → $RETIRE_SHA(仅测试; 版本号最高, 第二跳要证明它没被误装)"
    echo "裸库 refs/heads/main → $BRIDGE_SHA"
    echo "正式路径取件自官方仓库与官方 v* tag; 本轮取件自本机裸库与合成 tag ⇒ 本支通过不等于正式发布来源已验证。"
  } | _ev 02-source-map.txt
  ok "源映射已留档(02-source-map.txt); 排序最高的是退役目标 $RETIRE_TAG"
}
bc_deps_selfcheck(){   # 依赖自检: 抽进来的常量数组非空、名字像 unit; 真实消费者(采样 + 集合判据)按 SVC_WATCH 跑一遍 → 0 / 1
  local u
  (( ${#E2E_OWNED_UNITS[@]} > 0 && ${#SVC_WATCH[@]} > 0 )) || { bad "依赖自检: E2E_OWNED_UNITS / SVC_WATCH 有空数组"; return 1; }
  for u in "${E2E_OWNED_UNITS[@]}" "${SVC_WATCH[@]}"; do
    [[ "$u" =~ ^[A-Za-z0-9@._-]+$ ]] || { bad "依赖自检: 有不像 unit 名的元素 [$u]"; return 1; }
  done
  for u in "${E2E_OWNED_UNITS[@]}"; do
    [[ "$u" == *.service || "$u" == *.timer || "$u" == *.socket ]] || { bad "依赖自检: E2E_OWNED_UNITS 里 [$u] 没有 unit 后缀"; return 1; }
  done
  bc_svc_phase depcheck || { bad "依赖自检: $R3_WHY"; return 1; }
  ok "依赖自检: E2E_OWNED_UNITS ${#E2E_OWNED_UNITS[@]} 项 / SVC_WATCH ${#SVC_WATCH[@]} 项; 采样器与集合判据按 SVC_WATCH 真跑一遍齐全有效"
}
bc_main(){   # → 0 两跳与各自判据全部成立 / 1 有不成立、未取得或场景未执行
  local g st=0
  SECT "B/C2-0 真实环境硬门、源映射与依赖自检(前像 $BC_PRE)"
  bc_hardgate
  bc_source_map
  bc_deps_selfcheck || { bc_notrun "依赖自检没过"; return 1; }
  SECT "B/C2-1 前像构造($BC_PRE)"
  "bc_build_$BC_PRE"
  if [[ "${BC_PRE_OK:-0}" != 1 ]]; then bc_notrun "前像构造不成立"; return 1; fi
  SECT "B/C2-2 前像门($BC_PRE)"
  if ! "bc_gate_$BC_PRE"; then bc_notrun "前像门不成立"; return 1; fi
  snap_state "bc-preimage-$BC_PRE"
  SECT "B/C2-3 第二跳前静置(人为规定的验收时序前提)"
  if ! bc_quiesce pre-hop2; then bc_notrun "第二跳前静置不成立"; return 1; fi
  SECT "B/C2-4 第二跳: 桥接入口流程(恰一次)"
  if ! bc_hop2; then bc_notrun "第二跳调用前停止: $R3_WHY"; return 1; fi
  if ! bc_hop2_verdict; then
    bad "第二跳不成立或未取得 —— 第三跳不调用($(bc_counts_say))"; nrun "场景 $BC_PRE: 第二跳不成立, 第三跳未执行"; return 1
  fi
  snap_state "bc-after-hop2"
  SECT "B/C2-5 第三跳: 门全过、调用前观测取全才调用现役桥接 CLI update --to $RETIRE_TAG"
  bc_gated_invoke; g=$?
  if (( g != 0 )); then
    bad "第三跳门返回 $g(见上) —— 第三跳未调用($(bc_counts_say))"; nrun "场景 $BC_PRE: 第三跳前提不成立($g)"; return 1
  fi
  BC_H3_C1="$(_j_mark hop3-end)" || { BC_H3_C1=""; note "第三跳止界桩没建成($(_j_why)) —— 窗口将判观测无效"; }
  SECT "B/C2-6 第三跳逐维验收($BC_PRE)"
  bc_hop3_verdict || st=1
  snap_state "bc-after-hop3"
  return "$st"
}
# <<< PDG-EXTRACT-END bc_main

# ── 输入 ────────────────────────────────────────────────────────────────────
OLD_SHA="${PDG_OLD_SHA:-242602c17bd92900df81f468aae8c66e18c7a4ff}"     # v1.11.15 peeled
BRIDGE_SHA="${PDG_BRIDGE_SHA:-}"; RETIRE_SHA="${PDG_RETIRE_SHA:-}"
[[ "$OLD_SHA" =~ ^[0-9a-f]{40}$ ]] || _hard "PDG_OLD_SHA 不是 40 位提交"
[[ "$BRIDGE_SHA" =~ ^[0-9a-f]{40}$ ]] || _hard "必须显式给出 40 位桥接 SHA(PDG_BRIDGE_SHA)"
[[ "$RETIRE_SHA" =~ ^[0-9a-f]{40}$ ]] || _hard "必须显式给出 40 位退役候选 SHA(PDG_RETIRE_SHA)"
OLD_TAG="v1.11.15"; BRIDGE_TAG="v9.9.8-bridge-TEST"; RETIRE_TAG="v9.9.9-retire-TEST"
TEST_TAG="$BRIDGE_TAG"                       # build_preimage 用它把新 tag 从工作副本里删掉, 逼取件真去 fetch
ORIGIN="$BC_TMP/origin.git"; OLDSRC="$BC_TMP/oldsrc"; BRSRC="$BC_TMP/brsrc"; R3_RTSRC="$BC_TMP/rtsrc"
REPO=/opt/privdns-gateway; R3_REPO="$REPO"; R3_CLI=/usr/local/bin/pdg; R3_MODDIR=/opt/pdg-bot; R3_ETC=/etc/privdns-gateway
R3_OBJ="$E2E_ROOT"
R3_LOG="$BC_TMP/hop3-update.log"; R3_TIMEOUT="${PDG_BC_HOP3_TIMEOUT:-900}"
R3_RCFILE="$BC_TMP/hop3-update.rc"; R3_TOERR="$BC_TMP/hop3-update.timeout-stderr"
BC_HOP2_TIMEOUT="${PDG_BC_HOP2_TIMEOUT:-900}"; BC_OLD_TIMEOUT="${PDG_BC_OLD_TIMEOUT:-900}"
SNAPROOT=/var/lib/privdns-gateway/backups
IOS_META=/etc/privdns-gateway/ios-profile.json; IOS_ART=/var/lib/privdns-gateway/ios-profile
MJ=/etc/privdns-gateway/mitm.json; HIJ=/etc/mosdns/rules/mitm_hijack.txt; MC=/etc/mihomo/config.yaml
CA_DIR=/etc/privdns-gateway/ca
BC_MITM_UNIT=/etc/systemd/system/pdg-mitm.service
BC_NFT_CONF=/etc/nftables.conf               # B 前像门的 GMS 判据读它(模型格据此换成样本)
BC_IOS_ONLY=(mitm_ca.py mitm_server.py mitm_wloc.py iosprofile.py iosstate.py pdg-dot.mobileconfig.tmpl pdg-mitm.mobileconfig.tmpl)
BC_B_MIGFILES=(/etc/mosdns/config.yaml /etc/mihomo/config.yaml /etc/sing-box/config.json /etc/nftables.conf
               /etc/privdns-gateway/profile.env /etc/privdns-gateway/bot.env /etc/privdns-gateway/platform /etc/privdns-gateway/backend
               /etc/systemd/journald.conf.d/50-pdg.conf /etc/systemd/system/mosdns.service /etc/systemd/system/mihomo.service
               /etc/systemd/system/pdg-mitm.service /etc/systemd/system/pdg-probe81.service /etc/systemd/system/pdg-health.service
               /etc/systemd/system/pdg-health.timer /etc/systemd/system/pdg-bot.service /etc/systemd/system/pdg-dotwitness.service)
KREQ=(); KOPT=()
declare -A KFP=() BC_FP=() BC_SVC_ROWS=()
# DNS 仪器(③ r3_dns 段): U = 自有上游固定答案, H = 产品规定的劫持地址 E2E_SIP; 名字每次运行新造(W 除外, W 只在第三跳之后问)
R3_DNS_U=198.51.100.7; R3_DNS_PORT=15301; R3_DNS_W=gs-loc.apple.com
R3_STUB="$E2E_ROOT/tests/helpers/dns-stub.py"; R3_STUB_PID=""; R3_DNS_RESTARTS=0
R3_UPLOG="$BC_TMP/dns-up.log"; R3_UPCNT="$BC_TMP/dns-up.count"; R3_UPOUT="$BC_TMP/dns-up.out"
R3_MONO=(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')   # 静置的实得时长以 CLOCK_MONOTONIC 为准
R3_MOSCFG=/etc/mosdns/config.yaml; R3_GEOCN=/etc/mosdns/rules/geosite_cn.txt
_sfx="$$-$RANDOM"
R3_DNS_K="bck-$_sfx.e2e.test"; R3_DNS_CPRE="bcc-pre-$_sfx.e2e.test"; R3_DNS_CPOST="bcc-post-$_sfx.e2e.test"
R3_DNS_PPRE="bcp-pre-$_sfx.e2e.test"; R3_DNS_PPOST="bcp-post-$_sfx.e2e.test"

{ mkdir -p "$EVID" && chmod 700 "$EVID"; } 2>/dev/null || _hard "证据目录 $EVID 建不出来 —— 调用计数无处可落, 不调用"
BC_CNT_HOP2="$EVID/00-hop2-invoke-count.txt"; BC_CNT_HOP3="$EVID/00-hop3-invoke-count.txt"; BC_CNT_OLD="$EVID/00-old-cli-invoke-count.txt"
R3_COUNT="$BC_CNT_HOP3"                       # ③ r3_invoke 原文按 R3_COUNT 记第三跳
for _c in "$BC_CNT_HOP2" "$BC_CNT_HOP3" "$BC_CNT_OLD"; do
  bc_count_init "$_c" || _hard "调用计数初始化失败: $R3_WHY —— 不调用"
done

bc_main; BC_RC=$?

SECT "B/C2-7 收尾"
{
  echo "# 前像 $BC_PRE($BC_PLAT): $([[ "$BC_PRE" == b ]] && echo '夹具组装 + v1.11.15 自己的 pdg migrate 一次(不是完整旧安装器装出的现场)' || echo '共享 build_preimage ios on + 防火墙加载 + v1.11.15 自己的 pdg platform android 一次')"
  echo "# 调用次数: $(bc_counts_say)"
  echo "# 第二跳: 桥接入口流程(04-hop2-*); 第三跳: bash $R3_CLI update --to $RETIRE_TAG(04-hop3-*)"
  echo "# 退出码: 第三跳包装器(timeout)返回码 ${R3_WRAP_RC:-未取得}; 第三跳产品原始退出码 ${R3_RC:-未取得}; 第二跳见 03-hop2-identity.txt"
  echo "# 两段静置(人为规定的验收时序前提, 不证明必需): 06-quiesce-pre-hop2.txt / 06-quiesce-pre-hop3.txt"
  echo "# DNS 仪器重启 $R3_DNS_RESTARTS 次(05-dns-instrument-restarts.txt), 都在第三跳调用前观测起界桩之前; 第二跳只有配置层结论"
  [[ "$BC_PRE" == c2 ]] && echo "# C2: build_preimage 内部首次启动命令的退出码未取得; 保留维按 360 选择(甲)判(不宣称旧文件已清除 / 信任已撤销 / 分发渠道不可用)"
  echo "# 窗口口径: journal 'Started <unit>' 条数 —— 不是完整的服务动作审计"
  echo "# 不覆盖: ④ 晚期失败恢复、A-off、C1、完整旧安装器、官方分发来源、发布"
  echo "# 证据文件"; ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-bc-summary.txt
chmod 600 "$EVID"/* 2>/dev/null || true
echo; echo "未执行(前像/前置不成立而跳过)的场景数: $E2E_NOTRUN"
if (( BC_RC != 0 && E2E_FAIL == 0 )); then bad "主流程返回 $BC_RC 却没有记下失败项 —— 按失败处理"; fi
e2e_summary
