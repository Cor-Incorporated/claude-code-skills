#!/usr/bin/env bash
# test-git-commit-guard-message-parsing.sh — git commit -m parser regressions
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/git-commit-guard.sh"
TMP_REPO=""

cleanup() {
  [[ -n "$TMP_REPO" ]] && rm -rf "$TMP_REPO"
}
trap cleanup EXIT

make_payload() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {
        "command": sys.argv[1],
    },
}))
PY
}

run_hook() {
  local command="$1"
  local payload
  payload="$(make_payload "$command")"
  local ec=0
  out=$(cd "$TMP_REPO" && printf '%s\n' "$payload" | bash "$HOOK" 2>&1) || ec=$?
  return "$ec"
}

echo "=== git-commit-guard.sh message parser tests ==="

if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check"
else
  fail "T1: syntax check failed"
fi

TMP_REPO=$(mktemp -d)
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" symbolic-ref HEAD refs/heads/develop

if run_hook 'git commit -m "fix(parser): accept split refs" -m "Refs: #687"'; then
  [[ -z "$out" ]] && pass "T2: split -m subject plus Refs body passes" || fail "T2: unexpected output: $out"
else
  fail "T2: split -m commit should pass (exit $? output: $out)"
fi

multiline_command=$'git commit -m "fix(parser): accept multiline body" -m "Body line\n\nRefs: #687"'
if run_hook "$multiline_command"; then
  [[ -z "$out" ]] && pass "T3: multiline -m body with Refs passes" || fail "T3: unexpected output: $out"
else
  fail "T3: multiline -m commit should pass (exit $? output: $out)"
fi

if run_hook 'git commit -m "fix(parser): reject missing ref"'; then
  fail "T4: non-exempt type without issue ref should be blocked"
else
  if [[ "$out" == *"Issue reference"* ]]; then
    pass "T4: non-exempt type without issue ref fails"
  else
    fail "T4: expected issue reference block, got: $out"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
