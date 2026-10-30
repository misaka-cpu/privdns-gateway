#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────────────
# tools/kernel-watch.sh: 每周查 mihomo 上游, 比钉死的新就换钉值、推分支、开 PR、派发 CI。
#
# 这一支钉住它的契约, 不联网: gh 由替身应答, 换钉值由替身改写沙箱里的 versions.sh,
# "远端"是本地一个裸库。要钉的几件事:
#   · 只跟稳定版(预发布 / 草稿 / 形态不对的版本号一律不动), 只在上游**更新**时动;
#   · 幂等: 同版本已有分支或打开的 PR 就什么都不做;
#   · 换钉值失败、或者改动不止 lib/versions.sh 时, 不推、不开 PR;
#   · 顺序: 先推分支, 再开 PR, 最后派发 CI(GITHUB_TOKEN 开的 PR 不会自己触发 CI);
#   · 不在 Actions 里、或不在默认分支上时拒绝 —— 它会推分支, 不能在本地误跑。
# 工作流文件本身(触发、权限、只用登记过的 action)另在第 6 节按文本核。
# ───────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-kwatch.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"    # e2e_git: 守卫与动作绑成一件事(见 test-e2e-repo-guard.py)

TOOL="$ROOT/tools/kernel-watch.sh"
WF="$ROOT/.github/workflows/kernel-watch.yml"
CUR="$(sed -n 's/^MIHOMO_VER="\([^"]*\)".*/\1/p' "$ROOT/lib/versions.sh" | head -1)"

echo "══ 0. 工具存在、可执行、语法通过 ══"
[[ -x "$TOOL" ]] && ok "tools/kernel-watch.sh 存在且可执行" || bad "tools/kernel-watch.sh 不存在或没有可执行位"
bash -n "$TOOL" && ok "bash -n 通过" || bad "语法错"
[[ "$CUR" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "读到当前钉的 MIHOMO_VER=$CUR" || bad "读不出 MIHOMO_VER('$CUR')"

# ── 替身 ───────────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh 替身: 记录每次调用; 按环境变量应答
echo "gh $*" >> "$KW_LOG"
case "$1 $2" in
  "api repos/MetaCubeX/mihomo/releases/latest") printf '%s\n' "$KW_LATEST"; exit "${KW_API_RC:-0}" ;;
  "pr list")   echo "${KW_OPEN_PRS:-0}"; exit 0 ;;
  "pr create")
    # 开 PR 那一刻, 分支必须已经在远端 —— 记下来给顺序断言用
    br=""; while [[ $# -gt 0 ]]; do [[ "$1" == --head ]] && br="$2"; shift; done
    git --git-dir="$KW_ORIGIN" rev-parse -q --verify "refs/heads/$br" >/dev/null \
      && echo "pr-create: 分支已在远端" >> "$KW_LOG" || echo "pr-create: 分支不在远端" >> "$KW_LOG"
    exit "${KW_PR_RC:-0}" ;;
  "workflow run") exit 0 ;;
esac
echo "gh 替身: 没想到的调用 $*" >&2; exit 99
EOF
cat > "$WORK/bin/bump" <<'EOF'
#!/usr/bin/env bash
# bump-kernel 替身: 只改写沙箱里 versions.sh 的版本行(不联网); 可模拟失败或越界改动
echo "bump $*" >> "$KW_LOG"
[[ "${KW_BUMP:-ok}" == fail ]] && exit 1
sed -i "s/^MIHOMO_VER=\"[^\"]*\"/MIHOMO_VER=\"$2\"/" "$PDG_WATCH_ROOT/lib/versions.sh"
[[ "${KW_BUMP:-ok}" == extra ]] && echo extra >> "$PDG_WATCH_ROOT/README-extra"
exit 0
EOF
chmod +x "$WORK/bin/gh" "$WORK/bin/bump"

# 每格一个新沙箱: 一个只有 lib/versions.sh 的仓库 + 一个裸库当 origin
box(){
  local n="$1"; B="$WORK/$n"; mkdir -p "$B/repo/lib"
  cp "$ROOT/lib/versions.sh" "$B/repo/lib/versions.sh"
  git init -q --bare "$B/origin.git" >/dev/null 2>&1
  git init -q -b main "$B/repo" >/dev/null 2>&1      # git init 不受限: 仓库还不存在时守卫必然假拒
  e2e_git "$B/repo" config user.email t@t         >/dev/null 2>&1
  e2e_git "$B/repo" config user.name t            >/dev/null 2>&1
  e2e_git "$B/repo" config commit.gpgsign false   >/dev/null 2>&1
  e2e_git "$B/repo" add -A                        >/dev/null 2>&1
  e2e_git "$B/repo" commit -qm base               >/dev/null 2>&1
  e2e_git "$B/repo" remote add origin "$B/origin.git" >/dev/null 2>&1
  e2e_git "$B/repo" push -q origin main           >/dev/null 2>&1
  : > "$B/log"
}
# run <最新版 TSV> [额外环境…]: 在 Actions 的样子下跑一次工具
run(){
  local latest="$1"; shift
  out=$(env PATH="$WORK/bin:$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=owner/pdg GITHUB_REF=refs/heads/main \
            PDG_WATCH_ROOT="$B/repo" PDG_WATCH_BUMP="$WORK/bin/bump" KW_LOG="$B/log" KW_ORIGIN="$B/origin.git" \
            KW_LATEST="$latest" "$@" bash "$TOOL" 2>&1); rc=$?
}
remote_has(){ git --git-dir="$B/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
lines(){ grep -c -- "$1" "$B/log" || true; }

echo
echo "══ 1. 上游不比钉的新 → 什么都不做 ══"
box same; run "$(printf '%s\tfalse\tfalse' "$CUR")"
{ [[ "$rc" == 0 ]] && grep -q '已是最新' <<<"$out" && [[ "$(lines 'bump ')" == 0 && "$(lines 'pr create')" == 0 ]]; } \
  && ok "上游 = 钉的版本 → rc=0, 不换钉值、不开 PR" || bad "上游与钉的相同时 rc=$rc: $out"
box older; run "$(printf 'v0.0.1\tfalse\tfalse')"
{ [[ "$rc" == 0 ]] && [[ "$(lines 'bump ')" == 0 && "$(lines 'pr create')" == 0 ]]; } \
  && ok "上游比钉的旧 → 不动(不会往回降)" || bad "上游比钉的旧时 rc=$rc: $out"

echo
echo "══ 2. 只跟稳定版、版本号形态严格 ══"
box pre; run "$(printf 'v99.0.0\ttrue\tfalse')"
{ [[ "$rc" != 0 ]] && [[ "$(lines 'bump ')" == 0 ]] && ! remote_has kernel/mihomo-v99.0.0; } \
  && ok "预发布 → 拒绝, 不换钉值" || bad "预发布时 rc=$rc: $out"
box draft; run "$(printf 'v99.0.0\tfalse\ttrue')"
{ [[ "$rc" != 0 ]] && [[ "$(lines 'bump ')" == 0 ]]; } && ok "草稿 → 拒绝" || bad "草稿时 rc=$rc: $out"
box shape; run "$(printf 'v99.0.0; rm -rf /\tfalse\tfalse')"
{ [[ "$rc" != 0 ]] && [[ "$(lines 'bump ')" == 0 ]]; } && ok "版本号形态不对 → 拒绝(它会拼进分支名与 URL)" || bad "坏版本号时 rc=$rc: $out"
box api; run "" KW_API_RC=1
{ [[ "$rc" != 0 ]] && [[ "$(lines 'bump ')" == 0 ]]; } && ok "查不到上游 → 非零, 不动" || bad "查询失败时 rc=$rc: $out"

echo
echo "══ 3. 有新版: 换钉值 → 推分支 → 开 PR → 派发 CI ══"
NEW="v99.0.0"; BR="kernel/mihomo-$NEW"
box new; run "$(printf '%s\tfalse\tfalse' "$NEW")"
[[ "$rc" == 0 ]] && ok "rc=0" || bad "rc=$rc: $out"
[[ "$(lines "bump mihomo $NEW")" == 1 ]] && ok "换钉值调用一次, 参数是 mihomo $NEW" || bad "换钉值调用不对: $(cat "$B/log")"
remote_has "$BR" && ok "远端有分支 $BR" || bad "远端没有分支 $BR"
got="$(git --git-dir="$B/origin.git" show "refs/heads/$BR:lib/versions.sh" 2>/dev/null | sed -n 's/^MIHOMO_VER="\([^"]*\)".*/\1/p')"
[[ "$got" == "$NEW" ]] && ok "分支上的 versions.sh 钉的是 $NEW" || bad "分支上的 MIHOMO_VER 是 '$got'"
files="$(git --git-dir="$B/origin.git" diff --name-only main "refs/heads/$BR" 2>/dev/null | tr '\n' ' ')"
[[ "$files" == "lib/versions.sh " ]] && ok "分支相对 main 只改了 lib/versions.sh" || bad "分支改动: '$files'"
remote_has main && [[ "$(git --git-dir="$B/origin.git" rev-parse main)" == "$(git -C "$B/repo" rev-parse main)" ]] \
  && ok "main 没被推动" || bad "远端 main 变了"
grep -q -- "--base main --head $BR" "$B/log" && ok "开 PR: base=main, head=$BR" || bad "开 PR 的参数不对: $(grep 'pr create' "$B/log")"
grep -q 'pr-create: 分支已在远端' "$B/log" && ok "开 PR 时分支已经推上去了(先推后开)" || bad "开 PR 时分支还不在远端"
grep -q "gh workflow run ci.yml --repo owner/pdg --ref $BR" "$B/log" && ok "派发了 ci.yml 到 $BR" || bad "没有派发 CI"
n_pr="$(grep -n 'gh pr create' "$B/log" | cut -d: -f1)"; n_ci="$(grep -n 'gh workflow run' "$B/log" | cut -d: -f1)"
[[ -n "$n_pr" && -n "$n_ci" && "$n_pr" -lt "$n_ci" ]] && ok "先开 PR, 再派发 CI" || bad "顺序不对: pr=$n_pr ci=$n_ci"
# 版本比较按语义: v1.19.100 比 v1.19.33 新(按字符串比会反过来)
box semver; run "$(printf 'v%s\tfalse\tfalse' "$(awk -F. '{print $1"."$2"."$3+100}' <<<"${CUR#v}")")"
[[ "$(lines 'bump mihomo')" == 1 ]] && ok "补丁号多一位数也认得是新版(按版本号比, 不按字符串)" || bad "版本比较不对: $out"

echo
echo "══ 4. 幂等与失败路径 ══"
box exists; e2e_git "$B/repo" push -q origin "main:refs/heads/$BR" >/dev/null 2>&1
run "$(printf '%s\tfalse\tfalse' "$NEW")"
{ [[ "$rc" == 0 ]] && [[ "$(lines 'bump ')" == 0 && "$(lines 'pr create')" == 0 ]]; } \
  && ok "同版本分支已在远端 → 不重复开" || bad "分支已在时 rc=$rc: $out"
box openpr; run "$(printf '%s\tfalse\tfalse' "$NEW")" KW_OPEN_PRS=1
{ [[ "$rc" == 0 ]] && [[ "$(lines 'bump ')" == 0 && "$(lines 'pr create')" == 0 ]] && ! remote_has "$BR"; } \
  && ok "已有打开的 PR → 不重复开" || bad "已有 PR 时 rc=$rc: $out"
box bumpfail; run "$(printf '%s\tfalse\tfalse' "$NEW")" KW_BUMP=fail
{ [[ "$rc" != 0 ]] && ! remote_has "$BR" && [[ "$(lines 'pr create')" == 0 && "$(lines 'workflow run')" == 0 ]]; } \
  && ok "换钉值失败 → 非零, 不推、不开 PR、不派发" || bad "换钉值失败时 rc=$rc: $out"
box extra; run "$(printf '%s\tfalse\tfalse' "$NEW")" KW_BUMP=extra
{ [[ "$rc" != 0 ]] && ! remote_has "$BR" && [[ "$(lines 'pr create')" == 0 ]]; } \
  && ok "改动不止 lib/versions.sh → 非零, 不推、不开 PR" || bad "越界改动时 rc=$rc: $out"
box prfail; run "$(printf '%s\tfalse\tfalse' "$NEW")" KW_PR_RC=1
{ [[ "$rc" != 0 ]] && [[ "$(lines 'workflow run')" == 0 ]]; } && ok "开 PR 失败 → 非零, 不派发 CI" || bad "开 PR 失败时 rc=$rc: $out"

echo
echo "══ 5. 只在 Actions 里、只在默认分支上跑 ══"
box local
out=$(env -u GITHUB_ACTIONS -u PDG_WATCH_ALLOW_LOCAL PATH="$WORK/bin:$PATH" GITHUB_REPOSITORY=owner/pdg PDG_WATCH_ROOT="$B/repo" \
          PDG_WATCH_BUMP="$WORK/bin/bump" KW_LOG="$B/log" KW_ORIGIN="$B/origin.git" \
          KW_LATEST="$(printf '%s\tfalse\tfalse' "$NEW")" bash "$TOOL" 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && [[ ! -s "$B/log" ]]; } && ok "不在 Actions 里 → 拒绝, 一个调用都没发" || bad "本地误跑时 rc=$rc, 调用: $(cat "$B/log")"
box branch; run "$(printf '%s\tfalse\tfalse' "$NEW")" GITHUB_REF=refs/heads/feature
{ [[ "$rc" != 0 ]] && [[ ! -s "$B/log" ]]; } && ok "不在 main 上 → 拒绝(否则会把那条分支的提交带进 PR)" || bad "非默认分支时 rc=$rc: $out"

echo
echo "══ 6. 工作流文件 ══"
[[ -f "$WF" ]] && ok ".github/workflows/kernel-watch.yml 存在" || bad "没有 kernel-watch.yml"
grep -qE '^[[:space:]]+- cron: "[0-9]+ [0-9]+ \* \* [0-6]"' "$WF" && ok "每周定时触发" || bad "没有每周的 cron"
grep -qE '^[[:space:]]+workflow_dispatch:' "$WF" && ok "可手动触发(workflow_dispatch)" || bad "没有 workflow_dispatch"
perm="$(sed -n '/^permissions:/,/^[a-z]/p' "$WF" | grep -oE '^[[:space:]]+[a-z-]+: [a-z]+' | tr -s ' ' | sort | tr '\n' ';')"
[[ "$perm" == " actions: write; contents: write; pull-requests: write;" ]] \
  && ok "权限只开了 contents / pull-requests / actions 三项写权限" || bad "权限不对: '$perm'"
uses="$(grep -oE 'uses: [^ ]+' "$WF" | sort -u | tr '\n' ' ')"
[[ "$uses" == "uses: actions/checkout@v5 " ]] && ok "只用 actions/checkout@v5(没有第三方 action)" || bad "用到的 action: '$uses'"
grep -q 'GH_TOKEN: ${{ github.token }}' "$WF" && ok "gh 用工作流自带的 token" || bad "没给 gh 设 GH_TOKEN"
grep -q 'run: bash tools/kernel-watch.sh' "$WF" && ok "调用 tools/kernel-watch.sh" || bad "没有调用 tools/kernel-watch.sh"
grep -q 'kernel-watch' "$ROOT/.github/workflows/ci.yml" && ok "本测试已登记进 ci.yml" || bad "ci.yml 里没有登记本测试"

echo "────────────────────────────────────────"
echo "test-kernel-watch.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]
