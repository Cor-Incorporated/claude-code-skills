#!/bin/bash
# pr-merge-claude-review-gate.sh — HARD BLOCK: enforce review reading before merge
#
# FIVE gates, ALL must pass in order:
#   Gate 0: All CI checks must be COMPLETED (not still running)
#   Gate 1: All CI checks must be GREEN (no failures)
#   Gate 2: Review comment must exist (Claude Review or code-reviewer fallback)
#   Gate 3: Agent must have read the review (pr-review-read.json)
#   Gate 4: If CRITICAL findings exist, must be explicitly acknowledged
#
# Exit 2 = BLOCK. No exceptions. No bypass.
# =========================================================================
set -euo pipefail

# Project-scoped state
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  _STATE_BASE="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  _STATE_BASE="$(git rev-parse --show-toplevel)/.claude/state"
else
  _STATE_BASE="$HOME/.claude/state"
fi
mkdir -p "$_STATE_BASE"

export GH_FORCE_TTY=0
export GH_NO_UPDATE_NOTIFIER=1

# Subagent exemption
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  exit 0
fi

input=""
[[ ! -t 0 ]] && input=$(cat)

cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

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

# Only apply to gh pr merge
if ! echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+merge'; then
  exit 0
fi

# Extract PR number
PR_NUMBER=$(echo "$(echo "$cmd" | head -1)" | grep -oE 'merge\s+([0-9]+)' | awk '{print $2}')
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER=$(echo "$(echo "$cmd" | head -1)" | grep -oE '[0-9]+' | head -1)
fi
[[ -z "$PR_NUMBER" ]] && exit 0

# Get repo (fork-aware: resolve_repo from common.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/gate-modes/common.sh"
REPO=$(resolve_repo "$cmd")
[[ -z "$REPO" ]] && exit 0

# State file
REVIEW_FILE="$_STATE_BASE/pr-review-read.json"
[ ! -f "$REVIEW_FILE" ] && echo '{}' > "$REVIEW_FILE"

# =========================================================================
# GATE 0: All CI checks must be COMPLETED
# =========================================================================
HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")
if [[ -z "$HEAD_SHA" ]]; then
  echo "[WARN] PR #${PR_NUMBER}: HEAD SHA 取得失敗。" >&2
  exit 0
fi

PENDING_COUNT=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
  --jq '[.check_runs[] | select(.status != "completed")] | length' 2>/dev/null || echo "0")

if [[ "$PENDING_COUNT" -gt 0 ]]; then
  echo "" >&2
  echo "[BLOCKED] PR #${PR_NUMBER}: CI がまだ実行中です（${PENDING_COUNT}件未完了）。" >&2
  echo "  全 CI が完了するまでマージできません。" >&2
  echo "  確認: gh pr checks ${PR_NUMBER} -R ${REPO}" >&2
  echo "" >&2
  exit 2
fi

# =========================================================================
# GATE 1: All CI checks must be GREEN
# =========================================================================
FAILED_COUNT=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
  --jq '[.check_runs[] | select(.conclusion == "failure")] | length' 2>/dev/null || echo "0")

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  echo "" >&2
  echo "[BLOCKED] PR #${PR_NUMBER}: CI に失敗があります（${FAILED_COUNT}件）。" >&2
  echo "  全 CI がグリーンになるまでマージできません。" >&2
  echo "  確認: gh pr checks ${PR_NUMBER} -R ${REPO}" >&2
  echo "" >&2
  exit 2
fi

# =========================================================================
# GATE 2: Review comment must exist
#   - First check for Claude Review (GitHub Action) comments
#   - If none exist, instruct agent to run code-reviewer as fallback
# =========================================================================
COMMENT_COUNT=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --jq 'length' 2>/dev/null || echo "0")

if [[ "$COMMENT_COUNT" -eq 0 ]]; then
  # Check if a code-reviewer fallback was already done
  FALLBACK_DONE=$(_REVIEW_FILE="$REVIEW_FILE" _PR="$PR_NUMBER" python3 -c "
import json, os
with open(os.environ['_REVIEW_FILE']) as f: s=json.load(f)
print(s.get(os.environ['_PR'], {}).get('fallback_review_done', False))
" 2>/dev/null || echo "False")

  if [[ "$FALLBACK_DONE" != "True" ]]; then
    echo "" >&2
    echo "[BLOCKED] PR #${PR_NUMBER}: レビューコメントが存在しません。" >&2
    echo "" >&2
    echo "  Claude Review workflow のコメントが見つかりません。" >&2
    echo "  以下のいずれかを実行してください:" >&2
    echo "" >&2
    echo "  A) Claude Review の完了を待つ（workflow が設定されている場合）" >&2
    echo "     gh pr checks ${PR_NUMBER} -R ${REPO}" >&2
    echo "" >&2
    echo "  B) code-reviewer エージェントで代替レビューを実行:" >&2
    echo "     Agent(subagent_type='code-reviewer', prompt='Review PR #${PR_NUMBER} ...')" >&2
    echo "     完了後、必要に応じて VERIFY を実行してから再試行してください:" >&2
    echo "     bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER}" >&2
    echo "" >&2
    exit 2
  fi
  # Fallback review was done — proceed to Gate 3
fi

# =========================================================================
# GATE 3: Review must be marked as read
# =========================================================================
REVIEW_READ=$(_REVIEW_FILE="$REVIEW_FILE" _PR="$PR_NUMBER" python3 -c "
import json, os
with open(os.environ['_REVIEW_FILE']) as f: s=json.load(f)
print(s.get(os.environ['_PR'], {}).get('review_read', False))
" 2>/dev/null || echo "False")

if [[ "$REVIEW_READ" != "True" ]]; then
  echo "" >&2
  echo "[BLOCKED] PR #${PR_NUMBER}: レビューを未読のままマージしようとしています。" >&2
  echo "" >&2
  echo "  以下を実行してください（レビュー読み取り＋既読マークを一括で行います）:" >&2
  echo "     bash ~/.claude/scripts/verify-pr-review.sh ${PR_NUMBER}" >&2
  echo "" >&2
  echo "  ※ verify-pr-review.sh はレビュー内容を表示し、問題なければ自動で既読マークします。" >&2
  echo "  ※ 直接 pr-review-read.json を書き換える必要はありません (Issue #151)。" >&2
  echo "" >&2
  exit 2
fi

# =========================================================================
# GATE 4: If CRITICAL findings, must be acknowledged
# Issue #154: If claude-review CI check passed, skip CRITICAL check.
# Accumulated old comments cause false positives; CI pass = latest is clean.
# Issue #165: Use commit-level check-runs API instead of `gh pr checks`
# to avoid false positives from residual review bot comments (CodeRabbit,
# Copilot etc.) and fragile awk parsing.
# =========================================================================
CLAUDE_REVIEW_STATUS=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
  --jq '[.check_runs[] | select(.name | test("claude-review"; "i"))] | .[0].conclusion // ""' 2>/dev/null || echo "")
if [[ "$CLAUDE_REVIEW_STATUS" == "success" ]] || [[ -z "$CLAUDE_REVIEW_STATUS" ]]; then
  HAS_CRITICAL="NO"
  # claude-review CI passed or not configured → skip comment-based CRITICAL detection
else
  # Check both issue comments and fallback review state for CRITICAL
  HAS_CRITICAL="NO"
if [[ "$COMMENT_COUNT" -gt 0 ]]; then
  HAS_CRITICAL=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --jq '.[].body' 2>/dev/null | python3 -c "
import sys, re
bodies = sys.stdin.read()
patterns = [
r'(?i)\bcritical\b.*(?:issue|bug|finding)',
r'(?i)critical\s+issues',
r'(?i)\|\s*critical\s*\|',
r'(?i)\|\s*CRITICAL\s*\|',
r'(?i)## critical',
]
for pat in patterns:
    if re.search(pat, bodies):
        print('YES')
        sys.exit(0)
print('NO')
" 2>/dev/null || echo "NO")
fi

# Also check if fallback review flagged critical
if [[ "$HAS_CRITICAL" == "NO" ]]; then
  HAS_CRITICAL=$(_REVIEW_FILE="$REVIEW_FILE" _PR="$PR_NUMBER" python3 -c "
import json, os
with open(os.environ['_REVIEW_FILE']) as f: s=json.load(f)
print('YES' if s.get(os.environ['_PR'], {}).get('has_critical', False) else 'NO')
" 2>/dev/null || echo "NO")
fi

if [[ "$HAS_CRITICAL" == "YES" ]]; then
  CRITICAL_ACK=$(_REVIEW_FILE="$REVIEW_FILE" _PR="$PR_NUMBER" python3 -c "
import json, os
with open(os.environ['_REVIEW_FILE']) as f: s=json.load(f)
print(s.get(os.environ['_PR'], {}).get('critical_acknowledged', False))
" 2>/dev/null || echo "False")

  if [[ "$CRITICAL_ACK" != "True" ]]; then
    echo "" >&2
    echo "[BLOCKED] PR #${PR_NUMBER}: CRITICAL 指摘が未対応です。" >&2
    echo "" >&2
    echo "  修正を push し、レビューを再確認したうえで正規フローを完了してください。" >&2
    echo "  code-reviewer の再実行、または必要な確認後に VERIFY を再実行してください:" >&2
    echo "  bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER}" >&2
    echo "" >&2
    exit 2
  fi
fi  # close claude-review pass check
fi

echo "✅ PR #${PR_NUMBER}: CI green + レビュー確認済み。マージ許可。" >&2
exit 0
