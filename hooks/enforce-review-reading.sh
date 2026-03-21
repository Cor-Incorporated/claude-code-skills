#!/bin/bash
# enforce-review-reading.sh — PreToolUse hook
# If pending-review-comments.json exists with unread CRITICAL/HIGH,
# block gh pr merge AND inject a reminder on any Bash command.
#
# This ensures the agent cannot claim "ready to merge" without having
# addressed review findings.
set -uo pipefail

[[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && exit 0
[[ -n "${CLAUDE_AGENT_ID:-}" ]] && exit 0

# Project-scoped state
if git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi

PENDING_FILE="$STATE_DIR/pending-review-comments.json"
[[ ! -f "$PENDING_FILE" ]] && exit 0

input=""
[[ ! -t 0 ]] && input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Read pending state
REVIEW_DATA=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f:
    d = json.load(f)
print(json.dumps(d))
" 2>/dev/null || echo "{}")

TOTAL=$(echo "$REVIEW_DATA" | jq -r '.total // 0' 2>/dev/null || echo "0")
CRITICAL=$(echo "$REVIEW_DATA" | jq -r '.critical // 0' 2>/dev/null || echo "0")
HIGH=$(echo "$REVIEW_DATA" | jq -r '.high // 0' 2>/dev/null || echo "0")
PR=$(echo "$REVIEW_DATA" | jq -r '.pr // ""' 2>/dev/null || echo "")

[[ "$TOTAL" -eq 0 ]] && exit 0

# HARD BLOCK: gh pr merge with unresolved findings
if echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+merge'; then
  if [[ "$CRITICAL" -gt 0 ]] || [[ "$HIGH" -gt 0 ]]; then
    echo "[BLOCKED] PR #${PR}: 未対応のCRITICAL/HIGH指摘があります（CRITICAL=${CRITICAL}, HIGH=${HIGH}）。" >&2
    echo "  レビューコメントを確認し、全て対応してからマージしてください。" >&2
    echo "  確認: gh api repos/.../pulls/${PR}/comments" >&2
    exit 2
  fi
fi

# SOFT REMINDER: any other command — output pending review info
# This outputs hookSpecificOutput so agent sees the pending reviews
OUTPUT=$(echo "$REVIEW_DATA" | jq -r '.output // ""' 2>/dev/null || echo "")
if [[ -n "$OUTPUT" ]] && [[ "$OUTPUT" != "null" ]]; then
  _OUTPUT="$OUTPUT" _PR="$PR" python3 -c "
    import json, os
    output = os.environ['_OUTPUT']
    # Truncate for context efficiency
    if len(output) > 2000:
        output = output[:2000] + '\n... (truncated, see full: gh api repos/.../pulls/' + os.environ['_PR'] + '/comments)'
    result = {
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'additionalContext': output
        }
    }
    print(json.dumps(result))
    " 2>/dev/null
fi

exit 0
