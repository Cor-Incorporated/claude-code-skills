#!/usr/bin/env bash
# context-budget-set-mode.sh
# ========================================================================
# Manual helper: set context budget gate mode.
#
# Usage:
#   bash ~/.claude/hooks/context-budget-set-mode.sh planning
#   bash ~/.claude/hooks/context-budget-set-mode.sh research
#   bash ~/.claude/hooks/context-budget-set-mode.sh auto
#
# This is intentionally a hook-side helper because context-budget gate
# messages point users at ~/.claude/hooks/ and the state file is protected
# from direct edits.
# ========================================================================

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  auto|planning|research) ;;
  *)
    echo "Usage: $0 <auto|planning|research>" >&2
    exit 2
    ;;
esac

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/context-budget.json"
mkdir -p "$STATE_DIR"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

_STATE_FILE="$STATE_FILE" _MODE="$MODE" _NOW="$NOW" python3 << 'PY'
import json
import os
import fcntl

path = os.environ["_STATE_FILE"]
mode = os.environ["_MODE"]
now = os.environ["_NOW"]

with open(path, "a+", encoding="utf-8") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.seek(0)
    try:
        state = json.load(f)
    except json.JSONDecodeError:
        state = {}

    state["mode"] = mode
    state["mode_set_at"] = now
    state["mode_set_by"] = "context-budget-set-mode.sh"
    state.setdefault("contexts", {})
    state.setdefault("read_files", [])
    state.setdefault("warnings_issued", [])

    f.seek(0)
    f.truncate()
    json.dump(state, f, indent=2)
    f.write("\n")
    fcntl.flock(f, fcntl.LOCK_UN)
PY

echo "[Context Budget] mode=$MODE"
