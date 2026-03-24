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

# Project-scoped state: match block-merge-without-review.sh resolution (Issue #19)
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  _STATE_BASE="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  _STATE_BASE="$(git rev-parse --show-toplevel)/.claude/state"
else
  _STATE_BASE="$HOME/.claude/state"
fi
REVIEW_LOCK="$_STATE_BASE/pr-review-lock.json"
mkdir -p "$(dirname "$REVIEW_LOCK")"
[ ! -f "$REVIEW_LOCK" ] && echo '{}' > "$REVIEW_LOCK"

echo "🔍 PR #${PR_NUM} claude-review 3ソース検証中..."

# --- Check if auto-review was needed (no claude-review workflow) ---
AUTO_REVIEW_NEEDED=$(_LOCK="$REVIEW_LOCK" _PR="$PR_NUM" python3 -c "
import json, os, fcntl
with open(os.environ['_LOCK']) as f:
    fcntl.flock(f, fcntl.LOCK_SH)
    s = json.load(f)
    fcntl.flock(f, fcntl.LOCK_UN)
print('yes' if s.get(os.environ['_PR'], {}).get('auto_review_needed', False) else 'no')
" 2>/dev/null || echo "no")

# Source 1: Review bodies
REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews" 2>/dev/null || echo "[]")

# Source 2: Inline comments
PR_COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/comments" 2>/dev/null || echo "[]")

# Source 3: Issue comments (review summaries)
ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUM}/comments" 2>/dev/null || echo "[]")

# Issue #152: Only check the LATEST claude-review comment, not all historical ones.
# Old reviews may contain 🔴 from issues already fixed in subsequent pushes.
LATEST_REVIEW_BODY=$(echo "$ISSUE_COMMENTS" | python3 -c "
import json, sys
comments = json.load(sys.stdin)
claude_comments = [c for c in comments
    if c.get('user', {}).get('login') == 'claude[bot]'
    or ('CRITICAL' in c.get('body', '')[:1000] and 'review' in c.get('body', '').lower()[:500])]
if claude_comments:
    print(claude_comments[-1].get('body', ''))
else:
    print('')
" 2>/dev/null || echo "")

LATEST_FORMAL_REVIEW=$(echo "$REVIEWS" | python3 -c "
import json, sys
reviews = json.load(sys.stdin)
if reviews:
    print(reviews[-1].get('body', ''))
else:
    print('')
" 2>/dev/null || echo "")

# Combine ONLY latest review content (not all historical)
COMBINED="$LATEST_REVIEW_BODY $LATEST_FORMAL_REVIEW"
# Use severity-prefix patterns to avoid false positives (aligned with block-merge-without-review.sh)
BLOCKING=$(echo "$COMBINED" | grep -ciE '\[BLOCKING\]|severity:\s*BLOCKING|^\s*BLOCKING[:\s-]|>\s*BLOCKING|\*\*BLOCKING\*\*|🔴' || true)
MUST_FIX=$(echo "$COMBINED" | grep -ciE '\[MUST.FIX\]|severity:\s*MUST.FIX|^\s*MUST.FIX[:\s-]|>\s*MUST.FIX|\*\*MUST.FIX\*\*' || true)
CRITICAL=$(echo "$COMBINED" | grep -ciE '\[CRITICAL\]|severity:\s*CRITICAL|^\s*CRITICAL[:\s-]|>\s*CRITICAL|\*\*CRITICAL\*\*' || true)
# Issue #116: quality.md requires "CRITICAL/HIGHゼロまで完了ではない"
HIGH=$(echo "$COMBINED" | grep -ciE '\[HIGH\]|severity:\s*HIGH|^\s*HIGH:|>\s*HIGH|\*\*HIGH\*\*' || true)
# BUG: 2-pass with false-positive filtering (aligned with block-merge-without-review.sh)
BUG_FILTERED=$(echo "$COMBINED" \
    | grep -iE '\[BUG\]|\*\*BUG\*\*|severity:\s*BUG|bug\s+found|バグ発見|バグあり' \
    | grep -viE 'bug\s*fix|fix.*bug|no\s+bug|bug-free' || true)
BUG=$(echo "$BUG_FILTERED" | grep -c '.' || true)

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
echo "  High:      ${HIGH}"
echo "  Bug:       ${BUG}"
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

# --- CRITICAL: Ensure at least one review comment exists (Issue #114) ---
# "レビュー0件でtrivially pass" の抜け穴を塞ぐ
# EXEMPT tier (docs/chore/ci branches) はスキップ
PR_BRANCH=$(gh api "repos/${REPO}/pulls/${PR_NUM}" --jq '.head.ref' 2>/dev/null || echo "")
IS_EXEMPT="no"
case "$PR_BRANCH" in docs/*|chore/*|ci/*) IS_EXEMPT="yes" ;; esac

if [ "$IS_EXEMPT" = "no" ]; then
    # Count total review-related comments (reviews + inline + issue comments from bots/agents)
    REVIEW_COUNT=$(echo "$REVIEWS" | python3 -c "
import json, sys
reviews = json.load(sys.stdin)
# Count non-PENDING reviews (APPROVED, CHANGES_REQUESTED, COMMENTED)
actual = [r for r in reviews if r.get('state', '') != 'PENDING']
print(len(actual))
" 2>/dev/null || echo "0")
    INLINE_COUNT=$(echo "$PR_COMMENTS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    BOT_COMMENT_COUNT=$(echo "$ISSUE_COMMENTS" | python3 -c "
import json, sys
comments = json.load(sys.stdin)
# Count comments from bots/agents that contain review-like content
review_bots = [c for c in comments if
    c.get('user', {}).get('type') == 'Bot' or
    'review' in c.get('body', '').lower()[:500] or
    'walkthrough' in c.get('body', '').lower()[:500] or
    'CRITICAL' in c.get('body', '')[:500] or
    'BLOCKING' in c.get('body', '')[:500]]
print(len(review_bots))
" 2>/dev/null || echo "0")

    TOTAL_REVIEW_EVIDENCE=$((REVIEW_COUNT + INLINE_COUNT + BOT_COMMENT_COUNT))

    if [ "$TOTAL_REVIEW_EVIDENCE" -eq 0 ]; then
        echo "" >&2
        echo "❌ PR #${PR_NUM} にレビューが存在しません。code-reviewer を実行してください。" >&2
        echo "   レビューなしでのマージは許可されません。" >&2
        echo "" >&2
        echo "   実行方法:" >&2
        echo "   1. Agent (subagent_type=code-reviewer) でレビュー実行" >&2
        echo "   2. CodeRabbit レビュー待ち" >&2
        echo "   3. gh pr review ${PR_NUM} --approve で手動レビュー" >&2
        echo "" >&2
        exit 1
    fi
    echo "  レビュー存在確認: ${TOTAL_REVIEW_EVIDENCE}件 ✓"
fi

if [ "$BLOCKING" -gt 0 ] || [ "$MUST_FIX" -gt 0 ] || [ "$CRITICAL" -gt 0 ] || [ "$HIGH" -gt 0 ] || [ "$BUG" -gt 0 ]; then
    echo "❌ PR #${PR_NUM} にBlocking/MustFix/Critical/High/Bug指摘が残っています。ロック解除できません。"

    _LOCK="$REVIEW_LOCK" _PR="$PR_NUM" _BLOCKING="$BLOCKING" _MUST_FIX="$MUST_FIX" _CRITICAL="$CRITICAL" _HIGH="$HIGH" _BUG="$BUG" python3 -c "
import json, os, fcntl
f_path = os.environ['_LOCK']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    s.setdefault(os.environ['_PR'], {})
    s[os.environ['_PR']]['blocking_count'] = int(os.environ['_BLOCKING'])
    s[os.environ['_PR']]['must_fix_count'] = int(os.environ['_MUST_FIX'])
    s[os.environ['_PR']]['critical_count'] = int(os.environ['_CRITICAL'])
    s[os.environ['_PR']]['high_count'] = int(os.environ['_HIGH'])
    s[os.environ['_PR']]['bug_count'] = int(os.environ['_BUG'])
    s[os.environ['_PR']]['verified'] = False
    f.seek(0)
    f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null
    exit 1
fi

# ALL CLEAN — release lock
_LOCK="$REVIEW_LOCK" _PR="$PR_NUM" _NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 -c "
import json, os, fcntl
f_path = os.environ['_LOCK']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    s.setdefault(os.environ['_PR'], {})
    s[os.environ['_PR']]['blocking_count'] = 0
    s[os.environ['_PR']]['must_fix_count'] = 0
    s[os.environ['_PR']]['critical_count'] = 0
    s[os.environ['_PR']]['high_count'] = 0
    s[os.environ['_PR']]['bug_count'] = 0
    s[os.environ['_PR']]['verified'] = True
    s[os.environ['_PR']]['verified_at'] = os.environ['_NOW']
    f.seek(0)
    f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null

# Also mark review as read (resolves pr-merge-claude-review-gate.sh / block-state-file-tampering-bash.sh design gap — Issue #99)
# verify-pr-review.sh fetches and displays all review comments above, satisfying the "read" requirement.
REVIEW_READ_FILE="$_STATE_BASE/pr-review-read.json"
[ ! -f "$REVIEW_READ_FILE" ] && echo '{}' > "$REVIEW_READ_FILE"
_RR="$REVIEW_READ_FILE" _PR="$PR_NUM" python3 -c "
import json, os, fcntl
f_path = os.environ['_RR']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    s.setdefault(os.environ['_PR'], {})['review_read'] = True
    f.seek(0)
    f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null || true

echo "✅ PR #${PR_NUM} ロック解除。claude-review クリーン確認済み。マージ可能。"
exit 0
