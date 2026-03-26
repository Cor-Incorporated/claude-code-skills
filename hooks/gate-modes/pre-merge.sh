#!/bin/bash
# pre-merge.sh — PRE_MERGE mode: Block PR merge without CI green + review
# =========================================================================
# Exit 0 = allow, Exit 2 = HARD BLOCK
# All output to stderr (Claude Code hooks spec)
# =========================================================================
set -euo pipefail

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh"

# DIAGNOSTIC: Log hook invocation
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) PRE_MERGE invoked. cmd=$(extract_cmd)" >> "${STATE_DIR}/pr-gate-diagnostic.log" 2>/dev/null
cmd=$(extract_cmd)

# Verify this is a gh pr merge command
if [[ -n "$cmd" ]] && ! echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+merge'; then
  exit 0
fi

# Extract PR number from command FIRST (before branch lookup)
PR_NUMBER=""
if [[ -n "$cmd" ]]; then
  PR_NUMBER=$(echo "$cmd" | grep -oE 'gh\s+pr\s+merge\s+([0-9]+)' | grep -oE '[0-9]+' || echo "")
fi
if [[ -z "$PR_NUMBER" ]]; then
  # Fallback: try current branch
  local_branch=$(current_branch)
  if [[ -n "$local_branch" ]]; then
    PR_NUMBER=$(gh pr list --head "$local_branch" --json number -q '.[0].number' 2>/dev/null || echo "")
  fi
fi

if [[ -z "$PR_NUMBER" ]]; then
  echo "🚫 [BLOCKED] PR番号を特定できません。明示的にPR番号を指定してください。" >&2
  exit 2
fi

# BUG FIX: Get the PR's HEAD branch from GitHub API, NOT local current_branch()
# current_branch() returns 'develop' when merging from develop, but we need
# the PR's source branch to check review-status.json correctly.
REPO_FOR_BRANCH=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
if [[ -n "$REPO_FOR_BRANCH" ]]; then
  BRANCH=$(_timeout 10 gh api "repos/${REPO_FOR_BRANCH}/pulls/${PR_NUMBER}" --jq '.head.ref' 2>/dev/null || echo "")
fi
if [[ -z "${BRANCH:-}" ]]; then
  BRANCH=$(current_branch)
fi
[[ -z "$BRANCH" ]] && { echo "[WARN] Cannot determine branch. Blocking PR merge." >&2; exit 2; }

# =========================================================================
# Tier detection FIRST (before CI check) — fixes #163
# EXEMPT tier must bypass CI failures to avoid chicken-and-egg problem
# (e.g., ci/* branch fixing a broken workflow can't merge if that
# workflow's CI failure blocks tier detection)
# =========================================================================
REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
HEAD_SHA=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")
TIER=$(classify_review_tier "$BRANCH" "${PR_NUMBER:-}")

if [[ "$TIER" == "EXEMPT" ]]; then
  echo "✅ PR #${PR_NUMBER}: EXEMPT tier ($BRANCH). CIグリーンのみで許可。" >&2
  exit 0
fi

# CI status check (non-EXEMPT tiers only)
if [[ -n "$REPO" ]] && [[ -n "$HEAD_SHA" ]]; then
  CI_FAILURES=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | select(.conclusion=="failure")] | length' 2>/dev/null || echo "0")
  CI_PENDING=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | select(.status!="completed")] | length' 2>/dev/null || echo "0")

  if [[ "$CI_FAILURES" -gt 0 ]]; then
    echo "🚫 [BLOCKED] CI に失敗ジョブあり ($CI_FAILURES 件)。修正してからマージしてください。" >&2
    exit 2
  fi
  if [[ "$CI_PENDING" -gt 0 ]]; then
    echo "🚫 [BLOCKED] CI に実行中ジョブあり ($CI_PENDING 件)。完了を待ってください。" >&2
    exit 2
  fi
fi

# =========================================================================
# 3-pass OR judgment (LIGHT) / AND judgment (FULL)
# Pass A: review-status.json has code_review: true (code-reviewer agent done)
# Pass B: pending-review-comments.json CRITICAL=0 AND HIGH=0
# Pass C: pr-review-lock.json has verified: true (manual/auto verified)
# FULL tier additionally requires Codex CLI second opinion
# =========================================================================
PASS_A="no"
PASS_B="no"
PASS_C="no"

# --- Pass A: code-reviewer agent completion ---
CODE_REVIEW=$(read_review "$BRANCH" "code_review")
[[ "$CODE_REVIEW" == "yes" ]] && PASS_A="yes"

# --- Pass B: No CRITICAL/HIGH in review comments ---
PENDING_FILE="$STATE_DIR/pending-review-comments.json"
if [[ -f "$PENDING_FILE" ]] && command -v jq &>/dev/null; then
  _pr_in_file=$(jq -r '.pr // ""' "$PENDING_FILE" 2>/dev/null || echo "")
  _head_sha_in_file=$(jq -r '.head_sha // ""' "$PENDING_FILE" 2>/dev/null || echo "")
  # Validate scope: pending-review-comments must match current PR
  if [[ "$_pr_in_file" == "$PR_NUMBER" ]] && [[ -n "$HEAD_SHA" ]] && [[ "$_head_sha_in_file" == "$HEAD_SHA" ]]; then
    _critical=$(jq -r '.critical // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
    _high=$(jq -r '.high // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
    _total=$(jq -r '.total // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
    if [[ "$_critical" -eq 0 ]] && [[ "$_high" -eq 0 ]] && [[ "$_total" -gt 0 ]]; then
      PASS_B="yes"
    fi
  fi
fi

# --- Pass C: Manual verification via pr-review-lock.json ---
if [[ -f "$LOCK_STATE" ]] && command -v jq &>/dev/null; then
  _verified=$(jq -r --arg pr "$PR_NUMBER" '.[$pr].verified // false' "$LOCK_STATE" 2>/dev/null || echo "false")
  [[ "$_verified" == "true" ]] && PASS_C="yes"
fi

# --- Tier-aware judgment ---
CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")

if [[ "$TIER" == "FULL" ]]; then
  # FULL tier: code-reviewer (A/B/C) AND Codex CLI required
  PASS_ANY="no"
  [[ "$PASS_A" == "yes" ]] || [[ "$PASS_B" == "yes" ]] || [[ "$PASS_C" == "yes" ]] && PASS_ANY="yes"

  if [[ "$PASS_ANY" == "yes" ]] && [[ "$CODEX_REVIEW" == "yes" ]]; then
    echo "✅ PR #${PR_NUMBER}: FULL tier 合格 (code-review✓ + Codex✓). マージ許可。" >&2
    exit 0
  fi

  MISSING=""
  [[ "$PASS_ANY" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
  [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "
  MISSING="${MISSING%, }"

  echo "" >&2
  echo "🚫 [BLOCKED] PR #${PR_NUMBER} のマージを拒否。レビュー未完了。" >&2
  echo "   ブランチ: $BRANCH | Tier: FULL" >&2
  echo "   未完了: $MISSING" >&2
  echo "   Pass A [${PASS_A}] | Pass B [${PASS_B}] | Pass C [${PASS_C}] | Codex [${CODEX_REVIEW}]" >&2
  echo "" >&2
  exit 2
else
  # LIGHT tier: 3-pass OR judgment
  if [[ "$PASS_A" == "yes" ]] || [[ "$PASS_B" == "yes" ]] || [[ "$PASS_C" == "yes" ]]; then
    PASSED=""
    [[ "$PASS_A" == "yes" ]] && PASSED="${PASSED}code-reviewer✓ "
    [[ "$PASS_B" == "yes" ]] && PASSED="${PASSED}C/H=0✓ "
    [[ "$PASS_C" == "yes" ]] && PASSED="${PASSED}verified✓ "
    echo "✅ PR #${PR_NUMBER}: LIGHT tier 3パスOR合格 (${PASSED}). マージ許可。" >&2
    exit 0
  fi

  echo "" >&2
  echo "🚫 [BLOCKED] PR #${PR_NUMBER} のマージを拒否。レビュー未完了。" >&2
  echo "   ブランチ: $BRANCH | Tier: LIGHT" >&2
  echo "   以下のいずれか1つが必要:" >&2
  echo "     A. code-reviewer エージェント完了 [${PASS_A}]" >&2
  echo "     B. CRITICAL/HIGH指摘ゼロ (レビュー実行済み) [${PASS_B}]" >&2
  echo "     C. 手動検証済み (verify-pr-review) [${PASS_C}]" >&2
  echo "" >&2
  echo "   解決方法:" >&2
  echo "     1. Agent tool (subagent_type=code-reviewer) → Pass A" >&2
  echo "     2. gh pr checks + レビューコメント全対応 → Pass B" >&2
  echo "     3. bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER} → Pass C" >&2
  echo "" >&2
  exit 2
fi
