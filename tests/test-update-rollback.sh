#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 更新快照 + 精确回滚回归(Item 10)。
#   A. 有效服务前像的健康快照: 文件 / Git / 服务模型后置状态**分别**成立, rc=0, 完整恢复文案;
#   A0. 精确快照选择(--dir 指定的那份, 不被 index0 顶掉)与默认 index0;
#   B. **缺**服务前像的历史快照: 文件与 Git 仍按契约恢复, 但"运行态/自启未确认"必须计入
#      未恢复项、返回非零、不声称完整恢复 —— 这条真实兼容性边界保留, 不改成成功;
#   C. 指定故障各自命中自己的原因: Git 目标失效 / 内核收敛失败 / 快照内核校验失败;
#   B2/B3. 元数据派生 Git 目标与字面量 unknown 的处置;
#   D. 静态: cmd_update 快照失败即中止; 精确 --dir+--git; 快照候选集; 越界守卫。
#
# ── 隔离(本轮加) ────────────────────────────────────────────────────────────
# cmd_rollback 会**直接写绝对路径**(/etc/privdns-gateway/backend、/etc/mihomo、
# /etc/systemd/system/... )。以前本壳只覆写了"快照落盘"那一个函数, 其余绝对路径写入照样
# 打在宿主上 —— 在开发机上表现为 Permission denied, 在有权限的机器上就是真的改了宿主。
# 现在整支在 `unshare -rm`(用户+挂载命名空间)里跑, 把 /etc、/var/lib、/usr/local/bin、
# /opt、/run 绑到本轮自有的隔离根。**隔离先成立, 才允许运行被测函数**; 隔离不成立就明确
# 报"未执行"并非零退出, 不退回宿主、不靠"宿主没权限"兜底, 也不给产品加测试开关。
#
# ── 真身 / 模型的边界 ───────────────────────────────────────────────────────
# 真身(抽自 deploy/bot/pdg.sh, 本壳正在核验的就是它们的决策与未恢复项累计):
#   cmd_rollback · _snap_meta_commit · _snap_meta_label · _pdg_svcstate_plan ·
#   _pdg_svcstate_valid · _pdg_svcstate_units · _pdg_save_svcstate · _pdg_restore_svcstate ·
#   _pdg_kernel_converge · _pdg_svc_q · _pdg_svc_known · _pdg_now_en · _pdg_now_ac ·
#   _pdg_set_enable_state · _nft_apply_main
# 模型(外部世界, 不冒充真实服务验证):
#   systemctl —— 按产品注释里记录的真实 enable/disable 语义做的状态机, 不连真 systemd;
#   nft / mihomo / sing-box 二进制 · _core_kernel_activate(可控) · 内网面板收敛 · iOS 校验。
# 因此本壳的"服务后置状态成立"指的是**模型后置状态**, 不是真实 systemd 验收。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
# ═══ 隔离层: 先成立, 再运行被测函数 ═══════════════════════════════════════════
if [[ -z "${PDG_RB_ISO:-}" ]]; then
  echo "── 本壳可达的绝对路径写入面(清点, 也是必须隔离的理由) ──"
  echo "   /etc/privdns-gateway/backend · /etc/mihomo · /etc/systemd/system/*.service ·"
  echo "   /etc/sing-box 残留清理 · 快照树落盘到 / · /run 与 /var/lib 下的派生物"
  echo "   外部服务动作: systemctl(daemon-reload/enable/disable/start/stop/show) · nft · 内核二进制"
  if ! unshare -rm true 2>/dev/null; then
    echo "[未执行] 本环境不支持 unshare -rm(用户+挂载命名空间)。"
    echo "         隔离不成立 ⇒ **没有运行任何被测函数**; 不退回宿主, 也不靠'宿主没权限'兜底。"
    exit 2
  fi
  ISO="$(mktemp -d "${TMPDIR:-/tmp}/pdg-rbiso.XXXXXX")" || { echo "[未执行] 建不出隔离根"; exit 2; }
  mkdir -p "$ISO"/etc "$ISO"/varlib "$ISO"/localbin "$ISO"/opt "$ISO"/run || { echo "[未执行] 隔离根建不全"; rm -rf "$ISO"; exit 2; }
  cp -a /etc/. "$ISO/etc/" 2>/dev/null || true       # 产品有大量写死的 /etc 路径, 整份复制一次最干净
  mkdir -p "$ISO/etc/privdns-gateway" "$ISO/etc/systemd/system" "$ISO/etc/mihomo" "$ISO/etc/sing-box"
  : > "$ISO/etc/.pdg-rollback-iso"                   # 自检标记: 内层看到它才说明 /etc 是本轮的隔离根
  # 宿主对照**只读取**, 不往宿主写任何探针
  _host_be="/etc/privdns-gateway/backend"
  _host_before="$( [[ -e "$_host_be" ]] && sha256sum "$_host_be" 2>/dev/null | cut -d" " -f1 || echo "<不存在>")"
  # 隔离保护的**定向反例**: 给一个缺自检标记的隔离根, 必须报"未执行"并非零,
  # 且一条被测断言都不许跑 —— 否则"隔离先成立才运行"这句话就没有实据。
  _neg="$(mktemp -d)"; mkdir -p "$_neg"/etc "$_neg"/varlib "$_neg"/localbin "$_neg"/opt "$_neg"/run
  _nrc=0; _nout="$(PDG_RB_ISO="$_neg" unshare -rm bash "$0" 2>&1)" || _nrc=$?
  rm -rf "$_neg"
  if [[ "$_nrc" != 0 && "$_nout" == *"[未执行]"* && "$_nout" != *"[OK]"* ]]; then
    echo "[OK]   隔离反例: 隔离根缺自检标记 ⇒ 报'未执行'并非零退出($_nrc), 零断言"
  else
    echo "[FAIL] 隔离反例: 缺标记时没有停(rc=$_nrc)"; echo "$_nout" | head -3 | sed 's/^/       /'
    _neg_failed=1
  fi
  _rc=0
  PDG_RB_ISO="$ISO" unshare -rm bash "$0" "$@" || _rc=$?
  [[ -n "${_neg_failed:-}" ]] && _rc=1
  _host_after="$( [[ -e "$_host_be" ]] && sha256sum "$_host_be" 2>/dev/null | cut -d" " -f1 || echo "<不存在>")"
  if [[ "$_host_before" == "$_host_after" ]]; then
    echo "[OK]   隔离复核(宿主侧): $_host_be 在整支运行前后一致($_host_before)"
  else
    echo "[FAIL] 隔离复核(宿主侧): $_host_be 被改动了($_host_before → $_host_after)"; _rc=1
  fi
  rm -rf "$ISO"
  exit "$_rc"
fi
# ── 内层: 绑定挂载 + 自检 ────────────────────────────────────────────────────
for _m in "$PDG_RB_ISO/etc:/etc" "$PDG_RB_ISO/varlib:/var/lib" "$PDG_RB_ISO/localbin:/usr/local/bin" \
          "$PDG_RB_ISO/opt:/opt" "$PDG_RB_ISO/run:/run"; do
  mount --bind "${_m%%:*}" "${_m##*:}" 2>/dev/null \
    || { echo "[未执行] 绑定失败: $_m ⇒ 隔离不成立, 未运行被测函数"; exit 2; }
done
[[ -e /etc/.pdg-rollback-iso ]] \
  || { echo "[未执行] 隔离自检失败: /etc 不是本轮隔离根 ⇒ 未运行被测函数"; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# ── 造两份快照(旧 A=OLD / 新 B=NEW), 各含 backend + 判别标记 ──────────────────
SNAP="$WORK/snaps"; mkdir -p "$SNAP"
mksnap(){ # $1=目录名 $2=标记
  local d="$SNAP/$1"; mkdir -p "$d/tree/etc/privdns-gateway"
  printf 'singbox\n' > "$d/tree/etc/privdns-gateway/backend"
  printf '%s\n' "$2" > "$d/tree/etc/privdns-gateway/snapid"
  tar czf "$d/snap.tar.gz" -C "$d/tree" etc 2>/dev/null; rm -rf "$d/tree"
}
mksnap A OLD; sleep 1; mksnap B NEW    # B 更新(mtime 更晚 → ls -t 里 index 0)

# ── 沙箱 REPO_DIR: 两提交的 git 仓库 ─────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"
# 这里的 `&&` 链本身是安全的(cd 失败会短路), 但守卫盯的是另一件事: $WORK 将来被改成别的
# 地方时, "在一次性库里动 ref"这个前提必须仍然成立, 而不是靠读代码去确认。
# shellcheck source=tests/repoguard.sh
source "$(dirname "${BASH_SOURCE[0]}")/repoguard.sh"
( cd "$REPO" && git init -q && E2E_ROOT="$ROOT" e2e_guard_repo . \
  && e2e_git . config user.email t@t && e2e_git . config user.name t \
  && echo v1 > f && e2e_git . add f && e2e_git . commit -qm c1 && echo v2 > f && e2e_git . add f && e2e_git . commit -qm c2 )
GOOD_REF=$(git -C "$REPO" rev-parse HEAD~1)   # 第一提交
HEAD_REF=$(git -C "$REPO" rev-parse HEAD)

# ── 抽取 cmd_rollback + 打桩 ──────────────────────────────────────────────────
sed -n '/^cmd_rollback(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" > "$WORK/rollback.sh"
# _snap_meta_commit 也要**抽真的**, 不能靠打桩、更不能不管。
#
# 它是 cmd_rollback 在"调用方没点名 --git"时用来取回滚目标提交的那一步。原来两样都没做:
# 没抽也没打桩, 于是壳里跑到那行是 **127(command not found)**, 输出被 2>/dev/null 吞掉,
# 命令替换得到空串 —— 恰好和"这份快照没记提交"是同一个结果, 于是判据一路绿着走过去,
# 而**真函数从来没被执行过**。这条 127 在基线上就存在, 是 v1.10.16 那轮加收敛调用时才
# 因为退出码变化被顺带暴露出来的。
#
# 它只依赖 python3(读 snapshot.json 的 git_commit, 且只认合法哈希 —— 字面量 "unknown"
# 会被正则挡掉), 抽进来零成本, 比任何桩都忠实。
sed -n '/^_snap_meta_commit(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" >> "$WORK/rollback.sh"
# 本轮补齐: 恢复决策与未恢复项累计**必须用真身**, 不能拿恒真替身顶替 ——
# 那正是本壳在核验的东西。这批各自的依赖也一并抽进来(按实际调用路径清点, 见交付说明),
# 只有真正属于"外部世界"的才做模型(systemctl / nft / 内核二进制 / 面板收敛 / iOS 校验)。
for _f in _snap_meta_label _pdg_svcstate_units _pdg_svc_known _pdg_svc_q _pdg_now_en _pdg_now_ac \
          _pdg_svcstate_valid _pdg_svcstate_plan _pdg_save_svcstate _pdg_set_enable_state \
          _pdg_restore_svcstate _pdg_kernel_converge _nft_apply_main _lan_nft_reapply; do
  sed -n "/^${_f}(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh" >> "$WORK/rollback.sh"
  grep -q "^${_f}(){" "$WORK/rollback.sh" \
    || { echo "[FAIL] 抽不到 $_f —— 改名了? 后面的判据全部无效"; exit 1; }
done
# 语法必须在**实际加载顺序**下成立: 抽取拼接出来的这一份先 bash -n, 不过就停 ——
# 语法错误/未定义符号都算执行无效, 不能让它冒充某个故障用例的"预期失败"。
bash -n "$WORK/rollback.sh" || { echo "[FAIL] 抽取拼出来的壳语法不过 —— 执行无效, 停止"; exit 1; }
grep -q '^_snap_meta_commit(){' "$WORK/rollback.sh" \
  || { echo "[FAIL] 抽不到 _snap_meta_commit —— 改名了? 后面的判据全部无效"; exit 1; }
# 快照里不含 etc/sing-box/config.json 与 etc/nftables.conf → 内核/nft 校验分支被跳过,
# 无需真 sing-box/mihomo/nft 二进制(也就不必打桩带连字符的函数名)。
# harness 的生成分两段, 把"要展开的"和"要原样保留的"**显式分开** ——
# 以前整段用未引用的 <<EOF: 正文里需要展开的只有 WORK/SNAP/REPO 三个路径, 代价却是**整段**
# 都进了 shell 的展开: 注释里的 `cp -a` 被当成命令替换, 在**生成阶段**真的执行了一次
# (生成段 rc 仍是 0, 只在 stderr 留下两行 "cp: missing file operand"), 而那段注释被替换成空。
# 现在: 三个路径用 printf %q 显式写在前面(引号安全), 其余正文一律走带引号的 heredoc。
# --- harness-gen: BEGIN(G 节按这两行标记抽出本段单独运行) ---
{ printf 'WORK=%q\n'  "$WORK"
  printf 'SNAP=%q\n'  "$SNAP"
  printf 'REPO=%q\n'  "$REPO"
} > "$WORK/harness.sh"
cat >> "$WORK/harness.sh" <<'HARNESSEOF'
SNAP_DIR="$SNAP"
# _lan_nft_reapply 读这个全局(产品有意不写死路径)。指到本壳自有文件: 不存在即早退,
# 于是不会去碰隔离根外的任何 nft 配置。
LAN_NFT_CONF="$WORK/lan-nft.conf"
REPO_DIR="$REPO"
need_root(){ :; }; _lock(){ :; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
_pdg_core(){ echo singbox; }
_pdg_core_svc(){ echo sing-box; }
_pdg_mktemp_dir(){ mktemp -d; }
_sb_panel_managed_on(){ return 1; }
_core_kernel_activate(){ return 0; }
# cmd_rollback 会用到的 units.sh / 归属助手: 沙箱里没有真 /etc, 一并打桩(与 systemctl/nft 同理)
pdg_write_unit(){ return 0; }
pdg_unit_mihomo(){ echo "[Unit]"; }
_pdg_drop_singbox_files(){ :; }
_pdg_singbox_is_ours(){ return 1; }
nft(){ return 0; }
# 快照落盘: 隔离已成立, 这里**真的把树落到隔离根的 /**。
APPLIED="$WORK/applied_snapid"
_pdg_apply_snapshot_tree(){
  # 逐文件落盘: 目录用 mkdir -p 现建(不碰已存在目录的元数据), 文件用 `cp -PpT`。
  #
  # 为什么不是一句 tar: 隔离根只绑了 /usr/local/bin、没绑 /usr, 而快照里有 usr/local/bin/...。
  # tar 会去给归档里的目录成员(含 `.` 也就是 / 本身)设模式, 在命名空间里被拒:
  #   tar: .: Cannot change mode to rwx------: Operation not permitted   → rc=2
  # 加 --no-overwrite-dir 也没挡住(本机实测)。逐文件复制就没有这一类"改目录元数据"的动作。
  #
  # `-T` 不能省: 少了它, 当目标同路径**已经是一个目录**时, `cp` 会把文件拷进那个目录里
  # (变成 .../snapid/snapid)并返回 0 —— 落盘其实没发生, 却报成功。-T 让这种情形直接失败。
  #
  # 任何一步失败都**立刻返回非零**, 并且**不生成任何代表"恢复成功"的标记** ——
  # 失败要传回真正的调用方 cmd_rollback, 不是在辅助函数里记一笔就算了。
  local tree="$1" dest="${3:-/}" rel
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    mkdir -p "$dest/${rel%/*}" 2>/dev/null || return 1
    cp -PpT "$tree/$rel" "$dest/$rel" 2>/dev/null || return 1
  done < <(cd "$tree" && find . -mindepth 1 \( -type f -o -type l \) -print0)
  # 判别标记从**目标**读回, 不是从源树抄 —— 源树里那份一直都在, 抄它证明不了落盘发生过。
  # 它只用来辅助辨认"落的是哪一份快照"; 文件是否真的恢复由断言直接查隔离目标里的实际文件。
  cat "$dest/etc/privdns-gateway/snapid" > "$APPLIED" 2>/dev/null || return 1
  return 0; }
# 覆盖生产文件之前的 iOS 联合校验(见 pdg.sh _pdg_ios_verify_tree)。这些快照里根本没有
# iOS 生命周期成员, 生产里它会直接 return 0 —— 这里打桩只是因为本壳没抽那一批函数。
_pdg_ios_verify_tree(){ return 0; }
# 内网面板的回滚收敛(见 pdg.sh _lan_rollback_converge)。同样是"本壳没抽那一批函数"才打的桩 ——
# 收敛本身由 tests/test-lan-rollback-convergence.sh 跑真函数覆盖, 这里只要它不影响本壳的判据。
_lan_rollback_converge(){ return 0; }
HARNESSEOF
# --- harness-gen: END ---


# ── 外部服务动作的模型, 单独一份文件(**带引号 heredoc**, 内容原样保留) ──────
# model.sh 用的是**带引号**的 heredoc, 里面的 $WORK 要到 source 时才展开 —— 必须导出。
export WORK
cat > "$WORK/model.sh" <<'MODELEOF'
# ── 外部服务动作: **唯一**的模型点(systemctl 状态机) ────────────────────────
# 不连真 systemd。语义照 pdg.sh 里 _pdg_set_enable_state 上方那段"在真 systemd 上实测过"
# 的记录来: enable→enabled; 已 enabled 再 enable --runtime 仍 enabled; disable→enabled-runtime;
# enabled-runtime 上只 disable 仍 enabled-runtime; disable --runtime→disabled。
# 状态落在自有文件里, 断言据此核对"服务模型后置状态", **不冒充真实 systemd 验收**。
SVCD="$WORK/svc"; mkdir -p "$SVCD"
svc_set(){ printf '%s\n' "$2" > "$SVCD/$1.en"; printf '%s\n' "$3" > "$SVCD/$1.ac"
           printf '%s\n' "${4:-running}" > "$SVCD/$1.sub"; printf 'INV-%s-0\n' "$1" > "$SVCD/$1.inv"; }
svc_en(){ cat "$SVCD/$1.en" 2>/dev/null || echo not-found; }
svc_ac(){ cat "$SVCD/$1.ac" 2>/dev/null || echo not-found; }
systemctl(){
  local sub="${1:-}"; shift || true
  local rt=0; [[ "${1:-}" == "--runtime" ]] && { rt=1; shift; }
  [[ "${1:-}" == "--now" ]] && shift
  local u="${1:-}"
  case "$sub" in
    daemon-reload|reset-failed) return 0;;
    is-enabled) svc_en "$u";;
    is-active)  svc_ac "$u";;
    show)
      local prop="" val=""
      for a in "$@"; do [[ "$a" == -p ]] && continue; [[ "$a" == --value ]] && continue
                        [[ "$a" == LoadState || "$a" == SubState || "$a" == InvocationID ]] && prop="$a"; done
      u="${@: -1}"
      case "$prop" in
        LoadState)    [[ -e "$SVCD/$u.en" ]] && val=loaded || val=not-found;;
        SubState)     val="$(cat "$SVCD/$u.sub" 2>/dev/null)";;
        InvocationID) val="$(cat "$SVCD/$u.inv" 2>/dev/null)";;
      esac
      printf '%s\n' "$val";;
    enable)
      local cur; cur="$(svc_en "$u")"
      if (( rt )); then [[ "$cur" == enabled ]] || printf 'enabled-runtime\n' > "$SVCD/$u.en"
      else printf 'enabled\n' > "$SVCD/$u.en"; fi;;
    disable)
      local cur; cur="$(svc_en "$u")"
      if (( rt )); then printf 'disabled\n' > "$SVCD/$u.en"
      else [[ "$cur" == enabled ]] && printf 'enabled-runtime\n' > "$SVCD/$u.en"
           [[ "$cur" == disabled ]] && printf 'disabled\n' > "$SVCD/$u.en"; fi
      [[ "$DISABLE_NOW_STOPS" == 1 ]] && printf 'inactive\n' > "$SVCD/$u.ac";;
    start|restart)
      printf 'active\n' > "$SVCD/$u.ac"; printf 'running\n' > "$SVCD/$u.sub"
      printf 'INV-%s-%s\n' "$u" "$RANDOM$RANDOM" > "$SVCD/$u.inv";;
    stop) printf 'inactive\n' > "$SVCD/$u.ac"; printf 'dead\n' > "$SVCD/$u.sub";;
    *) return 0;;
  esac
  return 0
}
DISABLE_NOW_STOPS=1
# 八个 unit 的初始模型状态(与 _pdg_svcstate_units 的清单一致)
svc_init(){
  local u
  for u in pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer; do
    svc_set "$u" "${1:-enabled}" "${2:-active}"
  done
}
nft(){ return 0; }
# _pdg_svcstate_plan / _pdg_restore_svcstate 用到的全局: 关联数组必须先声明, 否则赋值会变成
# 普通变量; _PDG_SVC_SRC 初值为空(plan 靠它判"同一份快照不重复解析")。
declare -A _PDG_WANT_EN=() _PDG_WANT_AC=() _PDG_WANT_URC=() _PDG_WANT_ARC=()
_PDG_SVC_SRC=""; _PDG_SVC_MODE=blind; _PDG_SVC_WHY=""; _PDG_SVCSTATE_WHY=""
MODELEOF

run(){ bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; source '$WORK/rollback.sh'; cmd_rollback $1" 2>&1; }

# ── A. --dir 精确回滚(指到旧的 A, 而非 index0 的 B) ─────────────────────────
rm -f "$WORK/applied_snapid"; out=$(run "--dir '$SNAP/A'")
[[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == OLD ]] \
  && ok "--dir 指定旧快照 A → 精确回滚到 A(未被 index0 的 B 顶掉)" || bad "A: applied=$(cat "$WORK/applied_snapid" 2>/dev/null) out=$out"

# 不带 --dir → index 0(最近 = B)
rm -f "$WORK/applied_snapid"; out=$(run "0")
[[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == NEW ]] \
  && ok "无 --dir → 默认 index0 仍回滚到最近 B" || bad "A2: applied=$(cat "$WORK/applied_snapid" 2>/dev/null) out=$out"

# ── B 类. **缺**服务前像的历史快照: 文件与 Git 照旧恢复, 但运行态/自启未确认 ─────────
# 快照 A 是老格式(没有 svcstate.tsv)。这是真实存在的兼容性边界, 不能改成"成功":
# 文件和 Git 该恢复的仍要恢复, 但"运行态/自启无法确认"必须计入未恢复项、返回非零、
# 且不得声称完整恢复。
# 四件事**分别判** —— 原来它们挤在一个 && 链里, 于是"HEAD 其实已经复位"会被"没有完整成功
# 文案"一起判成失败, 读起来像 HEAD 没复位(134 号原始日志里 '仓库已复位到…' 就在那儿)。
e2e_git "$REPO" reset --hard -q "$HEAD_REF"
rc=0; out=$(run "--dir '$SNAP/A' --git '$GOOD_REF'") || rc=$?
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$GOOD_REF" ]] \
  && ok "B-git: --git 指定的提交**确实复位了**(HEAD=${GOOD_REF:0:12})" \
  || bad "B-git: HEAD=$(git -C "$REPO" rev-parse HEAD) 期望 ${GOOD_REF:0:12}"
# 文件判据直接查**隔离目标里的实际文件**: 存在性 + 内容 + 属性。
# applied_snapid 只作辅助辨认(它本身也是从目标读回的), 不能替代落盘证据。
{ [[ -f /etc/privdns-gateway/snapid ]] && [[ "$(cat /etc/privdns-gateway/snapid)" == OLD ]] \
  && [[ "$(cat /etc/privdns-gateway/backend 2>/dev/null)" == mihomo ]]; } \
  && ok "B-file: 隔离目标里确有恢复出来的普通文件(snapid=OLD, 权限 $(stat -c %a /etc/privdns-gateway/snapid))" \
  || bad "B-file: 目标文件不对(存在=$( [[ -f /etc/privdns-gateway/snapid ]] && echo 是 || echo 否) 内容=$(cat /etc/privdns-gateway/snapid 2>/dev/null))"
[[ "$rc" != 0 ]] && ok "B-rc: 缺前像 ⇒ 返回非零($rc), 不当成完整成功" || bad "B-rc: 缺前像却返回 0"
grep -q '运行态/自启未确认' <<<"$out" \
  && ok "B-unrestored: 未恢复项里明确列出'运行态/自启未确认'" || bad "B-unrestored: 未列出, out=$out"
grep -q '✅ 已回滚并重启服务' <<<"$out" \
  && bad "B-文案: 缺前像却打了完整恢复文案" || ok "B-文案: 没有声称完整恢复(打的是'未完全回滚')"

# ── B2. 不带 --git 时, 目标从**快照自己记的** git_commit 派生 ────────────────
# 这一格是补上来的: 本壳原来每个用例都显式传 --git, 于是 _snap_meta_commit 那条路径
# 一次都没走过 —— 而它当时根本没被抽进壳里, 跑到那行是静默 127, 命令替换得到空串,
# 恰好与"这份快照没记提交"同一个结果, 所以一路绿着走过去。127 消失了不等于这条路被验了。
e2e_git "$REPO" reset --hard -q "$HEAD_REF"
printf '{"id":"A","source":"cli","op":"update","git_commit":"%s"}\n' "$GOOD_REF" > "$SNAP/A/snapshot.json"
out=$(run "--dir '$SNAP/A'")
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$GOOD_REF" ]] \
  && ok "无 --git: 目标取自快照记的 git_commit(仓库已复位)" \
  || bad "B2: HEAD=$(git -C "$REPO" rev-parse HEAD) 期望=$GOOD_REF out=$out"
echo "$out" | grep -q '将一并把仓库复位到快照记录的提交' \
  && ok "  并明说目标是从快照元数据派生的" || bad "B2b: out=$out"

# ── B3. git_commit 是字面量 "unknown" 时不许当成提交 ─────────────────────────
# _snap_meta_write 读不到仓库时写的就是 "unknown"。把它交给 `git reset --hard` 会拿一个
# 不存在的 ref 去复位 —— 正则必须把它挡在外面, 表现应与"没记提交"一致。
e2e_git "$REPO" reset --hard -q "$HEAD_REF"
printf '{"id":"A","source":"cli","op":"update","git_commit":"unknown"}\n' > "$SNAP/A/snapshot.json"
out=$(run "--dir '$SNAP/A'")
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$HEAD_REF" ]] \
  && ok "git_commit=unknown → 不当成提交, 仓库不动" || bad "B3: HEAD 被改成 $(git -C "$REPO" rev-parse HEAD)"
echo "$out" | grep -q '没记下仓库提交' \
  && ok "  并如实说'只还原了一半'而不是静默跳过" || bad "B3b: out=$out"
rm -f "$SNAP/A/snapshot.json"

# ── C. git ref 不存在 → 不谎报完全回滚, 返回 1 ───────────────────────────────
rc=0; out=$(run "--dir '$SNAP/A' --git 'deadbeefdeadbeef'") || rc=$?
{ echo "$out" | grep -q '未完全回滚' && [[ "$rc" == 1 ]]; } \
  && ok "git ref 失效 → 打印'未完全回滚'并返回 1(不谎报成功)" || bad "C: rc=$rc out=$out"
# 但快照本身仍已恢复(apply 成功)
[[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == OLD ]] && ok "  部分失败下配置快照仍已落盘(只是 git 未复位)" || bad "C2"

# ── C3. 跨内核回滚: _core_kernel_activate 失败 → 计入 unrestored, 非0 + "未完全回滚" ──
# 造"回滚前是 mihomo, 快照是 singbox"的跨内核场景: _pdg_core 首调(pre_core)返 mihomo, 之后返 singbox。
cat > "$WORK/xcore.sh" <<EOF
PRE="$WORK/precore"; : > "\$PRE"
_pdg_core(){ if [[ -s "\$PRE" ]]; then echo singbox; else echo mihomo; printf x > "\$PRE"; fi; }
pdg_write_unit(){ return 0; }
_core_kernel_activate(){ return 1; }        # 注入: 快照核激活失败
EOF
runx(){ bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; source '$WORK/xcore.sh'; source '$WORK/rollback.sh'; cmd_rollback $1" 2>&1; }
rc=0; out=$(runx "--dir '$SNAP/A'") || rc=$?
{ [[ "$rc" != 0 ]] && grep -q '未完全回滚' <<<"$out" && ! grep -q '✅ 已回滚并重启服务' <<<"$out"; } \
  && ok "跨内核回滚: 内核激活失败 → 非0 + '未完全回滚' + 不报'✅ 已回滚'" || bad "C3: rc=$rc out=$out"
# 具名原因按**产品实际用到的标签**核: 产品累计的是"内核收敛(mihomo/sing-box)";
# "内核激活"只出现在一句注释里(pdg.sh 里 grep 得到 1 处, 且是注释)。
# 这里不是放宽 —— 仍然要求点名到内核这一项, 只是对账到产品真正会打出来的那个词。
grep -q '内核收敛' <<<"$out" \
  && ok "  未恢复项明确点名内核那一项('内核收敛')" || bad "C3b: 未列出失败项 out=$out"

# ── A 类. 有效服务前像的健康快照: 文件 / Git / 服务模型后置状态**分别**成立 ──────────
# 前像用**产品既有的 _pdg_save_svcstate 真身**生成(不伪造有效标签): 先把模型里的服务状态
# 摆成"回滚目标应有的样子", 让产品自己拍下前像; 再把现状打乱; 回滚后逐项核对是否收敛回去。
mksnap H HEALTHY
mkpre(){   # $1=快照目录: 跑产品真身写 svcstate.tsv
  bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; source '$WORK/rollback.sh'; \
           svc_init enabled active; _pdg_save_svcstate '$1'" >/dev/null 2>&1
}
mkpre "$SNAP/H"
[[ -s "$SNAP/H/svcstate.tsv" ]] \
  && ok "A-pre: 前像由产品真身 _pdg_save_svcstate 生成($(grep -c $'^unit\t' "$SNAP/H/svcstate.tsv") 个 unit), 不是伪造的标签" \
  || bad "A-pre: 前像没生成出来"
printf '{"id":"H","source":"cli","op":"update","git_commit":"%s"}\n' "$GOOD_REF" > "$SNAP/H/snapshot.json"
# 打乱现状: 全部停用 + 关自启 —— 回滚要把它们按前像收敛回 enabled+active
bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; svc_init disabled inactive" >/dev/null 2>&1
e2e_git "$REPO" reset --hard -q "$HEAD_REF"
rm -f "$WORK/applied_snapid"; rc=0; out=$(run "--dir '$SNAP/H' --git '$GOOD_REF'") || rc=$?
[[ "$rc" == 0 ]] && ok "A-rc: 有效前像的健康快照 ⇒ rc=0" || bad "A-rc: rc=$rc out=$out"
{ [[ -f /etc/privdns-gateway/snapid ]] && [[ "$(cat /etc/privdns-gateway/snapid)" == HEALTHY ]]; } \
  && ok "A-file: 隔离目标里确有恢复出来的普通文件(snapid=HEALTHY, 权限 $(stat -c %a /etc/privdns-gateway/snapid))" \
  || bad "A-file: 目标文件不对(存在=$( [[ -f /etc/privdns-gateway/snapid ]] && echo 是 || echo 否) 内容=$(cat /etc/privdns-gateway/snapid 2>/dev/null))"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$GOOD_REF" ]] \
  && ok "A-git: 仓库复位到指定提交" || bad "A-git: HEAD=$(git -C "$REPO" rev-parse HEAD)"
_bad_svc=""
for u in mosdns mihomo pdg-bot pdg-probe81; do
  [[ "$(cat "$WORK/svc/$u.en" 2>/dev/null)" == enabled && "$(cat "$WORK/svc/$u.ac" 2>/dev/null)" == active ]] \
    || _bad_svc="$_bad_svc $u($(cat "$WORK/svc/$u.en" 2>/dev/null)/$(cat "$WORK/svc/$u.ac" 2>/dev/null))"
done
[[ -z "$_bad_svc" ]] \
  && ok "A-svc: **服务模型**后置状态按前像收敛回 enabled+active(不是真实 systemd 验收)" \
  || bad "A-svc: 未收敛:$_bad_svc"
grep -q '✅ 已回滚并重启服务' <<<"$out" \
  && ok "A-文案: 允许完整恢复文案(未恢复项为空时才打)" || bad "A-文案: out=$out"

# ── A 反例. 前像判据不是恒真: 把 H 的前像改坏, 必须被具名拒绝并计入未恢复项 ──────────
cp "$SNAP/H/svcstate.tsv" "$WORK/svcstate.good"
printf 'unit\tbogus\tenabled\t0\tactive\t0\trunning\tX\n' >> "$SNAP/H/svcstate.tsv"   # 摘要当场对不上
bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; svc_init disabled inactive" >/dev/null 2>&1
e2e_git "$REPO" reset --hard -q "$HEAD_REF"
rc=0; out=$(run "--dir '$SNAP/H' --git '$GOOD_REF'") || rc=$?
[[ "$rc" != 0 ]] && ok "A-neg-rc: 前像被改坏 ⇒ 非零($rc), 没有当成健康快照" || bad "A-neg-rc: 改坏了还返回 0"
grep -q '前像不可用' <<<"$out" \
  && ok "A-neg-why: 具名拒绝($(grep -o '前像不可用[^;)]*' <<<"$out" | head -1))" || bad "A-neg-why: 没说为什么, out=$out"
grep -q '运行态/自启未确认' <<<"$out" \
  && ok "A-neg-unrestored: 并计入未恢复项, 不是静默降级" || bad "A-neg-unrestored: 未计入"
grep -q '✅ 已回滚并重启服务' <<<"$out" && bad "A-neg-文案: 仍打了完整恢复文案" || ok "A-neg-文案: 未声称完整恢复"
cp "$WORK/svcstate.good" "$SNAP/H/svcstate.tsv"

# ── C4. 校验快照旧配置要用**快照自带的内核**, 不能用当前(新)内核 ──────────────
# 场景: 新内核拒绝旧配置(正是要回滚的原因)。若拿当前新内核去校验快照里的旧配置, 它当然
# 说"不合法", 回滚就被自己挡住了 —— 旧内核和旧配置本该一起回去。
mkmihomo_snap(){  # $1=目录名 $2=快照内核的 check 退出码
  local d="$SNAP/$1"; rm -rf "$d"; mkdir -p "$d/tree/etc/privdns-gateway" "$d/tree/etc/mihomo" "$d/tree/usr/local/bin"
  printf 'mihomo\n' > "$d/tree/etc/privdns-gateway/backend"
  printf 'SNAP-M\n'  > "$d/tree/etc/privdns-gateway/snapid"
  printf 'mixed-port: 7890\n' > "$d/tree/etc/mihomo/config.yaml"
  printf '#!/bin/sh\nexit %s\n' "$2" > "$d/tree/usr/local/bin/mihomo"; chmod 755 "$d/tree/usr/local/bin/mihomo"
  # 按 cmd_snapshot 的方式打**显式成员路径**: 递归打 usr 会带出 usr/ 目录项, 触发越界守卫
  tar czf "$d/snap.tar.gz" -C "$d/tree" etc/privdns-gateway etc/mihomo usr/local/bin/mihomo 2>/dev/null
  rm -rf "$d/tree"
}
# 当前内核一律拒绝旧配置(模拟"新内核不认旧配置")
cat > "$WORK/curkernel.sh" <<'EOF'
mihomo(){ return 1; }
_pdg_core(){ echo mihomo; }
_pdg_core_svc(){ echo mihomo; }
EOF
runm(){ bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; source '$WORK/curkernel.sh'; source '$WORK/rollback.sh'; cmd_rollback $1" 2>&1; }

mkmihomo_snap M_OK 0            # 快照自带的 mihomo 接受旧配置
# 这一格的被测对象是"用哪一个内核去校验旧配置", 不是前像。给它一份**真身生成的**有效前像,
# 否则它会因为"缺服务前像"必然非零 —— 那就测不到内核校验这件事了。
mkpre "$SNAP/M_OK"
bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; svc_init enabled active" >/dev/null 2>&1
rm -f "$WORK/applied_snapid"; rc=0; out=$(runm "--dir '$SNAP/M_OK'") || rc=$?
{ [[ "$rc" == 0 ]] && [[ -f /etc/privdns-gateway/snapid ]] && [[ "$(cat /etc/privdns-gateway/snapid)" == SNAP-M ]] \
  && [[ -x /usr/local/bin/mihomo ]]; } \
  && ok "快照内核接受旧配置 → 回滚成功落盘(目标里 snapid=SNAP-M 且快照自带的 mihomo 可执行)" \
  || bad "C4a: rc=$rc 目标 snapid=$(cat /etc/privdns-gateway/snapid 2>/dev/null) out=$out"

mkmihomo_snap M_BAD 1           # 快照自带的 mihomo 也拒绝 → 这份快照真的不可用
rm -f "$WORK/applied_snapid"; rc=0; out=$(runm "--dir '$SNAP/M_BAD'") || rc=$?
{ [[ "$rc" != 0 ]] && [[ ! -e "$WORK/applied_snapid" ]]; } \
  && ok "快照内核也拒绝旧配置 → 落盘前中止(不写坏现网)" || bad "C4b: rc=$rc applied=$(cat "$WORK/applied_snapid" 2>/dev/null)"

# ── D. 静态断言: cmd_update / cmd_snapshot / 越界守卫 ─────────────────────────
u="$ROOT/deploy/bot/pdg.sh"
grep -q '更新前快照失败, 中止更新' "$u" && ok "cmd_update: 快照失败即中止(不在无法回滚下继续)" || bad "D1: 缺快照失败中止"
grep -q 'cmd_rollback --dir "\$snap_dir" --git "\$pre_sha"' "$u" && ok "cmd_update: 回滚用精确 --dir+--git(非 cmd_rollback 0)" || bad "D2"
grep -q "pre_sha=.*git -C .*rev-parse HEAD" "$u" && ok "cmd_update: 记录升级前 Git SHA" || bad "D3"
for p in 'usr/local/bin/pdg' 'usr/local/bin/pdg-set-token' 'etc/systemd/system/mihomo.service' 'etc/systemd/system/pdg-mitm.service' '99-pdg-cert.sh'; do
  grep -q "$p" "$u" || bad "D4: 快照 cand 缺 $p"
done
grep -q "etc/systemd/system/mihomo.service etc/systemd/system/sing-box.service" "$u" && ok "cmd_snapshot cand: 覆盖已装脚本 + 内核/mitm/probe/health 全部 unit + cert hook" || bad "D4 汇总"
# D5 越界守卫: 拿真实的那条正则去跑样本, 而不是 grep 一段字面量 —— 字面量只能证明"那行字
# 还在", 证明不了它放行/拦住的到底是什么。守卫的前缀集必须与 cmd_snapshot 的候选集对齐:
# 装的脚本(usr/local/bin)、iOS 描述文件产物(var/lib 下那一个子树)要能进快照; 别的一律不行。
_guard="$(sed -n "s/.*grep -Evq '\(\^([^']*)\)'.*/\1/p" "$u" | head -1)"
[[ -n "$_guard" ]] || _guard="$(grep -oE "\^\(etc\|[^']*\)\(/\|\\$\)" "$u" | head -1)"
_chk(){ printf '%s\n' "$1" | grep -Evq "$_guard"; }   # 返回 0 = 会被守卫判越界
for _good in 'etc/mosdns/config.yaml' 'opt/pdg-bot/bot.py' 'usr/local/bin/pdg' \
             'var/lib/privdns-gateway/ios-profile/current.mobileconfig' \
             'var/lib/privdns-gateway/ios-profile/previous.mobileconfig'; do
  _chk "$_good" && bad "D5: 守卫误拦了应进快照的 $_good"
done
ok "回滚越界守卫放行 etc/opt/usr-local-bin 与 iOS 描述文件产物(真跑正则, 非字面量)"
for _bad in 'var/lib/privdns-gateway/tx/abc/before' 'var/lib/privdns-gateway/backups/x.tar.gz' \
            'var/lib/other/thing' 'var/log/syslog' 'root/.ssh/authorized_keys'; do
  _chk "$_bad" || bad "D5: 守卫放行了不该进快照的 $_bad"
done
ok "守卫仍然拦住 tx 记录/备份包/其它 var 路径(没有放宽成整个 var/lib)"

echo
echo "══ F. 落盘失败必须传到调用方; 文件证据必须来自目标 ══"
# 直接反例(真实文件系统, 不是模拟): 目标同路径是一个**带哨兵的非空目录**, 源里是普通文件。
rm -f /etc/privdns-gateway/snapid
mkdir -p /etc/privdns-gateway/snapid && printf 'SENTINEL\n' > /etc/privdns-gateway/snapid/keep
rm -f "$WORK/applied_snapid"
e2e_git "$REPO" reset --hard -q "$HEAD_REF"
rc=0; out=$(run "--dir '$SNAP/H' --git '$GOOD_REF'") || rc=$?
[[ "$rc" != 0 ]] && ok "F1: 落盘失败 ⇒ **调用方** cmd_rollback 返回非零($rc), 不是只在辅助函数里记一笔" \
                 || bad "F1: 落盘失败却返回 0"
grep -q '快照落盘失败' <<<"$out" && ok "F2: 并点名是落盘这一步失败" || bad "F2: 没点名, out=$(tail -2 <<<"$out")"
[[ ! -s "$WORK/applied_snapid" ]] \
  && ok "F3: **没有生成**代表恢复成功的标记(applied 为空)" || bad "F3: 仍写了标记: $(cat "$WORK/applied_snapid")"
[[ -d /etc/privdns-gateway/snapid && "$(cat /etc/privdns-gateway/snapid/keep 2>/dev/null)" == SENTINEL ]] \
  && ok "F4: 目标那一路径仍是原来的非空目录, 哨兵还在(确实没落盘)" || bad "F4: 目标被改了"
[[ ! -f /etc/privdns-gateway/snapid ]] \
  && ok "F5: 目标处**没有**出现那个普通文件 —— 与'函数返回成功'区分开" || bad "F5: 竟然出现了普通文件"
# 撤销对照: 把替身改回"只看生产端 + 从源树抄标记", 同一反例必须重新暴露
cat > "$WORK/apply-broken.sh" <<'BROKENEOF'
_pdg_apply_snapshot_tree(){
  local tree="$1" dest="${3:-/}"
  tar cf - -C "$tree" . 2>/dev/null | tar xf - -C "$dest" --no-overwrite-dir 2>/dev/null
  [[ "${PIPESTATUS[0]}" == 0 ]] || return 1
  cat "$tree/etc/privdns-gateway/snapid" > "$APPLIED" 2>/dev/null; return 0; }
BROKENEOF
runbroken(){ bash -c "source '$WORK/harness.sh'; source '$WORK/model.sh'; source '$WORK/apply-broken.sh'; source '$WORK/rollback.sh'; cmd_rollback $1" 2>&1; }
rm -f "$WORK/applied_snapid"; e2e_git "$REPO" reset --hard -q "$HEAD_REF"
brc=0; bout=$(runbroken "--dir '$SNAP/H' --git '$GOOD_REF'") || brc=$?
{ [[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == HEALTHY ]] && [[ ! -f /etc/privdns-gateway/snapid ]] \
  && ! grep -q '快照落盘失败' <<<"$bout"; } \
  && ok "F6: 撤销修复后**同一反例重新暴露**(标记写成 HEALTHY, 目标文件却不存在, 也没报落盘失败)" \
  || bad "F6: 撤销对照没重现(applied=$(cat "$WORK/applied_snapid" 2>/dev/null) rc=$brc)"
rm -rf /etc/privdns-gateway/snapid

echo
echo "══ G. 生成阶段: 注释不能变成命令 ══"
# 单独把生成段抽出来跑一遍, 生成阶段与被测执行阶段的 stdout/stderr/rc **分别**记。
GENDIR="$WORK/gencheck"; mkdir -p "$GENDIR"
{ printf 'WORK=%q\nSNAP=%q\nREPO=%q\n' "$GENDIR" "$GENDIR/snaps" "$GENDIR/repo"
  # 取**第一个**范围就停(`/END/q`): 本行自己也含这两个标记字样, 不停的话 sed 会在这里
  # 重新开一个范围并一路抄到文件尾。
  sed -n '/# --- harness-gen: BEGIN/,/# --- harness-gen: END/{p; /# --- harness-gen: END/q}' \
      "${BASH_SOURCE[0]}"; } > "$GENDIR/gen.sh"
grc=0; bash "$GENDIR/gen.sh" > "$GENDIR/gen.out" 2> "$GENDIR/gen.err" || grc=$?
echo "    生成阶段: rc=$grc  stdout=$(wc -l < "$GENDIR/gen.out") 行  stderr=$(wc -l < "$GENDIR/gen.err") 行"
[[ "$grc" == 0 ]] && ok "G1: 生成阶段退出码 0" || bad "G1: 生成阶段 rc=$grc"
[[ ! -s "$GENDIR/gen.err" ]] \
  && ok "G2: 生成阶段 stderr **为空** —— 没有任何命令被顺带执行" \
  || { bad "G2: 生成阶段 stderr 非空(注释里的东西被执行了?)"; sed 's/^/        /' "$GENDIR/gen.err"; }
bash -n "$GENDIR/harness.sh" 2>/dev/null && ok "G3: 生成出来的 harness 语法有效" || bad "G3: 生成物语法不过"
{ grep -qx "WORK=$GENDIR" "$GENDIR/harness.sh" && grep -q "^SNAP=" "$GENDIR/harness.sh" && grep -q "^REPO=" "$GENDIR/harness.sh"; } \
  && ok "G4: 需要展开的三个路径**正确传入**(WORK/SNAP/REPO 各一行)" || bad "G4: 路径没正确传入"
grep -qF '`cp -PpT`' "$GENDIR/harness.sh" \
  && ok "G5: 注释里的反引号片段**原样保留**(以前这种片段会在生成阶段被当成命令执行掉)" \
  || bad "G5: 注释片段丢失或被改写"
# 更一般的判据: 生成段里有多少个反引号, 生成物里就该有多少个。命令替换发生过的话, 成对的
# 反引号连同中间的内容会一起消失, 这个计数立刻对不上 —— 不用逐条盯某一句注释。
_gen_bt="$(grep -o '`' "$GENDIR/gen.sh" | wc -l)"
_out_bt="$(grep -o '`' "$GENDIR/harness.sh" | wc -l)"
[[ "$_gen_bt" == "$_out_bt" && "$_gen_bt" -gt 0 ]] \
  && ok "G6: 反引号逐个守恒(生成段 $_gen_bt 个 → 生成物 $_out_bt 个), 没有一对被当成命令替换吃掉" \
  || bad "G6: 反引号数量对不上(生成段 $_gen_bt, 生成物 $_out_bt)"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
