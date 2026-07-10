#!/usr/bin/env bash
# test-issue-209.sh -- Test enforce-deploy-verify-on-pr.sh (#209)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOOK="$PROJECT_DIR/hooks/enforce-deploy-verify-on-pr.sh"
PASS=0
FAIL=0

pass() { echo -e "\033[0;32mPASS\033[0m: $1"; PASS=$(( PASS + 1 )); }
fail() { echo -e "\033[0;31mFAIL\033[0m: $1"; FAIL=$(( FAIL + 1 )); }

# T1: Non-Bash tool → pass
ec=0; echo '{"tool_name":"Edit","tool_input":{"file_path":"x"}}' | bash "$HOOK" 2>/dev/null || ec=$?
[[ $ec -eq 0 ]] && pass "T1: non-Bash passes" || fail "T1: exit $ec"

# T2: Bash without gh pr create → pass
ec=0; echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash "$HOOK" 2>/dev/null || ec=$?
[[ $ec -eq 0 ]] && pass "T2: non-PR bash passes" || fail "T2: exit $ec"

# T3: Syntax check
bash -n "$HOOK" && pass "T3: syntax OK" || fail "T3: syntax error"

# T4: gh pr create triggers (may block or pass depending on branch state, but must not crash)
ec=0; echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title test"}}' | bash "$HOOK" 2>/dev/null || ec=$?
[[ $ec -eq 0 || $ec -eq 2 ]] && pass "T4: gh pr create handled (exit $ec)" || fail "T4: unexpected exit $ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
