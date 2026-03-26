#!/bin/bash
# Test: enforce-factcheck-github-ops.sh
set -euo pipefail

HOOK="hooks/enforce-factcheck-github-ops.sh"
STATE_FILE="${HOME}/.claude/state/factcheck-status.json"

# Ensure state directory exists
mkdir -p "$(dirname "$STATE_FILE")"

echo "=== Test: Block gh issue comment without factcheck ==="
echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"gh issue comment 329 --body \"test\""}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "✅ PASS: Blocked gh issue comment without factcheck"
else
    echo "❌ FAIL: Did not block gh issue comment"
    exit 1
fi

echo "=== Test: Allow gh issue comment with factcheck ==="
now=$(date +%s)
echo "{\"factchecked\": true, \"source\": \"gcloud\", \"timestamp\": $now, \"edit_count_since_check\": 0}" > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"gh issue comment 329 --body \"test\""}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "❌ FAIL: Blocked despite factcheck done"
    exit 1
else
    echo "✅ PASS: Allowed gh issue comment with factcheck"
fi

echo "=== Test: Allow gh issue list (read operation) ==="
echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"gh issue list --state open"}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "❌ FAIL: Blocked read-only operation"
    exit 1
else
    echo "✅ PASS: Allowed read-only gh issue list"
fi

echo "=== Test: Block gh pr create without factcheck ==="
echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"gh pr create --title \"test\" --body \"test\""}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "✅ PASS: Blocked gh pr create without factcheck"
else
    echo "❌ FAIL: Did not block gh pr create"
    exit 1
fi

echo "=== Test: Block gh issue create without factcheck ==="
echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"gh issue create --title \"bug\" --body \"description\""}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "✅ PASS: Blocked gh issue create without factcheck"
else
    echo "❌ FAIL: Did not block gh issue create"
    exit 1
fi

echo "=== Test: Allow gh issue view (read operation) ==="
echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"gh issue view 329"}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "❌ FAIL: Blocked read-only gh issue view"
    exit 1
else
    echo "✅ PASS: Allowed read-only gh issue view"
fi

echo "=== Test: Allow non-gh commands ==="
echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"npm test"}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "❌ FAIL: Blocked non-gh command"
    exit 1
else
    echo "✅ PASS: Allowed non-gh command"
fi

echo "=== Test: Block when factcheck expired (>10 min) ==="
expired_ts=$(($(date +%s) - 700))
echo "{\"factchecked\": true, \"source\": \"WebSearch\", \"timestamp\": $expired_ts, \"edit_count_since_check\": 0}" > "$STATE_FILE"
result=$(echo '{"tool_input":{"command":"gh issue comment 329 --body \"test\""}}' | bash "$HOOK" 2>&1) || true
if echo "$result" | grep -q "BLOCK"; then
    echo "✅ PASS: Blocked expired factcheck"
else
    echo "❌ FAIL: Did not block expired factcheck"
    exit 1
fi

echo ""
echo "All tests passed ✅"
