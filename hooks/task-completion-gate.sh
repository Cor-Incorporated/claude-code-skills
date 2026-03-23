#!/bin/bash
# task-completion-gate.sh — TaskCompleted hook
# =========================================================================
# Issue #66 Fix #2: Prevent premature task completion
#
# Ref: https://code.claude.com/docs/en/hooks
#   Event: TaskCompleted (no matcher support — fires for ALL tasks)
#   stdin: { task_id, task_subject, task_description, teammate_name, team_name }
#   Exit 2 = block task from being marked complete
#   Exit 0 = allow task completion
#
# Logic:
#   1. Check if current branch has an open PR
#   2. If yes, verify CI is all green
#   3. If yes, verify no CRITICAL/HIGH review findings
#   4. If any check fails, block task completion with guidance
#
# Scope:
#   - Only fires for PR-related tasks (task_subject contains "PR" or "merge")
#   - Skips tasks that are clearly non-PR (docs, planning, etc.)
# =========================================================================

set -uo pipefail

# Read stdin
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

# Extract task metadata
TASK_SUBJECT=""
TASK_ID=""
if [[ -n "$input" ]] && command -v jq &>/dev/null; then
  TASK_SUBJECT=$(echo "$input" | jq -r '.task_subject // ""' 2>/dev/null || echo "")
  TASK_ID=$(echo "$input" | jq -r '.task_id // ""' 2>/dev/null || echo "")
fi

# Skip non-PR tasks: only gate tasks related to PR/merge/deploy
# This prevents blocking every single task completion
if [[ -n "$TASK_SUBJECT" ]]; then
  case "$TASK_SUBJECT" in
    *PR*|*pr*|*merge*|*Merge*|*deploy*|*Deploy*|*ship*|*Ship*|*release*|*Release*)
      : # PR-related task — proceed with checks
      ;;
    *)
      # Not PR-related — allow completion without checks
      exit 0
      ;;
  esac
fi

# Determine current branch
BRANCH=$(git branch --show-current 2>/dev/null || echo "")
[[ -z "$BRANCH" ]] && exit 0

# Check if there's an open PR for this branch
PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number -q '.[0].number' 2>/dev/null || echo "")
[[ -z "$PR_NUMBER" ]] && exit 0  # No open PR — allow completion

# Get repo info
REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
[[ -z "$REPO" ]] && exit 0

# Get HEAD SHA for CI checks
HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")
[[ -z "$HEAD_SHA" ]] && exit 0

# =========================================================================
# Gate 1: CI must be all green (no failures, no pending)
# =========================================================================
CI_FAILURES=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
  --jq '[.check_runs[] | select(.conclusion=="failure")] | length' 2>/dev/null || echo "0")
CI_PENDING=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
  --jq '[.check_runs[] | select(.status!="completed")] | length' 2>/dev/null || echo "0")

if [[ "$CI_FAILURES" -gt 0 ]]; then
  echo "" >&2
  echo "[task-completion-gate] タスク完了をブロック: PR #${PR_NUMBER} CI失敗 (${CI_FAILURES}件)" >&2
  echo "  CIを修正してからタスクを完了してください。" >&2
  echo "  確認: gh pr checks ${PR_NUMBER}" >&2
  echo "" >&2
  exit 2
fi

if [[ "$CI_PENDING" -gt 0 ]]; then
  echo "" >&2
  echo "[task-completion-gate] タスク完了をブロック: PR #${PR_NUMBER} CI実行中 (${CI_PENDING}件)" >&2
  echo "  CI完了を待ってからタスクを完了してください。" >&2
  echo "  確認: gh pr checks ${PR_NUMBER}" >&2
  echo "" >&2
  exit 2
fi

# =========================================================================
# Gate 2: No CRITICAL/HIGH review findings
# =========================================================================
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi

PENDING_FILE="$STATE_DIR/pending-review-comments.json"
if [[ -f "$PENDING_FILE" ]] && command -v jq &>/dev/null; then
  _pr_match=$(jq -r '.pr // ""' "$PENDING_FILE" 2>/dev/null || echo "")
  if [[ "$_pr_match" == "$PR_NUMBER" ]]; then
    CRITICAL=$(jq -r '.critical // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
    HIGH=$(jq -r '.high // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
    if [[ "$CRITICAL" -gt 0 ]] || [[ "$HIGH" -gt 0 ]]; then
      echo "" >&2
      echo "[task-completion-gate] タスク完了をブロック: PR #${PR_NUMBER} 未対応レビュー" >&2
      echo "  CRITICAL=${CRITICAL} HIGH=${HIGH}" >&2
      echo "  レビュー指摘を対応してからタスクを完了してください。" >&2
      echo "" >&2
      exit 2
    fi
  fi
fi

# All checks passed
exit 0
