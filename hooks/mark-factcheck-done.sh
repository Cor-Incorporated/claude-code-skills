#!/bin/bash
# mark-factcheck-done.sh
# PostToolUse: context7/WebSearch/WebFetch/Read(docs) 使用後にファクトチェック済みフラグを立てる
set -euo pipefail

STATE_FILE="${HOME}/.claude/state/factcheck-status.json"
mkdir -p "$(dirname "$STATE_FILE")"

input=$(cat)
tool=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
now=$(date +%s)

source_name=""
case "$tool" in
    mcp__plugin_context7_context7__resolve-library-id|mcp__plugin_context7_context7__query-docs)
        source_name="context7"
        ;;
    WebSearch|mcp__brave-search__brave_web_search|mcp__brave-search__brave_local_search)
        source_name="WebSearch"
        ;;
    WebFetch)
        source_name="WebFetch"
        ;;
    mcp__claude_ai_Vercel__search_vercel_documentation)
        source_name="VercelDocs"
        ;;
    Read)
        # Readは公式ドキュメント/READMEの場合のみカウント
        file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
        if echo "$file_path" | grep -qEi 'README|CLAUDE\.md|docs/|\.md$'; then
            source_name="DocRead"
        fi
        ;;
esac

if [ -n "$source_name" ]; then
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{}' > "$STATE_FILE"
    fi
    _STATE_FILE="$STATE_FILE" _SOURCE_NAME="$source_name" _NOW="$now" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE_FILE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        data = {}
    data['factchecked'] = True
    data['source'] = os.environ['_SOURCE_NAME']
    data['timestamp'] = int(os.environ['_NOW'])
    data['edit_count_since_check'] = 0
    f.seek(0)
    f.truncate()
    json.dump(data, f)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null
fi

exit 0
