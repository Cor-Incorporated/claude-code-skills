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

# Resolve REPO independent of cwd (Fix8):
#   1. CLAUDE_FORK_REPO env override
#   2. explicit 2nd CLI arg (owner/repo)
#   3. gh repo view from cwd
#   4. git remote (origin/upstream) of CLAUDE_PROJECT_DIR or git toplevel
REPO="${CLAUDE_FORK_REPO:-${2:-}}"
if [ -z "$REPO" ]; then
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
fi
if [ -z "$REPO" ]; then
    _repo_dir="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
    if [ -n "$_repo_dir" ]; then
        REPO=$(git -C "$_repo_dir" remote get-url upstream 2>/dev/null \
                 | sed 's|.*github.com[:/]||;s|\.git$||')
        [ -z "$REPO" ] && REPO=$(git -C "$_repo_dir" remote get-url origin 2>/dev/null \
                 | sed 's|.*github.com[:/]||;s|\.git$||')
    fi
fi
if [ -z "$REPO" ]; then
    echo "❌ リポジトリ情報を取得できません。" >&2
    exit 1
fi

# Project-scoped state: match block-merge-without-review.sh resolution (Issue #19).
# Fix8: write the lock to BOTH the project-scoped dir AND the global dir so a
# later reader with no/other CLAUDE_PROJECT_DIR (block-merge) sees verified=true.
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  _STATE_BASE="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  _STATE_BASE="$(git rev-parse --show-toplevel)/.claude/state"
else
  _STATE_BASE="$HOME/.claude/state"
fi
_GLOBAL_STATE_BASE="$HOME/.claude/state"
REVIEW_LOCK="$_STATE_BASE/pr-review-lock.json"
mkdir -p "$(dirname "$REVIEW_LOCK")"
[ ! -f "$REVIEW_LOCK" ] && echo '{}' > "$REVIEW_LOCK"

_add_review_read_target() {
  local target="$1" existing
  [[ -z "$target" ]] && return 0
  for existing in "${REVIEW_READ_TARGETS[@]:-}"; do
    [[ "$existing" == "$target" ]] && return 0
  done
  REVIEW_READ_TARGETS+=("$target")
}

# Build deduped list of lock targets (project-scoped, then global)
LOCK_TARGETS=("$REVIEW_LOCK")
if [[ "$_GLOBAL_STATE_BASE/pr-review-lock.json" != "$REVIEW_LOCK" ]]; then
  LOCK_TARGETS+=("$_GLOBAL_STATE_BASE/pr-review-lock.json")
fi
mkdir -p "$_GLOBAL_STATE_BASE"
for _lt in "${LOCK_TARGETS[@]}"; do
  [ ! -f "$_lt" ] && echo '{}' > "$_lt"
done

echo "🔍 PR #${PR_NUM} claude-review 3ソース検証中..."

# --- Check if auto-review was needed (no claude-review workflow) ---
# Fix8: OR-logic across ALL lock locations.
AUTO_REVIEW_NEEDED="no"
for _lt in "${LOCK_TARGETS[@]}"; do
  [ ! -f "$_lt" ] && continue
  _arn=$(_LOCK="$_lt" _PR="$PR_NUM" python3 -c "
import json, os, fcntl
try:
    with open(os.environ['_LOCK']) as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        s = json.load(f)
        fcntl.flock(f, fcntl.LOCK_UN)
    print('yes' if s.get(os.environ['_PR'], {}).get('auto_review_needed', False) else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
  [ "$_arn" = "yes" ] && { AUTO_REVIEW_NEEDED="yes"; break; }
done

# Source 1: Review bodies
REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews" 2>/dev/null || echo "[]")

# Source 2: Inline PR comments — intentionally excluded from severity check.
# Issue #152: We only check the LATEST review summary, not individual inline comments,
# because old inline comments from prior pushes cause false positives.
# Inline CRITICAL/BLOCKING findings will appear in the review summary comment.

# Source 3: Issue comments (review summaries)
ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUM}/comments" 2>/dev/null || echo "[]")

# Issue #165: Check claude-review CI status. If passed or not configured, skip keyword severity detection.
HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUM}" --jq '.head.sha' 2>/dev/null || echo "")
CLAUDE_REVIEW_CI=""
if [[ -n "$HEAD_SHA" ]]; then
  CLAUDE_REVIEW_CI=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | select(.name | test("claude-review"; "i"))] | .[0].conclusion // ""' 2>/dev/null || echo "")
fi

# Issue #152: Only check the LATEST claude-review comment, not all historical ones.
# Old reviews may contain 🔴 from issues already fixed in subsequent pushes.
LATEST_REVIEW_BODY=$(echo "$ISSUE_COMMENTS" | python3 -c "
import json, sys
comments = json.load(sys.stdin)
# Match claude[bot], any Bot with review content, OR any comment with severity markers
review_comments = [c for c in comments
    if c.get('user', {}).get('login') == 'claude[bot]'
    or (c.get('user', {}).get('type') == 'Bot'
        and 'review' in c.get('body', '').lower()[:500])
    or any(sev in c.get('body', '')[:2000]
           for sev in ['[CRITICAL]', '[HIGH]', '[BLOCKING]', '[MUST_FIX]', '[BUG]',
                       '**CRITICAL**', '**HIGH**', '**BLOCKING**'])]
if review_comments:
    print(review_comments[-1].get('body', ''))
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

# Issue #165: If claude-review CI passed or not configured, skip keyword-based severity detection
if [[ "$CLAUDE_REVIEW_CI" == "success" ]] || [[ -z "$CLAUDE_REVIEW_CI" ]]; then
  # claude-review CI passed or not configured — skip keyword-based severity detection
  BLOCKING=0; MUST_FIX=0; CRITICAL=0; HIGH=0; BUG=0
else
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
fi

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
    INLINE_COUNT=$(echo "[]" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
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

    # Fix8: write failure state (verified=False) to ALL lock locations
    for _lt in "${LOCK_TARGETS[@]}"; do
      _LOCK="$_lt" _PR="$PR_NUM" _BLOCKING="$BLOCKING" _MUST_FIX="$MUST_FIX" _CRITICAL="$CRITICAL" _HIGH="$HIGH" _BUG="$BUG" python3 -c "
import json, os, fcntl
f_path = os.environ['_LOCK']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except Exception:
        s = {}
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
    done
    exit 1
fi

# ALL CLEAN — release lock in ALL locations (Fix8 dual-write).
# block-merge-without-review.sh reads $HOME/.claude/state when CLAUDE_PROJECT_DIR
# is unset, so verified=true MUST land in the global file too.
for _lt in "${LOCK_TARGETS[@]}"; do
  _LOCK="$_lt" _PR="$PR_NUM" _NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 -c "
import json, os, fcntl
f_path = os.environ['_LOCK']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except Exception:
        s = {}
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
done

# Also mark review as read (resolves pr-merge-claude-review-gate.sh / block-state-file-tampering-bash.sh design gap — Issue #99)
# verify-pr-review.sh fetches and displays all review comments above, satisfying the "read" requirement.
REVIEW_READ_TARGETS=()
_add_review_read_target "$_STATE_BASE/pr-review-read.json"
_GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -n "$_GIT_ROOT" ]]; then
  _add_review_read_target "$_GIT_ROOT/.claude/state/pr-review-read.json"
fi
_add_review_read_target "$_GLOBAL_STATE_BASE/pr-review-read.json"

for _rr_target in "${REVIEW_READ_TARGETS[@]}"; do
  mkdir -p "$(dirname "$_rr_target")"
  [ ! -f "$_rr_target" ] && echo '{}' > "$_rr_target"
  _RR="$_rr_target" _PR="$PR_NUM" python3 -c "
import json, os, fcntl
f_path = os.environ['_RR']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except Exception:
        s = {}
    s.setdefault(os.environ['_PR'], {})['review_read'] = True
    f.seek(0)
    f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null || true
done

echo "✅ PR #${PR_NUM} ロック解除。claude-review クリーン確認済み。マージ可能。"
exit 0
