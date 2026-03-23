#!/bin/bash
# block-merge-without-review.sh — Block merge only when CRITICAL/HIGH findings exist
# PreToolUse hook for gh pr merge commands
#
# Issue #53: Simplified logic
#   - EXEMPT tier (docs/*, chore/*, ci/*) → only CRITICAL/HIGH check
#   - Pessimistic lock verified → skip APPROVED requirement
#   - CRITICAL/HIGH findings are the only hard blocker
#   - APPROVED/timestamp checks removed (handled by pr-ci-review-gate.sh)
set -euo pipefail

# Project-scoped state
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  _STATE_BASE="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  _STATE_BASE="$(git rev-parse --show-toplevel)/.claude/state"
else
  _STATE_BASE="$HOME/.claude/state"
fi
mkdir -p "$_STATE_BASE"

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

cmd_first_line=$(echo "$cmd" | head -1)
if ! echo "$cmd_first_line" | grep -q 'gh.*pr.*merge'; then
    echo "$input"
    exit 0
fi

PR_NUM=$(echo "$cmd_first_line" | grep -oE 'pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+' || echo "")
if [ -z "$PR_NUM" ]; then
    echo "$input"
    exit 0
fi

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
    echo "[BLOCK] リポジトリ情報を取得できません。" >&2
    exit 2
fi

# Get PR branch for tier classification
PR_BRANCH=$(gh api "repos/${REPO}/pulls/${PR_NUM}" --jq '.head.ref' 2>/dev/null || echo "")
TIER="FULL"
case "$PR_BRANCH" in
    docs/*|chore/*|ci/*) TIER="EXEMPT" ;;
    *)
        # Check if repo is claude-code-skills (meta-task → LIGHT)
        if [[ "$REPO" == *"/claude-code-skills"* ]]; then
            TIER="LIGHT"
        fi
        ;;
esac

# --- EXEMPT tier: skip pessimistic lock, skip review requirements ---
if [[ "$TIER" != "EXEMPT" ]]; then
    # --- Pessimistic Lock Check (non-EXEMPT only) ---
    REVIEW_LOCK="$_STATE_BASE/pr-review-lock.json"
    if [ -f "$REVIEW_LOCK" ]; then
        LOCK_STATUS=$(_REVIEW_LOCK="$REVIEW_LOCK" _PR="$PR_NUM" python3 -c "
import json, os
with open(os.environ['_REVIEW_LOCK']) as f:
    s = json.load(f)
pr = s.get(os.environ['_PR'], {})
if not pr.get('verified', False):
    print('LOCKED')
else:
    print('OK')
" 2>/dev/null || echo "OK")

        if [ "$LOCK_STATUS" = "LOCKED" ]; then
            echo "🔒 [Pessimistic Lock] PR #${PR_NUM} は review_pending 状態です。マージ不可。" >&2
            echo "" >&2
            echo "push後のclaude-review 3ソース全確認が未完了です。" >&2
            echo "解除: bash ~/.claude/scripts/verify-pr-review.sh ${PR_NUM}" >&2
            echo "または /review-loop ${PR_NUM} で自動検証" >&2
            exit 2
        fi
    fi
fi

# --- CRITICAL/HIGH check (ALL tiers — the only hard blocker) ---
PR_COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/comments" 2>/dev/null || echo "[]")
ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUM}/comments" 2>/dev/null || echo "[]")

# Use severity-prefix patterns to avoid false positives
HAS_CRITICAL=$(echo "$PR_COMMENTS $ISSUE_COMMENTS" | grep -ciE '\[CRITICAL\]|severity:\s*CRITICAL|^\s*CRITICAL:|>\s*CRITICAL|\*\*CRITICAL\*\*' || true)
HAS_HIGH=$(echo "$PR_COMMENTS $ISSUE_COMMENTS" | grep -ciE '\[HIGH\]|severity:\s*HIGH|^\s*HIGH:|>\s*HIGH|\*\*HIGH\*\*' || true)

if [ "$HAS_CRITICAL" -gt 0 ] || [ "$HAS_HIGH" -gt 0 ]; then
    echo "[BLOCK] PR #${PR_NUM} にCRITICAL/HIGH指摘が残っている可能性があります (tier=$TIER)。" >&2
    echo "全レビューソースを確認してください:" >&2
    echo "  gh api repos/${REPO}/pulls/${PR_NUM}/comments" >&2
    echo "  gh api repos/${REPO}/issues/${PR_NUM}/comments" >&2
    exit 2
fi

echo "[Review Guard] PR #${PR_NUM} (tier=$TIER): CRITICAL/HIGH指摘なし ✓" >&2
echo "$input"
exit 0
