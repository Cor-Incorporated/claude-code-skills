#!/bin/bash
# test-issue-187.sh — Verify non-CI check runs are excluded from merge gate (#187)
# =========================================================================
# Tests that jq_ci_failures_filter and jq_ci_pending_filter correctly
# exclude non-CI check runs (Agent, copilot, dependabot, CodeRabbit)
# while still counting actual CI check runs.
# =========================================================================
set -uo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Source common.sh to get the filter functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/hooks/gate-modes/common.sh"

echo "=== Issue #187: Non-CI check run exclusion filter tests ==="
echo ""

# =========================================================================
# Test 1: jq_ci_pending_filter excludes "Agent" check run
# =========================================================================
echo "--- Test 1: Agent check run (in_progress) is excluded from pending count ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "Agent", "status": "in_progress", "conclusion": null},
    {"name": "hook-tests", "status": "completed", "conclusion": "success"},
    {"name": "shellcheck", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_pending_filter)")
if [[ "$RESULT" -eq 0 ]]; then
  pass "Agent in_progress excluded, pending=0"
else
  fail "Expected pending=0, got $RESULT"
fi

# =========================================================================
# Test 2: Actual CI pending job is still counted
# =========================================================================
echo "--- Test 2: Actual CI pending job is counted ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "Agent", "status": "in_progress", "conclusion": null},
    {"name": "hook-tests", "status": "in_progress", "conclusion": null},
    {"name": "shellcheck", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_pending_filter)")
if [[ "$RESULT" -eq 1 ]]; then
  pass "hook-tests in_progress counted, pending=1"
else
  fail "Expected pending=1, got $RESULT"
fi

# =========================================================================
# Test 3: Multiple non-CI check runs excluded simultaneously
# =========================================================================
echo "--- Test 3: Multiple non-CI check runs excluded ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "Agent", "status": "in_progress", "conclusion": null},
    {"name": "copilot", "status": "in_progress", "conclusion": null},
    {"name": "dependabot", "status": "in_progress", "conclusion": null},
    {"name": "CodeRabbit", "status": "in_progress", "conclusion": null},
    {"name": "hook-tests", "status": "completed", "conclusion": "success"},
    {"name": "shellcheck", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_pending_filter)")
if [[ "$RESULT" -eq 0 ]]; then
  pass "All 4 non-CI runs excluded, pending=0"
else
  fail "Expected pending=0, got $RESULT"
fi

# =========================================================================
# Test 4: Case-insensitive matching
# =========================================================================
echo "--- Test 4: Case-insensitive matching ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "agent", "status": "in_progress", "conclusion": null},
    {"name": "COPILOT", "status": "in_progress", "conclusion": null},
    {"name": "Dependabot", "status": "in_progress", "conclusion": null},
    {"name": "coderabbit", "status": "in_progress", "conclusion": null},
    {"name": "quality-gate", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_pending_filter)")
if [[ "$RESULT" -eq 0 ]]; then
  pass "Case-insensitive exclusion works, pending=0"
else
  fail "Expected pending=0, got $RESULT"
fi

# =========================================================================
# Test 5: jq_ci_failures_filter excludes non-CI failed runs
# =========================================================================
echo "--- Test 5: Non-CI failure check runs excluded from failure count ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "Agent", "status": "completed", "conclusion": "failure"},
    {"name": "hook-tests", "status": "completed", "conclusion": "success"},
    {"name": "shellcheck", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_failures_filter)")
if [[ "$RESULT" -eq 0 ]]; then
  pass "Agent failure excluded, failures=0"
else
  fail "Expected failures=0, got $RESULT"
fi

# =========================================================================
# Test 6: Actual CI failure is still counted
# =========================================================================
echo "--- Test 6: Actual CI failure is counted ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "Agent", "status": "completed", "conclusion": "failure"},
    {"name": "hook-tests", "status": "completed", "conclusion": "failure"},
    {"name": "shellcheck", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_failures_filter)")
if [[ "$RESULT" -eq 1 ]]; then
  pass "hook-tests failure counted, failures=1"
else
  fail "Expected failures=1, got $RESULT"
fi

# =========================================================================
# Test 7: All CI jobs completed successfully — no false positives
# =========================================================================
echo "--- Test 7: All CI green, no non-CI runs — clean pass ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "hook-tests", "status": "completed", "conclusion": "success"},
    {"name": "shellcheck", "status": "completed", "conclusion": "success"},
    {"name": "json-validate", "status": "completed", "conclusion": "success"},
    {"name": "syntax-check", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT_F=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_failures_filter)")
RESULT_P=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_pending_filter)")
if [[ "$RESULT_F" -eq 0 ]] && [[ "$RESULT_P" -eq 0 ]]; then
  pass "All green: failures=0, pending=0"
else
  fail "Expected failures=0 pending=0, got failures=$RESULT_F pending=$RESULT_P"
fi

# =========================================================================
# Test 8: Prefix match — names starting with excluded pattern
# =========================================================================
echo "--- Test 8: Prefix match — names starting with excluded pattern ---"
MOCK_RESPONSE='{
  "check_runs": [
    {"name": "Agent - session abc123", "status": "in_progress", "conclusion": null},
    {"name": "copilot-review", "status": "in_progress", "conclusion": null},
    {"name": "hook-tests", "status": "completed", "conclusion": "success"}
  ]
}'
RESULT=$(echo "$MOCK_RESPONSE" | jq "$(jq_ci_pending_filter)")
if [[ "$RESULT" -eq 0 ]]; then
  pass "Prefix-extended names excluded, pending=0"
else
  fail "Expected pending=0, got $RESULT"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
