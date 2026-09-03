#!/bin/bash
# =============================================================================
# Regression test: multi-repository `git -C` context resolution (Issue #263)
# =============================================================================
# Pre-existing gap: git-push-guard.sh resolved its git context dir with a single
# `re.search` for the FIRST `git -C <dir>` anywhere in the command, without
# pairing it to the invocation that actually pushes. In a chained command naming
# two repos, the implicit-branch force-push check (Issue #28) therefore read the
# wrong repo's HEAD:
#
#   git -C <feature-repo> status && git -C <protected-repo> push --force
#       -> ctx = feature repo -> NOT protected -> force push ALLOWED (exit 0)
#
# Both directions were wrong: the above is a fail-open BYPASS, and the mirror
# case (protected repo named first, feature repo pushed) was a FALSE BLOCK.
#
# Falsifiability: run this against the UNFIXED hook and the BYPASS / FALSE BLOCK
# cases must FAIL — proving the test detects the bug:
#   git show origin/develop:hooks/git-push-guard.sh > /tmp/unfixed/git-push-guard.sh
#   HOOK_DIR=/tmp/unfixed bash tests/test-issue-263-multi-repo-ctx.sh
#
# The hook is fed JSON on stdin via jq; no git push is ever executed, so the
# runner's own PreToolUse guards are never triggered. The fixture repos are
# real (the check runs `git rev-parse --abbrev-ref HEAD` against them) and are
# created under mktemp, then removed on exit.
#
# Usage:
#   bash tests/test-issue-263-multi-repo-ctx.sh              # source hooks
#   HOOK_DIR=~/.claude/hooks bash tests/test-issue-263-...   # deployed hooks
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR="${HOOK_DIR:-$SCRIPT_DIR/../hooks}"
PUSH_GUARD="$HOOK_DIR/git-push-guard.sh"
PASS=0
FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# FEAT: on a feature branch (not protected).  PROT: on develop (protected).
FEAT="$TMP/feature-repo"
PROT="$TMP/protected-repo"
mkdir -p "$FEAT" "$PROT"
git -C "$FEAT" init -q
git -C "$FEAT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$FEAT" checkout -q -b feat/harmless
git -C "$PROT" init -q
git -C "$PROT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$PROT" checkout -q -b develop

# test_case <name> <expected_exit> <command>
test_case() {
  local name="$1" expected_exit="$2" cmd="$3"
  local json actual_exit=0
  json=$(jq -n --arg cmd "$cmd" '{tool_input:{command:$cmd}}')
  printf '%s' "$json" | bash "$PUSH_GUARD" >/dev/null 2>&1 || actual_exit=$?
  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS: $name (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected=$expected_exit actual=$actual_exit)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== HOOK_DIR: $HOOK_DIR ==="
echo "  feature repo on: $(git -C "$FEAT" rev-parse --abbrev-ref HEAD)"
echo "  protected repo on: $(git -C "$PROT" rev-parse --abbrev-ref HEAD)"
echo ""

echo "--- Controls: single repo, implicit branch (must hold pre- and post-fix) ---"
test_case "single protected repo, implicit force"   2 "git -C $PROT push --force"
test_case "single feature repo, implicit force"     0 "git -C $FEAT push --force"

echo "--- BYPASS: pushing invocation's repo is protected, named second ---"
test_case "feature -C first, protected pushes"      2 "git -C $FEAT status && git -C $PROT push --force"
test_case "feature -C first, force-with-lease"      2 "git -C $FEAT log -1 && git -C $PROT push --force-with-lease"
test_case "second push hidden behind benign push"   2 "git -C $FEAT push --force && git -C $PROT push --force"
test_case "protected push after semicolon chain"    2 "git -C $FEAT status ; git -C $PROT push -f"

echo "--- FALSE BLOCK: pushing invocation's repo is a feature branch ---"
test_case "protected -C first, feature pushes"      0 "git -C $PROT status && git -C $FEAT push --force"
test_case "protected -C first, feature -f"          0 "git -C $PROT log -1 && git -C $FEAT push -f"

echo "--- cd fallback must survive (no -C on the pushing invocation) ---"
test_case "cd protected && implicit force"          2 "cd $PROT && git push --force"
test_case "cd feature && implicit force"            0 "cd $FEAT && git push --force"
test_case "cd feature, -C protected pushes"         2 "cd $FEAT && git -C $PROT push --force"
test_case "cd protected, -C feature pushes"         0 "cd $PROT && git -C $FEAT push --force"

echo "--- A quoted 'git -C' must not shadow the real context ---"
test_case "quoted bogus -C, cd protected"           2 "cd $PROT && gh issue create --title \"git -C /nonexistent push\" && git push --force"

echo "--- Explicit refspecs are unaffected by ctx resolution ---"
test_case "explicit protected ref, feature ctx"     2 "git -C $FEAT status && git push --force origin develop"
test_case "explicit feature ref, protected ctx"     0 "git -C $PROT status && git push --force origin feat/x"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
