#!/bin/bash
# enforce-factcheck-before-edit.sh
# BLOCKING: Write/Edit 前にファクトチェック（context7/WebSearch/WebFetch/ドキュメントRead）を強制
#
# 仕組み:
#   - PostToolUse で context7/WebSearch/WebFetch/Read(docs) 使用時にフラグを立てる
#   - PreToolUse で Write/Edit 時にフラグを確認、未確認なら強制停止
#   - SessionStart でフラグをリセット
#
# State file: ~/.claude/state/factcheck-status.json
set -euo pipefail

STATE_FILE="${HOME}/.claude/state/factcheck-status.json"
mkdir -p "$(dirname "$STATE_FILE")"

# State fileが存在しない場合は作成
if [ ! -f "$STATE_FILE" ]; then
    echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
fi

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

# .claude/ 配下、node_modules、lock files は除外
if echo "$file_path" | grep -qE '\.claude/|node_modules/|pnpm-lock\.yaml|package-lock\.json|MEMORY\.md'; then
    exit 0
fi

# テスト結果ファイルやログは除外
if echo "$file_path" | grep -qE '\.log$|/log/|/tmp/|coverage'; then
    exit 0
fi

# 非コードファイルは除外 (LSP分析不要: CI, docs, config)
if echo "$file_path" | grep -qE '\.(md|yml|yaml)$|Dockerfile|\.dockerignore|\.gitignore|\.gitattributes|\.editorconfig|LICENSE|CHANGELOG'; then
    exit 0
fi

# GitHub Actions / CI workflows は除外
if echo "$file_path" | grep -qE '\.github/(workflows|actions)/'; then
    exit 0
fi

# ファクトチェック状態を確認
factchecked=$(jq -r '.factchecked // false' "$STATE_FILE" 2>/dev/null || echo "false")
edit_count=$(jq -r '.edit_count_since_check // 0' "$STATE_FILE" 2>/dev/null || echo "0")
source_used=$(jq -r '.source // ""' "$STATE_FILE" 2>/dev/null || echo "")
timestamp=$(jq -r '.timestamp // 0' "$STATE_FILE" 2>/dev/null || echo "0")

# 現在のUNIX時刻
now=$(date +%s)

# ファクトチェックの有効期限: 10分（600秒）
# または5回のEdit/Write後にリセット
expired=false
if [ "$factchecked" = "true" ]; then
    elapsed=$((now - timestamp))
    if [ "$elapsed" -gt 600 ]; then
        expired=true
    fi
    if [ "$edit_count" -ge 5 ]; then
        expired=true
    fi
fi

if [ "$factchecked" = "false" ] || [ "$expired" = "true" ]; then
    # インフラ/設定ファイルの場合は完全ブロック
    if echo "$file_path" | grep -qE '\.(yml|yaml)$|Dockerfile|vercel\.json|\.env|Makefile|docker-compose|cloudbuild|terraform'; then
        echo "[BLOCKED] enforce-factcheck-before-edit: インフラ/設定ファイルの修正前にファクトチェックが必要です。" >&2
        echo "  対象ファイル: $file_path" >&2
        echo "  必須: context7 (resolve-library-id → query-docs) または WebSearch で公式ドキュメントを確認してから修正してください。" >&2
        echo "" >&2
        echo "  例: Vercel設定 → context7でVercel docs確認" >&2
        echo "  例: GitHub Actions → context7でGitHub Actions docs確認" >&2
        echo "  例: Cloud Run → WebSearchでCloud Run最新ドキュメント確認" >&2
        echo "解決方法: context7/WebSearch/WebFetchで公式ドキュメントを確認してから再度実行してください。" >&2
        exit 2
    fi

    # ソースコードの場合は警告（初回は通す、2回目以降はブロック）
    if [ "$edit_count" -ge 2 ] && [ "$factchecked" = "false" ]; then
        echo "[BLOCKED] enforce-factcheck-before-edit: 複数ファイルの修正前にファクトチェックが必要です。" >&2
        echo "  context7、WebSearch、または関連ドキュメントのReadを実行してから修正してください。" >&2
        echo "  ファクトチェック済みの場合: context7/WebSearch/WebFetch を1回使うとフラグが立ちます。" >&2
        echo "解決方法: context7/WebSearch/WebFetchのいずれかを1回使用してからファイル修正を実行してください。" >&2
        exit 2
    fi

    # edit_countを増加
    jq --argjson count "$((edit_count + 1))" '.edit_count_since_check = $count' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    if [ "$factchecked" = "false" ] && [ "$edit_count" -eq 0 ]; then
        echo "⚠️ [WARN] ファクトチェックが未実施です。修正内容が最新ドキュメントに沿っているか確認してください。"
        echo "  context7/WebSearch/WebFetch を使用するとこの警告は消えます。"
    fi
else
    # ファクトチェック済み: edit_countを増加
    jq --argjson count "$((edit_count + 1))" '.edit_count_since_check = $count' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

exit 0
