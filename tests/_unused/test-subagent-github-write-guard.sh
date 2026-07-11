#!/usr/bin/env bash
# test-subagent-github-write-guard.sh — block ask-gated GitHub writes in subagents
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/block-subagent-github-write.sh"
SETTINGS="$ROOT/settings.json"

echo "=== Subagent GitHub write guard tests ==="

if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check"
else
  fail "T1: syntax check failed"
fi

payload='{"tool_name":"Bash","tool_input":{"command":"gh pr create --base develop"}}'
if out=$(echo "$payload" | CLAUDE_AGENT_DEPTH=1 bash "$HOOK" 2>&1); then
  fail "T2: subagent gh pr create should be blocked"
else
  if [[ "$out" == *"Git/GitHub 書き込み"* ]]; then
    pass "T2: subagent gh pr create blocked"
  else
    fail "T2: block message missing"
  fi
fi

payload='{"tool_name":"Bash","tool_input":{"command":"git push -u origin feat/test"}}'
if out=$(echo "$payload" | CLAUDE_AGENT_ID=subagent-123 bash "$HOOK" 2>&1); then
  fail "T3: subagent git push should be blocked"
else
  if [[ "$out" == *"git push / gh pr create / gh pr merge"* ]]; then
    pass "T3: subagent git push blocked"
  else
    fail "T3: expected push guidance"
  fi
fi

payload='{"tool_name":"Bash","tool_input":{"command":"gh pr view 123"}}'
if out=$(echo "$payload" | CLAUDE_AGENT_DEPTH=1 bash "$HOOK" 2>&1); then
  if [[ -z "$out" ]]; then
    pass "T4: read-only gh command allowed"
  else
    fail "T4: expected no output for read-only gh command"
  fi
else
  fail "T4: read-only gh command should not be blocked"
fi

payload='{"agent_id":"worker-json-only","tool_name":"Bash","tool_input":{"command":"gh pr create --base develop"}}'
if out=$(echo "$payload" | bash "$HOOK" 2>&1); then
  fail "T5: JSON agent_id gh pr create should be blocked"
else
  if [[ "$out" == *"Git/GitHub 書き込み"* ]]; then
    pass "T5: JSON agent_id gh pr create blocked"
  else
    fail "T5: JSON agent_id block message missing"
  fi
fi

payload='{"tool_name":"Bash","tool_input":{"command":"gh pr create --base develop"}}'
if out=$(echo "$payload" | bash "$HOOK" 2>&1); then
  if [[ -z "$out" ]]; then
    pass "T6: parent session bypasses hook"
  else
    fail "T6: expected no output for parent session"
  fi
else
  fail "T6: parent session should not be blocked"
fi

if grep -q 'block-subagent-github-write.sh' "$SETTINGS"; then
  pass "T7: settings.json registers guard hook"
else
  fail "T7: settings.json missing guard hook registration"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
