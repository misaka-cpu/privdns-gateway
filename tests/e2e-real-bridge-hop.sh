#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 ②: **v1.11.15 → 桥接版, 走公开的显式目标入口 `install.sh --ref <版本 tag>`**。
#
# 这一跳只验这一跳: 装上去的必须是**指定的桥接版**(不是版本号更高的退役目标), 桥接该带的
# 前像保存/恢复能力确实到位, 而 WLOC 退役、iOS 记录格式推进、旧产物/CA 删除 **一件都不许发生**。
# 不接着跑 ③(桥接→退役)或 ④, 也不做发布或生产部署。
#
# 关键: 这一跳由**真实公开入口**完成 —— 取一份新版 install.sh(相当于 curl 官方 raw),
# 带 `--ref` 跑, 让它自己走两段自举、自己 fetch/checkout。**不允许**直接把新版 pdg.sh
# 复制过去然后说"安装通过", 也不向旧调用方伪造任何服务前像凭据。
#
# 前提(缺一即硬停, 不 SKIP、不退回桩): 真 systemd / 真 systemctl / 真 nft /
# 钉死版 mosdns+mihomo 已就位 / git python3 openssl ss 齐备; 只许在一次性 runner 上跑。
#
# 源映射(测试专用, 可审计): 自有一次性裸库, 里面放三个**真实对象**:
#   v1.11.15(官方真 tag 对象) / v9.9.8-bridge-TEST(桥接候选) / v9.9.9-retire-TEST(退役候选)。
#   后两个 tag 名是"仅测试"的合成名, 只存在于这个裸库; 官方仓库一个字节不动, 不推 tag、不发 Release。
#   裸库 refs/heads/main → 桥接候选(相当于"官方 main 上的最新入口脚本")。
#   **本支通过 ≠ 正式发布来源已验证。**
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
E2E_ROOT_REAL="$E2E_ROOT"

_hard(){ echo "[HARD-STOP] $1" >&2; exit 1; }
[[ "${PDG_REAL_MIGRATION_OK:-}" == 1 ]] || _hard "缺 PDG_REAL_MIGRATION_OK=1 —— 这支会真的改本机 systemd 与 /etc。"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || _hard "不在 GitHub Actions 里 —— 拒绝在开发机/生产机上执行。"
[[ "${RUNNER_OS:-}" == "Linux" ]] || _hard "RUNNER_OS=${RUNNER_OS:-<空>}, 只支持 Linux runner。"
[[ "$(id -u)" == 0 ]] || _hard "需要 root。"
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || _hard "需要 PDG_E2E_ISOLATED=1。"

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
EVID="${PDG_REAL_MIG_EVID:-${TMPDIR:-/tmp}/real-migration-evidence}"
mkdir -p "$EVID" && chmod 700 "$EVID"

PLAT_SRC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
[[ -f "$PLAT_SRC" ]] || _hard "找不到 $PLAT_SRC(要从它原文取前像与状态采集那几支)"
# ── 按**唯一成对标记**定点抽函数原文 ────────────────────────────────────────
# 上一次(run 34976950055)栽在这: 抽法是"从 name(){ 读到第一行顶格 }", 而 build_preimage
# 里写 mitm.json 的那段 heredoc 正文就有一行顶格 } —— 抽取在那里提前收尾, 把 EOF 和后面的
# 代码全切了, eval 当场语法错, 前像根本没开始建。
# 现在改成: 只认来源脚本里那对 `# >>> PDG-EXTRACT-BEGIN <名字>` / `# <<< PDG-EXTRACT-END <名字>`
# 注释标记(它们只是注释, 不改被抽函数的任何行为)。规矩:
#   · 标记必须唯一、成对、BEGIN 在 END 之前 —— 缺失/重复/倒置一律当场拒绝;
#   · 片段必须以 `<名字>(){` 开头、以顶格 `}` 结尾(heredoc、闭合符、函数尾一个都不少);
#   · 每个片段先**单独** bash -n, 全部拼成一个加载单元后**再** bash -n;
#   · 只有都过了才 source; 任何一步失败就 _hard —— 不进前像构造、不动任何服务;
#   · 绝不 source 整支来源脚本(它有运行副作用)。
EXTRACT_NAMES=(_ev _evn SECT note sc_get sc_state nrun snap_state reset_units_strict reset_proof
               build_preimage wait_stable unit_identify
               _unit_wants_mainpid svc_stable_window svc_stable_assert mitm_listen_verdict
               _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after
               _j_tag_after _j_interval)
# >>> PDG-EXTRACT-BEGIN extract_marked_fns
extract_marked_fns(){   # $1=来源脚本 $2=落点(加载单元) $3..=函数名 → 0 成功 / 非 0 并具名说明
  local src="$1" out="$2"; shift 2
  local n b e nb ne frag tmp rc=0
  [[ -f "$src" ]] || { echo "抽取: 找不到来源 $src" >&2; return 2; }
  : > "$out" || { echo "抽取: 写不了落点 $out" >&2; return 2; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/frag.XXXXXX")" || { echo "抽取: 建不出临时文件" >&2; return 2; }
  for n in "$@"; do
    nb="$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")"
    ne="$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")"
    if [[ "$nb" != 1 || "$ne" != 1 ]]; then
      echo "抽取: $n 的标记不是唯一成对(BEGIN $nb 个 / END $ne 个)" >&2; rc=1; break
    fi
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
    e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
    if (( b >= e )); then echo "抽取: $n 的标记顺序不对(BEGIN 在第 $b 行, END 在第 $e 行)" >&2; rc=1; break; fi
    # 相邻两行 = 标记之间根本没有内容。必须显式判: sed 的倒置范围会**只打一行**, 靠 -z 兜不住。
    if (( e - b < 2 )); then echo "抽取: $n 的标记之间是空的(BEGIN 第 $b 行, END 第 $e 行)" >&2; rc=1; break; fi
    frag="$(sed -n "$((b+1)),$((e-1))p" "$src")"
    if [[ -z "$frag" ]]; then echo "抽取: $n 的标记之间是空的" >&2; rc=1; break; fi
    if ! grep -q "^$n(){" <<<"$frag"; then echo "抽取: $n 的片段不是以 $n(){ 开头" >&2; rc=1; break; fi
    if ! { [[ "$(tail -1 <<<"$frag")" == "}" ]] || [[ "$(tail -1 <<<"$frag")" =~ \}[[:space:]]*(#.*)?$ ]]; }; then
      echo "抽取: $n 的片段结尾不是函数闭合(实得: $(tail -1 <<<"$frag"))" >&2; rc=1; break
    fi
    printf '%s\n' "$frag" > "$tmp"
    if ! bash -n "$tmp" 2>"$tmp.err"; then
      echo "抽取: $n 的片段单独语法检查不过: $(head -2 "$tmp.err" | tr '\n' ' ')" >&2; rc=1; break
    fi
    printf '%s\n' "$frag" >> "$out"
  done
  rm -f "$tmp" "$tmp.err"
  (( rc == 0 )) || return "$rc"
  if ! bash -n "$out" 2>"$out.err"; then
    echo "抽取: 组合后的加载单元语法检查不过: $(head -2 "$out.err" | tr '\n' ' ')" >&2; return 1
  fi
  rm -f "$out.err"
  return 0
}
# <<< PDG-EXTRACT-END extract_marked_fns
EXTRACT_UNIT="${E2E_TMP:-${TMPDIR:-/tmp}}/plat-fns.sh"
extract_marked_fns "$PLAT_SRC" "$EXTRACT_UNIT" "${EXTRACT_NAMES[@]}" \
  || _hard "函数抽取没通过(见上一行) —— 前像构造与任何服务动作都还没开始, 就停在这里。"
# ── 依赖声明: 抽出来的函数还要读来源脚本的**顶层常量数组** ────────────────────
# 上一次(run 34978387896)栽在这: 只搬了函数, 没搬 E2E_OWNED_UNITS —— set -u 下当场
# unbound, reset_units_strict 半路崩, 前像一件没建成。这里把依赖同样按标记搬过来,
# **不允许**用空数组占位: 空的/缺的/不像 unit 名的都当场停。
EXTRACT_DEPS=(E2E_OWNED_UNITS SVC_WATCH)
DEPS_UNIT="${E2E_TMP:-${TMPDIR:-/tmp}}/plat-deps.sh"
# >>> PDG-EXTRACT-BEGIN extract_marked_decls
extract_marked_decls(){   # $1=来源 $2=落点 $3..=常量名 → 与函数抽取同一套边界规矩
  local src="$1" out="$2"; shift 2
  local n b e nb ne frag tmp rc=0
  : > "$out" || { echo "依赖抽取: 写不了落点 $out" >&2; return 2; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/dep.XXXXXX")" || { echo "依赖抽取: 建不出临时文件" >&2; return 2; }
  for n in "$@"; do
    nb="$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")"
    ne="$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")"
    if [[ "$nb" != 1 || "$ne" != 1 ]]; then echo "依赖抽取: $n 的标记不是唯一成对(BEGIN $nb / END $ne)" >&2; rc=1; break; fi
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
    e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
    if (( e - b < 2 )); then echo "依赖抽取: $n 的标记之间是空的" >&2; rc=1; break; fi
    frag="$(sed -n "$((b+1)),$((e-1))p" "$src")"
    grep -q "^$n=(" <<<"$frag" || { echo "依赖抽取: $n 的片段不是以 $n=( 开头" >&2; rc=1; break; }
    printf '%s\n' "$frag" > "$tmp"
    bash -n "$tmp" 2>"$tmp.err" || { echo "依赖抽取: $n 片段语法不过: $(head -1 "$tmp.err")" >&2; rc=1; break; }
    printf '%s\n' "$frag" >> "$out"
  done
  rm -f "$tmp" "$tmp.err"
  (( rc == 0 )) || return "$rc"
  bash -n "$out" 2>"$out.err" || { echo "依赖抽取: 组合单元语法不过: $(head -1 "$out.err")" >&2; return 1; }
  rm -f "$out.err"; return 0
}
# <<< PDG-EXTRACT-END extract_marked_decls
extract_marked_decls "$PLAT_SRC" "$DEPS_UNIT" "${EXTRACT_DEPS[@]}" \
  || _hard "依赖声明抽取没通过(见上一行) —— 停在前像之前, 不拿空数组顶上。"
# shellcheck source=/dev/null
source "$EXTRACT_UNIT" || _hard "加载抽取单元失败 —— 同样停在前像之前。"
# shellcheck source=/dev/null
source "$DEPS_UNIT" || _hard "加载依赖声明失败 —— 同样停在前像之前。"
for _f in "${EXTRACT_NAMES[@]}"; do
  declare -F "$_f" >/dev/null || _hard "抽取单元里少了 $_f"
done
# ── 依赖自检 + **真实消费者**验证(不是只看变量在不在)────────────────────────
# >>> PDG-EXTRACT-BEGIN deps_selfcheck
deps_selfcheck(){
  local n cnt bad=0 u; local -a arr
  for n in "${EXTRACT_DEPS[@]}"; do
    declare -p "$n" >/dev/null 2>&1 || { echo "依赖自检: $n 根本没声明" >&2; return 1; }
    local -n _ref="$n"                       # nameref: 不用 eval 也能按名字读数组
    cnt="${#_ref[@]}"
    (( cnt > 0 )) || { echo "依赖自检: $n 是空数组 —— 空集合会让判据变成恒真, 不接受" >&2; return 1; }
    arr=("${_ref[@]}")
    unset -n _ref
    for u in "${arr[@]}"; do
      [[ "$u" =~ ^[A-Za-z0-9@._-]+$ ]] || { echo "依赖自检: $n 里有不像 unit 名的元素: [$u]" >&2; bad=1; }
    done
  done
  (( bad == 0 )) || return 1
  # 真实消费者: 让**本支真正会用的那支采样器** bridge_svc_sample 按 SVC_WATCH 采一遍,
  # 再用本支真正会用的那支集合判据 bridge_set_check 核名称/唯一性/完整性 —— 不是只数行。
  local probe; probe="$(mktemp "${TMPDIR:-/tmp}/depprobe.XXXXXX")" || return 1
  bridge_svc_sample "$probe" || { echo "依赖自检: bridge_svc_sample 跑不起来" >&2; rm -f "$probe"; return 1; }
  local setmsg
  if ! setmsg="$(bridge_set_check "$probe" 依赖自检)"; then
    echo "依赖自检: $setmsg" >&2; rm -f "$probe"; return 1
  fi
  if awk -F'\t' 'NF!=13{bad=1} END{exit bad+0}' "$probe"; then :; else
    echo "依赖自检: bridge_svc_sample 的记录字段数不是 13" >&2; rm -f "$probe"; return 1
  fi
  rm -f "$probe"
  # E2E_OWNED_UNITS 的真实消费者是 reset_units_strict; 这里不真去停服务, 只核它读得到、
  # 且每一项都是本轮确实管得着的 unit 名(带 .service/.timer/.socket 后缀)。
  for u in "${E2E_OWNED_UNITS[@]}"; do
    [[ "$u" == *.service || "$u" == *.timer || "$u" == *.socket ]] \
      || { echo "依赖自检: E2E_OWNED_UNITS 里 [$u] 没有 unit 后缀" >&2; return 1; }
  done
  return 0
}
# <<< PDG-EXTRACT-END deps_selfcheck
# **调用点不在这里**: deps_selfcheck 会调 bridge_svc_sample 与 bridge_set_check, 而那两支
# 定义在本文件后面。bash 是顺序读入并定义函数的 —— 在这里调等于调一个还没进符号表的名字,
# 于是依赖自检**必然**失败, 真实验收在前像之前就永远停住(隔离复现: order.sh)。
# 真正的调用挪到"全部必要定义 + 依赖加载"都完成之后、③ 前像构造与任何服务动作之前。
# 这几个是给上面 eval 进来的那些原文函数读的(界桩/前像/状态采集), 本文件自己不直接引用
# shellcheck disable=SC2034
JBOUND_TAG="pdg-e2e-jbound"
# shellcheck disable=SC2034
J_ERR=""
E2E_NOTRUN=0; PREIMAGE_OK=1
OLD_SHA="${PDG_OLD_SHA:-242602c17bd92900df81f468aae8c66e18c7a4ff}"     # v1.11.15 peeled
BRIDGE_SHA="${PDG_BRIDGE_SHA:-}"; RETIRE_SHA="${PDG_RETIRE_SHA:-}"
[[ -n "$BRIDGE_SHA" ]] || _hard "必须显式给出桥接候选 SHA(PDG_BRIDGE_SHA)"
[[ -n "$RETIRE_SHA" ]] || _hard "必须显式给出退役候选 SHA(PDG_RETIRE_SHA; 只用来证明它**没**被误装)"
OLD_TAG="v1.11.15"; BRIDGE_TAG="v9.9.8-bridge-TEST"; RETIRE_TAG="v9.9.9-retire-TEST"
ORIGIN="$E2E_TMP/origin.git"; OLDSRC="$E2E_TMP/oldsrc"; BRSRC="$E2E_TMP/brsrc"; REPO=/opt/privdns-gateway
# shellcheck disable=SC2034
TEST_TAG="$BRIDGE_TAG"   # build_preimage 会用它把新 tag 从工作副本里删掉, 逼取件真去 fetch

# ── 桥接这一跳的**允许动作清单**: 从冻结桥接候选的 cmd_update 实际调用链推导 ────────
# 入口换成 `pdg.sh update --to` 之后, 这一跳跑的**不再是** install.sh —— 所以清单也必须
# 换源头。下面每一条都逐处核对过冻结桥接候选 9c9b268 的 deploy/bot/pdg.sh(行号即该文件):
#
#   cmd_update 自己(迁移之后):
#     2777 daemon-reload                       2780 enable --now pdg-health.timer
#     2781 restart pdg-bot pdg-probe81         2782 restart pdg-mitm(先 is-enabled 再 reset-failed)
#     _update_mosdns_binary / _update_core_binary → _core_restart_clean:1995 restart <内核 svc>
#   `pdg __migrate` → run_all_migrations 里按序调的那些(只列会动服务的):
#     migrate_mihomo_safepaths:4084  restart mihomo
#     migrate_mosdns_concurrent:599/603 · _unlock:646/650 · _ratelimit:687/691 ·
#       _hijack_shape:5108 · _explicit_proxy:5179/5185 · _mitm:4432/4436 ·
#       ruleset_hijack:5233/5239 · custom_hijack:5083 · adblock:8360/8363   → restart mosdns
#     migrate_deploy_botfiles:4251   try-restart(bot 相关 unit)
#     migrate_deploy_units:4122      daemon-reload
#     migrate_dotwitness:4626 enable --now pdg-dotwitness · 4629 restart pdg-dotwitness ·
#                        4596/4617 restart mosdns
#     migrate_health_timer:4163/4194/4210 enable · 4168/4213 restart · 4200 start(pdg-health.timer)
#     migrate_pdg_mitm_service:4453  enable --now pdg-mitm
#     migrate_probe81_public:4737 enable --now pdg-probe81 · 4744 restart pdg-probe81
#     migrate_ios_gms_cleanup:4965/5018 restart <内核 svc>
#     migrate_lowmem → _migrate_journald_cap:268/281 restart systemd-journald ·
#                      _migrate_mosdns_cache:252/254 restart mosdns
#
# 链上**唯一**会 stop/disable 的几处, 各有明确前提, 都不属于本跳的成功路径:
#     migrate_android_cleanup:4778 disable --now pdg-mitm  ← **只在 Android 平台**; 本跳是 iOS
#     migrate_dotwitness:4589/4593 disable/stop pdg-dotwitness ← 只在 witness 迁移**自身回滚**时,
#         而 `migrate_dotwitness || rc=1` 会让整次更新回滚 —— 成功路径上不该看到
#     migrate_drop_singbox → _pdg_drop_singbox_files:69/76 disable --now sing-box ← 本跳夹具不装 sing-box
#     _pdg_restore_svcstate:1689 stop ← 只在**回滚**里按前像复原, 不是升级动作
# 所以: 重启允许发生(上面每一条都点得出来源); 停止 / 禁用 / 删除**一律另判**, 不并进"正常"。
# 采样与裁决分离的两条铁律:
#   1. **采样时**就把该次查询的值、退出码、错误信息一并落进行里, 并当场判这一行有没有效。
#      裁决时**不许**再查一次 —— 拿裁决时的新查询给历史采样补证, 等于"当时读坏了, 后来
#      读好了就算当时也好"; 那正是要挡住的假绿。
#   2. 集合核对按**名称 + 唯一性 + 完整性**, 不是只数行。行数相同但名字不同、或者用重复行
#      顶掉缺的那一项, 都能凑出"行数对得上"。
# >>> PDG-EXTRACT-BEGIN bridge_svc_sample
bridge_svc_sample(){   # $1=落点。每行 13 列, 末两列是**采样当时**算出的探针摘要与有效性。
  local out="$1" u id kind typ load act sub ufs pid inv nr why probe qfail
  local errf="${E2E_TMP:-${TMPDIR:-/tmp}}/sample.err"
  : > "$out" || return 1
  # ── show 查询: 每一次都看 rc 与 stderr, 失败当场具名记账 ────────────────────
  # 判据分两条, 缺一不可:
  #   · rc != 0                         → 查询失败;
  #   · rc == 0 但 stdout 空而 stderr 有 → 同样是查询失败(命令自己报了错)。
  # 记账写进 $why 并累加进 $qfail, **后一次查询不会抹掉前一次的错误** ——
  # $why 只追加, 从不重置; 每个字段的"这次查询成不成"由各自的 q_* 标志单独留着。
  # 返回 0 = 这次查询成功(值可能合法地为空); 1 = 查询失败(SV 已清空, 不许再当"值")。
  _showq(){
    SV="$(systemctl show -p "$1" --value "$2" 2>"$errf")"; SRC=$?
    SERR="$(tr '\n' ' ' < "$errf" 2>/dev/null)"
    if (( SRC != 0 )); then
      why="${why}${1} 查询失败(rc=$SRC${SERR:+, stderr: ${SERR}});"; qfail="${qfail}${1}/rc=$SRC,"; SV=""; return 1
    fi
    if [[ -z "${SV//[[:space:]]/}" && -n "${SERR//[[:space:]]/}" ]]; then
      why="${why}${1} 无值却有错误输出(rc=0, stderr: ${SERR}) —— 按查询失败处理;"; qfail="${qfail}${1}/rc=0+err,"; SV=""; return 1
    fi
    return 0
  }
  # ── is-active / is-enabled: **返回码有意义**, 与 show 查询失败不是一回事 ──────
  # inactive 回 3、disabled 回 1 都是**答案**; 只有"无值"才需要看 stderr 区分
  # "没有这个 unit"(答案)与"查询失败"(无效)。
  _query(){ QV="$(systemctl "$1" "$2" 2>"$errf")"; QRC=$?; QERR="$(tr '\n' ' ' < "$errf" 2>/dev/null)"
            QV="${QV%%$'\n'*}"; }
  for u in "${SVC_WATCH[@]}"; do
    why=""; qfail=""
    local q_id=1 q_load=1 q_act=1 q_sub=1 q_ufs=1 q_pid=1 q_inv=1 q_nr=1 q_typ=1
    _showq Id "$u"           || q_id=0;   id="$SV"
    _showq LoadState "$u"    || q_load=0; load="$SV"
    _showq ActiveState "$u"  || q_act=0;  act="$SV"
    _showq SubState "$u"     || q_sub=0;  sub="$SV"
    _showq UnitFileState "$u"|| q_ufs=0;  ufs="$SV"
    _showq MainPID "$u"      || q_pid=0;  pid="$SV"
    _showq InvocationID "$u" || q_inv=0;  inv="$SV"
    _showq NRestarts "$u"    || q_nr=0;   nr="$SV"
    kind=unknown
    case "$id" in *.timer) kind=timer;; *.socket) kind=socket;; *.service) kind=service;;
                  "") kind=unknown;; *) kind=other;; esac
    typ=n/a
    if [[ "$kind" == service ]]; then _showq Type "$u" || q_typ=0; typ="$SV"; fi
    _query is-active "$u";  probe="isa=${QV:-<无值>}/${QRC}"
    if [[ -z "${QV//[[:space:]]/}" ]]; then
      case "$QERR" in
        *"No such file"*|*not-found*|*"could not be found"*) probe="${probe}(not-found 是答案)";;
        "") why="${why}is-active 无值且 stderr 为空(rc=$QRC) —— 查询失败;";;
        *)  why="${why}is-active 查询失败(rc=$QRC, stderr: ${QERR});";;
      esac
    fi
    _query is-enabled "$u"; probe="$probe;ise=${QV:-<无值>}/${QRC}"
    if [[ -z "${QV//[[:space:]]/}" ]]; then
      case "$QERR" in
        *"No such file"*|*not-found*|*"could not be found"*) probe="${probe}(not-found 是答案)";;
        "") why="${why}is-enabled 无值且 stderr 为空(rc=$QRC) —— 查询失败;";;
        *)  why="${why}is-enabled 查询失败(rc=$QRC, stderr: ${QERR});";;
      esac
    fi
    [[ -n "$qfail" ]] && probe="$probe;showfail=${qfail%,}"
    # ── 适用字段: 只在**这一次查询确实成功**时才谈"缺失/非法" ────────────────
    # 查询失败已经在上面具名记过账了; 在这里再判一次"非法值"会把**读取失败**说成
    # **值不对** —— 两者的处置完全不同, 必须分开。
    (( q_id ))   && { [[ -n "$id" ]]   || why="${why}读不到 Id(查询成功但值为空);"; }
    (( q_load )) && { [[ -n "$load" ]] || why="${why}读不到 LoadState(查询成功但值为空);"; }
    case "$kind" in unknown|other) (( q_id )) && why="${why}unit 类型不认识(Id=[$id]);";; esac
    # UnitFileState 分两档, 没有第三档:
    #   · 词表内的**非空**值 → 正常(transient 就在词表里, 走这一条);
    #   · 词表外的值         → 非法(与查询失败分开报);
    #   · **空**且 unit 已加载 → **必需字段缺失 ⇒ 观测无效**, 没有豁免。
    # 为什么没有豁免: 上一版按"Transient=yes 或 FragmentPath 为空 ⇒ 瞬态 unit 没有 unit 文件"
    # 放行过, 那个前提是错的。本机 systemd 252 实测(见证据 86 号文件): 真实瞬态 unit 的
    # UnitFileState = **transient**(词表内的合法非空值), Transient=yes, 且 FragmentPath
    # 指向 /run/systemd/transient/<名字> —— 文件确实在盘上(v252 的 unit_make_transient
    # 会建文件并设置 fragment_path)。所以合法 transient 根本走不到空值这一支,
    # 空值也就没有任何已知的合法来源, 不该有豁免。
    # 本支要在 ⑤-4 上核 mosdns/mihomo/pdg-mitm/pdg-probe81 的自启态, bridge_svc_class 也读
    # 这一列判 pdg-mitm 有没有被禁用 —— 取不到就是取不到, 不拿别的属性猜, 也不拿
    # is-enabled 的另一次结果去填这一格。
    # not-found 不在此列: 它的 UnitFileState 本来就是空, 由 LoadState 单独区分, 不与 loaded 混判。
    if (( q_ufs )); then
      case "$ufs" in enabled|enabled-runtime|linked|linked-runtime|alias|masked|masked-runtime\
                    |static|indirect|disabled|generated|transient|bad) :;;
                     "") [[ "$load" == loaded ]] \
                           && why="${why}UnitFileState 为空而 LoadState=loaded —— 本支要据此核自启态, 这是**必需字段缺失**(空值没有已知的合法来源: 真实瞬态 unit 报的是 transient, 不是空);";;
                     *) why="${why}UnitFileState 非法值 [$ufs];";; esac
    fi
    if (( q_act )); then
      case "$act" in active|inactive|activating|deactivating|reloading|failed|"") :;;
                     *) why="${why}ActiveState 非法值 [$act];";; esac
      [[ "$act" == "" && "$load" == "loaded" ]] && why="${why}已加载却读不到 ActiveState;"
    fi
    # SubState 是**每个已加载 unit 都有**的状态属性(systemd 252 实测: service=running/
    # timer=waiting/socket=listening, 连 not-found 都给 dead)。它不是服务专属属性,
    # 所以 timer/socket **不能**因为"不是 service"就免检 —— 查询成功却空就是必需字段缺失。
    # timer/socket 真正不适用的是 MainPID / NRestarts 那类服务专属属性(见下面那一段)。
    (( q_sub )) && [[ "$load" == loaded && -z "$sub" ]] \
      && why="${why}$kind 已加载却读不到 SubState(查询成功但值为空)—— 每个已加载 unit 都该有 SubState, 这是必需字段缺失;"
    if [[ "$kind" == service && "$load" == loaded ]]; then
      (( q_typ )) && { [[ -n "$typ" ]] || why="${why}service 已加载却读不到 Type;"; }
      (( q_pid )) && { [[ "$pid" =~ ^[0-9]+$ ]] || why="${why}MainPID 非法值 [$pid];"; }
      (( q_nr ))  && { [[ "$nr"  =~ ^[0-9]+$ ]] || why="${why}NRestarts 非法值 [$nr];"; }
      if [[ "$act" == active ]] && (( q_typ && q_pid )) && _unit_wants_mainpid "$typ"; then
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || why="${why}Type=$typ 的 service 处于 active 却没有非零 MainPID([$pid]);"
      fi
    fi
    # timer / socket: Type 与 NRestarts 合法地不适用 —— 但那是"查询成功且值为空",
    # 与"查询失败"两码事; 后者已经在 _showq 里判无效了, 到不了这里。
    (( q_inv )) && { [[ "$act" == active && ! "$inv" =~ ^[0-9a-f]{32}$ ]] && why="${why}active 却没有合法 InvocationID([$inv]);"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$u" "${id:--}" "$kind" "${typ:--}" "${load:--}" "${act:-<空>}" "${sub:-<空>}" \
      "${ufs:-<空>}" "${pid:--}" "${inv:--}" "${nr:--}" "$probe" \
      "$( [[ -z "$why" ]] && echo ok || echo "bad:${why//$'\t'/ }" )" >> "$out"
  done
  rm -f "$errf" 2>/dev/null || true
  unset -f _showq _query
  return 0
}
# <<< PDG-EXTRACT-END bridge_svc_sample
# >>> PDG-EXTRACT-BEGIN bridge_row_valid
bridge_row_valid(){   # $1=一行采样 → 0 有效 / 1 无效(置 OBS_WHY)。**纯函数**: 不查任何东西。
  OBS_WHY=""
  local TAB; TAB="$(printf '\t')"
  local n; n="$(awk -F"$TAB" '{print NF}' <<<"$1")"
  [[ "$n" == 13 ]] || { OBS_WHY="这一行不是 13 列(实得 ${n:-0}) —— 采样格式不对"; return 1; }
  local v; v="$(cut -d"$TAB" -f13 <<<"$1")"
  [[ "$v" == ok ]] || { OBS_WHY="${v#bad:}"; return 1; }
  return 0
}
# <<< PDG-EXTRACT-END bridge_row_valid
# >>> PDG-EXTRACT-BEGIN bridge_set_check
bridge_set_check(){   # $1=采样文件 $2=标签 → 0 齐 / 非 0 并具名。按名称+唯一性+完整性核。
  local f="$1" lbl="$2" u TAB; TAB="$(printf '\t')"
  [[ -r "$f" ]] || { echo "$lbl: 采样文件读不了($f)"; return 3; }
  local names dup extra=""
  names="$(cut -d"$TAB" -f1 "$f")"
  dup="$(sort <<<"$names" | uniq -d)"
  [[ -z "$dup" ]] || { printf '%s: 采样里有重复服务行(%s) —— 重复行能顶掉缺的那一项\n' "$lbl" "$(tr '\n' ' ' <<<"$dup")"; return 1; }
  local missing=""
  for u in "${SVC_WATCH[@]}"; do grep -qxF -- "$u" <<<"$names" || missing="$missing $u"; done
  [[ -z "$missing" ]] || { printf '%s: 采样缺服务:%s\n' "$lbl" "$missing"; return 1; }
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    printf '%s\n' "${SVC_WATCH[@]}" | grep -qxF -- "$u" || extra="$extra $u"
  done <<<"$names"
  [[ -z "$extra" ]] || { printf '%s: 采样里有清单外的服务:%s\n' "$lbl" "$extra"; return 1; }
  return 0
}
# <<< PDG-EXTRACT-END bridge_set_check
# 允许动作清单的判定本体。它只回答"这次观察到的变化, 在冻结候选的 cmd_update 链上
# 点不点得出来源", **不**反过来证明整条升级流程合法 —— 那要靠 ⑤ 的其余各维与功能结果。
# >>> PDG-EXTRACT-BEGIN bridge_svc_class
bridge_svc_class(){   # $1=unit $2=前状态行 $3=后状态行 → "<类别>|<理由>"
  local u="$1" b="$2" a="$3" TAB; TAB="$(printf '\t')"
  local b_act a_act b_ufs a_ufs rev=""
  b_act="$(cut -d"$TAB" -f6 <<<"$b")"; a_act="$(cut -d"$TAB" -f6 <<<"$a")"
  b_ufs="$(cut -d"$TAB" -f8 <<<"$b")"; a_ufs="$(cut -d"$TAB" -f8 <<<"$a")"
  # ── 反向变化先单拎出来 ──────────────────────────────────────────────────────
  # "本来在跑, 现在不在" / "本来启用, 现在不启用或找不到" = 停止 / 禁用 / 删除。
  # cmd_update 链上这三类动作只有那几处、且都不在本跳的成功路径上(见上面的逐处核对),
  # 所以一旦出现就必须点名到具体 unit 与前后取值, **不并进"正常安装动作"**。
  [[ "$b_act" == active  && "$a_act" != active  ]] && rev="运行 $b_act→$a_act"
  [[ "$b_ufs" == enabled && "$a_ufs" != enabled ]] && rev="${rev:+$rev; }自启 $b_ufs→$a_ufs"
  if [[ -n "$rev" ]]; then
    case "$u" in
      pdg-mitm)
        printf '意外|pdg-mitm 被停/禁/删(%s)。链上唯一会 disable 它的是 migrate_android_cleanup:4778, 而那只在 Android 平台跑; 本跳是 iOS' "$rev";;
      pdg-dotwitness)
        printf '意外|pdg-dotwitness 被停/禁(%s)。链上只有 migrate_dotwitness 自身回滚(4589/4593)会这么做, 而那会让整次更新回滚 —— 成功路径上不该出现' "$rev";;
      sing-box)
        printf '意外|sing-box 被停/禁(%s)。链上只有 migrate_drop_singbox→_pdg_drop_singbox_files:69/76 会动它, 而本跳夹具不装 sing-box' "$rev";;
      *)
        printf '意外|%s 被停/禁/删(%s) —— cmd_update 链的成功路径上没有这一步' "$u" "$rev";;
    esac
    return 0
  fi
  # ── 正向变化: 必须点得出链上的来源 ──────────────────────────────────────────
  case "$u" in
    mosdns)          printf '桥接更新链正常|pdg.sh:2777 daemon-reload 前后多处 migrate_* restart mosdns(599/646/687/4432/4596/5083/5179/5233/8360 等)';;
    mihomo)          printf '桥接更新链正常|pdg.sh:4084 migrate_mihomo_safepaths restart mihomo; 4965/5018 migrate_ios_gms_cleanup restart 内核 svc; 1995 _core_restart_clean(换核)';;
    pdg-bot)         printf '桥接更新链正常|pdg.sh:2781 cmd_update restart pdg-bot; 4251 migrate_deploy_botfiles try-restart';;
    pdg-probe81)     printf '桥接更新链正常|pdg.sh:2781 cmd_update restart pdg-probe81; 4737 enable --now / 4744 restart(migrate_probe81_public)';;
    pdg-mitm)        printf '桥接更新链正常|pdg.sh:2782 cmd_update 先 is-enabled 再 restart pdg-mitm; 4453 migrate_pdg_mitm_service enable --now(只拉起, 不停不禁不删)';;
    pdg-dotwitness)  printf '桥接更新链正常|pdg.sh:4626 migrate_dotwitness enable --now; 4629 restart(四件套闭合后)';;
    pdg-health.timer|pdg-health.service)
                     printf '桥接更新链正常|pdg.sh:2780 cmd_update enable --now pdg-health.timer; 4163/4194/4210 enable · 4168/4213 restart(migrate_health_timer)';;
    pdg-rules-update.timer|pdg-rules-update.service)
                     printf '意外|cmd_update 链里没有任何一处动 pdg-rules-update.*(那是 install.sh 的动作) —— 这一跳出现就要查';;
    pdg-rescue.socket)
                     printf '意外|cmd_update 链里动救援平面的只有 migrate_rescue_plane→_rescue_enable, 且只在"老机首次获得救援平面"时; 出现变化要逐条核对来源';;
    sing-box)        printf '意外|本跳夹具不装 sing-box, 链上也不该动它';;
    ssh|cron)        printf '意外|无关系统服务, cmd_update 链一个字都不该动';;
    *)               printf '意外|不在 cmd_update 链的允许清单里';;
  esac
}
# <<< PDG-EXTRACT-END bridge_svc_class
# >>> PDG-EXTRACT-BEGIN bridge_svc_verdict
bridge_svc_verdict(){   # $1=before $2=after $3=场景名 $4=窗口观测结果(可省)
  local u b a cls reason TAB; TAB="$(printf '\t')"
  local win="${4:-}"
  local n_norm=0 n_un=0 n_inst=0 n_invalid=0 n_win=0 n_winbad=0
  local unexpected="" invalid="" winacted="" winbad=""
  # ① 集合: 名称 + 唯一性 + 完整性, 前后各自独立核
  local setmsg
  if ! setmsg="$(bridge_set_check "$1" "$3/前")"; then bad "$3: $setmsg —— 集合不全就不能谈'意外 0'"; return 1; fi
  if ! setmsg="$(bridge_set_check "$2" "$3/后")"; then bad "$3: $setmsg —— 集合不全就不能谈'意外 0'"; return 1; fi
  echo "── 服务动作对账($3; 允许清单来自冻结桥接候选的 cmd_update 调用链, 逐处标了 pdg.sh 行号)──"
  while IFS= read -r b; do
    u="$(cut -d"$TAB" -f1 <<<"$b")"; [[ -n "$u" ]] || continue
    a="$(awk -F"$TAB" -v u="$u" '$1==u' "$2" | head -1)"
    # ② 有效性: 前后两行**各自**证明自己有效, 判据来自采样当时写下的那一列
    if ! bridge_row_valid "$b"; then
      n_invalid=$((n_invalid+1)); invalid="$invalid $u(前: $OBS_WHY)"; continue
    fi
    if ! bridge_row_valid "$a"; then
      n_invalid=$((n_invalid+1)); invalid="$invalid $u(后: $OBS_WHY)"; continue
    fi
    # ③ 实例更替单列: PID/InvocationID 变了**只**说明换了实例, 不等于被停/被禁/被删
    local b_pid a_pid b_inv a_inv
    b_pid="$(cut -d"$TAB" -f9  <<<"$b")"; a_pid="$(cut -d"$TAB" -f9  <<<"$a")"
    b_inv="$(cut -d"$TAB" -f10 <<<"$b")"; a_inv="$(cut -d"$TAB" -f10 <<<"$a")"
    if [[ "$b_pid" != "$a_pid" || "$b_inv" != "$a_inv" ]]; then
      n_inst=$((n_inst+1))
      printf '    %-20s [实例更替] MainPID %s→%s Invocation %s→%s(只说明换了实例)\n' \
        "$u" "$b_pid" "$a_pid" "${b_inv:0:8}" "${a_inv:0:8}"
    fi
    # ④ 窗口内动作: 两次采样一样**不能**证明中间没动过 —— 窗口另算, 观测无效也另算
    if [[ -n "$win" && -r "$win" ]]; then
      local wl wv; wl="$(awk -F"$TAB" -v u="$u" '$1==u' "$win" | head -1)"
      if [[ -n "$wl" ]]; then
        wv="$(cut -d"$TAB" -f2 <<<"$wl")"
        if [[ "$wv" == INVALID ]]; then
          n_winbad=$((n_winbad+1)); winbad="$winbad $u($(cut -d"$TAB" -f3 <<<"$wl"))"
        elif [[ "$wv" =~ ^[0-9]+$ ]] && (( wv > 0 )); then
          n_win=$((n_win+1)); winacted="$winacted $u(${wv}次)"
          printf '    %-20s [窗口内动作] 界桩区间里被启动 %s 次(前后状态是否相同都不影响这一条)\n' "$u" "$wv"
        fi
      fi
    fi
    # ⑤ 状态差异
    [[ "$b" == "$a" ]] && continue
    cls="$(bridge_svc_class "$u" "$b" "$a")"; reason="${cls#*|}"; cls="${cls%%|*}"
    printf '    %-20s [%s]\n      前: %s\n      后: %s\n      依据: %s\n' \
      "$u" "$cls" "${b#*"$TAB"}" "${a#*"$TAB"}" "$reason"
    case "$cls" in
      桥接更新链正常*) n_norm=$((n_norm+1));;
      *) n_un=$((n_un+1)); unexpected="$unexpected $u";;
    esac
  done < "$1"
  printf '    小计: 桥接链正常 %d / 实例更替 %d / 窗口内动作 %d / **意外 %d** / 观测无效 %d / 窗口观测无效 %d\n' \
    "$n_norm" "$n_inst" "$n_win" "$n_un" "$n_invalid" "$n_winbad"
  _evn "07-service-actions-$3.txt" "正常=$n_norm 实例更替=$n_inst 窗口动作=$n_win 意外=$n_un 观测无效=$n_invalid 窗口无效=$n_winbad;$unexpected;$invalid;$winbad"
  cp "$1" "$EVID/svc-$3-before.tsv" 2>/dev/null; cp "$2" "$EVID/svc-$3-after.tsv" 2>/dev/null
  chmod 600 "$EVID/svc-$3-before.tsv" "$EVID/svc-$3-after.tsv" 2>/dev/null || true
  if (( n_invalid > 0 )); then
    bad "$3: 有 $n_invalid 项观测无效:$invalid —— 观测无效不产出'意外 0', 这一格不成立"
  elif (( n_winbad > 0 )); then
    bad "$3: 有 $n_winbad 项**窗口观测无效**:$winbad —— 窗口读不出来就不知道区间里动没动过, 不能据此说'意外 0'"
  elif [[ -n "$win" && ! -r "$win" ]]; then
    bad "$3: 给了窗口结果文件却读不了($win) —— 不能在没有窗口证据的情况下说'意外 0'"
  elif (( n_un > 0 )); then
    bad "$3: 出现桥接清单外的服务动作:$unexpected"
  else
    ok "$3: 服务动作全部落在**暂定的**桥接安装链允许清单内(意外 0, 观测无效 0, 窗口观测无效 0; 实例更替 $n_inst 项、窗口内动作 $n_win 项已分别单列)"
  fi
}
# <<< PDG-EXTRACT-END bridge_svc_verdict

SECT "① 真实环境硬门"
[[ "$(cat /proc/1/comm)" == systemd ]] || _hard "PID 1 不是 systemd"
SCBIN="$(command -v systemctl || true)"; [[ -x "$SCBIN" ]] || _hard "没有 systemctl"
case "$SCBIN" in /usr/local/bin/*) _hard "systemctl 解析到 $SCBIN(本仓桩的落点), 拒绝";; esac
head -c2 "$SCBIN" | grep -q '#!' && _hard "systemctl 是脚本, 不是真二进制"
NFTBIN="$(command -v nft || true)"; [[ -x "$NFTBIN" ]] || _hard "没有 nft"
nft list ruleset >/dev/null 2>&1 || _hard "nft 读不到内核规则"
[[ -f /usr/local/bin/mosdns && "$(stat -c %s /usr/local/bin/mosdns)" -gt 1000000 ]] || _hard "mosdns 不是真二进制"
e2e_mihomo_is_real 2>/dev/null || _hard "mihomo 不是真钉死版"
for c in git python3 openssl ss curl sha256sum; do command -v "$c" >/dev/null || _hard "缺命令: $c"; done
ok "硬门: 真 systemd / 真 systemctl / 真 nft / 钉死版 mosdns+mihomo / 基础命令齐备"
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1
  note "已停用 runner 自带的 systemd-resolved(释放 :53; 一次性 runner 专属改动)"
fi
rm -f /etc/resolv.conf 2>/dev/null; printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf

SECT "② 自有测试源(三个真实对象; 官方仓库不动)"
for s in "$OLD_SHA" "$BRIDGE_SHA" "$RETIRE_SHA"; do
  [[ "$(git -C "$E2E_ROOT_REAL" cat-file -t "$s" 2>/dev/null)" == commit ]] || _hard "工作区里取不到对象 $s"
done
rm -rf "$ORIGIN"; git clone --bare -q "$E2E_ROOT_REAL" "$ORIGIN" || _hard "建裸库失败"
e2e_guard_repo "$ORIGIN" || _hard "裸库没通过 ref 库守卫"
e2e_git "$ORIGIN" fetch -q "$E2E_ROOT_REAL" "+refs/tags/*:refs/tags/*" 2>/dev/null || true
if [[ "$(git -C "$ORIGIN" rev-parse -q --verify "$OLD_TAG^{commit}" 2>/dev/null)" == "$OLD_SHA" ]]; then
  OLD_TAG_KIND="$(git -C "$ORIGIN" cat-file -t "$OLD_TAG" 2>/dev/null)"
  ok "裸库里的 $OLD_TAG 指向真实对象 $OLD_SHA(tag 对象类型=$OLD_TAG_KIND)"
else
  e2e_git "$ORIGIN" tag -f "$OLD_TAG" "$OLD_SHA" >/dev/null 2>&1; OLD_TAG_KIND="lightweight(本轮补建)"
  note "工作区没带来官方 $OLD_TAG 的 tag 对象, 已按真实提交补一个轻量 tag"
fi
e2e_git "$ORIGIN" tag -f "$BRIDGE_TAG" "$BRIDGE_SHA" >/dev/null 2>&1 || _hard "建桥接测试 tag 失败"
e2e_git "$ORIGIN" tag -f "$RETIRE_TAG" "$RETIRE_SHA" >/dev/null 2>&1 || _hard "建退役测试 tag 失败"
e2e_git "$ORIGIN" update-ref refs/heads/main "$BRIDGE_SHA" || _hard "裸库 main 指不过去"
for _br in $(git -C "$ORIGIN" for-each-ref --format='%(refname)' refs/heads | grep -v '^refs/heads/main$'); do
  e2e_git "$ORIGIN" update-ref -d "$_br" >/dev/null 2>&1 || true
done
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
SEL="$(git -C "$ORIGIN" tag -l 'v*' --sort=-v:refname | head -1)"
[[ "$SEL" == "$RETIRE_TAG" ]] \
  && ok "排序最高的是**退役目标** $RETIRE_TAG → ${RETIRE_SHA:0:12} —— 指定桥接时它就是最容易被误装的那个" \
  || _hard "最高版本不是退役目标而是 $SEL, 源映射无效"
rm -rf "$OLDSRC" "$BRSRC"; mkdir -p "$OLDSRC" "$BRSRC"
git -C "$ORIGIN" archive "$OLD_SHA" | tar -x -C "$OLDSRC" || _hard "展开 v1.11.15 源码失败"
git -C "$ORIGIN" archive "$BRIDGE_SHA" | tar -x -C "$BRSRC" || _hard "展开桥接源码失败"
{
  echo "# 测试源映射(与正式发布路径的差异, 逐条)"
  echo "裸库              : $ORIGIN (本机自有, 一次性)"
  echo "$OLD_TAG          → $OLD_SHA (类型: $OLD_TAG_KIND)"
  echo "$BRIDGE_TAG       → $BRIDGE_SHA  (**仅测试**的合成 tag 名; 对象是真实桥接候选)"
  echo "$RETIRE_TAG       → $RETIRE_SHA  (**仅测试**; 版本号更高, 用来证明它没被误装)"
  echo "裸库 refs/heads/main → $BRIDGE_SHA (相当于官方 main 上的最新入口脚本)"
  echo "差异: 正式路径取件自 https://github.com/misaka-cpu/privdns-gateway.git 与官方 v* tag;"
  echo "      本轮取件自本机裸库与合成 tag。官方仓库不打 tag、不发 Release。"
  echo "      因此本支通过**不**等于「正式发布来源已验证」。"
} | _ev 02-source-map.txt
ok "源映射已留档(02-source-map.txt)"

# ── 依赖自检的**真正调用点** ───────────────────────────────────────────────
# 位置有讲究, 两头都卡死:
#   · 必须在 bridge_svc_sample / bridge_set_check 的定义之后 —— 它俩是自检的真实消费者;
#   · 必须在 ③ 前像构造与任何服务动作之前 —— 自检没过就不许往下走。
# 先核一遍"消费者真的在符号表里": 这条挡的正是上面那类顺序错误, 让它当场具名, 而不是
# 表现成一句 command not found 后的泛泛失败。
for _f in deps_selfcheck bridge_svc_sample bridge_set_check bridge_row_valid; do
  declare -F "$_f" >/dev/null \
    || _hard "依赖自检的消费者 $_f 在调用点还没定义 —— 执行顺序错了(定义必须排在调用之前), 前像与服务动作都没开始。"
done
deps_selfcheck || _hard "依赖自检没过(见上一行) —— 前像构造与任何服务动作都还没开始。"
note "依赖已就位: E2E_OWNED_UNITS ${#E2E_OWNED_UNITS[@]} 项 / SVC_WATCH ${#SVC_WATCH[@]} 项(均来自来源脚本的标记, 非本支另写)"
ok "准备段顺序自洽: 消费者已定义 → 依赖自检通过 → 才进 ③ 前像构造"

SECT "③ 旧版前像(v1.11.15; **夹具组装**, 不是完整旧安装器跑出来的)"
note "如实登记: 前像由 tests/e2e-lib.sh 的播种函数 + 旧版自己的模板/模块清单组装,"
note "  **没有**跑 v1.11.15 的 install.sh。所以本支不是「完整旧安装器升级验收」——"
note "  它验的是**这一跳的公开入口与版本身份**, 前像只需合法稳定。"
build_preimage ios on || _hard "旧版前像没建起来"
install -m755 "$OLDSRC/deploy/bot/pdg.sh" /usr/local/bin/pdg
OLD_CLI_SHA="$(sha256sum /usr/local/bin/pdg | awk '{print $1}')"
[[ "$OLD_CLI_SHA" == "$(sha256sum "$OLDSRC/deploy/bot/pdg.sh" | awk '{print $1}')" ]] \
  && ok "前像: /usr/local/bin/pdg 逐字节等于 v1.11.15 的那一份($(cut -c1-12 <<<"$OLD_CLI_SHA"))" \
  || bad "前像: CLI 不是 v1.11.15 的"
for _f in _pdg_save_svcstate _pdg_restore_svcstate; do
  grep -q "^$_f(){" /usr/local/bin/pdg \
    && { bad "前像: 旧版 CLI 里竟然已经有 $_f —— 那就没有可验的跳了"; } \
    || ok "前像: 旧版 CLI **没有** $_f(桥接要带来的能力, 现在确实还不在)"
done
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$OLD_SHA" ]] \
  && ok "前像: $REPO 停在 v1.11.15($OLD_SHA)" || bad "前像: $REPO HEAD=$(git -C "$REPO" rev-parse HEAD)"
[[ "$(git -C "$REPO" remote get-url origin)" == "$ORIGIN" ]] \
  && ok "前像: $REPO 的 origin 指向自有裸库(公开入口就从这里取件)" || bad "前像: origin 不对"
systemctl daemon-reload
svc_stable_assert mosdns      running "前像: mosdns 持续运行" 5
svc_stable_assert mihomo      running "前像: mihomo 持续运行" 5
svc_stable_assert pdg-mitm    running "前像: pdg-mitm 持续运行(WLOC 开着)" 5
svc_stable_assert pdg-probe81 running "前像: pdg-probe81 持续运行" 5
MITM_LISTEN_BEFORE="$(ss -lnt 2>/dev/null | grep -c ':7894 ')"
mitm_listen_verdict "$(sc_state is-active pdg-mitm)" "$MITM_LISTEN_BEFORE" \
  && ok "前像自洽: $MITM_VERDICT_WHY" || { bad "前像不自洽: $MITM_VERDICT_WHY"; PREIMAGE_OK=0; }
# ── 这一跳**不该动**的东西: 路径取自旧版自己的常量, 不是手写猜的 ──────────────
#   iosstate.py  : META=/etc/privdns-gateway/ios-profile.json
#                  ART_DIR=/var/lib/privdns-gateway/ios-profile, CUR/PREV=current/previous.mobileconfig
#   mitm_ca.py   : CA_DIR=/etc/privdns-gateway/ca, 文件名 ca.crt / ca.key
#   iosprofile.py: CA_CRT=$CA_DIR/ca.crt
_const(){ sed -n "s/^$2 *= *\(FSROOT *+ *\)\?\"\([^\"]*\)\".*/\2/p" "$1" | head -1; }
IOS_META="$(_const "$OLDSRC/deploy/bot/iosstate.py" META)"
IOS_ART="$(_const "$OLDSRC/deploy/bot/iosstate.py" ART_DIR)"
CA_DIR_OLD="$(_const "$OLDSRC/deploy/bot/mitm_ca.py" CA_DIR)"
OLD_SCHEMA_CONST="$(sed -n 's/^SCHEMA *= *\([0-9]\+\).*/\1/p' "$OLDSRC/deploy/bot/iosstate.py" | head -1)"
{ [[ -n "$IOS_META" ]] && [[ -n "$IOS_ART" ]] && [[ -n "$CA_DIR_OLD" ]] && [[ -n "$OLD_SCHEMA_CONST" ]]; } \
  && ok "前像: 保留项路径与 schema 常量都取自旧版原文(META=$IOS_META, ART_DIR=$IOS_ART, CA_DIR=$CA_DIR_OLD, SCHEMA=$OLD_SCHEMA_CONST)" \
  || { bad "前像: 读不出旧版常量(META=[$IOS_META] ART_DIR=[$IOS_ART] CA_DIR=[$CA_DIR_OLD] SCHEMA=[$OLD_SCHEMA_CONST])"; PREIMAGE_OK=0; }
# iOS 槽位的存在性**由记录决定**, 不预设 previous 一定在。
# build_preimage 清空现场后只调一次生成器 ⇒ 合法状态就是 current 有记录、previous=null、
# 且 previous 产物**不该存在**。硬把 previous.mobileconfig 列进必需项, 等于拿一个前像根本
# 不会产生的对象当判据 —— 那既不是保留失败, 也不能靠复制 current/伪造 revision/建空文件凑齐。
# 有效性一律走**产品自己的校验入口** iosstate.artifact_health(): 它区分
# healthy / missing / corrupt / state_mismatch, 而 "schema==1" 或 "文件里有 <plist"
# 只证明局部形态, 证明不了记录与产物对得上。
# >>> PDG-EXTRACT-BEGIN ios_slots
ios_slots(){   # $1=meta 路径 $2=产物目录 $3=旧版 deploy/bot 目录
               # 输出逐行 TSV; 首行 schema, 之后每槽位一行: which 记录 文件 状态 说明
  python3 - "$1" "$2" "$3" <<'PY' 2>&1 || echo "RUNFAIL	python3 退出非零"
import os, sys
sys.path.insert(0, sys.argv[3])
try:
    import iosstate
except Exception as e:
    print("IMPORTFAIL\t%s: %s" % (type(e).__name__, e)); raise SystemExit(0)
mp, ar = sys.argv[1], sys.argv[2]
try:
    meta = iosstate.load(mp)
except Exception as e:
    print("LOADFAIL\t%s: %s" % (type(e).__name__, e)); raise SystemExit(0)
if meta is None:
    print("NOMETA\t记录文件不存在(还没启用受管生命周期)"); raise SystemExit(0)
print("schema\t%s" % meta.get("schema"))
for which in ("current", "previous"):
    rec = iosstate._slot(meta, which)
    try:
        state, detail = iosstate.artifact_health(meta, which, ar)
    except Exception as e:
        state, detail = "CHECKFAIL", "%s: %s" % (type(e).__name__, e)
    print("%s\t%s\t%s\t%s\t%s" % (
        which,
        "有记录" if rec else "无记录",
        "文件在" if os.path.exists(iosstate.art_path(which, ar)) else "文件不在",
        state, detail))
PY
}
# <<< PDG-EXTRACT-END ios_slots
# >>> PDG-EXTRACT-BEGIN ios_slot_verdict
ios_slot_verdict(){   # $1=ios_slots 的输出 $2=期望 schema
                      # 打印结论行; 0=槽位形态自洽 / 1=不自洽 / 2=记录读不出来
  local rep="$1" want="$2" w rec fil st detail got_schema="" n=0 bad=0
  while IFS=$'\t' read -r w rec fil st detail; do
    [[ -n "$w" ]] || continue
    case "$w" in
      IMPORTFAIL|LOADFAIL|NOMETA|RUNFAIL)
        printf '记录不可用: %s(%s)\n' "$w" "$rec"; return 2;;
      schema) got_schema="$rec"; continue;;
    esac
    n=$((n+1))
    # 槽位有无记录, 决定文件该不该在、健康状态该是什么 —— 两条**必须一起**成立
    if [[ "$rec" == 无记录 ]]; then
      if [[ "$fil" == 文件不在 && "$st" == missing ]]; then
        printf '  %-8s 无记录 ⇒ 文件不在且判 missing(合法的单版本前像)\n' "$w"
      else
        printf '  %-8s **不自洽**: 记录里没有这一版, 却 %s / 状态 %s —— %s\n' "$w" "$fil" "$st" "$detail"; bad=$((bad+1))
      fi
    else
      if [[ "$fil" == 文件在 && "$st" == healthy ]]; then
        printf '  %-8s 有记录 ⇒ 文件在且 iosstate.artifact_health 判 healthy(%s)\n' "$w" "$detail"
      else
        printf '  %-8s **不自洽**: 记录里有这一版, 但 %s / 状态 %s —— %s\n' "$w" "$fil" "$st" "$detail"; bad=$((bad+1))
      fi
    fi
  done <<< "$rep"
  (( n == 2 )) || { printf '槽位行数 %d(应为 2: current + previous)\n' "$n"; return 1; }
  [[ "$got_schema" == "$want" ]] || { printf 'schema 读到 [%s], 应为 [%s]\n' "$got_schema" "$want"; return 1; }
  printf 'schema %s; 槽位 2 个; 不自洽 %d\n' "$got_schema" "$bad"
  (( bad == 0 )) || return 1
  return 0
}
# <<< PDG-EXTRACT-END ios_slot_verdict
SLOTS_BEFORE="$(ios_slots "$IOS_META" "$IOS_ART" "$OLDSRC/deploy/bot")"
_SV="$(ios_slot_verdict "$SLOTS_BEFORE" "$OLD_SCHEMA_CONST")"; _SVRC=$?
printf '%s\n' "$_SV" | sed 's/^/    /'
case "$_SVRC" in
  0) ok "前像: iOS 槽位形态自洽 —— 存在性按**记录**判定, 有效性走产品入口 artifact_health($(tail -1 <<<"$_SV"))";;
  2) bad "前像: iOS 记录读不出来 —— 这是读取失败, 不当成'槽位为空'"; PREIMAGE_OK=0;;
  *) bad "前像: iOS 槽位形态不自洽(上面逐项列出)"; PREIMAGE_OK=0;;
esac
# 必需保留项 = 固定那批 + **按记录实际存在的**槽位产物(previous 只在记录里有时才算必需)
# 保留项分三类, **不混在一起判** —— 混着判会把"应当被候选更新的代码"误列成"必须逐字节不变",
# 那种红是判据的错, 不是产品的错。
#   ① KEEP_MUST  用户数据 / 身份 / 凭据: 这一跳一个字节都不该动
#   ② KEEP_CODE  产品代码与 unit: **允许按候选更新**; 它们"是不是更新成了候选那一份"由 ⑤-1
#                的 ios 模块清单逐字节核对(那里比的是 $BRSRC), 这里只核"还在、没被删掉"
#   ③ KEEP_GEN   受管生成物: 允许被迁移重新生成, 只核"还在且非空"
KEEP_MUST=("$CA_DIR_OLD/ca.crt" "$CA_DIR_OLD/ca.key" "$IOS_META"
           "$IOS_ART/current.mobileconfig"
           /etc/privdns-gateway/platform /etc/privdns-gateway/mitm.json)
KEEP_CODE=(/opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py /opt/pdg-bot/mitm_ca.py
           /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py
           /etc/systemd/system/pdg-mitm.service)
KEEP_GEN=(/etc/mosdns/rules/mitm_hijack.txt)
if grep -qP '^previous\t有记录' <<< "$SLOTS_BEFORE"; then
  KEEP_MUST+=("$IOS_ART/previous.mobileconfig")
  note "前像: 记录里**有** previous 槽位 ⇒ previous.mobileconfig 进必需保留项"
else
  note "前像: 记录里**没有** previous 槽位(单次生成的合法形态) ⇒ 不把 previous.mobileconfig 当必需项, 也不去凑一个出来"
fi
KEEP_OPT=(/etc/privdns-gateway/bot.env /opt/pdg-bot/dot-domain)
# 先自证: 必需项都在盘上且读得出来 —— 缺失 / 读不出来分别报告。
_KM_MISS=(); _KM_BAD=()
for _f in "${KEEP_MUST[@]}"; do
  if [[ ! -e "$_f" ]]; then _KM_MISS+=("$_f"); continue; fi
  sha256sum "$_f" >/dev/null 2>&1 || _KM_BAD+=("$_f(读不出来)")
done
[[ "${#_KM_MISS[@]}" == 0 ]] \
  && ok "前像: ${#KEEP_MUST[@]} 项**应当存在**的保留对象全部在盘上(按旧版常量与记录定位)" \
  || { bad "前像: 缺 ${#_KM_MISS[@]} 项保留对象: ${_KM_MISS[*]}"; PREIMAGE_OK=0; }
[[ "${#_KM_BAD[@]}" == 0 ]] || { bad "前像: 有 ${#_KM_BAD[@]} 项读不出来: ${_KM_BAD[*]}"; PREIMAGE_OK=0; }
# 代码类与生成物在前像里也必须在盘上 —— 不然"跳完还在不在"根本无从谈起。
_KC_MISS=(); for _f in "${KEEP_CODE[@]}" "${KEEP_GEN[@]}"; do [[ -e "$_f" ]] || _KC_MISS+=("$_f"); done
[[ "${#_KC_MISS[@]}" == 0 ]] \
  && ok "前像: ${#KEEP_CODE[@]} 项代码/unit 与 ${#KEEP_GEN[@]} 项受管生成物也都在盘上(它们**允许**被候选更新, 只是不许消失)" \
  || { bad "前像: 代码/生成物缺 ${#_KC_MISS[@]} 项: ${_KC_MISS[*]}"; PREIMAGE_OK=0; }
# 台账: 期望集合单列成文件, 台账逐项带**明确的存在性**, 对账时核有效记录数/路径唯一性/集合完整性。
KEEP_LEDGER="${E2E_TMP:-${TMPDIR:-/tmp}}/keep-ledger.tsv"
KEEP_EXPECT="${E2E_TMP:-${TMPDIR:-/tmp}}/keep-expect.txt"
# >>> PDG-EXTRACT-BEGIN keep_fp
keep_fp(){ printf '%s %s\n' "$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" "$(stat -c '%a %u:%g' "$1" 2>/dev/null)"; }
# <<< PDG-EXTRACT-END keep_fp
# >>> PDG-EXTRACT-BEGIN ledger_build
ledger_build(){   # $1=台账落点 $2=期望集合落点; $3..=必需项; 其后以 -- 分隔可选项
  local led="$1" exp="$2"; shift 2
  local f opt=0
  : > "$led"; : > "$exp"
  for f in "$@"; do
    [[ "$f" == -- ]] && { opt=1; continue; }
    (( opt == 0 )) && printf '%s\n' "$f" >> "$exp"     # 期望集合**只含必需项**
    if [[ -e "$f" ]]; then printf '%s\tpresent\t%s\n' "$f" "$(keep_fp "$f")" >> "$led"
    else                   printf '%s\tabsent\t-\n'   "$f" >> "$led"; fi
  done
}
# <<< PDG-EXTRACT-END ledger_build
ledger_build "$KEEP_LEDGER" "$KEEP_EXPECT" "${KEEP_MUST[@]}" -- "${KEEP_OPT[@]}"
# 代码类另记一份前像指纹: 跳完要能说出"这几项是没动, 还是按候选更新了", 而不是笼统一句"变了"。
declare -A KEEP_CODE_FP
for _f in "${KEEP_CODE[@]}"; do [[ -e "$_f" ]] && KEEP_CODE_FP["$_f"]="$(keep_fp "$_f")"; done
KEEP_N="$(grep -c . "$KEEP_LEDGER")"
snap_state "hop-before"; bridge_svc_sample "$E2E_TMP/svc-hop-before.tsv"
[[ "$PREIMAGE_OK" == 1 ]] || { nrun "场景 ②: 前像不成立, 本场景未执行"; e2e_summary; exit $?; }

SECT "④ 真跑桥接入口流程: 核验独立副本 → 从副本运行 pdg.sh update --to"
# 换掉了什么、为什么:
#   旧写法是 `bash <新版 install.sh> --ref <tag>`。桥接候选把跨版本升级的入口定案成
#   docs/BRIDGE-ENTRY.md 里那一段**已实现**的流程 —— 先核验一份独立入口副本的身份,
#   再**从那份副本**运行 `pdg.sh update --to <tag>`。被更新的对象始终是现役受管仓库。
#   这里不另造更新器、不改正式参数接口: 原文按标记从**桥接候选自己的文档**里抽出来跑。
ENTRYDIR="$E2E_TMP/bridge-entry-copy"          # 入口副本: 与现役 /opt/privdns-gateway 分开
FLOW="$E2E_TMP/bridge-entry-flow.sh"
DOC="$BRSRC/docs/BRIDGE-ENTRY.md"
[[ -f "$DOC" ]] || _hard "桥接候选里没有 docs/BRIDGE-ENTRY.md —— 入口流程无从抽取"
_FB="$(grep -c '^# --- pdg-bridge-entry-flow: BEGIN' "$DOC")"
_FE="$(grep -c '^# --- pdg-bridge-entry-flow: END'   "$DOC")"
{ [[ "$_FB" == 1 && "$_FE" == 1 ]]; } \
  || _hard "入口流程标记不是唯一成对(BEGIN=$_FB END=$_FE) —— 抽取无效, 不进入真实执行"
awk '/^# --- pdg-bridge-entry-flow: BEGIN/{f=1;next} /^# --- pdg-bridge-entry-flow: END/{exit} f' \
    "$DOC" > "$FLOW" || _hard "抽取入口流程失败"
[[ -s "$FLOW" ]] || _hard "抽出来的入口流程是空的"
bash -n "$FLOW" || _hard "抽出来的入口流程语法不过 —— 执行无效, 不动任何服务"
ok "④-0 入口流程取自桥接候选 docs/BRIDGE-ENTRY.md 的唯一成对标记($(grep -c . "$FLOW") 行, bash -n 通过)"
# 接线核对: 跑的确实是"从副本运行产品 CLI 的 update --to", 不是别的东西
grep -qE 'update --dry-run --to' "$FLOW" && ok "④-0 流程含**预览**一步(update --dry-run --to)" \
                                         || bad "④-0 流程里没有预览步"
grep -qE 'pdg\.sh" update --to' "$FLOW" && ok "④-0 流程含**正式**一步(从副本运行 pdg.sh update --to)" \
                                         || bad "④-0 流程里没有正式更新步"
grep -q -- '--ref' "$FLOW" && bad "④-0 流程里竟还有 --ref —— 这一跳不该再走旧入口" \
                           || ok "④-0 流程**不含** --ref(旧入口已经换掉)"
command -v sudo >/dev/null || _hard "流程里用 sudo 提权, 但机器上没有 sudo"
FLOW_SHA="$(sha256sum "$FLOW" | awk '{print $1}')"
DOC_SHA="$(sha256sum "$DOC" | awk '{print $1}')"
# 入口副本必须与现役受管仓库分开 —— 同一个目录的话, "从副本跑"就没有意义了
case "$ENTRYDIR" in "$REPO"|"$REPO"/*) _hard "入口副本落在现役仓库里($ENTRYDIR)";; esac
[[ ! -e "$ENTRYDIR" ]] || _hard "入口副本目录已存在($ENTRYDIR) —— 流程要求空目录"
ok "④-0 入口副本 $ENTRYDIR 与现役受管仓库 $REPO 分开, 且当前不存在"
# 调用之前: 现役 CLI 必须仍然逐字节是旧版 —— 不许提前把桥接版装进去
_CLI_NOW="$(sha256sum /usr/local/bin/pdg | awk '{print $1}')"
[[ "$_CLI_NOW" == "$OLD_CLI_SHA" ]] \
  && ok "④-0 调用前: 现役 /usr/local/bin/pdg 仍逐字节等于 v1.11.15($(cut -c1-12 <<<"$_CLI_NOW"))" \
  || _hard "调用前现役 CLI 已经不是旧版($_CLI_NOW) —— 桥接版被提前安装了, 这一跳作废"
grep -q "^_pdg_save_svcstate(){" /usr/local/bin/pdg \
  && _hard "调用前现役 CLI 里已经有前像能力 —— 提前装了桥接版" \
  || ok "④-0 调用前: 现役 CLI 仍然没有前像能力(可验的跳还在)"
_evn 03-hop-identity.txt "workflow checkout = ${GITHUB_SHA:-<非 CI>}"
_evn 03-hop-identity.txt "旧版 CLI sha256 = $OLD_CLI_SHA (来源: $OLD_TAG → $OLD_SHA, 夹具组装)"
_evn 03-hop-identity.txt "入口来源        = $DOC (sha256 $DOC_SHA) → 流程原文 sha256 $FLOW_SHA"
_evn 03-hop-identity.txt "入口副本        = $ENTRYDIR (独立于现役 $REPO)"
_evn 03-hop-identity.txt "显式目标        = $BRIDGE_TAG → $BRIDGE_SHA (tag 对象类型=$(git -C "$ORIGIN" cat-file -t "$BRIDGE_TAG"))"
ENTRY_SHA="$FLOW_SHA"    # 交付里"入口身份"这一列现在记的是流程原文的摘要
C_PROD0="$(_j_mark hop-start)" || note "阶段记账: 起界桩没建成($(_j_why))"
HOP_OUT="$E2E_TMP/hop.log"
# --- hop-chain-invoke: BEGIN (契约测试按这两行标记抽本段原文, 串起"调用点→采样→裁决→汇总") ---
# 退出码**显式捕获**, 且**一个 Shell 选项都不动**。
# 原来这里是 `set +e … <调用> … HOP_RC=$? … set -e`: 前半句是空操作(本支头部只有
# set -uo pipefail, errexit 本来就关着), 后半句却把 errexit **打开**了 —— 于是从这一行往后,
# 任何一个**正常的**非零返回码都会当场打死脚本。实测 run 35436339744 就死在跳后第一处采样:
# `systemctl is-active pdg-bot` 对 inactive 服务正常返回 3, 脚本以 exit 3 终止,
# 服务动作对账 / ⑥ 收尾 / 最终汇总一步都没跑(证据 211 号)。
# 现在用 `|| HOP_RC=$?` 取子进程的原始返回值: 成功就是 0, 失败就是它自己的码, 不丢、不改、不吞。
HOP_RC=0
env -u PDG_TAG_BOOTSTRAPPED -u PDG_PLATFORM \
    TAG="$BRIDGE_TAG" WANT="$BRIDGE_SHA" ENTRY="$ENTRYDIR" SRC="$ORIGIN" \
    bash "$FLOW" > "$HOP_OUT" 2>&1 || HOP_RC=$?
# --- hop-chain-invoke: END ---
C_PROD1="$(_j_mark hop-end)" || note "阶段记账: 止界桩没建成($(_j_why))"
cp "$HOP_OUT" "$EVID/04-hop-install.log" 2>/dev/null; chmod 600 "$EVID/04-hop-install.log" 2>/dev/null || true
tail -40 "$HOP_OUT" | sed 's/^/    /'
_evn 03-hop-identity.txt "公开入口退出码 = $HOP_RC"

SECT "⑤ 逐维验收"
[[ "$HOP_RC" == 0 ]] && ok "⑤-0 返回码: 桥接入口流程以 0 退出" || bad "⑤-0 返回码: rc=$HOP_RC(见 04-hop-install.log)"
# 流程自己的身份门(⑥ 读回实际 HEAD 再比一次)必须留痕 —— 它是"先核对再提权"的证据
grep -q '✅ 身份核对通过' "$HOP_OUT" \
  && ok "⑤-0 报告: 入口副本的身份核对通过并留痕(先核对, 后提权)" \
  || bad "⑤-0 报告: 没有入口副本身份核对的输出"
# 产品自己的钉版贯穿门(cmd_update 在 reset 之后读**真实 HEAD** 再比一次)
grep -q '钉版目标已贯穿到实际安装' "$HOP_OUT" \
  && ok "⑤-0 报告: 产品的钉版贯穿门通过并留痕" || bad "⑤-0 报告: 没有钉版贯穿门输出"
grep -qF "已切到发布 $BRIDGE_TAG" "$HOP_OUT" \
  && ok "⑤-0 报告: 日志写明切到的是**指定**发布 $BRIDGE_TAG" || bad "⑤-0 报告: 没有指定版本的输出"
grep -qF -- "--dry-run --to" "$HOP_OUT" || true   # 预览的输出由产品决定, 不强求特定文案
# 入口副本: 独立存在、停在冻结桥接对象上, 且**不是**现役受管仓库
if [[ -d "$ENTRYDIR/.git" ]]; then
  _EHEAD="$(git -C "$ENTRYDIR" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || echo 读不到)"
  [[ "$_EHEAD" == "$BRIDGE_SHA" ]] \
    && ok "⑤-0 入口副本停在冻结桥接对象 ${BRIDGE_SHA:0:12}(与被更新的现役仓库是两份)" \
    || bad "⑤-0 入口副本 HEAD=$_EHEAD, 不是冻结桥接对象"
  [[ "$(readlink -f "$ENTRYDIR")" != "$(readlink -f "$REPO")" ]] \
    && ok "⑤-0 入口副本与现役受管仓库确实是两个不同目录" \
    || bad "⑤-0 入口副本与现役受管仓库指向同一处"
  _evn 03-hop-identity.txt "入口副本 HEAD   = $_EHEAD"
else
  bad "⑤-0 入口副本没建起来($ENTRYDIR 里没有 .git)"
fi
HEAD_AFTER="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo 读不到)"
[[ "$HEAD_AFTER" == "$BRIDGE_SHA" ]] \
  && ok "⑤-1 版本身份: $REPO 的 HEAD = 桥接 ${BRIDGE_SHA:0:12}" || bad "⑤-1 版本身份: HEAD=$HEAD_AFTER"
[[ "$HEAD_AFTER" != "$RETIRE_SHA" ]] \
  && ok "⑤-1 版本身份: **没有**误入版本号更高的退役目标 ${RETIRE_SHA:0:12}" || bad "⑤-1 竟然装成了退役目标"
CLI_SHA_AFTER="$(sha256sum /usr/local/bin/pdg | awk '{print $1}')"
[[ "$CLI_SHA_AFTER" == "$(sha256sum "$BRSRC/deploy/bot/pdg.sh" | awk '{print $1}')" ]] \
  && ok "⑤-1 已安装 CLI 逐字节等于桥接版($(cut -c1-12 <<<"$CLI_SHA_AFTER"))" \
  || bad "⑤-1 已安装 CLI 不是桥接版(实得 $(cut -c1-12 <<<"$CLI_SHA_AFTER"))"
[[ "$CLI_SHA_AFTER" != "$OLD_CLI_SHA" ]] && ok "⑤-1 CLI 确实换掉了(不是原地没动)" || bad "⑤-1 CLI 还是旧版"
_MODBAD=0; _MODN=0
while read -r _src _name _mode; do
  [[ -n "$_name" ]] || continue; _MODN=$((_MODN+1))
  cmp -s "$BRSRC/$_src" "/opt/pdg-bot/$_name" || { _MODBAD=$((_MODBAD+1)); echo "       不符: $_name"; }
done < <( ( source "$BRSRC/lib/modules.sh" && pdg_platform_modules ios ) 2>/dev/null )
{ [[ "$_MODN" -gt 0 && "$_MODBAD" == 0 ]]; } \
  && ok "⑤-1 已安装模块: ios 清单 $_MODN 项全部逐字节等于桥接版" || bad "⑤-1 模块有 $_MODBAD 项不符(共 $_MODN)"
_evn 03-hop-identity.txt "安装后: $REPO HEAD=$HEAD_AFTER; CLI sha256=$CLI_SHA_AFTER; ios 模块 $_MODN 项"
for _f in _pdg_save_svcstate _pdg_restore_svcstate _pdg_svcstate_valid _pdg_set_enable_state; do
  grep -q "^$_f(){" /usr/local/bin/pdg \
    && ok "⑤-2 桥接能力已安装: $_f" || bad "⑤-2 桥接能力缺失: $_f"
done
for _f in migrate_wloc_retire _retire_caller_gate _plat_purge_retired; do
  grep -q "^$_f(){" /usr/local/bin/pdg \
    && bad "⑤-2 装进来了**退役专属**实现 $_f —— 这一跳不该有它" \
    || ok "⑤-2 没有退役专属实现 $_f(这一跳本来就不该带)"
done
# >>> PDG-EXTRACT-BEGIN keep_compare
keep_compare(){   # $1=台账 $2=期望集合 → 打印结论
                  # 0=全对 / 1=有出入 / 2=零有效记录 / 3=路径重复 / 4=集合不完整 / 5=台账读不了
  local led="$1" exp="$2" f ex now cur valid=0 rows=0 miss=0 chg=0 appeared=0
  [[ -r "$led" ]] || { echo "台账读不了: $led"; return 5; }
  [[ -r "$exp" ]] || { echo "期望集合读不了: $exp"; return 5; }
  [[ -s "$led" ]] || { echo "台账为空 —— 零项台账不能证明保留成功"; return 2; }
  # 路径唯一性: 重复记录会让"逐项对账"在同一个对象上算两次, 掩盖另一项的缺失
  local dup; dup="$(cut -f1 "$led" | sort | uniq -d)"
  [[ -z "$dup" ]] || { printf '台账里有重复路径(每条只该出现一次):\n%s\n' "$(sed 's/^/       /' <<< "$dup")"; return 3; }
  # 集合完整性: 期望的**每一个**对象都必须在台账里出现(按名字核, 不是只数行)
  local absent_exp=""
  while IFS= read -r ex; do
    [[ -n "$ex" ]] || continue
    cut -f1 "$led" | grep -qxF -- "$ex" || absent_exp+="       漏项: $ex"$'\n'
  done < "$exp"
  [[ -z "$absent_exp" ]] || { printf '台账没覆盖期望集合:\n%s' "$absent_exp"; return 4; }
  # 逐项对账。存在性是台账里**明确写下来的**一列, 不靠"没写就当没有"
  while IFS=$'\t' read -r f ex now; do
    [[ -n "$f" ]] || continue; rows=$((rows+1))
    case "$ex" in
      present)
        valid=$((valid+1))
        if [[ ! -e "$f" ]]; then echo "       没了: $f(台账记的是 present)"; miss=$((miss+1)); continue; fi
        cur="$(keep_fp "$f")"
        [[ "$cur" == "$now" ]] || { echo "       变了: $f(台账 [$now] / 现在 [$cur])"; chg=$((chg+1)); };;
      absent)
        if [[ -e "$f" ]]; then echo "       凭空出现: $f(台账记的是 absent)"; appeared=$((appeared+1)); fi;;
      *)  echo "       台账这一行的存在性列不合法: $f [$ex]"; return 5;;
    esac
  done < "$led"
  (( valid > 0 )) || { printf '台账 %d 行, 但**零条有效记录**(没有一项 present)—— 不能据此说保留成功\n' "$rows"; return 2; }
  printf '有效记录 %d/%d 行; 缺失 %d 变化 %d 凭空出现 %d\n' "$valid" "$rows" "$miss" "$chg" "$appeared"
  (( miss == 0 && chg == 0 && appeared == 0 )) || return 1
  return 0
}
# <<< PDG-EXTRACT-END keep_compare
_KEEPSUM="$(keep_compare "$KEEP_LEDGER" "$KEEP_EXPECT")"; _KEEPRC=$?
printf '%s\n' "$_KEEPSUM" | grep -v '^有效记录' | sed 's/^/    /' || true
_KEEPBAD=$(( _KEEPRC == 0 ? 0 : 1 ))
[[ "$_KEEPRC" == 0 ]] \
  && ok "⑤-3a 用户数据/身份/凭据 $KEEP_N 项的存在性/内容/mode/uid:gid 全部原样(CA、iOS 记录与产物、平台标记、WLOC 配置、bot.env、dot-domain)" \
  || bad "⑤-3 保留项对账不过($(tail -1 <<<"$_KEEPSUM"); rc=$_KEEPRC) —— 上面逐项列出"
# ⑤-3b 代码与 unit: **允许**按候选更新, 但不许消失。"更新成了候选那一份"由 ⑤-1 的 ios
#       模块清单逐字节核对(那里比的是 $BRSRC), 这里只核存在性与"是不是被删了"。
_KC_GONE=(); _KC_SAME=0; _KC_UPD=0
for _f in "${KEEP_CODE[@]}"; do
  if [[ ! -e "$_f" ]]; then _KC_GONE+=("$_f"); continue; fi
  if [[ -n "${KEEP_CODE_FP[$_f]:-}" && "$(keep_fp "$_f")" == "${KEEP_CODE_FP[$_f]}" ]]; then
    _KC_SAME=$((_KC_SAME+1)); else _KC_UPD=$((_KC_UPD+1)); fi
done
[[ "${#_KC_GONE[@]}" == 0 ]] \
  && ok "⑤-3b 代码与 unit ${#KEEP_CODE[@]} 项全部仍在(未更新 $_KC_SAME / 已按候选更新 $_KC_UPD —— 更新是**允许**的, 删除才是退役动作)" \
  || bad "⑤-3b 有 ${#_KC_GONE[@]} 项代码/unit 被删掉了: ${_KC_GONE[*]} —— 那是退役动作"
# ⑤-3c 受管生成物: 允许被迁移重新生成, 但必须还在且非空
_KG_BAD=()
for _f in "${KEEP_GEN[@]}"; do [[ -s "$_f" ]] || _KG_BAD+=("$_f"); done
[[ "${#_KG_BAD[@]}" == 0 ]] \
  && ok "⑤-3c 受管生成物 ${#KEEP_GEN[@]} 项仍在且非空(内容允许被迁移按候选重新生成)" \
  || bad "⑤-3c 受管生成物没了或空了: ${_KG_BAD[*]}"
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] \
  && ok "⑤-3 平台标记仍是 ios(桥接入口沿用了已有标记, 没把 iOS 改成 Android)" || bad "⑤-3 平台标记变成了 $(cat /etc/privdns-gateway/platform)"
# 记录与产物在这一跳之后仍须有效, 且**槽位形态不能变** ——
# 这一跳既不该推进 schema, 也不该顶掉 previous、更不该凭空造出一版历史。
SLOTS_AFTER="$(ios_slots "$IOS_META" "$IOS_ART" "$OLDSRC/deploy/bot")"
_SV2="$(ios_slot_verdict "$SLOTS_AFTER" "$OLD_SCHEMA_CONST")"; _SVRC2=$?
printf '%s\n' "$_SV2" | sed 's/^/    /'
case "$_SVRC2" in
  0) ok "⑤-3 这一跳之后 iOS 槽位仍然自洽(存在性按记录判, 有效性由 iosstate.artifact_health 给: $(tail -1 <<<"$_SV2"))";;
  2) bad "⑤-3 这一跳之后 iOS 记录**读不出来** —— 读取失败, 不当成'槽位为空'";;
  *) bad "⑤-3 这一跳之后 iOS 槽位不自洽(上面逐项列出)";;
esac
if [[ "$SLOTS_AFTER" == "$SLOTS_BEFORE" ]]; then
  ok "⑤-3 iOS 槽位形态逐字节未变(schema、current/previous 的记录有无与文件在否, 前后完全一致)"
else
  bad "⑤-3 iOS 槽位形态变了 —— 前后差异:"
  diff <(printf '%s\n' "$SLOTS_BEFORE") <(printf '%s\n' "$SLOTS_AFTER") | sed 's/^/       /' || true
fi
grep -qE 'WLOC 退役|migrate_wloc_retire|已清理 iOS 专属残留' "$HOP_OUT" \
  && bad "⑤-3 安装日志里出现了退役动作的痕迹" || ok "⑤-3 安装日志里**没有**任何 WLOC 退役/iOS 专属件清理的痕迹"
svc_stable_assert mosdns      running "⑤-4 运行态: mosdns 持续运行" 5
svc_stable_assert mihomo      running "⑤-4 运行态: mihomo 持续运行" 5
svc_stable_assert pdg-mitm    running "⑤-4 运行态: pdg-mitm 仍持续运行(退役没发生)" 5
svc_stable_assert pdg-probe81 running "⑤-4 运行态: pdg-probe81 持续运行" 5
for _u in mosdns mihomo pdg-mitm pdg-probe81; do
  _en="$(sc_state is-enabled "$_u")"
  [[ "$_en" == enabled ]] && ok "⑤-4 自启态: $_u = enabled" || bad "⑤-4 自启态: $_u = $_en"
done
L7894_AFTER="$(ss -lnt 2>/dev/null | grep -c ':7894 ')"
mitm_listen_verdict "$(sc_state is-active pdg-mitm)" "$L7894_AFTER" \
  && ok "⑤-4 已加载配置: $MITM_VERDICT_WHY(前像监听数 $MITM_LISTEN_BEFORE → $L7894_AFTER)" \
  || bad "⑤-4 已加载配置不自洽: $MITM_VERDICT_WHY"
_DNSA="$(dig +time=3 +tries=1 @127.0.0.1 gs-loc.apple.com A +short 2>/dev/null | head -1)"
[[ -n "$_DNSA" ]] \
  && ok "⑤-4 实际功能: 本机 :53 真的答得出接管域名(gs-loc.apple.com → $_DNSA) —— 不是只看安装返回 0" \
  || bad "⑤-4 实际功能: :53 答不出接管域名(实得 '${_DNSA:-空}')"
_PDGV="$(pdg version 2>&1 | head -1 || true)"
note "⑤-4 已安装 CLI 自报: ${_PDGV:-<无输出>}"
# --- hop-chain-observe: BEGIN (与上面那段合起来就是被契约测试串联驱动的真实链路) ---
snap_state "hop-after"; bridge_svc_sample "$E2E_TMP/svc-hop-after.tsv"
# 窗口观测先收成文件, 再交给裁决 —— 读不出来就是 INVALID, 不是"没动过"。
# 只写 note 然后照报"意外 0", 等于把"没看见"说成"没发生"。
WIN_TSV="$E2E_TMP/svc-hop-window.tsv"; : > "$WIN_TSV"
for _u in "${SVC_WATCH[@]}"; do
  if [[ -z "${C_PROD0:-}" || -z "${C_PROD1:-}" ]]; then
    printf '%s\tINVALID\t界桩没建成: %s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"; continue
  fi
  if _n="$(_j_interval "$_u" "$C_PROD0" "$C_PROD1")" && [[ -n "$_n" ]]; then
    printf '%s\t%s\t-\n' "$_u" "$_n" >> "$WIN_TSV"
  else
    printf '%s\tINVALID\t%s\n' "$_u" "$(_j_why)" >> "$WIN_TSV"
  fi
done
sed 's/^/    /' "$WIN_TSV"
bridge_svc_verdict "$E2E_TMP/svc-hop-before.tsv" "$E2E_TMP/svc-hop-after.tsv" "hop" "$WIN_TSV"
# --- hop-chain-observe: END ---

SECT "⑥ 收尾"
{
  echo "# 本轮在这台一次性 runner 上创建/改动的东西"
  echo "  · /etc/{mosdns,mihomo,sing-box,privdns-gateway}/, /opt/{pdg-bot,privdns-gateway}, /var/lib/privdns-gateway"
  echo "  · /etc/systemd/system/{mosdns,mihomo,pdg-bot,pdg-probe81,pdg-mitm}.service"
  echo "  · 自有裸库 $ORIGIN, 旧版源码树 $OLDSRC, 桥接源码树 $BRSRC(都在本轮 \$E2E_TMP 里)"
  echo "  · 停用了 runner 自带的 systemd-resolved(为释放 :53)"
  echo "  全部落在这台一次性 runner 上; runner 随 job 结束销毁。"
  echo
  echo "# 身份"
  echo "  workflow checkout = ${GITHUB_SHA:-<非 CI>}"
  echo "  旧版  = $OLD_TAG → $OLD_SHA (CLI sha256 $OLD_CLI_SHA)"
  echo "  新入口 = 裸库 main → $BRIDGE_SHA (install.sh sha256 $ENTRY_SHA)"
  echo "  显式目标 = $BRIDGE_TAG → $BRIDGE_SHA; 安装后 HEAD=$HEAD_AFTER, CLI sha256=$CLI_SHA_AFTER"
  echo "  未被误装的更高版本 = $RETIRE_TAG → $RETIRE_SHA"
  echo
  echo "# 本支**没有**覆盖的(如实登记)"
  echo "  · 前像是夹具组装的, 不是 v1.11.15 完整安装器跑出来的;"
  echo "  · 取件源是本机裸库与合成 tag, 不是官方 Release —— 正式发布来源仍未验证;"
  echo "  · ③桥接→退役正常升级、④晚期失败恢复都不在本支范围内。"
  echo
  echo "# 证据文件"; ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-cleanup-hop.txt
chmod 600 "$EVID"/* 2>/dev/null || true
echo; echo "未执行(前像/前置不成立而跳过)的场景数: $E2E_NOTRUN"
e2e_summary
