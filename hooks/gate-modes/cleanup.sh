#!/bin/bash
# cleanup.sh — CLEANUP mode: Remove merged/closed PRs from lock + review state
# =========================================================================
# Safe housekeeping: not a bypass. Only removes entries for PRs that
# GitHub confirms are already merged or closed.
# Usage: GATE_MODE=CLEANUP bash pr-ci-review-gate.sh
#    or: bash pr-ci-review-gate.sh CLEANUP
# =========================================================================
set -euo pipefail

# Resolve script directory and source common functions
GATE_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_MODES_DIR}/common.sh"

REPO=$(resolve_repo "")
if [[ -z "$REPO" ]]; then
  echo "⚠️ リポジトリ情報取得失敗。git repoディレクトリで実行してください。" >&2
  exit 1
fi

# Fix8: clean the lock entry from BOTH project-scoped AND global lock files.
# Pass a newline-separated, deduped list so a merged PR is purged everywhere.
LOCK_PATHS=$(lock_files)

CLEANED=$(_LOCK_PATHS="$LOCK_PATHS" _REVIEW="$REVIEW_STATE" _REPO="$REPO" python3 -c "
import json, subprocess, os, fcntl

lock_paths = [p for p in os.environ['_LOCK_PATHS'].splitlines() if p.strip()]
review_path = os.environ['_REVIEW']
repo = os.environ['_REPO']
lock_cleaned = []
review_cleaned = []

# Cache PR state lookups so we don't re-query the same PR across files
_state_cache = {}
def pr_state(pr):
    if pr not in _state_cache:
        try:
            r = subprocess.run(['gh','api','repos/'+repo+'/pulls/'+pr,'--jq','.state'],
                capture_output=True, text=True, timeout=10)
            _state_cache[pr] = r.stdout.strip()
        except Exception:
            _state_cache[pr] = ''
    return _state_cache[pr]

# Clean lock state in every location (with file lock)
for lock_path in lock_paths:
    if not os.path.exists(lock_path):
        continue
    with open(lock_path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            lock = json.load(f)
        except Exception:
            lock = {}
        for pr in list(lock.keys()):
            if pr_state(pr) in ('closed','merged'):
                branch = lock[pr].get('branch', '?')
                del lock[pr]
                lock_cleaned.append(f'PR #{pr} ({branch}) [{os.path.basename(os.path.dirname(lock_path))}]')
        f.seek(0); f.truncate()
        json.dump(lock, f, indent=2)
        fcntl.flock(f, fcntl.LOCK_UN)

# Clean review state (with file lock)
with open(review_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    review = json.load(f)
    for branch in list(review.keys()):
        try:
            r = subprocess.run(['gh','pr','list','--head',branch,'--state','open',
                '--json','number','-q','.[0].number'],
                capture_output=True, text=True, timeout=10)
            if not r.stdout.strip():
                del review[branch]
                review_cleaned.append(branch)
        except Exception:
            pass
    f.seek(0); f.truncate()
    json.dump(review, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)

if lock_cleaned or review_cleaned:
    for item in lock_cleaned:
        print(f'  lock: {item}')
    for item in review_cleaned:
        print(f'  review: {item}')
else:
    print('  (nothing to clean)')
" 2>/dev/null || echo "  (cleanup failed)")

echo "🧹 Housekeeping完了:" >&2
echo "$CLEANED" >&2
exit 0
