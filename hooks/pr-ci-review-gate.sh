#!/bin/bash
# pr-ci-review-gate.sh — ABSOLUTE ENFORCEMENT: CI green + review LGTM gate
# =========================================================================
# NO ESCAPE: This hook blocks PR creation AND merge without review.
#
# Modes (GATE_MODE env var):
#   PRE_CREATE  — Blocks `gh pr create` unless review pipeline completed
#   PRE_MERGE   — Blocks `gh pr merge` unless CI green + reviews verified
#   POST_PUSH   — Sets pessimistic lock after every `git push`
#   STOP        — Blocks session stop if any PR has pending review/CI
#   VERIFY      — Manual verification (called by agent after review)
#
# Exit 2 = HARD BLOCK. No skip. No override.
# =========================================================================

# Prevent gh CLI TTY hangs
export GH_FORCE_TTY=0
export GH_NO_UPDATE_NOTIFIER=1

GATE_MODE="${GATE_MODE:-STOP}"

# DIAGNOSTIC: Log every invocation regardless of mode

# =========================================================================
# State directory — project-scoped
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

# DIAGNOSTIC: Log every invocation
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) INVOKED gate_mode=$GATE_MODE agent_depth=${CLAUDE_AGENT_DEPTH:-0} agent_id=${CLAUDE_AGENT_ID:-none}" >> "$STATE_DIR/pr-gate-diagnostic.log" 2>/dev/null
[ ! -f "$REVIEW_STATE" ] && echo '{}' > "$REVIEW_STATE"
[ ! -f "$LOCK_STATE" ] && echo '{}' > "$LOCK_STATE"

# =========================================================================
# NO SUBAGENT EXEMPTION for PR create/merge.
# Subagents MUST NOT create or merge PRs without review.
# Only POST_PUSH and STOP modes are exempt for subagents.
# =========================================================================
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  case "$GATE_MODE" in
    POST_PUSH|STOP) exit 0 ;;
    # PRE_CREATE and PRE_MERGE are NOT exempt — fall through to enforcement
  esac
fi

# Read stdin (tool input JSON) — macOS compatible (no timeout command)
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

# Helper: extract command from tool input JSON
extract_cmd() {
  if [[ -n "$input" ]] && command -v jq &>/dev/null; then
    echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Helper: get current branch
current_branch() {
  git branch --show-current 2>/dev/null || echo ""
}

# Helper: read review status for a branch (jq-based, no python3 dependency)
read_review() {
  local branch="$1"
  local field="$2"
  if [[ ! -f "$REVIEW_STATE" ]]; then
    echo "no"
    return
  fi
  if command -v jq &>/dev/null; then
    local val
    val=$(jq -r --arg b "$branch" --arg f "$field" '.[$b][$f] // false' "$REVIEW_STATE" 2>/dev/null)
    if [[ "$val" == "true" ]]; then
      echo "yes"
    else
      echo "no"
    fi
  else
    # Fallback: grep-based check (less precise but always available)
    if grep -q "\"$branch\"" "$REVIEW_STATE" 2>/dev/null && \
       grep -A5 "\"$branch\"" "$REVIEW_STATE" 2>/dev/null | grep -q "\"$field\".*true"; then
      echo "yes"
    else
      echo "no"
    fi
  fi
}

# =========================================================================
# MODE: PRE_CREATE — Block PR creation without review
# =========================================================================
if [[ "$GATE_MODE" == "PRE_CREATE" ]]; then
  # Diagnostic log for debugging hook execution
  LOG_FILE="${STATE_DIR}/pr-gate-diagnostic.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) PRE_CREATE invoked. CWD=$(pwd) STATE=$REVIEW_STATE" >> "$LOG_FILE" 2>/dev/null

  cmd=$(extract_cmd)

  # Verify this is a gh pr create command
  if [[ -n "$cmd" ]] && ! echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+create'; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP: cmd='$cmd' not gh pr create" >> "$LOG_FILE" 2>/dev/null
    exit 0
  fi

  BRANCH=$(current_branch)
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BRANCH=$BRANCH" >> "$LOG_FILE" 2>/dev/null
  [[ -z "$BRANCH" ]] && { echo "[WARN] Cannot determine branch. Blocking PR creation." >&2; exit 2; }

  # Exempt doc/chore/ci branches
  case "$BRANCH" in docs/*|chore/*|ci/*) echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) EXEMPT: $BRANCH" >> "$LOG_FILE" 2>/dev/null; exit 0 ;; esac

  CODE_REVIEW=$(read_review "$BRANCH" "code_review")
  CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) code_review=$CODE_REVIEW codex_review=$CODEX_REVIEW" >> "$LOG_FILE" 2>/dev/null

  MISSING=""
  [[ "$CODE_REVIEW" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
  [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "

  if [[ -n "$MISSING" ]]; then
    MISSING="${MISSING%, }"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BLOCKED: $MISSING" >> "$LOG_FILE" 2>/dev/null
    echo "" >&2
    echo "🚫 [BLOCKED] PR作成を拒否。レビューパイプライン未完了。" >&2
    echo "   ブランチ: $BRANCH" >&2
    echo "   未完了: $MISSING" >&2
    echo "" >&2
    echo "   解決方法:" >&2
    echo "   1. code-reviewer エージェントでレビュー実行" >&2
    echo "   2. Codex CLI セカンドオピニオン実行" >&2
    echo "   3. レビュー完了後に再試行" >&2
    echo "" >&2
    exit 2
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ALLOWED: all reviews passed" >> "$LOG_FILE" 2>/dev/null
  exit 0
fi

# =========================================================================
# MODE: PRE_MERGE — Block PR merge without CI green + review
# =========================================================================
if [[ "$GATE_MODE" == "PRE_MERGE" ]]; then
  # DIAGNOSTIC: Log hook invocation
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) PRE_MERGE invoked. cmd=$(extract_cmd)" >> "${STATE_DIR}/pr-gate-diagnostic.log" 2>/dev/null
  cmd=$(extract_cmd)

  # Verify this is a gh pr merge command
  if [[ -n "$cmd" ]] && ! echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+merge'; then
    exit 0
  fi

  # Extract PR number from command FIRST (before branch lookup)
  PR_NUMBER=""
  if [[ -n "$cmd" ]]; then
    PR_NUMBER=$(echo "$cmd" | grep -oE 'gh\s+pr\s+merge\s+([0-9]+)' | grep -oE '[0-9]+' || echo "")
  fi
  if [[ -z "$PR_NUMBER" ]]; then
    # Fallback: try current branch
    local_branch=$(current_branch)
    if [[ -n "$local_branch" ]]; then
      PR_NUMBER=$(gh pr list --head "$local_branch" --json number -q '.[0].number' 2>/dev/null || echo "")
    fi
  fi

  if [[ -z "$PR_NUMBER" ]]; then
    echo "🚫 [BLOCKED] PR番号を特定できません。明示的にPR番号を指定してください。" >&2
    exit 2
  fi

  # BUG FIX: Get the PR's HEAD branch from GitHub API, NOT local current_branch()
  # current_branch() returns 'develop' when merging from develop, but we need
  # the PR's source branch to check review-status.json correctly.
  REPO_FOR_BRANCH=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  if [[ -n "$REPO_FOR_BRANCH" ]]; then
    BRANCH=$(gh api "repos/${REPO_FOR_BRANCH}/pulls/${PR_NUMBER}" --jq '.head.ref' 2>/dev/null || echo "")
  fi
  if [[ -z "$BRANCH" ]]; then
    BRANCH=$(current_branch)
  fi
  [[ -z "$BRANCH" ]] && { echo "[WARN] Cannot determine branch. Blocking PR merge." >&2; exit 2; }

  # Check CI status
  REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")

  if [[ -n "$REPO" ]] && [[ -n "$HEAD_SHA" ]]; then
    CI_FAILURES=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
      --jq '[.check_runs[] | select(.conclusion=="failure")] | length' 2>/dev/null || echo "0")
    CI_PENDING=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
      --jq '[.check_runs[] | select(.status!="completed")] | length' 2>/dev/null || echo "0")

    if [[ "$CI_FAILURES" -gt 0 ]]; then
      echo "🚫 [BLOCKED] CI に失敗ジョブあり ($CI_FAILURES 件)。修正してからマージしてください。" >&2
      exit 2
    fi
    if [[ "$CI_PENDING" -gt 0 ]]; then
      echo "🚫 [BLOCKED] CI に実行中ジョブあり ($CI_PENDING 件)。完了を待ってください。" >&2
      exit 2
    fi
  fi

  # Check review status
  CODE_REVIEW=$(read_review "$BRANCH" "code_review")
  CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")

  MISSING=""
  [[ "$CODE_REVIEW" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
  [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "

  if [[ -n "$MISSING" ]]; then
    MISSING="${MISSING%, }"
    echo "" >&2
    echo "🚫 [BLOCKED] PR #${PR_NUMBER} のマージを拒否。" >&2
    echo "   ブランチ: $BRANCH" >&2
    echo "   未完了: $MISSING" >&2
    echo "" >&2
    echo "   解決方法:" >&2
    echo "   1. レビュー実行後に再試行" >&2
    echo "   2. bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER}" >&2
    echo "" >&2
    exit 2
  fi

  echo "✅ PR #${PR_NUMBER}: CI green + レビュー完了。マージ許可。" >&2
  exit 0
fi

# =========================================================================
# MODE: POST_PUSH — Set pessimistic lock after push
# =========================================================================
if [[ "$GATE_MODE" == "POST_PUSH" ]]; then
  cmd=$(extract_cmd)
  if [[ -n "$cmd" ]] && ! echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+push'; then
    exit 0
  fi

  BRANCH=$(current_branch)
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
  echo "🔒 PR #${PR_NUMBER} をロック。以下が完了するまでマージ禁止:" >&2
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
if [[ "$GATE_MODE" == "VERIFY" ]] || [[ "${1:-}" == "VERIFY" ]]; then
  PR="${2:-${PR_NUMBER:-}}"
  [ -z "$PR" ] && { echo "Usage: $0 VERIFY <PR_NUMBER>" >&2; exit 1; }

  REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR}" --jq '.head.sha' 2>/dev/null || echo "")
  if [[ -z "$REPO" ]] || [[ -z "$HEAD_SHA" ]]; then
    echo "⚠️ PR #${PR}: リポジトリ/SHA取得失敗。手動確認してください。" >&2
    exit 1
  fi

  CI_FAILURES=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | select(.conclusion=="failure")] | length' 2>/dev/null || echo "0")
  CI_PENDING=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | select(.status!="completed")] | length' 2>/dev/null || echo "0")

  if [[ "$CI_FAILURES" -gt 0 ]]; then
    echo "❌ PR #${PR}: CI に失敗ジョブあり ($CI_FAILURES 件)。修正してください。" >&2
    exit 1
  fi
  if [[ "$CI_PENDING" -gt 0 ]]; then
    echo "⏳ PR #${PR}: CI に実行中ジョブあり ($CI_PENDING 件)。完了を待ってください。" >&2
    exit 1
  fi

  BRANCH=$(python3 -c "
import json
with open('$LOCK_STATE') as f: s=json.load(f)
print(s.get('$PR',{}).get('branch',''))
" 2>/dev/null || echo "")

  CODE_REVIEW=$(read_review "$BRANCH" "code_review")
  CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")

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
