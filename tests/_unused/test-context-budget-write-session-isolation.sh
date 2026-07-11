#!/usr/bin/env bash
# test-context-budget-write-session-isolation.sh
# Verifies doc/test Write gating is scoped to the current transcript, not
# stale counters left by another agent/session.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/context-budget-write-gate.sh"
SET_MODE="$ROOT/hooks/context-budget-set-mode.sh"

PASS=0
FAIL=0

pass() { echo -e "\033[0;32mPASS\033[0m: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "\033[0;31mFAIL\033[0m: $1"; FAIL=$((FAIL + 1)); }

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/state"

make_input() {
  local transcript="$1"
  local file_path="$2"
  python3 - "$transcript" "$file_path" <<'PY'
import json
import sys

print(json.dumps({
    "tool_name": "Write",
    "transcript_path": sys.argv[1],
    "tool_input": {"file_path": sys.argv[2], "content": "x"},
}))
PY
}

run_hook() {
  local input="$1"
  set +e
  output=$(printf '%s' "$input" | bash "$HOOK" 2>&1)
  status=$?
  set -e
}

# Stale global counter should not affect a fresh transcript.
cat > "$HOME/.claude/state/context-budget.json" <<'JSON'
{
  "mode": "auto",
  "write_test_doc_count": 9,
  "contexts": {}
}
JSON
fresh_transcript="$TMP_HOME/fresh.jsonl"
: > "$fresh_transcript"
run_hook "$(make_input "$fresh_transcript" "/repo/docs/reviews/claude-code-review-20260520.md")"
if [[ "$status" -eq 0 && "$output" == *"ドキュメントファイル作成を検出"* ]]; then
  pass "T1: fresh transcript ignores stale global doc counter"
else
  fail "T1: expected allow despite stale counter (status=$status output=$output)"
fi

# A second doc Write in the same transcript is still blocked.
blocked_transcript="$TMP_HOME/blocked.jsonl"
cat > "$blocked_transcript" <<'JSONL'
{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/docs/reviews/first.md","content":"x"}}]}}
JSONL
run_hook "$(make_input "$blocked_transcript" "/repo/docs/reviews/second.md")"
if [[ "$status" -eq 2 && "$output" == *"2件目"* ]]; then
  pass "T2: same transcript still blocks second doc Write"
else
  fail "T2: expected second doc Write block (status=$status output=$output)"
fi

# The advertised planning helper must exist and exempt the gate.
bash "$SET_MODE" planning >/dev/null
run_hook "$(make_input "$blocked_transcript" "/repo/docs/reviews/third.md")"
if [[ "$status" -eq 0 ]]; then
  pass "T3: planning mode helper exempts doc Write gate"
else
  fail "T3: expected planning mode allow (status=$status output=$output)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
