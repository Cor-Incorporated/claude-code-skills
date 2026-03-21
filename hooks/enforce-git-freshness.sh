#!/bin/bash
# enforce-git-freshness.sh — SessionStart + PreToolUse(Edit,Write) hook
# Ensures local branch is up-to-date with remote before editing.
#
# SessionStart: auto-fetch and warn if behind
# PreToolUse(Edit,Write): block edits if local is behind remote
set -euo pipefail

HOOK_EVENT="${CLAUDE_HOOK_EVENT:-PreToolUse}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Skip non-git directories
if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Skip worktree agents (they manage their own state)
if echo "$PROJECT_DIR" | grep -q '\.claude/worktrees'; then
  exit 0
fi

BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "")
if [ -z "$BRANCH" ]; then
  exit 0
fi

REMOTE="origin"
REMOTE_BRANCH="$REMOTE/$BRANCH"

if [ "$HOOK_EVENT" = "SessionStart" ]; then
  # Auto-fetch on session start
  git -C "$PROJECT_DIR" fetch "$REMOTE" --quiet 2>/dev/null || true

  # Check if behind
  LOCAL_SHA=$(git -C "$PROJECT_DIR" rev-parse "$BRANCH" 2>/dev/null || echo "")
  REMOTE_SHA=$(git -C "$PROJECT_DIR" rev-parse "$REMOTE_BRANCH" 2>/dev/null || echo "")

  if [ -n "$REMOTE_SHA" ] && [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    BEHIND=$(git -C "$PROJECT_DIR" rev-list --count "$BRANCH".."$REMOTE_BRANCH" 2>/dev/null || echo "0")
    if [ "$BEHIND" -gt 0 ]; then
      echo "⚠️ Local '$BRANCH' is $BEHIND commit(s) behind '$REMOTE_BRANCH'." >&2
      echo "  Run: git pull --ff-only" >&2
      # Don't block session start, just warn
      exit 0
    fi
  fi
  exit 0
fi

# PreToolUse: block Edit/Write if behind remote
input=$(cat)
tool=$(echo "$input" | jq -r '.tool_name // ""')

# Only check for Edit and Write tools
if [ "$tool" != "Edit" ] && [ "$tool" != "Write" ]; then
  exit 0
fi

# Skip files outside project (e.g., memory files, state files)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')
if [ -n "$file_path" ] && ! echo "$file_path" | grep -q "$PROJECT_DIR"; then
  exit 0
fi

# Skip non-project files (.claude/, memory, state)
if echo "$file_path" | grep -qE '(\.claude/|memory/|state/)'; then
  exit 0
fi

# Fetch (with 60s cache to avoid hammering remote)
CACHE_FILE="${TMPDIR:-/tmp}/git-freshness-$(printf '%s' "$PROJECT_DIR" | md5 2>/dev/null || printf '%s' "$PROJECT_DIR" | md5sum | cut -d' ' -f1).timestamp"
NOW=$(date +%s)
LAST_FETCH=$(cat "$CACHE_FILE" 2>/dev/null || echo "0")
ELAPSED=$((NOW - LAST_FETCH))

if [ "$ELAPSED" -gt 60 ]; then
  git -C "$PROJECT_DIR" fetch "$REMOTE" --quiet 2>/dev/null || true
  echo "$NOW" > "$CACHE_FILE"
fi

# Check if behind
LOCAL_SHA=$(git -C "$PROJECT_DIR" rev-parse "$BRANCH" 2>/dev/null || echo "")
REMOTE_SHA=$(git -C "$PROJECT_DIR" rev-parse "$REMOTE_BRANCH" 2>/dev/null || echo "")

if [ -n "$REMOTE_SHA" ] && [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  BEHIND=$(git -C "$PROJECT_DIR" rev-list --count "$BRANCH".."$REMOTE_BRANCH" 2>/dev/null || echo "0")
  if [ "$BEHIND" -gt 0 ]; then
    echo "[BLOCKED] Local '$BRANCH' is $BEHIND commit(s) behind '$REMOTE_BRANCH'." >&2
    echo "  Run 'git pull --ff-only' before editing project files." >&2
    echo "  To use an older commit intentionally, use 'git revert' or specify the hash." >&2
    exit 2
  fi
fi

exit 0
