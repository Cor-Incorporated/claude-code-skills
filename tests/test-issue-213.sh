#!/usr/bin/env bash
# test-issue-213.sh — enforce-codex-delegation.sh fixes (#213)
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/enforce-codex-delegation.sh"
echo "=== Issue #213: enforce-codex-delegation.sh tests ==="

run_hook() {
  unset CLAUDE_AGENT_DEPTH
  echo "$1" | bash "$HOOK" 2>&1
}

# T1: Syntax check
if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check (bash -n)"
else
  fail "T1: syntax check failed"
fi

# T2: Normal Agent tool_input (object) — refactor with many files → warning
out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"refactor utils.ts, helpers.ts, and config.ts to use new pattern","subagent_type":"general-purpose"}}')
if [[ "$out" == *"[delegation]"* ]]; then
  pass "T2: refactor+3 files triggers delegation warning"
else
  fail "T2: expected delegation warning for refactor+files"
fi

# T3: Stringified tool_input — should still parse correctly
out=$(run_hook '{"tool_name":"Agent","tool_input":"{\"prompt\":\"refactor utils.ts, helpers.ts, and config.ts\",\"subagent_type\":\"general-purpose\"}"}')
if [[ "$out" == *"[delegation]"* ]]; then
  pass "T3: stringified tool_input triggers delegation warning"
else
  fail "T3: stringified tool_input should still trigger warning"
fi

# T4: Numeric file count — "refactor 10 files" should count as 10
out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"refactor 10 files across the codebase","subagent_type":"general-purpose"}}')
if [[ "$out" == *"[delegation]"* ]]; then
  pass "T4: 'refactor 10 files' triggers delegation warning"
else
  fail "T4: 'refactor 10 files' should count 10 toward FILE_IND"
fi

# T5: Small task — no warning
out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"fix the typo in README.md","subagent_type":"general-purpose"}}')
if [[ -z "$out" ]]; then
  pass "T5: simple fix → no warning"
else
  fail "T5: simple fix should not trigger warning"
fi

# T6: Code-reviewer subagent → no warning
out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"review the PR","subagent_type":"code-reviewer"}}')
if [[ -z "$out" ]]; then
  pass "T6: code-reviewer → no warning"
else
  fail "T6: code-reviewer should be exempt"
fi

# T7: Subagent depth → skip (call hook directly, not via run_hook)
out=$(CLAUDE_AGENT_DEPTH=1 bash -c 'echo "$1" | bash "$0" 2>&1' "$HOOK" '{"tool_name":"Agent","tool_input":{"prompt":"refactor everything across 20 files","subagent_type":"general-purpose"}}')
if [[ -z "$out" ]]; then
  pass "T7: CLAUDE_AGENT_DEPTH=1 → skip"
else
  fail "T7: subagent should skip hook"
fi

# T8: settings.json registration check
SETTINGS="$(cd "$(dirname "$0")/.." && pwd)/settings.json"
if grep -q 'enforce-codex-delegation.sh' "$SETTINGS"; then
  pass "T8: registered in settings.json"
else
  fail "T8: NOT registered in settings.json"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
