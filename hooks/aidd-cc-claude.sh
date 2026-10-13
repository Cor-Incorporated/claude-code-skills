#!/usr/bin/env bash
# Claude Code entry for the H17 common control.  Registered in settings.json for
# PreToolUse (Bash|Edit|Write|AskUserQuestion), PostToolUse (Bash), UserPromptSubmit,
# PermissionRequest and Stop.  The logic lives in hooks/lib/aidd_cc.py; this file
# only fixes the agent name and resolves the shared adapter.
#
# Cases: DOT-INC-003/008 (re-asking), 004/045 (deadline), 010/017/026 (evidence),
#        012/022 (actual-entry binding), 033 (denominator), 043 (rc UNKNOWN).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER=""
for cand in "$HERE/lib/aidd-cc-adapter.sh" "$HOME/.claude/hooks/lib/aidd-cc-adapter.sh"; do
  [ -f "$cand" ] && ADAPTER="$cand" && break
done
[ -z "$ADAPTER" ] && exit 0
AIDD_CC_AGENT=claude-code exec bash "$ADAPTER"
