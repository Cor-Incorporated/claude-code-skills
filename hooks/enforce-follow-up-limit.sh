#!/bin/bash
# enforce-follow-up-limit.sh — PreToolUse hook: detect consecutive fix PRs → feature freeze
# =========================================================================
# Blocks feat PR creation when 2+ consecutive fix PRs exist for the same
# feature prefix, enforcing stabilization before new feature development.
#
# Rules (git-workflow.md):
#   - 同一feature系統のfollow-up fixが2本連続 → feature freeze発動
#   - 新規feat PRの作成を停止し、stabilizationに集中
#   - 安定化確認後にfreeze解除
#
# Exit 2 = HARD BLOCK (feat PR creation blocked)
# =========================================================================
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only act on gh pr create commands
cmd_first=$(echo "$cmd" | head -1)
if ! echo "$cmd_first" | grep -qE 'gh\s+pr\s+create\b'; then
  exit 0
fi

# Only block feat PRs (fix/chore/docs/ci are always allowed)
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "$CURRENT_BRANCH" ]] || ! echo "$CURRENT_BRANCH" | grep -qE '^feat/'; then
  exit 0
fi

# --- Extract feature prefix ---
# feat/user-auth-v2 → user-auth
# fix/user-auth-bug → user-auth
# Pattern: remove type prefix, then extract first 2 hyphen-separated words
extract_feature_prefix() {
  local branch="$1"
  echo "$branch" | sed -E 's|^(feat|fix|refactor|chore|docs|ci|test|perf)/||' | cut -d'-' -f1-2
}

CURRENT_PREFIX=$(extract_feature_prefix "$CURRENT_BRANCH")
if [[ -z "$CURRENT_PREFIX" ]]; then
  exit 0
fi

# --- Count recent fix PRs with same prefix ---
REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
if [[ -z "$REPO" ]]; then
  exit 0
fi

# Get merged fix PRs from last 7 days with matching prefix
SEVEN_DAYS_AGO=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
if [[ -z "$SEVEN_DAYS_AGO" ]]; then
  exit 0  # Cannot compute date, skip
fi

# Query merged PRs with fix/ prefix
FIX_COUNT=0
FIX_PRS=""
while IFS= read -r pr_line; do
  [[ -z "$pr_line" ]] && continue
  pr_branch=$(echo "$pr_line" | jq -r '.headRefName // ""')
  pr_num=$(echo "$pr_line" | jq -r '.number // ""')

  # Check if this is a fix/ branch
  if ! echo "$pr_branch" | grep -qE '^fix/'; then
    continue
  fi

  # Extract prefix and compare
  pr_prefix=$(extract_feature_prefix "$pr_branch")
  if [[ "$pr_prefix" == "$CURRENT_PREFIX" ]]; then
    FIX_COUNT=$((FIX_COUNT + 1))
    FIX_PRS="${FIX_PRS}  - PR #${pr_num}: ${pr_branch}\n"
  fi
done < <(gh api "repos/${REPO}/pulls?state=closed&sort=updated&direction=desc&per_page=30" \
  --jq '.[] | select(.merged_at != null) | {headRefName, number}' 2>/dev/null | jq -c '.')

# --- Enforce: 2+ consecutive fixes → feature freeze ---
FREEZE_THRESHOLD=2
if [[ "$FIX_COUNT" -ge "$FREEZE_THRESHOLD" ]]; then
  echo "" >&2
  echo "🧊 [FEATURE FREEZE] feat PR作成をブロック。" >&2
  echo "   理由: 同一feature prefix '${CURRENT_PREFIX}' のfix PRが${FIX_COUNT}本検出。" >&2
  echo "   直近のfix PR:" >&2
  echo -e "$FIX_PRS" >&2
  echo "   対応:" >&2
  echo "   1. 既存のfix PRを全てマージ" >&2
  echo "   2. stabilization確認（テスト全パス）" >&2
  echo "   3. その後にfeat PRを作成" >&2
  echo "" >&2
  echo "   git-workflow.md: 同一feature系統のfollow-up fixが2本連続 → feature freeze" >&2
  echo "" >&2
  exit 2
fi

exit 0
