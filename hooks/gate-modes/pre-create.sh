#!/bin/bash
# pre-create.sh — PRE_CREATE mode: Block PR creation without review
# =========================================================================
# Exit 0 = allow, Exit 2 = HARD BLOCK
# All output to stderr (Claude Code hooks spec)
# =========================================================================
set -euo pipefail

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh"

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
TIER=$(classify_review_tier "$BRANCH" "${PR_NUMBER:-}")
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
