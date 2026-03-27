#!/bin/bash
# inject-claude-review-on-checks.sh — PreToolUse hook (matcher: Bash)
#
# Multi-mode hook for review quality enforcement:
# 1. On `gh pr checks` → fetch reviews, save to state, output summary
# 2. On `gh pr merge` → hard block if unresolved CRITICAL/HIGH
# 3. On any Bash → if pending reviews exist, remind via stderr
#
# Exit 0 = allow, Exit 2 = block
set -uo pipefail
export GH_NO_UPDATE_NOTIFIER=1
export GH_FORCE_TTY=0

[[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && exit 0
[[ -n "${CLAUDE_AGENT_ID:-}" ]] && exit 0

# Project-scoped state
if git rev-parse --show-toplevel &>/dev/null 2>&1; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
mkdir -p "$STATE_DIR"
PENDING_FILE="$STATE_DIR/pending-review-comments.json"

input=""
[[ ! -t 0 ]] && input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# =========================================================================
# MODE 1: gh pr checks → fetch reviews and save state
# =========================================================================
if echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+checks'; then
  PR_NUMBER=$(echo "$(echo "$cmd" | head -1)" | grep -oE '[0-9]+' | head -1)
  [[ -z "$PR_NUMBER" ]] && exit 0

  REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  [[ -z "$REPO" ]] && exit 0

  # Fetch and save via Python helper (stdin=/dev/null to avoid pipe issues)
  # Issue #66 Fix #4: Do not suppress stderr — surface errors instead of silent failure
  python3 ~/.claude/hooks/inject-claude-review-helper.py "$REPO" "$PR_NUMBER" </dev/null >/dev/null 2>"$STATE_DIR/inject-review-errors.log" || {
    echo "[inject-claude-review] Python helper failed. See $STATE_DIR/inject-review-errors.log" >&2
  }

  # Read back the saved state and output as reminder
  if [[ -f "$PENDING_FILE" ]]; then
    OUTPUT=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f:
    d = json.load(f)
print(d.get('output', ''))
" 2>/dev/null || echo "")

    if [[ -n "$OUTPUT" ]]; then
      echo "" >&2
      echo "═══════════════════════════════════════════════════" >&2
      echo "$OUTPUT" >&2
      echo "═══════════════════════════════════════════════════" >&2
      echo "" >&2
    fi
  fi
  exit 0
fi

# =========================================================================
# MODE 2: gh pr merge → hard block if unresolved
# =========================================================================
if echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+merge'; then
  if [[ -f "$PENDING_FILE" ]]; then
    REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
    # Issue #165: Check classification_method — prefer AI classification if available
    CLASSIFICATION_METHOD=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('classification_method', 'regex'))
" 2>/dev/null || echo "regex")
    if [[ "$CLASSIFICATION_METHOD" == "ai" ]]; then
      CRITICAL=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
ai = d.get('ai_classification') or {}
print(ai.get('critical', d.get('critical', 0)))
" 2>/dev/null || echo "0")
      HIGH=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
ai = d.get('ai_classification') or {}
print(ai.get('high', d.get('high', 0)))
" 2>/dev/null || echo "0")
    else
      CRITICAL=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('critical', 0))
" 2>/dev/null || echo "0")
      HIGH=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('high', 0))
" 2>/dev/null || echo "0")
    fi
    PR=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('pr', ''))
" 2>/dev/null || echo "")
    PENDING_HEAD_SHA=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('head_sha', ''))
" 2>/dev/null || echo "")

    if [[ -n "$REPO" ]] && [[ -n "$PR" ]] && [[ -n "$PENDING_HEAD_SHA" ]]; then
      CURRENT_HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR}" --jq '.head.sha' 2>/dev/null || echo "")
      if [[ -n "$CURRENT_HEAD_SHA" ]] && [[ "$PENDING_HEAD_SHA" != "$CURRENT_HEAD_SHA" ]]; then
        echo "[inject-claude-review] pending-review-comments.json is stale for PR #${PR}; skip merge block." >&2
        exit 0
      fi
    fi

    if [[ "$CRITICAL" -gt 0 ]] || [[ "$HIGH" -gt 0 ]]; then
      echo "" >&2
      echo "[BLOCKED] PR #${PR}: 未対応 CRITICAL=${CRITICAL} HIGH=${HIGH}" >&2
      echo "  レビューコメントを全て対応してからマージしてください。" >&2
      echo "" >&2
      exit 2
    fi
  fi
  exit 0
fi

# =========================================================================
# MODE 3: Any other Bash → soft reminder if pending reviews exist
# =========================================================================
# Only remind occasionally (not on every single command)
# Skip for: git, ls, cat, echo, python3, etc.
if echo "$(echo "$cmd" | head -1)" | grep -qE '^(git |ls |cat |echo |python3 |head |tail |grep |find |test |set )'; then
  exit 0
fi

if [[ -f "$PENDING_FILE" ]]; then
  TOTAL=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('total', 0))
" 2>/dev/null || echo "0")
  CLASSIFICATION_METHOD=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('classification_method', 'regex'))
" 2>/dev/null || echo "regex")
  if [[ "$CLASSIFICATION_METHOD" == "ai" ]]; then
    CRITICAL=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
ai = d.get('ai_classification') or {}
print(ai.get('critical', d.get('critical', 0)))
" 2>/dev/null || echo "0")
  else
    CRITICAL=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('critical', 0))
" 2>/dev/null || echo "0")
  fi

  if [[ "$TOTAL" -gt 0 ]] && [[ "$CRITICAL" -gt 0 ]]; then
    PR=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f: d = json.load(f)
print(d.get('pr', ''))
" 2>/dev/null || echo "")
    echo "[REMINDER] PR #${PR}: ${TOTAL}件のレビューコメント（CRITICAL=${CRITICAL}）が未対応です。" >&2
  fi
fi

exit 0
