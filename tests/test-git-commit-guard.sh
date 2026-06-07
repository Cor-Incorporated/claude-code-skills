#!/bin/bash
# Regression tests for hooks/git-commit-guard.sh commit message parsing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_DIR/hooks/git-commit-guard.sh"

PASS=0
FAIL=0
TOTAL=0

TEST_DIR=$(mktemp -d /tmp/git-commit-guard.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

cd "$TEST_DIR"
git init >/dev/null
git config user.email "test@example.com"
git config user.name "Test User"
git remote add origin https://github.com/example/test-repo.git
touch README.md
git add README.md
git commit -m "initial commit" >/dev/null

make_input() {
  local command="$1"
  jq -nc --arg command "$command" '{"tool_input":{"command":$command}}'
}

expect_allow() {
  local desc="$1"
  local command="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  make_input "$command" | bash "$HOOK" >/dev/null 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (expected 0, got $rc)" >&2
  fi
}

expect_block() {
  local desc="$1"
  local command="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  make_input "$command" | bash "$HOOK" >/dev/null 2>/dev/null || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (expected 2, got $rc)" >&2
  fi
}

expect_allow "複数 -m の本文にあるIssue参照を許可" \
  'git commit -m "fix(estimate): 根拠不足時のready化を防止" -m "Refs: #687"'

expect_allow "multiline -m の本文にあるIssue参照を許可" \
  $'git commit -m "fix(estimate): 根拠不足時のready化を防止\n\nRefs: #687"'

expect_allow "--message= 形式のIssue参照を許可" \
  'git commit --message="fix(estimate): 根拠不足時のready化を防止" --message="Refs: #687"'

expect_block "本文にもIssue参照がないfix commitを拒否" \
  'git commit -m "fix(estimate): 根拠不足時のready化を防止" -m "no issue reference"'

expect_block "複数 -m の本文をsubject扱いしない" \
  'git commit -m "fix(estimate): 根拠不足時のready化を防止" -m "Refs issue-687"'

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED: $FAIL/$TOTAL tests" >&2
  exit 1
fi

echo "PASSED: $PASS/$TOTAL tests"
