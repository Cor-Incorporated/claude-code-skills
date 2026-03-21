#!/bin/bash
# post-push-review-check.sh — PostToolUse hook after git push
# PESSIMISTIC LOCK: After every push, mark PR as review_pending.
# Merge is blocked until claude-review is explicitly verified clean.
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

if ! echo "$cmd" | grep -qE 'git\s+push'; then
    exit 0
fi

BRANCH=$(echo "$cmd" | grep -oE 'origin\s+\S+' | awk '{print $2}' || true)
if [ -z "$BRANCH" ]; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "")
fi

[ -z "$BRANCH" ] && exit 0

PR_NUMBER=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "")

if [ -n "$PR_NUMBER" ]; then
    # --- PESSIMISTIC LOCK: Mark PR as review_pending ---
    REVIEW_STATE="$_STATE_BASE/pr-review-lock.json"
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    mkdir -p "$(dirname "$REVIEW_STATE")"
    [ ! -f "$REVIEW_STATE" ] && echo '{}' > "$REVIEW_STATE"

    _REVIEW_STATE="$REVIEW_STATE" _PR="$PR_NUMBER" _BR="$BRANCH" _NOW="$NOW" python3 -c "
    import json, os
    f = os.environ['_REVIEW_STATE']
    with open(f) as fh:
        s = json.load(fh)
    s[os.environ['_PR']] = {
        'status': 'review_pending',
        'branch': os.environ['_BR'],
        'push_at': os.environ['_NOW'],
        'blocking_count': -1,
        'must_fix_count': -1,
        'verified': False
    }
    with open(f, 'w') as fh:
        json.dump(s, fh, indent=2)
    " 2>/dev/null

    echo "" >&2
    echo "🔒 [Pessimistic Lock] PR #${PR_NUMBER} を review_pending に設定。" >&2
    echo "   claude-review 3ソース全確認 + Blocking/MustFix 0件 を検証するまで:" >&2
    echo "   - 「マージ可能」「LGTM」と判断してはならない" >&2
    echo "   - gh pr merge はブロックされる" >&2
    echo "" >&2

    # --- Auto-review: Detect if claude-review workflow exists ---
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
    HAS_CLAUDE_REVIEW="false"
    if [ -n "$REPO" ]; then
        # Check if claude-review workflow ran or is pending for this PR
        REVIEW_CHECK=$(gh api "repos/${REPO}/commits/$(git rev-parse HEAD 2>/dev/null)/check-runs" \
            --jq '.check_runs[] | select(.name == "claude-review") | .name' 2>/dev/null | head -1 || echo "")
        if [ -n "$REVIEW_CHECK" ]; then
            HAS_CLAUDE_REVIEW="true"
        fi
    fi

    if [ "$HAS_CLAUDE_REVIEW" = "true" ]; then
        echo "   ℹ️  claude-review workflow 検出。CI完了後に自動レビューされます。" >&2
        echo "   解除: bash ~/.claude/scripts/verify-pr-review.sh ${PR_NUMBER}" >&2
    else
        echo "   ⚠️  claude-review workflow 未検出。自動レビューエージェントを起動してください。" >&2
        echo "" >&2
        echo "   必須アクション:" >&2
        echo "   Agent tool (subagent_type=code-reviewer) でレビューを実行し、" >&2
        echo "   結果を PR #${PR_NUMBER} にコメントしてください。" >&2
        echo "" >&2
        echo "   または /review-loop ${PR_NUMBER} で自動検証" >&2

        # Write auto-review-needed flag to state
        _REVIEW_STATE="$REVIEW_STATE" _PR="$PR_NUMBER" python3 -c "
    import json, os
    f = os.environ['_REVIEW_STATE']
    with open(f) as fh:
        s = json.load(fh)
    s[os.environ['_PR']]['auto_review_needed'] = True
    with open(f, 'w') as fh:
        json.dump(s, fh, indent=2)
    " 2>/dev/null
    fi
fi

exit 0
