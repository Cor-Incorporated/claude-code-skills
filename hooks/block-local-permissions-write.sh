#!/bin/bash
# block-local-permissions-write.sh — Prevent writing permissions to settings.local.json
# =========================================================================
# settings.local.json に permissions を書くと、グローバル settings.json の
# permissions を上書きしてしまう。Write/Edit ツールで settings.local.json を
# 変更する際、permissions が含まれていたらブロックする。
# =========================================================================

set -euo pipefail

input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

if [[ -z "$input" ]]; then
  exit 0
fi

FILE_PATH=""
if command -v jq &>/dev/null; then
  FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
fi

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != *"settings.local.json" ]]; then
  exit 0
fi

CONTENT=""
if command -v jq &>/dev/null; then
  CONTENT=$(echo "$input" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null)
fi

if echo "$CONTENT" | grep -qE '"permissions"\s*:'; then
  echo "" >&2
  echo "🚫 [BLOCKED] settings.local.json に permissions セクションを書き込もうとしています！" >&2
  echo "   settings.local.json の permissions はグローバル settings.json を上書きし、" >&2
  echo "   gh/git/Bash allowlist を消して ask/block に戻す可能性があります。" >&2
  echo "   permissions は settings.local.json ではなく settings.json に書いてください。" >&2
  echo "" >&2
  exit 2
fi

exit 0
