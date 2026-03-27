#!/bin/bash
# stop.sh — STOP mode: Informational warnings on session stop
# =========================================================================
# Issue #181: STOP mode is INFORMATIONAL ONLY — never blocks (always exit 0)
#   - CI pending  → allow stop silently
#   - CI fail     → warn to stderr, allow stop
#   - Unverified  → warn to stderr, allow stop
# Only PRE_MERGE and PRE_CREATE modes should hard-block.
#
# Exit 0 = allow (always)
# All output to stderr (Claude Code hooks spec)
# =========================================================================
set -euo pipefail

# =========================================================================
# CRITICAL: STOP mode MUST exit 0 under ALL circumstances.
# Even if python3 is missing, lock files don't exist, git fails, etc.
# This trap catches ANY error and forces exit 0.
# =========================================================================
trap 'exit 0' ERR

# =========================================================================
# CRITICAL: Redirect ALL stdout to stderr.
# Claude Code Stop hooks MUST produce valid JSON or empty stdout.
# Any non-JSON text on stdout causes "JSON validation failed" errors.
# $() captures still work correctly (they create their own pipe for fd 1).
# =========================================================================
exec 1>&2

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh" || true

# =========================================================================
# Issue #66 Fix #3: stop_hook_active check (official docs compliance)
# stop_hook_active=true -> already in a prior Stop hook -> prevent infinite loop
# =========================================================================
if [[ -n "${input:-}" ]] && command -v jq &>/dev/null; then
  _stop_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
  if [[ "$_stop_active" == "true" ]]; then
    exit 0
  fi
fi

# Issue #58: Skip gate during active error recovery
# Dirty working tree = active work in progress -> skip silently
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
" 2>/dev/null || true
fi

# =========================================================================
# Gather PR status — informational warnings only (never block)
# =========================================================================
UNVERIFIED=$(_LOCK="$LOCK_STATE" python3 -c "
import json, os
with open(os.environ['_LOCK']) as f: s = json.load(f)
unverified = [f'PR #{pr} ({d.get(\"branch\",\"?\")})' for pr, d in s.items()
              if isinstance(d, dict) and d.get('ci_green', False) and not d.get('verified', False)]
print('|'.join(unverified) if unverified else '')
" 2>/dev/null || echo "")
CI_PENDING=$(_LOCK="$LOCK_STATE" python3 -c "
import json, os
with open(os.environ['_LOCK']) as f: s = json.load(f)
pending = [f'PR #{pr} ({d.get(\"branch\",\"?\")})' for pr, d in s.items()
           if isinstance(d, dict) and not d.get('ci_green', False) and not d.get('verified', False)]
print('|'.join(pending) if pending else '')
" 2>/dev/null || echo "")

# Issue #181: All warnings are informational — exit 0 regardless
if [[ -n "$UNVERIFIED" ]]; then
  cat >&2 <<MSG
[INFO] 未検証PRがあります（停止はブロックしません）:
$(echo "$UNVERIFIED" | tr '|' '\n' | sed 's/^/  - /')

次のセッションで以下を実行してください:
  1. gh pr checks <PR番号> で全グリーン確認
  2. code-reviewer + Codex CLI レビュー実行
  3. bash ~/.claude/hooks/pr-ci-review-gate.sh VERIFY <PR番号>
MSG
fi
if [[ -n "$CI_PENDING" ]]; then
  echo "[INFO] CI未完了/未検証のPR:" >&2
  echo "$CI_PENDING" | tr '|' '\n' | sed 's/^/  - /' >&2
fi
exit 0
