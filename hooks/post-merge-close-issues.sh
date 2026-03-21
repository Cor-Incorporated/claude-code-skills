#!/bin/bash
# post-merge-close-issues.sh — PostToolUse hook after gh pr merge
# Automatically closes linked Issues after PR merge.
#
# Flow: Issue → PR (Closes #XX) → Merge → Issue Auto-Close
#
# Extracts Issue numbers from PR body (Closes/Fixes/Resolves #XX)
# and closes them with a comment linking back to the merged PR.
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

cmd_first_line=$(echo "$cmd" | head -1)
if ! echo "$cmd_first_line" | grep -q 'gh.*pr.*merge'; then
    echo "$input"
    exit 0
fi

PR_NUM=$(echo "$cmd_first_line" | grep -oE 'pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+' || echo "")
[ -z "$PR_NUM" ] && { echo "$input"; exit 0; }

REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
[ -z "$REPO" ] && { echo "$input"; exit 0; }

# Check if PR was actually merged
PR_STATE=$(gh pr view "$PR_NUM" --json state -q '.state' 2>/dev/null || echo "")
if [ "$PR_STATE" != "MERGED" ]; then
    echo "$input"
    exit 0
fi

# Extract Issue numbers from PR body (Closes/Fixes/Resolves #XX)
PR_BODY=$(gh pr view "$PR_NUM" --json body -q '.body' 2>/dev/null || echo "")
ISSUE_NUMS=$(echo "$PR_BODY" | grep -oiE '(closes?|fixes?|resolves?)\s*#[0-9]+' | grep -oE '[0-9]+' || true)

if [ -z "$ISSUE_NUMS" ]; then
    echo "⚠️ [Post-Merge] PR #${PR_NUM} マージ済みだがクローズ対象のIssueが見つかりません。" >&2
    echo "   PRのbodyに 'Closes #XX' が含まれていない可能性があります。" >&2
    echo "   手動でIssueをクローズしてください。" >&2
    echo "$input"
    exit 0
fi

# Close each linked Issue
CLOSED_COUNT=0
for ISSUE_NUM in $ISSUE_NUMS; do
    ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --json state -q '.state' 2>/dev/null || echo "")
    if [ "$ISSUE_STATE" = "OPEN" ]; then
        gh issue close "$ISSUE_NUM" --comment "Closed by PR #${PR_NUM} merge." 2>/dev/null && {
            CLOSED_COUNT=$((CLOSED_COUNT + 1))
            echo "✅ [Post-Merge] Issue #${ISSUE_NUM} を自動クローズしました (PR #${PR_NUM})" >&2
        }
    fi
done

if [ "$CLOSED_COUNT" -gt 0 ]; then
    echo "✅ [Post-Merge] PR #${PR_NUM} マージ → ${CLOSED_COUNT}件のIssueを自動クローズ" >&2
else
    echo "ℹ️ [Post-Merge] PR #${PR_NUM} の関連Issue(${ISSUE_NUMS})は既にクローズ済み" >&2
fi

echo "$input"
exit 0
