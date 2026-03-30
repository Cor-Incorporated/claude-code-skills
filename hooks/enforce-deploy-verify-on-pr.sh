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

BASE_BRANCH="${DEPLOY_VERIFY_BASE_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "develop")}"
CHANGED_FILES=$(git diff --name-only "$BASE_BRANCH"...HEAD 2>/dev/null || git diff --name-only "$BASE_BRANCH" HEAD 2>/dev/null || echo "")
[[ -n "$CHANGED_FILES" ]] || exit 0

HOOK_CHANGES=$(echo "$CHANGED_FILES" | grep -E '^hooks/[^/]+\.sh$' || true)
SCRIPT_CHANGES=$(echo "$CHANGED_FILES" | grep -E '^scripts/[^/]+\.sh$' || true)
[[ -n "$HOOK_CHANGES" || -n "$SCRIPT_CHANGES" ]] || exit 0

ERRORS=""

# Common function to check deployment status
check_deploy() {
  local file="$1" deploy_dir="$2"
  [[ -z "$file" ]] && return
  local source="$PROJECT_DIR/$file"
  local deployed
  deployed="$deploy_dir/$(basename "$file")"
  if [[ ! -f "$deployed" ]]; then
    ERRORS="${ERRORS}\n  ❌ $file → $deployed (未デプロイ)"
  else
    local src_md5 dep_md5
    src_md5=$(md5 -q "$source" 2>/dev/null || md5sum "$source" 2>/dev/null | awk '{print $1}')
    dep_md5=$(md5 -q "$deployed" 2>/dev/null || md5sum "$deployed" 2>/dev/null | awk '{print $1}')
    if [[ "$src_md5" != "$dep_md5" ]]; then
      ERRORS="${ERRORS}\n  ❌ $file — MD5不一致 (src:${src_md5:0:8} != dep:${dep_md5:0:8})"
    fi
  fi
}

while IFS= read -r file; do
  check_deploy "$file" "$HOME/.claude/hooks"
done <<< "$HOOK_CHANGES"

while IFS= read -r file; do
  check_deploy "$file" "$HOME/.claude/scripts"
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
