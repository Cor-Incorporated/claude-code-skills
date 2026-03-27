#!/bin/bash
# test-issue-189.sh — Verify enforce-codex-for-impl.sh warns on implementation delegation (#189)
# =========================================================================
# Tests that the hook correctly:
#   - Warns when general-purpose subagent receives implementation prompts
#   - Passes silently for specialized subagent types
#   - Passes silently for investigation-only prompts
#   - Always exits 0 (warning only, never blocks)
# =========================================================================
set -uo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${SCRIPT_DIR}/hooks/enforce-codex-for-impl.sh"

# Helper: run hook with mock JSON on stdin, capture stderr
run_hook_stderr() {
  local mock_json="$1"
  echo "$mock_json" | bash "$HOOK" 2>&1 >/dev/null
}

# Helper: run hook and return exit code
run_hook_exit() {
  local mock_json="$1"
  echo "$mock_json" | bash "$HOOK" 2>/dev/null >/dev/null
  echo $?
}

echo "=== Issue #189: Codex CLI delegation enforcement tests ==="
echo ""

# =========================================================================
# Test 1: general-purpose + Japanese implementation keyword → WARNING
# =========================================================================
echo "--- Test 1: general-purpose + '実装' → WARNING ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"このモジュールを実装してください"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  pass "general-purpose + 実装 → WARNING detected"
else
  fail "Expected WARNING, got: $OUTPUT"
fi

# =========================================================================
# Test 2: general-purpose + investigation only → no WARNING
# =========================================================================
echo "--- Test 2: general-purpose + '調査' only → no WARNING ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"このバグの原因を調査してください"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  fail "Should not warn for investigation-only, got WARNING"
else
  pass "Investigation-only prompt passes silently"
fi

# =========================================================================
# Test 3: code-reviewer subagent → always PASS
# =========================================================================
echo "--- Test 3: code-reviewer subagent → PASS regardless of prompt ---"
MOCK='{"tool_input":{"subagent_type":"code-reviewer","prompt":"このコードを実装してレビューして"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  fail "code-reviewer should always pass, got WARNING"
else
  pass "code-reviewer passes silently"
fi

# =========================================================================
# Test 4: Explore subagent → always PASS
# =========================================================================
echo "--- Test 4: Explore subagent → PASS regardless of prompt ---"
MOCK='{"tool_input":{"subagent_type":"Explore","prompt":"ファイルを検索して変更してください"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  fail "Explore should always pass, got WARNING"
else
  pass "Explore passes silently"
fi

# =========================================================================
# Test 5: general-purpose + English implementation keyword → WARNING
# =========================================================================
echo "--- Test 5: general-purpose + 'implement' → WARNING ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"Implement the authentication middleware"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  pass "general-purpose + implement → WARNING detected"
else
  fail "Expected WARNING for implement keyword"
fi

# =========================================================================
# Test 6: general-purpose + 'Edit' keyword → WARNING
# =========================================================================
echo "--- Test 6: general-purpose + 'Edit' → WARNING ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"Edit the config file and add the new setting"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  pass "general-purpose + Edit → WARNING detected"
else
  fail "Expected WARNING for Edit keyword"
fi

# =========================================================================
# Test 7: general-purpose + 'Write' keyword → WARNING
# =========================================================================
echo "--- Test 7: general-purpose + 'Write' → WARNING ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"Write the new service module"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  pass "general-purpose + Write → WARNING detected"
else
  fail "Expected WARNING for Write keyword"
fi

# =========================================================================
# Test 8: general-purpose + no keywords → no WARNING
# =========================================================================
echo "--- Test 8: general-purpose + neutral prompt → no WARNING ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"このプロジェクトの概要を説明してください"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  fail "Neutral prompt should not trigger warning"
else
  pass "Neutral prompt passes silently"
fi

# =========================================================================
# Test 9: Default subagent (no subagent_type) → treated as general-purpose
# =========================================================================
echo "--- Test 9: No subagent_type + implementation keyword → WARNING ---"
MOCK='{"tool_input":{"prompt":"新しいAPIエンドポイントを作成して"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  pass "Missing subagent_type defaults to general-purpose, WARNING detected"
else
  fail "Expected WARNING when subagent_type is missing"
fi

# =========================================================================
# Test 10: Mixed keywords (investigation + implementation) → WARNING
# =========================================================================
echo "--- Test 10: Mixed '調査' + '実装' → WARNING (implementation takes priority) ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"バグを調査して修正を実装してください"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  pass "Mixed keywords → WARNING (implementation takes priority)"
else
  fail "Expected WARNING for mixed investigation+implementation"
fi

# =========================================================================
# Test 11: Exit code is always 0 (never blocks)
# =========================================================================
echo "--- Test 11: Exit code is 0 even when WARNING is emitted ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"このモジュールを実装してください"}}'
EXIT_CODE=$(run_hook_exit "$MOCK")
if [[ "$EXIT_CODE" -eq 0 ]]; then
  pass "Exit code is 0 (warning only, no block)"
else
  fail "Expected exit 0, got exit $EXIT_CODE"
fi

# =========================================================================
# Test 12: Plan subagent → always PASS
# =========================================================================
echo "--- Test 12: Plan subagent → PASS regardless of prompt ---"
MOCK='{"tool_input":{"subagent_type":"Plan","prompt":"実装計画を作成してください"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  fail "Plan should always pass, got WARNING"
else
  pass "Plan passes silently"
fi

# =========================================================================
# Test 13: feature-dev:* subagent → always PASS
# =========================================================================
echo "--- Test 13: feature-dev:code-explorer → PASS ---"
MOCK='{"tool_input":{"subagent_type":"feature-dev:code-explorer","prompt":"コードを変更して実装して"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  fail "feature-dev:* should always pass, got WARNING"
else
  pass "feature-dev:code-explorer passes silently"
fi

# =========================================================================
# Test 14: WHY/FIX format in warning message
# =========================================================================
echo "--- Test 14: Warning contains WHY and FIX guidance ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"認証ミドルウェアを実装して"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
HAS_WHY=$(echo "$OUTPUT" | grep -c "WHY:" || true)
HAS_FIX=$(echo "$OUTPUT" | grep -c "FIX:" || true)
if [[ "$HAS_WHY" -ge 1 ]] && [[ "$HAS_FIX" -ge 1 ]]; then
  pass "Warning contains WHY + FIX guidance"
else
  fail "Expected WHY/FIX format, WHY=$HAS_WHY FIX=$HAS_FIX"
fi

# =========================================================================
# Test 15: '検索' (search) only → no WARNING
# =========================================================================
echo "--- Test 15: general-purpose + '検索' only → no WARNING ---"
MOCK='{"tool_input":{"subagent_type":"general-purpose","prompt":"関連ファイルを検索してください"}}'
OUTPUT=$(run_hook_stderr "$MOCK")
if echo "$OUTPUT" | grep -q "WARNING"; then
  fail "Search-only prompt should not trigger warning"
else
  pass "Search-only prompt passes silently"
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
