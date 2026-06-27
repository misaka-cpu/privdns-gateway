#!/usr/bin/env bash
# Regression checks for the tag-only release/update path.
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
