#!/bin/bash
# block-merge-without-ci.sh — BLOCK gh pr merge unless CI all green
# PreToolUse hook for gh pr merge commands
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
cmd_first_line=$(echo "$cmd" | head -1)

# Only trigger for merge commands
if ! echo "$cmd_first_line" | grep -q 'gh.*pr.*merge'; then
    exit 0
fi

# Extract PR number
PR_NUM=$(echo "$cmd_first_line" | grep -oE 'pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+' || echo "")
if [ -z "$PR_NUM" ]; then
    echo "[BLOCK] PR番号が特定できません。gh pr merge <number> の形式で指定してください。" >&2
    exit 2
fi

# Check CI status
echo "[Merge Guard] PR #${PR_NUM} の CI/CD ステータスを確認中..." >&2

CHECK_STATUS=$(gh pr checks "$PR_NUM" 2>&1 || true)

# Check for failures
if echo "$CHECK_STATUS" | grep -qi "fail\|error"; then
    echo "[BLOCK] PR #${PR_NUM} の CI/CD にfailureがあります。オールグリーンになるまでマージ禁止。" >&2
    echo "$CHECK_STATUS" >&2
    exit 2
fi

# Check for pending
if echo "$CHECK_STATUS" | grep -qi "pending\|queued\|in_progress"; then
    echo "[BLOCK] PR #${PR_NUM} の CI/CD がまだ実行中です。完了を待ってください。" >&2
    echo "$CHECK_STATUS" >&2
    exit 2
fi

# Check for no checks at all
if echo "$CHECK_STATUS" | grep -qi "no checks"; then
    echo "[BLOCK] PR #${PR_NUM} にCIチェックがありません。コンフリクトの可能性があります。" >&2
    echo "確認: gh pr view $PR_NUM --json mergeable,mergeStateStatus" >&2
    exit 2
fi

# Check mergeable status
MERGEABLE=$(gh pr view "$PR_NUM" --json mergeable -q '.mergeable' 2>/dev/null || echo "UNKNOWN")
if [ "$MERGEABLE" = "CONFLICTING" ]; then
    echo "[BLOCK] PR #${PR_NUM} にコンフリクトがあります。Codex CLIでリベースしてください。" >&2
    exit 2
fi

echo "[Merge Guard] CI/CD オールグリーン確認済み ✓" >&2
exit 0
