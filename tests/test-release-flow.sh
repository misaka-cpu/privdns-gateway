#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 发布链路**静态守卫** —— 不是端到端测试。
#
# 这个文件从头到尾只做一件事: 在源码里核对几个关键标识符还在不在(tag-only 安装、
# unshallow 后再比 tag、merge-base 返回码区分、文档版本号)。它**不执行** install.sh,
# 也不跑 pdg update; 只要标识符还在就会通过, 哪怕发布链路实际已经坏了。
#
# 真实行为覆盖在这两支, 它们跑真流程、真仓库、真 tag:
#   · tests/e2e-update.sh                —— 造带两个 tag 的真 git 仓库, 真跑 cmd_update
#                                            的完整路径(取 tag → reset → 装文件 → 迁移 →
#                                            校验门 → 成功/回滚)。
#   · tests/e2e-upgrade-from-release.sh  —— 机器上装的是**上一个发布 tag 的那份 pdg**,
#                                            再升到当前工作树(存量用户唯一会走的那条路)。
#
# 之所以把话说这么死: 这个文件曾经在 CI 里挂着"发布链路回归"的名字, 看起来像是端到端
# 验过了。名字与它实际验的东西对不上, 比没有这个测试更糟。
# 守卫见 tests/test-ci-coverage.py: 上面两支真实 E2E 一旦从 workflow 里消失即报错 ——
# 否则只留静态守卫会让"发布链路有覆盖"这句话再次名不副实。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail(){ echo "[FAIL] $*" >&2; exit 1; }

grep -q 'pdg_checkout_latest_tag' "$ROOT/install.sh" \
  || fail "install.sh bootstrap must checkout the latest v* tag"
! grep -q 'git clone -q --depth 1 "$REPO_URL"' "$ROOT/install.sh" \
  || fail "install.sh must not seed /opt/privdns-gateway as a shallow main clone"
grep -q 'git -C "$dir" checkout -q "$tag"' "$ROOT/install.sh" \
  || fail "install.sh must checkout the selected release tag before re-exec"

grep -q 'pdg_fetch_release_tags' "$ROOT/deploy/bot/pdg.sh" \
  || fail "pdg update must share a release-tag fetch helper"
grep -q 'fetch -q --unshallow --tags origin main' "$ROOT/deploy/bot/pdg.sh" \
  || fail "pdg update must unshallow old installs before comparing tags"

grep -q '_fetch_release_tags' "$ROOT/deploy/bot/pdg-bot.py" \
  || fail "bot update check must fetch release tags through a helper"
grep -q 'mb.returncode == 0' "$ROOT/deploy/bot/pdg-bot.py" \
  || fail "bot update check must distinguish merge-base success"
grep -q 'mb.returncode == 1' "$ROOT/deploy/bot/pdg-bot.py" \
  || fail "bot update check must distinguish not-ancestor from git errors"
grep -q 'merge-base 判断失败' "$ROOT/deploy/bot/pdg-bot.py" \
  || fail "bot update check must report merge-base git errors instead of treating them as up-to-date"

! grep -q '1\.12\.9' "$ROOT/docs/INSTALL.md" \
  || fail "INSTALL.md must not mention stale sing-box 1.12.9"
