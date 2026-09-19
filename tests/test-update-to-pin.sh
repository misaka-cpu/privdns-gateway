#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# `pdg update --to <版本tag>`: 把一次更新**钉在指定发布**上。
#
# 为什么需要这一支: 默认契约是"选仓库里最高的 v* tag"。线上同时存在更高的退役线 tag 时,
# 那条默认会把机器带到不想要的版本上; 跨版本验收也需要能指定落点。`--to` 只收窄目标,
# 不放宽任何既有的门 —— 这一支钉住的正是"收窄了, 而且一处都没放宽"。
#
#   输入                         应有行为
#   ──────────────────────────  ────────────────────────────────────────────
#   省略 --to                    默认契约不变(最高 v* tag)
#   --to 缺值 / 显式空值          取件**之前**拒绝, 不改装最新发布
#   --to 非 tag 形态              取件之前拒绝(取值会拼进 refs/tags/)
#   --to <存在的较低 tag>         装那一版, 不被更高的退役 tag 带偏
#   --to <不存在的 tag>           停止, 不回退到最新发布
#   取件失败                      停止(目标无法确认 ≠ 目标不存在, 但都得停)
#   目标在过程中被移动            停止并回滚, 不成功短路到新对象
#   ahead / diverged              仍然拒绝(--to 不兼作降级后门)
#   same 且同步                   健康短路; same 不同步 → 仍走修复路径
#   --dry-run --to                预览的目标 == 执行会装的目标
#   --dry-run 锁忙                拒绝且**不取件**(dry-run 会写 FETCH_HEAD, 不是只读)
#
# 造拓扑用**真 git**(不打桩祖先判定, 否则测的是桩的想法); 会动 ref 的 git 一律走 e2e_git。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-updto.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

command -v git >/dev/null 2>&1 || { echo "[SKIP] 没有 git —— 这一支必须用真 git 判祖先关系"; exit 0; }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

PDG="$ROOT/deploy/bot/pdg.sh"
sed -n '/^cmd_update(){/,/^}/p'                 "$PDG" > "$WORK/upd.sh"
sed -n '/^_update_release_relation(){/,/^}/p'   "$PDG" > "$WORK/rel.sh"
sed -n '/^_update_pin_resolve(){/,/^}/p'        "$PDG" >> "$WORK/rel.sh"
sed -n '/^_update_pin_still(){/,/^}/p'          "$PDG" >> "$WORK/rel.sh"
sed -n '/^_pdg_entry_src(){/,/^}/p'             "$PDG" >> "$WORK/rel.sh"
# 完整性预检另有专测(test-update-mosdns-preflight.sh), 这里只当成恒真输入。
printf '_update_mosdns_preflight(){ return 0; }\n' >> "$WORK/rel.sh"

echo "══ 1. 结构: 单一事实源与定义顺序 ══"
# 抽取式测试有个特有的假绿: 把所有函数抽出来再调, 天然满足"定义在前", 于是源文件里
# **调用排在定义之前**这种真故障会被盖成全绿。所以顺序单独按源文件行号判一次。
for f in _update_pin_resolve _update_pin_still; do
  n=$(grep -c "^$f(){" "$PDG")
  [[ "$n" == 1 ]] && ok "$f 只定义一次(实得 $n)" || bad "$f 定义了 $n 次"
done
def_line=$(grep -n '^_update_pin_resolve(){' "$PDG" | cut -d: -f1)
use_line=$(grep -n '^cmd_update(){' "$PDG" | cut -d: -f1)
[[ -n "$def_line" && -n "$use_line" && "$def_line" -lt "$use_line" ]] \
  && ok "钉版判据定义($def_line 行)排在 cmd_update($use_line 行)之前 —— 按源文件行号判, 不靠抽取顺序" \
  || bad "钉版判据定义顺序不对: def=$def_line use=$use_line"
n=$(grep -c -- '--to)' "$PDG")
[[ "$n" == 1 ]] && ok "--to 只有一处解析(预览与执行共用同一套选版契约)" || bad "--to 解析出现 $n 处"
grep -q '_update_release_relation "$REPO_DIR" "$_to_commit"' "$PDG" \
  && ok "钉版走的是既有那一个关系判据, 没有另写一份方向判断" \
  || bad "钉版另写了方向判断 —— 两份判据迟早会漂"

# ── 真 git 拓扑 ─────────────────────────────────────────────────────────────
# A(v1.0.0) → B(v1.11.15, 本轮的"桥接版") → C(v9.0.0, **更高的退役线 tag**)
# 外加从 A 分叉的 side(v1.5.0-side)。默认契约会选 v9.0.0; 钉版必须不被它带偏。
g(){ e2e_git "$1" "${@:2}"; }
mkrepo(){
  local r="$1"; rm -rf "$r"; mkdir -p "$r"
  command git -C "$r" init -q -b main
  g "$r" config user.email t@t; g "$r" config user.name t; g "$r" config commit.gpgsign false
  mkdir -p "$r/lib"
  printf 'pdg_install_runtime_modules(){ return 0; }\n' > "$r/lib/modules.sh"
  echo A > "$r/f"; g "$r" add -A; g "$r" commit -qm A; g "$r" tag -a v1.0.0   -m v1.0.0
  echo B > "$r/f"; g "$r" add -A; g "$r" commit -qm B; g "$r" tag -a v1.11.15 -m v1.11.15
  echo C > "$r/f"; g "$r" add -A; g "$r" commit -qm C; g "$r" tag -a v9.0.0   -m v9.0.0
  g "$r" checkout -q -b side v1.0.0
  echo D > "$r/f"; g "$r" add -A; g "$r" commit -qm D; g "$r" tag -a v1.5.0-side -m side
  g "$r" checkout -q main
}
sha_of(){ command git -C "$WORK/repo" rev-parse -q --verify "$1^{commit}"; }

# 守卫要在**子壳里**也能用: harness 会被 `bash -c "source harness; …"` 加载, 那里没有
# repoguard。路径用 printf 显式写进去(下面的 heredoc 带引号, 不展开)。
printf 'source %q\n' "$ROOT/tests/repoguard.sh" > "$WORK/harness.sh"
cat >> "$WORK/harness.sh" <<'EOF'
REPO_DIR="$WORK/repo"; REPO_URL="file:///dev/null"; ENVF="$WORK/none.env"
need_root(){ :; }
_lock(){ echo "LOCK_TAKEN" >> "$WORK/side.log"; }
c_g(){ echo "$*"; }
c_y(){ echo "$*"; }
sleep(){ :; }
_pdg_platform(){ echo android; }
_pdg_core(){ echo mihomo; }
_pdg_bot_cred(){ echo unset; }
_update_in_sync(){ return "${INSYNC_RC:-0}"; }
# 取件: 本地夹具没有 origin, 真跑 `git fetch` 测的是网络不是选版。做成可控替身, 并**留痕** ——
# "非法参数必须在取件之前被拒"这条判据要的就是"这一步到底有没有被调到"。
pdg_fetch_release_tags(){ echo "FETCH_CALLED" >> "$WORK/side.log"; [[ -n "${FAIL_FETCH:-}" ]] && return 1; return 0; }
# git 不打桩(祖先关系必须真 git 判), 只记录调用。HIJACK_RESET 是**单处注入**:
# 让 reset 落到别的提交上, 用来验"目标贯穿到实际安装"那一道核对真的会判红。
git(){
  printf '%s\n' "$*" >> "$WORK/git.log"
  if [[ -n "${HIJACK_RESET:-}" && "$1" == -C && "$3" == reset ]]; then
    # 这一次写操作走**既有归属守卫**(先守后写)。e2e_git 内部还会调回本 wrapper, 所以先把
    # 注入变量清空再委托 —— 否则就是无限递归; 调用完原样放回, 注入对后续调用仍然有效。
    local _hj="$HIJACK_RESET"; HIJACK_RESET=""
    e2e_git "$2" reset --hard -q "$_hj"; local _rc=$?
    HIJACK_RESET="$_hj"; return "$_rc"
  fi
  command git "$@"
}
install(){ printf 'install %s\n' "$*" >> "$WORK/side.log"; return 0; }
bash(){ [[ "$*" == *__migrate* ]] && { echo "migrate" >> "$WORK/side.log"; return 0; }; command bash "$@"; }
_update_core_binary(){ echo "core" >> "$WORK/side.log"; return 0; }
_update_mosdns_binary(){ echo "mosbin" >> "$WORK/side.log"; return 0; }
systemctl(){ printf 'systemctl %s\n' "$*" >> "$WORK/side.log"; return 0; }
python3(){ case "$*" in *py_compile*) return 0;; *doctor.py*) echo '[{"level":"ok","check":"服务","detail":"都在"}]'; return 0;; *) command python3 "$@";; esac; }
mihomo(){ return 0; }
nft(){ return 0; }
# 本轮契约变化: 服务前像由 **cmd_snapshot** 保存并校验, cmd_update 只**确认**它可用。
# 桩也照此产出前像; SVCSTATE_RC 非 0 时桩自己失败(= 前像存不下 ⇒ 快照失败),
# PLAN_RC 非 0 时确认那一步不过(= 前像校验失败)。
_pdg_svcstate_plan(){ _PDG_SVC_WHY="注入: 前像不可用"; [[ -f "$1/svcstate.tsv" ]] && return "${PLAN_RC:-0}"; return 1; }
cmd_snapshot(){ echo "SNAPSHOT_CALLED" >> "$WORK/side.log"
  _PDG_SNAP_CREATED="$WORK/snap"; mkdir -p "$_PDG_SNAP_CREATED"; : | gzip > "$_PDG_SNAP_CREATED/snap.tar.gz"
  _pdg_save_svcstate "$_PDG_SNAP_CREATED" || { _PDG_SNAP_CREATED=""; return 1; }
  # MOVE_TAG_AT_SNAP: 在快照这一刻把钉的 tag 挪到别的提交上 —— 复现"目标在过程中被移动"。
  [[ -n "${MOVE_TAG_AT_SNAP:-}" ]] && e2e_git "$REPO_DIR" tag -f -a "$MOVE_TAG_AT_SNAP" -m moved HEAD >/dev/null 2>&1
  return 0; }
_pdg_save_svcstate(){ echo "SVCSTATE_SAVED" >> "$WORK/side.log"
  [[ -n "${1:-}" && -d "${1:-}" ]] && printf 'modeled-svcstate\n' > "$1/svcstate.tsv"
  return "${SVCSTATE_RC:-0}"; }
cmd_rollback(){ echo "ROLLBACK_CALLED $*" >> "$WORK/side.log"; return 0; }
EOF
export WORK

# run <HEAD-ref> <env串> <cmd_update 的参数...> → "<rc>|<输出>"
run(){
  local head="$1" envs="$2"; shift 2
  mkrepo "$WORK/repo" >/dev/null 2>&1
  g "$WORK/repo" checkout -q "$head"
  : > "$WORK/side.log"; : > "$WORK/git.log"
  local rc=0 out
  # shellcheck disable=SC2086
  out=$(env $envs bash -c "source '$WORK/harness.sh'; source '$WORK/rel.sh'; source '$WORK/upd.sh'; cmd_update $*" 2>&1) || rc=$?
  printf '%s\n' "$rc|$out"
}
side(){ grep -qF "$1" "$WORK/side.log" 2>/dev/null; }
fetched(){ grep -qF 'FETCH_CALLED' "$WORK/side.log" 2>/dev/null; }
did_reset(){ grep -qE '(^| )reset ' "$WORK/git.log" 2>/dev/null; }
head_now(){ command git -C "$WORK/repo" rev-parse HEAD; }

echo
echo "══ 2. 参数三态: 省略 / 缺值 / 显式空值, 以及非 tag 形态 ══"
r=$(run v1.0.0 "" "--to"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 && "$out" == *"缺少取值"* ]] && ok "--to 缺值 → 拒绝(rc=$rc)" || bad "--to 缺值没被拒: rc=$rc"
fetched && bad "  缺值时仍然取件了" || ok "  且在**取件之前**就拒了(取件一次都没被调到)"
for empty in '--to ""' '--to='; do
  r=$(run v1.0.0 "" "$empty"); rc="${r%%|*}"; out="${r#*|}"
  [[ "$rc" != 0 && "$out" == *"空目标"* ]] \
    && ok "$empty → 拒绝, 并点名'显式空值 ≠ 省略'(rc=$rc)" || bad "$empty 没被拒: rc=$rc"
  fetched && bad "  $empty 时仍然取件了" || ok "  $empty 未触发取件"
done
for badarg in '--to main' '--to HEAD' '--to ../etc' '--to v1.0.0..v2.0.0' '--to -v1.0.0'; do
  r=$(run v1.0.0 "" "$badarg"); rc="${r%%|*}"
  if [[ "$rc" != 0 ]] && ! fetched; then ok "$badarg → 取件前拒绝(rc=$rc)"
  elif [[ "$rc" != 0 ]]; then bad "$badarg 虽拒绝但已经取件了"
  else bad "$badarg 被接受了"; fi
done
# 省略 --to: 既有默认契约一个字节都不变(选最高的 v9.0.0)
r=$(run v1.0.0 "" ""); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" == 0 && "$(head_now)" == "$(sha_of v9.0.0)" ]] \
  && ok "省略 --to → 仍是默认最高发布 v9.0.0(既有契约未变)" || bad "省略 --to 时装到了 $(head_now)"

echo
echo "══ 3. 钉版不被更高的退役 tag 带偏 ══"
r=$(run v1.0.0 "" "--to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
if [[ "$rc" == 0 && "$(head_now)" == "$(sha_of v1.11.15)" ]]; then
  ok "--to v1.11.15 落在 v1.11.15(仓库里存在更高的 v9.0.0, 没被带偏)"
else
  bad "钉版被带偏: rc=$rc HEAD=$(head_now) 期望=$(sha_of v1.11.15)"
fi
[[ "$out" == *"钉版目标已固定(一次, 在方向门之前)"* ]] && ok "  目标在方向门之前固定一次" || bad "  没有'方向门之前固定'的留痕"
[[ "$out" == *"钉版目标已贯穿到实际安装"* || "$out" == *"已切到发布 v1.11.15"* ]] \
  && ok "  目标贯穿到实际安装(按仓库真实 HEAD 核对)" || bad "  缺少实际安装身份核对留痕"
r=$(run v1.0.0 "" "--to v9.9.9"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 && "$out" == *"不存在"* ]] && ok "--to 指向不存在的 tag → 停止" || bad "不存在的 tag: rc=$rc"
[[ "$(head_now)" == "$(sha_of v1.0.0)" ]] && ok "  且没有改装最新发布(HEAD 仍在 v1.0.0)" || bad "  竟改装了 $(head_now)"
side SNAPSHOT_CALLED && bad "  目标不存在却建了快照" || ok "  未建快照、未 reset"

echo
echo "══ 4. 四态方向语义(参照系是钉版目标, 不是最高 tag) ══"
r=$(run v1.0.0 "" "--to v1.11.15"); [[ "${r%%|*}" == 0 ]] && ok "behind → 正常升级" || bad "behind 被拒: ${r%%|*}"
r=$(run v9.0.0 "" "--to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 && "$out" == *"尚未发布"* ]] && ok "ahead → 拒绝(--to 不兼作降级后门)" || bad "ahead 没被拒: rc=$rc"
did_reset && bad "  ahead 时发生了 reset" || ok "  ahead 零副作用(未 reset)"
r=$(run side "" "--to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 && "$out" == *"分叉"* ]] && ok "diverged → 拒绝, 不猜方向" || bad "diverged 没被拒: rc=$rc"
r=$(run v1.11.15 "INSYNC_RC=0" "--to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" == 0 && "$out" == *"无需更新"* ]] && ok "same 且已装文件一致 → 健康短路" || bad "same+同步没短路: rc=$rc"
side SNAPSHOT_CALLED && bad "  短路时却建了快照" || ok "  短路时未建快照、未重启"
r=$(run v1.11.15 "INSYNC_RC=1" "--to v1.11.15"); rc="${r%%|*}"
[[ "$rc" == 0 ]] && side SNAPSHOT_CALLED && ok "same 但不同步 → 仍走修复路径(建快照并重装)" || bad "same 不同步的修复路径丢了: rc=$rc"

echo
echo "══ 5. 取件失败 / 目标被移动 / 目标没贯穿到安装 ══"
r=$(run v1.0.0 "FAIL_FETCH=1" "--to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 && "$out" == *"取件失败"* ]] && ok "取件失败 → 停止, 且说的是'无法确认目标'不是'目标不存在'" || bad "取件失败: rc=$rc"
side SNAPSHOT_CALLED && bad "  取件失败却建了快照" || ok "  未建快照、未 reset"
r=$(run v1.0.0 "MOVE_TAG_AT_SNAP=v1.11.15" "--to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 && "$out" == *"被移动了"* ]] && ok "目标在过程中被移动 → 拒绝继续(不短路到新对象)" || bad "目标移动没被发现: rc=$rc"
side "ROLLBACK_CALLED" && ok "  且回滚到更新前快照" || bad "  目标移动后没有回滚"
r=$(run v1.0.0 "HIJACK_RESET=v9.0.0" "--to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 && "$out" == *"没有贯穿到实际安装"* ]] \
  && ok "reset 落到别处 → 身份核对判红(读真实 HEAD, 不是自证)" || bad "身份核对没判红: rc=$rc"
side "ROLLBACK_CALLED" && ok "  并回滚" || bad "  身份核对判红后没回滚"

echo
echo "══ 6. 预览: 目标与执行一致, 且 dry-run 会取件所以要持锁 ══"
r=$(run v1.0.0 "" "--dry-run --to v1.11.15"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" == 0 && "$out" == *"预览目标(钉版): v1.11.15"* ]] && ok "--dry-run --to 预览的是钉的那一版" || bad "预览目标不对: $out"
[[ "$(head_now)" == "$(sha_of v1.0.0)" ]] && ok "  预览不改工作树(HEAD 未动)" || bad "  预览动了 HEAD"
r=$(run v1.0.0 "" "--to v1.11.15 --dry-run"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" == 0 && "$out" == *"预览目标(钉版): v1.11.15"* ]] && ok "  --to 与 --dry-run 谁先谁后都成立" || bad "  参数顺序敏感: $out"
r=$(run v1.0.0 "" "--dry-run"); out="${r#*|}"
[[ "$out" == *"v9.0.0"* ]] && ok "  不钉版时预览仍是默认最高发布(契约未变)" || bad "  默认预览变了: $out"
r=$(run v1.0.0 "" "--dry-run --to v1.11.15")
side LOCK_TAKEN && ok "dry-run 路径上确实取了锁(它会写 FETCH_HEAD, 不是只读)" || bad "dry-run 没取锁"
# 锁必须在**第一次取件之前**: 按源文件里的行号判, 不靠运行时顺序
dl=$(awk '/--dry-run/{f=1} f&&/^    _lock$/{print NR; exit}' "$PDG")
fl=$(awk -v d="$dl" 'NR>d && /pdg_fetch_release_tags "\$REPO_DIR"/{print NR; exit}' "$PDG")
[[ -n "$dl" && -n "$fl" && "$dl" -lt "$fl" ]] \
  && ok "  取锁($dl 行)排在 dry-run 第一次取件($fl 行)之前" || bad "  取锁位置不对: lock=$dl fetch=$fl"

echo
echo "══ 7. dry-run 锁竞争: 用真 flock, 锁忙时拒绝且不取件 ══"
sed -n '/^_lock_inherited(){/,/^}/p' "$PDG" >  "$WORK/lock.sh"
sed -n '/^_lock(){/,/^}/p'          "$PDG" >> "$WORK/lock.sh"
LOCKF="$WORK/busy.lock"; : > "$LOCKF"
( exec 9>"$LOCKF"; flock -n 9 || exit 9; sleep 20 ) &
holder=$!; sleep 0.5
rc=0
out=$(LOCK="$LOCKF" PDG_LOCKED="" bash -c "LOCK='$LOCKF'; PDG_LOCKED=''; source '$WORK/lock.sh'; _lock; echo REACHED_FETCH" 2>&1) || rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[[ "$rc" != 0 && "$out" != *REACHED_FETCH* ]] \
  && ok "锁被别人持有 → _lock 立即停止(rc=$rc), 取件那一步根本没到" \
  || bad "锁忙时仍继续了: rc=$rc out=$out"
[[ "$out" == *"已有 pdg 操作在运行"* ]] && ok "  且给出可定位的理由(点名锁文件)" || bad "  没说清为什么停: $out"

echo
echo "══ 8. 快照之前, 现役 CLI 未被覆盖 ══"
r=$(run v1.0.0 "" "--to v1.11.15") >/dev/null
snap_ln=$(grep -n 'SNAPSHOT_CALLED' "$WORK/side.log" | head -1 | cut -d: -f1)
cli_ln=$(grep -n 'install .*-m755 .*pdg' "$WORK/side.log" | head -1 | cut -d: -f1)
if [[ -n "$snap_ln" && -n "$cli_ln" ]]; then
  [[ "$snap_ln" -lt "$cli_ln" ]] && ok "实际执行顺序: 快照(第 $snap_ln 条) 早于 覆盖现役 CLI(第 $cli_ln 条)" \
                                 || bad "先覆盖了 CLI 再快照: snap=$snap_ln cli=$cli_ln"
else
  # 覆盖 CLI 走的是 pdg_install_runtime_modules / install 清单, 记不到就按源码顺序判
  s_ln=$(grep -n 'cmd_snapshot --source cli --op update' "$PDG" | head -1 | cut -d: -f1)
  c_ln=$(awk -v s="$s_ln" 'NR>s && /usr\/local\/bin/{print NR; exit}' "$PDG")
  [[ -n "$s_ln" && -n "$c_ln" && "$s_ln" -lt "$c_ln" ]] \
    && ok "源码顺序: 快照($s_ln 行) 早于 写 /usr/local/bin($c_ln 行)" || bad "顺序判不出: snap=$s_ln cli=$c_ln"
fi

echo
echo "══ 9. 失败恢复作用于现役仓库, 不是入口副本 ══"
# 入口副本 = 另一份 pdg.sh 所在目录; 被更新/回滚的必须始终是 $REPO_DIR。
ENTRY="$WORK/entry"; mkdir -p "$ENTRY/deploy/bot"; cp "$PDG" "$ENTRY/deploy/bot/pdg.sh"
before_entry=$(cd "$ENTRY" && find . -type f -exec sha256sum {} \; | sort | sha256sum)
r=$(run v1.0.0 "HIJACK_RESET=v9.0.0" "--to v1.11.15"); rc="${r%%|*}"
after_entry=$(cd "$ENTRY" && find . -type f -exec sha256sum {} \; | sort | sha256sum)
[[ "$before_entry" == "$after_entry" ]] && ok "失败回滚全程没动入口副本(逐文件 SHA 不变)" || bad "入口副本被改动了"
rb=$(grep -F 'ROLLBACK_CALLED' "$WORK/side.log" | head -1)
[[ "$rb" == *"--dir $WORK/snap"* && "$rb" == *"--git "* ]] \
  && ok "回滚点名的是现役仓库的快照与升级前提交: ${rb#ROLLBACK_CALLED }" || bad "回滚参数不对: $rb"
grep -qE "^-C $WORK/repo " "$WORK/git.log" && ok "全程 git 操作的目标是 \$REPO_DIR($WORK/repo)" || bad "git 操作没打在 REPO_DIR 上"
grep -qE "^-C $ENTRY" "$WORK/git.log" && bad "有 git 操作打在了入口副本上" || ok "没有任何 git 操作打在入口副本上"

echo
echo "══ 10. 文档 docs/BRIDGE-ENTRY.md 的调用流程: 执行**文档原文**, 不另抄一份 ══"
DOC="$ROOT/docs/BRIDGE-ENTRY.md"
FLOW="$WORK/flow.sh"
sed -n '/pdg-bridge-entry-flow: BEGIN/,/pdg-bridge-entry-flow: END/p' "$DOC" > "$FLOW"
n_flow=$(grep -c . "$FLOW")
{ (( n_flow > 20 )) && bash -n "$FLOW"; } \
  && ok "10-0: 从文档抽到完整流程($n_flow 行)且语法通过 —— 下面跑的就是文档里那段原文" \
  || bad "10-0: 抽不到文档流程或语法不过($n_flow 行)"

# ── 自有临时"官方源": 真 git, 两个提交/两个 tag。旧提交那棵树的 pdg.sh **没有** --to ──
OFF="$WORK/official.git"; rm -rf "$OFF"; mkdir -p "$OFF"
command git -C "$OFF" init -q -b main
g "$OFF" config user.email t@t; g "$OFF" config user.name t; g "$OFF" config commit.gpgsign false
mkdir -p "$OFF/deploy/bot"
printf '#!/usr/bin/env bash\n# 旧入口: 不认识 --to\necho OLD-ENTRY\n' > "$OFF/deploy/bot/pdg.sh"
g "$OFF" add -A; g "$OFF" commit -qm old; g "$OFF" tag -a v1.0.0-old -m old
OLD_C="$(command git -C "$OFF" rev-parse HEAD)"
printf '#!/usr/bin/env bash\n# 新入口\necho NEW-ENTRY\n' > "$OFF/deploy/bot/pdg.sh"
g "$OFF" add -A; g "$OFF" commit -qm new; g "$OFF" tag -a v1.11.15 -m new
NEW_C="$(command git -C "$OFF" rev-parse HEAD)"

# ── 哨兵: 两类分别标明 ────────────────────────────────────────────────────────
# (a) **提权哨兵** `sudo`: 只记账, 绝不真的执行 —— 本支不碰现役目录, 不真的更新。
# (b) **受控查询哨兵** `git`: 默认原样转发给真 git(祖先/检出/状态全是真的),
#     只有显式注入时才让某一次查询失败, 用来考"查询失败被当成干净了吗"。
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/sudo" <<'SU'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_LOG"
[[ -n "${SUDO_FAIL_DRYRUN:-}" && "$*" == *--dry-run* ]] && exit 7
exit 0
SU
# 哨兵脚本自己也要能调守卫: 同样用 printf 把绝对路径写进去。
{ printf '#!/usr/bin/env bash\n'
  printf '# 受控查询哨兵。默认: 原样转发真 git。\n'
  printf 'source %q\n' "$ROOT/tests/repoguard.sh"; } > "$BIN/git"
cat >> "$BIN/git" <<'GW'
if [[ -n "${FAIL_STATUS:-}" && " $* " == *" status "* ]]; then exit 1; fi   # 失败且 stdout 为空
if [[ -n "${LOCK_AT_CHECKOUT:-}" && " $* " == *" checkout "* ]]; then
  # 先真的检出到**另一个干净提交**(旧入口那一版), 再放一个**自有** index.lock,
  # 于是接下来这次真 checkout 会被真 git 拒绝 —— 锁是真的, 失败也是真的。
  # 先守后写。e2e_git 会再调 `git`, 而 PATH 首位就是本脚本 —— 先把注入开关清掉再委托,
  # 否则无限递归; 清掉之后本脚本对那次内部调用就是纯转发, 注入语义不受影响
  # (本格只需注入命中一次: 检出到另一个提交 + 放下 index.lock)。
  LOCK_AT_CHECKOUT=""
  # 守卫拒绝就**当场停**: 不吞它给的理由, 不继续放 index.lock(那会把"没写成"冒充成
  # "注入已成立"), 也不再执行末尾那次真 git —— 否则被守卫挡下的写操作反而以另一种形式发生了。
  if ! _gw_err="$(e2e_git "$LOCK_REPO" checkout -q --detach "$LOCK_OTHER" 2>&1)"; then
    printf '%s\n' "$_gw_err" >&2
    echo "[哨兵] 归属守卫拒绝了这次检出 ⇒ 不创建 index.lock, 不执行后续 git" >&2
    exit 1
  fi
  # 锁文件没放下去同样要停: 注入的前提就是"锁真的在", 放不下去就不能假装命中。
  if ! : > "$LOCK_REPO/.git/index.lock"; then
    echo "[哨兵] index.lock 创建失败 ⇒ 注入未成立, 停止(不冒充)" >&2
    exit 1
  fi
fi
exec /usr/bin/git "$@"
GW
chmod +x "$BIN/sudo" "$BIN/git"

# runflow <场景名> <额外env...> → 设 FRC / FOUT / FERR / SUDO_N / SUDO_EXEC_N
runflow(){
  local name="$1"; shift
  local ent; ent="$WORK/entry-$(echo "$name" | tr -cd 'a-z0-9')"
  rm -rf "$ent"
  SUDO_LOG="$WORK/sudo-$(echo "$name" | tr -cd 'a-z0-9').log"; : > "$SUDO_LOG"
  FRC=0
  # 整段当成**一个文件**跑(文档要求的形态): 变量与控制流在同一个执行上下文里
  # shellcheck disable=SC2086
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" SUDO_LOG="$SUDO_LOG" \
      LOCK_REPO="$ent" LOCK_OTHER="$OLD_C" \
      TAG="${T_TAG:-v1.11.15}" WANT="${T_WANT:-$NEW_C}" ENTRY="$ent" SRC="$OFF" "$@" \
      bash "$FLOW" > "$WORK/f.out" 2> "$WORK/f.err" || FRC=$?
  FOUT="$(cat "$WORK/f.out")"; FERR="$(cat "$WORK/f.err")"
  # 用 wc 数行: grep -c 找不到时 rc=1, 再接 `|| echo 0` 会**多打一行 0**, 结果变成 "0\n0"
  SUDO_N=$(wc -l < "$SUDO_LOG")
  SUDO_EXEC_N=$(grep -v -- '--dry-run' "$SUDO_LOG" | grep -c -- '--to' || true)
  FENT="$ent"
}

echo "  ── 10a 健康输入 ──"
runflow healthy
{ (( FRC == 0 )) && [[ "$FOUT" == *"身份核对通过"* ]]; } \
  && ok "10a-1: 六步全过 ⇒ 通过(rc=$FRC)" || bad "10a-1: 健康输入没通过(rc=$FRC) err=${FERR:0:120}"
[[ "$(command git -C "$FENT" rev-parse HEAD 2>/dev/null)" == "$NEW_C" ]] \
  && ok "10a-2: 入口副本**实际检出**的就是预期对象 ${NEW_C:0:12}" || bad "10a-2: 检出的不是预期对象"
(( SUDO_N == 2 )) && ok "10a-3: 之后才进入提权哨兵, 共 2 次(预览 1 + 执行 1), 无害记账未真的执行" \
                  || { bad "10a-3: 提权哨兵调用 $SUDO_N 次(应 2)"; sed 's/^/        /' "$SUDO_LOG"; }
L_DRY=$(grep -n -- '--dry-run' "$SUDO_LOG" | head -1 | cut -d: -f1)
L_EXE=$(grep -vn -- '--dry-run' "$SUDO_LOG" | grep -- '--to' | head -1 | cut -d: -f1)
{ [[ -n "$L_DRY" && -n "$L_EXE" ]] && (( L_DRY < L_EXE )); } \
  && ok "10a-4: 顺序确为**先预览(第 $L_DRY 条)后执行(第 $L_EXE 条)**" \
  || bad "10a-4: 顺序判不出(预览=$L_DRY 执行=$L_EXE)"

echo "  ── 10b 预期 SHA 不符 ──"
T_WANT="0000000000000000000000000000000000000000" runflow mismatch
{ (( FRC != 0 )) && [[ "$FOUT$FERR" == *"身份不符"* ]]; } \
  && ok "10b-1: 拒绝(rc=$FRC)并点名身份不符" || bad "10b-1: 没拒绝(rc=$FRC)"
(( SUDO_N == 0 )) && ok "10b-2: **提权哨兵 0 次** —— 没进入提权执行" || bad "10b-2: 提权哨兵被调了 $SUDO_N 次"

echo "  ── 10c 目标 tag 正确, 但 checkout 因自有 index.lock 失败(仓库停在另一个干净提交) ──"
runflow lock LOCK_AT_CHECKOUT=1
{ (( FRC != 0 )) && [[ "$FOUT$FERR" == *"检出失败"* || "$FOUT$FERR" == *"实际 HEAD"* ]]; } \
  && ok "10c-1: 拒绝(rc=$FRC): $(printf '%s' "$FOUT$FERR" | grep -o '❌[^ ]*[^—]*' | head -1)" \
  || bad "10c-1: 没拒绝(rc=$FRC)"
(( SUDO_N == 0 )) && ok "10c-2: **没有运行旧入口** —— 提权哨兵 0 次" || bad "10c-2: 提权哨兵被调了 $SUDO_N 次"
H_LOCK="$(command git -C "$FENT" rev-parse HEAD 2>/dev/null)"
if [[ "$H_LOCK" == "$OLD_C" ]]; then
  ok "10c-3: 此刻副本**确实停在另一个提交** ${OLD_C:0:12}(旧入口那一版)—— 少一道检查就会跑它"
  [[ "$(cat "$FENT/deploy/bot/pdg.sh" 2>/dev/null)" == *OLD-ENTRY* ]] \
    && ok "10c-4: 盘上那份 pdg.sh 的确是旧入口(内容核对过, 不是靠推断)" || ok "10c-4: 工作树未展开(--no-checkout), 无旧入口可跑"
else bad "10c-3: 副本停在 ${H_LOCK:0:12}, 场景没造出来"; fi
rm -f "$FENT/.git/index.lock"

echo "  ── 10c2 守卫拒绝时, 哨兵必须当场停(自建仓库 + 它的 linked worktree) ──"
# 用**自有**的一次性仓库造一个 linked worktree: 它与上游共享 ref 库, 正是守卫要拦的形态。
GW_REPO="$WORK/gw-repo"; GW_WT="$WORK/gw-wt"; rm -rf "$GW_REPO" "$GW_WT"
command git init -q -b main "$GW_REPO"
g "$GW_REPO" config user.email t@t; g "$GW_REPO" config user.name t; g "$GW_REPO" config commit.gpgsign false
echo a > "$GW_REPO/f"; g "$GW_REPO" add -A; g "$GW_REPO" commit -qm a
echo b > "$GW_REPO/f"; g "$GW_REPO" add -A; g "$GW_REPO" commit -qm b
GW_OTHER="$(command git -C "$GW_REPO" rev-parse HEAD~1)"
g "$GW_REPO" worktree add -q --detach "$GW_WT" HEAD >/dev/null 2>&1
if [[ -e "$GW_WT/.git" ]]; then
  ok "10c2-前提: 造出了共享 ref 库的 linked worktree(守卫该拦的正是它)"
  _h0="$(command git -C "$GW_WT" rev-parse HEAD)"
  _r0="$(command git -C "$GW_REPO" show-ref | sha256sum | cut -d' ' -f1)"
  _i0="$( [[ -f "$GW_REPO/.git/index" ]] && sha256sum "$GW_REPO/.git/index" | cut -d' ' -f1 || echo none)"
  _lock0="$(find "$GW_REPO/.git" "$GW_WT" -name 'index.lock' 2>/dev/null | wc -l)"
  _grc=0
  # 这一格的被测对象**就是哨兵脚本自己**, 所以按路径直接调它(不是裸 git, 也不该走 e2e_git ——
  # 走了就在哨兵之外先被拦掉, 那就测不到"哨兵内部守卫拒绝后它怎么办")。
  _gw_sentinel="$BIN/git"
  _gout="$(env PATH="$BIN:/usr/bin:/bin" LOCK_AT_CHECKOUT=1 LOCK_REPO="$GW_WT" LOCK_OTHER="$GW_OTHER" \
           "$_gw_sentinel" -C "$GW_WT" checkout -q --detach "$GW_OTHER" 2>&1)" || _grc=$?
  [[ "$_grc" != 0 ]] && ok "10c2-a: 守卫拒绝 ⇒ 哨兵**立即非零退出**(rc=$_grc)" || bad "10c2-a: 竟然返回 0"
  grep -q '拒绝对' <<<"$_gout" && ok "10c2-b: 保留了守卫给出的**拒绝原因**(没被吞掉)" \
                              || bad "10c2-b: 没有拒绝原因: $(head -2 <<<"$_gout")"
  [[ "$(find "$GW_REPO/.git" "$GW_WT" -name 'index.lock' 2>/dev/null | wc -l)" == "$_lock0" ]] \
    && ok "10c2-c: **没有新增锁文件**(index.lock 数仍是 $_lock0)" || bad "10c2-c: 多了锁文件"
  [[ "$(command git -C "$GW_WT" rev-parse HEAD)" == "$_h0" ]] \
    && ok "10c2-d: worktree 的 HEAD 未变(${_h0:0:12})" || bad "10c2-d: HEAD 被改了"
  [[ "$(command git -C "$GW_REPO" show-ref | sha256sum | cut -d' ' -f1)" == "$_r0" ]] \
    && ok "10c2-e: 上游仓库的 refs 一条都没动" || bad "10c2-e: refs 变了"
  [[ "$( [[ -f "$GW_REPO/.git/index" ]] && sha256sum "$GW_REPO/.git/index" | cut -d' ' -f1 || echo none)" == "$_i0" ]] \
    && ok "10c2-f: index 未变" || bad "10c2-f: index 变了"
else bad "10c2-前提: 建不出 linked worktree(本环境可能不支持), 这一格没测到东西"; fi
rm -rf "$GW_WT"; e2e_git "$GW_REPO" worktree prune >/dev/null 2>&1

echo "  ── 10d status 查询失败且 stdout 为空 ──"
runflow statusfail FAIL_STATUS=1
{ (( FRC != 0 )) && [[ "$FOUT$FERR" == *"状态查询失败"* ]]; } \
  && ok "10d-1: 拒绝(rc=$FRC)并点名是**查询失败**, 不是'干净'" || bad "10d-1: 空输出被当成干净(rc=$FRC)"
(( SUDO_N == 0 )) && ok "10d-2: 提权哨兵 0 次" || bad "10d-2: 提权哨兵被调了 $SUDO_N 次"

echo "  ── 10e 预览返回非零 ──"
runflow previewfail SUDO_FAIL_DRYRUN=1
{ (( FRC != 0 )) && [[ "$FOUT$FERR" == *"预览失败"* ]]; } \
  && ok "10e-1: 预览非零 ⇒ 停止(rc=$FRC)" || bad "10e-1: 预览失败却继续了(rc=$FRC)"
(( SUDO_EXEC_N == 0 )) && ok "10e-2: **正式执行哨兵调用次数 = 0**(预览调用 $SUDO_N 次)" \
                       || { bad "10e-2: 正式执行被调了 $SUDO_EXEC_N 次"; sed 's/^/        /' "$SUDO_LOG"; }

echo "  ── 10f 变量不会因脚本边界丢失(文档要求整段存成一个文件跑) ──"
# 反证: 把同一段流程**按空行切成几块**分别跑(就是"分段粘进终端"那种用法), 变量必然丢。
awk 'BEGIN{n=0} /^$/{n++} {print > "'"$WORK"'/part" (n<3?n:2) ".sh"}' "$FLOW"
seg_rc=0; env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" SUDO_LOG="$WORK/seg.log" \
  bash -c "bash '$WORK/part0.sh' >/dev/null 2>&1; bash '$WORK/part2.sh'" >/dev/null 2>&1 || seg_rc=$?
(( seg_rc != 0 )) && ok "10f-1: 分段跑必然失败(rc=$seg_rc)—— 印证文档'整段存成一个文件'的要求" \
                  || bad "10f-1: 分段跑竟然成功了, 说明这段流程并不需要同一上下文"
runflow whole
(( FRC == 0 )) && ok "10f-2: 整段作为一个文件跑 ⇒ 变量贯穿全程, 通过" || bad "10f-2: 整段跑失败(rc=$FRC)"

echo "  ── 10g 定点撤销对照: 撤掉哪一道, 哪一类输入就放行 ──"
rev(){ # $1=名字 $2=sed 表达式 $3=场景env $4=期望(pass=应当放行/stop=应当仍拒)
  local nm="$1" expr="$2" envs="$3" want="$4"
  sed -E "$expr" "$FLOW" > "$WORK/rev.sh"
  if cmp -s "$FLOW" "$WORK/rev.sh"; then bad "10g[$nm]: 撤销没打上(锚点没命中)—— 这一格不算证据"; return; fi
  bash -n "$WORK/rev.sh" 2>/dev/null || { bad "10g[$nm]: 撤销版本语法错, 不算证据"; return; }
  local ent="$WORK/rev-ent"; rm -rf "$ent"; local log="$WORK/rev-sudo.log"; : > "$log"
  local rc=0
  # shellcheck disable=SC2086
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" SUDO_LOG="$log" LOCK_REPO="$ent" LOCK_OTHER="$OLD_C" \
      TAG=v1.11.15 WANT="$NEW_C" ENTRY="$ent" SRC="$OFF" $envs bash "$WORK/rev.sh" >/dev/null 2>&1 || rc=$?
  local n; n=$(grep -c . "$log")
  if [[ "$want" == ctrl ]]; then
    { (( rc == 0 )) && (( n == 2 )); } \
      && ok "10g[$nm]: 对照 —— 结论不变(rc=$rc, 提权哨兵 2 次), 零新增失败" \
      || bad "10g[$nm]: 只加一行注释结论却变了(rc=$rc, 哨兵 $n 次)"
  elif [[ "$want" == pass ]]; then
    (( n > 0 )) && ok "10g[$nm]: 撤掉之后该输入**被放行**(提权哨兵 $n 次)—— 原判据确实在起作用" \
                || bad "10g[$nm]: 撤掉后仍被拦(哨兵 $n 次), 这一道的区分力没证到"
  else
    (( n == 0 )) && ok "10g[$nm]: 撤掉这一道后仍被另一道拦住(哨兵 0 次)—— 两道并存, 如实记" \
                 || bad "10g[$nm]: 撤掉后被放行(哨兵 $n 次)"
  fi
}
# 锚在 `|| stop "检出失败…"` 那一段上: 效果与"撤掉 ⑤ 的退出码检查"一样, 而表达式里
# 不出现 git 字样 —— 守卫的文本扫描不会再把这条 sed **字符串**当成真实调用。
rev "撤⑤检出rc"      's# \|\| stop "检出失败[^"]*"##'  "LOCK_AT_CHECKOUT=1" stop
rev "撤⑥读回HEAD"    '/^HEAD_SHA=|^\[ "\$HEAD_SHA" = "\$WANT" \]/d'                          "LOCK_AT_CHECKOUT=1" stop
rev "撤⑤+⑥"        's# \|\| stop "检出失败[^"]*"##; /^HEAD_SHA=|^\[ "\$HEAD_SHA" = "\$WANT" \]/d' "LOCK_AT_CHECKOUT=1" pass
rev "⑦改回吞错写法"  's|^if ! ST=.*$|ST="$(git -C "$ENTRY" status --porcelain)"|'             "FAIL_STATUS=1"      pass
rev "撤⑧预览阻断"    's|^sudo bash "\$ENTRY/deploy/bot/pdg.sh" update --dry-run --to "\$TAG" \\\\$|sudo bash "$ENTRY/deploy/bot/pdg.sh" update --dry-run --to "$TAG" \|\| true|; /^  \|\| stop "预览失败/d' "SUDO_FAIL_DRYRUN=1" pass
rev "无关注释(对照)"  '1a\# 对照: 这行注释不参与任何判定'                                      ""                   ctrl
echo
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
