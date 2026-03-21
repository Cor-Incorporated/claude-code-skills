#!/bin/bash
# =============================================================================
# CI/CD & Review Comment Check Enforcement Hook (PostToolUse)
# =============================================================================
# After a PR is created via `gh pr create`, reminds the agent to:
# 1. Wait for all CI/CD checks to pass
# 2. Read and evaluate all PR review comments (Claude Review etc.)
#
# Both conditions must be met before reporting "all green" to user.
#
# Exit codes:
#   0 = success (outputs JSON with CI + review reminder)
# =============================================================================

set -euo pipefail

input=$(cat)
tool_output=$(echo "$input" | jq -r '.tool_output.stdout // .tool_output // ""')

# Extract PR URL from the output
pr_url=$(echo "$tool_output" | grep -oE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | head -1 || echo "")

if [ -z "$pr_url" ]; then
    exit 0
fi

# Extract owner/repo and PR number
pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
repo_path=$(echo "$pr_url" | sed 's|https://github.com/||' | sed 's|/pull/[0-9]*||')

echo "" >&2
echo "========================================" >&2
echo " [CI/CD + Review] PR #${pr_num}" >&2
echo "========================================" >&2
echo "" >&2
echo "STEP 1: CI/CD チェック（必須）" >&2
echo "  gh pr checks ${pr_num} --watch" >&2
echo "" >&2
echo "STEP 2: レビューコメント確認（必須）" >&2
echo "  gh api repos/${repo_path}/pulls/${pr_num}/comments" >&2
echo "  gh api repos/${repo_path}/pulls/${pr_num}/reviews" >&2
echo "  gh pr view ${pr_num} --comments --json comments" >&2
echo "" >&2
echo "STEP 3: 評価" >&2
echo "  CRITICAL/HIGH → 修正必須（マージブロッカー）" >&2
echo "  MEDIUM → 可能な限り修正" >&2
echo "  LOW/INFO → 対応任意" >&2
echo "" >&2
echo "CI/CDグリーン + レビューCRITICAL/HIGHゼロ = オールグリーン" >&2
echo "========================================" >&2

exit 0
