#!/bin/bash
# enforce-soak-time.sh — PreToolUse hook: enforce soak time before merge
# =========================================================================
# Blocks gh pr merge if insufficient soak time has elapsed since last push.
#
# Rules (git-workflow.md):
#   - develop→main release PR: 12h (43200s) minimum
#   - infra/migration/Terraform changes: 24h (86400s) minimum
#   - Other PRs to develop: no soak time required
#
# Exit 2 = HARD BLOCK
# =========================================================================
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only act on gh pr merge commands
cmd_first=$(echo "$cmd" | head -1)
if ! echo "$cmd_first" | grep -qE 'gh\s+pr\s+merge\b'; then
  exit 0
fi

# --- Extract PR number ---
PR_NUM=$(echo "$cmd" | grep -oE 'gh\s+pr\s+merge\s+([0-9]+)' | grep -oE '[0-9]+' || echo "")
if [[ -z "$PR_NUM" ]]; then
  exit 0  # Cannot determine PR, let other hooks handle
fi

# --- Get PR details ---
REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
if [[ -z "$REPO" ]]; then
  exit 0
fi

PR_JSON=$(gh api "repos/${REPO}/pulls/${PR_NUM}" 2>/dev/null || echo "")
if [[ -z "$PR_JSON" ]]; then
  exit 0
fi

BASE_BRANCH=$(echo "$PR_JSON" | jq -r '.base.ref // ""')
UPDATED_AT=$(echo "$PR_JSON" | jq -r '.updated_at // ""')

if [[ -z "$UPDATED_AT" ]]; then
  exit 0
fi

# --- Calculate elapsed time ---
# macOS compatible date parsing
if date -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s >/dev/null 2>&1; then
  PUSH_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s)
elif date -d "$UPDATED_AT" +%s >/dev/null 2>&1; then
  PUSH_EPOCH=$(date -d "$UPDATED_AT" +%s)
else
  # Cannot parse date, skip enforcement
  exit 0
fi

NOW_EPOCH=$(date +%s)
ELAPSED=$((NOW_EPOCH - PUSH_EPOCH))

# --- Determine required soak time ---
REQUIRED_SOAK=0
SOAK_REASON=""

# Rule 1: develop→main release PR requires 12h
if [[ "$BASE_BRANCH" == "main" ]] || [[ "$BASE_BRANCH" == "master" ]]; then
  REQUIRED_SOAK=43200  # 12 hours
  SOAK_REASON="develop→main release PR: 12時間のsoak time必須"
fi

# Rule 2: infra/migration/Terraform changes require 24h (overrides rule 1)
CHANGED_FILES=$(gh api "repos/${REPO}/pulls/${PR_NUM}/files" --jq '.[].filename' 2>/dev/null || echo "")
HAS_INFRA=false
if echo "$CHANGED_FILES" | grep -qE '^(terraform/|migration/|\.github/workflows/|cloudbuild|Dockerfile|docker-compose)'; then
  HAS_INFRA=true
fi

if [[ "$HAS_INFRA" == "true" ]]; then
  REQUIRED_SOAK=86400  # 24 hours
  SOAK_REASON="infra/migration/Terraform変更: 24時間のsoak time必須"
fi

# --- Enforce ---
if [[ "$REQUIRED_SOAK" -gt 0 ]] && [[ "$ELAPSED" -lt "$REQUIRED_SOAK" ]]; then
  REMAINING=$((REQUIRED_SOAK - ELAPSED))
  REMAINING_H=$((REMAINING / 3600))
  REMAINING_M=$(((REMAINING % 3600) / 60))

  echo "" >&2
  echo "⏳ [SOAK TIME] PR #${PR_NUM} のマージをブロック。" >&2
  echo "   理由: ${SOAK_REASON}" >&2
  echo "   最終更新: ${UPDATED_AT}" >&2
  echo "   経過時間: $((ELAPSED / 3600))h $((ELAPSED % 3600 / 60))m" >&2
  echo "   残り時間: ${REMAINING_H}h ${REMAINING_M}m" >&2
  echo "" >&2
  echo "   git-workflow.md: soak time ルール" >&2
  echo "   - develop→main: 半日以上(12h)" >&2
  echo "   - infra/migration/Terraform: 1営業日以上(24h)" >&2
  echo "" >&2
  exit 2
fi

exit 0
