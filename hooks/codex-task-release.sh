#!/bin/bash
# codex-task-release.sh — PostToolUse hook for Bash
# ========================================================================
# Releases codex_call_count after a Codex CLI command completes.
#
# Problem (Issue #31 / user feedback):
#   codex-task-gate.sh (PreToolUse) increments codex_call_count on Codex
#   execution, but never decrements it. This means after 1 Codex call
#   completes, no further Codex calls are allowed for the entire session.
#   The rule intent is "max 1 CONCURRENT Codex task", not "max 1 ever".
#
# Solution:
#   This PostToolUse hook detects completed Codex commands and decrements
#   codex_call_count, re-enabling future Codex calls.
#
# Trigger: PostToolUse for Bash tool
# State file: ~/.claude/state/context-budget.json
# ========================================================================

set -euo pipefail

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
bash_cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Only process Bash tool completions
[[ "$tool_name" != "Bash" ]] && exit 0

# Only match actual Codex execution (same pattern as codex-task-gate.sh)
first_line=$(echo "$bash_cmd" | head -1)
is_codex_exec=false
if echo "$first_line" | grep -qE '^\s*(\S+=\S+\s+)*bash\s+\S*codex-(parallel|orchestrate)'; then
    is_codex_exec=true
elif echo "$first_line" | grep -qE '^\s*(\S+=\S+\s+)*codex\s+exec\b'; then
    is_codex_exec=true
fi

[[ "$is_codex_exec" != "true" ]] && exit 0

# Decrement codex_call_count (release the lock)
BUDGET_FILE="${HOME}/.claude/state/context-budget.json"
if [[ ! -f "$BUDGET_FILE" ]]; then
    mkdir -p "$(dirname "$BUDGET_FILE")"
    echo '{}' > "$BUDGET_FILE"
fi

if [[ -f "$BUDGET_FILE" ]]; then
    _BUDGET_FILE="$BUDGET_FILE" python3 -c "
import fcntl, json, os
f_path = os.environ['_BUDGET_FILE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    count = s.get('codex_call_count', 0)
    if count > 0:
        s['codex_call_count'] = count - 1
    f.seek(0)
    f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null
fi

exit 0
