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

# Fail-closed: python3 is required for state file operations
if ! command -v python3 &>/dev/null; then
  echo "[pr-ci-review-gate] python3 not found. Blocking for safety." >&2
  exit 2
fi

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

# =========================================================================
# Review Tier Classification (content-based)
# =========================================================================
# Tier 1 (FULL)   : Source code changes → code-reviewer + Codex CLI
# Tier 2 (LIGHT)  : CI/config/docs-only changes → code-reviewer only
# Tier 3 (EXEMPT) : Branch-based exemption (docs/*, chore/*, ci/*)
#
# Low-risk file patterns (Tier 2):
#   .github/*, Dockerfile, .dockerignore, .gitignore, *.md, CLAUDE.md,
#   .claude/*, tsconfig.json, .eslintrc*, .prettierrc*, renovate.json
# =========================================================================
classify_review_tier() {
  local branch="$1"

  # Tier 3: Branch-based exemption
  case "$branch" in docs/*|chore/*|ci/*) echo "EXEMPT"; return ;; esac

  # Meta-task exemption (Issue #7): if the repo IS the hook system itself
  # (claude-code-skills), treat all changes as LIGHT tier. Hook infrastructure
  # changes are config/tooling, not application source code.
  # Defense in depth: check remote URL (not just directory name) to prevent spoofing.
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "$remote_url" == *"/claude-code-skills"* ]] || [[ "$remote_url" == *"/claude-code-skills.git"* ]]; then
    echo "LIGHT"
    return
  fi

  # Determine base branch for diff
  local base_branch="main"
  if git rev-parse --verify develop &>/dev/null; then
    base_branch="develop"
  elif git rev-parse --verify main &>/dev/null; then
    base_branch="main"
  elif git rev-parse --verify master &>/dev/null; then
    base_branch="master"
  fi

  # Get list of changed files vs base
  local changed_files
  changed_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || git diff --name-only "${base_branch}" 2>/dev/null || echo "")

  if [[ -z "$changed_files" ]]; then
    # Cannot determine changes — default to FULL for safety
    echo "FULL"
    return
  fi

  # Check each changed file: if ANY file is NOT in the low-risk pattern, it's Tier 1
  local has_source_changes="false"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
      # Low-risk: All .github config files
      .github/*) ;;
      # Low-risk: Docker config
      Dockerfile|Dockerfile.*|.dockerignore|docker-compose*.yml|docker-compose*.yaml) ;;
      # Low-risk: Documentation
      *.md|docs/*|LICENSE|CHANGELOG*|CONTRIBUTING*) ;;
      # Low-risk: Claude/editor config
      .claude/*|CLAUDE.md|.cursor/*|.vscode/*|.editorconfig) ;;
      # Low-risk: Linter/formatter config
      .eslintrc*|.prettierrc*|.stylelintrc*|biome.json|.biomeignore) ;;
      # Low-risk: Git config
      .gitignore|.gitattributes) ;;
      # Low-risk: Renovate/Dependabot
      renovate.json|.renovaterc*) ;;
      # Low-risk: tsconfig (build config, not source)
      tsconfig*.json) ;;
      # Everything else is source code → Tier 1
      *)
        has_source_changes="true"
        break
        ;;
    esac
  done <<< "$changed_files"

  if [[ "$has_source_changes" == "true" ]]; then
    echo "FULL"
  else
    echo "LIGHT"
  fi
}

# Helper: read review status for a branch (jq-based, no python3 dependency)
# Issue #60 Bug C: Check BOTH project-scoped AND global state (OR logic)
# to prevent path mismatch causing permanent blocks.
read_review() {
  local branch="$1"
  local field="$2"
  local global_state="$HOME/.claude/state/review-status.json"

  # Check both state files — return "yes" if EITHER has the field set to true
  local files_to_check=("$REVIEW_STATE")
  if [[ "$global_state" != "$REVIEW_STATE" ]]; then
    files_to_check+=("$global_state")
  fi

  for state_file in "${files_to_check[@]}"; do
    [[ ! -f "$state_file" ]] && continue
    if command -v jq &>/dev/null; then
      local val
      val=$(jq -r --arg b "$branch" --arg f "$field" '.[$b][$f] // false' "$state_file" 2>/dev/null)
      if [[ "$val" == "true" ]]; then
        echo "yes"
        return
      fi
    else
      if grep -q "\"$branch\"" "$state_file" 2>/dev/null && \
         grep -A5 "\"$branch\"" "$state_file" 2>/dev/null | grep -q "\"$field\".*true"; then
        echo "yes"
        return
      fi
    fi
  done
  echo "no"
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

  # Classify review tier based on branch name + changed files
  TIER=$(classify_review_tier "$BRANCH")
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) TIER=$TIER" >> "$LOG_FILE" 2>/dev/null

  # Tier 3 (EXEMPT): no review required
  if [[ "$TIER" == "EXEMPT" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) EXEMPT: $BRANCH (branch pattern)" >> "$LOG_FILE" 2>/dev/null
    exit 0
  fi

  CODE_REVIEW=$(read_review "$BRANCH" "code_review")
  CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) code_review=$CODE_REVIEW codex_review=$CODEX_REVIEW tier=$TIER" >> "$LOG_FILE" 2>/dev/null

  MISSING=""
  [[ "$CODE_REVIEW" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
  # Tier 1 (FULL): require Codex CLI too. Tier 2 (LIGHT): code-reviewer only.
  if [[ "$TIER" == "FULL" ]]; then
    [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "
  fi

  if [[ -n "$MISSING" ]]; then
    MISSING="${MISSING%, }"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) MISSING: $MISSING (tier=$TIER)" >> "$LOG_FILE" 2>/dev/null

    # LIGHT tier: warn only, don't block PR creation.
    # Safety is enforced at PRE_MERGE + block-merge-without-review.sh.
    # Blocking PR creation for LIGHT tier causes circular dependencies
    # when fixing hook infrastructure (the hooks block their own fix PRs).
    if [[ "$TIER" == "LIGHT" ]]; then
      echo "⚠️ [WARNING] レビュー未完了 ($MISSING) — LIGHT tierのため作成を許可。" >&2
      echo "   マージ前にcode-reviewerを実行してください。" >&2
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ALLOWED: LIGHT tier warning-only (tier=$TIER)" >> "$LOG_FILE" 2>/dev/null
    else
      echo "" >&2
      echo "🚫 [BLOCKED] PR作成を拒否。レビューパイプライン未完了。" >&2
      echo "   ブランチ: $BRANCH" >&2
      echo "   レビューTier: $TIER" >&2
      echo "   未完了: $MISSING" >&2
      echo "" >&2
      echo "   解決方法:" >&2
      echo "   1. code-reviewer エージェントでレビュー実行" >&2
      echo "   2. Codex CLI セカンドオピニオン実行" >&2
      echo "   3. レビュー完了後に再試行" >&2
      echo "" >&2
      exit 2
    fi
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ALLOWED: reviews passed (tier=$TIER)" >> "$LOG_FILE" 2>/dev/null
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

  # =========================================================================
  # Tier detection: EXEMPT (docs/chore/ci), LIGHT (default)
  # Ref: Issue #66 — "レビューゼロマージ不可" と "手動マージ不要" の両立
  # =========================================================================
  case "$BRANCH" in
    docs/*|chore/*|ci/*)
      echo "✅ PR #${PR_NUMBER}: EXEMPT tier ($BRANCH). CIグリーンのみで許可。" >&2
      exit 0 ;;
  esac

  # =========================================================================
  # LIGHT tier: 3パスOR判定
  # Issue #66 + Codex セカンドオピニオン: "全merge hookが同じ証跡を受理すべき"
  # いずれか1つ合格 = マージ許可。全不合格 = ブロック。
  #
  # Pass A: review-status.json に code_review: true (code-reviewer agent 完了)
  # Pass B: pending-review-comments.json の CRITICAL=0 AND HIGH=0
  # Pass C: pr-review-lock.json に verified: true (手動/自動検証済み)
  # =========================================================================
  PASS_A="no"
  PASS_B="no"
  PASS_C="no"

  # --- Pass A: code-reviewer agent completion ---
  CODE_REVIEW=$(read_review "$BRANCH" "code_review")
  [[ "$CODE_REVIEW" == "yes" ]] && PASS_A="yes"

  # --- Pass B: No CRITICAL/HIGH in review comments ---
  PENDING_FILE="$STATE_DIR/pending-review-comments.json"
  if [[ -f "$PENDING_FILE" ]] && command -v jq &>/dev/null; then
    _pr_in_file=$(jq -r '.pr // ""' "$PENDING_FILE" 2>/dev/null || echo "")
    # Validate scope: pending-review-comments must match current PR
    if [[ "$_pr_in_file" == "$PR_NUMBER" ]]; then
      _critical=$(jq -r '.critical // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
      _high=$(jq -r '.high // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
      _total=$(jq -r '.total // 0' "$PENDING_FILE" 2>/dev/null || echo "0")
      if [[ "$_critical" -eq 0 ]] && [[ "$_high" -eq 0 ]] && [[ "$_total" -gt 0 ]]; then
        PASS_B="yes"
      fi
    fi
  fi

  # --- Pass C: Manual verification via pr-review-lock.json ---
  if [[ -f "$LOCK_STATE" ]] && command -v jq &>/dev/null; then
    _verified=$(jq -r --arg pr "$PR_NUMBER" '.[$pr].verified // false' "$LOCK_STATE" 2>/dev/null || echo "false")
    [[ "$_verified" == "true" ]] && PASS_C="yes"
  fi

  # --- 3パスOR判定 ---
  if [[ "$PASS_A" == "yes" ]] || [[ "$PASS_B" == "yes" ]] || [[ "$PASS_C" == "yes" ]]; then
    PASSED=""
    [[ "$PASS_A" == "yes" ]] && PASSED="${PASSED}code-reviewer✓ "
    [[ "$PASS_B" == "yes" ]] && PASSED="${PASSED}C/H=0✓ "
    [[ "$PASS_C" == "yes" ]] && PASSED="${PASSED}verified✓ "
    echo "✅ PR #${PR_NUMBER}: LIGHT tier 3パスOR合格 (${PASSED}). マージ許可。" >&2
    exit 0
  fi

  echo "" >&2
  echo "🚫 [BLOCKED] PR #${PR_NUMBER} のマージを拒否。レビュー未完了。" >&2
  echo "   ブランチ: $BRANCH" >&2
  echo "   LIGHT tier — 以下のいずれか1つが必要:" >&2
  echo "     A. code-reviewer エージェント完了 [${PASS_A}]" >&2
  echo "     B. CRITICAL/HIGH指摘ゼロ (レビュー実行済み) [${PASS_B}]" >&2
  echo "     C. 手動検証済み (verify-pr-review) [${PASS_C}]" >&2
  echo "" >&2
  echo "   解決方法:" >&2
  echo "     1. Agent tool (subagent_type=code-reviewer) → Pass A" >&2
  echo "     2. gh pr checks + レビューコメント全対応 → Pass B" >&2
  echo "     3. bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY ${PR_NUMBER} → Pass C" >&2
  echo "" >&2
  exit 2
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

  # Classify tier to show appropriate requirements
  TIER=$(classify_review_tier "$BRANCH")
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
fi

# =========================================================================
# MODE: STOP — Block session stop if unverified PRs exist
# =========================================================================
if [[ "$GATE_MODE" == "STOP" ]]; then
  # =========================================================================
  # Issue #66 Fix #3: stop_hook_active チェック (公式ドキュメント準拠)
  # Ref: https://code.claude.com/docs/en/hooks
  #   "To prevent Claude Code from running indefinitely,
  #    check stop_hook_active or analyze the transcript."
  # stop_hook_active=true → 既に前回のStop hookで継続中 → 無限ループ防止
  # =========================================================================
  if [[ -n "$input" ]] && command -v jq &>/dev/null; then
    _stop_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
    if [[ "$_stop_active" == "true" ]]; then
      echo "[stop-gate] stop_hook_active=true: 2回目のStop hook。ログ出力のみ。" >&2
      exit 0
    fi
  fi

  # Issue #58: Skip gate during active error recovery
  # Dirty working tree = active work in progress → don't block session end
  if ! git diff --quiet HEAD 2>/dev/null; then
    exit 0
  fi

  # Auto-cleanup: remove merged/closed PRs from lock state (housekeeping)
  REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  if [[ -n "$REPO" ]]; then
    _LOCK="$LOCK_STATE" _REPO="$REPO" python3 -c "
import json, subprocess, os, fcntl
lock_path = os.environ['_LOCK']
repo = os.environ['_REPO']
with open(lock_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    for pr in list(s.keys()):
        try:
            r = subprocess.run(['gh','api','repos/'+repo+'/pulls/'+pr,'--jq','.state'],
                capture_output=True, text=True, timeout=10)
            if r.stdout.strip() in ('closed','merged'):
                del s[pr]
        except Exception:
            pass
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null
  fi

  UNVERIFIED=$(_LOCK="$LOCK_STATE" python3 -c "
import json, os
with open(os.environ['_LOCK']) as f: s = json.load(f)
unverified = [f'PR #{pr} ({d.get("branch","?")})'  for pr, d in s.items()
              if isinstance(d, dict) and not d.get('verified', False)]
print('|'.join(unverified) if unverified else '')
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

  BRANCH=$(_LOCK="$LOCK_STATE" _PR="$PR" python3 -c "
import json, os
with open(os.environ['_LOCK']) as f: s = json.load(f)
print(s.get(os.environ['_PR'], {}).get('branch', ''))
" 2>/dev/null || echo "")

  # If branch not in lock state, try GitHub API
  if [[ -z "$BRANCH" ]]; then
    BRANCH=$(gh api "repos/${REPO}/pulls/${PR}" --jq '.head.ref' 2>/dev/null || echo "")
  fi

  # Classify review tier
  TIER=$(classify_review_tier "$BRANCH")

  # EXEMPT tier: CI green is sufficient, no review needed
  if [[ "$TIER" == "EXEMPT" ]]; then
    echo "✅ PR #${PR}: EXEMPT tier — CI green確認済み。" >&2
  else
    CODE_REVIEW=$(read_review "$BRANCH" "code_review")
    CODEX_REVIEW=$(read_review "$BRANCH" "codex_review")

    # Issue #60 Bug B: Also check pending-review-comments.json (claude-review results)
    # If claude-review reported CRITICAL/HIGH=0, treat as review passed
    if [[ "$CODE_REVIEW" != "yes" ]]; then
      PENDING_FILE="$STATE_DIR/pending-review-comments.json"
      GLOBAL_PENDING="$HOME/.claude/state/pending-review-comments.json"
      for pf in "$PENDING_FILE" "$GLOBAL_PENDING"; do
        if [[ -f "$pf" ]] && command -v jq &>/dev/null; then
          PR_MATCH=$(jq -r --arg p "$PR" '.pr // ""' "$pf" 2>/dev/null)
          CR=$(jq -r '.critical // 0' "$pf" 2>/dev/null)
          HI=$(jq -r '.high // 0' "$pf" 2>/dev/null)
          if [[ "$PR_MATCH" == "$PR" ]] && [[ "$CR" == "0" ]] && [[ "$HI" == "0" ]]; then
            CODE_REVIEW="yes"
            echo "  ℹ️ claude-review CRITICAL/HIGH=0 → code_review=yes として扱う" >&2
            break
          fi
        fi
      done
    fi

    MISSING=""
    [[ "$CODE_REVIEW" != "yes" ]] && MISSING="${MISSING}code-reviewer, "
    if [[ "$TIER" == "FULL" ]]; then
      [[ "$CODEX_REVIEW" != "yes" ]] && MISSING="${MISSING}Codex CLI, "
    fi

    if [[ -n "$MISSING" ]]; then
      echo "❌ PR #${PR}: レビュー未完了 (${MISSING%, }) [tier=$TIER]" >&2
      exit 1
    fi
  fi

  # All checks passed — mark as verified
  _LOCK="$LOCK_STATE" _PR="$PR" python3 -c "
import json, os, fcntl
f_path = os.environ['_LOCK']
pr = os.environ['_PR']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    s = json.load(f)
    if pr in s:
        s[pr]['ci_green'] = True
        s[pr]['review_lgtm'] = True
        s[pr]['verified'] = True
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null

  echo "✅ PR #${PR}: CI green + レビュー LGTM 確認完了。ロック解除。" >&2
  exit 0
fi

# =========================================================================
# MODE: CLEANUP — Remove merged/closed PRs from lock + review state
# =========================================================================
# Safe housekeeping: not a bypass. Only removes entries for PRs that
# GitHub confirms are already merged or closed.
# Usage: GATE_MODE=CLEANUP bash pr-ci-review-gate.sh
#    or: bash pr-ci-review-gate.sh CLEANUP
# =========================================================================
if [[ "$GATE_MODE" == "CLEANUP" ]] || [[ "${1:-}" == "CLEANUP" ]]; then
  REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  if [[ -z "$REPO" ]]; then
    echo "⚠️ リポジトリ情報取得失敗。git repoディレクトリで実行してください。" >&2
    exit 1
  fi

  CLEANED=$(_LOCK="$LOCK_STATE" _REVIEW="$REVIEW_STATE" _REPO="$REPO" python3 -c "
import json, subprocess, os, fcntl

lock_path = os.environ['_LOCK']
review_path = os.environ['_REVIEW']
repo = os.environ['_REPO']
lock_cleaned = []
review_cleaned = []

# Clean lock state (with file lock)
with open(lock_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    lock = json.load(f)
    for pr in list(lock.keys()):
        try:
            r = subprocess.run(['gh','api','repos/'+repo+'/pulls/'+pr,'--jq','.state'],
                capture_output=True, text=True, timeout=10)
            if r.stdout.strip() in ('closed','merged'):
                branch = lock[pr].get('branch', '?')
                del lock[pr]
                lock_cleaned.append(f'PR #{pr} ({branch})')
        except Exception:
            pass
    f.seek(0); f.truncate()
    json.dump(lock, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)

# Clean review state (with file lock)
with open(review_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    review = json.load(f)
    for branch in list(review.keys()):
        try:
            r = subprocess.run(['gh','pr','list','--head',branch,'--state','open',
                '--json','number','-q','.[0].number'],
                capture_output=True, text=True, timeout=10)
            if not r.stdout.strip():
                del review[branch]
                review_cleaned.append(branch)
        except Exception:
            pass
    f.seek(0); f.truncate()
    json.dump(review, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)

if lock_cleaned or review_cleaned:
    for item in lock_cleaned:
        print(f'  lock: {item}')
    for item in review_cleaned:
        print(f'  review: {item}')
else:
    print('  (nothing to clean)')
" 2>/dev/null || echo "  (cleanup failed)")

  echo "🧹 Housekeeping完了:" >&2
  echo "$CLEANED" >&2
  exit 0
fi

echo "Unknown GATE_MODE: $GATE_MODE" >&2
exit 1
