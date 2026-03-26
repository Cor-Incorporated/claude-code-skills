#!/bin/bash
# stop.sh — STOP mode: Block session stop if unverified PRs exist
# =========================================================================
# Exit 0 = allow, Exit 2 = HARD BLOCK
# All output to stderr (Claude Code hooks spec)
# =========================================================================
set -euo pipefail

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh"

# =========================================================================
# Issue #66 Fix #3: stop_hook_active check (official docs compliance)
# Ref: https://code.claude.com/docs/en/hooks
#   "To prevent Claude Code from running indefinitely,
#    check stop_hook_active or analyze the transcript."
# stop_hook_active=true -> already in a prior Stop hook -> prevent infinite loop
# =========================================================================
if [[ -n "${input:-}" ]] && command -v jq &>/dev/null; then
  _stop_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
  if [[ "$_stop_active" == "true" ]]; then
    echo "[stop-gate] stop_hook_active=true: 2回目のStop hook。ログ出力のみ。" >&2
    exit 0
  fi
fi

# Issue #58: Skip gate during active error recovery
# Dirty working tree = active work in progress -> don't block session end
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
unverified = [f'PR #{pr} ({d.get(\"branch\",\"?\")})' for pr, d in s.items()
              if isinstance(d, dict) and d.get('ci_green', False) and not d.get('verified', False)]
print('|'.join(unverified) if unverified else '')
" 2>/dev/null || echo "")
SKIPPED_UNVERIFIED=$(_LOCK="$LOCK_STATE" python3 -c "
import json, os
with open(os.environ['_LOCK']) as f: s = json.load(f)
skipped = [f'PR #{pr} ({d.get(\"branch\",\"?\")})' for pr, d in s.items()
           if isinstance(d, dict) and not d.get('ci_green', False) and not d.get('verified', False)]
print('|'.join(skipped) if skipped else '')
" 2>/dev/null || echo "")

if [[ -n "$UNVERIFIED" ]]; then
  cat >&2 <<MSG
[BLOCKED] 未検証PRが存在します。CI green + レビュー LGTM を確認してください。
$(echo "$UNVERIFIED" | tr '|' '\n' | sed 's/^/  - /')

解除方法:
  1. gh pr checks <PR番号> で全グリーン確認
  2. code-reviewer + Codex CLI レビュー実行
  3. bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY <PR番号>
MSG
  exit 2
fi
if [[ -n "$SKIPPED_UNVERIFIED" ]]; then
  echo "[stop-gate] CI green 未達の未検証PRは停止ブロック対象外としてスキップしました:" >&2
  echo "$SKIPPED_UNVERIFIED" | tr '|' '\n' | sed 's/^/  - /' >&2
fi
exit 0
