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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/gate-modes/common.sh"

MERGE_COUNT=$(count_gh_pr_merge_invocations "$cmd" || echo 0)
if [ "$MERGE_COUNT" -ne 1 ]; then
    exit 0
fi

_cmd_context=$(command_git_context_dir "$cmd")
if [[ -n "$_cmd_context" ]]; then
    export GIT_CONTEXT_DIR="$_cmd_context"
    use_git_context_state_dir
fi

PR_NUM=$(extract_gh_pr_merge_target "$cmd" || echo "")
if [[ "$PR_NUM" == __NON_NUMERIC__:* || -z "$PR_NUM" ]]; then
    exit 0
fi

REPO=$(resolve_repo "$cmd")
[ -z "$REPO" ] && exit 0

# Check if PR was actually merged
PR_STATE=$(gh pr view "$PR_NUM" -R "$REPO" --json state -q '.state' 2>/dev/null || echo "")
if [ "$PR_STATE" != "MERGED" ]; then
    exit 0
fi

# Clear leftover review-comment residue for this merged PR so the
# enforce-review-reading.sh banner does not linger after merge. Removes the
# state only when its .pr matches THIS PR, in BOTH project-scoped and global
# state dirs.
_TOP=$(git_ctx rev-parse --show-toplevel 2>/dev/null || echo "")
for _sd in ${_TOP:+"$_TOP/.claude/state"} "$HOME/.claude/state"; do
    _pf="$_sd/pending-review-comments.json"
    [ -f "$_pf" ] || continue
    _pf_pr=$(jq -r '.pr // ""' "$_pf" 2>/dev/null || echo "")
    if [ "$_pf_pr" = "$PR_NUM" ]; then
        rm -f "$_pf" "$_sd/pending-review-pr-state.cache" 2>/dev/null || true
        echo "🧹 [Post-Merge] PR #${PR_NUM} のレビュー残骸 (pending-review-comments.json) を削除しました。" >&2
    fi
done

# Extract Issue numbers from PR body (Closes/Fixes/Resolves #XX).
# Refs-only PRs intentionally do not trigger automatic Issue closure.
PR_BODY=$(gh pr view "$PR_NUM" -R "$REPO" --json body -q '.body' 2>/dev/null || echo "")
ISSUE_NUMS=$(echo "$PR_BODY" | grep -oiE '(^|[^[:alnum:]_])(closes?|fixes?|resolves?)[[:space:]:]*#[0-9]+' | grep -oE '[0-9]+' || true)

if [ -z "$ISSUE_NUMS" ]; then
    echo "ℹ️ [Post-Merge] PR #${PR_NUM} はクローズキーワードなし。Issue自動クローズをスキップします。" >&2
    exit 0
fi

# Close each linked Issue
CLOSED_COUNT=0
for ISSUE_NUM in $ISSUE_NUMS; do
    ISSUE_STATE=$(gh issue view "$ISSUE_NUM" -R "$REPO" --json state -q '.state' 2>/dev/null || echo "")
    if [ "$ISSUE_STATE" = "OPEN" ]; then
        gh issue close "$ISSUE_NUM" -R "$REPO" --comment "Closed by PR #${PR_NUM} merge." 2>/dev/null && {
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

exit 0
