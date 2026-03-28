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

BRANCH=$(_LOCK="$LOCK_STATE" _PR="$PR" python3 -c "
import json, os
with open(os.environ['_LOCK']) as f: s = json.load(f)
print(s.get(os.environ['_PR'], {}).get('branch', ''))
" 2>/dev/null || echo "")

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
  CODE_REVIEW=$(read_review "$BRANCH" "code_review")
  CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")

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

# All checks passed — mark as verified
_LOCK="$LOCK_STATE" _PR="$PR" python3 -c "
import json, os, fcntl
f_path = os.environ['_LOCK']
pr = os.environ['_PR']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    if pr in s:
        s[pr]['ci_green'] = True
        s[pr]['review_lgtm'] = True
        s[pr]['verified'] = True
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null

echo "✅ PR #${PR}: CI green + レビュー LGTM 確認完了。ロック解除。" >&2
exit 0
