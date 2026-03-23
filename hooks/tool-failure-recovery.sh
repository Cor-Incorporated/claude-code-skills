#!/bin/bash
# tool-failure-recovery.sh — PostToolUseFailure hook
# =========================================================================
# Issue #66 Fix #6: Error recovery guidance on tool failure
#
# Ref: https://code.claude.com/docs/en/hooks
#   Event: PostToolUseFailure (matcher: tool name regex)
#   stdin: { tool_name, tool_input, error, is_interrupt, tool_use_id }
#   Exit 0 + JSON = additionalContext injected into conversation
#   Exit 2 = stderr shown to Claude (tool already failed, non-blocking)
#
# Logic:
#   1. Skip interrupted commands (is_interrupt=true)
#   2. Classify error by tool type and error pattern
#   3. Provide actionable recovery guidance via additionalContext
# =========================================================================

set -uo pipefail

# Read stdin
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

[[ -z "$input" ]] && exit 0

# Require jq
command -v jq &>/dev/null || exit 0

# Skip interrupted commands (user Ctrl+C, etc.)
IS_INTERRUPT=$(echo "$input" | jq -r '.is_interrupt // false' 2>/dev/null || echo "false")
if [[ "$IS_INTERRUPT" == "true" ]]; then
  exit 0
fi

TOOL_NAME=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
ERROR_MSG=$(echo "$input" | jq -r '.error // ""' 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$input" | jq -r '.tool_input // {}' 2>/dev/null || echo "{}")

# Skip if no useful info
[[ -z "$TOOL_NAME" ]] && exit 0
[[ -z "$ERROR_MSG" ]] && exit 0

# =========================================================================
# Error classification and recovery guidance
# =========================================================================
GUIDANCE=""

case "$TOOL_NAME" in
  Bash)
    CMD=$(echo "$TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null || echo "")
    if echo "$ERROR_MSG" | grep -qi "command not found"; then
      MISSING_CMD=$(echo "$ERROR_MSG" | grep -oE '[a-z_-]+: command not found' | head -1 | cut -d: -f1)
      GUIDANCE="コマンド '${MISSING_CMD}' が見つかりません。brew install / npm install -g / pip install で導入するか、代替コマンドを使用してください。"
    elif echo "$ERROR_MSG" | grep -qi "permission denied"; then
      GUIDANCE="権限エラー。ファイル権限を確認してください: ls -la <path>。実行権限が必要なら chmod +x を検討。"
    elif echo "$ERROR_MSG" | grep -qi "No such file or directory"; then
      GUIDANCE="ファイル/ディレクトリが存在しません。パスを確認してください: ls -la で親ディレクトリを確認。"
    elif echo "$ERROR_MSG" | grep -qi "ENOSPC\|No space left"; then
      GUIDANCE="ディスク容量不足。不要ファイルを削除してください: docker system prune, npm cache clean --force"
    elif echo "$ERROR_MSG" | grep -qi "ECONNREFUSED\|Connection refused"; then
      GUIDANCE="接続拒否。サービスが起動しているか確認: lsof -i :<port>, docker ps"
    elif echo "$ERROR_MSG" | grep -qi "timeout\|timed out"; then
      GUIDANCE="タイムアウト。ネットワーク接続を確認するか、タイムアウト値を増やしてください。"
    elif echo "$CMD" | grep -qE '^(npm|pnpm|yarn)'; then
      GUIDANCE="パッケージマネージャエラー。lockfile削除と再インストールを試してください: rm -rf node_modules && npm install"
    elif echo "$CMD" | grep -qE '^pip'; then
      GUIDANCE="Pythonパッケージエラー。venvが有効か確認: which python3, pip install --upgrade pip"
    elif echo "$CMD" | grep -qE '^(docker|docker-compose)'; then
      GUIDANCE="Dockerエラー。Docker Desktopが起動しているか確認。--platform linux/amd64 が必要な場合あり(Apple Silicon)。"
    fi
    ;;
  Edit)
    if echo "$ERROR_MSG" | grep -qi "old_string.*not found\|not unique"; then
      GUIDANCE="Edit失敗: old_stringが一致しません。Readツールでファイルの現在の内容を再確認してから、正確なold_stringでリトライしてください。"
    fi
    ;;
  Write)
    if echo "$ERROR_MSG" | grep -qi "must read.*first\|did not read"; then
      GUIDANCE="Write失敗: ファイルを先にReadする必要があります。Read → Write の順序を守ってください。"
    fi
    ;;
  Grep)
    if echo "$ERROR_MSG" | grep -qi "regex.*error\|invalid.*pattern"; then
      GUIDANCE="Grep正規表現エラー。特殊文字をエスケープしてください。ripgrep構文: {} は \\{\\} に。"
    fi
    ;;
  WebFetch|WebSearch)
    if echo "$ERROR_MSG" | grep -qi "redirect"; then
      GUIDANCE="リダイレクト検出。リダイレクト先URLで再試行してください。"
    elif echo "$ERROR_MSG" | grep -qi "403\|forbidden\|unauthorized"; then
      GUIDANCE="アクセス拒否。認証が必要なURLです。gh CLI や専用MCPツールを使用してください。"
    fi
    ;;
esac

# If no specific guidance matched, provide generic guidance
if [[ -z "$GUIDANCE" ]]; then
  # Only provide generic guidance for repeated failures (avoid noise)
  exit 0
fi

# Output additionalContext via hookSpecificOutput
# Ref: PostToolUseFailure can inject additionalContext on exit 0
if command -v jq &>/dev/null; then
  jq -n --arg ctx "[recovery-guide] ${GUIDANCE}" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUseFailure","additionalContext":$ctx}}'
else
  # Fallback: sanitize for JSON
  _safe=$(echo "$GUIDANCE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat <<RECOVERY_JSON
{"hookSpecificOutput":{"hookEventName":"PostToolUseFailure","additionalContext":"[recovery-guide] ${_safe}"}}
RECOVERY_JSON
fi
exit 0
