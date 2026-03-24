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

# Determine state directories — write to BOTH global and project-scoped
# to prevent CWD-dependent state mismatch (Issue #7)
GLOBAL_STATE_DIR="$HOME/.claude/state"
mkdir -p "$GLOBAL_STATE_DIR"
[ ! -f "$GLOBAL_STATE_DIR/review-status.json" ] && echo '{}' > "$GLOBAL_STATE_DIR/review-status.json"

PROJECT_STATE_DIR=""
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  PROJECT_STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
fi
if [[ -n "$PROJECT_STATE_DIR" ]] && [[ "$PROJECT_STATE_DIR" != "$GLOBAL_STATE_DIR" ]]; then
  mkdir -p "$PROJECT_STATE_DIR"
  [ ! -f "$PROJECT_STATE_DIR/review-status.json" ] && echo '{}' > "$PROJECT_STATE_DIR/review-status.json"
fi

# Primary state file (global — always consistent regardless of CWD)
REVIEW_STATE="$GLOBAL_STATE_DIR/review-status.json"

# Get current branch
BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "$BRANCH" ]]; then
  exit 0
fi

# Update review-status.json: mark code_review as true for this branch
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if ! command -v python3 &>/dev/null; then
  echo "[WARN] python3 が見つかりません。レビュー記録をスキップできないため fail-closed します。" >&2
  echo "  python3 をインストールしてください。" >&2
  exit 2
fi
if command -v python3 &>/dev/null; then
  # Primary: python3 + fcntl for atomic flock write
  _STATE="$REVIEW_STATE" _BR="$BRANCH" _NOW="$NOW" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except json.JSONDecodeError:
        s = {}
    s.setdefault(os.environ['_BR'], {})['code_review'] = True
    s[os.environ['_BR']]['code_review_at'] = os.environ['_NOW']
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
"
elif command -v jq &>/dev/null; then
  # Fallback: jq (not atomic — no flock)
  tmp=$(mktemp)
  jq --arg b "$BRANCH" --arg t "$NOW" \
    '.[$b] = ((.[$b] // {}) + {"code_review": true, "code_review_at": $t})' \
    "$REVIEW_STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$REVIEW_STATE"
fi

# Also write to project-scoped state if it exists (dual-write for CWD consistency)
if [[ -n "$PROJECT_STATE_DIR" ]] && [[ "$PROJECT_STATE_DIR" != "$GLOBAL_STATE_DIR" ]]; then
  PROJECT_REVIEW="$PROJECT_STATE_DIR/review-status.json"
  if command -v python3 &>/dev/null; then
    # Primary: python3 + fcntl for atomic flock write
    _STATE="$PROJECT_REVIEW" _BR="$BRANCH" _NOW="$NOW" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except json.JSONDecodeError:
        s = {}
    s.setdefault(os.environ['_BR'], {})['code_review'] = True
    s[os.environ['_BR']]['code_review_at'] = os.environ['_NOW']
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
"
  elif command -v jq &>/dev/null; then
    # Fallback: jq (not atomic — no flock)
    tmp=$(mktemp)
    jq --arg b "$BRANCH" --arg t "$NOW" \
      '.[$b] = ((.[$b] // {}) + {"code_review": true, "code_review_at": $t})' \
      "$PROJECT_REVIEW" > "$tmp" 2>/dev/null && mv "$tmp" "$PROJECT_REVIEW"
  fi
fi

echo "✅ [review-gate] code-reviewer 完了を記録: branch=$BRANCH" >&2
exit 0
