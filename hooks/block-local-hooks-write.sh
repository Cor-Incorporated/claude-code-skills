#!/bin/bash
# block-local-hooks-write.sh — Prevent writing hooks to settings.local.json
# =========================================================================
# settings.local.json に hooks を書くとグローバルの hooks を上書きしてしまう。
# Write/Edit ツールで settings.local.json を変更する際、hooks が含まれていたらブロック。
# =========================================================================

input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

if [[ -z "$input" ]]; then
  exit 0
fi

# Check if the target file is settings.local.json
FILE_PATH=""
if command -v jq &>/dev/null; then
  FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
fi

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Only guard settings.local.json
if [[ "$FILE_PATH" != *"settings.local.json" ]]; then
  exit 0
fi

# Check if the content being written contains "hooks"
CONTENT=""
if command -v jq &>/dev/null; then
  # For Write tool: check content field
  CONTENT=$(echo "$input" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null)
fi

if echo "$CONTENT" | grep -qE '"hooks"\s*:'; then
  echo "" >&2
  echo "🚫 [BLOCKED] settings.local.json に hooks セクションを書き込もうとしています！" >&2
  echo "   hooks は settings.local.json ではなく settings.json (グローバル) に書いてください。" >&2
  echo "   理由: settings.local.json の hooks はグローバルの hooks を完全に上書きし、" >&2
  echo "         PR merge gate 等の保護が全て無効化されます。" >&2
  echo "" >&2
  exit 2
fi

exit 0
