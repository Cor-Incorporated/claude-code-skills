#!/bin/bash
# verify.sh — VERIFY mode: Manual verification (called by agent after review)
# =========================================================================
# Exit 0 = verified, Exit 1 = verification failed
# All output to stderr (Claude Code hooks spec)
# =========================================================================
set -euo pipefail

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh"

PR="${VERIFY_PR_NUMBER:-${2:-${PR_NUMBER:-}}}"
[ -z "$PR" ] && { echo "Usage: $0 VERIFY <PR_NUMBER>" >&2; exit 1; }

REPO=$(resolve_repo "")
HEAD_SHA=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR}" --jq '.head.sha' 2>/dev/null || echo "")
if [[ -z "$REPO" ]] || [[ -z "$HEAD_SHA" ]]; then
  echo "⚠️ PR #${PR}: リポジトリ/SHA取得失敗。手動確認してください。" >&2
  exit 1
fi

CI_FAILURES=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
  --jq "$(jq_ci_failures_filter)" 2>/dev/null || echo "0")
CI_PENDING=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
  --jq "$(jq_ci_pending_filter)" 2>/dev/null || echo "0")

if [[ "$CI_FAILURES" -gt 0 ]]; then
  echo "" >&2
  echo "🚫 [BLOCKED] PR #${PR}: CI に失敗ジョブあり ($CI_FAILURES 件)" >&2
  echo "  WHY: マージ前にCI全ジョブの成功を確認する必要があります (Epic #130)" >&2
  echo "  FIX: gh pr checks ${PR} で失敗ジョブを特定し、修正してください" >&2
  echo "  NOTE: Agent/copilot/dependabot/CodeRabbit は自動除外済み" >&2
  echo "" >&2
  exit 1
fi
if [[ "$CI_PENDING" -gt 0 ]]; then
  echo "" >&2
  echo "⏳ [BLOCKED] PR #${PR}: CI に実行中ジョブあり ($CI_PENDING 件)" >&2
  echo "  WHY: マージ前にCI全ジョブの完了を確認する必要があります (Epic #130)" >&2
  echo "  FIX: gh pr checks ${PR} --watch で完了を待ってください" >&2
  echo "  NOTE: Agent/copilot/dependabot/CodeRabbit は自動除外済み" >&2
  echo "" >&2
  exit 1
fi

# Read branch from ANY lock file (project or global) — Fix8 dual-location
BRANCH=""
while IFS= read -r _lf; do
  [[ -z "$_lf" || ! -f "$_lf" ]] && continue
  BRANCH=$(_LOCK="$_lf" _PR="$PR" python3 -c "
import json, os
try:
    with open(os.environ['_LOCK']) as f: s = json.load(f)
    print(s.get(os.environ['_PR'], {}).get('branch', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")
  [[ -n "$BRANCH" ]] && break
done < <(lock_files)

# If branch not in lock state, try GitHub API
if [[ -z "$BRANCH" ]]; then
  BRANCH=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR}" --jq '.head.ref' 2>/dev/null || echo "")
fi

# Classify review tier
TIER=$(classify_review_tier "$BRANCH" "${PR:-}")

# EXEMPT tier: CI green is sufficient, no review needed
if [[ "$TIER" == "EXEMPT" ]]; then
  echo "✅ PR #${PR}: EXEMPT tier — CI green確認済み。" >&2
else
  CODE_REVIEW=$(read_review_for_head "$BRANCH" "code_review" "$HEAD_SHA")
  CODEX_REVIEW=$(read_review_for_head "$BRANCH" "codex_review" "$HEAD_SHA")

  # Issue #60 Bug B: Also check pending-review-comments.json (claude-review results)
  # If claude-review reported CRITICAL/HIGH=0, treat as review passed
  if [[ "$CODE_REVIEW" != "yes" ]]; then
    PENDING_FILE="$STATE_DIR/pending-review-comments.json"
    GLOBAL_PENDING="$HOME/.claude/state/pending-review-comments.json"
    for pf in "$PENDING_FILE" "$GLOBAL_PENDING"; do
      if [[ -f "$pf" ]] && command -v jq &>/dev/null; then
        PR_MATCH=$(jq -r --arg p "$PR" '.pr // ""' "$pf" 2>/dev/null)
        PENDING_HEAD_SHA=$(jq -r '.head_sha // ""' "$pf" 2>/dev/null)
        # Issue #165: Check classification_method — prefer AI classification
        _vmethod=$(jq -r '.classification_method // "regex"' "$pf" 2>/dev/null || echo "regex")
        if [[ "$_vmethod" == "ai" ]]; then
          CR=$(jq -r '.ai_classification.critical // 0' "$pf" 2>/dev/null)
          HI=$(jq -r '.ai_classification.high // 0' "$pf" 2>/dev/null)
        else
          CR=$(jq -r '.critical // 0' "$pf" 2>/dev/null)
          HI=$(jq -r '.high // 0' "$pf" 2>/dev/null)
        fi
        if [[ "$PR_MATCH" == "$PR" ]] && [[ -n "$HEAD_SHA" ]] && [[ "$PENDING_HEAD_SHA" == "$HEAD_SHA" ]] && [[ "$CR" == "0" ]] && [[ "$HI" == "0" ]]; then
          CODE_REVIEW="yes"
          echo "  ℹ️ claude-review CRITICAL/HIGH=0 → code_review=yes として扱う" >&2
          break
        fi
      fi
    done
  fi

  MISSING=""
  [[ "$CODE_REVIEW" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
  if [[ "$TIER" == "FULL" ]]; then
    [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "
  fi

  if [[ -n "$MISSING" ]]; then
    echo "❌ PR #${PR}: レビュー未完了 (${MISSING%, }) [tier=$TIER]" >&2
    exit 1
  fi
fi

# All checks passed — mark as verified in BOTH project + global state (Fix8).
# Use setdefault so the global file (which may lack the entry) also gets
# verified=true, satisfying block-merge-without-review.sh's global read.
# Fix C: capture lock_apply's status so a silent write failure cannot make VERIFY
# falsely report success while verified=true was never persisted. lock_apply emits
# its own stderr warning; `|| _lock_rc=$?` prevents set -e from aborting before we
# decide. On failure, do NOT print the success line — exit non-zero so the operator
# knows the lock is still pending.
_lock_rc=0
_BR="$BRANCH" _HEAD_SHA="$HEAD_SHA" lock_apply "$PR" "
e = s.setdefault(PR, {'status': 'review_pending', 'branch': os.environ['_BR']})
e['ci_green'] = True
e['review_lgtm'] = True
e['verified'] = True
e['head_sha'] = os.environ['_HEAD_SHA']
e['verified_head_sha'] = os.environ['_HEAD_SHA']
" || _lock_rc=$?

if [[ "$_lock_rc" -ne 0 ]]; then
  echo "❌ PR #${PR}: 検証は通りましたがロック解除の保存に失敗しました。再実行してください。" >&2
  exit 1
fi

echo "✅ PR #${PR}: CI green + レビュー LGTM 確認完了。ロック解除。" >&2
exit 0
