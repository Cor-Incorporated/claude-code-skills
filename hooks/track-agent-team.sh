#!/usr/bin/env bash
# track-agent-team.sh
# ========================================================================
# PostToolUse hook: Tracks when Agent tools are launched.
# When 2+ agents are launched (including background), creates/updates
# the parallel team signal file so enforce-parallel-agents.sh can detect
# single-agent regression after compaction.
#
# Trigger: After Agent tool use
# Signal file: ~/.claude/state/parallel-team.json
# ========================================================================

set -euo pipefail

STATE_DIR="$HOME/.claude/state"
SIGNAL_FILE="$STATE_DIR/parallel-team.json"

mkdir -p "$STATE_DIR"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ ! -f "$SIGNAL_FILE" ]]; then
  # First agent launch — create signal with count=1
  cat > "$SIGNAL_FILE" << EOF
{
  "tasks": ["agent-1"],
  "created_at": "$NOW",
  "last_agent_at": "$NOW",
  "agent_count": 1
}
EOF
else
  # Increment agent count and update timestamp
  _SIGNAL_FILE="$SIGNAL_FILE" _NOW="$NOW" python3 -c "
import json, os, sys

with open(os.environ['_SIGNAL_FILE']) as f:
    data = json.load(f)

count = data.get('agent_count', 0) + 1
data['agent_count'] = count
data['last_agent_at'] = os.environ['_NOW']
data['tasks'].append(f'agent-{count}')

# Keep only last 10 task entries
data['tasks'] = data['tasks'][-10:]

with open(os.environ['_SIGNAL_FILE'], 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
fi

exit 0
