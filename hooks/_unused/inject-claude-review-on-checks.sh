#!/bin/bash
# inject-claude-review-on-checks.sh — PreToolUse hook (matcher: Bash)
#
# Multi-mode hook for review quality enforcement:
# 1. On `gh pr checks` → fetch reviews, save to state, output summary
# 2. On `gh pr merge` → hard block if unresolved CRITICAL/HIGH
# 3. On any Bash → if pending reviews exist, remind via stderr
#
# Exit 0 = allow, Exit 2 = block
set -uo pipefail
export GH_NO_UPDATE_NOTIFIER=1
unset GH_FORCE_TTY

input=""
[[ ! -t 0 ]] && input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_common_merge_count() {
  _COMMON_SH="${SCRIPT_DIR}/gate-modes/common.sh" _CMD="$1" bash -c '
source "$_COMMON_SH"
count_gh_pr_merge_invocations "$_CMD"
' 2>/dev/null || echo 0
}

_common_merge_target() {
  _COMMON_SH="${SCRIPT_DIR}/gate-modes/common.sh" _CMD="$1" bash -c '
source "$_COMMON_SH"
extract_gh_pr_merge_target "$_CMD"
' 2>/dev/null || echo ""
}

MERGE_COUNT=$(_common_merge_count "$cmd")

_IS_SUBAGENT=0
case "${CLAUDE_AGENT_DEPTH:-0}" in
  ''|*[!0-9]*) ;;
  *) [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && _IS_SUBAGENT=1 ;;
esac
[[ -n "${CLAUDE_AGENT_ID:-}" ]] && _IS_SUBAGENT=1
if [[ "$_IS_SUBAGENT" -eq 1 && "$MERGE_COUNT" -eq 0 ]]; then
  exit 0
fi

# Project-scoped state
if git rev-parse --show-toplevel &>/dev/null 2>&1; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
mkdir -p "$STATE_DIR"
PENDING_FILE="$STATE_DIR/pending-review-comments.json"

# Issue #169: Shared severity reader — replaces duplicated python3 one-liners
_read_severity() {
  local file="$1"
  _PENDING_FILE="$file" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
ai = d.get('ai_classification') or {}
method = d.get('classification_method', 'regex')
if method == 'ai':
    c, h = ai.get('critical', d.get('critical', 0)), ai.get('high', d.get('high', 0))
else:
    c, h = d.get('critical', 0), d.get('high', 0)
print(f'{c}|{h}|{d.get(\"pr\", \"\")}|{d.get(\"head_sha\", \"\")}|{d.get(\"total\", 0)}|{method}')
" 2>/dev/null || echo "0|0|||0|regex"
}

_review_comment_set_hash_script() {
  local hook_dir candidate
  hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "$HOME/.claude/scripts/review-comment-set-hash.sh" \
    "${hook_dir}/../scripts/review-comment-set-hash.sh"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

_pending_comment_set_current() {
  local pending_file="$1"
  local repo="$2"
  local pr_number="$3"
  local head_sha="$4"
  local state_hash script current_hash

  [[ -f "$pending_file" ]] || return 1
  [[ -n "$repo" && -n "$pr_number" && -n "$head_sha" ]] || return 1

  state_hash=$(jq -r '.comment_set_hash // ""' "$pending_file" 2>/dev/null || echo "")
  [[ -n "$state_hash" && "$state_hash" != "null" ]] || return 1

  script="$(_review_comment_set_hash_script || true)"
  [[ -n "$script" ]] || return 1

  current_hash="$(bash "$script" "$pr_number" "$repo" "$head_sha" 2>/dev/null || echo "")"
  [[ -n "$current_hash" && "$current_hash" == "$state_hash" ]]
}

# =========================================================================
# MODE 1: gh pr checks → fetch reviews and save state
# =========================================================================
if echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+checks'; then
  PR_NUMBER=$(echo "$(echo "$cmd" | head -1)" | grep -oE '[0-9]+' | head -1)
  [[ -z "$PR_NUMBER" ]] && exit 0

  REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  [[ -z "$REPO" ]] && exit 0

  # Fetch and save via Python helper (stdin=/dev/null to avoid pipe issues)
  # Issue #66 Fix #4: Do not suppress stderr — surface errors instead of silent failure
  python3 ~/.claude/hooks/inject-claude-review-helper.py "$REPO" "$PR_NUMBER" </dev/null >/dev/null 2>"$STATE_DIR/inject-review-errors.log" || {
    echo "[inject-claude-review] Python helper failed. See $STATE_DIR/inject-review-errors.log" >&2
  }

  # Read back the saved state and output as reminder
  if [[ -f "$PENDING_FILE" ]]; then
    OUTPUT=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f:
    d = json.load(f)
print(d.get('output', ''))
" 2>/dev/null || echo "")

    if [[ -n "$OUTPUT" ]]; then
      echo "" >&2
      echo "═══════════════════════════════════════════════════" >&2
      echo "$OUTPUT" >&2
      echo "═══════════════════════════════════════════════════" >&2
      echo "" >&2
    fi
  fi
  exit 0
fi

# =========================================================================
# MODE 2 (gh pr merge hard-block) was removed in Phase 3.
# The consolidated pre-merge.sh (sourced via pr-ci-review-gate.sh PRE_MERGE)
# now performs the merge-time gate (CI green + Gate 0-4 + C/H/BUG severity).
# MODE 1 (gh pr checks fetch) and MODE 3 (soft reminder) remain below.
# =========================================================================

# =========================================================================
# MODE 3: Any other Bash → soft reminder if pending reviews exist
# =========================================================================
# Only remind occasionally (not on every single command)
# Skip for: git, ls, cat, echo, python3, etc.
if echo "$(echo "$cmd" | head -1)" | grep -qE '^(git |ls |cat |echo |python3 |head |tail |grep |find |test |set )'; then
  exit 0
fi

if [[ -f "$PENDING_FILE" ]]; then
  # Issue #169: Use shared severity reader instead of duplicated python3 one-liners
  IFS='|' read -r CRITICAL _HIGH _PR _SHA TOTAL _METHOD <<< "$(_read_severity "$PENDING_FILE")"

  if [[ "$TOTAL" -gt 0 ]] && [[ "$CRITICAL" -gt 0 ]]; then
    echo "[REMINDER] PR #${_PR}: ${TOTAL}件のレビューコメント（CRITICAL=${CRITICAL}）が未対応です。" >&2
  fi
fi

exit 0
