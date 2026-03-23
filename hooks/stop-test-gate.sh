#!/bin/bash
# stop-test-gate.sh — Stop hook: run project tests before session end
# ====================================================================
# Detects the project's test framework and runs tests with a 60s timeout.
# On failure, returns JSON hookSpecificOutput with truncated test output.
# On success or no tests found, exits 0 silently.
# ====================================================================

set -uo pipefail
# Note: -e is intentionally omitted because timeout returns non-zero

# =========================================================================
# Issue #58: Skip gate during active error recovery
# If the working tree has unstaged changes, the developer is actively working.
# Blocking the session end during error recovery breaks autonomous fix loops.
# =========================================================================
if git diff --quiet HEAD 2>/dev/null; then
  : # Clean tree — proceed with test gate
else
  # Dirty tree — active work in progress, skip gate
  exit 0
fi

# =========================================================================
# Determine project root
# =========================================================================
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
elif git rev-parse --show-toplevel &>/dev/null; then
  PROJECT_DIR="$(git rev-parse --show-toplevel)"
else
  PROJECT_DIR="$PWD"
fi

# =========================================================================
# Test detection logic (priority order)
# =========================================================================
TEST_CMD=""

if [ -f "$PROJECT_DIR/package.json" ] && command -v jq >/dev/null 2>&1 && jq -e '.scripts.test' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
  TEST_CMD="npm test"
elif [ -f "$PROJECT_DIR/pytest.ini" ] || [ -f "$PROJECT_DIR/pyproject.toml" ]; then
  TEST_CMD="python -m pytest --tb=short -q"
elif [ -f "$PROJECT_DIR/go.mod" ]; then
  TEST_CMD="go test ./... -short"
elif [ -f "$PROJECT_DIR/Cargo.toml" ]; then
  TEST_CMD="cargo test"
elif [ -f "$PROJECT_DIR/test/cli.bats" ]; then
  TEST_CMD="bats test/"
else
  # No test framework detected — silent pass
  exit 0
fi

# =========================================================================
# Run tests with 60s timeout (macOS compatible)
# =========================================================================
# HIGH-1 fix: macOS has no GNU timeout. Fall back to gtimeout or perl.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi

# HIGH-2 fix: Capture exit code directly instead of PIPESTATUS
EXIT_CODE=0
if [[ -n "$TIMEOUT_CMD" ]]; then
  TEST_OUTPUT=$(cd "$PROJECT_DIR" && $TIMEOUT_CMD 60 $TEST_CMD 2>&1) || EXIT_CODE=$?
else
  # No timeout available — run with perl alarm as fallback
  TEST_OUTPUT=$(cd "$PROJECT_DIR" && perl -e 'alarm 60; exec @ARGV' $TEST_CMD 2>&1) || EXIT_CODE=$?
fi

# timeout(1) returns 124 on timeout
if [[ "$EXIT_CODE" -eq 124 ]]; then
  TRUNCATED=$(printf '%s' "$TEST_OUTPUT" | head -30)
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "message": "Tests timed out after 60s. Review test suite performance.",
    "testOutput": $(printf '%s' "$TRUNCATED" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')
  }
}
EOF
  exit 2
fi

if [[ "$EXIT_CODE" -ne 0 ]]; then
  TRUNCATED=$(printf '%s' "$TEST_OUTPUT" | head -30)
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "message": "Tests failed. Fix failing tests before ending session.",
    "testOutput": $(printf '%s' "$TRUNCATED" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')
  }
}
EOF
  exit 2
fi

# Tests passed — silent success
exit 0
