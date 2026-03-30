#!/usr/bin/env bash
# test-issue-207.sh — record-codex-review.sh auto-bridge (#207)
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/record-codex-review.sh"
echo "=== Issue #207: record-codex-review.sh auto-bridge tests ==="

# T1: Syntax check
if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check (bash -n)"
else
  fail "T1: syntax check failed"
fi

# T2: settings.json registration check
SETTINGS="$(cd "$(dirname "$0")/.." && pwd)/settings.json"
if grep -q 'record-codex-review.sh' "$SETTINGS"; then
  pass "T2: registered in settings.json (PostToolUse Bash)"
else
  fail "T2: NOT registered in settings.json"
fi

# T3: Hook mode — non-codex command → exit 0 (no-op)
ec=0
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash "$HOOK" 2>/dev/null || ec=$?
if [[ "$ec" -eq 0 ]]; then
  pass "T3: non-codex command exits 0"
else
  fail "T3: non-codex command expected exit 0, got $ec"
fi

# T4: Hook mode — codex exec review → records state
TMPSTATE=$(mktemp -d)
ec=0
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"codex exec review --base develop"}}' | HOME="$TMPSTATE" bash "$HOOK" 2>&1) || ec=$?
if [[ "$ec" -eq 0 ]]; then
  pass "T4: codex exec review exits 0"
else
  fail "T4: codex exec review expected exit 0, got $ec"
fi
rm -rf "$TMPSTATE"

# T5: Manual mode — with branch argument
TMPSTATE=$(mktemp -d)
TMPSTATE_FILE="$TMPSTATE/.claude/state"
mkdir -p "$TMPSTATE_FILE"
echo '{}' > "$TMPSTATE_FILE/review-status.json"
ec=0
HOME="$TMPSTATE" bash "$HOOK" "test-branch" "$(pwd)" 2>/dev/null || ec=$?
if [[ "$ec" -eq 0 ]]; then
  pass "T5: manual mode with branch exits 0"
else
  fail "T5: manual mode expected exit 0, got $ec"
fi

# T6: Verify state file written in manual mode
if [[ -f "$TMPSTATE_FILE/review-status.json" ]]; then
  if python3 -c "import json; d=json.load(open('$TMPSTATE_FILE/review-status.json')); assert d.get('test-branch',{}).get('codex_review_ran') == True" 2>/dev/null; then
    pass "T6: state file has codex_review_ran=true"
  else
    fail "T6: state file missing codex_review_ran"
  fi
else
  fail "T6: state file not created"
fi
rm -rf "$TMPSTATE"

# T7: Dual-mode detection — has both hook and manual paths
if grep -q 'if \[\[ \$# -eq 0 \]\]' "$HOOK"; then
  pass "T7: dual-mode detection present"
else
  fail "T7: dual-mode detection missing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
