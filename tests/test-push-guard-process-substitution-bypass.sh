#!/bin/bash
# =============================================================================
# Regression test: process-substitution / chain / redirect force-push bypass
# =============================================================================
# Pre-existing parser gap: git-push-guard.sh and protect-branches.sh extracted
# the push remote/branch position-dependently, assuming `git push` is the first
# token. Wrapping the push in a process substitution `cat <(git push --force
# origin main)` (or a chain / redirect) shifted the tokens, so the protected
# branch was mis-extracted (e.g. `main)` instead of `main`) and the force push
# was ALLOWED (exit 0).
#
# Falsifiability: run this against the UNFIXED hooks and the BYPASS cases must
# FAIL (hook exits 0 where 2 is expected) — proving the test detects the bug.
# After the fix, every case must PASS.
#
# Trigger strings live ONLY inside this file and are fed to the hooks as JSON on
# stdin via jq; the test never executes any git command, so host PreToolUse
# guards on the runner's own Bash calls are never triggered.
#
# Usage:
#   bash tests/test-push-guard-process-substitution-bypass.sh            # source hooks
#   HOOK_DIR=~/.claude/hooks bash tests/test-...-bypass.sh               # deployed hooks
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR="${HOOK_DIR:-$SCRIPT_DIR/../hooks}"
PUSH_GUARD="$HOOK_DIR/git-push-guard.sh"
PROTECT="$HOOK_DIR/protect-branches.sh"
PASS=0
FAIL=0

# test_case <hook> <name> <expected_exit> <command>
test_case() {
  local hook="$1" name="$2" expected_exit="$3" cmd="$4"
  local json actual_exit=0
  json=$(jq -n --arg cmd "$cmd" '{tool_input:{command:$cmd}}')
  printf '%s' "$json" | bash "$hook" >/dev/null 2>&1 || actual_exit=$?
  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS: $name (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected=$expected_exit actual=$actual_exit)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== HOOK_DIR: $HOOK_DIR ==="
echo ""
echo "### git-push-guard.sh ###"

echo "--- BYPASS: force push hidden in process substitution / chain / redirect ---"
test_case "$PUSH_GUARD" "procsub force main"            2 'cat <(git push --force origin main)'
test_case "$PUSH_GUARD" "procsub force-with-lease dev"  2 'cat <(git push --force-with-lease origin develop)'
test_case "$PUSH_GUARD" "procsub force master"          2 'diff <(git push --force origin master) /dev/null'
test_case "$PUSH_GUARD" "chain && force main"           2 'echo ok && git push --force origin main'
test_case "$PUSH_GUARD" "chain ; force develop"         2 'true ; git push --force origin develop'
test_case "$PUSH_GUARD" "redirect > force main"         2 'git push --force origin main > /tmp/x'
test_case "$PUSH_GUARD" "procsub direct (non-force) main" 2 'cat <(git push origin main)'

echo "--- Baseline (already detected pre-fix) ---"
test_case "$PUSH_GUARD" "plain force main"              2 'git push --force origin main'
test_case "$PUSH_GUARD" "plain force-with-lease master" 2 'git push --force-with-lease origin master'

echo "--- Must stay ALLOWED (feature branches, no false positives) ---"
test_case "$PUSH_GUARD" "feature force-with-lease"      0 'git push --force-with-lease origin feat/test'
test_case "$PUSH_GUARD" "feature force"                 0 'git push --force origin feat/x'
test_case "$PUSH_GUARD" "normal feature push"           0 'git push origin feat/test'
test_case "$PUSH_GUARD" "feat/main-fix not 'main'"      0 'git push --force origin feat/main-fix'
test_case "$PUSH_GUARD" "mainline not 'main'"           0 'git push --force origin mainline'
test_case "$PUSH_GUARD" "develop-2 not 'develop'"       0 'git push --force origin develop-2'

echo ""
echo "### protect-branches.sh ###"

echo "--- BYPASS: force push hidden in process substitution / chain / redirect ---"
test_case "$PROTECT" "procsub force main"               2 'cat <(git push --force origin main)'
test_case "$PROTECT" "procsub force develop"            2 'cat <(git push --force origin develop)'
test_case "$PROTECT" "chain && force main"              2 'echo ok && git push --force origin main'
test_case "$PROTECT" "redirect > force master"          2 'git push --force origin master > /tmp/x'
test_case "$PROTECT" "procsub colon-delete main"        2 'cat <(git push origin :main)'

echo "--- Baseline (already detected pre-fix) ---"
test_case "$PROTECT" "plain force develop"              2 'git push --force origin develop'
test_case "$PROTECT" "force-with-lease HEAD:develop"    2 'git push --force-with-lease origin HEAD:develop'
test_case "$PROTECT" "remote delete develop"           2 'git push origin --delete develop'
test_case "$PROTECT" "colon delete develop"            2 'git push origin :develop'

echo "--- Must stay ALLOWED (feature branches, no false positives) ---"
test_case "$PROTECT" "feature force"                    0 'git push --force origin feat/test'
test_case "$PROTECT" "normal feature push"             0 'git push origin feat/test'
test_case "$PROTECT" "feat/main-fix not 'main'"        0 'git push --force origin feat/main-fix'
test_case "$PROTECT" "mainline not 'main'"             0 'git push --force origin mainline'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
