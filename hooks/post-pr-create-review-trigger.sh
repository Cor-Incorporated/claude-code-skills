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
export GH_FORCE_TTY=0
export GH_NO_UPDATE_NOTIFIER=1

# Subagent exemption — subagents creating PRs is blocked by other hooks
[[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && exit 0

input=""
[[ ! -t 0 ]] && input=$(cat 2>/dev/null || echo "")
[[ -z "$input" ]] && exit 0
command -v jq &>/dev/null || exit 0

# Check if this was a gh pr create command
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
if ! echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+create'; then
  exit 0
fi

# Extract PR number from tool_response (gh pr create outputs the PR URL)
tool_response=$(echo "$input" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
PR_NUMBER=""
if [[ -n "$tool_response" ]]; then
  # gh pr create outputs URL like https://github.com/owner/repo/pull/123
  PR_NUMBER=$(echo "$tool_response" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -1)
fi

# If we can't find PR number from response, try from current branch
if [[ -z "$PR_NUMBER" ]]; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [[ -n "$BRANCH" ]]; then
    PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number -q '.[0].number' 2>/dev/null || echo "")
  fi
fi

[[ -z "$PR_NUMBER" ]] && exit 0

# Set review_pending in state file
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
mkdir -p "$STATE_DIR"

BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Write review-pending state
LOCK_STATE="$STATE_DIR/pr-review-lock.json"
[[ ! -f "$LOCK_STATE" ]] && echo '{}' > "$LOCK_STATE"

if command -v python3 &>/dev/null; then
  _PR="$PR_NUMBER" _BRANCH="$BRANCH" _LOCK="$LOCK_STATE" python3 -c "
import json, os
lock_file = os.environ['_LOCK']
with open(lock_file) as f: s = json.load(f)
s[os.environ['_PR']] = {
  'status': 'review_pending',
  'branch': os.environ['_BRANCH'],
  'ci_green': False,
  'review_lgtm': False,
  'verified': False
}
with open(lock_file, 'w') as f: json.dump(s, f, indent=2)
" 2>/dev/null
fi

# Inject review instructions via additionalContext
REVIEW_MSG="[AUTO-REVIEW REQUIRED] PR #${PR_NUMBER} を作成しました。マージ前に以下を実行してください:

1. code-reviewer エージェントでレビュー:
   Agent(subagent_type='code-reviewer', prompt='Review PR #${PR_NUMBER} on branch ${BRANCH}')

2. Codex CLI セカンドオピニオン:
   bash codex exec review --base develop

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
