#!/bin/bash
# pre-merge.sh — PRE_MERGE mode: consolidated gh pr merge gate (Phase 3)
# =========================================================================
# Exit 0 = allow, Exit 2 = HARD BLOCK
# All output to stderr (Claude Code hooks spec)
#
# Phase 3 consolidation — absorbs (do NOT weaken vs. the union):
#   * pr-merge-claude-review-gate.sh  → Gate 0 (CI completed),
#                                        Gate 1 (CI green),
#                                        Gate 2 (comments exist or fallback),
#                                        Gate 3 (review_read current — Issue #151),
#                                        Gate 4 (CRITICAL acknowledged)
#   * block-merge-without-ci.sh       → CI_TOTAL=0 fail-closed,
#                                        mergeable CONFLICTING block
#   * block-merge-without-review.sh   → FULL tier pessimistic lock,
#                                        CRITICAL/HIGH/BUG comment severity
#                                        (skipped when claude-review CI passes)
#
# Five unique logics that MUST be preserved (regression = security hole):
#   1. CI_TOTAL=0 fail-closed        (no-CI repos cannot merge)
#   2. mergeable CONFLICTING         (conflict PRs cannot merge)
#   3. BUG severity detection        ([BUG] line-level filter, Issue #142)
#   4. Gate 3 review_read            (pr-review-read.json, Issue #151)
#   5. PR auto-close self-heal       (purge stale pending-review state)
#
# API call reduction: a single check-runs fetch feeds CI_TOTAL / failures /
# pending / claude-review-conclusion (was 5 separate gh calls across the
# three retired hooks).
# =========================================================================
set -euo pipefail

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh"

# DIAGNOSTIC: Log hook invocation
cmd=$(extract_cmd)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) PRE_MERGE invoked. cmd=${cmd}" >> "${STATE_DIR}/pr-gate-diagnostic.log" 2>/dev/null || true

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
if should_block_unparsed_pr_merge "$cmd" "$MERGE_COUNT"; then
  print_unparsed_pr_merge_block
  exit 2
fi
if [[ "$MERGE_COUNT" -eq 0 ]]; then
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
if [[ -z "$HEAD_SHA" || "$HEAD_SHA" == "null" ]]; then
  echo "🚫 [BLOCKED] PR #${PR_NUMBER}: HEAD SHA を取得できません。" >&2
  echo "  現在のPR headに対するレビュー証拠を検証できないため、fail closedします。" >&2
  echo "  確認: gh pr view ${PR_NUMBER} -R ${REPO} --json headRefOid" >&2
  exit 2
fi
BASE_SHA=""
if [[ -n "$BASE_REF" ]]; then
  BASE_SHA=$(_timeout 10 gh api "repos/${REPO}/git/ref/heads/${BASE_REF}" --jq '.object.sha' 2>/dev/null || echo "")
fi
[[ -n "$BASE_SHA" ]] || BASE_SHA=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.base.sha' 2>/dev/null || echo "")
ensure_pr_base_fresh "$REPO" "$PR_NUMBER" "$BASE_REF" "$BASE_SHA" || exit 2
TIER=$(classify_review_tier "$BRANCH" "${PR_NUMBER:-}")

# =========================================================================
# CONSOLIDATED CI GATE — Gate 0 + Gate 1 + (CI_TOTAL=0 fail-closed) +
# mergeable CONFLICTING. Single check-runs fetch, multi-pass jq.
# EXEMPT tier skips Gate 0/1 only (chicken-and-egg, fix #163); EXEMPT still
# must pass Gate 2/3/4 + 3-pass judgment below.
# =========================================================================
if [[ "$TIER" != "EXEMPT" ]]; then
  CHECK_RUNS_JSON=""
  if [[ -n "$REPO" ]] && [[ -n "$HEAD_SHA" ]]; then
    CHECK_RUNS_JSON=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" 2>/dev/null || echo "")
  fi
  if [[ -z "$CHECK_RUNS_JSON" ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] PR #${PR_NUMBER}: check-runs API を取得できませんでした（タイムアウトまたはAPI障害）。" >&2
    echo "  fail-closed でマージを拒否します。確認: gh pr checks ${PR_NUMBER} -R ${REPO}" >&2
    echo "" >&2
    exit 2
  fi

  EXCL="${NON_CI_CHECK_PATTERN}"
  CI_TOTAL=$(printf '%s' "$CHECK_RUNS_JSON" \
    | jq "[.check_runs[] | select(.name | test(\"${EXCL}\"; \"i\") | not)] | length" 2>/dev/null || echo "0")
  CI_FAILURES=$(printf '%s' "$CHECK_RUNS_JSON" \
    | jq "[.check_runs[] | select((.name | test(\"${EXCL}\"; \"i\") | not) and .conclusion==\"failure\")] | length" 2>/dev/null || echo "0")
  CI_PENDING=$(printf '%s' "$CHECK_RUNS_JSON" \
    | jq "[.check_runs[] | select((.name | test(\"${EXCL}\"; \"i\") | not) and .status!=\"completed\")] | length" 2>/dev/null || echo "0")
  CLAUDE_REVIEW_CI=$(printf '%s' "$CHECK_RUNS_JSON" \
    | jq -r '[.check_runs[] | select(.name | test("claude-review"; "i"))] | .[0].conclusion // ""' 2>/dev/null || echo "")

  # Logic 1: CI_TOTAL=0 fail-closed (from block-merge-without-ci.sh)
  if [[ "$CI_TOTAL" -eq 0 ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] PR #${PR_NUMBER} にCIチェックがありません。" >&2
    echo "  CIが設定されたリポジトリでのみマージできます。確認: gh pr view ${PR_NUMBER} --json mergeable,mergeStateStatus" >&2
    echo "" >&2
    exit 2
  fi

  # Gate 1: CI failures
  if [[ "$CI_FAILURES" -gt 0 ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] CI に失敗ジョブあり ($CI_FAILURES 件)" >&2
    echo "  WHY: マージ前にCI全ジョブの成功を確認する必要があります (Epic #130)" >&2
    echo "  FIX: gh pr checks ${PR_NUMBER} で失敗ジョブを特定し、修正してください" >&2
    echo "  NOTE: Agent/copilot/dependabot/CodeRabbit は自動除外済み" >&2
    echo "" >&2
    exit 2
  fi

  # Gate 0: CI pending
  if [[ "$CI_PENDING" -gt 0 ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] CI に実行中ジョブあり ($CI_PENDING 件)" >&2
    echo "  WHY: マージ前にCI全ジョブの完了を確認する必要があります (Epic #130)" >&2
    echo "  FIX: gh pr checks ${PR_NUMBER} --watch で完了を待ってください" >&2
    echo "  NOTE: Agent/copilot/dependabot/CodeRabbit は自動除外済み" >&2
    echo "" >&2
    exit 2
  fi

  # Logic 2: mergeable CONFLICTING (from block-merge-without-ci.sh)
  MERGEABLE=$(pr_mergeable_state "$REPO" "$PR_NUMBER")
  if [[ "$MERGEABLE" == "conflicting" ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] PR #${PR_NUMBER} にコンフリクトがあります。リベースで解決してください。" >&2
    echo "  確認: gh pr view ${PR_NUMBER} -R ${REPO} --json mergeable,mergeStateStatus" >&2
    echo "" >&2
    exit 2
  fi
else
  # EXEMPT still needs claude-review conclusion for the severity skip path below.
  CLAUDE_REVIEW_CI=""
  if [[ -n "$REPO" ]] && [[ -n "$HEAD_SHA" ]]; then
    CLAUDE_REVIEW_CI=$(claude_review_ci_conclusion "$REPO" "$HEAD_SHA" "")
  fi
fi

# =========================================================================
# Review Hierarchy: Tier 1 PRIMARY_LGTM check (#175)
# =========================================================================
PRIMARY_LGTM="false"
_code_rev=$(read_review_for_head "$BRANCH" "code_review" "$HEAD_SHA")
_codex_rev=$(read_review_for_head "$BRANCH" "codex_review" "$HEAD_SHA")
if [[ "$_code_rev" == "yes" ]] && [[ "$_codex_rev" == "yes" ]]; then
  PRIMARY_LGTM="true"
fi

# =========================================================================
# FULL tier pessimistic lock (from block-merge-without-review.sh)
# Read BOTH project-scoped AND global lock files (OR-logic via common.sh).
# Tier 1 PRIMARY_LGTM bypasses the lock (reviewer + Codex already verified).
# =========================================================================
if [[ "$TIER" == "FULL" ]] && [[ "$PRIMARY_LGTM" != "true" ]]; then
  if [[ "$(lock_pr_locked_for_head "$PR_NUMBER" "$HEAD_SHA" "$REPO")" == "yes" ]]; then
    echo "" >&2
    echo "🔒 [Pessimistic Lock] PR #${PR_NUMBER} は review_pending 状態です。マージ不可。" >&2
    echo "  push後のclaude-review 3ソース全確認が未完了です。" >&2
    echo "  解除: bash ~/.claude/scripts/verify-pr-review.sh ${PR_NUMBER}" >&2
    echo "  または /review-loop ${PR_NUMBER} で自動検証" >&2
    echo "" >&2
    exit 2
  fi
fi

# =========================================================================
# Logic 5: PR auto-close self-heal + Tier 1 PRIMARY_LGTM override.
# If pending-review-comments.json references a closed/merged PR, purge it.
# If the file references another OPEN PR, ignore it for this PR's judgment.
# PRIMARY_LGTM then overrides Tier 2 (pending-review-comments) findings.
# =========================================================================
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
fi

if [[ "$PRIMARY_LGTM" == "true" ]]; then
  # Validate pending-review-comments.json scope (Issue #165 comment_set_hash).
  if [[ -f "$PENDING_FILE" ]] && command -v jq &>/dev/null; then
    _primary_pr_in_file=$(jq -r '.pr // ""' "$PENDING_FILE" 2>/dev/null || echo "")
    if [[ "$_primary_pr_in_file" == "$PR_NUMBER" ]]; then
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
  exit 0
fi

# =========================================================================
# Logic 3: CRITICAL/HIGH/BUG comment severity (from block-merge-without-review.sh)
# Issue #165: skip comment-based detection when claude-review CI passed
# (residual bot comments should not block a clean latest CI).
# Gate 4 (CRITICAL acknowledgement) is folded in: if CRITICAL is detected
# and not yet acknowledged in pr-review-read.json, block.
# =========================================================================
if [[ "$CLAUDE_REVIEW_CI" != "success" ]]; then
  _bodies=$(pr_comment_bodies "$REPO" "$PR_NUMBER")
  HAS_CRITICAL=$(printf '%s' "$_bodies" | detect_critical_severity)
  HAS_HIGH=$(printf '%s' "$_bodies" | detect_high_severity)
  HAS_BUG=$(printf '%s' "$_bodies" | detect_bug_severity)

  BLOCKERS=""
  [[ "$HAS_CRITICAL" -gt 0 ]] && BLOCKERS="${BLOCKERS}CRITICAL($HAS_CRITICAL) "
  [[ "$HAS_HIGH" -gt 0 ]] && BLOCKERS="${BLOCKERS}HIGH($HAS_HIGH) "
  [[ "$HAS_BUG" -gt 0 ]] && BLOCKERS="${BLOCKERS}BUG($HAS_BUG) "

  if [[ -n "$BLOCKERS" ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] PR #${PR_NUMBER} にブロッカー指摘があります: ${BLOCKERS}(tier=$TIER)" >&2
    echo "  全レビューソースを確認してください:" >&2
    echo "    gh api repos/${REPO}/pulls/${PR_NUMBER}/comments" >&2
    echo "    gh api repos/${REPO}/issues/${PR_NUMBER}/comments" >&2
    echo "" >&2
    exit 2
  fi

  # Gate 4: CRITICAL findings must be acknowledged (Issue #154).
  # If detected (either via comment grep OR has_critical flag in state),
  # critical_acknowledged must be set current in pr-review-read.json.
  _has_critical_flag=$(review_read_current_bool "$PR_NUMBER" "has_critical" "$HEAD_SHA" "$REPO")
  if [[ "$HAS_CRITICAL" -gt 0 ]] || [[ "$_has_critical_flag" == "True" ]]; then
    _critical_ack=$(review_read_current_bool "$PR_NUMBER" "critical_acknowledged" "$HEAD_SHA" "$REPO")
    if [[ "$_critical_ack" != "True" ]]; then
      echo "" >&2
      echo "🚫 [BLOCKED] PR #${PR_NUMBER}: CRITICAL 指摘が未対応です。" >&2
      echo "  修正を push し、レビューを再確認したうえで正規フローを完了してください。" >&2
      echo "  code-reviewer の再実行、または必要な確認後に VERIFY を再実行してください:" >&2
      echo "  bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER}" >&2
      echo "" >&2
      exit 2
    fi
  fi
fi

# =========================================================================
# Gate 2: Review comment must exist (Claude Review) or fallback done.
# (from pr-merge-claude-review-gate.sh Gate 2)
# =========================================================================
COMMENT_COUNT=$(pr_issue_comment_count "$REPO" "$PR_NUMBER")
if [[ "$COMMENT_COUNT" -eq 0 ]]; then
  _fallback_done=$(review_read_current_bool "$PR_NUMBER" "fallback_review_done" "$HEAD_SHA" "$REPO")
  if [[ "$_fallback_done" != "True" ]]; then
    echo "" >&2
    echo "🚫 [BLOCKED] PR #${PR_NUMBER}: レビューコメントが存在しません。" >&2
    echo "  Claude Review workflow のコメントが見つかりません。" >&2
    echo "  以下のいずれかを実行してください:" >&2
    echo "    A) Claude Review の完了を待つ（workflow が設定されている場合）" >&2
    echo "       gh pr checks ${PR_NUMBER} -R ${REPO}" >&2
    echo "    B) code-reviewer エージェントで代替レビューを実行:" >&2
    echo "       Agent(subagent_type='code-reviewer', prompt='Review PR #${PR_NUMBER} ...')" >&2
    echo "       完了後、必要に応じて VERIFY を実行してから再試行してください:" >&2
    echo "       bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER}" >&2
    echo "" >&2
    exit 2
  fi
fi

# =========================================================================
# Logic 4: Gate 3 review_read (Issue #151) — from pr-merge-claude-review-gate.sh.
# pr-review-read.json must have review_read=true with current head_sha.
# =========================================================================
REVIEW_READ_STATE=$(review_read_field_state "$PR_NUMBER" "review_read" "$HEAD_SHA" "$REPO")
if [[ "$REVIEW_READ_STATE" != "current" ]]; then
  echo "" >&2
  if [[ "$REVIEW_READ_STATE" == "stale" ]]; then
    echo "🚫 [BLOCKED] PR #${PR_NUMBER}: レビュー既読証跡が現在の head_sha と一致しません。" >&2
    echo "  現在の head_sha: ${HEAD_SHA}" >&2
    echo "  push 後に古い既読証跡が残っている可能性があります。" >&2
  elif [[ "$REVIEW_READ_STATE" == "foreign" ]]; then
    echo "🚫 [BLOCKED] PR #${PR_NUMBER}: レビュー既読証跡が別リポジトリのものです。" >&2
    echo "  対象 repo: ${REPO}" >&2
    echo "  同じPR番号を持つ別リポジトリの state を merge 根拠にはできません (Issue #258)。" >&2
  else
    echo "🚫 [BLOCKED] PR #${PR_NUMBER}: レビューを未読のままマージしようとしています。" >&2
  fi
  echo "" >&2
  echo "  以下を実行してください（レビュー読み取り＋既読マークを一括で行います）:" >&2
  echo "     bash ~/.claude/scripts/verify-pr-review.sh ${PR_NUMBER} ${REPO}" >&2
  echo "  ※ verify-pr-review.sh はレビュー内容を表示し、問題なければ自動で既読マークします。" >&2
  echo "  ※ 直接 pr-review-read.json を書き換える必要はありません (Issue #151)。" >&2
  echo "" >&2
  exit 2
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
CODE_REVIEW=$(read_review_for_head "$BRANCH" "code_review" "$HEAD_SHA")
[[ "$CODE_REVIEW" == "yes" ]] && PASS_A="yes"

# --- Pass B: No CRITICAL/HIGH in review comments ---
if [[ -f "$PENDING_FILE" ]] && command -v jq &>/dev/null; then
  _pr_in_file=$(jq -r '.pr // ""' "$PENDING_FILE" 2>/dev/null || echo "")
  _head_sha_in_file=$(jq -r '.head_sha // ""' "$PENDING_FILE" 2>/dev/null || echo "")
  _repo_in_file=$(jq -r '.repo // ""' "$PENDING_FILE" 2>/dev/null || echo "")
  [[ -n "$_repo_in_file" && "$_repo_in_file" != "null" ]] || _repo_in_file="$REPO"

  # A pending file for another PR must not approve or block this merge. The
  # closed/merged purge already ran above; remaining mismatched files are
  # informational only and ignored here.
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
[[ "$(lock_pr_verified_for_head "$PR_NUMBER" "$HEAD_SHA" "$REPO")" == "yes" ]] && PASS_C="yes"

# --- Tier-aware judgment ---
CODEX_REVIEW=$(read_review_for_head "$BRANCH" "codex_review" "$HEAD_SHA")

# Issue #203: Severity-aware Codex override (consistent with pre-create.sh)
# Policy: CRITICAL/HIGH → block, MEDIUM/LOW → follow-up Issue (not a blocker)
if [[ "$CODEX_REVIEW" != "yes" ]]; then
  _codex_ran=$(read_review_for_head "$BRANCH" "codex_review_ran" "$HEAD_SHA")
  _codex_critical=$(read_codex_severity_for_head "$BRANCH" "codex_critical" "$HEAD_SHA")
  _codex_high=$(read_codex_severity_for_head "$BRANCH" "codex_high" "$HEAD_SHA")
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
