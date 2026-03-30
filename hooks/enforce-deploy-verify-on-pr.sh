#!/usr/bin/env bash
# enforce-deploy-verify-on-pr.sh — Block PR creation if changed hooks/scripts not deployed
# PreToolUse hook on Bash matcher
# Exit 0 = allow, Exit 2 = block
# Triggers on: gh pr create
# Checks: MD5 of changed hooks/*.sh and scripts/*.sh vs deployed copies
set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

COMMAND=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")
echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b' || exit 0

PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[[ -n "$PROJECT_DIR" ]] || exit 0

BASE_BRANCH="develop"
CHANGED_FILES=$(git diff --name-only "$BASE_BRANCH"...HEAD 2>/dev/null || git diff --name-only "$BASE_BRANCH" HEAD 2>/dev/null || echo "")
[[ -n "$CHANGED_FILES" ]] || exit 0

HOOK_CHANGES=$(echo "$CHANGED_FILES" | grep -E '^hooks/[^/]+\.sh$' || true)
SCRIPT_CHANGES=$(echo "$CHANGED_FILES" | grep -E '^scripts/[^/]+\.sh$' || true)
[[ -n "$HOOK_CHANGES" || -n "$SCRIPT_CHANGES" ]] || exit 0

ERRORS=""

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  SOURCE="$PROJECT_DIR/$file"
  DEPLOYED="$HOME/.claude/hooks/$(basename "$file")"
  if [[ ! -f "$DEPLOYED" ]]; then
    ERRORS="${ERRORS}\n  ❌ $file → $DEPLOYED (未デプロイ)"
  else
    SRC_MD5=$(md5 -q "$SOURCE" 2>/dev/null || md5sum "$SOURCE" 2>/dev/null | awk '{print $1}')
    DEP_MD5=$(md5 -q "$DEPLOYED" 2>/dev/null || md5sum "$DEPLOYED" 2>/dev/null | awk '{print $1}')
    if [[ "$SRC_MD5" != "$DEP_MD5" ]]; then
      ERRORS="${ERRORS}\n  ❌ $file — MD5不一致 (src:${SRC_MD5:0:8} != dep:${DEP_MD5:0:8})"
    fi
  fi
done <<< "$HOOK_CHANGES"

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  SOURCE="$PROJECT_DIR/$file"
  DEPLOYED="$HOME/.claude/scripts/$(basename "$file")"
  if [[ ! -f "$DEPLOYED" ]]; then
    ERRORS="${ERRORS}\n  ❌ $file → $DEPLOYED (未デプロイ)"
  else
    SRC_MD5=$(md5 -q "$SOURCE" 2>/dev/null || md5sum "$SOURCE" 2>/dev/null | awk '{print $1}')
    DEP_MD5=$(md5 -q "$DEPLOYED" 2>/dev/null || md5sum "$DEPLOYED" 2>/dev/null | awk '{print $1}')
    if [[ "$SRC_MD5" != "$DEP_MD5" ]]; then
      ERRORS="${ERRORS}\n  ❌ $file — MD5不一致 (src:${SRC_MD5:0:8} != dep:${DEP_MD5:0:8})"
    fi
  fi
done <<< "$SCRIPT_CHANGES"

[[ -n "$ERRORS" ]] || exit 0

echo "" >&2
echo "🚫 [BLOCKED] PR作成を拒否。変更されたhook/scriptが未デプロイです。" >&2
echo "" >&2
echo "  デプロイ検証結果:" >&2
echo -e "$ERRORS" >&2
echo "" >&2
echo "  解決方法:" >&2
echo "  1. bash setup.sh  # 全hook/scriptをデプロイ" >&2
echo "  2. MD5一致を確認してから再試行" >&2
echo "" >&2
echo "  Epic #130: 「コードがある」≠「動作する」" >&2
exit 2
