#!/bin/bash
# reset-factcheck.sh
# SessionStart: ファクトチェック状態をリセット
set -euo pipefail

STATE_FILE="${HOME}/.claude/state/factcheck-status.json"
mkdir -p "$(dirname "$STATE_FILE")"
_STATE="$STATE_FILE" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
data = {'factchecked': False, 'source': '', 'timestamp': 0, 'edit_count_since_check': 0}
fd = os.open(f_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
with os.fdopen(fd, 'w') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    json.dump(data, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null || echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
exit 0
