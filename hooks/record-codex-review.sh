#!/usr/bin/env bash
# record-codex-review.sh
# ========================================================================
# Records Codex CLI review completion in review-status.json.
# Called by codex-parallel.sh after --review mode completes.
#
# Usage: record-codex-review.sh <branch> [repo-path]
# State file: <project>/.claude/state/review-status.json
# ========================================================================

set -euo pipefail

BRANCH="${1:?branch required}"
REPO_PATH="${2:-$(pwd)}"

# Determine state directory
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif [[ -d "$REPO_PATH/.git" ]] || [[ -f "$REPO_PATH/.git" ]]; then
  STATE_DIR="$REPO_PATH/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
REVIEW_STATE="$STATE_DIR/review-status.json"
mkdir -p "$STATE_DIR"
[ ! -f "$REVIEW_STATE" ] && echo '{}' > "$REVIEW_STATE"

# Update review-status.json: mark codex_review as true for this branch
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if command -v jq &>/dev/null; then
  tmp=$(mktemp)
  jq --arg b "$BRANCH" --arg t "$NOW" \
    '.[$b] = ((.[$b] // {}) + {"codex_review": true, "codex_review_at": $t})' \
    "$REVIEW_STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$REVIEW_STATE"
else
  python3 -c "
import json
with open('$REVIEW_STATE') as f: s=json.load(f)
s.setdefault('$BRANCH', {})['codex_review'] = True
s['$BRANCH']['codex_review_at'] = '$NOW'
with open('$REVIEW_STATE', 'w') as f: json.dump(s, f, indent=2)
" 2>/dev/null || true
fi

echo "✅ [review-gate] Codex CLI レビュー完了を記録: branch=$BRANCH" >&2
exit 0
