#!/bin/bash
# reset-factcheck.sh
# SessionStart: ファクトチェック状態をリセット
set -euo pipefail

STATE_FILE="${HOME}/.claude/state/factcheck-status.json"
mkdir -p "$(dirname "$STATE_FILE")"
echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
exit 0
