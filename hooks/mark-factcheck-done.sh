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
    cat > "$STATE_FILE" <<EOJSON
{"factchecked": true, "source": "$source_name", "timestamp": $now, "edit_count_since_check": 0}
EOJSON
fi

exit 0
