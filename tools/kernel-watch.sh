#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mihomo 上游监视: 上游最新**稳定版**比钉死的新, 就换钉值、推分支、开 PR、派发 CI。
#
#   tools/kernel-watch.sh        (由 .github/workflows/kernel-watch.yml 每周在 main 上调用)
#
# 只做到"开 PR + 派发 CI"为止。合并、发版、机器升级都留给人: 内核随项目发版走, PR 上的
# CI 会让 E2E 真跑在新内核上, 那才是"这一版会不会弄坏分流"的答案(见 tools/bump-kernel.sh)。
# 机器不直接跟上游换内核 —— doctor 按钉值核对内核文件, pdg update 会把它收敛回钉死版。
# mosdns 不在这里: 它是有意不跟随的钉死版(上游近乎停摆)。
#
# 为什么要自己派发 CI: 用工作流自带的 GITHUB_TOKEN 推的分支、开的 PR **不会**触发
# push / pull_request 工作流(GitHub 防递归), 只有 workflow_dispatch 例外。不派发的话,
# PR 上就没有 CI, 看着像"还没跑", 实际永远不会跑。
#
# 幂等: 同一个上游版本已有分支或打开的 PR 时什么都不做(每周跑一次, 不重复开)。
# 它会推分支、开 PR —— 不在 Actions 里跑时默认拒绝, 免得维护者在本地误跑一次就推上去。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PDG_WATCH_ROOT:-$(cd "$HERE/.." && pwd)}"   # 测试可指向沙箱仓库
BUMP="${PDG_WATCH_BUMP:-$ROOT/tools/bump-kernel.sh}"  # 测试可换成不联网的替身
BASE="${PDG_WATCH_BASE:-main}"
UPSTREAM="MetaCubeX/mihomo"

die(){ echo "❌ $*" >&2; exit 1; }
say(){ echo "$*"; }

if [[ "${GITHUB_ACTIONS:-}" != true && -z "${PDG_WATCH_ALLOW_LOCAL:-}" ]]; then
  die "只在 GitHub Actions 里跑(它会推分支、开 PR); 确实要在本地跑, 设 PDG_WATCH_ALLOW_LOCAL=1"
fi
REPO="${GITHUB_REPOSITORY:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GITHUB_REPOSITORY 不是 owner/name: '$REPO'"
# 只从默认分支出发: 从别的分支派发的话, 新分支会把那条分支上的提交一起带进 PR
if [[ -n "${GITHUB_REF:-}" && "$GITHUB_REF" != "refs/heads/$BASE" ]]; then
  die "只在 $BASE 上跑(当前 $GITHUB_REF)"
fi

cur="$(sed -n 's/^MIHOMO_VER="\([^"]*\)".*/\1/p' "$ROOT/lib/versions.sh" | head -1)"
[[ "$cur" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "读不出 lib/versions.sh 里的 MIHOMO_VER(得到 '$cur')"

# releases/latest 本来就不含预发布与草稿; 字段再核一遍, 不靠默认行为
rel="$(gh api "repos/$UPSTREAM/releases/latest" \
       --jq '[.tag_name, (.prerelease|tostring), (.draft|tostring)] | @tsv')" \
  || die "查不到 $UPSTREAM 的最新版"
IFS=$'\t' read -r tag pre draft <<<"$rel"
[[ "$pre" == false && "$draft" == false ]] || die "上游 latest 是预发布或草稿($tag, prerelease=$pre draft=$draft) —— 不跟"
# 版本号会拼进分支名、URL 与文件名, 形态必须严格
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "上游版本号形态不对: '$tag'"

newest="$(printf '%s\n%s\n' "$cur" "$tag" | sort -V | tail -1)"
if [[ "$tag" == "$cur" || "$newest" != "$tag" ]]; then
  say "已是最新: 钉的是 $cur, 上游最新稳定版 $tag"
  exit 0
fi
say "上游有新版: $cur → $tag"

br="kernel/mihomo-$tag"
git -C "$ROOT" ls-remote --exit-code --heads origin "refs/heads/$br" >/dev/null 2>&1; rc=$?
case "$rc" in
  0) say "分支 $br 已存在 —— 不重复开"; exit 0;;
  2) ;;                                                  # 没有这个分支
  *) die "查不了远端分支(git ls-remote rc=$rc)";;
esac
open="$(gh pr list --repo "$REPO" --head "$br" --state open --json number --jq 'length')" \
  || die "查不了 PR 列表"
[[ "$open" == 0 ]] || { say "已有打开的 PR(head=$br)—— 不重复开"; exit 0; }

git -C "$ROOT" checkout -q -b "$br" || die "建不出分支 $br"
"$BUMP" mihomo "$tag" || die "换钉值失败(取件或校验没过)—— 不推、不开 PR"
changed="$(git -C "$ROOT" status --porcelain=v1)"
[[ "$changed" == " M lib/versions.sh" ]] \
  || die "换钉值之后改动的不只是 lib/versions.sh —— 停: $(tr '\n' ' ' <<<"$changed")"
git -C "$ROOT" -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "chore(mihomo): pin $tag" -- lib/versions.sh || die "提交失败"
git -C "$ROOT" push -q origin "HEAD:refs/heads/$br" || die "推送分支 $br 失败"

body="$(mktemp)"; trap 'rm -f "$body"' EXIT
{
  printf '上游 %s 发布了 %s(当前钉的是 %s)。\n\n' "$UPSTREAM" "$tag" "$cur"
  printf -- '- 上游发布说明: https://github.com/%s/releases/tag/%s\n' "$UPSTREAM" "$tag"
  printf -- '- 钉值由 tools/bump-kernel.sh 算出: 两个架构各自下载, 与官方 asset digest 交叉核对,\n'
  printf -- '  本机架构真跑一次核对自报版本, 另一架构核对 ELF 头; 只改 lib/versions.sh。\n'
  printf -- '- CI 已由 kernel-watch 以 workflow_dispatch 派发到分支 %s(GITHUB_TOKEN 开的 PR 不会自己触发 CI),\n' "$br"
  printf -- '  E2E 会真跑在新内核上; 在 Actions 页按这个分支查看结果。\n\n'
  printf '合并之后还要照常发版, 机器通过 pdg update 升到那一版时才会换内核。\n'
} > "$body"
gh pr create --repo "$REPO" --base "$BASE" --head "$br" \
  --title "chore(mihomo): pin $tag" --body-file "$body" || die "开 PR 失败(仓库设置里要允许 GitHub Actions 创建 PR)"
gh workflow run ci.yml --repo "$REPO" --ref "$br" || die "派发 CI 失败"
say "已开 PR 并派发 CI: $cur → $tag(分支 $br)"
