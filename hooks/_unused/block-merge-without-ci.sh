#!/bin/bash
# block-merge-without-ci.sh — BLOCK gh pr merge unless CI all green
# PreToolUse hook for gh pr merge commands
set -euo pipefail

# Portable timeout: macOS has no timeout command (GNU coreutils)
if command -v timeout &>/dev/null; then
  _timeout() { timeout "$@"; }
elif command -v gtimeout &>/dev/null; then
  _timeout() { gtimeout "$@"; }
else
  _timeout() { shift; "$@"; }  # skip timeout arg, run command directly
fi

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/gate-modes/common.sh"

# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

# Only trigger for merge commands
MERGE_COUNT=$(count_gh_pr_merge_invocations "$cmd" || echo 0)
if should_block_unparsed_pr_merge "$cmd" "$MERGE_COUNT"; then
    print_unparsed_pr_merge_block
    exit 2
fi
if [[ "$MERGE_COUNT" -eq 0 ]]; then
    exit 0
fi

_cmd_context=$(command_git_context_dir "$cmd")
if [[ -n "$_cmd_context" ]]; then
    export GIT_CONTEXT_DIR="$_cmd_context"
    use_git_context_state_dir
fi

# Extract PR number
PR_NUM=$(extract_gh_pr_merge_target "$cmd" || echo "")
if [[ "$MERGE_COUNT" -gt 1 || "$PR_NUM" == "__MULTIPLE__" ]]; then
    echo "[BLOCK] 1つのBashコマンドに複数の gh pr merge が含まれています。" >&2
    exit 2
fi
if [[ "$PR_NUM" == __NON_NUMERIC__:* ]]; then
    echo "[BLOCK] PR番号が特定できません。gh pr merge <number> の形式で指定してください。" >&2
    exit 2
fi
if [ -z "$PR_NUM" ]; then
    echo "[BLOCK] PR番号が特定できません。gh pr merge <number> の形式で指定してください。" >&2
    exit 2
fi

# Check CI status using commit-level check-runs API (not PR-level gh pr checks)
# This avoids false blocking by review bots (CodeRabbit, etc.) that appear
# as "pending" in PR checks but are not CI/CD jobs. Fixes #163 root cause.
echo "[Merge Guard] PR #${PR_NUM} の CI/CD ステータスを確認中..." >&2

REPO=$(resolve_repo "$cmd")
HEAD_SHA=$(_timeout 10 gh api "repos/${REPO}/pulls/${PR_NUM}" --jq '.head.sha' 2>/dev/null || echo "")

# Fail-closed: if HEAD_SHA is empty, block merge
if [ -z "$HEAD_SHA" ] || [ -z "$REPO" ]; then
    echo "[BLOCK] PR #${PR_NUM} の HEAD SHA を取得できませんでした（タイムアウトまたはAPI障害）。" >&2
    echo "  手動で確認してください: gh pr checks $PR_NUM" >&2
    exit 2
fi

# Query commit-level check runs
CHECK_RUNS=$(_timeout 10 gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" 2>/dev/null || echo "")

if [ -z "$CHECK_RUNS" ]; then
    echo "[BLOCK] PR #${PR_NUM} のチェック情報を取得できませんでした。fail-closed でブロックします。" >&2
    exit 2
fi

CI_TOTAL=$(echo "$CHECK_RUNS" | jq "[.check_runs[] | select(.name | test(\"${NON_CI_CHECK_PATTERN}\"; \"i\") | not)] | length" 2>/dev/null || echo "0")
CI_FAILURES=$(echo "$CHECK_RUNS" | jq "$(jq_ci_failures_filter)" 2>/dev/null || echo "0")
CI_PENDING=$(echo "$CHECK_RUNS" | jq "$(jq_ci_pending_filter)" 2>/dev/null || echo "0")

# No checks at all (after exclusion)
if [ "$CI_TOTAL" -eq 0 ]; then
    echo "[BLOCK] PR #${PR_NUM} にCIチェックがありません。" >&2
    echo "確認: gh pr view $PR_NUM --json mergeable,mergeStateStatus" >&2
    exit 2
fi

# Check for failures (CodeRabbit excluded, Claude Review included)
if [ "$CI_FAILURES" -gt 0 ]; then
    FAILED_NAMES=$(echo "$CHECK_RUNS" | jq -r "[.check_runs[] | select((.name | test(\"${NON_CI_CHECK_PATTERN}\"; \"i\") | not) and .conclusion==\"failure\") | .name] | join(\", \")" 2>/dev/null || echo "unknown")
    echo "[BLOCK] PR #${PR_NUM} の CI/CD に失敗あり ($CI_FAILURES 件: $FAILED_NAMES)。" >&2
    exit 2
fi

# Check for pending (same non-CI filter as pr-ci-review-gate)
if [ "$CI_PENDING" -gt 0 ]; then
    PENDING_NAMES=$(echo "$CHECK_RUNS" | jq -r "[.check_runs[] | select((.name | test(\"${NON_CI_CHECK_PATTERN}\"; \"i\") | not) and .status!=\"completed\") | .name] | join(\", \")" 2>/dev/null || echo "unknown")
    echo "[BLOCK] PR #${PR_NUM} の CI/CD がまだ実行中です ($CI_PENDING 件: $PENDING_NAMES)。" >&2
    exit 2
fi

# Check mergeable status
MERGEABLE=$(_timeout 10 gh pr view "$PR_NUM" -R "$REPO" --json mergeable -q '.mergeable' 2>/dev/null || echo "UNKNOWN")
if [ "$MERGEABLE" = "CONFLICTING" ]; then
    echo "[BLOCK] PR #${PR_NUM} にコンフリクトがあります。Codex CLIでリベースしてください。" >&2
    exit 2
fi

echo "[Merge Guard] CI/CD オールグリーン確認済み ✓" >&2
exit 0
