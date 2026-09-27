#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 ③: **已安装桥接 → 退役候选**, 走本 job 里 ② 刚装上的现役桥接 CLI:
#     bash /usr/local/bin/pdg update --to <退役候选的合成 tag>
#
# 前像从哪来: **同一 job、同一 runner** 上, 上一步原样跑完的 tests/e2e-real-bridge-hop.sh(②)。
# 本支不自己造桥接现场、不拷桥接文件冒充升级、不读别的运行的日志; 起跑前把桥接前像逐项现查一遍,
# 任一不成立就停在调用之前(调用计数保持 0)。
# DNS 仪器(317): 夹具前像是 all 劫持形态, WLOC 接管与普通 all 模式代理劫持对 A 查询答同一个地址, 光看答案分不出路径。
# 所以在桥接身份门之后、运行态门之前, 本支对 ② 现场做且只做下列仪器调整(前后原文与差异进证据目录 05-dns-*):
# 起自有上游(tests/helpers/dns-stub.py, 固定答 U)只接 local_upstream 一行; geosite_cn 末尾追加见证 / 标定 / 分阶段对照名;
# 标定时临时往接管表加一条标定名、随后按内容与属性还原并核验。劫持模式、规则顺序、其它规则不动。
# 因此 ③ 的前像 = ② 的真实现场 + 上述仪器调整; 本支不再声称现场未经调整。仪器重启单独登记, 不混入升级服务窗口。
#
# 这一跳验的是: 目标确实到达(退役候选)、WLOC 位置改写及其专属 MITM 执行能力按产品规则撤除、
# 该保留的用户数据 / 身份 / 凭据原样、允许迁移的记录按产品规则迁移、服务动作都点得出来源、
# 真实功能仍在。判据全部**事先**从冻结产品推导(见 309 证据 plan/plan.txt), 不拿运行时看到的动作补清单。
#
# 快照、服务前像、锁、能力句柄全部由产品自己产生(桥接 cmd_update → cmd_snapshot →
# PDG_UPDATE_SVCSTATE → 新 CLI __migrate)。本支**不**设 PDG_UPDATE_SVCSTATE、不预装候选、不绕退役门。
#
# 观测有效性: 每一次读取都先看它自己的退出码与格式, 读失败 / 半截输出**不消费**, 也不当成"零"或"原样";
# 调用前必须取得的观测(记录、指纹、快照清单、服务采样、journal 起界桩)任一没取到就不调用。
# 退出码按来源命名: 包装器(timeout)返回码、timeout 自己的发信号记录、产品原始退出码(内层单独写出)分开取、分开说。
#
# 不覆盖: ④ 晚期失败恢复、v1.7.8、完整旧安装器、官方分发来源、发布。
# 前提缺一即硬停, 不 SKIP、不退回桩; 只许在一次性 GitHub runner 上跑。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

EVID="${PDG_RETIRE_HOP_EVID:-/tmp/real-acceptance-evidence-retire}"
R3_COUNT="$EVID/00-retire-invoke-count.txt"
# >>> PDG-EXTRACT-BEGIN r3_count
# 调用计数只认本阶段的明确状态: 初始化 / 读取 / 写入任一失败都具名返回 2, 不拿 0 兜底。
# 读取器约定(本支通用): 成功 ⇒ 返回 0、值放 R3_VAL; 失败 ⇒ 非 0、原因放 R3_WHY。
# 不用 $( ) 取值 —— 子壳里置的 R3_WHY 回不到调用方, 原因会丢。
r3_count_read(){   # → 0 取得(R3_VAL=非负整数) / 2 读不了或不是非负整数
  local v rc; R3_VAL=""
  v="$(cat -- "$R3_COUNT" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="调用计数读不了($R3_COUNT, cat rc=$rc)"; return 2; }
  [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]] || { R3_WHY="调用计数不是非负整数(实得 [${v:0:40}])"; return 2; }
  R3_VAL="$v"
}
r3_count_write(){   # $1=新值 → 写入并读回核对; 0 成立 / 2 写不进或读回不符
  { printf '%s\n' "$1" > "$R3_COUNT"; } 2>/dev/null || { R3_WHY="调用计数写不进($R3_COUNT)"; return 2; }
  r3_count_read || return 2
  [[ "$R3_VAL" == "$1" ]] || { R3_WHY="调用计数写入 $1 后读回 [$R3_VAL]"; return 2; }
}
r3_count_init(){ r3_count_write 0; }
r3_count_bump(){ local c; r3_count_read || return 2; c="$R3_VAL"; r3_count_write "$((c + 1))"; }
# <<< PDG-EXTRACT-END r3_count
{ mkdir -p "$EVID" && chmod 700 "$EVID"; } 2>/dev/null \
  || { echo "[HARD-STOP] 证据目录 $EVID 建不出来 —— 调用计数无处可落, 不调用" >&2; exit 1; }
r3_count_init || { echo "[HARD-STOP] 调用计数初始化失败: $R3_WHY —— 不调用" >&2; exit 1; }   # 任何门之前先落 0 并读回

_hard(){ echo "[HARD-STOP] $1" >&2
  if r3_count_read; then echo "升级调用次数(计数文件) = $R3_VAL" >&2; else echo "升级调用次数: 计数读不出来($R3_WHY)" >&2; fi
  exit 1; }
[[ "${PDG_REAL_MIGRATION_OK:-}" == 1 ]] || _hard "缺 PDG_REAL_MIGRATION_OK=1 —— 这支会真的改本机 systemd 与 /etc。"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || _hard "不在 GitHub Actions 里 —— 拒绝在开发机/生产机上执行。"
[[ "${RUNNER_OS:-}" == "Linux" ]] || _hard "RUNNER_OS=${RUNNER_OS:-<空>}, 只支持 Linux runner。"
[[ "$(id -u)" == 0 ]] || _hard "需要 root。"
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || _hard "需要 PDG_E2E_ISOLATED=1。"

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
R3_TMP="$(mktemp -d "${TMPDIR:-/tmp}/r3.XXXXXX")" || _hard "建不出本支临时目录"
E2E_TMP="$R3_TMP"                           # 被抽取的函数按 $E2E_TMP 落临时物 —— 落在本支自己的目录, 不碰 ② 的现场
export E2E_TMP

# ── 复用 ② 与 platform-fail 里已验证的函数: 只按唯一成对标记抽, 不 source 整支 ──────────
# ② 自己的抽取器也在 ② 里按标记登记; 先用同样的规矩把它取出来, 再用它取其余。
HOP2_SRC="$E2E_ROOT/tests/e2e-real-bridge-hop.sh"
PLAT_SRC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
# >>> PDG-EXTRACT-BEGIN r3_bootstrap
r3_bootstrap(){   # $1=来源 $2=落点 $3..=名字 → 只认唯一成对标记, 片段与组合各自 bash -n
  local src="$1" out="$2" n b e; shift 2
  [[ -f "$src" ]] || { echo "引导: 找不到 $src" >&2; return 2; }
  : > "$out" || return 2
  for n in "$@"; do
    [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] \
      || { echo "引导: $n 的标记不是唯一成对" >&2; return 1; }
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
    e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
    (( e - b >= 2 )) || { echo "引导: $n 的标记之间是空的" >&2; return 1; }
    sed -n "$((b+1)),$((e-1))p" "$src" >> "$out"
  done
  bash -n "$out" || { echo "引导: 组合后语法不过" >&2; return 1; }
}
# <<< PDG-EXTRACT-END r3_bootstrap
r3_bootstrap "$HOP2_SRC" "$R3_TMP/extractor.sh" extract_marked_fns extract_marked_decls \
  || _hard "抽取器引导失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$R3_TMP/extractor.sh"
extract_marked_fns "$PLAT_SRC" "$R3_TMP/plat-fns.sh" _ev _evn SECT note sc_get sc_state nrun snap_state \
    wait_stable unit_identify _unit_wants_mainpid svc_stable_window svc_stable_assert mitm_listen_verdict \
    _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after _j_interval \
  || _hard "platform-fail 函数抽取没通过 —— 还没碰任何服务"
extract_marked_decls "$PLAT_SRC" "$R3_TMP/plat-deps.sh" E2E_OWNED_UNITS SVC_WATCH \
  || _hard "platform-fail 依赖抽取没通过"
extract_marked_fns "$HOP2_SRC" "$R3_TMP/hop2-fns.sh" bridge_svc_sample bridge_row_valid \
  || _hard "② 函数抽取没通过"
# shellcheck source=/dev/null
source "$R3_TMP/plat-fns.sh"; source "$R3_TMP/plat-deps.sh"; source "$R3_TMP/hop2-fns.sh"
# shellcheck disable=SC2034
JBOUND_TAG="pdg-e2e-jbound-r3"
# shellcheck disable=SC2034
J_ERR=""
E2E_NOTRUN=0

# ── 本支自己的判据函数(契约测试按标记抽出来用受控输入驱动) ─────────────────────────
# >>> PDG-EXTRACT-BEGIN r3_read
# 读取器: 成功 ⇒ 0 且值在 R3_VAL; 失败 ⇒ 非 0 且原因在 R3_WHY。失败时 R3_VAL 一律清空, 调用方不得消费。
r3_grepq(){   # grep -q 的包装 → 0 命中 / 1 没有(答案) / 2 grep 自己出错(观测无效)
  grep -q "$@" 2>/dev/null; local rc=$?
  case "$rc" in 0|1) return "$rc";; *) R3_WHY="grep 出错(rc=$rc; 参数 ${*:1:2})"; return 2;; esac
}
r3_head(){   # $1=仓库 → 40 位提交
  local v rc; R3_VAL=""
  v="$(git -C "$1" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ ! "$v" =~ ^[0-9a-f]{40}$ ]]; then R3_WHY="读不出 $1 的 HEAD(rc=$rc, 实得 [${v:0:48}])"; return 2; fi
  R3_VAL="$v"
}
r3_fsha(){   # $1=文件 → 64 位 sha256; 读失败或半截 ⇒ 2
  local v rc; R3_VAL=""
  v="$(sha256sum -- "$1" 2>/dev/null)"; rc=$?; v="${v%% *}"
  if (( rc != 0 )) || [[ ! "$v" =~ ^[0-9a-f]{64}$ ]]; then R3_WHY="算不出 $1 的摘要(rc=$rc, 实得 [${v:0:70}])"; return 2; fi
  R3_VAL="$v"
}
r3_objsha(){   # $1=对象库 $2=提交 $3=路径 → 对象内文件的 sha256; 取不到 ⇒ 2
  local v rc; R3_VAL=""
  v="$(git -C "$1" show "$2:$3" 2>/dev/null | sha256sum 2>/dev/null)"; rc=$?; v="${v%% *}"
  if (( rc != 0 )) || [[ ! "$v" =~ ^[0-9a-f]{64}$ ]]; then R3_WHY="取不到对象 ${2:0:12}:$3 的摘要(rc=$rc)"; return 2; fi
  R3_VAL="$v"
}
r3_tagsha(){   # $1=仓库 $2=tag → 0 取得(R3_VAL=40 位) / 1 tag 不存在(答案) / 2 查询失败(观测无效)
  local v rc; R3_VAL=""
  v="$(git -C "$1" rev-parse -q --verify "refs/tags/$2^{commit}" 2>/dev/null)"; rc=$?
  if (( rc == 0 )) && [[ "$v" =~ ^[0-9a-f]{40}$ ]]; then R3_VAL="$v"; return 0; fi
  if (( rc == 1 )) && [[ -z "$v" ]]; then R3_WHY="$1 里没有 tag $2"; return 1; fi
  R3_WHY="$1 里 tag $2 查询失败(rc=$rc, 实得 [${v:0:48}])"; return 2
}
r3_modules(){   # $1=源码树 $2=已安装目录 → R3_VAL="总数 不符数"; 清单取不到或比对出错 ⇒ 2
  local src name _mode n=0 badn=0 list rc
  R3_VAL=""
  list="$( ( source "$1/lib/modules.sh" && pdg_platform_modules ios ) 2>/dev/null )"; rc=$?
  if (( rc != 0 )) || [[ -z "$list" ]]; then R3_WHY="$1 的 ios 模块清单取不到(rc=$rc)"; return 2; fi
  while read -r src name _mode; do
    [[ -n "$name" ]] || continue; n=$((n+1))
    cmp -s -- "$1/$src" "$2/$name"; rc=$?
    case "$rc" in
      0) ;;
      1) badn=$((badn+1));;
      *) if [[ -e "$1/$src" && ! -e "$2/$name" ]]; then badn=$((badn+1))    # 已安装的那份不在 = 不符(答案)
         else R3_WHY="比对 $src 出错(cmp rc=$rc)"; return 2; fi;;
    esac
  done <<<"$list"
  R3_VAL="$n $badn"
}
r3_keepfp(){   # $1=文件 → 0 取得(R3_VAL="sha256 mode uid:gid") / 3 不存在(答案) / 2 观测无效; 摘要与元数据各自核退出码与格式
  local f="$1" s m rc
  R3_VAL=""
  if [[ ! -e "$f" && ! -L "$f" ]]; then
    [[ -d "$(dirname -- "$f")" && ! -x "$(dirname -- "$f")" ]] && { R3_WHY="$f 的上级目录不可进入, 存在性判不了"; return 2; }
    R3_WHY="$f 不存在"; return 3
  fi
  r3_fsha "$f" || { R3_WHY="保留项摘要没取得: $R3_WHY"; return 2; }; s="$R3_VAL"; R3_VAL=""
  m="$(stat -c '%a %u:%g' -- "$f" 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ ! "$m" =~ ^[0-7]{3,4}\ [0-9]+:[0-9]+$ ]]; then
    R3_WHY="保留项元数据没取得: $f(stat rc=$rc, 实得 [${m:0:40}])"; return 2
  fi
  R3_VAL="$s $m"
}
r3_listen_count(){   # $1=端口 → 0 取得(R3_VAL=本地监听条数, 可为 0) / 2 ss 失败或输出不像 ss(不当成零监听)
  local out rc n; R3_VAL=""
  out="$(ss -lnt 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="ss -lnt 失败(rc=$rc) —— 不当成零监听"; return 2; }
  [[ "${out%%$'\n'*}" =~ ^State[[:space:]] ]] || { R3_WHY="ss -lnt 的输出没有表头(首行 [${out:0:40}]) —— 不当成零监听"; return 2; }
  n="$(awk -v p=":$1" 'NR > 1 && length($4) > length(p) && substr($4, length($4) - length(p) + 1) == p { c++ } END { print c + 0 }' <<<"$out")"; rc=$?
  if (( rc != 0 )) || [[ ! "$n" =~ ^[0-9]+$ ]]; then R3_WHY="监听条数解析失败(awk rc=$rc, 实得 [${n:0:20}])"; return 2; fi
  R3_VAL="$n"
}
r3_lsdir(){   # $1=目录 → 0 取得(R3_VAL=按 C 序排好的条目, 可为空; 目录不存在时写明在 R3_NOTE) / 2 观测无效
  local out rc; R3_VAL=""; R3_NOTE=""
  if [[ ! -e "$1" && ! -L "$1" ]]; then R3_NOTE="$1 不存在, 按空清单"; return 0; fi
  [[ -d "$1" ]] || { R3_WHY="$1 在但不是目录"; return 2; }
  out="$(ls -1A -- "$1" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="列不出 $1(ls rc=$rc)"; return 2; }
  out="$(LC_ALL=C sort <<<"$out")"; rc=$?
  (( rc == 0 )) || { R3_WHY="$1 的清单排序失败(sort rc=$rc)"; return 2; }
  R3_VAL="$out"
}
r3_snapdiff(){   # $1=前清单 $2=后清单 → 0 取得(R3_VAL=新增条目) / 2 comm 或整理失败(它的输出不消费)
  local out rc; R3_VAL=""
  out="$(LC_ALL=C comm --check-order -13 <(printf '%s\n' "$1") <(printf '%s\n' "$2") 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="快照差集 comm 失败(rc=$rc) —— 它的输出不消费"; return 2; }
  out="$(grep -v '^$' <<<"$out")"; rc=$?
  (( rc <= 1 )) || { R3_WHY="快照差集整理失败(grep rc=$rc)"; return 2; }
  R3_VAL="$out"
}
r3_copy_record(){   # $1=源 $2=落点 → 0 调用前记录已留(逐字节核过) / 2 没取得
  { cp -p -- "$1" "$2"; } 2>/dev/null || { R3_WHY="调用前记录 $1 复制失败"; return 2; }
  cmp -s -- "$1" "$2"; local rc=$?
  (( rc == 0 )) || { R3_WHY="调用前记录 $1 的副本与原件不一致(cmp rc=$rc)"; return 2; }
}
r3_prod_rc(){   # 读 R3_RCFILE(包装器内层单独写出的产品原始退出码) → 0 取得 / 3 没写出(答案: 内层没走到那一步) / 2 观测无效
  local v rc; R3_VAL=""
  [[ -e "$R3_RCFILE" ]] || { R3_WHY="产品退出码文件不存在($R3_RCFILE)"; return 3; }
  v="$(cat -- "$R3_RCFILE" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="产品退出码文件读不了(cat rc=$rc)"; return 2; }
  [[ -n "$v" ]] || { R3_WHY="产品退出码文件为空(内层没走到写退出码那一步)"; return 3; }
  [[ "$v" =~ ^(0|[1-9][0-9]{0,2})$ ]] || { R3_WHY="产品退出码文件内容不是退出码(实得 [${v:0:40}])"; return 2; }
  R3_VAL="$v"
}
r3_timeout_sig(){   # 读 R3_TOERR(timeout --verbose 自己的 stderr) → 0 有发信号记录(R3_VAL=那一行) / 1 没有 / 2 观测无效
  local v rc; R3_VAL=""
  v="$(cat -- "$R3_TOERR" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="timeout 的 stderr 留档读不了($R3_TOERR, cat rc=$rc)"; return 2; }
  v="$(grep -m1 -E '^timeout: sending signal [A-Z0-9]+ to command' <<<"$v")"; rc=$?
  case "$rc" in
    0) R3_VAL="$v"; return 0;;
    1) return 1;;
    *) R3_WHY="解析 timeout 的 stderr 失败(grep rc=$rc)"; return 2;;
  esac
}
r3_set_check(){   # $1=采样文件 $2=标签 $3=关联数组名(按 unit 填整行) → 0 集合有效 / 1 集合不对 / 2 读取失败; 原因在 R3_WHY
                  # 名称、唯一性、完整性都核; 整份先读出并核退出码, 再在 bash 里解析 —— 没有生产者管道, 先输出后失败的内容不用
  local f="$1" lbl="$2" raw rc l u w inw why=""
  local -n _rows="$3"
  _rows=()
  raw="$(cat -- "$f" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="$lbl: 采样文件读取失败($f, cat rc=$rc) —— 已输出的部分也不当集合"; return 2; }
  while IFS= read -r l; do
    [[ -n "$l" ]] || { why="$why 有空行;"; continue; }
    u="${l%%$'\t'*}"
    [[ -n "$u" && "$u" != "$l" ]] || { why="$why 行首没有制表分隔的 unit 名([${l:0:30}]);"; continue; }
    inw=0; for w in "${SVC_WATCH[@]}"; do [[ "$w" == "$u" ]] && inw=1; done
    (( inw )) || { why="$why 清单外的服务 [$u];"; continue; }
    [[ -z "${_rows[$u]+x}" ]] || { why="$why 重复的服务行 [$u];"; continue; }
    _rows[$u]="$l"
  done <<<"$raw"
  for w in "${SVC_WATCH[@]}"; do [[ -n "${_rows[$w]+x}" ]] || why="$why 缺服务 [$w];"; done
  [[ -z "$why" ]] || { R3_WHY="$lbl:$why"; return 1; }
  return 0
}
r3_http_code(){   # $1=URL → 0 取得(R3_VAL=三位状态码) / 2 命令失败或输出无效(失败命令的输出不采信); 业务条件由调用方判
  local out rc; R3_VAL=""
  out="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="命令失败: curl 退出 $rc(它打印的 [${out:0:20}] 不采信)"; return 2; }
  [[ "$out" =~ ^[1-5][0-9][0-9]$ ]] || { R3_WHY="输出无效: curl 退出 0 但打印的不是 HTTP 状态码([${out:0:20}])"; return 2; }
  R3_VAL="$out"
}
r3_unit_q(){   # $1=active|enabled|load $2=unit [$3=同一 unit 已有效取得的 LoadState, 只对 active 有意义] → 0 取得(R3_VAL=状态词) / 2 观测无效(R3_WHY)
               # 完整输出必须恰一行; 状态词与原始退出码必须成对(依据: systemctl(1) is-enabled 表; is-active 非运行态退出 3);
               # 正常的"不在运行 / 不存在"本来就用非零码, 不一律判失败。load 查询失败时输出一律不采信。
  local k="$1" u="$2" out rc err ef="${R3_TMP:?}/unitq.err"; R3_VAL=""
  case "$k" in
    active)  out="$(systemctl is-active "$u" 2>"$ef")"; rc=$?;;
    enabled) out="$(systemctl is-enabled "$u" 2>"$ef")"; rc=$?;;
    load)    out="$(systemctl show -p LoadState --value "$u" 2>"$ef")"; rc=$?;;
    *) R3_WHY="r3_unit_q 不认识的查询 [$k]"; return 2;;
  esac
  err="$(tr '\n' ' ' < "$ef" 2>/dev/null)"
  [[ "$out" != *$'\n'* ]] || { R3_WHY="$u 的 $k 查询输出不止一行([${out//$'\n'/|}], rc=$rc)"; return 2; }
  case "$k" in
    active)
      case "$out" in
        active|reloading|refreshing) (( rc == 0 )) || { R3_WHY="$u is-active 打印 $out 却退出 $rc(应为 0)"; return 2; };;
        inactive) # systemd 252: 非运行态一律 3; systemd 255: 该 unit LoadState=not-found 时改用 LSB 4(见 systemctl-is-active.c)
          (( rc == 3 )) || { (( rc == 4 )) && [[ "${3:-}" == not-found ]]; } \
            || { R3_WHY="$u is-active 打印 inactive 却退出 $rc(应为 3); 只有已取得 LoadState=not-found 时才可为 4(实得 LoadState=[${3:-未提供}])"; return 2; };;
        failed|activating|deactivating|maintenance) (( rc == 3 )) || { R3_WHY="$u is-active 打印 $out 却退出 $rc(应为 3)"; return 2; };;
        *) R3_WHY="$u is-active 输出不是状态词([${out:0:30}], rc=$rc, stderr: ${err:-无})"; return 2;;
      esac;;
    enabled)
      case "$out" in
        enabled|enabled-runtime|alias|static|indirect|generated|transient) (( rc == 0 )) || { R3_WHY="$u is-enabled 打印 $out 却退出 $rc(应为 0)"; return 2; };;
        linked|linked-runtime|masked|masked-runtime|disabled|not-found) (( rc != 0 )) || { R3_WHY="$u is-enabled 打印 $out 却退出 0(应非零)"; return 2; };;
        "") if (( rc != 0 )) && [[ "$err" == *"No such file or directory"* ]]; then out=not-found     # systemd 252 对不存在的 unit 只在 stderr 报这句
            else R3_WHY="$u is-enabled 没有输出(rc=$rc, stderr: ${err:-无})"; return 2; fi;;
        *) R3_WHY="$u is-enabled 输出不是状态词([${out:0:30}], rc=$rc, stderr: ${err:-无})"; return 2;;
      esac;;
    load)
      (( rc == 0 )) || { R3_WHY="$u 的 LoadState 查询退出 $rc(输出 [${out:0:30}] 不采信)"; return 2; }
      case "$out" in loaded|not-found|bad-setting|error|masked|merged|stub) ;;
        *) R3_WHY="$u 的 LoadState 不是状态词([${out:0:30}])"; return 2;; esac;;
  esac
  R3_VAL="$out"
}
# <<< PDG-EXTRACT-END r3_read
# >>> PDG-EXTRACT-BEGIN r3_real2_gate
r3_real2_gate(){   # $1=② 的输出留档 → 0 通过 / 1 不通过 / 2 读不了或查询失败; 原因在 R3_WHY
  local f="$1" raw rc nr m sumline np nf last
  R3_WHY=""
  [[ -n "$f" ]] || { R3_WHY="没给 ② 的输出留档路径"; return 2; }
  raw="$(cat -- "$f" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="② 的输出留档读不了($f, rc=$rc)"; return 2; }
  nr="$(grep -cE '^未执行\(前像/前置不成立而跳过\)的场景数: ' <<<"$raw")"; rc=$?
  if (( rc > 1 )) || [[ ! "$nr" =~ ^[0-9]+$ ]]; then R3_WHY="② 的「未执行场景数」行查询失败(grep rc=$rc, 实得 [${nr:0:20}]) —— 观测无效"; return 2; fi
  [[ "$nr" == 1 ]] || { R3_WHY="② 的「未执行场景数」行有 $nr 行(应恰 1 行) —— ② 没跑到收尾或输出不完整"; return 1; }
  r3_grepq -xE '未执行\(前像/前置不成立而跳过\)的场景数: 0' <<<"$raw"; rc=$?
  case "$rc" in
    0) ;;
    1) R3_WHY="② 有未执行场景($(grep -E '^未执行' <<<"$raw"))"; return 1;;
    *) R3_WHY="② 的未执行场景数查询失败: $R3_WHY —— 观测无效"; return 2;;
  esac
  r3_grepq -E '^\[(FAIL|HARD-STOP)\]' <<<"$raw"; rc=$?
  case "$rc" in
    0) R3_WHY="② 的输出里有 [FAIL] / [HARD-STOP] 行"; return 1;;
    1) ;;
    *) R3_WHY="② 的失败行查询失败: $R3_WHY —— 观测无效"; return 2;;
  esac
  m="$(grep -E '^通过 [0-9]+, 失败 [0-9]+$' <<<"$raw")"; rc=$?
  case "$rc" in
    0) sumline="${m##*$'\n'}";;
    1) R3_WHY="② 的汇总行找不到"; return 1;;
    *) R3_WHY="② 的汇总行查询失败(grep rc=$rc) —— 观测无效"; return 2;;
  esac
  m="$(grep -v '^[[:space:]]*$' <<<"$raw")"; rc=$?
  case "$rc" in
    0) last="${m##*$'\n'}";;
    1) last="";;
    *) R3_WHY="② 的末行查询失败(grep rc=$rc) —— 观测无效"; return 2;;
  esac
  [[ "$last" == "$sumline" ]] || { R3_WHY="② 的汇总不是最后一行(最后一行: ${last:0:80}) —— 输出可能被截断"; return 1; }
  np="${sumline#通过 }"; np="${np%%,*}"; nf="${sumline##*失败 }"
  [[ "$nf" == 0 ]] || { R3_WHY="② 汇总失败 $nf"; return 1; }
  (( np > 0 )) || { R3_WHY="② 汇总通过 0 —— 零断言"; return 1; }
  R3_WHY="② 汇总「$sumline」, 未执行场景 0"; return 0
}
# <<< PDG-EXTRACT-END r3_real2_gate
# >>> PDG-EXTRACT-BEGIN r3_bridge_identity_gate
r3_bridge_identity_gate(){   # 读 R3_REPO R3_CLI R3_OBJ R3_BRSRC R3_MODDIR R3_ETC BRIDGE_SHA RETIRE_SHA BRIDGE_TAG RETIRE_TAG
                             # → 0 全成立 / 1 有不成立 / 2 观测无效; 逐项打印; 成立时 R3_ORIGIN = 现役仓库的取件源
  local h st want got mods p o rc rc2 tg ts tn bad=0
  R3_ORIGIN=""
  r3_head "$R3_REPO" || { echo "  B1 观测无效: $R3_WHY"; return 2; }; h="$R3_VAL"
  [[ "$h" == "$BRIDGE_SHA" ]] && echo "  B1 现役 HEAD = 桥接 ${h:0:12}" || { echo "  B1 现役 HEAD=$h, 不是桥接 $BRIDGE_SHA"; bad=1; }
  st="$(git -C "$R3_REPO" status --porcelain 2>/dev/null)" || { echo "  B1 观测无效: 工作区状态查不出来"; return 2; }
  [[ -z "$st" ]] && echo "  B1 现役仓库工作区干净" || { echo "  B1 现役仓库工作区不干净: $(head -3 <<<"$st" | tr '\n' ';')"; bad=1; }
  r3_objsha "$R3_OBJ" "$BRIDGE_SHA" deploy/bot/pdg.sh || { echo "  B2 观测无效: $R3_WHY"; return 2; }; want="$R3_VAL"
  r3_fsha "$R3_CLI" || { echo "  B2 观测无效: $R3_WHY"; return 2; }; got="$R3_VAL"
  [[ "$got" == "$want" ]] && echo "  B2 现役 CLI 逐字节 = 桥接 pdg.sh(${got:0:12})" || { echo "  B2 现役 CLI(${got:0:12}) ≠ 桥接 pdg.sh(${want:0:12})"; bad=1; }
  r3_grepq '^_pdg_save_svcstate(){' "$R3_CLI"; rc=$?
  r3_grepq '^_pdg_restore_svcstate(){' "$R3_CLI"; rc2=$?
  (( rc <= 1 && rc2 <= 1 )) || { echo "  B3 观测无效: $R3_WHY"; return 2; }
  if (( rc == 0 && rc2 == 0 )); then echo "  B3 CLI 带前像能力"; else echo "  B3 CLI 没有前像能力 —— 不是桥接版"; bad=1; fi
  r3_grepq '^migrate_wloc_retire(){' "$R3_CLI"; rc=$?
  case "$rc" in
    0) echo "  B3 CLI 已含退役实现 —— 退役版被提前装上了"; bad=1;;
    1) echo "  B3 CLI 不含退役实现";;
    *) echo "  B3 观测无效: $R3_WHY"; return 2;;
  esac
  r3_modules "$R3_BRSRC" "$R3_MODDIR" || { echo "  B4 观测无效: $R3_WHY"; return 2; }; mods="$R3_VAL"
  [[ "${mods#* }" == 0 ]] && echo "  B4 ios 模块 ${mods% *} 项逐字节 = 桥接树" || { echo "  B4 ios 模块 ${mods% *} 项里 ${mods#* } 项与桥接树不同"; bad=1; }
  p="$(cat -- "$R3_ETC/platform" 2>/dev/null)" || { echo "  B5 观测无效: 平台标记读不了"; return 2; }
  [[ "$p" == ios ]] && echo "  B5 平台标记 = ios" || { echo "  B5 平台标记 = [$p], 不是 ios"; bad=1; }
  o="$(git -C "$R3_REPO" remote get-url origin 2>/dev/null)" || { echo "  B8 观测无效: 现役仓库 origin 读不出来"; return 2; }
  if [[ "$o" != /* || ! -d "$o" ]]; then echo "  B8 现役仓库 origin=[$o] 不是本机裸库目录"; bad=1
  else
    for tg in "$RETIRE_TAG|$RETIRE_SHA|退役" "$BRIDGE_TAG|$BRIDGE_SHA|桥接"; do
      ts="${tg#*|}"; tn="${ts#*|}"; ts="${ts%%|*}"; tg="${tg%%|*}"
      r3_tagsha "$o" "$tg"; rc=$?
      case "$rc" in
        0) if [[ "$R3_VAL" == "$ts" ]]; then echo "  B8 取件源 $o 里 $tg → ${R3_VAL:0:12}"
           else echo "  B8 取件源里 $tg → $R3_VAL, 不是$tn $ts"; bad=1; fi;;
        1) echo "  B8 取件源里没有 $tg(查询成功, 答案是不存在), 不是$tn $ts"; bad=1;;
        *) echo "  B8 观测无效: $R3_WHY"; return 2;;
      esac
    done
    R3_ORIGIN="$o"
  fi
  return "$bad"
}
# <<< PDG-EXTRACT-END r3_bridge_identity_gate
# >>> PDG-EXTRACT-BEGIN r3_keep
# 保留项: 必需项(309 plan K1/K2)调用前必须在, 进场缺失就是前像不对, 不许静默移出比较集合;
# 可选项(309 plan K2: 若调用前在则原样)调用前不在时显式登记为 ABSENT, 不作原样判定。
r3_keep_capture(){   # 读 KREQ KOPT → 填 KFP[文件]; 0 全取得 / 1 有必需项进场缺失或任一项观测无效(逐项打印)
  local f rc st=0
  declare -gA KFP=()
  for f in "${KREQ[@]}"; do
    r3_keepfp "$f"; rc=$?
    case "$rc" in
      0) KFP["$f"]="$R3_VAL"; echo "  E 必需保留项 $f 调用前指纹已取得";;
      3) echo "  E 必需保留项 $f 调用前就不存在 —— 前像不对, 不能把它移出比较集合"; st=1;;
      *) echo "  E 必需保留项观测无效: $R3_WHY"; st=1;;
    esac
  done
  for f in "${KOPT[@]}"; do
    r3_keepfp "$f"; rc=$?
    case "$rc" in
      0) KFP["$f"]="$R3_VAL"; echo "  E 可选保留项 $f 调用前在, 调用后须原样";;
      3) KFP["$f"]=ABSENT; echo "  E 可选保留项 $f 调用前不在(显式登记; 按 309 plan K2 只在调用前在时核原样)";;
      *) echo "  E 可选保留项观测无效: $R3_WHY"; st=1;;
    esac
  done
  return "$st"
}
r3_keep_verdict(){   # 调用后逐项比对 → 0 全原样 / 1 有被改或被删 / 2 有观测无效(不当成原样)
  local f rc st=0
  for f in "${KREQ[@]}" "${KOPT[@]}"; do
    if [[ -z "${KFP[$f]:-}" ]]; then bad "③-3 K 观测无效: $f 没有调用前指纹记录 —— 不能判原样"; st=2; continue; fi
    r3_keepfp "$f"; rc=$?
    if [[ "${KFP[$f]}" == ABSENT ]]; then
      case "$rc" in
        3) note "③-3 K 可选保留项 $f 调用前后都不在(不作原样判定)";;
        0) note "③-3 K 可选保留项 $f 调用前不在、调用后出现(按 309 plan K2 不作原样判定, 只登记)";;
        *) bad "③-3 K 观测无效: $R3_WHY"; st=2;;
      esac
      continue
    fi
    case "$rc" in
      0) if [[ "$R3_VAL" == "${KFP[$f]}" ]]; then ok "③-3 K 保留: $f 内容 / mode / uid:gid 原样"
         else bad "③-3 K 保留项被改: $f(前 [${KFP[$f]:0:16}… ${KFP[$f]#* }] 后 [${R3_VAL:0:16}… ${R3_VAL#* }])"; (( st )) || st=1; fi;;
      3) bad "③-3 K 保留项被删: $f"; (( st )) || st=1;;
      *) bad "③-3 K 观测无效: $R3_WHY —— 不当成原样"; st=2;;
    esac
  done
  return "$st"
}
# <<< PDG-EXTRACT-END r3_keep
# >>> PDG-EXTRACT-BEGIN r3_precapture
r3_rows_valid(){   # $1=关联数组名(r3_set_check 填好的行) → 0 每行有效 / 1 有无效行(R3_WHY 列出)
  local u why=""
  local -n _vr="$1"
  (( ${#_vr[@]} > 0 )) || { R3_WHY="采样里一行都没有"; return 1; }
  for u in "${SVC_WATCH[@]}"; do bridge_row_valid "${_vr[$u]}" || why="$why $u($OBS_WHY);"; done
  [[ -z "$why" ]] || { R3_WHY="${why# }"; return 1; }
}
r3_precapture(){   # 调用前必须取得的观测, 逐项打印; 任一没取到 ⇒ 1(调用方据此**不调用**); 本阶段自己的状态, 不看累计失败数
  local st=0 rc
  if r3_copy_record "$IOS_META" "$R3_TMP/ios-before.json"; then echo "  E iOS 记录原文已留(逐字节核过)"
  else echo "  E 没取得: $R3_WHY"; st=1; fi
  if r3_copy_record "$MJ" "$R3_TMP/mitm-before.json"; then echo "  E mitm.json 原文已留(逐字节核过)"
  else echo "  E 没取得: $R3_WHY"; st=1; fi
  r3_keep_capture || st=1
  SNAP_BEFORE=""
  if r3_lsdir "$SNAPROOT"; then SNAP_BEFORE="$R3_VAL"; echo "  E 快照目录清单已取得(${R3_NOTE:-$(grep -c . <<<"$SNAP_BEFORE") 项})"
  else echo "  E 快照目录清单没取得: $R3_WHY"; st=1; fi
  if bridge_svc_sample "$R3_TMP/svc-retire-before.tsv"; then
    # shellcheck disable=SC2034  # 经 nameref 由 r3_set_check 填、r3_rows_valid 读
    declare -gA R3_ROWS_BEFORE=()
    r3_set_check "$R3_TMP/svc-retire-before.tsv" 调用前 R3_ROWS_BEFORE; rc=$?
    if (( rc == 2 )); then echo "  E 服务观测无效: $R3_WHY"; st=1
    elif (( rc != 0 )); then echo "  E 服务观测不全: $R3_WHY"; st=1
    elif ! r3_rows_valid R3_ROWS_BEFORE; then echo "  E 调用前服务采样有无效行: $R3_WHY"; st=1
    else echo "  E 调用前服务采样 ${#SVC_WATCH[@]} 项齐全且逐行有效"; fi
  else echo "  E 调用前服务采样写不出来"; st=1; fi
  # 起界桩放最后: 离调用越近, 窗口里混进别的动作的机会越少
  C3_0=""
  if C3_0="$(_j_mark retire-start)" && [[ -n "$C3_0" ]]; then echo "  E journal 起界桩已建"
  else C3_0=""; echo "  E journal 起界桩没建成($(_j_why)) —— 窗口无从谈起"; st=1; fi
  return "$st"
}
# <<< PDG-EXTRACT-END r3_precapture
# >>> PDG-EXTRACT-BEGIN r3_invoke
r3_invoke(){   # **唯一**升级入口 → 0 已调用(结果在 R3_WRAP_RC / R3_RCFILE / R3_TOERR) / 2 留档或计数不可用, **没有调用**
  # 包装器(timeout)返回码 ≠ 产品退出码: 产品原始退出码由内层 bash 在产品结束后单独写进 R3_RCFILE;
  # timeout --verbose 发信号时自己在 stderr 留一行, 落进 R3_TOERR —— 超时只认这一行, 不认 124 这个数。
  R3_WRAP_RC=""
  { : > "$R3_RCFILE" && : > "$R3_TOERR"; } 2>/dev/null || { R3_WHY="退出码留档准备不了($R3_RCFILE / $R3_TOERR)"; return 2; }
  r3_count_bump || return 2
  R3_WRAP_RC=0
  # shellcheck disable=SC2016  # 单引号是有意的: $1..$4 由内层 bash 展开
  env -u PDG_UPDATE_SVCSTATE -u PDG_TAG_BOOTSTRAPPED -u PDG_PLATFORM timeout --verbose "$R3_TIMEOUT" bash -c 'bash "$1" update --to "$2" </dev/null >"$3" 2>&1; printf "%s\n" "$?" >"$4"' r3wrap "$R3_CLI" "$RETIRE_TAG" "$R3_LOG" "$R3_RCFILE" 2>"$R3_TOERR" || R3_WRAP_RC=$?
  return 0
}
# <<< PDG-EXTRACT-END r3_invoke
# >>> PDG-EXTRACT-BEGIN r3_gated_invoke
r3_gated_invoke(){   # 门全过、调用前观测全部取得才调用。返回(10–15 都**没有**调用):
                     #   10=② 结果门 11=桥接身份门 15=DNS 仪器条件 / 标定 / 还原核验 12=运行态 / WLOC 前像门(含前阶段 DNS 路径)
                     #   13=调用前观测没取全 14=计数或退出码留档不可用; 0=已调用
  local g
  r3_real2_gate "$R3_REAL2_LOG"; g=$?
  echo "  R2 $R3_WHY"
  (( g == 0 )) || return 10
  r3_bridge_identity_gate; g=$?
  (( g == 0 )) || return 11
  r3_dns_instrument || return 15
  r3_runtime_gate || return 12
  r3_precapture || return 13
  r3_invoke || { echo "  调用前停止: $R3_WHY"; return 14; }
  return 0
}
# <<< PDG-EXTRACT-END r3_gated_invoke
# >>> PDG-EXTRACT-BEGIN r3_arrival_verdict
r3_arrival_verdict(){   # 读 R3_WRAP_RC R3_RCFILE R3_TOERR R3_LOG R3_REPO R3_CLI R3_OBJ RETIRE_SHA RETIRE_TAG
                        # 分别结算 R3_PROC(OK/FAIL/UNKNOWN) R3_ARRIVE(OK/FAIL/UNKNOWN) R3_OBS(VALID/INVALID); 三者全好才返回 0
  local log h want got rc sig=no logok=1 aunk=0
  R3_PROC=OK; R3_ARRIVE=OK; R3_OBS=VALID; R3_RC=""
  # ── 进程状态: 三个来源分开取、分开说 ──
  if [[ ! "${R3_WRAP_RC:-}" =~ ^[0-9]+$ ]]; then R3_OBS=INVALID; echo "  P0 观测无效: 没取到包装器(timeout)返回码"; fi
  r3_timeout_sig; rc=$?
  case "$rc" in
    0) sig=yes; R3_PROC=FAIL
       echo "  P0 timeout 自己留下了发信号记录「$R3_VAL」(包装器返回码 ${R3_WRAP_RC:-未取得}) —— 超时终止有直接记录";;
    1) if [[ "${R3_WRAP_RC:-}" =~ ^[0-9]+$ ]] && (( R3_WRAP_RC != 0 )); then
         R3_PROC=FAIL; echo "  P0 包装器(timeout)返回码 $R3_WRAP_RC 非零 —— 没有 timeout 的发信号记录, 不据此认定超时; 这也不是产品退出码"
       else echo "  P0 包装器(timeout)返回码 ${R3_WRAP_RC:-未取得}, 没有 timeout 的发信号记录"; fi;;
    *) R3_OBS=INVALID; echo "  P0 观测无效: $R3_WHY";;
  esac
  r3_prod_rc; rc=$?
  case "$rc" in
    0) R3_RC="$R3_VAL"
       if (( R3_RC != 0 )); then R3_PROC=FAIL; echo "  P1 产品原始退出码 $R3_RC(内层单独写出) —— 失败, 不看日志里写了什么"
       else echo "  P1 产品原始退出码 0(内层单独写出)"; fi;;
    3) if [[ "$sig" == yes ]]; then echo "  P1 产品原始退出码未取得: 进程被超时终止($R3_WHY) —— 不冒称"
       else R3_OBS=INVALID; [[ "$R3_PROC" == FAIL ]] || R3_PROC=UNKNOWN
            echo "  P1 观测无效: 产品原始退出码未取得($R3_WHY) —— 不拿包装器返回码冒充"; fi;;
    *) R3_OBS=INVALID; [[ "$R3_PROC" == FAIL ]] || R3_PROC=UNKNOWN; echo "  P1 观测无效: $R3_WHY";;
  esac
  # ── 目标到达: 读失败的项记"未取得", 不当成"没到达"也不当成"到达" ──
  log="$(cat -- "$R3_LOG" 2>/dev/null)" || { R3_OBS=INVALID; logok=0; echo "  观测无效: 升级日志读不了 —— A2 / A5 未取得"; }
  if (( logok )) && [[ -z "$log" ]]; then R3_OBS=INVALID; logok=0; echo "  观测无效: 升级日志为空 —— A2 / A5 未取得"; fi
  (( logok )) || aunk=1
  if r3_head "$R3_REPO"; then
    h="$R3_VAL"
    [[ "$h" == "$RETIRE_SHA" ]] && echo "  A1 现役 HEAD = 退役 ${h:0:12}" || { R3_ARRIVE=FAIL; echo "  A1 现役 HEAD=$h, 不是退役 $RETIRE_SHA —— 目标没到达"; }
  else R3_OBS=INVALID; aunk=1; echo "  A1 观测无效: $R3_WHY"; fi
  if (( logok )); then
    r3_grepq -F "钉版目标已贯穿到实际安装: $RETIRE_TAG → $RETIRE_SHA" <<<"$log"; rc=$?
    case "$rc" in 0) echo "  A2 产品的钉版贯穿门留痕";; 1) R3_ARRIVE=FAIL; echo "  A2 没有「钉版目标已贯穿到实际安装: $RETIRE_TAG → $RETIRE_SHA」";;
                  *) R3_OBS=INVALID; aunk=1; echo "  A2 观测无效: $R3_WHY";; esac
    r3_grepq -F "→ 已切到发布 $RETIRE_TAG($RETIRE_SHA)" <<<"$log"; rc=$?
    case "$rc" in 0) echo "  A2 日志写明切到指定发布";; 1) R3_ARRIVE=FAIL; echo "  A2 没有「→ 已切到发布 $RETIRE_TAG($RETIRE_SHA)」";;
                  *) R3_OBS=INVALID; aunk=1; echo "  A2 观测无效: $R3_WHY";; esac
  fi
  if r3_objsha "$R3_OBJ" "$RETIRE_SHA" deploy/bot/pdg.sh && want="$R3_VAL" && r3_fsha "$R3_CLI" && got="$R3_VAL"; then
    [[ "$got" == "$want" ]] && echo "  A3 现役 CLI 逐字节 = 退役 pdg.sh(${got:0:12})" || { R3_ARRIVE=FAIL; echo "  A3 现役 CLI(${got:0:12}) ≠ 退役 pdg.sh(${want:0:12})"; }
  else R3_OBS=INVALID; aunk=1; echo "  A3 观测无效: $R3_WHY"; fi
  r3_grepq '^migrate_wloc_retire(){' "$R3_CLI"; rc=$?
  case "$rc" in 0) echo "  A3 现役 CLI 含退役实现";; 1) R3_ARRIVE=FAIL; echo "  A3 现役 CLI 不含 migrate_wloc_retire";;
                *) R3_OBS=INVALID; aunk=1; echo "  A3 观测无效: $R3_WHY";; esac
  if (( logok )); then
    r3_grepq -F '✅ 已更新。' <<<"$log"; rc=$?
    case "$rc" in 0) echo "  A5 产品自报「✅ 已更新。」";; 1) R3_ARRIVE=FAIL; echo "  A5 没有「✅ 已更新。」";;
                  *) R3_OBS=INVALID; aunk=1; echo "  A5 观测无效: $R3_WHY";; esac
  fi
  [[ "$R3_ARRIVE" == OK ]] && (( aunk )) && R3_ARRIVE=UNKNOWN
  echo "  结算: 进程 $R3_PROC / 目标到达 $R3_ARRIVE / 观测 $R3_OBS"
  [[ "$R3_PROC" == OK && "$R3_ARRIVE" == OK && "$R3_OBS" == VALID ]]
}
# <<< PDG-EXTRACT-END r3_arrival_verdict
# >>> PDG-EXTRACT-BEGIN r3_svc_class
r3_win_policy(){   # $1=unit → "allow|来源" / "zero|理由"; 策略里没有 ⇒ 返回 1(按窗口观测无效处理, 不猜)
  case "$1" in
    pdg-mitm) printf 'allow|退役候选 migrate_deploy_botfiles 在 iOS 且模块有变化时 try-restart pdg-mitm, 排在 migrate_wloc_retire 之前';;
    mosdns|mihomo|pdg-probe81|pdg-bot|pdg-dotwitness|pdg-health.timer) printf 'allow|退役链成功路径上有重启 / 启用(来源见 r3_svc_class)';;
    sing-box|ssh|cron) printf 'zero|本现场退役链成功路径上不该启动它(309 plan S2)';;
    pdg-rescue.socket) printf 'zero|本现场退役链成功路径上不该启动它(309 plan S2); 注意 socket 激活在 journal 里记为 Listening on, 本计数口径看不到';;
    *) return 1;;
  esac
}
r3_svc_class(){   # $1=unit $2=前 $3=后 → "<类别>|<理由>"; 类别: 退役链必需 / 退役链正常 / 意外
  local u="$1" b="$2" a="$3" TAB; TAB="$(printf '\t')"
  local b_act a_act b_ufs a_ufs a_load rev=""
  b_act="$(cut -d"$TAB" -f6 <<<"$b")"; a_act="$(cut -d"$TAB" -f6 <<<"$a")"
  b_ufs="$(cut -d"$TAB" -f8 <<<"$b")"; a_ufs="$(cut -d"$TAB" -f8 <<<"$a")"
  a_load="$(cut -d"$TAB" -f5 <<<"$a")"
  [[ "$b_act" == active  && "$a_act" != active  ]] && rev="运行 $b_act→$a_act"
  [[ "$b_ufs" == enabled && "$a_ufs" != enabled ]] && rev="${rev:+$rev; }自启 $b_ufs→${a_ufs:-<空>}"
  case "$u" in
    pdg-mitm)
      if [[ "$a_load" == not-found && "$a_act" != active ]]; then
        printf '退役链必需|退役 migrate_wloc_retire: disable --now / stop pdg-mitm, 删 unit 后 daemon-reload(桥接 cmd_update 只在 is-enabled 时才重启它)'
      else
        printf '意外|pdg-mitm 退役后仍是 %s/%s —— 退役链要求停、禁并删 unit' "$a_load" "$a_act"
      fi;;
    mosdns|mihomo|pdg-probe81|pdg-bot|pdg-dotwitness|pdg-health.timer|pdg-health.service)
      if [[ -n "$rev" ]]; then
        printf '意外|%s 被停/禁(%s) —— 退役链成功路径上对它只有重启 / 启用' "$u" "$rev"
      else
        case "$u" in
          mosdns) printf '退役链正常|_retire_reload_svc mosdns(撤接管表); migrate_mosdns_* / migrate_dotwitness 等 restart mosdns';;
          mihomo) printf '退役链正常|退役重渲内核配置; migrate_ios_gms_cleanup / _core_restart_clean restart 内核 svc';;
          pdg-probe81) printf '退役链正常|桥接 cmd_update restart pdg-probe81; migrate_probe81_public enable --now / restart';;
          pdg-bot) printf '退役链正常|桥接 cmd_update restart pdg-bot; migrate_deploy_botfiles try-restart';;
          pdg-dotwitness) printf '退役链正常|migrate_dotwitness enable --now / restart';;
          *) printf '退役链正常|桥接 cmd_update enable --now pdg-health.timer; migrate_health_timer enable / restart';;
        esac
      fi;;
    *) printf '意外|%s 有变化 —— 本现场(无 sing-box unit、救援未配置、平台 iOS)退役链成功路径上不该动它' "$u";;
  esac
}
# <<< PDG-EXTRACT-END r3_svc_class
# >>> PDG-EXTRACT-BEGIN r3_svc_verdict
r3_win_check(){   # $1=窗口结果 → 0 结构有效(WINV[unit]=值 WINWHY[unit]=第三列) / 1 无效(R3_WHY 逐项)
                  # 每个受监视 unit 恰一行、三列; 值只能是非负整数或 INVALID; 不许重复、不许清单外、不许缺
  local f="$1" raw rc l u v r t w inw why="" TAB; TAB="$(printf '\t')"
  declare -gA WINV=() WINWHY=()
  [[ -n "$f" ]] || { R3_WHY="没有给窗口结果文件"; return 1; }
  raw="$(cat -- "$f" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="窗口结果读不了($f, cat rc=$rc)"; return 1; }
  while IFS= read -r l; do
    [[ -n "$l" ]] || { why="$why 有空行;"; continue; }
    t="${l//[!$TAB]/}"
    (( ${#t} == 2 )) || { why="$why 行不是 3 列([${l:0:40}]);"; continue; }
    u="${l%%"$TAB"*}"; r="${l#*"$TAB"}"; v="${r%%"$TAB"*}"; r="${r#*"$TAB"}"
    inw=0; for w in "${SVC_WATCH[@]}"; do [[ "$w" == "$u" ]] && inw=1; done
    (( inw )) || { why="$why 清单外的 unit [$u];"; continue; }
    [[ -z "${WINV[$u]+x}" ]] || { why="$why 窗口里重复出现 [$u];"; continue; }
    if [[ ! "$v" =~ ^(0|[1-9][0-9]*)$ && "$v" != INVALID ]]; then why="$why [$u] 的窗口值非法 [${v:0:20}];"; WINV[$u]=BAD; continue; fi
    WINV[$u]="$v"; WINWHY[$u]="$r"
  done <<<"$raw"
  for w in "${SVC_WATCH[@]}"; do [[ -n "${WINV[$w]+x}" ]] || why="$why 缺 [$w] 这一行;"; done
  [[ -z "$why" ]] || { R3_WHY="${why# }"; return 1; }
  return 0
}
r3_svc_verdict(){   # $1=前 $2=后 $3=场景 $4=窗口结果 → 0 成立
                    # 终态对账结构同 ②, 分类换成退役链, 另核 pdg-mitm 必需动作;
                    # 窗口按每个 unit 的启动事件计数参与判定, **不因前后状态相同而跳过**
  local u b a cls reason pol TAB; TAB="$(printf '\t')"
  local win="${4:-}" rc
  local -A R3_RB=() R3_RA=()
  local n_req=0 n_norm=0 n_un=0 n_inst=0 n_invalid=0 n_win=0 n_winbad=0 n_winviol=0 n_zero=0
  local unexpected="" invalid="" winbad="" winviol="" mitm_after=""
  r3_set_check "$1" "$3/前" R3_RB; rc=$?
  if (( rc == 2 )); then bad "$3: $R3_WHY —— 集合观测无效就不能谈'意外 0'"; return 1
  elif (( rc != 0 )); then bad "$3: $R3_WHY —— 集合不全就不能谈'意外 0'"; return 1; fi
  r3_set_check "$2" "$3/后" R3_RA; rc=$?
  if (( rc == 2 )); then bad "$3: $R3_WHY —— 集合观测无效就不能谈'意外 0'"; return 1
  elif (( rc != 0 )); then bad "$3: $R3_WHY —— 集合不全就不能谈'意外 0'"; return 1; fi
  if ! r3_win_check "$win"; then bad "$3: 窗口结果无效: $R3_WHY —— 不能拿它说'区间里没启动过'"; return 1; fi
  echo "── 服务动作对账($3; 允许清单事先从桥接 cmd_update 与退役 run_all_migrations 的调用链推导)──"
  for u in "${SVC_WATCH[@]}"; do
    b="${R3_RB[$u]}"; a="${R3_RA[$u]}"
    # 窗口: 先判, 每个 unit 都判
    if ! pol="$(r3_win_policy "$u")"; then n_winbad=$((n_winbad+1)); winbad="$winbad $u(窗口策略里没有它)"
    elif [[ "${WINV[$u]}" == INVALID ]]; then n_winbad=$((n_winbad+1)); winbad="$winbad $u(${WINWHY[$u]})"
    elif [[ "${pol%%|*}" == zero ]]; then
      n_zero=$((n_zero+1))
      if (( ${WINV[$u]} > 0 )); then
        n_winviol=$((n_winviol+1)); winviol="$winviol $u(${WINV[$u]} 条)"
        printf '    %-20s [窗口内启动事件 · 不允许] %s 条 —— %s\n' "$u" "${WINV[$u]}" "${pol#*|}"
      fi
    elif (( ${WINV[$u]} > 0 )); then
      n_win=$((n_win+1)); printf '    %-20s [窗口内启动事件 · 允许] %s 条 —— %s\n' "$u" "${WINV[$u]}" "${pol#*|}"
    fi
    if ! bridge_row_valid "$b"; then n_invalid=$((n_invalid+1)); invalid="$invalid $u(前: $OBS_WHY)"; continue; fi
    if ! bridge_row_valid "$a"; then n_invalid=$((n_invalid+1)); invalid="$invalid $u(后: $OBS_WHY)"; continue; fi
    [[ "$u" == pdg-mitm ]] && mitm_after="$a"
    local b_pid a_pid b_inv a_inv
    b_pid="$(cut -d"$TAB" -f9 <<<"$b")"; a_pid="$(cut -d"$TAB" -f9 <<<"$a")"
    b_inv="$(cut -d"$TAB" -f10 <<<"$b")"; a_inv="$(cut -d"$TAB" -f10 <<<"$a")"
    if [[ "$b_pid" != "$a_pid" || "$b_inv" != "$a_inv" ]]; then
      n_inst=$((n_inst+1))
      printf '    %-20s [实例更替] MainPID %s→%s Invocation %s→%s(只说明换了实例)\n' "$u" "$b_pid" "$a_pid" "${b_inv:0:8}" "${a_inv:0:8}"
    fi
    [[ "$b" == "$a" ]] && continue
    cls="$(r3_svc_class "$u" "$b" "$a")"; reason="${cls#*|}"; cls="${cls%%|*}"
    printf '    %-20s [%s]\n      前: %s\n      后: %s\n      依据: %s\n' "$u" "$cls" "${b#*"$TAB"}" "${a#*"$TAB"}" "$reason"
    case "$cls" in
      退役链必需) n_req=$((n_req+1));;
      退役链正常) n_norm=$((n_norm+1));;
      *) n_un=$((n_un+1)); unexpected="$unexpected $u";;
    esac
  done
  printf '    小计: 退役链必需 %d / 退役链正常 %d / 实例更替 %d / **意外 %d** / 观测无效 %d | 窗口启动事件: 不允许启动的 %d 个里有 %d 个出现 / 允许启动且出现 %d 个 / 窗口观测无效 %d\n' \
    "$n_req" "$n_norm" "$n_inst" "$n_un" "$n_invalid" "$n_zero" "$n_winviol" "$n_win" "$n_winbad"
  _evn "07-service-actions-$3.txt" "必需=$n_req 正常=$n_norm 实例更替=$n_inst 意外=$n_un 观测无效=$n_invalid 窗口不允许启动却有启动事件=$n_winviol 窗口允许启动且有启动事件=$n_win 窗口无效=$n_winbad;$unexpected;$invalid;$winviol;$winbad"
  if (( n_invalid > 0 )); then bad "$3: 有 $n_invalid 项观测无效:$invalid —— 不产出'意外 0'"; return 1; fi
  if (( n_winbad > 0 )); then bad "$3: 有 $n_winbad 项窗口观测无效:$winbad —— 不知道区间里启动过没有"; return 1; fi
  if (( n_winviol > 0 )); then bad "$3: 不允许启动的服务在窗口内有启动事件:$winviol —— 前后状态相同也不放过"; return 1; fi
  if (( n_un > 0 )); then bad "$3: 出现退役链清单外的服务动作:$unexpected"; return 1; fi
  if [[ -z "$mitm_after" ]] || [[ "$(cut -d"$TAB" -f5 <<<"$mitm_after")" != not-found ]] \
     || [[ "$(cut -d"$TAB" -f6 <<<"$mitm_after")" == active ]]; then
    bad "$3: 退役链必需的 pdg-mitm 停 / 禁 / 删**没有发生**(后: ${mitm_after:-<无有效行>})"; return 1
  fi
  ok "$3: 服务终态对账落在事先推导的退役链清单内(必需 $n_req 项已发生; 意外 0, 观测无效 0; 实例更替 $n_inst 单列); 窗口内启动事件计数: 不允许启动的 $n_zero 个服务均为 0 条, 允许启动且出现启动事件的 $n_win 个单列 —— 窗口口径只是 journal 里 'Started <unit>' 的条数, 看不到停止 / 禁用 / reload, 也看不到 socket 的激活(记为 Listening on), 不是完整的服务动作审计"
  return 0
}
# <<< PDG-EXTRACT-END r3_svc_verdict

# ── 输入 ────────────────────────────────────────────────────────────────────
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
R3_MOSCFG=/etc/mosdns/config.yaml; R3_GEOCN=/etc/mosdns/rules/geosite_cn.txt
_sfx="$$-$RANDOM"
R3_DNS_K="r3k-$_sfx.e2e.test"; R3_DNS_CPRE="r3c-pre-$_sfx.e2e.test"; R3_DNS_CPOST="r3c-post-$_sfx.e2e.test"
R3_DNS_PPRE="r3p-pre-$_sfx.e2e.test"; R3_DNS_PPOST="r3p-post-$_sfx.e2e.test"

SECT "③-0 前置: ② 的结果与桥接前像(任一不成立就停在调用之前)"
for c in git python3 ss dig curl sha256sum timeout comm cmp stat diff; do command -v "$c" >/dev/null || _hard "缺命令: $c"; done
for s in "$BRIDGE_SHA" "$RETIRE_SHA"; do
  [[ "$(git -C "$R3_OBJ" cat-file -t "$s" 2>/dev/null)" == commit ]] || _hard "本 job 的检出里取不到对象 $s"
done
mkdir -p "$R3_BRSRC" "$R3_RTSRC"
git -C "$R3_OBJ" archive "$BRIDGE_SHA" | tar -x -C "$R3_BRSRC" || _hard "展开桥接树失败"
git -C "$R3_OBJ" archive "$RETIRE_SHA" | tar -x -C "$R3_RTSRC" || _hard "展开退役树失败"

# >>> PDG-EXTRACT-BEGIN r3_stable
r3_stable_assert(){   # 参数同共享 svc_stable_assert: $1=unit $2=running|stopped $3=标签 [$4=窗口秒数] → 0 持续 / 1 不稳定 / 2 观测无效
                      # 共享窗口 svc_stable_window 原样执行(窗口长度、状态、实例身份、重启计数、journal 判据都在它里面), 但它不看
                      # systemctl / journalctl 的退出码。这里只给这一次调用在 PATH 最前放两个记账包装: 窗口里任何一次查询非零退出都记下,
                      # 有记录就判观测无效、共享结论不采信 —— 一次失败不能被随后一次成功覆盖。journalctl --sync(共享的尽力刷盘,
                      # 输出不被任何判据消费)不记。包装只作用于这次函数调用: 不定义同名函数、不导出; 产品升级进程看不到它。
                      # 记账通道自身失效(追加失败)不能被读成"没有查询失败": 包装追加失败时向本 shell 发 USR1(不经文件系统),
                      # 粘性标志 R3_STABLE_FAULT 置 1 ⇒ 本项观测无效; 窗口一返回就把 USR1 处置复原(不留 trap、不留忽略态)。
  local u="$1" want="$2" lbl="$3" secs="${4:-8}" wd rec c real rc raw n prev_usr1
  wd="${R3_TMP:?}/stableq-$u-$BASHPID-$RANDOM"; rec="$wd.rec"
  if ! { mkdir -p -- "$wd" && : > "$rec"; } 2>/dev/null; then bad "$lbl: **观测无效** —— 查询记账建不出来($wd)"; return 2; fi
  for c in systemctl journalctl; do
    real="$(type -P "$c")"
    [[ -n "$real" && "$real" != "$wd/$c" ]] || { bad "$lbl: **观测无效** —— 找不到真实的 $c"; rm -rf -- "$wd"; return 2; }
    if ! printf '#!/usr/bin/env bash\n%q "$@"; rc=$?\nif (( rc != 0 )) && [[ "$*" != --sync ]]; then printf "%%s\\t%%s\\t%%s\\n" %q "$rc" "$*" >> %q || kill -USR1 %q; fi\nexit "$rc"\n' \
         "$real" "$c" "$rec" "$BASHPID" > "$wd/$c" 2>/dev/null || ! chmod +x "$wd/$c" 2>/dev/null; then
      bad "$lbl: **观测无效** —— $c 的记账包装写不出来"; rm -rf -- "$wd"; return 2
    fi
  done
  prev_usr1="$(trap -p USR1)"; R3_STABLE_FAULT=0; trap 'R3_STABLE_FAULT=1' USR1
  PATH="$wd:$PATH" svc_stable_window "$u" "$want" "$secs"; rc=$?
  if [[ -n "$prev_usr1" ]]; then eval "$prev_usr1"; else trap - USR1; fi
  rm -rf -- "$wd"
  if (( R3_STABLE_FAULT )); then
    bad "$lbl: **观测无效** —— 记账通道失效: 有失败查询的记录没写进去(包装追加失败, 经 USR1 报告); 共享判据给的是 rc=$rc(${SVC_STABLE_WHY:-无}), 不采信"
    return 2
  fi
  raw="$(cat -- "$rec" 2>/dev/null)" || { bad "$lbl: **观测无效** —— 查询记账读不了($rec)"; return 2; }
  if [[ -n "$raw" ]]; then
    n="$(grep -c . <<<"$raw")"
    bad "$lbl: **观测无效** —— 窗口里有 $n 次查询非零退出(首条: ${raw%%$'\n'*}); 共享判据给的是 rc=$rc(${SVC_STABLE_WHY:-无}), 不采信"
    return 2
  fi
  case "$rc" in
    0) ok "$lbl: $SVC_STABLE_WHY";;
    1) bad "$lbl: 不是持续稳定 —— $SVC_STABLE_WHY";;
    *) bad "$lbl: **观测无效** —— $SVC_STABLE_WHY"; rc=2;;
  esac
  return "$rc"
}
# <<< PDG-EXTRACT-END r3_stable
# >>> PDG-EXTRACT-BEGIN r3_dns
# DNS 仪器与答案来源判据(317)。只用既有合法输入建立可区分条件: 自有上游只接 local_upstream, geosite_cn 末尾追加名字;
# 劫持模式、规则顺序、其它规则不动。答案来源一律以自有上游按名记录的**本次查询窗口增量**为据: U 必须有正增量, H 必须零增量;
# 缓存命中、重启本身都不是来源证明。lazy_cache 排在所有分支之前, 所以要求正增量的名字在它所在实例里只问一次(分阶段取名)。
# 不复用 platform-fail 的 dns_* 仪器(它的计数读取不分"读不了"与"没有查询", 标定 bad 之后仍返回 0; 只登记, 不在此修)。
r3_ipv4(){ local o; [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1; for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done; }
r3_proc_prop(){   # $1=MainPID|InvocationID $2=unit → 0 取得(R3_VAL) / 2 查询失败、多行或格式不对(输出不采信)
  local out rc; R3_VAL=""
  out="$(systemctl show -p "$1" --value "$2" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="$2 的 $1 查询退出 $rc(输出 [${out:0:40}] 不采信)"; return 2; }
  case "$1" in
    MainPID)      [[ "$out" =~ ^[1-9][0-9]*$ ]] || { R3_WHY="$2 的 MainPID 取值无效([${out:0:40}])"; return 2; };;
    InvocationID) [[ "$out" =~ ^[0-9a-f]{32}$ ]] || { R3_WHY="$2 的 InvocationID 取值无效([${out:0:40}])"; return 2; };;
    *) R3_WHY="r3_proc_prop 不认识的属性 [$1]"; return 2;;
  esac
  R3_VAL="$out"
}
r3_pid_live(){ local st; st="$( { cut -d' ' -f3 < "/proc/$1/stat"; } 2>/dev/null)"; [[ -n "$st" && "$st" != Z ]]; }   # 进程在且不是僵尸(kill -0 对僵尸也成功)
r3_dns_stub_alive(){   # → 0 登记的自有上游进程还在且命令行逐项等于本次启动参数 / 2 不在、身份不符或读不了
  local got want
  [[ "$R3_STUB_PID" =~ ^[1-9][0-9]*$ ]] || { R3_WHY="自有上游没有登记 PID"; return 2; }
  r3_pid_live "$R3_STUB_PID" || { R3_WHY="自有上游进程 $R3_STUB_PID 已不在"; return 2; }
  got="$( { tr '\0' '\n' < "/proc/$R3_STUB_PID/cmdline"; } 2>/dev/null)" || { R3_WHY="自有上游进程 $R3_STUB_PID 的命令行读不了"; return 2; }
  want="$(printf '%s\n' python3 "$R3_STUB" --port "$R3_DNS_PORT" --count "$R3_UPCNT" --log "$R3_UPLOG" --mode answer-a --answer "$R3_DNS_U")"
  [[ "$got" == "$want" ]] || { R3_WHY="进程 $R3_STUB_PID 的命令行与本次登记的自有上游不符([${got//$'\n'/ }])"; return 2; }
}
r3_dns_upcount(){   # $1=名字 → 0 取得(R3_VAL=自有上游日志里该名的记录数; R3_UPTOTAL=全部查询记录数) / 2 日志或计数不可用(不当成"没有查询")
  local log cnt l first=1 n=0 t=0 c=0 want="${1,,}"; R3_VAL=""; R3_UPTOTAL=""
  log="$(cat -- "$R3_UPLOG" 2>/dev/null)" || { R3_WHY="自有上游日志读不了($R3_UPLOG)"; return 2; }
  cnt="$(cat -- "$R3_UPCNT" 2>/dev/null)" || { R3_WHY="自有上游计数读不了($R3_UPCNT)"; return 2; }
  while IFS= read -r l; do
    if (( first )); then
      [[ "$l" == "started mode=answer-a port=$R3_DNS_PORT" ]] || { R3_WHY="自有上游日志首行与本次启动记录不符([${l:0:60}])"; return 2; }
      first=0; continue
    fi
    [[ "$l" =~ ^[0-9]+\.[0-9]{3}\ q=([^ ]*)\ len=[0-9]+$ ]] || { R3_WHY="自有上游日志有不认识的行([${l:0:60}])"; return 2; }
    t=$((t + 1)); [[ "${BASH_REMATCH[1],,}" == "$want" ]] && n=$((n + 1))
  done <<<"$log"
  if [[ -n "$cnt" ]]; then
    while IFS= read -r l; do
      [[ "$l" == 1 ]] || { R3_WHY="自有上游计数文件有不认识的行([${l:0:20}])"; return 2; }
      c=$((c + 1))
    done <<<"$cnt"
  fi
  (( c == t )) || { R3_WHY="自有上游计数 $c 与日志里的查询记录 $t 条对不上"; return 2; }
  R3_VAL="$n"; R3_UPTOTAL="$t"
}
r3_dns_stub_start(){   # → 0 自有上游已起(PID 登记、退出回收已挂、就绪与启动记录都核过) / 2 没起来
  local i rd="stub ready 127.0.0.1:$R3_DNS_PORT mode=answer-a"
  [[ -z "$R3_STUB_PID" ]] || { R3_WHY="自有上游已经起过(PID $R3_STUB_PID), 不重复起"; return 2; }
  [[ -f "$R3_STUB" ]] || { R3_WHY="找不到自有上游程序 $R3_STUB"; return 2; }
  python3 "$R3_STUB" --port "$R3_DNS_PORT" --count "$R3_UPCNT" --log "$R3_UPLOG" --mode answer-a --answer "$R3_DNS_U" \
    < /dev/null > "$R3_UPOUT" 2>&1 &
  R3_STUB_PID=$!
  e2e_add_exit_hook r3_dns_stub_stop || { r3_dns_stub_stop; R3_WHY="自有上游的退出回收登记不上"; return 2; }
  for ((i = 0; i < 50; i++)); do
    [[ "$(cat -- "$R3_UPOUT" 2>/dev/null)" == "$rd" ]] && break
    r3_pid_live "$R3_STUB_PID" || break
    sleep 0.2
  done
  [[ "$(cat -- "$R3_UPOUT" 2>/dev/null)" == "$rd" ]] || { R3_WHY="自有上游没报就绪(输出: $(head -c 200 -- "$R3_UPOUT" 2>/dev/null | tr '\n' ' '))"; return 2; }
  r3_dns_stub_alive || return 2
  r3_dns_upcount "$R3_DNS_W" || return 2
  (( R3_UPTOTAL == 0 )) || { R3_WHY="自有上游刚起就已有 $R3_UPTOTAL 条查询记录"; return 2; }
  echo "  I 自有上游已起: PID $R3_STUB_PID(python3 $R3_STUB --port $R3_DNS_PORT --mode answer-a --answer $R3_DNS_U)"
}
r3_dns_stub_stop(){   # 只按登记 PID、且身份仍相符时回收(有上限的等待); 不按名字宽杀
  local i
  [[ -n "${R3_STUB_PID:-}" ]] || return 0
  if r3_dns_stub_alive; then
    kill "$R3_STUB_PID" 2>/dev/null
    for ((i = 0; i < 25; i++)); do r3_pid_live "$R3_STUB_PID" || break; sleep 0.2; done
    ! r3_pid_live "$R3_STUB_PID" || kill -KILL "$R3_STUB_PID" 2>/dev/null
  fi
  wait "$R3_STUB_PID" 2>/dev/null
  R3_STUB_PID=""
  return 0
}
r3_dns_probe(){   # $1=名字 $2=阶段标签 → 0 一次有效观测(R3_DNS_ST 状态 / R3_DNS_ANS 全部 A / R3_DNS_INC 该名上游增量 / R3_DNS_ID 实例) / 2 观测无效
  local name="$1" lbl="$2" of="$R3_TMP/dig-$2.out" ef="$R3_TMP/dig-$2.err" out err rc pid0 inv0 pid1 inv1 c0 c1
  local l st="" nst=0 nfl=0 nsrv=0 hdr="" sec="" got=0 own ttl cls typ rd extra chain ans=""
  local re_st='^;; ->>HEADER<<- opcode: QUERY, status: ([A-Z]+), id: [0-9]+$'
  local re_fl='^;; flags:[a-z ]*; QUERY: 1, ANSWER: ([0-9]+), AUTHORITY: [0-9]+, ADDITIONAL: [0-9]+$'
  R3_DNS_ST=""; R3_DNS_ANS=""; R3_DNS_INC=""; R3_DNS_ID=""
  r3_dns_stub_alive || return 2
  r3_proc_prop MainPID mosdns || return 2; pid0="$R3_VAL"
  r3_proc_prop InvocationID mosdns || return 2; inv0="$R3_VAL"
  r3_dns_upcount "$name" || return 2; c0="$R3_VAL"
  dig +time=3 +tries=2 @127.0.0.1 "$name" A > "$of" 2> "$ef"; rc=$?
  out="$(cat -- "$of" 2>/dev/null)" || { R3_WHY="dig 的标准输出留档读不了"; return 2; }
  err="$(cat -- "$ef" 2>/dev/null)" || { R3_WHY="dig 的标准错误留档读不了"; return 2; }
  { printf '# 阶段 %s 名字 %s: dig 退出 %s; 查询前 mosdns MainPID %s InvocationID %s; 该名上游记录 %s\n' "$lbl" "$name" "$rc" "$pid0" "$inv0" "$c0"
    printf '%s\n' '## stdout' "$out" '## stderr' "$err"; } > "$EVID/05-dns-probe-$lbl.txt" 2>/dev/null \
    || { R3_WHY="$lbl 的原始记录写不进证据目录"; return 2; }
  (( rc == 0 )) || { R3_WHY="命令失败: dig 退出 $rc(已输出的 ${#out} 字节不采信)"; return 2; }
  [[ -z "$err" ]] || { R3_WHY="dig 有标准错误输出([${err:0:80}])"; return 2; }
  chain=" ${name,,}. "
  while IFS= read -r l; do
    if [[ "$l" =~ $re_st ]]; then st="${BASH_REMATCH[1]}"; nst=$((nst + 1)); continue; fi
    if [[ "$l" =~ $re_fl ]]; then hdr="${BASH_REMATCH[1]}"; nfl=$((nfl + 1)); continue; fi
    if [[ "$l" == ";; SERVER: 127.0.0.1#53(127.0.0.1)"* ]]; then nsrv=$((nsrv + 1)); continue; fi
    if [[ "$l" == ";; ANSWER SECTION:" ]]; then sec=ans; continue; fi
    [[ "$sec" == ans ]] || continue
    if [[ -z "$l" ]]; then sec=end; continue; fi
    read -r own ttl cls typ rd extra <<<"$l"
    [[ -n "$rd" && -z "$extra" && "$ttl" =~ ^[0-9]+$ && "$cls" == IN ]] || { R3_WHY="输出无效: 答案段有一行格式不对([${l:0:60}])"; return 2; }
    got=$((got + 1))
    [[ "$chain" == *" ${own,,} "* ]] || { R3_WHY="输出无效: 答案段记录 [$own] 不在 $name 的应答链上"; return 2; }
    case "$typ" in
      CNAME) chain="$chain${rd,,} ";;
      A) r3_ipv4 "$rd" || { R3_WHY="输出无效: A 记录 [$rd] 不是合法 IPv4"; return 2; }; ans="$ans $rd";;
      *) R3_WHY="输出无效: 答案段有 $typ 记录"; return 2;;
    esac
  done <<<"$out"
  (( nst == 1 && nfl == 1 )) || { R3_WHY="输出无效: 状态行 $nst 行、flags 行 $nfl 行(都应恰 1)"; return 2; }
  (( nsrv == 1 )) || { R3_WHY="输出无效: 应答服务器 127.0.0.1#53 的行有 $nsrv 条(应恰 1)"; return 2; }
  (( got == hdr )) || { R3_WHY="输出无效: 答案段 $got 条, 头部 ANSWER: $hdr"; return 2; }
  r3_dns_upcount "$name" || return 2; c1="$R3_VAL"
  (( c1 >= c0 )) || { R3_WHY="自有上游里 $name 的记录数倒退($c0 → $c1)"; return 2; }
  r3_proc_prop MainPID mosdns || return 2; pid1="$R3_VAL"
  r3_proc_prop InvocationID mosdns || return 2; inv1="$R3_VAL"
  [[ "$pid1" == "$pid0" && "$inv1" == "$inv0" ]] || { R3_WHY="查询期间 mosdns 实例变了(MainPID $pid0 → $pid1, InvocationID $inv0 → $inv1)"; return 2; }
  r3_dns_stub_alive || return 2
  R3_DNS_ST="$st"; R3_DNS_ANS="${ans# }"; R3_DNS_INC=$((c1 - c0)); R3_DNS_ID="$pid0/${inv0:0:8}"
  printf '## 解析: status=%s A=[%s]; 该名上游记录 %s → %s(增量 %s; 上游总记录 %s); 查询后实例相同\n' \
    "$st" "$R3_DNS_ANS" "$c0" "$c1" "$R3_DNS_INC" "$R3_UPTOTAL" >> "$EVID/05-dns-probe-$lbl.txt" 2>/dev/null \
    || { R3_DNS_ST=""; R3_DNS_ANS=""; R3_DNS_INC=""; R3_DNS_ID=""; R3_WHY="$lbl 的解析结果写不进证据目录"; return 2; }
}
r3_dns_path(){   # $1=名字 $2=阶段标签 $3=U|H → 0 期望路径成立 / 1 有效观测但答案与期望不符 / 3 答案符合期望但来源证据不成立 / 2 观测无效
  local want x only=1 a
  case "$3" in U) want="$R3_DNS_U";; H) want="$E2E_SIP";; *) R3_WHY="r3_dns_path 不认识的期望 [$3]"; return 2;; esac
  r3_dns_probe "$1" "$2" || return 2
  a="status=$R3_DNS_ST A=[${R3_DNS_ANS:-无}] 自有上游该名 +$R3_DNS_INC 实例 $R3_DNS_ID"
  [[ -n "$R3_DNS_ANS" ]] || only=0
  for x in $R3_DNS_ANS; do [[ "$x" == "$want" ]] || only=0; done       # 全部 A 都要等于期望, 不只看第一条
  if [[ "$R3_DNS_ST" != NOERROR ]] || (( ! only )); then R3_WHY="$1 答案与期望 $3=$want 不符($a)"; return 1; fi
  if [[ "$3" == U ]] && (( R3_DNS_INC < 1 )); then
    R3_WHY="$1 答案是 U, 但本次查询窗口里自有上游没有收到该名($a) —— 答案来源没有证据(缓存或别的来源)"; return 3
  fi
  if [[ "$3" == H ]] && (( R3_DNS_INC > 0 )); then
    R3_WHY="$1 答案是 H, 但本次查询窗口里自有上游收到了该名($a) —— 与接管 / 劫持路径对不上"; return 3
  fi
  R3_WHY="$1 = $3($a)"
}
r3_dns_rulematch(){   # $1..=名字 → 0 取得(R3_VAL 每行"名字<TAB>命中来源, 逗号分隔; 空 = 没有命中") / 2 判不了(原因在 R3_WHY)
                      # 求值口径 = mosdns v5.3.4(b7323188)pkg/matcher/domain 的语义, 只支持 full / domain / keyword(无前缀或空类型按 domain);
                      # regexp 不判(mosdns 用 Go RE2, 这里没有等价实现)。范围 = 全部 domain_set 块的 files + 序列里 qname 的内联表达式。
                      # 配置只认模板那一种写法; 认不出的结构、读不全的文件、不支持的规则一律"判不了", 不静默跳过, 更不当成"没有命中"。
  local out rc
  out="$(python3 - "$R3_MOSCFG" "$@" 2>&1 <<'PY'
import re, sys
cfg, names = sys.argv[1], sys.argv[2:]
def die(m):
    print(m); sys.exit(2)
# ── mosdns v5.3.4 的域名规则语义 ──
def norm(s):              # NormalizeDomain: 去掉一个结尾点, 转小写
    return (s[:-1] if s.endswith(".") else s).lower()
def labels(s):            # SubDomainMatcher: NormalizeDomain 后经 ReverseDomainScanner(再去一个结尾点; 自右向左; 不产生开头的空标签)
    s = norm(s)
    s = s[:-1] if s.endswith(".") else s
    out, p = [], len(s)
    while p > 0:
        t = p; p = s.rfind(".", 0, p); out.append(s[p + 1:t])
    return out
VIS = re.compile(r"[\x21-\x7e]+")
def rule(src, s):         # MixMatcher.Add(默认 domain): 第一个冒号前是类型
    if not VIS.fullmatch(s):
        die("%s: 规则含空白或非 ASCII 可见字符, 本判据不认 [%s]" % (src, s[:60]))
    typ, sep, pat = s.partition(":")
    if not sep:
        typ, pat = "", s
    typ = typ or "domain"
    if typ == "regexp":
        die("%s: regexp 规则不判(mosdns 用 Go RE2, 本判据没有等价实现)[%s]" % (src, s[:60]))
    if typ not in ("full", "domain", "keyword"):
        die("%s: 不认识的规则类型 [%s]" % (src, typ))
    return (src, typ, pat)
def hit(name, r):
    typ, pat = r[1], r[2]
    if typ == "full":
        return norm(name) == norm(pat)
    if typ == "keyword":
        return norm(pat) in norm(name)
    pl = labels(pat)
    return labels(name)[:len(pl)] == pl
# ── 配置: 只认模板写法 ──
def code_of(i, ln):       # 去掉 YAML 行尾注释(引号外、行首或空格之后的 #); 引号不闭合 ⇒ 判不了
    q = None; k = 0
    while k < len(ln):
        c = ln[k]
        if q:
            if q == '"' and c == "\\":
                k += 2; continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "#" and (k == 0 or ln[k - 1] == " "):
            return ln[:k].rstrip()
        k += 1
    if q:
        die("配置第 %d 行引号没有闭合, 本判据不认" % i)
    return ln.rstrip()
try:
    raw = open(cfg, "rb").read().decode("utf-8")
except (OSError, UnicodeError) as e:
    die("配置读不了: %s" % e)
if "\t" in raw:
    die("配置里有制表符, 本判据不认")
raws = raw.split("\n")
codes = [code_of(i, ln) for i, ln in enumerate(raws, 1)]
def bare(c):             # 找关键词前去掉双引号串(文件路径等), 只留 "(!)qname …" 这种匹配器串; 单引号串不去(里面有 qname 就判不了)
    return re.sub(r'"(?!!?qname )(?:[^"\\]|\\.)*"', '""', c)
blocks, cur, top = [], None, None
for i, c in enumerate(codes, 1):
    if re.search(r"\b(exps|sets|domain_sets)\s*:", bare(c)):
        die("配置第 %d 行有 exps / sets / domain_sets 键, 本判据不认" % i)
    if not c.strip():
        continue
    if not c.startswith(" "):
        top, cur = c, None; continue
    if top != "plugins:":
        continue
    m = re.fullmatch(r"  - tag: ([A-Za-z0-9_.-]+)", c)
    if m:
        cur = {"tag": m.group(1), "line": i, "body": []}; blocks.append(cur); continue
    if cur is None or not c.startswith("    "):
        die("配置第 %d 行不在任何 plugin 块里(或缩进不是模板写法), 本判据不认" % i)
    cur["body"].append((i, c, raws[i - 1]))      # (行号, 去掉行尾注释的代码, 原文)
sets = {}
for b in blocks:
    ts = [c for _, c, _ in b["body"] if c.startswith("    type:")]   # 按去掉行尾注释后的代码认 type 行
    t = re.fullmatch(r"    type: ([A-Za-z0-9_]+)", ts[0]) if len(ts) == 1 else None
    if not t:
        die("plugin %s(第 %d 行)的 type 不是恰 1 行模板写法, 本判据不认" % (b["tag"], b["line"]))
    if t.group(1) == "qname":
        die("plugin %s 是 qname 匹配器插件(带自己的规则), 本判据不认" % b["tag"])
    if t.group(1) != "domain_set":
        continue
    if b["tag"] in sets:
        die("domain_set %s 重名" % b["tag"])
    a = [c for _, c, _ in b["body"] if not c.startswith("    type:")]
    m = re.fullmatch(r'    args: *\{ *files: *\[ *((?:"[^"\\]+" *, *)*"[^"\\]+")? *\] *\}', a[0]) if len(a) == 1 else None
    if not m:
        die("domain_set %s(第 %d 行)的写法不是模板那一种(单行 args: { files: [\"…\"] }), 本判据不认" % (b["tag"], b["line"]))
    sets[b["tag"]] = re.findall(r'"([^"\\]+)"', m.group(1) or "")
n_ds = sum(1 for c in codes if re.search(r"\bdomain_set\b", bare(c)))
if n_ds != len(sets):
    die("配置里提到 domain_set 的地方 %d 处, 认出的 domain_set 块 %d 个, 本判据不认" % (n_ds, len(sets)))
rules = []
for i, c in enumerate(codes, 1):
    n = len(re.findall(r"(?<![\w$])!?qname(?!\w)", bare(c)))
    if not n:
        continue
    m = re.fullmatch(r' +(?:- )?(?:matches: )?"!?qname ([^"]+)"', c) or re.fullmatch(r" +(?:- )?(?:matches: )?qname ([^\"'!]+)", c)
    if n != 1 or not m:
        die("配置第 %d 行的 qname 写法本判据不认 [%s]" % (i, c.strip()[:60]))
    for tok in m.group(1).split():
        if tok.startswith("$"):
            if tok[1:] not in sets:
                die("配置第 %d 行 qname 引用了认不出的集合 %s" % (i, tok))
        elif tok.startswith("&"):
            die("配置第 %d 行 qname 直接引用规则文件 %s, 本判据不认" % (i, tok))
        else:
            rules.append(rule("配置第 %d 行内联" % i, tok))
for tag, fs in sets.items():
    for f in fs:
        if not f.startswith("/"):
            die("domain_set %s 的文件不是绝对路径 [%s]" % (tag, f))
        try:
            data = open(f, "rb").read()
        except OSError as e:
            die("规则文件读不了: %s(%s 引用; %s)" % (f, tag, e))
        for j, ln in enumerate(data.split(b"\n"), 1):      # LoadFromTextReader: 按行, # 之后是注释, 两端去空白, 空行跳过
            if len(ln) > 65536:
                die("%s:%d 超过 64 KiB(mosdns 逐行读取的上限)" % (f, j))
            r = ln.split(b"#", 1)[0].strip(b" \t\r\n\v\f")
            if r:
                rules.append(rule("%s:%d" % (f, j), r.decode("latin-1")))
for x in names:
    print("%s\t%s" % (norm(x), ",".join(r[0] for r in rules if hit(x, r))))
PY
)"; rc=$?
  (( rc == 0 )) || { R3_VAL=""; R3_WHY="规则匹配判不了(python 退出 $rc): ${out:0:200}"; return 2; }
  R3_VAL="$out"
}
r3_dns_cfgline(){   # $1=mosdns 配置 [$2=新 args 行 $3=写出到] → 0 取得(R3_VAL="行号<TAB>local_upstream 块里唯一那一行单行 args 的原文");
                    # 给了 $2 $3 时另把"只换这一行、其余逐字不变"的整份写到 $3 / 2 结构与预期不符(不改任何东西)
  local out rc
  out="$(python3 - "$@" 2>&1 <<'PY'
import re, sys
src = sys.argv[1]; new = sys.argv[2] if len(sys.argv) > 3 else None; dst = sys.argv[3] if len(sys.argv) > 3 else None
try:
    lines = open(src, encoding="utf-8").read().split("\n")
except (OSError, UnicodeError) as e:
    print("配置读不了: %s" % e); sys.exit(2)
tags = [i for i, l in enumerate(lines) if l.rstrip() == "  - tag: local_upstream"]
if len(tags) != 1:
    print("local_upstream 标签行 %d 处(应恰 1)" % len(tags)); sys.exit(2)
t = tags[0]
end = next((j for j in range(t + 1, len(lines)) if re.match(r"  - tag: |[^\s#]", lines[j])), len(lines))
if sum(1 for l in lines[t + 1:end] if l.rstrip() == "    type: forward") != 1:
    print("local_upstream 块里 type: forward 不是恰 1 行"); sys.exit(2)
args = [j for j in range(t + 1, end) if lines[j].startswith("    args:")]
if len(args) != 1 or not re.match(r"    args: \{.*\}\s*$", lines[args[0]]):
    print("local_upstream 块里单行 args 不是恰 1 行"); sys.exit(2)
a = args[0]
print("%d\t%s" % (a + 1, lines[a]))
if new is not None:
    lines[a] = new
    open(dst, "w", encoding="utf-8").write("\n".join(lines))
PY
)"; rc=$?
  (( rc == 0 )) || { R3_VAL=""; R3_WHY="mosdns 配置结构与预期不符($out)"; return 2; }
  R3_VAL="$out"
}
r3_dns_append_full(){   # $1=原件 $2=写出到 $3..=名字 → 原件逐字节在前(缺结尾换行先补)+ 每个名字一行 full:<名字>; 0 / 2
  python3 - "$@" <<'PY' 2>/dev/null || { R3_WHY="追加内容生成不了($1 → $2)"; return 2; }
import sys
src, dst, add = sys.argv[1], sys.argv[2], sys.argv[3:]
b = open(src, "rb").read()
if b and not b.endswith(b"\n"):
    b += b"\n"
open(dst, "wb").write(b + "".join("full:%s\n" % n for n in add).encode())
PY
}
r3_dns_write(){   # $1=已备好的新内容 $2=目标 → 以 cat > 写进原文件(保 inode / mode / owner)并逐字节核; 0 / 2
  if ! { cat -- "$1" > "$2"; } 2>/dev/null; then R3_WHY="写不进 $2"; return 2; fi
  cmp -s -- "$1" "$2" || { R3_WHY="$2 写后与预期内容对不上"; return 2; }
}
r3_dns_restart(){   # $1=缘由 → 0 新实例 active 且 InvocationID 换过(登记 05-dns-instrument-restarts.txt) / 2 不成立
  local inv0 inv1 pid1 i ac=""
  r3_proc_prop InvocationID mosdns || return 2; inv0="$R3_VAL"
  systemctl restart mosdns > /dev/null 2>&1 || { R3_WHY="仪器重启($1): systemctl restart mosdns 失败"; return 2; }
  for ((i = 0; i < 50; i++)); do
    if r3_unit_q active mosdns; then ac="$R3_VAL"; [[ "$ac" == active ]] && break
    else ac="查询无效: $R3_WHY"; fi
    sleep 0.2
  done
  [[ "$ac" == active ]] || { R3_WHY="仪器重启($1)后 mosdns 没到 active(最后: $ac)"; return 2; }
  r3_proc_prop InvocationID mosdns || return 2; inv1="$R3_VAL"
  [[ "$inv1" != "$inv0" ]] || { R3_WHY="仪器重启($1)后 InvocationID 没变($inv0) —— 实例没换, 新条件没被加载"; return 2; }
  r3_proc_prop MainPID mosdns || return 2; pid1="$R3_VAL"
  R3_DNS_RESTARTS=$((R3_DNS_RESTARTS + 1))
  printf '仪器重启 #%s(%s): InvocationID %s → %s, MainPID %s\n' "$R3_DNS_RESTARTS" "$1" "$inv0" "$inv1" "$pid1" \
    >> "$EVID/05-dns-instrument-restarts.txt" 2>/dev/null || { R3_WHY="仪器重启登记写不进证据目录"; return 2; }
  echo "  I 仪器重启 #$R3_DNS_RESTARTS($1): InvocationID ${inv0:0:8}… → ${inv1:0:8}…, MainPID $pid1(调用前观测起界桩之前, 不进升级服务窗口)"
}
r3_dns_conditions(){   # → 0 仪器条件仍成立 / 1 被改动 / 2 观测无效(原因在 R3_WHY)
  local l
  r3_dns_stub_alive || { R3_WHY="自有上游: $R3_WHY"; return 2; }
  r3_dns_cfgline "$R3_MOSCFG" || return 2
  l="${R3_VAL#*$'\t'}"
  [[ "$l" == "$R3_DNS_UPLINE" ]] || { R3_WHY="local_upstream 的 args 行已换成 [${l:0:120}]"; return 1; }
  r3_fsha "$R3_GEOCN" || { R3_WHY="geosite_cn 摘要取不到: $R3_WHY"; return 2; }
  [[ "$R3_VAL" == "$R3_DNS_GEOSHA" ]] || { R3_WHY="geosite_cn 与调整后那一份对不上(sha256 ${R3_DNS_GEOSHA:0:12}… → ${R3_VAL:0:12}…)"; return 1; }
}
r3_dns_adjust(){   # 建立仪器条件(只做一次)→ 0 成立 / 2 不成立(R3_WHY); 调整前后原文与差异进 05-dns-*
  local ln old rc sha
  [[ "$R3_DNS_U" != "$E2E_SIP" ]] || { R3_WHY="U 与 H 相同($R3_DNS_U), 这组预期没有区分力"; return 2; }
  R3_DNS_UPLINE="    args: { concurrent: 1, upstreams: [ {addr: \"udp://127.0.0.1:$R3_DNS_PORT\"} ] }"
  r3_copy_record "$R3_MOSCFG" "$EVID/05-dns-mosdns-config.before.yaml" || return 2
  r3_copy_record "$R3_GEOCN" "$EVID/05-dns-geosite_cn.before.txt" || return 2
  r3_dns_cfgline "$EVID/05-dns-mosdns-config.before.yaml" "$R3_DNS_UPLINE" "$R3_TMP/moscfg.new" || return 2
  ln="${R3_VAL%%$'\t'*}"; old="${R3_VAL#*$'\t'}"
  r3_dns_append_full "$EVID/05-dns-geosite_cn.before.txt" "$R3_TMP/geocn.new" "$R3_DNS_W" "$R3_DNS_K" "$R3_DNS_CPRE" "$R3_DNS_CPOST" || return 2
  r3_fsha "$R3_STUB" || return 2; sha="$R3_VAL"
  r3_dns_stub_start || { R3_WHY="自有上游: $R3_WHY"; return 2; }
  r3_dns_write "$R3_TMP/moscfg.new" "$R3_MOSCFG" || return 2
  r3_dns_write "$R3_TMP/geocn.new" "$R3_GEOCN" || return 2
  r3_copy_record "$R3_MOSCFG" "$EVID/05-dns-mosdns-config.after.yaml" || return 2
  r3_copy_record "$R3_GEOCN" "$EVID/05-dns-geosite_cn.after.txt" || return 2
  r3_fsha "$R3_GEOCN" || return 2; R3_DNS_GEOSHA="$R3_VAL"
  diff -u "$EVID/05-dns-mosdns-config.before.yaml" "$EVID/05-dns-mosdns-config.after.yaml" > "$EVID/05-dns-mosdns-config.diff" 2>&1; rc=$?
  (( rc == 1 )) || { R3_WHY="配置调整前后差异取不到(diff 退出 $rc)"; return 2; }
  diff -u "$EVID/05-dns-geosite_cn.before.txt" "$EVID/05-dns-geosite_cn.after.txt" > "$EVID/05-dns-geosite_cn.diff" 2>&1; rc=$?
  (( rc == 1 )) || { R3_WHY="geosite_cn 调整前后差异取不到(diff 退出 $rc)"; return 2; }
  { echo "# ③ 调用前对 ② 现场所做的 DNS 仪器调整(逐项; 本支不再声称现场未经调整)"
    echo "自有上游: python3 $R3_STUB(sha256 $sha)--port $R3_DNS_PORT --mode answer-a --answer $R3_DNS_U; PID $R3_STUB_PID; 日志 $R3_UPLOG; 计数 $R3_UPCNT"
    echo "$R3_MOSCFG 第 $ln 行(local_upstream 的 args):"; echo "  前: $old"; echo "  后: $R3_DNS_UPLINE"
    echo "$R3_GEOCN 末尾追加: full:$R3_DNS_W full:$R3_DNS_K full:$R3_DNS_CPRE full:$R3_DNS_CPOST(调整后 sha256 $R3_DNS_GEOSHA)"
    echo "普通劫持探针 $R3_DNS_PPRE / $R3_DNS_PPOST 不写进任何集合; 劫持模式、规则顺序、其它规则未动"
    echo "标定: 接管表临时追加 full:$R3_DNS_K, 随后按原内容与属性还原(见 05-dns-calibration.txt); 仪器重启见 05-dns-instrument-restarts.txt"
  } > "$EVID/05-dns-instrument-adjustments.txt" 2>/dev/null || { R3_WHY="仪器调整清单写不进证据目录"; return 2; }
  echo "  I 仪器调整: $R3_MOSCFG 第 $ln 行 local_upstream → 127.0.0.1:$R3_DNS_PORT; $R3_GEOCN 末尾追加 4 个 full: 名字(差异见 05-dns-*.diff)"
  r3_dns_restart "仪器条件生效" || return 2
}
r3_dns_calibrate(){   # K 的 U→H→U → 0 标定与还原都成立 / 2 不成立(R3_WHY; 磁盘与运行还原分别在 R3_CAL_DISK / R3_CAL_RUN)
  local fp0 m0 o0 r st=0 why="" l
  R3_CAL_DISK="未改动"; R3_CAL_RUN="未改动"
  r3_dns_rulematch "$R3_DNS_W" "$R3_DNS_K" "$R3_DNS_CPRE" "$R3_DNS_CPOST" "$R3_DNS_PPRE" "$R3_DNS_PPOST" || return 2
  printf '%s\n' "$R3_VAL" > "$EVID/05-dns-rulematch-calib.txt" 2>/dev/null || { R3_WHY="规则匹配表写不进证据目录"; return 2; }
  while IFS=$'\t' read -r l r; do echo "  I 规则匹配(mosdns 语义): $l ← ${r:-无}"; done <<<"$R3_VAL"
  r3_dns_path "$R3_DNS_K" calib-u1 U; r=$?
  (( r == 0 )) || { R3_WHY="标定第一段(K 不在接管表)不成立: $R3_WHY —— 接管表未改动"; return 2; }
  echo "  I 标定 U1: $R3_WHY"
  # 接管表原件: 指纹(sha256 / mode / owner)与内容都必须有效取得, 否则不改接管表
  r3_keepfp "$HIJ"; r=$?
  (( r == 0 )) || { R3_WHY="接管表原件指纹没取得($R3_WHY) —— 接管表未改动"; return 2; }
  fp0="$R3_VAL"; read -r _ m0 o0 <<<"$fp0"
  r3_copy_record "$HIJ" "$R3_TMP/hij.orig" || { R3_WHY="接管表原件内容没取得($R3_WHY) —— 接管表未改动"; return 2; }
  r3_copy_record "$HIJ" "$EVID/05-dns-mitm_hijack.orig.txt" || { R3_WHY="接管表原件留证失败($R3_WHY) —— 接管表未改动"; return 2; }
  r3_dns_append_full "$R3_TMP/hij.orig" "$R3_TMP/hij.calib" "$R3_DNS_K" || { R3_WHY="$R3_WHY —— 接管表未改动"; return 2; }
  r3_copy_record "$R3_TMP/hij.calib" "$EVID/05-dns-mitm_hijack.calib.txt" || { R3_WHY="标定用接管表留证失败($R3_WHY) —— 接管表未改动"; return 2; }
  diff -u "$EVID/05-dns-mitm_hijack.orig.txt" "$EVID/05-dns-mitm_hijack.calib.txt" > "$EVID/05-dns-mitm_hijack.calib.diff" 2>&1; r=$?
  (( r == 1 )) || { R3_WHY="标定用接管表的差异取不到(diff 退出 $r) —— 接管表未改动"; return 2; }
  R3_CAL_DISK="未核实"; R3_CAL_RUN="未核实"
  # ── 临时只追加 full:K(原有条目逐字保留)──
  if ! r3_dns_write "$R3_TMP/hij.calib" "$HIJ"; then st=2; why="临时追加 K: $R3_WHY"
  elif ! r3_dns_restart "标定: 接管表临时加 K"; then st=2; why="$R3_WHY"
  else
    r3_dns_path "$R3_DNS_K" calib-h H; r=$?
    if (( r == 0 )); then echo "  I 标定 H: $R3_WHY"; else st=2; why="标定第二段(K 临时接管)不成立: $R3_WHY"; fi
  fi
  # ── 还原: 不论上面成败都做; 磁盘与运行分别核验 ──
  if ! { cat -- "$R3_TMP/hij.orig" > "$HIJ"; } 2>/dev/null; then R3_CAL_DISK="失败(写回原件失败)"
  elif ! { chmod "$m0" -- "$HIJ" && chown "$o0" -- "$HIJ"; } 2>/dev/null; then R3_CAL_DISK="失败(属性设不回 $m0 $o0)"
  elif ! r3_keepfp "$HIJ"; then R3_CAL_DISK="未核实(还原后指纹没取得: $R3_WHY)"
  elif [[ "$R3_VAL" != "$fp0" ]]; then R3_CAL_DISK="失败(还原后指纹 [$R3_VAL], 原件 [$fp0])"
  elif ! cmp -s -- "$R3_TMP/hij.orig" "$HIJ"; then R3_CAL_DISK="失败(还原后内容与原件逐字节不同)"
  else R3_CAL_DISK="已核实"; fi
  if [[ "$R3_CAL_DISK" != 已核实 ]]; then R3_CAL_RUN="未核实(磁盘还原不成立, 不再重启)"
  elif ! r3_dns_restart "标定: 接管表还原"; then R3_CAL_RUN="未核实($R3_WHY)"
  else
    r3_dns_path "$R3_DNS_K" calib-u2 U; r=$?
    if (( r == 0 )); then R3_CAL_RUN="已核实"; echo "  I 标定 U2: $R3_WHY"; else R3_CAL_RUN="失败($R3_WHY)"; fi
  fi
  printf '标定名 %s; 接管表原件指纹 %s; 标定结果=%s; 磁盘还原=%s; 运行还原=%s\n' "$R3_DNS_K" "$fp0" "${why:-U→H 成立}" "$R3_CAL_DISK" "$R3_CAL_RUN" \
    >> "$EVID/05-dns-calibration.txt" 2>/dev/null || { st=2; why="${why:+$why; }标定记录写不进证据目录"; }
  echo "  I 标定还原: 磁盘 $R3_CAL_DISK; 运行 $R3_CAL_RUN"
  (( st == 0 )) || { R3_WHY="$why(还原: 磁盘 $R3_CAL_DISK, 运行 $R3_CAL_RUN)"; return 2; }
  [[ "$R3_CAL_DISK" == 已核实 && "$R3_CAL_RUN" == 已核实 ]] || { R3_WHY="U→H 成立, 但还原不成立(磁盘 $R3_CAL_DISK, 运行 $R3_CAL_RUN)"; return 2; }
}
r3_dns_instrument(){   # 仪器条件建立 → 标定 → 还原核验; 0 全成立 / 1 不成立(已打印; 调用方据此不调用)
  if ! r3_dns_adjust; then bad "③-0 DNS 仪器条件没建立: $R3_WHY"; return 1; fi
  ok "③-0 DNS 仪器条件已建立: 自有上游(U=$R3_DNS_U)只接 local_upstream; geosite_cn 追加 W / K / 两个分阶段对照名; 劫持模式与规则顺序未动(调整见 05-dns-*)"
  if ! r3_dns_calibrate; then bad "③-0 DNS 仪器标定不成立: $R3_WHY"; return 1; fi
  ok "③-0 DNS 仪器标定: 同一名字 K 在三个实例里按接管表那一行 U→H→U 精确切换, 来源各有上游记录为证; 接管表按内容与属性还原(磁盘与运行都已核实)"
}
r3_dns_say(){   # $1=前缀 $2=说明 $3=r3_dns_path 的返回码 → 打印判词; 0 成立 / 1 不成立
  case "$3" in
    0) ok "$1 $2 —— 成立: $R3_WHY"; return 0;;
    1) bad "$1 $2 —— 不成立: $R3_WHY";;
    3) bad "$1 $2 —— 来源证据不成立: $R3_WHY; 该功能结论未取得";;
    *) bad "$1 $2 —— 观测无效: $R3_WHY; 该功能结论未取得";;
  esac
  return 1
}
r3_dns_phase(){   # $1=pre|post → 0 仪器条件仍成立且 W / C / P 的期望路径全部成立 / 1 有不成立(逐项已打印)
  local lb c p ww wd r st=0 pok=0
  if [[ "$1" == pre ]]; then lb="③-0 前像 DNS"; c="$R3_DNS_CPRE"; p="$R3_DNS_PPRE"; ww=H; wd="W($R3_DNS_W)走接管 H、自有上游未收到: WLOC 接管在"
  else lb="③-4 F2"; c="$R3_DNS_CPOST"; p="$R3_DNS_PPOST"; ww=U; wd="W($R3_DNS_W)经 local_upstream 由自有上游取得 U: WLOC 接管已撤除"; fi
  r3_dns_conditions; r=$?
  if (( r == 1 )); then bad "$lb 仪器条件被改动: $R3_WHY —— 该功能结论未取得"; return 1
  elif (( r != 0 )); then bad "$lb 仪器条件观测失效: $R3_WHY —— 该功能结论未取得"; return 1; fi
  ok "$lb 仪器条件仍成立(自有上游同一进程; local_upstream 那一行与 geosite_cn 都是调整后的原样)"
  if ! r3_dns_rulematch "$p"; then bad "$lb P 规则匹配判不了: $R3_WHY —— 该功能结论未取得"; st=1
  elif [[ -n "${R3_VAL#*$'\t'}" ]]; then bad "$lb P 探针 $p 被规则匹配(${R3_VAL#*$'\t'}) —— 它不能代表普通劫持路径, 该功能结论未取得"; st=1
  else ok "$lb P 探针 $p 不被任何 domain_set 规则或内联 qname 匹配(按 mosdns 语义求值)"; pok=1; fi
  r3_dns_path "$R3_DNS_W" "$1-w" "$ww"; r3_dns_say "$lb" "$wd" $? || st=1
  r3_dns_path "$c" "$1-c" U; r3_dns_say "$lb" "C(独立上游对照 $c)经 local_upstream 取得 U" $? || st=1
  if (( pok )); then r3_dns_path "$p" "$1-p" H; r3_dns_say "$lb" "P(普通劫持探针 $p)走 H、自有上游未收到: 普通 DNS 代理劫持路径保留" $? || st=1
  else note "$lb P 的路径不判: 探针名的规则匹配核对没成立, 不作'普通 DNS 代理劫持路径保留'的结论"; fi
  return "$st"
}
# <<< PDG-EXTRACT-END r3_dns
# 运行态 / WLOC 前像门: 调用前逐项现查。契约测试在受控外部命令下执行它的判断原文(模型验证, 不冒充真实服务验收)。
# >>> PDG-EXTRACT-BEGIN r3_runtime_gate
r3_runtime_gate(){
  local okall=0 w rc l n_ent=0 n_other=0
  r3_stable_assert mosdns      running "③-0 前像: mosdns 持续运行" 5      || okall=1
  r3_stable_assert mihomo      running "③-0 前像: mihomo 持续运行" 5      || okall=1
  r3_stable_assert pdg-mitm    running "③-0 前像: pdg-mitm 持续运行(WLOC 开着)" 5 || okall=1
  r3_stable_assert pdg-probe81 running "③-0 前像: pdg-probe81 持续运行" 5 || okall=1
  if r3_unit_q enabled pdg-mitm; then
    [[ "$R3_VAL" == enabled ]] && ok "③-0 前像: pdg-mitm 自启 enabled" || { bad "③-0 前像: pdg-mitm 自启是 $R3_VAL(不是 enabled)"; okall=1; }
  else bad "③-0 前像观测无效: $R3_WHY"; okall=1; fi
  L7894_BEFORE=""
  if r3_listen_count 7894; then
    L7894_BEFORE="$R3_VAL"
    (( L7894_BEFORE > 0 )) && ok "③-0 前像: 7894 有监听($L7894_BEFORE)" || { bad "③-0 前像: 7894 无监听"; okall=1; }
  else bad "③-0 前像观测无效: $R3_WHY"; okall=1; fi
  r3_dns_phase pre || okall=1              # DNS 前像: W 走接管 H、C 取得 U、P 走普通劫持 H, 来源都以自有上游按名记录为据
  if r3_http_code http://127.0.0.1:81/; then
    [[ "$R3_VAL" == 200 ]] && ok "③-0 前像: :81 HTTP 200" || { bad "③-0 前像: :81 查询成功但状态码是 $R3_VAL(要 200)"; okall=1; }
  else bad "③-0 前像观测无效(:81): $R3_WHY"; okall=1; fi
  if python3 - "$IOS_META" "$IOS_ART/current.mobileconfig" "$MJ" <<'PY'
import json, os, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
cur = m.get("current") or {}
ok = (m.get("schema") == 1 and cur.get("inputs", {}).get("wloc_enabled") is True and os.path.isfile(sys.argv[2])
      and json.load(open(sys.argv[3], encoding="utf-8")).get("wloc", {}).get("enabled") is True)
sys.exit(0 if ok else 1)
PY
  then ok "③-0 前像: iOS 记录 schema 1、当前版 wloc_enabled=true 且产物在; mitm.json wloc.enabled=true"
  else bad "③-0 前像: iOS 记录 / mitm.json 不是'WLOC 开着的 schema 1'形态(或读不了)"; okall=1; fi
  # 接管表: 先整份读出并核退出码, 读失败不消费(读失败时空输出曾被当成"只有 gs-loc 条目")
  if w="$(cat -- "$HIJ" 2>/dev/null)"; then
    while IFS= read -r l; do
      l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
      [[ -z "$l" || "$l" == \#* ]] && continue
      n_ent=$((n_ent+1))
      [[ "$l" =~ ^(domain:|full:)?gs-loc(-cn)?\.apple\.com$ ]] || n_other=$((n_other+1))
    done <<<"$w"
    if (( n_ent > 0 && n_other == 0 )); then ok "③-0 前像: 接管表非空且只有 gs-loc 条目($n_ent 条)"
    else bad "③-0 前像: 接管表条目 $n_ent 条, 其中 gs-loc 以外 $n_other 条"; okall=1; fi
  else bad "③-0 前像观测无效: 接管表 $HIJ 读不了"; okall=1; fi
  r3_grepq 'MITM-OUT' "$MC"; rc=$?
  case "$rc" in 0) ok "③-0 前像: 内核配置含 MITM-OUT";; 1) bad "③-0 前像: 内核配置没有 MITM-OUT"; okall=1;;
                *) bad "③-0 前像观测无效: 内核配置读不了($R3_WHY)"; okall=1;; esac
  return "$okall"
}
# <<< PDG-EXTRACT-END r3_runtime_gate
# >>> PDG-EXTRACT-BEGIN r3_post
r3_post_w1(){   # 调用后 W1: pdg-mitm unit 文件、LoadState / is-active、7894 监听; 观测无效 ⇒ 本项判失败, 不输出撤除成功
  local ld ac
  if [[ -e "$R3_MITM_UNIT" ]]; then bad "③-3 W1 pdg-mitm unit 文件还在"; else ok "③-3 W1 pdg-mitm unit 文件已删"; fi
  if ! r3_unit_q load pdg-mitm; then bad "③-3 W1 观测无效: $R3_WHY"
  else
    ld="$R3_VAL"
    if ! r3_unit_q active pdg-mitm "$ld"; then bad "③-3 W1 观测无效: $R3_WHY"
    else
      ac="$R3_VAL"
      if [[ "$ld" == not-found && "$ac" != active ]]; then ok "③-3 W1 pdg-mitm LoadState=not-found, is-active=$ac"
      else bad "③-3 W1 pdg-mitm LoadState=[$ld] is-active=[$ac]"; fi
    fi
  fi
  if r3_listen_count 7894; then
    [[ "$R3_VAL" == 0 ]] && ok "③-3 W1 7894 已无监听(之前 ${L7894_BEFORE:-?})" || bad "③-3 W1 7894 仍有监听($R3_VAL)"
  else bad "③-3 W1 观测无效: $R3_WHY"; fi
}
r3_post_runtime(){   # 调用后 ③-4: 运行 / 自启态与真实功能; 观测无效或命令失败 ⇒ 本项判失败 / 未取得, 不输出功能成立
  local u
  r3_stable_assert mosdns      running "③-4 运行态: mosdns 持续运行" 5
  r3_stable_assert mihomo      running "③-4 运行态: mihomo 持续运行" 5
  r3_stable_assert pdg-probe81 running "③-4 运行态: pdg-probe81 持续运行" 5
  for u in mosdns mihomo pdg-probe81; do
    if r3_unit_q enabled "$u"; then [[ "$R3_VAL" == enabled ]] && ok "③-4 自启态: $u = enabled" || bad "③-4 自启态: $u = $R3_VAL"
    else bad "③-4 自启态观测无效: $R3_WHY"; fi
  done
  for u in pdg-dotwitness pdg-health.timer; do
    if r3_unit_q active "$u"; then [[ "$R3_VAL" == active ]] && ok "③-4 $u 仍 active" || bad "③-4 $u = $R3_VAL"
    else bad "③-4 运行态观测无效: $R3_WHY"; fi
  done
  if r3_http_code http://127.0.0.1:81/; then
    [[ "$R3_VAL" == 200 ]] && ok "③-4 F1 实际功能: :81 HTTP 200" || bad "③-4 F1 :81 查询成功但状态码是 $R3_VAL(要 200)"
  else bad "③-4 F1 功能观测未取得: $R3_WHY —— 不算通过"; fi
  r3_dns_phase post                        # 先核仪器条件仍成立, 再判 W→U / C→U / P→H 与各自来源; 条件或观测失效 ⇒ 该功能结论未取得
}
# <<< PDG-EXTRACT-END r3_post

snap_state "retire-before"      # 仅留档, 不参与任何判据

# ── 门 + 调用前观测 + 唯一升级入口 ─────────────────────────────────────────────
SECT "③-1 门全过、调用前观测取全才调用: 现役桥接 CLI 执行 update --to $RETIRE_TAG"
_cnt_say(){ if r3_count_read; then printf '%s' "$R3_VAL"; else printf '读不出(%s)' "$R3_WHY"; fi; }
r3_gated_invoke; GRC=$?
case "$GRC" in
  0) ;;
  10) bad "③-0 ② 的结果门不成立 —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ③: ② 不成立"; e2e_summary; exit 1;;
  11) bad "③-0 桥接身份门不成立(见上面逐项) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ③: 桥接前像不成立"; e2e_summary; exit 1;;
  15) bad "③-0 DNS 仪器条件 / 标定 / 还原核验不成立(见上面 I 项) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ③: DNS 仪器不成立"; e2e_summary; exit 1;;
  12) bad "③-0 运行态 / WLOC 前像门不成立 —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ③: 桥接前像不成立"; e2e_summary; exit 1;;
  13) bad "③-0 调用前观测没取全(见上面 E 项) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ③: 调用前观测不全"; e2e_summary; exit 1;;
  14) bad "③-0 调用计数或退出码留档不可用(见上) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ③: 计数不可用"; e2e_summary; exit 1;;
  *)  bad "③-0 门返回了未登记的值 $GRC —— 按未执行处理"; nrun "场景 ③: 门状态不明"; e2e_summary; exit 1;;
esac
ok "③-0 ② 结果门、桥接身份门、DNS 仪器(条件 / 标定 / 还原)、运行态 / WLOC 前像门全部成立且调用前观测取全后才调用(调用计数 $(_cnt_say))"
C3_1="$(_j_mark retire-end)" || { C3_1=""; note "阶段记账: 止界桩没建成($(_j_why)) —— 窗口将判观测无效"; }
cp "$R3_LOG" "$EVID/04-retire-update.log" 2>/dev/null && chmod 600 "$EVID/04-retire-update.log" 2>/dev/null \
  || note "升级日志没能复制进证据目录"
cp "$R3_RCFILE" "$EVID/04-retire-update.rc" 2>/dev/null; cp "$R3_TOERR" "$EVID/04-retire-update.timeout-stderr" 2>/dev/null
tail -40 "$R3_LOG" 2>/dev/null | sed 's/^/    /'

SECT "③-2 逐维验收"
r3_arrival_verdict && ok "③-2 进程状态 / 目标到达 / 观测有效性分别成立" \
                   || bad "③-2 进程 $R3_PROC / 目标到达 $R3_ARRIVE / 观测 $R3_OBS —— 不成立"
_evn 03-retire-identity.txt "workflow checkout = ${GITHUB_SHA:-<非 CI>}"
_evn 03-retire-identity.txt "桥接 = $BRIDGE_TAG → $BRIDGE_SHA; 退役 = $RETIRE_TAG → $RETIRE_SHA; 取件源 = $R3_ORIGIN"
_evn 03-retire-identity.txt "调用 = bash $R3_CLI update --to $RETIRE_TAG(经 timeout --verbose $R3_TIMEOUT); 调用计数 = $(_cnt_say); 包装器(timeout)返回码 = ${R3_WRAP_RC:-未取得}; 产品原始退出码 = ${R3_RC:-未取得}"
if r3_modules "$R3_RTSRC" "$R3_MODDIR"; then
  _m="$R3_VAL"
  [[ "${_m#* }" == 0 ]] && ok "③-2 A4 ios 模块 ${_m% *} 项逐字节 = 退役树" || bad "③-2 A4 ios 模块有 ${_m#* } 项与退役树不同(共 ${_m% *})"
else bad "③-2 A4 观测无效: $R3_WHY"; fi
if r3_lsdir "$SNAPROOT"; then
  SNAP_AFTER="$R3_VAL"
  if r3_snapdiff "$SNAP_BEFORE" "$SNAP_AFTER"; then
    _new="$R3_VAL"
    if [[ "$(grep -c . <<<"$_new")" == 1 && -s "$SNAPROOT/$_new/snap.tar.gz" && -s "$SNAPROOT/$_new/svcstate.tsv" ]]; then
      ok "③-2 A6 本次升级由产品新建了 1 个快照($_new, 含 snap.tar.gz 与 svcstate.tsv)"
    else bad "③-2 A6 新快照不是恰 1 个或缺件(新增: [$(tr '\n' ' ' <<<"$_new")])"; fi
  else bad "③-2 A6 观测无效: $R3_WHY"; fi
else bad "③-2 A6 观测无效: 调用后快照目录清单没取得($R3_WHY)"; fi

SECT "③-3 WLOC 撤除 / 保留 / 迁移"
r3_post_w1
for _f in /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py; do
  [[ -e "$_f" ]] && bad "③-3 W2 $_f 还在" || ok "③-3 W2 $_f 已删"
done
if [[ ! -e "$HIJ" ]]; then ok "③-3 W3 接管表不存在(无条目)"
elif _raw="$(cat -- "$HIJ" 2>/dev/null)"; then
  _hn=0
  while IFS= read -r _l; do
    _l="${_l#"${_l%%[![:space:]]*}"}"
    [[ -z "$_l" || "$_l" == \#* ]] || _hn=$((_hn+1))
  done <<<"$_raw"
  [[ "$_hn" == 0 ]] && ok "③-3 W3 接管表无条目(文件在)" || bad "③-3 W3 接管表仍有 $_hn 条"
else bad "③-3 W3 观测无效: 接管表读不了"; fi
r3_grepq 'MITM-OUT' "$MC"; _g=$?
case "$_g" in 1) ok "③-3 W4 内核配置里已无 MITM-OUT";; 0) bad "③-3 W4 内核配置里仍有 MITM-OUT";; *) bad "③-3 W4 观测无效: 内核配置读不了($R3_WHY)";; esac
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
  case "$_l" in "OK   "*) ok "③-3 ${_l#OK   }";; "FAIL "*) bad "③-3 ${_l#FAIL }";; *) note "③-3 $_l";; esac
done < "$R3_TMP/w56.txt"
(( _w56 == 0 || _w56 == 3 )) || bad "③-3 W5/W6 观测无效: 核对脚本异常退出($_w56) —— 记录读不了"
for _p in '✅ WLOC 位置改写及其专属 MITM 执行能力已退役|W7 产品自报 WLOC 执行能力已退役' \
          '✅ iOS 描述文件记录已迁移到新格式|W7 产品自报 iOS 记录已迁到新格式' \
          '盘上仍有 WLOC 时期的 CA 材料|K1 产品按保留策略报告 CA 材料仍在'; do
  r3_grepq -F "${_p%%|*}" "$R3_LOG"; _g=$?
  case "$_g" in 0) ok "③-3 ${_p#*|}";; 1) bad "③-3 ${_p#*|}: 日志里没有「${_p%%|*}」";; *) bad "③-3 ${_p#*|}: 观测无效($R3_WHY)";; esac
done
r3_keep_verdict
if _p="$(cat -- "$R3_ETC/platform" 2>/dev/null)"; then
  [[ "$_p" == ios ]] && ok "③-3 K2 平台标记仍是 ios" || bad "③-3 K2 平台标记变了([$_p])"
else bad "③-3 K2 观测无效: 平台标记读不了"; fi

SECT "③-4 服务与真实功能"
r3_post_runtime

snap_state "retire-after"; bridge_svc_sample "$R3_TMP/svc-retire-after.tsv" || note "调用后服务采样写不出来 —— 对账将判集合不全"
WIN_TSV="$R3_TMP/svc-retire-window.tsv"; : > "$WIN_TSV"
for _u in "${SVC_WATCH[@]}"; do
  if [[ -z "${C3_0:-}" || -z "${C3_1:-}" ]]; then printf '%s\tINVALID\t界桩没建成: %s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"; continue; fi
  if _n="$(_j_interval "$_u" "$C3_0" "$C3_1")" && [[ -n "$_n" ]]; then printf '%s\t%s\t-\n' "$_u" "$_n" >> "$WIN_TSV"
  else printf '%s\tINVALID\t%s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"; fi
done
sed 's/^/    /' "$WIN_TSV"
r3_svc_verdict "$R3_TMP/svc-retire-before.tsv" "$R3_TMP/svc-retire-after.tsv" retire "$WIN_TSV"
cp "$R3_TMP/svc-retire-before.tsv" "$R3_TMP/svc-retire-after.tsv" "$WIN_TSV" "$EVID/" 2>/dev/null
chmod 600 "$EVID"/* 2>/dev/null || true

SECT "③-5 收尾"
{
  echo "# 本支在这台一次性 runner 上的动作: 只有一次 bash $R3_CLI update --to $RETIRE_TAG(调用计数 $(_cnt_say))"
  echo "# 前像来源: 同一 job 上一步 ② 的真实现场(本支调用前逐项现查), 调用前经 DNS 仪器调整(05-dns-instrument-adjustments.txt); 取件源 $R3_ORIGIN"
  echo "# DNS 仪器重启 $R3_DNS_RESTARTS 次(05-dns-instrument-restarts.txt), 都在调用前观测起界桩之前, 不计入升级服务窗口"
  echo "# 退出码: 包装器(timeout)返回码 ${R3_WRAP_RC:-未取得}; 产品原始退出码 ${R3_RC:-未取得}"
  echo "# 窗口口径: journal 'Started <unit>' 条数 —— 不是完整的服务动作审计(停止 / 禁用 / reload / socket 激活不在其内)"
  echo "# 不覆盖: ④ 晚期失败恢复、v1.7.8、完整旧安装器、官方分发来源、发布"
  echo "# 证据文件"; ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-retire-summary.txt
echo; echo "未执行(前像/前置不成立而跳过)的场景数: $E2E_NOTRUN"
e2e_summary
