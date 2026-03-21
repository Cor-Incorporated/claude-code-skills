#!/bin/bash
# verify-pr-review.sh — Verify claude-review is clean and release pessimistic lock
# Usage: bash verify-pr-review.sh <PR_NUMBER>
#
# Checks ALL 3 review sources for Blocking/MustFix/Critical.
# Only releases the lock if ALL sources are clean.
set -euo pipefail

PR_NUM="${1:-}"
if [ -z "$PR_NUM" ]; then
    echo "Usage: bash verify-pr-review.sh <PR_NUMBER>" >&2
    exit 1
fi

REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
    echo "❌ リポジトリ情報を取得できません。" >&2
    exit 1
fi

REVIEW_LOCK="$HOME/.claude/state/pr-review-lock.json"
mkdir -p "$(dirname "$REVIEW_LOCK")"
[ ! -f "$REVIEW_LOCK" ] && echo '{}' > "$REVIEW_LOCK"

echo "🔍 PR #${PR_NUM} claude-review 3ソース検証中..."

# --- Check if auto-review was needed (no claude-review workflow) ---
AUTO_REVIEW_NEEDED=$(python3 -c "
import json
with open('$REVIEW_LOCK') as f:
    s = json.load(f)
print('yes' if s.get('$PR_NUM', {}).get('auto_review_needed', False) else 'no')
" 2>/dev/null || echo "no")

# Source 1: Review bodies
REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews" 2>/dev/null || echo "[]")

# Source 2: Inline comments
PR_COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/comments" 2>/dev/null || echo "[]")

# Source 3: Issue comments (review summaries)
ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUM}/comments" 2>/dev/null || echo "[]")

# Count blocking indicators across ALL sources
COMBINED="$REVIEWS $PR_COMMENTS $ISSUE_COMMENTS"
BLOCKING=$(echo "$COMBINED" | grep -ci "blocking\|🔴" || true)
MUST_FIX=$(echo "$COMBINED" | grep -ci "must.fix\|MUST FIX" || true)
CRITICAL=$(echo "$COMBINED" | grep -ci "critical" || true)

# Get latest claude-review summary
LATEST_SUMMARY=$(echo "$ISSUE_COMMENTS" | python3 -c "
import json, sys
comments = json.load(sys.stdin)
claude_comments = [c for c in comments if c.get('user', {}).get('login') == 'claude[bot]']
if claude_comments:
    print(claude_comments[-1].get('body', '')[:500])
else:
    print('(no claude-review found)')
" 2>/dev/null || echo "(parse error)")

echo ""
echo "=== 検証結果 ==="
echo "  Blocking:  ${BLOCKING}"
echo "  Must Fix:  ${MUST_FIX}"
echo "  Critical:  ${CRITICAL}"
echo ""
echo "=== 最新レビューサマリ (先頭500文字) ==="
echo "$LATEST_SUMMARY"
echo ""

# --- Check: If auto-review needed, verify review comments exist ---
if [ "$AUTO_REVIEW_NEEDED" = "yes" ]; then
    HAS_ANY_REVIEW=$(echo "$ISSUE_COMMENTS" | python3 -c "
import json, sys
comments = json.load(sys.stdin)
# Accept claude[bot] or any bot/agent review
review_comments = [c for c in comments if 'review' in c.get('body', '').lower()[:200]]
print('yes' if review_comments else 'no')
" 2>/dev/null || echo "no")

    if [ "$HAS_ANY_REVIEW" = "no" ]; then
        echo "❌ PR #${PR_NUM} にレビューコメントが存在しません。" >&2
        echo "   claude-review workflow未設定のため、手動レビューが必須です。" >&2
        echo "" >&2
        echo "   実行してください:" >&2
        echo "   1. Agent (subagent_type=code-reviewer) でレビュー" >&2
        echo "   2. レビュー結果を gh pr comment ${PR_NUM} --body で投稿" >&2
        echo "   3. 再度 verify-pr-review.sh ${PR_NUM} を実行" >&2
        exit 1
    fi
    echo "  Auto-review: レビューコメント検出 ✓"
fi

if [ "$BLOCKING" -gt 0 ] || [ "$MUST_FIX" -gt 0 ] || [ "$CRITICAL" -gt 0 ]; then
    echo "❌ PR #${PR_NUM} にBlocking/MustFix/Critical指摘が残っています。ロック解除できません。"

    python3 -c "
import json
f = '$REVIEW_LOCK'
with open(f) as fh:
    s = json.load(fh)
s.setdefault('$PR_NUM', {})
s['$PR_NUM']['blocking_count'] = $BLOCKING
s['$PR_NUM']['must_fix_count'] = $MUST_FIX
s['$PR_NUM']['verified'] = False
with open(f, 'w') as fh:
    json.dump(s, fh, indent=2)
" 2>/dev/null
    exit 1
fi

# ALL CLEAN — release lock
python3 -c "
import json
f = '$REVIEW_LOCK'
with open(f) as fh:
    s = json.load(fh)
s.setdefault('$PR_NUM', {})
s['$PR_NUM']['blocking_count'] = 0
s['$PR_NUM']['must_fix_count'] = 0
s['$PR_NUM']['verified'] = True
s['$PR_NUM']['verified_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open(f, 'w') as fh:
    json.dump(s, fh, indent=2)
" 2>/dev/null

echo "✅ PR #${PR_NUM} ロック解除。claude-review クリーン確認済み。マージ可能。"
exit 0
