#!/bin/bash
# test-issue-220.sh — Regression test for Issue #220
# =========================================================================
# Tests auto-commit-worktree-changes.sh PostToolUse:Agent hook.
# Verifies that worktree agent changes are auto-committed after merge.
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SCRIPT="$REPO_DIR/hooks/auto-commit-worktree-changes.sh"
SETTINGS_FILE="$REPO_DIR/settings.json"
GITIGNORE_FILE="$REPO_DIR/.gitignore"
SETUP_FILE="$REPO_DIR/setup.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0

test_case() {
  local name="$1"
  echo -e "${YELLOW}[TEST]${NC} $name"
}

assert_equals() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc"
    echo "    needle: $needle"
    echo "    haystack: ${haystack:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

# =========================================================================
# Setup: Create temp git repo for testing
# =========================================================================
TEST_DIR=$(mktemp -d /tmp/test-issue-220.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

echo "Test directory: $TEST_DIR"

# Create a git repo
cd "$TEST_DIR"
git init
git config user.email "test@test.com"
git config user.name "Test"
echo "initial" > initial.txt
git add initial.txt
git commit -m "initial commit"

# =========================================================================
# Test 1: Hook skips non-worktree agents
# =========================================================================
test_case "Non-worktree agent is skipped"
MOCK_INPUT='{"tool_input":{"isolation":"","subagent_type":"senior-frontend"}}'
OUTPUT=$(echo "$MOCK_INPUT" | bash "$HOOK_SCRIPT" 2>&1 || true)
COMMIT_COUNT=$(git log --oneline | wc -l | tr -d ' ')
assert_equals "No new commit created" "1" "$COMMIT_COUNT"

# =========================================================================
# Test 2: Hook skips research agents even with worktree isolation
# =========================================================================
test_case "Research agent with worktree is skipped"
MOCK_INPUT='{"tool_input":{"isolation":"worktree","subagent_type":"Explore"}}'
OUTPUT=$(echo "$MOCK_INPUT" | bash "$HOOK_SCRIPT" 2>&1 || true)
COMMIT_COUNT=$(git log --oneline | wc -l | tr -d ' ')
assert_equals "No new commit for research agent" "1" "$COMMIT_COUNT"

# =========================================================================
# Test 3: Hook skips when no uncommitted changes
# =========================================================================
test_case "Clean working tree is skipped"
MOCK_INPUT='{"tool_input":{"isolation":"worktree","subagent_type":"senior-frontend"}}'
OUTPUT=$(echo "$MOCK_INPUT" | bash "$HOOK_SCRIPT" 2>&1 || true)
COMMIT_COUNT=$(git log --oneline | wc -l | tr -d ' ')
assert_equals "No new commit on clean tree" "1" "$COMMIT_COUNT"

# =========================================================================
# Test 4: Hook auto-commits uncommitted changes for worktree agent
# =========================================================================
test_case "Uncommitted changes are auto-committed for worktree agent"
echo "worker change" > worker-file.txt
MOCK_INPUT='{"tool_input":{"isolation":"worktree","subagent_type":"senior-frontend","description":"test-task-220","task_id":"abc123"}}'
OUTPUT=$(echo "$MOCK_INPUT" | bash "$HOOK_SCRIPT" 2>&1 || true)
COMMIT_COUNT=$(git log --oneline | wc -l | tr -d ' ')
assert_equals "New commit was created" "2" "$COMMIT_COUNT"
LAST_MSG=$(git log -1 --format='%s')
assert_contains "Commit message contains task id" "$LAST_MSG" "abc123"
assert_contains "Commit message has chore(team) prefix" "$LAST_MSG" "chore(team)"

# =========================================================================
# Test 5: Hook commits staged changes for worktree agent
# =========================================================================
test_case "Staged changes are auto-committed for worktree agent"
echo "another change" > worker-file2.txt
git add worker-file2.txt
MOCK_INPUT='{"tool_input":{"isolation":"worktree","subagent_type":"senior-backend","description":"backend-task"}}'
OUTPUT=$(echo "$MOCK_INPUT" | bash "$HOOK_SCRIPT" 2>&1 || true)
COMMIT_COUNT=$(git log --oneline | wc -l | tr -d ' ')
assert_equals "New commit was created for staged changes" "3" "$COMMIT_COUNT"
LAST_MSG=$(git log -1 --format='%s')
assert_contains "Commit message uses description when no task_id" "$LAST_MSG" "backend-task"

# =========================================================================
# Test 6: Hook always exits 0 (never blocks)
# =========================================================================
test_case "Hook exits 0 even with empty input"
bash "$HOOK_SCRIPT" </dev/null 2>/dev/null
EXIT_CODE=$?
assert_equals "Exit code is 0" "0" "$EXIT_CODE"

test_case "Hook exits 0 with invalid JSON"
echo "not json" | bash "$HOOK_SCRIPT" 2>/dev/null
EXIT_CODE=$?
assert_equals "Exit code is 0 with bad input" "0" "$EXIT_CODE"

# =========================================================================
# Test 7: Script syntax is valid
# =========================================================================
test_case "Script has no syntax errors"
if bash -n "$HOOK_SCRIPT" 2>/dev/null; then
  echo -e "  ${GREEN}✓${NC} bash -n passes"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✗${NC} bash -n fails"
  FAIL=$((FAIL + 1))
fi

# =========================================================================
# Test 8: settings.json registers the PostToolUse Agent hook
# =========================================================================
test_case "settings.json registers auto-commit hook for Agent"
SETTINGS_SNIPPET=$(sed -n '/"matcher": "Agent"/,/\]/p' "$SETTINGS_FILE")
assert_contains "Agent matcher includes auto-commit hook" "$SETTINGS_SNIPPET" "auto-commit-worktree-changes.sh"

# =========================================================================
# Test 9: .gitignore excludes OpenCode generated files
# =========================================================================
test_case ".gitignore excludes .opencode/"
assert_contains ".gitignore contains .opencode/" "$(cat "$GITIGNORE_FILE")" ".opencode/"

# =========================================================================
# Test 10: setup.sh deploys settings.json so hook registration goes live
# =========================================================================
test_case "setup.sh deploys settings.json"
assert_contains "setup.sh copies repo settings.json into ~/.claude" "$(cat "$SETUP_FILE")" 'cp "$REPO_DIR/settings.json" "$CLAUDE_DIR/settings.json"'

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
