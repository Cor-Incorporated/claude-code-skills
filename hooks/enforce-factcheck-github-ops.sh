#!/bin/bash
# enforce-factcheck-github-ops.sh
# BLOCKING: gh issue/pr 操作前にファクトチェックを強制
#
# トリガー: PreToolUse:Bash (gh issue comment/create, gh pr create)
# 目的: 外部に公開される情報（Issue コメント、PR 説明文）に
#        未検証の事実が含まれないことを保証する
#
# 検出パターン:
#   - gh issue comment / gh issue create
#   - gh pr create
#
# ファクトチェック済みの判定:
#   - factcheck-status.json の factchecked = true かつ有効期限内
#
# 例外:
#   - gh issue close (クローズ操作自体は enforce-issue-close-verification.sh が担当)
#   - gh issue list / gh issue view (読み取り操作)
#   - gh pr merge / gh pr checks (マージ/確認操作)
set -euo pipefail

STATE_FILE="${HOME}/.claude/state/factcheck-status.json"
mkdir -p "$(dirname "$STATE_FILE")"

# jq必須: fail-closed（jqなしでは判定不能 → ブロック）
if ! command -v jq &>/dev/null; then
    echo "[BLOCK] jq が見つかりません。ファクトチェック判定に必要です。" >&2
    exit 2
fi

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Extract first command from chain (before &&, ||, ;, |)
# This prevents bypass via "gh issue create && gh issue view"
first_cmd=$(echo "$command" | sed 's/[&|;].*//' | xargs 2>/dev/null || echo "$command")

# gh issue/pr の書き込み操作のみ対象（\s+ for multi-space tolerance）
if ! echo "$first_cmd" | grep -qE 'gh\s+(issue\s+(comment|create)|pr\s+create)'; then
    exit 0
fi

# State file 存在チェック
if [ ! -f "$STATE_FILE" ]; then
    echo '{"factchecked": false, "source": "", "timestamp": 0, "edit_count_since_check": 0}' > "$STATE_FILE"
fi

factchecked=$(jq -r '.factchecked // false' "$STATE_FILE" 2>/dev/null || echo "false")
timestamp=$(jq -r '.timestamp // 0' "$STATE_FILE" 2>/dev/null || echo "0")
now=$(date +%s)

# 有効期限: 10分
expired=false
if [ "$factchecked" = "true" ]; then
    elapsed=$((now - timestamp))
    if [ "$elapsed" -gt 600 ]; then
        expired=true
    fi
fi

if [ "$factchecked" = "false" ] || [ "$expired" = "true" ]; then
    echo "🚫 [BLOCK] GitHub Issue/PR への書き込み前にファクトチェックが必要です。" >&2
    echo "" >&2
    echo "  検出コマンド: $(echo "$command" | head -c 100)..." >&2
    echo "" >&2
    echo "  外部に公開される情報には、検証済みの事実のみを含めてください。" >&2
    echo "  以下のいずれかを実行してからやり直してください:" >&2
    echo "" >&2
    echo "  1. gcloud / CLI コマンドで事実を確認" >&2
    echo "  2. WebSearch で公式ドキュメントを確認" >&2
    echo "  3. context7 でライブラリドキュメントを確認" >&2
    echo "  4. コードベースで grep/Read で実装を確認" >&2
    echo "" >&2
    echo "  ⚠️ 推測に基づくIssueコメントやPR説明文は禁止です。" >&2
    echo "  📋 インシデント事例: Issue #329 で「Generative Language API」の名称を" >&2
    echo "     GCPコンソールで検証せずに記載し、不正確な情報を投稿" >&2
    exit 2
fi

exit 0
