#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 回滚的防火墙结算(S-2 桥接部分): cmd_rollback 里主规则加载、内网面板出站白名单的补回、相关的
# pdg-lan 重启与状态查询, 每一次的结果都要如实进入最终结算 —— 过程失败、未取得、记录不完整
# 都不许报"✅ 已回滚并重启服务"、都要返回 1; 后来的成功不抹掉先前的记录。
#
# 跑的是**产品原文**: cmd_rollback / _nft_apply_main / _lan_nft_reapply / _lan_apply_proxy /
# _lan_rollback_converge / _lan_artifacts_digest / _pdg_svc_q / _pdg_svc_known / _lan_intent /
# c_g / c_y 一律从 pdg.sh 抽出来。外部世界(systemctl、nft)按状态建模; 与本支无关的产品步骤
# 打桩, 清单在结尾逐条列出。
#
# cmd_rollback 中段有三处写死的宿主绝对路径(mihomo 配置判定、backend 落盘、mihomo.service 判定)。
# 抽出来之后**逐行精确替换**成本支自有根下的路径: 每处恰好命中一次, 其余文字一字不动, 于是
# 宿主上的任何路径都不读写。替换不成立就整支记"执行无效", 一格都不跑。
#
# 两种模式(PDG_FW_MODE):
#   pass(默认, CI 用) —— 每格按修复后的判据核对: [OK] / [FAIL];
#   repro              —— 对冻结版跑: 登记为缺陷的格只看缺陷是否复现([REPRO] / [NOREPRO]),
#                         其余格照常核对。
# 每格先结算执行是否有效(跑到结尾、取到退出码、没有 127、注入确实命中); 无效记 [INVALID],
# 既不算通过, 也不算复现。
#
# PDG_UNDER_TEST 可指向另一份 pdg.sh(负控用)。"开关关闭"那一格的冻结参照取 PDG_FW_FROZEN;
# 没给就从仓库取 6843905e 的那一份, 取不到记执行无效(不跳过)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="${PDG_UNDER_TEST:-$ROOT/deploy/bot/pdg.sh}"
MODE="${PDG_FW_MODE:-pass}"
FROZEN_REF=6843905e07af5957a3013cab06f11890757fc5e9
WORK="$(mktemp -d)" || { echo "[INVALID] 建不出临时目录"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
npass=0; nfail=0; nrep=0; nnorep=0; ninv=0
ok(){ echo "[OK]   $1"; npass=$((npass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
inv(){ echo "[INVALID] $1"; ninv=$((ninv+1)); }
case "$MODE" in pass|repro) ;; *) echo "[INVALID] 未知模式: $MODE"; exit 2;; esac
[[ -s "$PDG" ]] || { echo "[INVALID] 找不到被测 pdg.sh: $PDG"; exit 2; }
echo "被测: $PDG (sha256 $(sha256sum "$PDG" | cut -c1-16)); 模式: $MODE"

# ── 抽取 ────────────────────────────────────────────────────────────────────
# 单行形态只取那一行, 多行形态取到第一个顶格 }(单行函数按范围抽会读穿到下一个函数)。
# 抽不到、或抽出来的不以函数头开头、不以 } 收尾, 一律返回 1 —— 空串不能冒充"抽到了"。
fx(){   # $1=源文件 $2=函数名
  local ln first out
  ln="$(grep -n -m1 "^$2(){" "$1" | cut -d: -f1)"
  [[ -n "$ln" ]] || return 1
  first="$(sed -n "${ln}p" "$1")"
  if [[ "$first" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)\{.*\}[[:space:]]*$ ]]; then out="$first"
  else out="$(sed -n "${ln},/^}/p" "$1")"; fi
  [[ "$out" == "$2(){"* && "$(tail -n1 <<<"$out")" == *"}"* ]] || return 1
  printf '%s\n' "$out"
}

# cmd_rollback 中段的三处宿主绝对路径 → 本支自有根。逐行精确替换, 每处恰好命中一次;
# 替换前后行数不变、恰好只有这三行不同。任何一条不成立都返回 1。
RW_FROM=(
  '  if [[ ! -f /etc/mihomo/config.yaml ]] && [[ -f /etc/sing-box/config.json ]]; then'
  "  printf 'mihomo\\n' > /etc/privdns-gateway/backend"
  '  if [[ ! -s /etc/systemd/system/mihomo.service ]]; then'
)
RW_TO=(
  '  if [[ ! -f "$N1_ROOT/etc/mihomo/config.yaml" ]] && [[ -f "$N1_ROOT/etc/sing-box/config.json" ]]; then'
  "  printf 'mihomo\\n' > \"\$N1_ROOT/etc/privdns-gateway/backend\""
  '  if [[ ! -s "$N1_ROOT/etc/systemd/system/mihomo.service" ]]; then'
)
rewrite_paths(){   # stdin=抽出来的 cmd_rollback → stdout
  local body new i n
  body="$(cat)"; new="$body"
  for i in 0 1 2; do
    n="$(grep -cxF -- "${RW_FROM[$i]}" <<<"$new")"
    [[ "$n" == 1 ]] || { echo "路径替换锚点 $((i+1)) 命中 $n 次(应为 1)" >&2; return 1; }
    new="${new/"${RW_FROM[$i]}"/"${RW_TO[$i]}"}"
  done
  [[ "$(wc -l <<<"$new")" == "$(wc -l <<<"$body")" ]] || { echo "路径替换改变了行数" >&2; return 1; }
  n="$(diff <(printf '%s\n' "$body") <(printf '%s\n' "$new") | grep -c '^>')"
  [[ "$n" == 3 ]] || { echo "路径替换改动了 $n 行(应为 3)" >&2; return 1; }
  printf '%s\n' "$new"
}

REAL_FNS=(c_g c_y _pdg_svc_known _pdg_svc_q _lan_intent _lan_artifacts_digest
          _nft_apply_main _lan_nft_reapply _lan_apply_proxy _lan_rollback_converge)
mkclosure(){   # $1=源 pdg.sh $2=输出文件 $3=rb 时连 cmd_rollback 一起抽
  local src="$1" out="$2" fn body
  : > "$out" || return 1
  for fn in "${REAL_FNS[@]}"; do
    body="$(fx "$src" "$fn")" || { echo "抽不到 $fn" >&2; return 1; }
    printf '%s\n\n' "$body" >> "$out"
  done
  if [[ "${3:-}" == rb ]]; then
    body="$(fx "$src" cmd_rollback)" || { echo "抽不到 cmd_rollback" >&2; return 1; }
    body="$(rewrite_paths <<<"$body")" || return 1
    printf '%s\n' "$body" >> "$out"
  fi
  bash -n "$out" || { echo "抽取拼出来的闭包语法不过" >&2; return 1; }
}
CLO="$WORK/clo-under.sh"
if ! _err="$(mkclosure "$PDG" "$CLO" rb 2>&1)"; then
  echo "[INVALID] 被测闭包建不起来 —— 后面一格都不跑: $_err"
  echo "────────────────────────────────────────"
  echo "模式 $MODE: 通过 0, 失败 0, 复现成立 0, 复现不成立 0, 执行无效 1"
  exit 1
fi

# ── 外部世界模型与无关步骤的桩(不是产品函数) ─────────────────────────────────
# systemctl / nft 按**状态**回答, 不按调用次序: 冻结版与修复版查询次数不同, 按次序回答会让
# 同一格在两边看到不同的现场。"时段"由服务前像恢复那一步切换(它在 ① 与收敛之间), 用来造
# "中途状态变了"的现场; 重启成功之后 is-active 改答 N1_ACT_POST。
cat > "$WORK/stubs.sh" <<'STUBS'
need_root(){ :; }
_lock(){ :; }
_snap_meta_commit(){ echo ""; }
_snap_meta_label(){ echo l; }
_pdg_mktemp_dir(){ mktemp -d; }
_sb_panel_managed_on(){ return 1; }
_pdg_ios_verify_tree(){ return 0; }
_pdg_apply_snapshot_tree(){ echo APPLY >> "$N1_EV"; return 0; }
_pdg_svcstate_plan(){ return 0; }
_pdg_restore_svcstate(){ echo SVCRESTORE >> "$N1_EV"; echo late > "$N1_DIR/phase"; return 0; }
_pdg_kernel_converge(){ echo KCONV >> "$N1_EV"; return "${N1_KCONV:-0}"; }
pdg_write_unit(){ return 0; }
pdg_unit_mihomo(){ echo "[Unit]"; }
_pdg_drop_singbox_files(){ :; }
_pdg_singbox_is_ours(){ return 1; }
pdg_internal_cidr(){ echo 10.0.0.0/8; }
_lan_render(){
  echo RENDER >> "$N1_EV"
  if [[ "${N1_RENDER_CHANGE:-0}" == 1 ]]; then printf 'changed\n' >> "$LAN_CADDYFILE"; fi
  return "${N1_RENDER:-0}"
}
_lan_disable(){ echo LANDISABLE >> "$N1_EV"; return "${N1_DISABLE:-0}"; }
n1_phase(){ cat "$N1_DIR/phase" 2>/dev/null || echo early; }
n1_act(){   # pdg-lan 此刻的 is-active 回答: "词:退出码"
  if [[ -e "$N1_DIR/restarted" ]]; then echo "${N1_ACT_POST:-active:0}"
  elif [[ "$(n1_phase)" == late ]]; then echo "${N1_ACT_LATE:-${N1_ACT_EARLY:-inactive:3}}"
  else echo "${N1_ACT_EARLY:-inactive:3}"; fi
}
systemctl(){
  printf 'systemctl %s\n' "$*" >> "$N1_CALLS"
  local sub="${1:-}" q=0 a w r p err
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    is-active)
      if [[ "${1:-}" == --quiet ]]; then q=1; shift; fi
      if [[ "${1:-}" != pdg-lan ]]; then (( q )) || echo inactive; return 3; fi
      a="$(n1_act)"; w="${a%%:*}"; r="${a##*:}"
      if (( q == 0 )); then
        case "$w" in
          EMPTY) ;;
          GARBAGE) echo bogus-state;;
          MULTI) printf 'active\ninactive\n';;
          TRAILING) printf 'active\n\n';;
          *) echo "$w";;
        esac
        if [[ -e "$N1_DIR/restarted" ]]; then err="${N1_ACT_POST_ERR:-}"
        elif [[ "$(n1_phase)" == late ]]; then err="${N1_ACT_LATE_ERR:-${N1_ACT_ERR:-}}"
        else err="${N1_ACT_ERR:-}"; fi
        [[ -z "$err" ]] || printf '%s\n' "$err" >&2
      fi
      return "$r";;
    show)
      p=""
      for a in "$@"; do case "$a" in LoadState|NeedDaemonReload|ExecStartPre) p="$a";; esac; done
      case "$p" in
        LoadState)
          [[ "${N1_LS:-not-found}" == FAIL ]] && return 1
          if [[ "${N1_LS:-not-found}" == MULTI ]]; then printf 'not-found\nloaded\n'; else echo "${N1_LS:-not-found}"; fi
          [[ -z "${N1_LS_ERR:-}" ]] || printf '%s\n' "$N1_LS_ERR" >&2
          return "${N1_LS_RC:-0}";;
        NeedDaemonReload)
          [[ "${N1_NDR:-no}" == FAIL ]] && return 1
          if [[ "${N1_NDR:-no}" == MULTI ]]; then printf 'no\nyes\n'; else echo "${N1_NDR:-no}"; fi
          [[ -z "${N1_NDR_ERR:-}" ]] || printf '%s\n' "$N1_NDR_ERR" >&2
          return "${N1_NDR_RC:-0}";;
        ExecStartPre)
          case "${N1_ESP:-ok}" in
            FAIL) return 1;;
            ignore) echo "{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft -f $LAN_NFT_CONF ; ignore_errors=yes ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }";;
            wrongpath) echo "{ path=/bin/true ; argv[]=/usr/sbin/nft -f $LAN_NFT_CONF ; ignore_errors=no ; pid=0 }";;
            extraarg) echo "{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft -a -f $LAN_NFT_CONF ; ignore_errors=no ; pid=0 }";;
            env) echo "{ path=/usr/sbin/nft ; argv[]=env X=1 /usr/sbin/nft -f $LAN_NFT_CONF ; ignore_errors=no ; pid=0 }";;
            two) printf '{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft -f %s ; ignore_errors=no ; pid=0 } { path=/bin/true ; argv[]=/bin/true ; ignore_errors=no ; pid=0 }\n' "$LAN_NFT_CONF";;
            duplicate) echo "{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft -f $LAN_NFT_CONF ; ignore_errors=no ; path=/bin/true ; pid=0 }";;
            *) echo "{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft -f $LAN_NFT_CONF ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }";;
          esac
          [[ -z "${N1_ESP_ERR:-}" ]] || printf '%s\n' "$N1_ESP_ERR" >&2
          return "${N1_ESP_RC:-0}";;
        *) echo "";;
      esac
      return 0;;
    restart)
      [[ "${1:-}" == pdg-lan ]] || return 0
      [[ "${N1_RESTART:-0}" == 0 ]] || return 1
      : > "$N1_DIR/restarted"; return 0;;
  esac
  return 0
}
nft(){
  printf 'nft %s\n' "$*" >> "$N1_CALLS"
  local want
  [[ "${1:-}" == -f ]] || return 0
  if [[ "${2:-}" == "$LAN_NFT_CONF" ]]; then
    if [[ "$(n1_phase)" == late ]]; then want="${N1_LOAD_LATE:-${N1_LOAD_EARLY:-ok}}"; else want="${N1_LOAD_EARLY:-ok}"; fi
    [[ "$want" == ok ]] && return 0
    echo "nft: (注入) 白名单加载失败" >&2; return 1
  fi
  [[ "${N1_MAIN:-ok}" == ok ]] && return 0
  echo "nft: (注入) 主规则加载失败 N1-MAIN-FAIL" >&2; return 1
}
n1_seed(){
  : > "$N1_CALLS"; : > "$N1_EV"; echo early > "$N1_DIR/phase"; rm -f "$N1_DIR/restarted"
  rm -f "$LAN_CADDYFILE" "$LAN_UNIT" "$LAN_NFT_CONF"
  if [[ "${N1_INTENT:-off}" == on ]]; then
    printf 'PDG_LAN_ENABLED=1\n' > "$PROFILE_ENV"
    printf 'caddy v1\n' > "$LAN_CADDYFILE"; printf '[Service]\n' > "$LAN_UNIT"
  else
    printf 'PDG_INTERNAL_CIDR=10.0.0.0/8\n' > "$PROFILE_ENV"
  fi
  case "${N1_FILE:-absent}" in
    nonempty) printf 'table inet pdglan {}\n' > "$LAN_NFT_CONF";;
    empty) : > "$LAN_NFT_CONF";;
  esac
}
STUBS

# 三个只用在单格里的替身(产品函数的替身, 只为造出"记录有问题"的现场)
cat > "$WORK/ovr-I1.sh" <<'OVR'
_lan_apply_proxy(){
  [[ "${_pdg_rb_fw:-}" == 1 ]] && _pdg_rb_fwrec+=("P:begin n=$(( ${#_pdg_rb_fwrec[@]} + 1 )) t=${EPOCHREALTIME:-}")
  return 0
}
OVR
cat > "$WORK/ovr-I2.sh" <<'OVR'
_nft_apply_main(){ return 0; }
_lan_rollback_converge(){ return 0; }
OVR
cat > "$WORK/ovr-I3.sh" <<'OVR'
_lan_rollback_converge(){
  [[ "${_pdg_rb_fw:-}" == 1 ]] && _pdg_rb_fwrec+=("C:begin n=$(( ${#_pdg_rb_fwrec[@]} + 1 )) t=${EPOCHREALTIME:-} intent=off" "C:end n=$(( ${#_pdg_rb_fwrec[@]} + 2 )) t=${EPOCHREALTIME:-} br=off dis=none rc=0")
  return 1
}
OVR

# 快照与影子仓库: 快照只带一个普通文件; 影子仓库只给救援保护模式要读的那份常量
mkdir -p "$WORK/snaps/S1" "$WORK/stage/etc/privdns-gateway" "$WORK/repo/lib" "$WORK/cells"
printf 'x\n' > "$WORK/stage/etc/privdns-gateway/keep"
tar czf "$WORK/snaps/S1/snap.tar.gz" -C "$WORK/stage" etc 2>/dev/null \
  || { echo "[INVALID] 造不出快照"; exit 1; }
cat > "$WORK/repo/lib/rescue.sh" <<'RESCUE'
PDG_RESCUE_PORT=8443
pdg_rescue_protected(){ printf '%s\n' etc/privdns-gateway/keep; }
RESCUE

# ── 一格 = 一个独立的 bash 进程 ─────────────────────────────────────────────
# 模型 → 被测闭包 → (可选)本格替身 → 一次 cmd_rollback。结果读进 C_*: 去掉颜色的输出、
# cmd_rollback 的退出码、调用记录、事件记录。
C_OUT=""; C_RC=""; C_CALLS=""; C_EV=""; C_LANF=""
run_cell(){   # $1=格名 $2=闭包 $3=本格替身(可空) $4..=模型参数(形如 N1_X=y)
  local id="$1" clo="$2" ovr="$3" d="$WORK/cells/$1" kv
  shift 3
  mkdir -p "$d/root/etc/privdns-gateway" "$d/root/etc/systemd/system" "$d/root/etc/pdg-lan" "$d/st"
  {
    printf 'N1_DIR=%q\nN1_CALLS=%q\nN1_EV=%q\nN1_ROOT=%q\n' "$d/st" "$d/calls.log" "$d/events.log" "$d/root"
    printf 'SNAP_DIR=%q\nREPO_DIR=%q\n' "$WORK/snaps" "$WORK/repo"
    printf 'LAN_NFT_CONF=%q\nLAN_CADDYFILE=%q\nLAN_UNIT=%q\nPROFILE_ENV=%q\n' \
      "$d/root/etc/nftables-pdg-lan.conf" "$d/root/etc/pdg-lan/caddy.conf" \
      "$d/root/etc/systemd/system/pdg-lan.service" "$d/root/etc/privdns-gateway/profile.env"
    for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    printf 'source %q\nsource %q\n' "$WORK/stubs.sh" "$clo"
    if [[ -n "$ovr" ]]; then printf 'source %q\n' "$ovr"; fi
    echo 'unset _pdg_rb_fw _pdg_rb_fwrec'
    echo 'n1_seed'
    echo 'cmd_rollback --dir "$SNAP_DIR/S1" --no-git ${N1_ARGS:-}; echo "N1-RC=$?"'
    echo 'echo N1-END'
  } > "$d/cell.sh"
  bash "$d/cell.sh" > "$d/out.log" 2>&1
  C_OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$d/out.log")"
  C_RC="$(grep -o 'N1-RC=[0-9]*' <<<"$C_OUT" | tail -n1 | cut -d= -f2)"
  C_CALLS="$(cat "$d/calls.log" 2>/dev/null)"
  C_EV="$(cat "$d/events.log" 2>/dev/null)"
  C_LANF="$d/root/etc/nftables-pdg-lan.conf"
}
has(){ [[ "$C_OUT" == *"$1"* ]]; }
# 同一行里同时出现两段文字(报告里"第几条"与"结论"必须在同一行, 分在两行不算)
line_has(){ local l; while IFS= read -r l; do [[ "$l" == *"$1"* && "$l" == *"$2"* ]] && return 0; done <<<"$C_OUT"; return 1; }
cnt(){ grep -cF -- "$1" <<<"$C_CALLS" || true; }
# 公共的执行有效性: 跑到了结尾、取到了退出码、没有 127、走到了快照落盘。空 = 有效。
valid(){
  [[ "$C_OUT" == *N1-END* ]] || { echo "没跑到结尾"; return; }
  [[ "$C_RC" =~ ^[0-9]+$ ]] || { echo "没取到 cmd_rollback 的退出码"; return; }
  [[ "$C_OUT" != *"command not found"* ]] || { echo "出现 command not found(漏抽依赖)"; return; }
  [[ "$C_EV" == *APPLY* ]] || { echo "没走到快照落盘那一步"; return; }
}
# 结算一格: 先看执行是否有效; repro 模式下缺陷格只结算"复现成立 / 不成立"; 其余照判据核对。
settle(){   # $1=格名 $2=both|defect $3=无效原因(空=有效) $4=不符项(空=全部成立) $5=缺陷签名(1/0)
  if [[ -n "$3" ]]; then inv "$1: 执行无效 —— $3"; return; fi
  if [[ "$MODE" == repro && "$2" == defect ]]; then
    if [[ "${5:-0}" == 1 ]]; then echo "[REPRO] $1: 冻结版上缺陷复现成立"; nrep=$((nrep+1))
    else echo "[NOREPRO] $1: 冻结版上缺陷没有复现"; nnorep=$((nnorep+1)); fi
    return
  fi
  if [[ -z "$4" ]]; then ok "$1"; else bad "$1:$4"; fi
}
okline="✅ 已回滚并重启服务"
rc0_ok(){ [[ "$C_RC" == 0 ]] && has "$okline"; }        # 冻结版吞错时的那副样子

echo "══ 一. 健康与确认无需: 返回 0、报完整回滚、不多加载 ══"
run_cell H1 "$CLO" "" N1_ACT_EARLY=inactive:3 N1_FILE=absent
iv="$(valid)"; miss=""
[[ "$C_RC" == 0 ]] || miss+=" 退出码 $C_RC(应为 0);"
has "$okline" || miss+=" 没有完整回滚文案;"
[[ "$(cnt "nft -f $C_LANF")" == 0 ]] || miss+=" 执行了白名单加载;"
settle "H1 健康回滚(反代从未启用)" both "$iv" "$miss"
H1_IV="$iv"; H1_RC="$C_RC"; H1_OUT="$C_OUT"
miss=""
line_has "内网面板出站白名单: 截至第 2 条记录" "本观察时点无需补回(pdg-lan 确认不在运行)" || miss+=" 没报终态'本观察时点无需补回';"
sig=0; [[ "$H1_RC" == 0 && "$H1_OUT" == *"$okline"* && "$H1_OUT" != *"内网面板出站白名单:"* ]] && sig=1
settle "H1r 健康回滚的终态报告(只依据最后一次观察)" defect "$H1_IV" "$miss" "$sig"

for spec in "N1|failed:3|nonempty|" "N2|inactive:4|absent|not-found"; do
  IFS='|' read -r id act file ls <<<"$spec"
  run_cell "$id" "$CLO" "" "N1_ACT_EARLY=$act" "N1_FILE=$file" "N1_LS=${ls:-loaded}"
  iv="$(valid)"; miss=""
  [[ "$C_RC" == 0 ]] || miss+=" 退出码 $C_RC(应为 0);"
  has "$okline" || miss+=" 没有完整回滚文案;"
  [[ "$(cnt "nft -f $C_LANF")" == 0 ]] || miss+=" 执行了白名单加载;"
  settle "$id 确认无需补回(is-active=$act, 文件 $file, LoadState=${ls:-loaded})" both "$iv" "$miss"
done

echo
echo "══ 二. 主规则加载失败: 照实计入, 后续恢复照常做 ══"
run_cell M1 "$CLO" "" N1_MAIN=fail N1_ACT_EARLY=active:0 N1_FILE=nonempty
iv="$(valid)"; [[ -z "$iv" && "$(cnt 'nft -f /etc/nftables.conf')" != 1 ]] && iv="主规则加载没有恰好调用一次(注入没命中)"
miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
has "防火墙主规则加载(nft 返回 1)" || miss+=" 未恢复项没点名主规则加载;"
has "N1-MAIN-FAIL" || miss+=" nft 的原始报错被吞了;"
[[ "$(cnt "nft -f $C_LANF")" == 1 ]] || miss+=" 主规则失败后没有照常补回白名单;"
[[ "$C_EV" == *KCONV*SVCRESTORE* ]] || miss+=" 后续恢复步骤没有照常执行;"
sig=0; rc0_ok && sig=1
settle "M1 主规则加载失败" defect "$iv" "$miss" "$sig"

run_cell M2 "$CLO" "" N1_MAIN=fail N1_ARGS=--preserve-rescue
iv="$(valid)"
[[ -z "$iv" ]] && ! has "保留当前救援平面文件(不恢复)" && iv="没走到救援保护模式"
[[ -z "$iv" && "$(cnt 'nft -f /etc/nftables.conf')" != 1 ]] && iv="主规则加载没有恰好调用一次(注入没命中)"
miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
has "防火墙主规则加载(nft 返回 1)" || miss+=" 未恢复项没点名主规则加载;"
sig=0; rc0_ok && sig=1
settle "M2 救援保护模式下主规则加载失败" defect "$iv" "$miss" "$sig"

run_cell M3 "$CLO" "" N1_ARGS=--preserve-rescue
iv="$(valid)"
[[ -z "$iv" ]] && ! has "保留当前救援平面文件(不恢复)" && iv="没走到救援保护模式"
miss=""
[[ "$C_RC" == 0 ]] || miss+=" 退出码 $C_RC(应为 0);"
has "$okline" || miss+=" 没有完整回滚文案;"
settle "M3 救援保护模式健康回滚" both "$iv" "$miss"

echo
echo "══ 三. ① 主规则之后那一次补回: 加载失败 / 反代在跑却没有文件 / 状态未取得 ══"
run_cell L1 "$CLO" "" N1_ACT_EARLY=active:0 N1_FILE=nonempty N1_LOAD_EARLY=fail
iv="$(valid)"; [[ -z "$iv" && "$(cnt "nft -f $C_LANF")" != 1 ]] && iv="白名单加载没有恰好调用一次(注入没命中)"
miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
has "内网面板的出站白名单没能重新加载" || miss+=" 加载失败的警告被吞了;"
line_has "过程失败: 第 2 条记录(①主规则之后的补回" "补回加载失败" || miss+=" 报告没点名第 2 条补回加载失败;"
sig=0; rc0_ok && ! has "内网面板的出站白名单没能重新加载" && sig=1
settle "L1 白名单补回加载失败" defect "$iv" "$miss" "$sig"

for spec in "F1|absent" "F2|empty"; do
  IFS='|' read -r id file <<<"$spec"
  run_cell "$id" "$CLO" "" N1_ACT_EARLY=active:0 "N1_FILE=$file"
  iv="$(valid)"; miss=""
  [[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
  has "✅" && miss+=" 仍报了 ✅;"
  line_has "第 2 条记录(①主规则之后的补回" "需要补回但所需文件缺失或为空" || miss+=" 报告没说需要补回但文件缺失或为空;"
  [[ "$(cnt "nft -f $C_LANF")" == 0 ]] || miss+=" 竟然执行了加载;"
  sig=0; rc0_ok && sig=1
  settle "$id 反代确认在运行, 但白名单文件$([[ $file == absent ]] && echo 缺失 || echo 为空)" defect "$iv" "$miss" "$sig"
done

U1_IV=""; U1_RC=""; U1_OUT=""
for spec in "U1|GARBAGE:1|loaded|状态词认不出" "U2|EMPTY:1|FAIL|无输出且 LoadState 取不到" \
            "U3|inactive:1|loaded|退出码不在登记集合内" "U4|activating:3|loaded|过渡态"; do
  IFS='|' read -r id act ls why <<<"$spec"
  run_cell "$id" "$CLO" "" "N1_ACT_EARLY=$act" N1_FILE=absent "N1_LS=$ls"
  iv="$(valid)"; miss=""
  [[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
  has "✅" && miss+=" 仍报了 ✅;"
  line_has "第 2 条记录(①主规则之后的补回" "是否需要补回未取得" || miss+=" 报告没说是否需要补回未取得;"
  [[ "$(cnt "nft -f $C_LANF")" == 0 ]] || miss+=" 竟然执行了加载;"
  sig=0; rc0_ok && sig=1
  settle "$id 服务状态未取得($why) + 文件缺失" defect "$iv" "$miss" "$sig"
  [[ "$id" == U1 ]] && { U1_IV="$iv"; U1_RC="$C_RC"; U1_OUT="$C_OUT"; }
done

# N3 原来把空输出当成确认无需, 与批准规则冲突。这里在运行前改为 U9,
# 并与 stderr、多行和查询失败的反例一起验证; 不给缺失读数补一个健康状态。
for spec in \
  'U5|active:0|nonempty|N1_ACT_ERR=query-warning' \
  'U6|MULTI:0|nonempty|' \
  'U7|inactive:4|absent|N1_LS_RC=1' \
  'U8|inactive:4|absent|N1_LS=MULTI' \
  'U9|EMPTY:4|nonempty|' \
  'U10|TRAILING:0|nonempty|' \
  'U11|inactive:4|absent|N1_LS_ERR=query-warning'; do
  IFS='|' read -r id act file extra <<< "$spec"
  args=("N1_ACT_EARLY=$act" "N1_FILE=$file")
  [[ -z "$extra" ]] || args+=("$extra")
  run_cell "$id" "$CLO" "" "${args[@]}"
  iv="$(valid)"; miss=""
  [[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
  has "✅" && miss+=" 仍报了 ✅;"
  line_has '第 2 条记录(①主规则之后的补回' '是否需要补回未取得' || miss+=" 查询无效未如实报告;"
  want_load=0; [[ "$file" == nonempty && "$act" == *:0 ]] && want_load=1
  [[ "$(cnt "nft -f $C_LANF")" == "$want_load" ]] || miss+=" 改变了原有加载动作边界;"
  sig=0; rc0_ok && sig=1
  settle "$id 无效查询不能当成确认依据" defect "$iv" "$miss" "$sig"
done

# X1 不另跑: 拿 U1(未取得 + 文件缺失)与 H1(确认不在运行 + 文件缺失)两格对照 —— 结论必须不同
iv=""; [[ -n "$U1_IV" || -n "$H1_IV" ]] && iv="对照的两格本身执行无效"
miss=""
[[ "$U1_RC" == 1 && "$H1_RC" == 0 ]] || miss+=" 退出码没分开(未取得=$U1_RC, 确认无需=$H1_RC);"
[[ "$U1_OUT" == *"是否需要补回未取得"* ]] || miss+=" 未取得那一格没报'是否需要补回未取得';"
[[ "$H1_OUT" == *"本观察时点无需补回"* ]] || miss+=" 确认无需那一格没报'本观察时点无需补回';"
sig=0; [[ "$U1_RC" == 0 && "$H1_RC" == 0 ]] && sig=1
settle "X1 未取得与确认无需对照(同为文件缺失, 结论必须不同)" defect "$iv" "$miss" "$sig"

echo
echo "══ 四. 先后两次补回: 后来的成功不抹掉先前的失败, 也不只看第一次 ══"
run_cell S1 "$CLO" "" N1_INTENT=on N1_ACT_EARLY=active:0 N1_FILE=nonempty N1_LOAD_EARLY=ok N1_LOAD_LATE=fail
iv="$(valid)"; [[ -z "$iv" && "$(cnt "nft -f $C_LANF")" != 2 ]] && iv="白名单加载没有恰好调用两次"
miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
line_has "记录: 第 2 条记录(①主规则之后的补回" "已补回" || miss+=" 报告里没有第 2 条已补回;"
line_has "过程失败: 第 7 条记录(③指纹相同时的补回" "补回加载失败" || miss+=" 报告里没有第 7 条补回加载失败;"
has "内网面板的出站白名单没能重新加载" || miss+=" 第二次失败的警告不见了;"
sig=0; rc0_ok && sig=1
settle "S1 初次补回成功、后续补回失败" defect "$iv" "$miss" "$sig"

run_cell S2 "$CLO" "" N1_INTENT=on N1_ACT_EARLY=active:0 N1_FILE=nonempty N1_LOAD_EARLY=fail N1_LOAD_LATE=ok
iv="$(valid)"; [[ -z "$iv" && "$(cnt "nft -f $C_LANF")" != 2 ]] && iv="白名单加载没有恰好调用两次"
miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
line_has "过程失败: 第 2 条记录(①主规则之后的补回" "补回加载失败" || miss+=" 第 2 条的失败被抹掉了;"
line_has "后续成功: 第 7 条记录(③指纹相同时的补回" "已补回" || miss+=" 没写第 7 条后续成功;"
line_has "终态: 截至第 7 条记录" "已补回" || miss+=" 终态没按最后一次观察写成已补回;"
has "终态未取得" && miss+=" 把终态写成了未取得;"
sig=0; rc0_ok && sig=1
settle "S2 初次补回失败、后续补回成功(写清先败后成, 不称终态错误)" defect "$iv" "$miss" "$sig"

echo
echo "══ 五. ③ 指纹不同 → 重启: 只按有效 unit 推断, 依据缺一项就不算确认 ══"
R4_IV=""; R4_OUT=""; R4_RC=""
for spec in "R1|N1_ESP=ok|N1_NDR=no|N1_RESTART=0" "R2|N1_ESP=FAIL|N1_NDR=no|N1_RESTART=0" \
            "R3|N1_ESP=ok|N1_NDR=yes|N1_RESTART=0" "R4|N1_ESP=ok|N1_NDR=no|N1_RESTART=1"; do
  IFS='|' read -r id e1 e2 e3 <<<"$spec"
  run_cell "$id" "$CLO" "" N1_INTENT=on N1_ACT_EARLY=active:0 N1_FILE=nonempty N1_RENDER_CHANGE=1 "$e1" "$e2" "$e3"
  iv="$(valid)"; [[ -z "$iv" && "$(cnt 'systemctl restart pdg-lan')" != 1 ]] && iv="重启没有恰好调用一次(没走到重启分支)"
  miss=""; sig=0
  case "$id" in
    R1)
      [[ "$C_RC" == 0 ]] || miss+=" 退出码 $C_RC(应为 0);"
      has "$okline" || miss+=" 没有完整回滚文案;"
      line_has "内网面板出站白名单: 截至第 7 条记录" "按有效 unit 推断白名单已随重启加载, 未独立观测" || miss+=" 没注明'按有效 unit 推断, 未独立观测';"
      rc0_ok && ! has "按有效 unit 推断" && sig=1
      settle "R1 健康的重启分支(依据齐全)" defect "$iv" "$miss" "$sig";;
    R2|R3)
      [[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
      has "✅" && miss+=" 仍报了 ✅;"
      line_has "第 7 条记录(③重启 pdg-lan" "白名单是否随之加载未确认" || miss+=" 没记'重启成功, 白名单是否随之加载未确认';"
      rc0_ok && sig=1
      settle "$id 重启成功但推断依据未取得($([[ $id == R2 ]] && echo 'ExecStartPre 查不到' || echo 'NeedDaemonReload=yes'))" defect "$iv" "$miss" "$sig";;
    R4)
      [[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
      has "✅" && miss+=" 仍报了 ✅;"
      has "内网面板派生产物" || miss+=" 收敛失败没计入未恢复项;"
      has "pdg-lan 重启失败" || miss+=" 没报重启失败;"
      settle "R4 重启失败(原有的收敛失败判据照旧)" both "$iv" "$miss"
      R4_IV="$iv"; R4_OUT="$C_OUT"; R4_RC="$C_RC";;
  esac
done
C_OUT="$R4_OUT"; miss=""
line_has "过程失败: 第 7 条记录(③重启 pdg-lan" "pdg-lan 重启失败" || miss+=" 报告没点名第 7 条重启失败;"
has "终态未取得: 截至第 7 条记录" || miss+=" 没写终态未取得;"
sig=0; [[ "$R4_RC" == 1 && "$R4_OUT" != *"内网面板出站白名单:"* ]] && sig=1
settle "R4r 重启失败的过程报告与终态" defect "$R4_IV" "$miss" "$sig"

for spec in \
  'R5|N1_NDR_RC=1' 'R6|N1_ESP_RC=1' \
  'R7|N1_ESP=wrongpath' 'R8a|N1_ESP=extraarg' 'R8b|N1_ESP=env' \
  'R9|N1_ESP=two' 'R10|N1_ACT_POST_ERR=query-warning' \
  'R11|N1_ESP=duplicate' 'R12|N1_NDR=MULTI' \
  'R13|N1_ESP_ERR=query-warning' 'R14|N1_NDR_ERR=query-warning'; do
  IFS='|' read -r id extra <<< "$spec"
  run_cell "$id" "$CLO" "" N1_INTENT=on N1_ACT_EARLY=active:0 N1_FILE=nonempty N1_RENDER_CHANGE=1 "$extra"
  iv="$(valid)"; miss=""
  [[ "$(cnt 'systemctl restart pdg-lan')" == 1 ]] || iv="没有恰好执行一次重启"
  [[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
  has "✅" && miss+=" 仍报了 ✅;"
  line_has '第 7 条记录(③重启 pdg-lan' '白名单是否随之加载未确认' || miss+=" 无效重启依据未被拒绝;"
  sig=0; rc0_ok && sig=1
  settle "$id 重启依据必须完整有效且绑定准确命令" defect "$iv" "$miss" "$sig"
done

echo
echo "══ 六. ② 反代入口: 状态未取得而跳过, 不当成'确认不在运行' ══"
run_cell P1u "$CLO" "" N1_INTENT=on N1_ACT_EARLY=inactive:3 N1_ACT_LATE=GARBAGE:1 N1_FILE=absent
iv="$(valid)"; [[ -z "$iv" && "$C_EV" != *RENDER* ]] && iv="没走到收敛的启用分支"
miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
line_has "第 5 条记录(②反代入口" "pdg-lan 状态未取得而跳过" || miss+=" 没记'状态未取得而跳过';"
sig=0; rc0_ok && sig=1
settle "P1u 反代入口状态未取得而跳过" defect "$iv" "$miss" "$sig"

echo
echo "══ 七. 记录完整性: 应有的缺了、整份为空、自报与真实返回值不符 ══"
run_cell I1 "$CLO" "$WORK/ovr-I1.sh" N1_INTENT=on N1_ACT_EARLY=inactive:3
iv="$(valid)"; miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
has "白名单记录不完整" || miss+=" 没报记录不完整;"
has "第 5 条(C:end)与实际经过的分支不符" || miss+=" 没指出缺的是反代入口的结束;"
sig=0; rc0_ok && sig=1
settle "I1 应有记录缺失(反代入口有开始、缺结束)" defect "$iv" "$miss" "$sig"

run_cell I2 "$CLO" "$WORK/ovr-I2.sh"
iv="$(valid)"; miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
has "白名单记录不完整: 记录意外为空" || miss+=" 没报记录意外为空;"
sig=0; rc0_ok && sig=1
settle "I2 记录意外为空(不能拿'没有失败条目'当成功)" defect "$iv" "$miss" "$sig"

run_cell I3 "$CLO" "$WORK/ovr-I3.sh"
iv="$(valid)"; miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "白名单记录不完整" || miss+=" 没报记录不完整;"
has "第 4 条(C:end)自相矛盾或与真实返回值对不上" || miss+=" 没指出收敛自报与真实返回值不符;"
sig=0; [[ "$C_RC" == 1 ]] && ! has "白名单记录不完整" && sig=1
settle "I3 收敛自报的返回值与真实返回值不符" defect "$iv" "$miss" "$sig"

echo
echo "══ 八. 原有的其它回滚判据照旧保留 ══"
run_cell K1 "$CLO" "" N1_KCONV=1
iv="$(valid)"; miss=""
[[ "$C_RC" == 1 ]] || miss+=" 退出码 $C_RC(应为 1);"
has "✅" && miss+=" 仍报了 ✅;"
has "内核收敛(mihomo/sing-box)" || miss+=" 原有的内核收敛未恢复项不见了;"
has "内网面板出站白名单: 本次回滚未能确认" && miss+=" 白名单本来合格, 却被报成未能确认;"
settle "K1 白名单合格、内核收敛失败: 原有未恢复项照报" both "$iv" "$miss"

echo
echo "══ 九. 开关关闭(回滚以外的调用者): 与冻结原文逐一相同 ══"
O_SCEN=(
  'o1|N1_ACT_EARLY=active:0 N1_FILE=absent|_lan_nft_reapply'
  'o2|N1_ACT_EARLY=active:0 N1_FILE=nonempty|_lan_nft_reapply'
  'o3|N1_ACT_EARLY=active:0 N1_FILE=nonempty N1_LOAD_EARLY=fail|_lan_nft_reapply'
  'o4|N1_ACT_EARLY=GARBAGE:1 N1_FILE=nonempty|_lan_nft_reapply'
  'o5|N1_ACT_EARLY=inactive:3 N1_INTENT=on|_lan_apply_proxy'
  'o6|N1_ACT_EARLY=active:0 N1_INTENT=on N1_FILE=nonempty|_lan_apply_proxy "$(_lan_artifacts_digest)"'
  'o7|N1_ACT_EARLY=active:0 N1_INTENT=on N1_FILE=nonempty|_lan_apply_proxy stale-digest'
  'o8|N1_ACT_EARLY=active:0 N1_INTENT=on N1_RESTART=1|_lan_apply_proxy stale-digest'
  'o9|N1_ACT_EARLY=active:0 N1_INTENT=on|_lan_apply_proxy'
  'o10|N1_ACT_EARLY=active:0 N1_INTENT=on N1_FILE=nonempty|_lan_rollback_converge'
  'o11|N1_ACT_EARLY=active:0|_lan_rollback_converge'
  'o12|N1_ACT_EARLY=inactive:3|_lan_rollback_converge'
  'o13|N1_ACT_EARLY=active:0 N1_INTENT=on N1_RENDER=1|_lan_rollback_converge'
  'o14|N1_ACT_EARLY=active:0 N1_FILE=nonempty|_nft_apply_main'
  'o15|N1_ACT_EARLY=active:0 N1_FILE=nonempty N1_MAIN=fail|_nft_apply_main'
)
run_o(){   # $1=闭包 $2=场景目录 $3=模型参数(空格分隔) $4=调用 → 在 $2 下留 out / calls / events
  local clo="$1" d="$2" envs="$3" call="$4" kv
  mkdir -p "$d/root/etc/privdns-gateway" "$d/root/etc/systemd/system" "$d/root/etc/pdg-lan" "$d/st"
  {
    printf 'N1_DIR=%q\nN1_CALLS=%q\nN1_EV=%q\nN1_ROOT=%q\n' "$d/st" "$d/calls.log" "$d/events.log" "$d/root"
    printf 'LAN_NFT_CONF=%q\nLAN_CADDYFILE=%q\nLAN_UNIT=%q\nPROFILE_ENV=%q\n' \
      "$d/root/etc/nftables-pdg-lan.conf" "$d/root/etc/pdg-lan/caddy.conf" \
      "$d/root/etc/systemd/system/pdg-lan.service" "$d/root/etc/privdns-gateway/profile.env"
    for kv in $envs; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    printf 'source %q\nsource %q\n' "$WORK/stubs.sh" "$clo"
    echo 'unset _pdg_rb_fw _pdg_rb_fwrec'
    echo 'n1_seed'
    printf '%s; echo "O-RC=$?"\n' "$call"
    echo 'echo O-END'
  } > "$d/o.sh"
  bash "$d/o.sh" > "$d/out.log" 2>&1
}
FROZEN="${PDG_FW_FROZEN:-}"
if [[ -z "$FROZEN" ]]; then
  FROZEN="$WORK/frozen-pdg.sh"
  git -C "$ROOT" show "$FROZEN_REF:deploy/bot/pdg.sh" > "$FROZEN" 2>/dev/null || : > "$FROZEN"
fi
iv=""; miss=""
if [[ ! -s "$FROZEN" ]]; then iv="取不到冻结参照($FROZEN_REF)"
elif ! _err="$(mkclosure "$FROZEN" "$WORK/clo-frozen-o.sh" 2>&1)"; then iv="冻结参照抽不出闭包: $_err"
elif ! _err="$(mkclosure "$PDG" "$WORK/clo-under-o.sh" 2>&1)"; then iv="被测文件抽不出闭包: $_err"
else
  for s in "${O_SCEN[@]}"; do
    IFS='|' read -r oid envs call <<<"$s"
    d="$WORK/cells/O1-$oid"
    run_o "$WORK/clo-frozen-o.sh" "$d" "$envs" "$call"
    for f in out calls events; do mv -f "$d/$f.log" "$d/$f.frozen" 2>/dev/null || : > "$d/$f.frozen"; done
    run_o "$WORK/clo-under-o.sh" "$d" "$envs" "$call"
    if ! grep -q 'O-END' "$d/out.frozen" || ! grep -q 'O-END' "$d/out.log"; then iv="场景 $oid 没跑到结尾"; break; fi
    for f in out calls events; do
      cmp -s "$d/$f.frozen" "$d/$f.log" || miss+=" $oid 的 $f 与冻结原文不同;"
    done
  done
fi
settle "O1 开关关闭: 返回值、输出、systemctl/nft 调用序列与冻结原文逐一相同(15 个场景)" both "$iv" "$miss"

echo
echo "──────── 本支替换掉的产品函数, 以及因此未覆盖的性质 ────────"
cat <<'NOTE'
  need_root / _lock                         → 未覆盖: 真实取锁
  _snap_meta_commit / _snap_meta_label      → 未覆盖: 快照元数据(本支一律 --no-git)
  _pdg_mktemp_dir / _sb_panel_managed_on     → 未覆盖: 临时目录分配、面板托管判定
  _pdg_ios_verify_tree / _pdg_apply_snapshot_tree → 未覆盖: iOS 联合校验、真实落盘
  _pdg_svcstate_plan / _pdg_restore_svcstate → 未覆盖: 服务前像(由 test-update-rollback / test-rollback-svcstate-chain 覆盖)
  _pdg_kernel_converge / pdg_write_unit / pdg_unit_mihomo / _pdg_drop_singbox_files → 未覆盖: 内核收敛与 unit 生成
  _lan_render / _lan_disable                 → 未覆盖: 派生产物渲染与停用(由 test-lan-rollback-convergence 覆盖)
  systemctl / nft                            → 模型, 未覆盖真实 systemd 与内核
  ⇒ 这一支证明的是**结算与记录的判据**; 重启分支的"白名单已加载"本来就只是推断, 不是观测。
NOTE
echo "────────────────────────────────────────"
echo "模式 $MODE: 通过 $npass, 失败 $nfail, 复现成立 $nrep, 复现不成立 $nnorep, 执行无效 $ninv"
if [[ "$MODE" == repro ]]; then
  [[ "$nfail" == 0 && "$ninv" == 0 && "$nnorep" == 0 && "$nrep" -gt 0 ]]
else
  [[ "$nfail" == 0 && "$ninv" == 0 && "$npass" -gt 0 ]]
fi
