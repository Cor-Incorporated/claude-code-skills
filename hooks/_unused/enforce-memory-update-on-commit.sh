#!/bin/bash
# enforce-memory-update-on-commit.sh — PostToolUse hook for git commit
# Warns if MEMORY.md currentDate is stale after a significant commit
set -euo pipefail

# Derive MEMORY.md path dynamically from project root
_project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$_project_root" ]; then
  # Claude Code stores per-project memory using a munged path
  _munged_path=$(echo "$_project_root" | sed 's|/|-|g')
  MEMORY_FILE="$HOME/.claude/projects/${_munged_path}/memory/MEMORY.md"
else
  MEMORY_FILE=""
fi

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only trigger on git commit commands
if ! echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+commit'; then
  exit 0
fi

# Check if the tool call was successful
exit_code=$(echo "$input" | jq -r '.tool_result.exitCode // .tool_result.exit_code // "0"')
if [ "$exit_code" != "0" ]; then
  exit 0
fi

# Get project root
project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$project_root" ]; then
  exit 0
fi

# Get changed files in this commit
changed_files=$(cd "$project_root" && git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")

# Skip if the commit itself modifies MEMORY.md
if echo "$changed_files" | grep -q "MEMORY.md"; then
  exit 0
fi

# Check if any significant files were changed (not just .claude/ or lock files)
significant_files=$(echo "$changed_files" | grep -v '^\.' | grep -v '^\.claude/' | grep -v 'pnpm-lock\.yaml' | grep -v 'package-lock\.json' | grep -v 'poetry\.lock' | grep -v '^$' || true)
if [ -z "$significant_files" ]; then
  exit 0
fi

# Check if MEMORY.md exists
if [ ! -f "$MEMORY_FILE" ]; then
  exit 0
fi

# Extract currentDate from MEMORY.md (macOS-compatible, no grep -P)
current_date_in_memory=$(grep "Today's date is" "$MEMORY_FILE" 2>/dev/null | sed -n 's/.*Today'\''s date is \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' || echo "")

# If no currentDate found, warn about that
if [ -z "$current_date_in_memory" ]; then
  output=$(cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "WARNING: MEMORY.md に currentDate フィールドが見つかりません。セッション終了前に MEMORY.md を更新してください。"
  }
}
EOF
)
  echo "$output"
  exit 0
fi

# Compare with today's date
today=$(date +%Y-%m-%d)
if [ "$current_date_in_memory" != "$today" ]; then
  output=$(cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "WARNING: MEMORY.md の currentDate が古いです（${current_date_in_memory} → 今日: ${today}）。セッション終了前に MEMORY.md を更新してください。"
  }
}
EOF
)
  echo "$output"
fi

exit 0
