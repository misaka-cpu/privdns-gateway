#!/usr/bin/env bash
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 只放**一个**函数, 且没有任何顶层副作用 —— 它要被两类调用方 source: 走 e2e harness 的
# (经 e2e-lib.sh)和不走的(如 test-update-rollback.sh)。后者不能整个 source e2e-lib.sh,
# 那会连 ok()/bad() 一起覆盖掉它自己的计数器。
# ─────────────────────────────────────────────────────────────────────────────

# git **ref 库**守卫。与 e2e_guard_path 是两件事, 谁也替代不了谁: 那个管"能不能删这个
# 路径", 这个管"能不能动这个仓库的 ref"。
#
# 判据必须落在 `--git-common-dir` 上, **不能**落在目录路径上。worktree 的 `.git` 是一行
# `gitdir:` 指针**文件**, 它的路径可以在任何地方(包括沙箱内, 于是 e2e_guard_path 会放行),
# 而 refs 与 config 与主仓库**共享**。在那种目录里 `git commit` / `git tag -d` /
# `git remote remove` 打的全是开发者真仓库。
#
# 2026-07-31 就是这么丢掉全部 56 个 tag 与全部 remote-tracking 的: e2e-cli-ops 里那段
# `cd /opt/privdns-gateway || exit` 只检查目录存不存在 —— 沙箱里它确实存在, 于是整块放行,
# 而那个目录的 ref 库是主仓库的。**目录存在**证明不了**这个仓库可以随便动**。
#
# 另外: 目标不是 git 仓库时也要拒。那时 git 会顺着父目录往上找, 找到的往往正是真仓库 ——
# 比"目录不存在"更危险, 因为它不会报错。
e2e_guard_repo(){
  local dir="${1:-.}" why="" common src src_common
  if [[ ! -d "$dir" ]]; then
    why="目录不存在: $dir"
  elif ! common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)"; then
    why="不是 git 仓库(git 会向上找到别的仓库, 那更危险)"
  else
    # --git-common-dir 常是相对 $dir 的 `.git`, 必须在 $dir 里解析
    common="$(cd "$dir" && realpath -m "$common" 2>/dev/null)" || why="common dir 解析失败"
  fi
  # 第一道, 也是自持的一道: 这个仓库的 ref 库必须**属于它自己**。
  #   非裸库 → common dir 必须正好是 <dir>/.git
  #   裸库   → common dir 必须正好是 <dir>
  # 对不上就说明它是个 linked worktree(refs 在别人家), 或者传进来的是某个仓库的子目录 ——
  # 两种情况下动 ref 打的都是**另一个**仓库。这条不依赖 E2E_ROOT, 所以对"任何仓库的
  # worktree"都成立, 不只是源码仓库的。
  if [[ -z "$why" ]]; then
    local self bare
    bare="$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null)"
    if [[ "$bare" == true ]]; then
      self="$(realpath -m "$dir" 2>/dev/null)"
    else
      self="$(realpath -m "$dir/.git" 2>/dev/null)"
    fi
    [[ "$common" == "$self" ]] || \
      why="ref 库不属于这个目录自己($common ≠ $self) —— 它是 linked worktree, 或是某个仓库的子目录"
  fi
  if [[ -z "$why" ]]; then
    src="$(realpath -m "${E2E_ROOT:-/nonexistent}" 2>/dev/null)"
    if src_common="$(git -C "$src" rev-parse --git-common-dir 2>/dev/null)"; then
      src_common="$(cd "$src" && realpath -m "$src_common" 2>/dev/null)"
    else
      src_common=""
    fi
    if [[ -n "$src_common" && "$common" == "$src_common" ]]; then
      why="目标与源码仓库共用同一个 ref 库($common) —— 它是仓库本体或它的 worktree"
    elif [[ "$common" == "$src"/* ]]; then
      why="目标的 ref 库落在源码仓库内: $common"
    fi
  fi
  [[ -z "$why" ]] && return 0
  echo "[FAIL] 拒绝对 $dir 执行会改动 ref/config 的 git 操作: $why" >&2
  return 1
}
