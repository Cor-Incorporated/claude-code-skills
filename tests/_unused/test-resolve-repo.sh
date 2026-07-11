#!/bin/bash
# Test suite for resolve_repo() in hooks/gate-modes/common.sh
# Covers priority order: --repo flag > CLAUDE_FORK_REPO > upstream > origin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_ORIGIN="$(git -C "$SCRIPT_DIR" remote get-url origin | sed 's|.*github.com[:/]||;s|\.git$||')"
PASS=0
FAIL=0

test_case() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== resolve_repo() tests ==="

# --- Priority 1: --repo flag ---
echo "--- Priority 1: --repo flag parsing ---"
result=$(CLAUDE_FORK_REPO="org/repo" bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr merge 1 --repo other/repo'")
test_case "--repo flag takes precedence over env var" "other/repo" "$result"

# --- Priority 2: CLAUDE_FORK_REPO env var ---
echo "--- Priority 2: CLAUDE_FORK_REPO env var ---"
result=$(CLAUDE_FORK_REPO="test/fork-repo" bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo ''")
test_case "env var override" "test/fork-repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr merge 10 --repo user/fork-repo --merge'")
test_case "--repo with space" "user/fork-repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr merge 10 --repo=user/equal-repo --merge'")
test_case "--repo= with equals" "user/equal-repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr merge 10 -R user/short-flag --merge'")
test_case "-R short flag" "user/short-flag" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh -R user/global-short pr merge 10 --merge'")
test_case "global -R before pr" "user/global-short" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh --repo user/global-long pr merge 10 --merge'")
test_case "global --repo before pr" "user/global-long" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo \"bash -c 'gh pr merge 10 --repo nested/repo --merge'\"")
test_case "nested bash -c merge repo flag" "nested/repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo \"env -S 'gh pr merge 10 --repo split/repo --merge'\"")
test_case "env split-string merge repo flag" "split/repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr merge 10 --repo first/repo --repo second/repo'")
test_case "multiple --repo uses first match" "first/repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr view 99 --repo wrong/repo && gh pr merge 10 --repo right/repo --merge'")
test_case "merge repo ignores earlier non-merge repo flag" "right/repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr create --repo wrong/repo --title x --body y && gh pr merge 10 --repo right/repo --merge'")
test_case "merge repo ignores earlier create repo flag" "right/repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr create --repo wrong/repo --title x --body y && gh pr merge 10 --merge'")
test_case "merge without repo ignores earlier create repo flag" "$EXPECTED_ORIGIN" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr merge 10 --merge -R right/repo 2>&1 && gh pr view 99 --repo wrong/repo'")
test_case "merge repo ignores later non-merge repo flag with fd redirect" "right/repo" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr view 99 --repo wrong/repo && gh pr merge 10 --merge'")
test_case "merge without repo ignores earlier non-merge repo flag" "$EXPECTED_ORIGIN" "$result"

# --- Priority 4: origin fallback ---
echo "--- Priority 4: origin fallback ---"
result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo ''")
test_case "fallback to origin" "$EXPECTED_ORIGIN" "$result"

result=$(bash -c "source '$SCRIPT_DIR/hooks/gate-modes/common.sh' && resolve_repo 'gh pr merge 10 --merge'")
test_case "no --repo flag falls back to origin" "$EXPECTED_ORIGIN" "$result"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
