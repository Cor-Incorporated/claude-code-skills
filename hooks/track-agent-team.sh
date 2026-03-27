#!/usr/bin/env bash
# track-agent-team.sh
# ========================================================================
# PostToolUse hook: Tracks when Agent tools are launched.
# When 2+ agents are launched (including background), creates/updates
# the parallel team signal file so enforce-parallel-agents.sh can detect
# single-agent regression after compaction.
#
# Trigger: After Agent tool use
# Signal file: ~/.claude/state/parallel-team.json
# ========================================================================

set -euo pipefail

STATE_DIR="$HOME/.claude/state"
SIGNAL_FILE="$STATE_DIR/parallel-team.json"

mkdir -p "$STATE_DIR"

# Save stdin for later use (agent metadata)
_HOOK_INPUT=""
if [[ ! -t 0 ]]; then
  _HOOK_INPUT=$(cat 2>/dev/null || echo "")
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ ! -f "$SIGNAL_FILE" ]]; then
  echo '{}' > "$SIGNAL_FILE"
fi

# Create or increment the parallel-team signal atomically.
_SIGNAL_FILE="$SIGNAL_FILE" _NOW="$NOW" python3 -c "
import fcntl
import json
import os

f_path = os.environ['_SIGNAL_FILE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        data = {}

    if not isinstance(data, dict):
        data = {}

    count = data.get('agent_count', 0) + 1
    tasks = data.get('tasks', [])
    if not isinstance(tasks, list):
        tasks = []

    data['agent_count'] = count
    data['created_at'] = data.get('created_at', os.environ['_NOW'])
    data['last_agent_at'] = os.environ['_NOW']
    tasks.append(f'agent-{count}')

    # Keep only last 10 task entries
    data['tasks'] = tasks[-10:]

    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null || true


# Issue #176: Release fg_impl_agent_count in context-budget.json
# Only decrement for agent types that were incremented by context-budget-agent-gate.sh
# Research types and background/team agents are exempt from the gate, so skip them
BUDGET_FILE="$HOME/.claude/state/context-budget.json"
if [[ -f "$BUDGET_FILE" ]]; then
  # Read saved stdin for agent metadata (PostToolUse provides tool_input)
  _subtype=""
  _is_bg="false"
  _has_team=""
  if [[ -n "${_HOOK_INPUT:-}" ]]; then
    _subtype=$(echo "$_HOOK_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
    _is_bg=$(echo "$_HOOK_INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo "false")
    _has_team=$(echo "$_HOOK_INPUT" | jq -r '.tool_input.team_name // ""' 2>/dev/null || echo "")
  fi

  # Research types that are never gated (same set as context-budget-agent-gate.sh)
  _is_research="false"
  case "$_subtype" in
    Explore|architect|planner|Plan|code-reviewer|security-reviewer) _is_research="true" ;;
    feature-dev:code-reviewer|feature-dev:code-explorer|feature-dev:code-architect) _is_research="true" ;;
    claude-code-guide|general-purpose) _is_research="true" ;;
  esac

  # Only decrement if this was a foreground impl agent (not research, not background, not team)
  if [[ "$_is_research" != "true" ]] && [[ "$_is_bg" != "true" ]] && [[ -z "$_has_team" ]]; then
    _BUDGET_FILE="$BUDGET_FILE" python3 -c "
import fcntl
import json
import os

f_path = os.environ['_BUDGET_FILE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        data = {}

    fg = data.get('fg_impl_agent_count', 0)
    if fg > 0:
        data['fg_impl_agent_count'] = fg - 1

    impl = data.get('impl_agent_count', 0)
    if impl > 0:
        data['impl_agent_count'] = impl - 1

    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null || true
  fi
fi
exit 0
