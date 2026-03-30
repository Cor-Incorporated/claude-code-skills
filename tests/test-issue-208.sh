#!/usr/bin/env bash
# test-issue-208.sh -- Test enforce-codex-delegation.sh (#208)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/hooks/enforce-codex-delegation.sh"
PASS=0; FAIL=0

pass() { echo -e "\033[0;32mPASS\033[0m: $1"; PASS=$(( PASS + 1 )); }
fail() { echo -e "\033[0;31mFAIL\033[0m: $1"; FAIL=$(( FAIL + 1 )); }

run_hook() { unset CLAUDE_AGENT_DEPTH 2>/dev/null || true; echo "$1" | bash "$HOOK" 2>&1 >/dev/null || true; }

export CLAUDE_AGENT_DEPTH=1
out=$(echo '{"tool_name":"Agent","tool_input":{"prompt":"refactor 10 files entirely","subagent_type":"general-purpose"}}' | bash "$HOOK" 2>&1 >/dev/null) || true
unset CLAUDE_AGENT_DEPTH
[[ -z "$out" ]] && pass "T1: subagent skip" || fail "T1: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"review","subagent_type":"code-reviewer"}}')
[[ -z "$out" ]] && pass "T2: reviewer pass" || fail "T2: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"find stuff","subagent_type":"Explore"}}')
[[ -z "$out" ]] && pass "T3: Explore pass" || fail "T3: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"調査 how auth works","subagent_type":"general-purpose"}}')
[[ -z "$out" ]] && pass "T4: research pass" || fail "T4: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"refactor auth across main.py, routes.py, middleware.py, models.py to unify tokens","subagent_type":"general-purpose"}}')
[[ "$out" == *"[delegation]"* ]] && pass "T5: refactor warns" || fail "T5: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"全体を理解して1500行をリファクタリング","subagent_type":"general-purpose"}}')
[[ "$out" == *"[delegation]"* ]] && pass "T6: large ctx warns" || fail "T6: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"implement then run tests fix failures and re-test iteratively","subagent_type":"general-purpose"}}')
[[ "$out" == *"[delegation]"* ]] && pass "T7: multi-cycle warns" || fail "T7: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"fix null pointer in auth.ts","subagent_type":"general-purpose"}}')
[[ -z "$out" ]] && pass "T8: simple fix pass" || fail "T8: $out"

out=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}')
[[ -z "$out" ]] && pass "T9: non-Agent pass" || fail "T9: $out"

out=$(run_hook '{"tool_name":"Agent","tool_input":{"prompt":"implement 10 files","subagent_type":"claude-code-harness:impl"}}')
[[ -z "$out" ]] && pass "T10: harness pass" || fail "T10: $out"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
