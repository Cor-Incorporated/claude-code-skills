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

REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
if [[ -z "$REPO" ]]; then
  echo "⚠️ リポジトリ情報取得失敗。git repoディレクトリで実行してください。" >&2
  exit 1
fi

CLEANED=$(_LOCK="$LOCK_STATE" _REVIEW="$REVIEW_STATE" _REPO="$REPO" python3 -c "
import json, subprocess, os, fcntl

lock_path = os.environ['_LOCK']
review_path = os.environ['_REVIEW']
repo = os.environ['_REPO']
lock_cleaned = []
review_cleaned = []

# Clean lock state (with file lock)
with open(lock_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    lock = json.load(f)
    for pr in list(lock.keys()):
        try:
            r = subprocess.run(['gh','api','repos/'+repo+'/pulls/'+pr,'--jq','.state'],
                capture_output=True, text=True, timeout=10)
            if r.stdout.strip() in ('closed','merged'):
                branch = lock[pr].get('branch', '?')
                del lock[pr]
                lock_cleaned.append(f'PR #{pr} ({branch})')
        except Exception:
            pass
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
