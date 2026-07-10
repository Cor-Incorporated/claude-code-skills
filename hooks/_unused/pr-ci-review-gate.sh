#!/bin/bash
# pr-ci-review-gate.sh — ABSOLUTE ENFORCEMENT: CI green + review LGTM gate
# =========================================================================
# Thin dispatcher: routes to mode-specific scripts in gate-modes/
#
# Modes (GATE_MODE env var or $1):
#   PRE_CREATE  — Blocks `gh pr create` unless review pipeline completed
#   PRE_MERGE   — Blocks `gh pr merge` unless CI green + reviews verified
#   POST_PUSH   — Sets pessimistic lock after every `git push`
#   STOP        — Blocks session stop if any PR has pending review/CI
#   VERIFY      — Manual verification (called by agent after review)
#   CLEANUP     — Remove merged/closed PRs from lock + review state
#
# Exit 2 = HARD BLOCK. No skip. No override.
# =========================================================================
set -euo pipefail

# Resolve the directory where this script (and gate-modes/) lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_MODES_DIR="${SCRIPT_DIR}/gate-modes"

# Determine mode: GATE_MODE env var, or positional arg $1
GATE_MODE="${GATE_MODE:-${1:-STOP}}"

# =========================================================================
# NO SUBAGENT EXEMPTION for PR create/merge/push.
# Subagents MUST NOT create or merge PRs without review, and POST_PUSH must
# still invalidate stale review evidence after child-session pushes.
# Only STOP mode is exempt for subagents.
# =========================================================================
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  case "$GATE_MODE" in
    STOP) exit 0 ;;
    # PRE_CREATE, PRE_MERGE, and POST_PUSH are NOT exempt — fall through
  esac
fi

# Read stdin (tool input JSON) — macOS compatible (no timeout command)
# Export so mode scripts can access it via the 'input' variable
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi
export input

# DIAGNOSTIC: Log every invocation regardless of mode
_log_dir=""
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  _log_dir="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  _log_dir="$(git rev-parse --show-toplevel)/.claude/state"
else
  _log_dir="$HOME/.claude/state"
fi
mkdir -p "$_log_dir" 2>/dev/null
_log_file="$_log_dir/pr-gate-diagnostic.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) INVOKED gate_mode=$GATE_MODE agent_depth=${CLAUDE_AGENT_DEPTH:-0} agent_id=${CLAUDE_AGENT_ID:-none}" >> "$_log_file" 2>/dev/null

# =========================================================================
# VERIFY and CLEANUP support positional arg invocation:
#   bash pr-ci-review-gate.sh VERIFY <PR_NUMBER>
#   bash pr-ci-review-gate.sh CLEANUP
# Pass PR number through env for the mode script
# =========================================================================
if [[ "$GATE_MODE" == "VERIFY" ]]; then
  export VERIFY_PR_NUMBER="${2:-${PR_NUMBER:-}}"
fi

# =========================================================================
# Dispatch to mode script
# =========================================================================
case "$GATE_MODE" in
  PRE_CREATE) source "${GATE_MODES_DIR}/pre-create.sh" ;;
  PRE_MERGE)  source "${GATE_MODES_DIR}/pre-merge.sh" ;;
  POST_PUSH)  source "${GATE_MODES_DIR}/post-push.sh" ;;
  STOP)       source "${GATE_MODES_DIR}/stop.sh" ;;
  VERIFY)     source "${GATE_MODES_DIR}/verify.sh" ;;
  CLEANUP)    source "${GATE_MODES_DIR}/cleanup.sh" ;;
  *)
    echo "Unknown GATE_MODE: $GATE_MODE" >&2
    exit 2
    ;;
esac
