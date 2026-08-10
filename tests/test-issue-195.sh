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

echo "--- --all/--mirror without --force (#195 P1) ---"
test_case "--mirror without --force blocked" 2 "git push --mirror origin"
test_case "--all without --force blocked" 2 "git push --all origin"

echo "--- --all/--mirror with --force (#195) ---"
test_case "--all force push blocked" 2 "git push --force --all origin"
test_case "--mirror force push blocked" 2 "git push --force --mirror origin"

echo "--- Implicit force push (branch-aware) ---"
current_branch=$(git branch --show-current 2>/dev/null || echo "")
is_protected=0
for b in develop main master; do
  [ "$current_branch" = "$b" ] && is_protected=1
done
if [ "$is_protected" -eq 1 ]; then
  test_case "implicit force push on protected branch" 2 "git push --force"
else
  test_case "implicit force push on feature branch" 0 "git push --force"
fi

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

echo "--- R6: heredoc/docs text must not trip --mirror (false-positive) ---"
python3 - <<'PY' > /tmp/r6-protect-payload.json
import json
cmd = "python3 - <<'PY'\nprint('git clone --mirror example')\nPY\ngit push -u origin docs/backup-completion"
print(json.dumps({"tool_input": {"command": cmd}}))
PY
actual_exit=0
bash "$HOOK" < /tmp/r6-protect-payload.json >/dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 0 ]; then
  echo "  PASS: heredoc mentions --mirror but push has no flag (exit 0)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: heredoc false-positive (expected=0 actual=$actual_exit)"
  FAIL=$((FAIL + 1))
fi
test_case "real --mirror flag still blocked" 2 "git push --mirror origin"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
