#!/bin/bash
# pr-ci-review-gate.sh — ABSOLUTE ENFORCEMENT: CI green + review LGTM gate
# Prevent gh CLI TTY hangs in non-interactive contexts
export GH_FORCE_TTY=0
export GH_NO_UPDATE_NOTIFIER=1
# =========================================================================
# This hook operates in THREE modes based on GATE_MODE env var:
#
# 1. PRE_CREATE  — Blocks `gh pr create` unless review pipeline completed
# 2. POST_PUSH   — Sets pessimistic lock after every `git push`
# 3. STOP         — Blocks session stop if any PR has pending review/CI
#
# Exit 2 = HARD BLOCK. No skip. No override.
# =========================================================================
set -euo pipefail

GATE_MODE="${GATE_MODE:-STOP}"

# =========================================================================
# Project-scoped state: use CLAUDE_PROJECT_DIR to isolate per-project.
# Falls back to git root, then cwd, then global ~/.claude/state as last resort.
# This prevents PR state from one project leaking into another.
# =========================================================================
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
REVIEW_STATE="$STATE_DIR/review-status.json"
LOCK_STATE="$STATE_DIR/pr-review-lock.json"
mkdir -p "$STATE_DIR"
[ ! -f "$REVIEW_STATE" ] && echo '{}' > "$REVIEW_STATE"
[ ! -f "$LOCK_STATE" ] && echo '{}' > "$LOCK_STATE"

# Subagent exemption (subagents can't create PRs or stop sessions)
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  exit 0
fi

input=""
[[ ! -t 0 ]] && input=$(cat)

# =========================================================================
# MODE: PRE_CREATE — Block PR creation without review
# =========================================================================
if [[ "$GATE_MODE" == "PRE_CREATE" ]]; then
  cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
  
  # Only apply to gh pr create
  if ! echo "$cmd" | grep -qE 'gh\s+pr\s+create'; then
    exit 0
  fi

  # Exempt doc/chore/ci branches
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  case "$BRANCH" in docs/*|chore/*|ci/*) exit 0 ;; esac

  # Check review status
  CODE_REVIEW=$(python3 -c "
import json
with open('$REVIEW_STATE') as f: s=json.load(f)
b=s.get('$BRANCH',{})
print('yes' if b.get('code_review') else 'no')
" 2>/dev/null || echo "no")

  CODEX_REVIEW=$(python3 -c "
import json
with open('$REVIEW_STATE') as f: s=json.load(f)
b=s.get('$BRANCH',{})
print('yes' if b.get('codex_review') else 'no')
" 2>/dev/null || echo "no")

  MISSING=""
  [[ "$CODE_REVIEW" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
  [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "

  if [[ -n "$MISSING" ]]; then
    MISSING="${MISSING%, }"
    echo "[BLOCKED] PR作成を拒否。レビューパイプライン未完了。" >&2
    echo "  ブランチ: $BRANCH" >&2
    echo "  未完了: $MISSING" >&2
    echo "  レビュー実施後に再試行してください。" >&2
    exit 2
  fi
  exit 0
fi

# =========================================================================
# MODE: POST_PUSH — Set pessimistic lock after push
# =========================================================================
if [[ "$GATE_MODE" == "POST_PUSH" ]]; then
  cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
  if ! echo "$cmd" | grep -qE 'git\s+push'; then
    exit 0
  fi

  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  [ -z "$BRANCH" ] && exit 0

  PR_NUMBER=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "")
  [ -z "$PR_NUMBER" ] && exit 0

  # Set pessimistic lock
  python3 -c "
import json
with open('$LOCK_STATE') as f: s=json.load(f)
s['$PR_NUMBER']={
  'status':'review_pending',
  'branch':'$BRANCH',
  'ci_green':False,
  'review_lgtm':False,
  'verified':False
}
with open('$LOCK_STATE','w') as f: json.dump(s,f,indent=2)
" 2>/dev/null

  # Reset review status for this branch (push invalidates prior reviews)
  python3 -c "
import json
with open('$REVIEW_STATE') as f: s=json.load(f)
s.pop('$BRANCH', None)
with open('$REVIEW_STATE','w') as f: json.dump(s,f,indent=2)
" 2>/dev/null

  echo "" >&2
  echo "🔒 PR #${PR_NUMBER} をロック。以下が完了するまで「完了」報告禁止:" >&2
  echo "   1. gh pr checks ${PR_NUMBER} — 全グリーン" >&2
  echo "   2. code-reviewer エージェント — LGTM" >&2
  echo "   3. Codex CLI セカンドオピニオン — LGTM" >&2
  echo "   解除: bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER}" >&2
  echo "" >&2
  exit 0
fi

# =========================================================================
# MODE: STOP — Block session stop if unverified PRs exist
# =========================================================================
if [[ "$GATE_MODE" == "STOP" ]]; then
  UNVERIFIED=$(python3 -c "
import json
with open('$LOCK_STATE') as f: s=json.load(f)
unverified=[]
for pr, data in s.items():
  if isinstance(data, dict) and not data.get('verified', False):
    unverified.append(f'PR #{pr} ({data.get(\"branch\",\"?\")})')
if unverified:
  print('|'.join(unverified))
else:
  print('')
" 2>/dev/null || echo "")

  if [[ -n "$UNVERIFIED" ]]; then
    echo '{"decision":"block","reason":"[BLOCKED] 未検証PRが存在します。CI green + レビュー LGTM を確認してください。\n'"$(echo "$UNVERIFIED" | tr '|' '\n' | sed 's/^/  - /')"'\n\n解除方法:\n  1. gh pr checks <PR番号> で全グリーン確認\n  2. code-reviewer + Codex CLI レビュー実行\n  3. bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY <PR番号>"}'
    exit 0
  fi
  exit 0
fi

# =========================================================================
# MODE: VERIFY — Manual verification (called by agent after review)
# =========================================================================
if [[ "$GATE_MODE" == "VERIFY" ]] || [[ "$1" == "VERIFY" ]]; then
  PR="${2:-${PR_NUMBER:-}}"
  [ -z "$PR" ] && { echo "Usage: $0 VERIFY <PR_NUMBER>" >&2; exit 1; }

  # Check CI status via gh api (gh pr checks hangs in non-TTY contexts)
  REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR}" --jq '.head.sha' 2>/dev/null || echo "")
  if [[ -z "$REPO" ]] || [[ -z "$HEAD_SHA" ]]; then
    echo "⚠️ PR #${PR}: リポジトリ/SHA取得失敗。手動確認してください。" >&2
    exit 1
  fi
  CI_STATUS=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | select(.conclusion=="failure")] | length' 2>/dev/null || echo "0")
  CI_PENDING=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | select(.status!="completed")] | length' 2>/dev/null || echo "0")

  if [[ "$CI_STATUS" -gt 0 ]]; then
    echo "❌ PR #${PR}: CI に失敗ジョブあり ($CI_STATUS 件)。修正してください。" >&2
    exit 1
  fi
  if [[ "$CI_PENDING" -gt 0 ]]; then
    echo "⏳ PR #${PR}: CI に実行中ジョブあり ($CI_PENDING 件)。完了を待ってください。" >&2
    exit 1
  fi

  # Check review status
  BRANCH=$(python3 -c "
import json
with open('$LOCK_STATE') as f: s=json.load(f)
print(s.get('$PR',{}).get('branch',''))
" 2>/dev/null || echo "")

  CODE_REVIEW=$(python3 -c "
import json
with open('$REVIEW_STATE') as f: s=json.load(f)
print('yes' if s.get('$BRANCH',{}).get('code_review') else 'no')
" 2>/dev/null || echo "no")

  CODEX_REVIEW=$(python3 -c "
import json
with open('$REVIEW_STATE') as f: s=json.load(f)
print('yes' if s.get('$BRANCH',{}).get('codex_review') else 'no')
" 2>/dev/null || echo "no")

  if [[ "$CODE_REVIEW" != "yes" ]] || [[ "$CODEX_REVIEW" != "yes" ]]; then
    MISSING=""
    [[ "$CODE_REVIEW" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
    [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "
    echo "❌ PR #${PR}: レビュー未完了 (${MISSING%, })" >&2
    exit 1
  fi

  # All checks passed — mark as verified
  python3 -c "
import json
with open('$LOCK_STATE') as f: s=json.load(f)
if '$PR' in s:
  s['$PR']['ci_green']=True
  s['$PR']['review_lgtm']=True
  s['$PR']['verified']=True
with open('$LOCK_STATE','w') as f: json.dump(s,f,indent=2)
" 2>/dev/null

  echo "✅ PR #${PR}: CI green + レビュー LGTM 確認完了。ロック解除。" >&2
  exit 0
fi

echo "Unknown GATE_MODE: $GATE_MODE" >&2
exit 1
