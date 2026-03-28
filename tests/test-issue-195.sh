#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/protect-branches.sh"
PASS=0; FAIL=0

test_case() {
  local name="$1" expected_exit="$2" cmd="$3"
  actual_exit=0
  echo "{\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS: $name (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected=$expected_exit actual=$actual_exit)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== protect-branches.sh tests ==="
echo "--- Force push bypass fixes (#195) ---"
test_case "--all force push blocked" 2 "git push --force --all origin"
test_case "--mirror force push blocked" 2 "git push --force --mirror origin"
test_case "implicit force push on feature" 0 "git push --force"

echo "--- Existing force push guards (#192) ---"
test_case "explicit force push to develop" 2 "git push --force origin develop"
test_case "force-with-lease to develop" 2 "git push --force-with-lease origin develop"
test_case "force-with-lease=HEAD to develop" 2 "git push --force-with-lease=HEAD origin develop"
test_case "refspec HEAD:develop" 2 "git push --force-with-lease origin HEAD:develop"
test_case "force push to feature (allow)" 0 "git push --force origin feat/test"

echo "--- Branch protection (regression) ---"
test_case "normal push (allow)" 0 "git push origin feat/test"
test_case "remote delete develop" 2 "git push origin --delete develop"
test_case "colon delete develop" 2 "git push origin :develop"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
