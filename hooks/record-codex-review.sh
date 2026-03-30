#!/usr/bin/env bash
# record-codex-review.sh
# ========================================================================
# Records Codex CLI review completion in review-status.json.
# Dual-mode: (1) called by codex-parallel.sh with args, (2) PostToolUse Bash hook via stdin JSON.
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

# --- Hook mode: PostToolUse Bash (no arguments) ---
# When registered as PostToolUse hook, stdin contains tool invocation JSON.
# Detect codex exec review commands and auto-record completion.
if [[ $# -eq 0 ]]; then
  INPUT=$(cat)
  COMMAND=$(echo "$INPUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ti=d.get('tool_input',{})
if isinstance(ti,str):
    import json as j2
    try: ti=j2.loads(ti)
    except: ti={}
print(ti.get('command',''))
" 2>/dev/null || echo "")

  # Only trigger on codex review commands
  echo "$COMMAND" | grep -qE 'codex\s+exec.*review|codex-parallel\.sh\s+--review' || exit 0

  # Extract branch and repo path from git
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  [[ -z "$BRANCH" ]] && exit 0
  REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  # In hook mode, severity is not available from command output
  # Record codex_review_ran=true with pass=true (no severity data)
  # codex-parallel.sh path provides severity data when available
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  write_codex_review_hook() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
    [ ! -f "$target" ] && echo '{}' > "$target"

    _STATE="$target" _BR="$BRANCH" _NOW="$NOW" \
    python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
br = os.environ['_BR']
now = os.environ['_NOW']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        data = json.load(f)
    except (json.JSONDecodeError, ValueError):
        data = {}
    if br not in data:
        data[br] = {}
    data[br]['codex_review_ran'] = True
    data[br]['codex_review_at'] = now
    if 'codex_review' not in data[br]:
        data[br]['codex_review'] = True
    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
"
  }

  GLOBAL_STATE="$HOME/.claude/state/review-status.json"
  write_codex_review_hook "$GLOBAL_STATE"

  PROJECT_STATE_DIR=""
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    PROJECT_STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
  elif [[ -d "$REPO_PATH/.git" ]] || [[ -f "$REPO_PATH/.git" ]]; then
    PROJECT_STATE_DIR="$REPO_PATH/.claude/state"
  fi
  if [[ -n "$PROJECT_STATE_DIR" ]] && [[ "$PROJECT_STATE_DIR" != "$HOME/.claude/state" ]]; then
    write_codex_review_hook "$PROJECT_STATE_DIR/review-status.json"
  fi

  echo "✅ [review-gate] Codex CLI レビュー完了を自動記録: branch=$BRANCH (hook mode)" >&2
  exit 0
fi

if ! command -v python3 &>/dev/null; then
  echo "[WARN] python3 が見つかりません。Codexレビュー記録をスキップできないため fail-closed します。" >&2
  echo "  python3 をインストールしてください。" >&2
  exit 2
fi

BRANCH="${1:?branch required}"
# Issue #203: Detect if $2 is a flag (--) rather than a repo path
if [[ "${2:-}" == --* ]] || [[ -z "${2:-}" ]]; then
  REPO_PATH="$(pwd)"
  shift 1 2>/dev/null || true
else
  REPO_PATH="${2}"
  shift 2 2>/dev/null || true
fi

# Issue #203: Optional severity params for severity-aware gating
# Usage: record-codex-review.sh <branch> [repo-path] [--critical N] [--high N] [--medium N] [--low N]
CODEX_CRITICAL=-1
CODEX_HIGH=-1
CODEX_MEDIUM=-1
CODEX_LOW=-1
HAS_SEVERITY="false"
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
        for key, env in [('codex_critical','_CRIT'),('codex_high','_HIGH'),('codex_medium','_MED'),('codex_low','_LOW')]:
            try:
                data[br][key] = int(os.environ[env])
            except (ValueError, KeyError):
                data[br][key] = -1
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
  echo "⚠️ [review-gate] Codex CLI レビュー記録: branch=$BRANCH (CRITICAL=$CODEX_CRITICAL HIGH=$CODEX_HIGH → FAIL, codex_review=false)" >&2
fi
exit 0
