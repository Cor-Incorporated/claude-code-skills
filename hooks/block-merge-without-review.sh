#!/bin/bash
# block-merge-without-review.sh — BLOCK merge unless latest review is after latest push
# PreToolUse hook for gh pr merge commands
set -euo pipefail
# Project-scoped state: isolate per-project via CLAUDE_PROJECT_DIR / git root.
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

# --- Pessimistic Lock Check ---
REVIEW_LOCK="$_STATE_BASE/pr-review-lock.json"
if [ -f "$REVIEW_LOCK" ]; then
    LOCK_STATUS=$(python3 -c "
import json
with open('$REVIEW_LOCK') as f:
    s = json.load(f)
pr = s.get('$PR_NUM', {})
if not pr.get('verified', False):
    print('LOCKED')
else:
    print('OK')
" 2>/dev/null || echo "OK")

    if [ "$LOCK_STATUS" = "LOCKED" ]; then
        # Check if auto-review is needed (no claude-review workflow)
        AUTO_REVIEW=$(python3 -c "
import json
with open('$REVIEW_LOCK') as f:
    s = json.load(f)
print('yes' if s.get('$PR_NUM', {}).get('auto_review_needed', False) else 'no')
" 2>/dev/null || echo "no")

        echo "🔒 [Pessimistic Lock] PR #${PR_NUM} は review_pending 状態です。マージ不可。" >&2
        echo "" >&2
        if [ "$AUTO_REVIEW" = "yes" ]; then
            echo "⚠️  claude-review workflow が未設定。自動レビューが必要です。" >&2
            echo "" >&2
            echo "以下のいずれかを実行してください:" >&2
            echo "  1. Agent tool (subagent_type=code-reviewer) でレビュー実行" >&2
            echo "  2. /review-loop ${PR_NUM} で自動検証ループ" >&2
            echo "  3. Codex CLI: bash ~/.claude/scripts/codex-parallel.sh --review" >&2
        else
            echo "push後のclaude-review 3ソース全確認が未完了です。" >&2
            echo "解除: bash ~/.claude/scripts/verify-pr-review.sh ${PR_NUM}" >&2
            echo "または /review-loop ${PR_NUM} で自動検証" >&2
        fi
        exit 2
    fi
fi

echo "[Review Guard] PR #${PR_NUM} のレビュータイムスタンプを検証中..." >&2

# Get latest push time
LAST_PUSH=$(gh pr view "$PR_NUM" --json updatedAt -q '.updatedAt' 2>/dev/null || echo "")

# Get all reviews
REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews" 2>/dev/null || echo "[]")

# Check if any review exists
REVIEW_COUNT=$(echo "$REVIEWS" | jq 'length' 2>/dev/null || echo "0")
if [ "$REVIEW_COUNT" = "0" ]; then
    echo "[BLOCK] PR #${PR_NUM} にレビューがありません。レビューなしでのマージは禁止。" >&2
    echo "code-reviewerエージェントでレビューを実施してください。" >&2
    exit 2
fi

# Check for APPROVED or LGTM reviews after the latest push
if [ -n "$LAST_PUSH" ]; then
    LATEST_REVIEW_TIME=$(echo "$REVIEWS" | jq -r '[.[] | select(.state == "APPROVED" or (.body | test("LGTM|lgtm"; "i")))] | sort_by(.submitted_at) | last | .submitted_at // ""' 2>/dev/null || echo "")

    if [ -z "$LATEST_REVIEW_TIME" ]; then
        echo "[BLOCK] PR #${PR_NUM} にAPPROVEDまたはLGTMレビューがありません。" >&2
        exit 2
    fi

    # Compare timestamps (lexicographic comparison works for ISO 8601)
    if [[ "$LATEST_REVIEW_TIME" < "$LAST_PUSH" ]]; then
        echo "[BLOCK] PR #${PR_NUM} の最新レビュー ($LATEST_REVIEW_TIME) が最終push ($LAST_PUSH) より古いです。" >&2
        echo "最終pushの後に再レビューが必要です。" >&2
        exit 2
    fi

    echo "[Review Guard] 最新レビューが最終push以降であることを確認 ✓" >&2
fi

# Also check all 3 review sources for unresolved CRITICAL/HIGH
PR_COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/comments" 2>/dev/null || echo "[]")
ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUM}/comments" 2>/dev/null || echo "[]")

# Check for unresolved CRITICAL/HIGH in any source
HAS_CRITICAL=$(echo "$PR_COMMENTS $ISSUE_COMMENTS" | grep -ci "CRITICAL\|critical" || true)
HAS_HIGH=$(echo "$PR_COMMENTS $ISSUE_COMMENTS" | grep -ci "\bHIGH\b" || true)

if [ "$HAS_CRITICAL" -gt 0 ] || [ "$HAS_HIGH" -gt 0 ]; then
    echo "[BLOCK] PR #${PR_NUM} にCRITICAL/HIGH指摘が残っている可能性があります。" >&2
    echo "全レビューソース (reviews, PR comments, issue comments) を確認してください。" >&2
    echo "  gh api repos/${REPO}/pulls/${PR_NUM}/reviews" >&2
    echo "  gh api repos/${REPO}/pulls/${PR_NUM}/comments" >&2
    echo "  gh api repos/${REPO}/issues/${PR_NUM}/comments" >&2
    exit 2
fi

echo "[Review Guard] レビュー検証完了 ✓" >&2
echo "$input"
exit 0
