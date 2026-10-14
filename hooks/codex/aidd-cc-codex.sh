#!/usr/bin/env bash
# Codex entry for the H17 common control.  Registered in ~/.codex/hooks.json for
# PreToolUse, PostToolUse, UserPromptSubmit, PermissionRequest and Stop (Codex
# 0.162 supports all five; verified against the binary's hook schema).
# Deployed to ~/.codex/hooks/aidd-cc-codex.sh by setup.sh; the shared adapter and
# python module are read from ~/.claude/hooks/lib/.
set -uo pipefail
ADAPTER=""
# Order: explicit override, the checkout this script lives in, then the deployed HOME copy
# (so a repo-path replay exercises the code under review — Codex r5 P2-f).
for cand in "${AIDD_CC_ADAPTER:-}" \
            "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)/aidd-cc-adapter.sh" \
            "$HOME/.claude/hooks/lib/aidd-cc-adapter.sh"; do
  [ -n "$cand" ] && [ -f "$cand" ] && ADAPTER="$cand" && break
done
[ -z "$ADAPTER" ] && exit 0
AIDD_CC_AGENT=codex exec bash "$ADAPTER"
