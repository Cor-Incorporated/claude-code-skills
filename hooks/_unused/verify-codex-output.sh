#!/bin/bash
# verify-codex-output.sh — PostToolUse:Bash hook
# =========================================================================
# Issue #174: Detect Codex CLI phantom completions
#
# Ref: https://code.claude.com/docs/en/hooks
#   Event: PostToolUse (matcher: Bash)
#   stdin: { tool_name, tool_input, tool_response, tool_use_id }
#   Exit 0 + JSON stdout = additionalContext injected into conversation
#
# Logic:
#   1. Check if Bash command is a Codex CLI invocation
#   2. Skip review mode (no file changes expected)
#   3. Check git diff for actual file changes
#   4. Warn if implementation mode completed with no changes
#
# Performance: <100ms (ADR-003 PostToolUse ms-level requirement)
# Fail-open: Always exit 0
# =========================================================================

set -uo pipefail

# --- Read stdin ---
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi
[[ -z "$input" ]] && exit 0
command -v jq &>/dev/null || exit 0

# --- Extract command ---
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[[ -z "$cmd" ]] && exit 0

# --- Match Codex CLI commands only ---
if ! echo "$cmd" | grep -qE '(codex\s+exec|codex-parallel|codex-orchestrate)'; then
  exit 0
fi

# --- Skip review mode (no file changes expected) ---
if echo "$cmd" | grep -qE '(--review|review\s)'; then
  exit 0
fi

# --- Must be in a git repo ---
git rev-parse --git-dir &>/dev/null || exit 0

# --- Check for actual file changes ---
DIFF_UNSTAGED=$(git diff --name-only HEAD 2>/dev/null || echo "")
DIFF_STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
# Also detect changes committed by Codex (clean working tree after commit)
DIFF_COMMITTED=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")

ALL_CHANGES=$(printf '%s\n%s\n%s\n%s' "$DIFF_UNSTAGED" "$DIFF_STAGED" "$UNTRACKED" "$DIFF_COMMITTED" | sort -u | grep -v '^$' || echo "")

# --- Warn if implementation mode but no changes ---
if [[ -z "$ALL_CHANGES" ]]; then
  MSG=$(printf '%s\n%s\n%s' \
    "⚠️ [verify-codex] Codex CLI 実装完了報告あり、ファイル変更なし。" \
    "  command: $(echo "$cmd" | head -c 100)" \
    "  → Codex 出力を確認し、必要なら再実行してください。")

  jq -n --arg ctx "$MSG" '{
    "hookSpecificOutput": {
      "hookEventName": "PostToolUse",
      "additionalContext": $ctx
    }
  }'
fi

exit 0
