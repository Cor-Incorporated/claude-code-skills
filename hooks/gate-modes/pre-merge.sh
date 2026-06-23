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
# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

# Verify this is a gh pr merge command anywhere in the Bash payload.
MERGE_COUNT=0
if [[ -n "$cmd" ]]; then
  MERGE_COUNT=$(count_gh_pr_merge_invocations "$cmd" || echo 0)
fi
if [[ "$MERGE_COUNT" -eq 0 ]]; then
  if should_block_unparsed_pr_merge "$cmd" "$MERGE_COUNT"; then
    print_unparsed_pr_merge_block
    exit 2
  fi
  exit 0
fi

_cmd_context=$(command_git_context_dir "$cmd")
if [[ -n "$_cmd_context" ]]; then
  export GIT_CONTEXT_DIR="$_cmd_context"
  use_git_context_state_dir
fi

# Extract PR number from command FIRST (before branch lookup)
PR_NUMBER=""
if [[ -n "$cmd" ]]; then
  PR_NUMBER=$(extract_gh_pr_merge_target "$cmd" || echo "")
  if [[ "$MERGE_COUNT" -gt 1 || "$PR_NUMBER" == "__MULTIPLE__" ]]; then
    echo "🚫 [BLOCKED] 1つのBashコマンドに複数の gh pr merge が含まれています。PRごとに個別実行してください。" >&2
    exit 2
  fi
  if [[ "$PR_NUMBER" == __NON_NUMERIC__:* ]]; then
    echo "🚫 [BLOCKED] PR番号を特定できません。非数値の gh pr merge target は安全に検証できないため、PR番号を指定してください。" >&2
    echo "  target: ${PR_NUMBER#__NON_NUMERIC__:}" >&2
    exit 2
  fi
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
REPO_FOR_BRANCH=$(resolve_repo "$cmd")
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
REPO=$(resolve_repo "$cmd")
HEAD_SHA=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")
BASE_REF=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.base.ref' 2>/dev/null || echo "")
BASE_SHA=""
if [[ -n "$BASE_REF" ]]; then
  BASE_SHA=$(_timeout 10 gh api "repos/${REPO}/git/ref/heads/${BASE_REF}" --jq '.object.sha' 2>/dev/null || echo "")
fi
[[ -n "$BASE_SHA" ]] || BASE_SHA=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.base.sha' 2>/dev/null || echo "")
ensure_pr_base_fresh "$REPO" "$PR_NUMBER" "$BASE_REF" "$BASE_SHA" || exit 2
TIER=$(classify_review_tier "$BRANCH" "${PR_NUMBER:-}")

if [[ "$TIER" == "EXEMPT" ]]; then
  echo "✅ PR #${PR_NUMBER}: EXEMPT tier ($BRANCH). CIグリーンのみで許可。" >&2
  exit 0
fi

# CI status check (non-EXEMPT tiers only)
if [[ -n "$REPO" ]] && [[ -n "$HEAD_SHA" ]]; then
  CI_FAILURES=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq "$(jq_ci_failures_filter)" 2>/dev/null || echo "0")
  CI_PENDING=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq "$(jq_ci_pending_filter)" 2>/dev/null || echo "0")

  if [[ "$CI_FAILURES" -gt 0 ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] CI に失敗ジョブあり ($CI_FAILURES 件)" >&2
    echo "  WHY: マージ前にCI全ジョブの成功を確認する必要があります (Epic #130)" >&2
    echo "  FIX: gh pr checks ${PR_NUMBER} で失敗ジョブを特定し、修正してください" >&2
    echo "  NOTE: Agent/copilot/dependabot/CodeRabbit は自動除外済み" >&2
    echo "" >&2
    exit 2
  fi
  if [[ "$CI_PENDING" -gt 0 ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] CI に実行中ジョブあり ($CI_PENDING 件)" >&2
    echo "  WHY: マージ前にCI全ジョブの完了を確認する必要があります (Epic #130)" >&2
    echo "  FIX: gh pr checks ${PR_NUMBER} --watch で完了を待ってください" >&2
    echo "  NOTE: Agent/copilot/dependabot/CodeRabbit は自動除外済み" >&2
    echo "" >&2
    exit 2
  fi
fi

# =========================================================================
# Review Hierarchy: Tier 1 PRIMARY_LGTM check (#175)
# =========================================================================
PRIMARY_LGTM="false"
_code_rev=$(read_review "$BRANCH" "code_review")
_codex_rev=$(read_review "$BRANCH" "codex_review")
if [[ "$_code_rev" == "yes" ]] && [[ "$_codex_rev" == "yes" ]]; then
  PRIMARY_LGTM="true"
  echo "  ✅ [pre-merge] Tier 1 LGTM: code-reviewer + Codex CLI 確認済み" >&2
fi

# Tier 2 LGTM check from pending-review-comments.json
TIER2_LGTM="false"
PENDING_FILE="$STATE_DIR/pending-review-comments.json"
if [[ -f "$PENDING_FILE" ]] && command -v jq &>/dev/null; then
  _t2=$(jq -r '.tier2_lgtm // false' "$PENDING_FILE" 2>/dev/null || echo "false")
  if [[ "$_t2" == "true" ]]; then
    TIER2_LGTM="true"
  fi
fi

# PRIMARY_LGTM override: Tier 1 trust bypasses Tier 2 severity
if [[ "$PRIMARY_LGTM" == "true" ]]; then
  PENDING_FILE="$STATE_DIR/pending-review-comments.json"
  if [[ -f "$PENDING_FILE" ]] && command -v jq &>/dev/null; then
    _primary_pr_in_file=$(jq -r '.pr // ""' "$PENDING_FILE" 2>/dev/null || echo "")
    _primary_head_sha_in_file=$(jq -r '.head_sha // ""' "$PENDING_FILE" 2>/dev/null || echo "")
    _primary_repo_in_file=$(jq -r '.repo // ""' "$PENDING_FILE" 2>/dev/null || echo "")
    [[ -n "$_primary_repo_in_file" && "$_primary_repo_in_file" != "null" ]] || _primary_repo_in_file="$REPO"

    if [[ -n "$_primary_pr_in_file" && "$_primary_pr_in_file" != "null" && "$_primary_pr_in_file" != "$PR_NUMBER" ]]; then
      _primary_pending_state=$(pending_review_pr_state "$PENDING_FILE" "$_primary_repo_in_file" || echo "")
      if [[ "$_primary_pending_state" == "closed" ]] || [[ "$_primary_pending_state" == "merged" ]]; then
        purge_pending_review_state "$PENDING_FILE"
        echo "  ℹ️ [pre-merge] closed/merged PR #${_primary_pr_in_file} の stale pending-review-comments.json を削除しました。" >&2
      else
        echo "  ℹ️ [pre-merge] pending-review-comments.json は別PR #${_primary_pr_in_file} の state のため、PR #${PR_NUMBER} の判定には使いません。" >&2
      fi
    fi

    if [[ "$_primary_pr_in_file" == "$PR_NUMBER" ]]; then
      if [[ -z "$HEAD_SHA" ]]; then
        echo "🚫 [BLOCKED] PR #${PR_NUMBER}: HEAD SHA を確認できないため pending-review-comments.json を検証できません。" >&2
        exit 2
      fi
      if [[ "$_primary_head_sha_in_file" != "$HEAD_SHA" ]]; then
        echo "🚫 [LOCAL_GATE_STALE_REVIEW_STATE] PR #${PR_NUMBER}: pending-review-comments.json が古い HEAD を参照しています。" >&2
        echo "  GitHub mergeable 判定とは別の local gate blocker です。" >&2
        echo "  復旧: gh pr checks ${PR_NUMBER} -R ${REPO} を再実行し、最新レビュー state を取得してください。" >&2
        exit 2
      fi
      if ! pending_comment_set_current "$PENDING_FILE" "$REPO" "$PR_NUMBER" "$HEAD_SHA"; then
        echo "🚫 [LOCAL_GATE_STALE_REVIEW_STATE] PR #${PR_NUMBER}: pending-review-comments.json が現在のレビューコメント集合と一致しません。" >&2
        echo "  GitHub mergeable 判定とは別の local gate blocker です。" >&2
        echo "  復旧: gh pr checks ${PR_NUMBER} -R ${REPO} を再実行し、最新レビュー state を取得してください。" >&2
        exit 2
      fi
    fi
  fi
  echo "  ℹ️ [pre-merge] Tier 1 LGTM により Tier 2 findings を許可。マージ可。" >&2
  # Still record the review status
  exit 0
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
  _repo_in_file=$(jq -r '.repo // ""' "$PENDING_FILE" 2>/dev/null || echo "")
  [[ -n "$_repo_in_file" && "$_repo_in_file" != "null" ]] || _repo_in_file="$REPO"

  # A pending file for another PR must not approve or block this merge. If
  # GitHub confirms that PR is already closed/merged, purge the local residue.
  if [[ -n "$_pr_in_file" && "$_pr_in_file" != "null" && "$_pr_in_file" != "$PR_NUMBER" ]]; then
    _pending_state=$(pending_review_pr_state "$PENDING_FILE" "$_repo_in_file" || echo "")
    if [[ "$_pending_state" == "closed" ]] || [[ "$_pending_state" == "merged" ]]; then
      purge_pending_review_state "$PENDING_FILE"
      echo "  ℹ️ [pre-merge] closed/merged PR #${_pr_in_file} の stale pending-review-comments.json を削除しました。" >&2
    else
      echo "  ℹ️ [pre-merge] pending-review-comments.json は別PR #${_pr_in_file} の state のため、PR #${PR_NUMBER} の判定には使いません。" >&2
    fi
  fi

  # Validate scope: pending-review-comments must match current PR
  if [[ "$_pr_in_file" == "$PR_NUMBER" ]]; then
    if [[ -z "$HEAD_SHA" ]]; then
      echo "🚫 [BLOCKED] PR #${PR_NUMBER}: HEAD SHA を確認できないため pending-review-comments.json を検証できません。" >&2
      exit 2
    fi
    if [[ "$_head_sha_in_file" != "$HEAD_SHA" ]]; then
      echo "🚫 [LOCAL_GATE_STALE_REVIEW_STATE] PR #${PR_NUMBER}: pending-review-comments.json が古い HEAD を参照しています。" >&2
      echo "  GitHub mergeable 判定とは別の local gate blocker です。" >&2
      echo "  復旧: gh pr checks ${PR_NUMBER} -R ${REPO} を再実行し、最新レビュー state を取得してください。" >&2
      exit 2
    fi
    if ! pending_comment_set_current "$PENDING_FILE" "$REPO" "$PR_NUMBER" "$HEAD_SHA"; then
      echo "🚫 [LOCAL_GATE_STALE_REVIEW_STATE] PR #${PR_NUMBER}: pending-review-comments.json が現在のレビューコメント集合と一致しません。" >&2
      echo "  GitHub mergeable 判定とは別の local gate blocker です。" >&2
      echo "  復旧: gh pr checks ${PR_NUMBER} -R ${REPO} を再実行し、最新レビュー state を取得してください。" >&2
      exit 2
    else
      # Issue #165: Check classification_method — prefer AI classification if available
      _method=$(jq -r '.classification_method // "regex"' "$PENDING_FILE" 2>/dev/null || echo "regex")
      if [[ "$_method" == "ai" ]]; then
        _critical=$(jq -r '.ai_classification.critical // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
        _high=$(jq -r '.ai_classification.high // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
      else
        _critical=$(jq -r '.critical // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
        _high=$(jq -r '.high // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
      fi
      _total=$(jq -r '.total // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
      if [[ "$_critical" -eq 0 ]] && [[ "$_high" -eq 0 ]] && [[ "$_total" -gt 0 ]]; then
        PASS_B="yes"
      fi
    fi
  fi
fi

# --- Pass C: Manual verification via pr-review-lock.json (Fix8 dual-location) ---
# Check BOTH project-scoped AND global lock files (OR-logic) so a verified=true
# written to either location releases the gate.
[[ "$(lock_pr_verified "$PR_NUMBER")" == "yes" ]] && PASS_C="yes"

# --- Tier-aware judgment ---
CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")

# Issue #203: Severity-aware Codex override (consistent with pre-create.sh)
# Policy: CRITICAL/HIGH → block, MEDIUM/LOW → follow-up Issue (not a blocker)
if [[ "$CODEX_REVIEW" != "yes" ]]; then
  _codex_ran=$(read_review "$BRANCH" "codex_review_ran")
  _codex_critical=$(read_codex_severity "$BRANCH" "codex_critical")
  _codex_high=$(read_codex_severity "$BRANCH" "codex_high")
  if [[ "$_codex_ran" == "yes" ]] && \
     [[ "$_codex_critical" != "-1" ]] && [[ "$_codex_critical" -eq 0 ]] 2>/dev/null && \
     [[ "$_codex_high" != "-1" ]] && [[ "$_codex_high" -eq 0 ]] 2>/dev/null; then
    CODEX_REVIEW="yes"
  fi
fi

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
