#!/bin/bash
# test-enforce-develop-base-release.sh — release PR exception for enforce-develop-base.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/hooks/enforce-develop-base.sh"

TMP_REPO=""
cleanup() {
  [[ -n "$TMP_REPO" ]] && rm -rf "$TMP_REPO"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

payload() {
  jq -n --arg cmd "$1" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

run_case() {
  local label="$1" branch="$2" expected="$3" command="$4"
  local actual=0

  git -C "$TMP_REPO" checkout "$branch" >/dev/null 2>&1 || {
    fail "$label (cannot checkout $branch)"
    return
  }

  payload "$command" | (cd "$TMP_REPO" && bash "$HOOK") >/dev/null 2>&1 || actual=$?

  if [[ "$actual" -eq "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected $expected, got $actual)"
  fi
}

echo "=== enforce-develop-base release PR tests ==="

TMP_REPO=$(mktemp -d)
git -C "$TMP_REPO" init -q -b main
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf "root\n" > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -qm "init"
git -C "$TMP_REPO" checkout -qb develop
git -C "$TMP_REPO" checkout -qb feat/test

run_case "feature branch -> main PR is blocked" "feat/test" 2 \
  'gh pr create --base main --title "feat: test" --body "Closes #1"'

run_case "feature branch -> develop PR is allowed" "feat/test" 0 \
  'gh pr create --base develop --title "feat: test" --body "Closes #1"'

run_case "develop branch -> main release PR is allowed" "develop" 0 \
  'gh pr create --base main --title "release: develop to main" --body "Closes #1"'

run_case "--head develop -> main release PR is allowed from another branch" "feat/test" 0 \
  'gh pr create --base main --head develop --title "release: develop to main" --body "Closes #1"'

run_case "branch creation from main is blocked when develop exists" "main" 2 \
  'git checkout -b feat/from-main'

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
