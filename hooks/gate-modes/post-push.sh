#!/bin/bash
# post-push.sh — POST_PUSH mode: Set pessimistic lock after push
# =========================================================================
# Exit 0 = allow (always allows push, but sets lock state)
# All output to stderr (Claude Code hooks spec)
# =========================================================================
set -euo pipefail

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh"

cmd=$(extract_cmd)
if [[ -n "$cmd" ]] && ! echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+push'; then
  exit 0
fi

BRANCH=$(current_branch)
[ -z "$BRANCH" ] && exit 0

PR_NUMBER=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "")
[ -z "$PR_NUMBER" ] && exit 0

# Set pessimistic lock (safe: env vars, not string interpolation)
_LOCK="$LOCK_STATE" _PR="$PR_NUMBER" _BR="$BRANCH" python3 -c "
import json, os, fcntl
f_path = os.environ['_LOCK']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    s[os.environ['_PR']] = {
        'status': 'review_pending',
        'branch': os.environ['_BR'],
        'ci_green': False,
        'review_lgtm': False,
        'verified': False,
    }
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null

# Reset review status for this branch (push invalidates prior reviews)
# Dual-reset: clear from BOTH project-scoped AND global state
# to prevent stale code_review=true from satisfying gates (Codex P2 finding)
GLOBAL_REVIEW="$HOME/.claude/state/review-status.json"
review_was_set=false
for _target in "$REVIEW_STATE" "$GLOBAL_REVIEW"; do
  [[ ! -f "$_target" ]] && continue
  # Check if review was previously marked as complete before clearing
  had_review=$(_STATE="$_target" _BR="$BRANCH" python3 -c "
import json, os
with open(os.environ['_STATE']) as f:
    s = json.load(f)
br = s.get(os.environ['_BR'], {})
print('true' if br.get('code_review') or br.get('codex_review') else 'false')
" 2>/dev/null || echo "false")
  [[ "$had_review" == "true" ]] && review_was_set=true
  _STATE="$_target" _BR="$BRANCH" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    s.pop(os.environ['_BR'], None)
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null
done

# Issue #33: Warn when push invalidated a completed review
if [[ "$review_was_set" == "true" ]]; then
  echo "" >&2
  echo "⚠️ [Review Reset] Push でレビューステータスがリセットされました。" >&2
  echo "  ブランチ: ${BRANCH} (PR #${PR_NUMBER})" >&2
  echo "  push前のレビュー結果は無効化されました。" >&2
  echo "  → PR作成/マージ前に code-reviewer + Codex CLI を再実行してください。" >&2
fi

REPO=$(resolve_repo "")
# Classify tier to show appropriate requirements
TIER=$(classify_review_tier "$BRANCH" "${PR_NUMBER:-}")
echo "" >&2
echo "🔒 PR #${PR_NUMBER} をロック (tier=$TIER)。以下が完了するまでマージ禁止:" >&2
echo "   1. gh pr checks ${PR_NUMBER} — 全グリーン" >&2
echo "   2. code-reviewer エージェント — LGTM" >&2
if [[ "$TIER" == "FULL" ]]; then
  echo "   3. Codex CLI セカンドオピニオン — LGTM" >&2
fi
echo "   解除: bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER}" >&2
echo "" >&2
exit 0
