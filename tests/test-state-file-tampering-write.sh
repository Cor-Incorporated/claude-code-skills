#!/bin/bash
# test-state-file-tampering-write.sh — Write/Edit state tampering guard

set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/block-state-file-tampering.sh"
PASSED=0
FAILED=0
TOTAL=0

make_input() {
  local path="$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$path"
}

expect_allow() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  echo "$input" | bash "$HOOK" >/dev/null 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=0)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit 0, got exit $rc)" >&2
  fi
}

expect_block() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  echo "$input" | bash "$HOOK" >/dev/null 2>/dev/null || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=2)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit 2, got exit $rc)" >&2
  fi
}

echo "=== Write/Edit state file tampering guard ==="

expect_block "review-status.json" \
  "$(make_input "/repo/.claude/state/review-status.json")"

expect_block "pending-review-comments.json" \
  "$(make_input "/repo/.claude/state/pending-review-comments.json")"

expect_block "pr-review-lock.json" \
  "$(make_input "/repo/.claude/state/pr-review-lock.json")"

expect_block "pr-review-read.json" \
  "$(make_input "/repo/.claude/state/pr-review-read.json")"

expect_block "context-budget.json" \
  "$(make_input "/repo/.claude/state/context-budget.json")"

expect_block "factcheck-status.json" \
  "$(make_input "/repo/.claude/state/factcheck-status.json")"

expect_block "rebase-session.json" \
  "$(make_input "/repo/.claude/state/rebase-session.json")"

expect_block "pr-gate-diagnostic.log" \
  "$(make_input "/repo/.claude/state/pr-gate-diagnostic.log")"

expect_allow "unrelated json" \
  "$(make_input "/repo/tmp/pending-review-comments-backup.json")"

expect_allow "empty file path" \
  '{"tool_input":{"file_path":""}}'

expect_allow "missing file path" \
  '{"tool_input":{}}'

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo "FAIL: $FAILED test(s) failed" >&2
  exit 1
fi

echo "ALL TESTS PASSED"
exit 0
