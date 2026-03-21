#!/usr/bin/env bash
# record-code-review.sh
# ========================================================================
# PostToolUse hook: Records code-reviewer agent completion in review-status.json.
# When an Agent tool completes with subagent_type "code-reviewer" or
# name containing "review", marks the current branch as reviewed.
#
# Trigger: PostToolUse for Agent tool
# State file: <project>/.claude/state/review-status.json
# ========================================================================

# Subagent hooks should still record reviews
# (no subagent exemption here)

# Read stdin (tool input JSON) — macOS compatible (no timeout command)
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

# Check if this was a code-reviewer agent
IS_REVIEW="false"
if [[ -n "$input" ]] && command -v jq &>/dev/null; then
  # Check subagent_type
  subagent_type=$(echo "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
  # Check agent name
  agent_name=$(echo "$input" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
  # Check prompt for review keywords
  prompt=$(echo "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

  if [[ "$subagent_type" == "code-reviewer" ]] || \
     [[ "$subagent_type" == *"review"* ]] || \
     [[ "$agent_name" == *"review"* ]]; then
    IS_REVIEW="true"
  fi

  # Also detect feature-dev:code-reviewer
  if [[ "$subagent_type" == "feature-dev:code-reviewer" ]]; then
    IS_REVIEW="true"
  fi
fi

# Exit early if not a review agent
if [[ "$IS_REVIEW" != "true" ]]; then
  exit 0
fi

# Determine state directory
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
REVIEW_STATE="$STATE_DIR/review-status.json"
mkdir -p "$STATE_DIR"
[ ! -f "$REVIEW_STATE" ] && echo '{}' > "$REVIEW_STATE"

# Get current branch
BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "$BRANCH" ]]; then
  exit 0
fi

# Update review-status.json: mark code_review as true for this branch
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if command -v jq &>/dev/null; then
  tmp=$(mktemp)
  jq --arg b "$BRANCH" --arg t "$NOW" \
    '.[$b] = ((.[$b] // {}) + {"code_review": true, "code_review_at": $t})' \
    "$REVIEW_STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$REVIEW_STATE"
else
  # Fallback: python3 (safe: env vars, not string interpolation)
  _STATE="$REVIEW_STATE" _BR="$BRANCH" _NOW="$NOW" python3 -c "
import json, os
f_path = os.environ['_STATE']
with open(f_path) as f: s = json.load(f)
s.setdefault(os.environ['_BR'], {})['code_review'] = True
s[os.environ['_BR']]['code_review_at'] = os.environ['_NOW']
with open(f_path, 'w') as f: json.dump(s, f, indent=2)
" 2>/dev/null || true
fi

echo "✅ [review-gate] code-reviewer 完了を記録: branch=$BRANCH" >&2
exit 0
