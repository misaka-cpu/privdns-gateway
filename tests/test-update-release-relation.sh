#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# `pdg update` 只跟随发布 tag。以前的判据只有一条: HEAD 与最新 tag **恰好相等**就短路,
# 否则一律 `git reset --hard <tag>`。于是当 HEAD 是最新 tag 的**后代**(机器上跑着尚未发布
# 的提交)时, 一次普通的 `pdg update` 会把它静默退回上一个 Release —— 不提示、不确认,
# 事后只能从 mtime 和 git reflog 里倒推出发生过什么。
#
# 这一支钉住四种关系各自该有的行为, 用**真 git 仓库**造拓扑(不打桩 git 的祖先判定,
# 否则测的是桩的想法而不是 git 的想法):
#
#   HEAD 与最新 tag 的关系          正式 update 应有行为
#   ─────────────────────────      ─────────────────────────────────────────
#   完全相同                        文件同步时幂等短路(不建快照、不重启)
#   当前落后(tag 是当前后代)        正常升级
#   当前领先(tag 是当前祖先)        明确拒绝: 不建快照、不 reset、不重启
#   两边分叉                        明确拒绝: 不猜方向、不 reset
#
# 外加: 没有 tag 沿用既有 fail-closed; 关系判不出来时非零退出且无副作用;
#       --dry-run 在"当前领先"时必须说清会拒绝, 不许只显示一段空的 HEAD..tag。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-updrel.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

command -v git >/dev/null 2>&1 || { echo "[SKIP] 没有 git —— 这一支必须用真 git 判祖先关系"; exit 0; }
# 会动 ref/config 的 git 一律走 e2e_git: 它把守卫和动作绑成一件事, 于是不存在"忘了守"
# 这种形态。由来是一次真事故 —— 裸 git 打在了本仓库上, 56 个 tag 与全部 remote-tracking
# 一起没了。这一支要造四种 git 拓扑, 正是最该走它的用例。
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

sed -n '/^cmd_update(){/,/^}/p'                 "$ROOT/deploy/bot/pdg.sh" > "$WORK/upd.sh"
sed -n '/^_update_release_relation(){/,/^}/p'   "$ROOT/deploy/bot/pdg.sh" > "$WORK/rel.sh"

# ── 判据函数必须存在, 且**只有一份** ────────────────────────────────────────
# dry-run 与正式 update 各写一份关系判断的话, 两边迟早会漂: 一边修好了另一边还在降级。
if [[ -s "$WORK/rel.sh" ]]; then
  ok "pdg.sh 里有 _update_release_relation 这个单一判据"
else
  bad "pdg.sh 里没有 _update_release_relation —— 关系判断没有单一事实源"
fi
_ndef=$(grep -c '^_update_release_relation(){' "$ROOT/deploy/bot/pdg.sh")
[[ "$_ndef" == 1 ]] && ok "判据只定义了一次(实得 $_ndef)" || bad "判据定义了 $_ndef 次"
_nuse=$(grep -c '_update_release_relation' "$ROOT/deploy/bot/pdg.sh")
[[ "$_nuse" -ge 3 ]] \
  && ok "判据被 dry-run 与正式路径共用(引用 $_nuse 处 ≥ 定义1+调用2)" \
  || bad "判据只出现 $_nuse 处 —— dry-run 与正式 update 没有共用它"

# ── 真 git 拓扑 ─────────────────────────────────────────────────────────────
g(){ e2e_git "$1" "${@:2}"; }          # 只读查询也走它: 目标始终是本轮自造的一次性仓库
mkrepo(){ # $1=目标目录 $2=是否给 C 打 v2.0.0(1/0); 造出 A(v1.0.0) → B → C 与从 A 分叉的 D
  local r="$1" tag2="${2:-0}"
  rm -rf "$r"; mkdir -p "$r"
  # init 时目标还不是仓库, e2e_guard_repo 必然拒 —— 这一处只能裸调, 但它建的是本轮自己
  # 刚 mkdir 出来的空目录, 且 $WORK 由 mktemp 生成。init 之后所有操作都走 e2e_git。
  command git -C "$r" init -q -b main
  g "$r" config user.email t@t; g "$r" config user.name t; g "$r" config commit.gpgsign false
  mkdir -p "$r/lib"
  # cmd_update 会 source 仓库里的运行模块清单; 给一份最小替身(真清单要校验源文件存在)
  printf 'pdg_install_runtime_modules(){ return 0; }\n' > "$r/lib/modules.sh"
  echo A > "$r/f"; g "$r" add -A; g "$r" commit -qm A
  g "$r" tag -a v1.0.0 -m v1.0.0
  echo B > "$r/f"; g "$r" add -A; g "$r" commit -qm B
  echo C > "$r/f"; g "$r" add -A; g "$r" commit -qm C
  # v2.0.0 是可选的: "当前领先最新发布"这一态**必须**没有更高的 tag, 否则 HEAD 恰好落在
  # 最新 tag 上, 测的就变成 same 而不是 ahead 了(第一版就是这么把红灯测没的)。
  [[ "$tag2" == 1 ]] && g "$r" tag -a v2.0.0 -m v2.0.0
  g "$r" checkout -q -b side v1.0.0
  echo D > "$r/f"; g "$r" add -A; g "$r" commit -qm D
  g "$r" checkout -q main
}

cat > "$WORK/harness.sh" <<'EOF'
REPO_DIR="$WORK/repo"; REPO_URL="file:///dev/null"; ENVF="$WORK/none.env"
need_root(){ :; }
_lock(){ :; }
c_g(){ echo "$*"; }
c_y(){ echo "$*"; }
sleep(){ :; }
_pdg_platform(){ echo "${PLATFORM:-android}"; }
_pdg_core(){ echo mihomo; }
_pdg_bot_cred(){ echo "${CRED:-unset}"; }
pdg_fetch_release_tags(){ [[ -n "${FAIL_FETCH:-}" ]] && return 1; return 0; }
# 已装文件是否与仓库一致: 这条另有专测, 这里只当成一个可控输入。
_update_in_sync(){ return "${INSYNC_RC:-0}"; }
# git **不打桩** —— 祖先关系必须由真 git 判。只记录调用, 便于断言 reset 到底有没有发生。
git(){ printf '%s\n' "$*" >> "$WORK/git.log"; command git "$@"; }
install(){ printf 'install %s\n' "$*" >> "$WORK/side.log"; return 0; }
bash(){ [[ "$*" == *__migrate* ]] && { echo "migrate" >> "$WORK/side.log"; return 0; }; command bash "$@"; }
_update_core_binary(){ echo "core" >> "$WORK/side.log"; return 0; }
systemctl(){ printf 'systemctl %s\n' "$*" >> "$WORK/side.log"; return 0; }
python3(){ case "$*" in *py_compile*) return 0;; *doctor.py*) echo '[{"level":"ok","check":"服务","detail":"都在"}]'; return 0;; *) command python3 "$@";; esac; }
mihomo(){ return 0; }
nft(){ return 0; }
cmd_snapshot(){ echo "SNAPSHOT_CALLED" >> "$WORK/side.log"
  _PDG_SNAP_CREATED="$WORK/snap"; mkdir -p "$_PDG_SNAP_CREATED"; : | gzip > "$_PDG_SNAP_CREATED/snap.tar.gz"; return 0; }
cmd_rollback(){ echo "ROLLBACK_CALLED $*" >> "$WORK/side.log"; return 0; }
EOF
export WORK

# run <HEAD-ref> <额外env> [--dry-run] → "<rc>|<输出>"; 副作用记在 $WORK/side.log, git 调用记在 git.log
run(){
  local head="$1" tag2="$2" envs="$3"; shift 3
  mkrepo "$WORK/repo" "$tag2" >/dev/null 2>&1
  g "$WORK/repo" checkout -q "$head"
  : > "$WORK/side.log"; : > "$WORK/git.log"
  local rc=0 out
  # shellcheck disable=SC2086
  out=$(env $envs bash -c "source '$WORK/harness.sh'; source '$WORK/rel.sh'; source '$WORK/upd.sh'; cmd_update $*" 2>&1) || rc=$?
  printf '%s\n' "$rc|$out"
}
side(){ grep -qF "$1" "$WORK/side.log" 2>/dev/null; }
did_reset(){ grep -qE '(^| )reset ' "$WORK/git.log" 2>/dev/null; }

# ── 关系判据本身: 四态 ──────────────────────────────────────────────────────
echo "══ 1. _update_release_relation 四态 ══"
relof(){ # $1=HEAD ref, $2=tag → 打印判据结果; 判不出来打印 "<rc=N>"
  mkrepo "$WORK/repo" 1 >/dev/null 2>&1
  g "$WORK/repo" checkout -q "$1"
  local r rc=0
  r=$(bash -c "source '$WORK/rel.sh'; _update_release_relation '$WORK/repo' '$2'") || rc=$?
  [[ "$rc" == 0 ]] && printf '%s' "$r" || printf '<rc=%s>' "$rc"
}
if [[ -s "$WORK/rel.sh" ]]; then
  r=$(relof v1.0.0 v1.0.0); [[ "$r" == same ]]     && ok "HEAD 就是 tag → same" || bad "same 判成了 '$r'"
  r=$(relof v1.0.0 v2.0.0); [[ "$r" == behind ]]   && ok "tag 是 HEAD 的后代 → behind" || bad "behind 判成了 '$r'"
  r=$(relof main   v1.0.0); [[ "$r" == ahead ]]    && ok "HEAD 是 tag 的后代 → ahead(未发布提交)" || bad "ahead 判成了 '$r'"
  r=$(relof side   v2.0.0); [[ "$r" == diverged ]] && ok "两边分叉 → diverged" || bad "diverged 判成了 '$r'"
  # 判不出关系: 目标 tag 根本不存在 → 必须非零退出, 不许退回某个默认关系
  r=$(relof main   v9.9.9); [[ "$r" == "<rc=1>" ]] && ok "tag 解析不了 → 非零退出, 不给默认关系" || bad "tag 不存在时返回了 '$r'"
  r=$(bash -c "source '$WORK/rel.sh'; _update_release_relation '$WORK/nosuchrepo' v1.0.0"; echo "rc=$?" ) 
  [[ "$r" == *"rc=1"* ]] && ok "不是 git 仓库 → 非零退出" || bad "非仓库时返回了 '$r'"
else
  bad "判据缺失, 四态无从验证(以下正式 update 的断言仍会跑)"
fi

echo
echo "══ 2. 正式 update: 当前领先最新发布 → 拒绝且零副作用 ══"
r=$(run main 0 "")
rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "rc 非 0(实得 $rc)" || bad "当前领先最新发布, update 竟然 rc=0 —— 这就是静默降级"
did_reset && bad "执行了 reset --hard —— 未发布提交被退回: $(grep -oE 'reset.*' "$WORK/git.log" | head -1)" || ok "没有执行 reset"
side SNAPSHOT_CALLED && bad "建了快照(拒绝路径不该有任何副作用)" || ok "没建快照"
side migrate         && bad "跑了迁移" || ok "没跑迁移"
side "install "      && bad "装了文件" || ok "没装任何文件"
side systemctl       && bad "碰了 systemctl" || ok "没碰 systemctl"
grep -qE '未发布|领先|拒绝' <<<"$out" && ok "说清了为什么拒绝(实得: $(grep -m1 -E '未发布|领先|拒绝' <<<"$out"))" \
  || bad "拒绝了却没说原因: $(tail -3 <<<"$out")"
grep -q '✅ 已更新' <<<"$out" && bad "谎报成功" || ok "没谎报成功"
# 环境变量不得成为降级后门: PDG_UPDATE_FORCE 是"强制重装同一版本", 不是"允许降级"
r=$(run main 0 "PDG_UPDATE_FORCE=1"); rc="${r%%|*}"
[[ "$rc" != 0 ]] && ok "PDG_UPDATE_FORCE=1 也拒绝(它不是降级开关)" || bad "PDG_UPDATE_FORCE 成了降级后门"
did_reset && bad "PDG_UPDATE_FORCE 下执行了 reset --hard" || ok "PDG_UPDATE_FORCE 下也没 reset"

echo
echo "══ 3. 正式 update: 两边分叉 → 拒绝, 不猜方向 ══"
r=$(run side 1 ""); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "rc 非 0(实得 $rc)" || bad "分叉时 update rc=0"
did_reset && bad "分叉时执行了 reset --hard" || ok "分叉时没 reset"
side SNAPSHOT_CALLED && bad "分叉时建了快照" || ok "分叉时没建快照"
grep -qE '分叉|拒绝' <<<"$out" && ok "说清了是分叉" || bad "分叉没说清: $(tail -3 <<<"$out")"

echo
echo "══ 4. 正式 update: 当前落后 → 正常升级 ══"
r=$(run v1.0.0 1 ""); rc="${r%%|*}"; out="${r#*|}"
did_reset && ok "落后时照常 reset 到发布 tag" || bad "落后时没有升级 —— 判据把正常升级也挡了"
[[ "$rc" == 0 ]] && ok "落后时 rc=0" || bad "落后时 rc=$rc: $(tail -3 <<<"$out")"

echo
echo "══ 5. 正式 update: HEAD 就是最新发布 → 幂等短路 ══"
r=$(run v1.0.0 0 "INSYNC_RC=0"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" == 0 ]] && ok "相同时 rc=0" || bad "相同时 rc=$rc"
side SNAPSHOT_CALLED && bad "相同且已同步却建了快照" || ok "相同且已同步: 未建快照"
grep -q '已是最新发布' <<<"$out" && ok "明说已是最新" || bad "没说已是最新: $(tail -3 <<<"$out")"

echo
echo "══ 6. 没有发布 tag → 沿用既有 fail-closed ══"
mkrepo "$WORK/repo" 1 >/dev/null 2>&1
g "$WORK/repo" tag -d v1.0.0 >/dev/null; g "$WORK/repo" tag -d v2.0.0 >/dev/null
: > "$WORK/side.log"; : > "$WORK/git.log"
out=$(bash -c "source '$WORK/harness.sh'; source '$WORK/rel.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "无 tag → rc 非 0" || bad "无 tag 却 rc=0"
grep -qE '没有发布 tag|没有任何发布 tag|无法确定目标版本' <<<"$out" \
  && ok "无 tag 的措辞未变(e2e-update.sh 据此判)" || bad "无 tag 措辞变了: $(tail -3 <<<"$out")"
did_reset && bad "无 tag 却 reset 了" || ok "无 tag 没 reset"

echo
echo "══ 7. --dry-run 在「当前领先」时必须说清会拒绝 ══"
r=$(run main 0 "" --dry-run); rc="${r%%|*}"; out="${r#*|}"
grep -qE '未发布|领先' <<<"$out" && ok "dry-run 说清当前是未发布提交" \
  || bad "dry-run 没说当前领先: $out"
grep -qE '拒绝|不会自动降级|不会降级' <<<"$out" && ok "dry-run 说清正式 update 会拒绝、不会自动降级" \
  || bad "dry-run 没说会拒绝: $out"
# 旧文案的病灶: 打印一段空的 "待更新提交(HEAD..tag):" 然后什么都不列 → 看着像"已是最新"
if grep -q 'HEAD\.\.' <<<"$out"; then
  bad "dry-run 仍在显示空的 HEAD..tag 区间 —— 会被读成「无需更新」"
else
  ok "dry-run 不再显示那段会被误读的空 HEAD..tag"
fi
side SNAPSHOT_CALLED && bad "dry-run 建了快照" || ok "dry-run 零副作用: 没建快照"
did_reset && bad "dry-run 执行了 reset --hard" || ok "dry-run 零副作用: 没 reset"
# dry-run 在正常「落后」时仍要列出待更新提交
r=$(run v1.0.0 1 "" --dry-run); out="${r#*|}"
grep -q 'B' <<<"$out" && ok "dry-run 落后时照旧列出待更新提交" || bad "dry-run 落后时不列提交了: $out"

echo "────────────────────────────────────────"
echo "test-update-release-relation.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
