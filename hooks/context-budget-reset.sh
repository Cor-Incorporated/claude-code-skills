#!/usr/bin/env bash
# context-budget-reset.sh
# ========================================================================
# SessionStart hook: Resets context budget gate counters for new session.
# Called alongside auto-init-permissions.sh at session start.
#
# State file: ~/.claude/state/context-budget.json
# ========================================================================

set -euo pipefail

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/context-budget.json"

mkdir -p "$STATE_DIR"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$STATE_FILE" << EOF
{
  "session_id": "$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')",
  "read_files": [],
  "read_count": 0,
  "write_test_doc_count": 0,
  "agent_count": 0,
  "impl_agent_count": 0,
  "fg_impl_agent_count": 0,
  "codex_call_count": 0,
  "edit_count": 0,
  "edited_files": [],
  "warnings_issued": [],
  "started_at": "$NOW"
}
EOF

exit 0
