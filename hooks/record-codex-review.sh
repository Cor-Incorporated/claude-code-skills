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

if ! command -v python3 &>/dev/null; then
  echo "[WARN] python3 が見つかりません。Codexレビュー記録をスキップできないため fail-closed します。" >&2
  echo "  python3 をインストールしてください。" >&2
  exit 2
fi

BRANCH="${1:?branch required}"
REPO_PATH="${2:-$(pwd)}"

# Issue #203: Optional severity params for severity-aware gating
# Usage: record-codex-review.sh <branch> [repo-path] [--critical N] [--high N] [--medium N] [--low N]
CODEX_CRITICAL=-1
CODEX_HIGH=-1
CODEX_MEDIUM=-1
CODEX_LOW=-1
HAS_SEVERITY="false"
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --critical) CODEX_CRITICAL="${2:-0}"; HAS_SEVERITY="true"; shift 2 ;;
    --high)     CODEX_HIGH="${2:-0}";     HAS_SEVERITY="true"; shift 2 ;;
    --medium)   CODEX_MEDIUM="${2:-0}";   HAS_SEVERITY="true"; shift 2 ;;
    --low)      CODEX_LOW="${2:-0}";      HAS_SEVERITY="true"; shift 2 ;;
    *) shift ;;
  esac
done

# Determine if codex_review should be true
# - No severity params (backward compat): always true
# - With severity: true only if CRITICAL=0 AND HIGH=0
CODEX_REVIEW_PASS="true"
if [[ "$HAS_SEVERITY" == "true" ]]; then
  if [[ "$CODEX_CRITICAL" -gt 0 ]] 2>/dev/null || [[ "$CODEX_HIGH" -gt 0 ]] 2>/dev/null; then
    CODEX_REVIEW_PASS="false"
  fi
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Helper: write codex_review to a single state file ---
write_codex_review() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  [ ! -f "$target" ] && echo '{}' > "$target"

  _STATE="$target" _BR="$BRANCH" _NOW="$NOW" \
  _PASS="$CODEX_REVIEW_PASS" _HAS_SEV="$HAS_SEVERITY" \
  _CRIT="$CODEX_CRITICAL" _HIGH="$CODEX_HIGH" \
  _MED="$CODEX_MEDIUM" _LOW="$CODEX_LOW" \
  python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
br = os.environ['_BR']
now = os.environ['_NOW']
review_pass = os.environ['_PASS'] == 'true'
has_sev = os.environ['_HAS_SEV'] == 'true'
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        data = json.load(f)
    except (json.JSONDecodeError, ValueError):
        data = {}
    if br not in data:
        data[br] = {}
    data[br]['codex_review'] = review_pass
    data[br]['codex_review_ran'] = True
    data[br]['codex_review_at'] = now
    if has_sev:
        data[br]['codex_critical'] = int(os.environ['_CRIT'])
        data[br]['codex_high'] = int(os.environ['_HIGH'])
        data[br]['codex_medium'] = int(os.environ['_MED'])
        data[br]['codex_low'] = int(os.environ['_LOW'])
    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
"
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

if [[ "$CODEX_REVIEW_PASS" == "true" ]]; then
  echo "✅ [review-gate] Codex CLI レビュー完了を記録: branch=$BRANCH (PASS)" >&2
else
  echo "⚠️ [review-gate] Codex CLI レビュー記録: branch=$BRANCH (CRITICAL=$CODEX_CRITICAL HIGH=$CODEX_HIGH -> FAIL, PR作成はMEDIUM-onlyなら許可)" >&2
fi
exit 0
