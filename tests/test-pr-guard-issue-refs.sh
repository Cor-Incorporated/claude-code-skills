#!/usr/bin/env bash
# test-pr-guard-issue-refs.sh — Issue references accepted by pr-guard.sh
set -euo pipefail

PASS=0
FAIL=0
TOTAL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/pr-guard.sh"
TMP_DIR=""
LAST_OUTPUT=""
LAST_RC=0

cleanup() {
  [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "${GREEN}  PASS${NC} $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "${RED}  FAIL${NC} $1"
}

run_guard() {
  local cmd="$1"
  LAST_OUTPUT=""
  LAST_RC=0
  set +e
  LAST_OUTPUT=$(jq -nc --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}' | bash "$HOOK" 2>&1)
  LAST_RC=$?
  set -e
}

expect_allow() {
  local label="$1"
  local cmd="$2"
  run_guard "$cmd"
  if [[ "$LAST_RC" -eq 0 ]]; then
    pass "$label"
  else
    fail "$label (exit $LAST_RC: $LAST_OUTPUT)"
  fi
}

expect_block() {
  local label="$1"
  local cmd="$2"
  run_guard "$cmd"
  if [[ "$LAST_RC" -eq 2 ]]; then
    pass "$label"
  else
    fail "$label (exit $LAST_RC: $LAST_OUTPUT)"
  fi
}

TMP_DIR=$(mktemp -d)
BODY_FILE="$TMP_DIR/pr-body.md"
cat > "$BODY_FILE" <<'EOF'
## Summary
https://github.com/Cor-Incorporated/Grift/issues/1261

codex review done
EOF

echo "=== pr-guard Issue reference tests ==="

expect_allow \
  "T1: closing keyword reference is accepted" \
  $'gh pr create --base develop --title "fix: close issue" --body "## Summary\nCloses #220\n\ncodex review done"'

expect_allow \
  "T2: Refs reference is accepted without auto-close semantics" \
  $'gh pr create --base develop --title "docs: refs issue" --body "## Summary\nRefs #220\n\ncodex review done"'

expect_allow \
  "T3: Ref reference is accepted without auto-close semantics" \
  $'gh pr create --base develop --title "docs: ref issue" --body "## Summary\nRef #220\n\ncodex review done"'

expect_allow \
  "T4: References reference is accepted without auto-close semantics" \
  $'gh pr create --base develop --title "docs: references issue" --body "## Summary\nReferences #220\n\ncodex review done"'

expect_allow \
  "T5: GitHub Issue URL is accepted" \
  $'gh pr create --base develop --title "docs: url issue" --body "## Summary\nhttps://github.com/Cor-Incorporated/Grift/issues/1261\n\ncodex review done"'

expect_allow \
  "T6: --body-file content is scanned for Issue URLs" \
  "gh pr create --base develop --title 'docs: body file issue' --body-file '$BODY_FILE'"

expect_block \
  "T7: missing Issue reference is blocked" \
  $'gh pr create --base develop --title "docs: no issue" --body "## Summary\ncodex review done"'

expect_block \
  "T8: bare issue number remains blocked as ambiguous" \
  $'gh pr create --base develop --title "docs: bare issue" --body "## Summary\n#220\n\ncodex review done"'

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
