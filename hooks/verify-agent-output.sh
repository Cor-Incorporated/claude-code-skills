#!/bin/bash
# verify-agent-output.sh — PostToolUse:Agent hook
# =========================================================================
# Issue #173: Detect agent phantom completions (false "done" reports)
#
# Ref: https://code.claude.com/docs/en/hooks
#   Event: PostToolUse (matcher: Agent)
#   stdin: { tool_name, tool_input, tool_response, tool_use_id }
#   Exit 0 + JSON stdout = additionalContext injected into conversation
#
# Logic:
#   1. Skip research/review agents (no file changes expected)
#   2. Skip worktree-isolated agents (changes in separate worktree)
#   3. Run git diff to detect actual file changes
#   4. Parse claimed files from agent response
#   5. Compare expected/claimed vs actual → warn via additionalContext
#
# Performance: <200ms (ADR-003 PostToolUse ms-level requirement)
# Fail-open: Always exit 0 (PostToolUse cannot block after execution)
# Coverage: Sub-agents + TeamCreate workers (PostToolUse:Agent fires for both)
# =========================================================================

set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# --- Read stdin ---
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi
[[ -z "$input" ]] && exit 0
command -v jq &>/dev/null || exit 0

# --- Extract agent metadata ---
subagent_type=$(echo "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
isolation=$(echo "$input" | jq -r '.tool_input.isolation // ""' 2>/dev/null || echo "")
prompt=$(echo "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")
description=$(echo "$input" | jq -r '.tool_input.description // ""' 2>/dev/null || echo "")

# --- Extract agent response (handle both string and object forms) ---
agent_response=$(echo "$input" | jq -r '
  if .tool_response | type == "object" then
    .tool_response.last_assistant_message // ""
  elif .tool_response | type == "string" then
    .tool_response
  else
    ""
  end
' 2>/dev/null || echo "")

# =========================================================================
# Skip criteria
# =========================================================================

# 1. Research agents: no file changes expected
#    (Same set as context-budget-agent-gate.sh L79-84)
RESEARCH_TYPES="Explore|architect|planner|Plan|code-reviewer|security-reviewer"
RESEARCH_TYPES="${RESEARCH_TYPES}|feature-dev:code-reviewer|feature-dev:code-explorer"
RESEARCH_TYPES="${RESEARCH_TYPES}|feature-dev:code-architect|claude-code-guide|general-purpose"

if [[ -n "$subagent_type" ]] && echo "$subagent_type" | grep -qE "^(${RESEARCH_TYPES})$"; then
  exit 0
fi

# Also check description for research keywords
_desc_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')
case "$_desc_lower" in
  *調査*|*確認*|*check*|*review*|*explore*|*research*|*read*|*verify*|*分析*|*検証*|*compare*)
    exit 0
    ;;
esac

# 2. Worktree isolation: changes won't appear in main git diff
# Issue #220: worktree agents now auto-commit via auto-commit-worktree-changes.sh
if [[ "$isolation" == "worktree" ]]; then
  exit 0
fi

# 3. Must be in a git repo
git rev-parse --git-dir &>/dev/null || exit 0

# =========================================================================
# Detect actual file changes via git diff
# =========================================================================

DIFF_UNSTAGED=$(git diff --name-only HEAD 2>/dev/null || echo "")
DIFF_STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
# Also detect changes committed by the agent (clean working tree after commit)
DIFF_COMMITTED=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")

# Combine all changes (deduplicated)
ALL_CHANGES=$(printf '%s\n%s\n%s\n%s' "$DIFF_UNSTAGED" "$DIFF_STAGED" "$UNTRACKED" "$DIFF_COMMITTED" | sort -u | grep -v '^$' || echo "")

# =========================================================================
# Parse agent response for edit claims
# =========================================================================

CLAIMED_FILES=""
if [[ -n "$agent_response" ]]; then
  CLAIMED_FILES=$(echo "$agent_response" \
    | grep -oiE "(edited|modified|created|wrote|updated|changed|writing|creating)\s+[\x60\"']?[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|py|go|sh|json|md|yaml|yml|css|html|vue|svelte|rs|rb|toml)" \
    | grep -oE '[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|py|go|sh|json|md|yaml|yml|css|html|vue|svelte|rs|rb|toml)' \
    | sort -u 2>/dev/null || echo "")
fi

# =========================================================================
# Comparison and warning generation
# =========================================================================

WARNINGS=""

# Case A: Non-research agent completed but git diff is empty
if [[ -z "$ALL_CHANGES" ]]; then
  WARNINGS="⚠️ [verify-agent] エージェント完了報告あり、ファイル変更なし。"
  WARNINGS="${WARNINGS}\n  subagent_type: ${subagent_type:-unknown}"
  WARNINGS="${WARNINGS}\n  git diff --name-only: (空)"
  WARNINGS="${WARNINGS}\n  → エージェント出力を確認し、必要なら再実行してください。"
fi

# Case B: Agent claims specific files were edited but they're not in diff
if [[ -n "$CLAIMED_FILES" ]] && [[ -n "$ALL_CHANGES" ]]; then
  UNVERIFIED=""
  while IFS= read -r claimed; do
    [[ -z "$claimed" ]] && continue
    if ! echo "$ALL_CHANGES" | grep -qF "$claimed"; then
      UNVERIFIED="${UNVERIFIED}${UNVERIFIED:+, }${claimed}"
    fi
  done <<< "$CLAIMED_FILES"

  if [[ -n "$UNVERIFIED" ]]; then
    if [[ -n "$WARNINGS" ]]; then
      WARNINGS="${WARNINGS}\n"
    fi
    WARNINGS="${WARNINGS}⚠️ [verify-agent] 未検証ファイル: ${UNVERIFIED}"
    WARNINGS="${WARNINGS}\n  エージェントが編集を主張しましたが git diff に存在しません。"
  fi
fi

# =========================================================================
# Output via additionalContext (only if warnings exist)
# =========================================================================

if [[ -n "$WARNINGS" ]]; then
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "verify-agent-output" "warn" "warn" "subagent=${subagent_type:-unknown}" "phantom-or-unverified-claim"
  fi
  MSG=$(printf '%b' "$WARNINGS")
  jq -n --arg ctx "$MSG" '{
    "hookSpecificOutput": {
      "hookEventName": "PostToolUse",
      "additionalContext": $ctx
    }
  }'
fi

exit 0
