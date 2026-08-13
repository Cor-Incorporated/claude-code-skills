#!/usr/bin/env bash
# Phase 18 T18-2: Cursor push rules only inspect the `git push` segment.
set -uo pipefail
export AIDD_LEDGER_SOURCE=test

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/cursor/git-guard.sh"
SB=$(mktemp -d)
mkdir -p "$SB/.cursor/hooks"

pass=0
fail=0

permission() {
  local command="$1" payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$command")
  printf '%s' "$payload" | env HOME="$SB" AIDD_LEDGER_SOURCE=test bash "$HOOK" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("permission", "missing"))'
}

check() {
  local name="$1" expected="$2" command="$3" actual
  actual=$(permission "$command")
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS: %s expected=%s actual=%s\n' "$name" "$expected" "$actual"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s expected=%s actual=%s command=%s\n' "$name" "$expected" "$actual" "$command"
    fail=$((fail + 1))
  fi
}

echo '--- safe push × unrelated protected-branch token (separator axis) ---'
check 'and separator' allow 'git push -u origin HEAD && gh pr create --base main'
check 'semicolon separator' allow 'git push -u origin HEAD; gh pr create --base main'
check 'or separator' allow 'git push -u origin HEAD || gh pr create --base main'

echo '--- destructive push remains denied in its own segment ---'
check 'mirror before PR' deny 'git push origin --mirror && gh pr create --base feat/x'
check 'direct main after safe command' deny 'printf ready; git push origin main'
check 'force refspec before PR' deny 'git push origin +HEAD:main || gh pr create --base feat/x'

echo '--- ordinary single commands ---'
check 'feature push' allow 'git push origin feat/x'
check 'direct protected push' deny 'git push origin develop'
check 'non-push' allow 'git status'

printf '%s\n' "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
