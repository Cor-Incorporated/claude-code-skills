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
# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi
if [[ -n "$cmd" ]] && ! echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+push'; then
  exit 0
fi

BRANCH=$(current_branch)
[ -z "$BRANCH" ] && exit 0

PR_NUMBER=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "")
[ -z "$PR_NUMBER" ] && exit 0

# Set pessimistic lock in BOTH project-scoped AND global state (Fix8).
# A later reader (block-merge-without-review.sh) with no/other CLAUDE_PROJECT_DIR
# resolves to $HOME/.claude/state, so the lock must exist there too.
# Fix C: tolerate (but surface) a lock write failure. If the lock cannot be set,
# lock_apply warns to stderr; `|| _lock_rc=$?` keeps set -e from aborting here so
# the SHA-smart invalidation below still runs. A failed SET means a review-required
# PR may be left UNLOCKED — the stderr warning is the operator's signal.
_lock_rc=0
_BR="$BRANCH" lock_apply "$PR_NUMBER" "
s[PR] = {
    'status': 'review_pending',
    'branch': os.environ['_BR'],
    'ci_green': False,
    'review_lgtm': False,
    'verified': False,
}
" || _lock_rc=$?
if [[ "$_lock_rc" -ne 0 ]]; then
  echo "[post-push] WARNING: PR #${PR_NUMBER} のロック設定に失敗しました（上記参照）。マージ前に手動確認してください。" >&2
fi

# SHA-smart review invalidation (replaces the old unconditional reset).
# A completed review stays valid across pushes UNLESS the push introduced SOURCE
# changes since the reviewed commit. docs/config-only pushes keep the review
# intact, eliminating needless re-review (the rework loop).
GLOBAL_REVIEW="$HOME/.claude/state/review-status.json"
HEAD_SHA=$(git_ctx rev-parse HEAD 2>/dev/null || echo "")
review_invalidated=false
review_kept=false
for _target in "$REVIEW_STATE" "$GLOBAL_REVIEW"; do
  [[ ! -f "$_target" ]] && continue
  _info=$(_STATE="$_target" _BR="$BRANCH" python3 -c "
import json, os
try:
    with open(os.environ['_STATE']) as f:
        s = json.load(f)
except Exception:
    print('false|'); raise SystemExit
br = s.get(os.environ['_BR'], {})
had = 'true' if (br.get('code_review') or br.get('codex_review')) else 'false'
sha = br.get('code_review_sha') or br.get('codex_review_sha') or ''
print(had + '|' + sha)
" 2>/dev/null || echo "false|")
  _had="${_info%%|*}"
  _reviewed_sha="${_info#*|}"
  [[ "$_had" != "true" ]] && continue

  # Keep the review if NO source file changed since the reviewed commit.
  if [[ -n "$_reviewed_sha" ]] && [[ -n "$HEAD_SHA" ]] && ! source_changed_between "$_reviewed_sha" "$HEAD_SHA"; then
    review_kept=true
    continue
  fi

  # Otherwise invalidate (source changed, or baseline/HEAD unknown -> fail-closed).
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
  review_invalidated=true
done

if [[ "$review_invalidated" == "true" ]]; then
  echo "" >&2
  echo "⚠️ [Review Reset] ソース変更を含む push のため既存レビューを無効化しました。" >&2
  echo "  ブランチ: ${BRANCH} (PR #${PR_NUMBER})" >&2
  echo "  → マージ前に code-reviewer（FULL tier は + Codex CLI）を再実行してください。" >&2
elif [[ "$review_kept" == "true" ]]; then
  echo "" >&2
  echo "✅ [Review Kept] 非ソース変更のみのため既存レビューを維持します（再レビュー不要）。" >&2
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
