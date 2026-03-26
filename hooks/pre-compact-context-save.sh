#!/bin/bash
# pre-compact-context-save.sh — PreCompact hook: save critical context before compaction
# =========================================================================
# Fires before context compaction (manual or auto).
# Saves critical state information to additionalContext so it survives
# the compaction process and remains available to Claude.
#
# Ref: Issue #146, Best Practices Section 2.2
# =========================================================================
# No -e: continue collecting context even if individual sections fail
set -uo pipefail

STATE_DIR="${HOME}/.claude/state"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# --- Collect critical context ---
context_parts=()

# 1. Active tasks summary
if command -v claude &>/dev/null 2>&1; then
  # TaskList is available via Claude Code internals — skip, handled by system
  :
fi

# 2. Current branch and uncommitted changes summary
if command -v git &>/dev/null && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  dirty_count=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  context_parts+=("Branch: $branch | Uncommitted: ${dirty_count} files")

  # Recent commits on this branch (last 3)
  recent=$(git -C "$PROJECT_DIR" log --oneline -3 2>/dev/null | tr '\n' '; ' || echo "")
  if [[ -n "$recent" ]]; then
    context_parts+=("Recent commits: $recent")
  fi
fi

# 3. Open PR status
if command -v gh &>/dev/null 2>&1; then
  open_prs=$(gh pr list --state open --json number,title --limit 5 2>/dev/null | \
    python3 -c "
import json, sys
try:
    prs = json.load(sys.stdin)
    for pr in prs:
        print(f'  PR #{pr[\"number\"]}: {pr[\"title\"]}')
except: pass
" 2>/dev/null || echo "")
  if [[ -n "$open_prs" ]]; then
    context_parts+=("Open PRs:")
    context_parts+=("$open_prs")
  fi
fi

# 4. Review/CI gate state
if [[ -f "$STATE_DIR/review-status.json" ]]; then
  review_summary=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for pr, info in data.items():
        status = 'reviewed' if info.get('reviewed') else 'pending'
        print(f'  {pr}: {status}')
except: pass
" "$STATE_DIR/review-status.json" 2>/dev/null || echo "")
  if [[ -n "$review_summary" ]]; then
    context_parts+=("Review status: $review_summary")
  fi
fi

# 5. Factcheck state
if [[ -f "$STATE_DIR/factcheck-status.json" ]]; then
  fc_state=$(_STATE="$STATE_DIR/factcheck-status.json" python3 -c "
import json, os
with open(os.environ['_STATE']) as f:
    d = json.load(f)
print(f'factchecked={d.get(\"factchecked\",False)}, source={d.get(\"source\",\"none\")}')
" 2>/dev/null || echo "unknown")
  context_parts+=("Factcheck: $fc_state")
fi

# --- Output additionalContext if any ---
if [[ ${#context_parts[@]} -gt 0 ]]; then
  # Build message
  message="Pre-compact context snapshot:"
  for part in "${context_parts[@]}"; do
    message="${message}\n${part}"
  done

  # stderr: diagnostic
  echo "[PreCompact] Saving context snapshot (${#context_parts[@]} items)" >&2

  # stdout: JSON additionalContext
  python3 -c "
import json, sys
msg = sys.argv[1]
output = {
    'hookSpecificOutput': {
        'hookEventName': 'PreCompact',
        'additionalContext': msg
    }
}
print(json.dumps(output))
" "$message"
fi

exit 0
