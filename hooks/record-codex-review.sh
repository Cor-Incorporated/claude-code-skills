#!/usr/bin/env bash
# record-codex-review.sh
# ========================================================================
# Records Codex CLI review completion in review-status.json.
# Called by codex-parallel.sh after --review mode completes.
#
# Dual-write: writes to BOTH global and project-scoped state files
# to prevent path-dependent mismatch (Issue #35).
# Pattern matches record-code-review.sh (PostToolUse hook).
#
# Usage: record-codex-review.sh <branch> [repo-path]
# State file: ~/.claude/state/review-status.json (global)
#             <project>/.claude/state/review-status.json (project-scoped)
# ========================================================================

set -euo pipefail

BRANCH="${1:?branch required}"
REPO_PATH="${2:-$(pwd)}"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Helper: write codex_review to a single state file ---
write_codex_review() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  [ ! -f "$target" ] && echo '{}' > "$target"

  if command -v jq &>/dev/null; then
    # Atomic read-modify-write with portable locking (Issue #129)
    # macOS: use Python fcntl; Linux: use flock command
    if command -v flock &>/dev/null; then
      (
        flock -x 200
        local tmp
        tmp=$(mktemp)
        if jq --arg b "$BRANCH" --arg t "$NOW" \
          '.[$b] = ((.[$b] // {}) + {"codex_review": true, "codex_review_at": $t})' \
          "$target" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$target"
        else
          rm -f "$tmp"
          echo '{}' > "$target"
          tmp=$(mktemp)
          jq --arg b "$BRANCH" --arg t "$NOW" \
            '.[$b] = {"codex_review": true, "codex_review_at": $t}' \
            "$target" > "$tmp" 2>/dev/null && mv "$tmp" "$target" || rm -f "$tmp"
        fi
      ) 200>"${target}.lock"
    else
      # macOS fallback: use Python fcntl.flock for locking + jq for transform
      _STATE="$target" _BR="$BRANCH" _NOW="$NOW" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
br = os.environ['_BR']
now = os.environ['_NOW']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        data = {}
    if br not in data:
        data[br] = {}
    data[br]['codex_review'] = True
    data[br]['codex_review_at'] = now
    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null || true
    fi
  else
    _STATE="$target" _BR="$BRANCH" _NOW="$NOW" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    s.setdefault(os.environ['_BR'], {})['codex_review'] = True
    s[os.environ['_BR']]['codex_review_at'] = os.environ['_NOW']
    f.seek(0)
    f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null || true
  fi
}

# --- Determine project-scoped state directory ---
PROJECT_STATE_DIR=""
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif [[ -d "$REPO_PATH/.git" ]] || [[ -f "$REPO_PATH/.git" ]]; then
  PROJECT_STATE_DIR="$REPO_PATH/.claude/state"
fi

# --- Global state (always write) ---
GLOBAL_STATE="$HOME/.claude/state/review-status.json"
write_codex_review "$GLOBAL_STATE"

# --- Project-scoped state (write if different from global) ---
if [[ -n "$PROJECT_STATE_DIR" ]] && [[ "$PROJECT_STATE_DIR" != "$HOME/.claude/state" ]]; then
  write_codex_review "$PROJECT_STATE_DIR/review-status.json"
fi

echo "✅ [review-gate] Codex CLI レビュー完了を記録: branch=$BRANCH" >&2
exit 0
