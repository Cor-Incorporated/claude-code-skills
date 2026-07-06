#!/bin/bash
# post-pr-create-review-trigger.sh — PostToolUse hook (Bash)
# =========================================================================
# Issue #72: Auto-trigger review after PR creation
#
# Ref: https://code.claude.com/docs/en/hooks
#   Event: PostToolUse (matcher: Bash)
#   stdin: { tool_name, tool_input, tool_response, tool_use_id }
#   Exit 0 + JSON = additionalContext injected
#   Cannot block (tool already executed)
#
# Logic:
#   1. Detect gh pr create in tool_input.command
#   2. Extract PR URL/number from tool_response
#   3. Set review_pending in state file
#   4. Inject review instructions via additionalContext
# =========================================================================

set -euo pipefail
unset GH_FORCE_TTY
export GH_NO_UPDATE_NOTIFIER=1

# Subagent exemption — subagents creating PRs is blocked by other hooks
[[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && exit 0

input=""
[[ ! -t 0 ]] && input=$(cat 2>/dev/null || echo "")
[[ -z "$input" ]] && exit 0
command -v jq &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

# Check if this was a gh pr create command
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[[ "$cmd" == *"gh"* && "$cmd" == *"pr"* && "$cmd" == *"create"* ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/gate-modes/common.sh"

CREATE_COUNT=$(count_gh_pr_create_invocations "$cmd" || echo 0)
if [[ "$CREATE_COUNT" -eq 0 ]]; then
  exit 0
fi
if [[ "$CREATE_COUNT" -gt 1 ]]; then
  echo "[post-pr-create] 複数の gh pr create を検出したため、PRレビュー状態の自動記録をスキップしました。" >&2
  exit 0
fi

# Extract PR number from tool_response (gh pr create outputs the PR URL)
tool_response=$(echo "$input" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
PR_NUMBER=""
RESPONSE_REPO=""
if [[ -n "$tool_response" ]]; then
  # gh pr create outputs URL like https://github.com/owner/repo/pull/123
  PR_NUMBER=$(echo "$tool_response" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -1)
  RESPONSE_REPO=$(echo "$tool_response" | grep -oE 'github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | sed -E 's|github\.com/([^/]+)/([^/]+)/pull/[0-9]+|\1/\2|' | head -1)
fi

_cmd_context=$(command_git_context_dir "$cmd")
if [[ -n "$_cmd_context" ]]; then
  export GIT_CONTEXT_DIR="$_cmd_context"
  use_git_context_state_dir
fi

BRANCH=$(current_branch "$cmd")
REPO=$(resolve_repo "$cmd")
[[ -n "$RESPONSE_REPO" ]] && REPO="$RESPONSE_REPO"

# If we can't find PR number from response, try from current branch
if [[ -z "$PR_NUMBER" ]]; then
  if [[ -n "$BRANCH" ]]; then
    if [[ -n "$REPO" ]]; then
      PR_NUMBER=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number -q '.[0].number // empty' 2>/dev/null || echo "")
    else
      PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number -q '.[0].number // empty' 2>/dev/null || echo "")
    fi
  fi
fi

[[ -z "$PR_NUMBER" ]] && exit 0

# Validate PR number is numeric
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  exit 0
fi

HEAD_SHA=""
if [[ -n "$REPO" ]]; then
  HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha // ""' 2>/dev/null || echo "")
fi
if [[ -z "$HEAD_SHA" || "$HEAD_SHA" == "null" ]]; then
  if [[ -n "$REPO" ]]; then
    HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q '.headRefOid // empty' 2>/dev/null || echo "")
  else
    HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid -q '.headRefOid // empty' 2>/dev/null || echo "")
  fi
fi
if [[ -z "$HEAD_SHA" || "$HEAD_SHA" == "null" ]]; then
  if [[ -n "$BRANCH" ]]; then
    HEAD_SHA=$(git_ctx rev-parse "$BRANCH" 2>/dev/null || git_ctx rev-parse "refs/remotes/origin/${BRANCH}" 2>/dev/null || echo "")
  fi
  [[ -z "$HEAD_SHA" ]] && HEAD_SHA=$(git_ctx rev-parse HEAD 2>/dev/null || echo "")
fi

# Write review-pending state to BOTH project-scoped AND global lock files (Fix8).
# block-merge-without-review.sh (CLAUDE_PROJECT_DIR unset) reads the global file,
# so the lock must be present there too.
_lock_rc=0
_BRANCH="$BRANCH" _REPO="$REPO" _HEAD_SHA="$HEAD_SHA" lock_apply "$PR_NUMBER" "
s[PR] = {
    'status': 'review_pending',
    'repo': os.environ['_REPO'],
    'branch': os.environ['_BRANCH'],
    'head_sha': os.environ['_HEAD_SHA'],
    'ci_green': False,
    'review_lgtm': False,
    'verified': False
}
" || _lock_rc=$?
if [[ "$_lock_rc" -ne 0 ]]; then
  echo "[post-pr-create] WARNING: PR #${PR_NUMBER} のレビュー状態保存に失敗しました（上記参照）。" >&2
fi

# Inject review instructions via additionalContext
REVIEW_MSG="[AUTO-REVIEW REQUIRED] PR #${PR_NUMBER} を作成しました。マージ前に以下を実行してください:

1. code-reviewer エージェントでレビュー:
   Agent(subagent_type='code-reviewer', prompt='Review PR #${PR_NUMBER} on ${REPO:-current repo} branch ${BRANCH}')

2. Codex CLI セカンドオピニオン:
   codex exec review --base develop

3. 全CRITICAL/HIGH指摘を修正

4. レビュー完了後にマージ:
   gh pr merge ${PR_NUMBER} --merge

レビューなしでのタスク完了・セッション終了はブロックされます。"

if command -v jq &>/dev/null; then
  jq -n --arg ctx "$REVIEW_MSG" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
fi

echo "[post-pr-create] PR #${PR_NUMBER} 作成検出。レビュー必須。" >&2
exit 0
