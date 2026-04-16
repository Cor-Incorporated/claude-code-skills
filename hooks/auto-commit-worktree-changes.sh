#!/bin/bash
# auto-commit-worktree-changes.sh — PostToolUse:Agent hook
# =========================================================================
# Issue #220: Auto-commit agent worktree changes after merge to parent dir.
#
# When a background Agent with isolation="worktree" completes, Claude Code
# applies the patch to the parent working directory via git apply --3way.
# However, the changes are left UNCOMMITTED, risking data loss on branch
# switch or stash operations.
#
# This hook detects uncommitted changes after a worktree agent completes
# and auto-commits them with --no-verify for traceability.
#
# Trigger: PostToolUse on Agent tool
# stdin: { tool_name, tool_input, tool_response, tool_use_id }
# Exit: always 0 (PostToolUse cannot block)
# =========================================================================
set -uo pipefail
# Note: -e is intentionally omitted — best-effort commit, never fail the hook

# --- Save original stdout for JSON output, redirect stdout to stderr ---
exec 3>&1
exec 1>&2

# --- Read stdin ---
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi
[[ -z "$input" ]] && exit 0
command -v jq &>/dev/null || exit 0

# --- Extract agent metadata ---
isolation=$(echo "$input" | jq -r '.tool_input.isolation // ""' 2>/dev/null || echo "")
subagent_type=$(echo "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
description=$(echo "$input" | jq -r '.tool_input.description // ""' 2>/dev/null || echo "")
task_id=$(echo "$input" | jq -r '.tool_input.task_id // ""' 2>/dev/null || echo "")

# --- Only trigger for worktree-isolated agents ---
if [[ "$isolation" != "worktree" ]]; then
  exit 0
fi

# --- Skip research/review agents (no file changes expected) ---
RESEARCH_TYPES="Explore|architect|planner|Plan|code-reviewer|security-reviewer"
RESEARCH_TYPES="${RESEARCH_TYPES}|feature-dev:code-reviewer|feature-dev:code-explorer"
RESEARCH_TYPES="${RESEARCH_TYPES}|feature-dev:code-architect|claude-code-guide|general-purpose"

if [[ -n "$subagent_type" ]] && echo "$subagent_type" | grep -qE "^(${RESEARCH_TYPES})$"; then
  exit 0
fi

# --- Must be in a git repo ---
git rev-parse --git-dir &>/dev/null || exit 0

# --- Check for uncommitted changes ---
if git diff --quiet HEAD 2>/dev/null && \
   git diff --cached --quiet 2>/dev/null && \
   [[ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
  # No uncommitted changes — nothing to do
  exit 0
fi

# --- Build commit message ---
TASK_LABEL=""
if [[ -n "$task_id" ]]; then
  TASK_LABEL="task ${task_id}"
elif [[ -n "$description" ]]; then
  # Truncate description to 50 chars for commit message
  TASK_LABEL="$(echo "$description" | head -c 50 | tr '\n' ' ')"
else
  TASK_LABEL="worktree agent"
fi

COMMIT_MSG="chore(team): apply worker changes from ${TASK_LABEL}"

# --- Auto-commit (best effort) ---
git add -A 2>/dev/null || true
if git commit -m "$COMMIT_MSG" --no-verify 2>/dev/null; then
  echo "[auto-commit] worktree changes committed: ${COMMIT_MSG}" >&2
  # Output additionalContext JSON via saved fd 3
  MSG="[auto-commit] ✅ worktree changes auto-committed: ${COMMIT_MSG}"
  jq -n --arg ctx "$MSG" '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}' >&3
else
  echo "[auto-commit] WARNING: commit failed (no changes to commit or other issue)" >&2
fi

exit 0
