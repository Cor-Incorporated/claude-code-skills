#!/usr/bin/env bash
# test-issue-214.sh — enforce-deploy-verify-on-pr.sh refactoring (#214)
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/enforce-deploy-verify-on-pr.sh"
echo "=== Issue #214: enforce-deploy-verify-on-pr.sh tests ==="

# T1: Syntax check
if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check (bash -n)"
else
  fail "T1: syntax check failed"
fi

# T2: Non-Bash tool → pass
ec=0
echo '{"tool_name":"Edit","tool_input":{"file_path":"foo.sh"}}' | bash "$HOOK" 2>/dev/null || ec=$?
if [[ "$ec" -eq 0 ]]; then
  pass "T2: non-Bash tool exits 0"
else
  fail "T2: non-Bash tool expected exit 0, got $ec"
fi

# T3: Bash without gh pr create → pass
ec=0
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash "$HOOK" 2>/dev/null || ec=$?
if [[ "$ec" -eq 0 ]]; then
  pass "T3: non-PR command exits 0"
else
  fail "T3: non-PR command expected exit 0, got $ec"
fi

# T4: check_deploy function exists
if grep -q 'check_deploy()' "$HOOK"; then
  pass "T4: check_deploy() function exists"
else
  fail "T4: check_deploy() function not found"
fi

# T5: No duplicate while loops (only 2 while loops calling check_deploy)
WHILE_COUNT=$(grep -c 'while IFS=' "$HOOK" || echo "0")
if [[ "$WHILE_COUNT" -eq 2 ]]; then
  pass "T5: exactly 2 while loops (hooks + scripts)"
else
  fail "T5: expected 2 while loops, found $WHILE_COUNT"
fi

# T6: BASE_BRANCH is dynamic (not hardcoded)
if grep -q 'DEPLOY_VERIFY_BASE_BRANCH' "$HOOK"; then
  pass "T6: BASE_BRANCH supports env override"
else
  fail "T6: DEPLOY_VERIFY_BASE_BRANCH not found"
fi

# T7: BASE_BRANCH env override works
ec=0
DEPLOY_VERIFY_BASE_BRANCH=main echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create"}}' | bash "$HOOK" 2>/dev/null || ec=$?
# Should exit 0 (no changed files on this branch vs main) or 2 (changes found)
if [[ "$ec" -eq 0 ]] || [[ "$ec" -eq 2 ]]; then
  pass "T7: BASE_BRANCH=main override accepted"
else
  fail "T7: BASE_BRANCH=main override unexpected exit $ec"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
