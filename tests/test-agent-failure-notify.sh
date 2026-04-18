#!/usr/bin/env bash
# test-agent-failure-notify.sh — propagate Agent failures to parent context
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/notify-agent-failure.sh"
SETTINGS="$ROOT/settings.json"

tmp_home=""
cleanup() {
  [[ -n "$tmp_home" ]] && rm -rf "$tmp_home"
}
trap cleanup EXIT

echo "=== Agent failure notify tests ==="

if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check"
else
  fail "T1: syntax check failed"
fi

tmp_home=$(mktemp -d)
payload='{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"Push branch and create PR","team_name":"team"},"error":"🚫 [BLOCK] サブエージェント/Team worker から ask 権限が必要な Git/GitHub 書き込みは実行できません。","is_interrupt":false}'
out=$(echo "$payload" | HOME="$tmp_home" bash "$HOOK")
if echo "$out" | grep -q '"hookEventName": "PostToolUseFailure"'; then
  pass "T2: returns PostToolUseFailure context"
else
  fail "T2: missing PostToolUseFailure context"
fi

if echo "$out" | grep -q 'stage: permission_gate'; then
  pass "T3: classifies permission gate failures"
else
  fail "T3: permission stage classification missing"
fi

state_file="$tmp_home/.claude/state/agent-failure-last.json"
if [[ -f "$state_file" ]]; then
  pass "T4: writes latest agent failure state"
else
  fail "T4: missing agent failure state file"
fi

if jq -e '.failure_stage == "permission_gate"' "$state_file" >/dev/null 2>&1; then
  pass "T5: state file stores failure_stage"
else
  fail "T5: state file missing failure_stage"
fi

payload='{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"},"error":"context budget exceeded after 6 source reads","is_interrupt":false}'
out=$(echo "$payload" | HOME="$tmp_home" bash "$HOOK")
if echo "$out" | grep -q 'stage: context_budget'; then
  pass "T6: classifies context budget failures"
else
  fail "T6: context budget classification missing"
fi

payload='{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"},"error":"Aborted","is_interrupt":true}'
if out=$(echo "$payload" | HOME="$tmp_home" bash "$HOOK" 2>&1); then
  if [[ -z "$out" ]]; then
    pass "T7: interrupted failures are ignored"
  else
    fail "T7: expected no output for interrupt"
  fi
else
  fail "T7: interrupt should not fail"
fi

if grep -q 'notify-agent-failure.sh' "$SETTINGS"; then
  pass "T8: settings.json registers Agent failure hook"
else
  fail "T8: settings.json missing Agent failure hook"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
