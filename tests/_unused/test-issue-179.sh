#!/bin/bash
# test-issue-179.sh — Issue #179: factcheck content validation + state-file-tampering gh exemption
set -uo pipefail

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="${SCRIPT_DIR}/../hooks"

check_exit() {
  local expected=$1 actual=$2 label="$3"
  echo "--- $label ---"
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS+1)); echo "  PASS"
  else
    FAIL=$((FAIL+1)); echo "  FAIL (expected $expected, got $actual)"
  fi
}

mk_json() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

set_factcheck() {
  local val="$1"
  python3 -c "
import json, time, os, fcntl
sf = os.path.expanduser('~/.claude/state/factcheck-status.json')
os.makedirs(os.path.dirname(sf), exist_ok=True)
ts = int(time.time()) if $val else 0
d = {'factchecked': $val, 'source': 'test', 'timestamp': ts, 'edit_count_since_check': 0}
fd = open(sf, 'w')
fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
json.dump(d, fd)
fd.close()
"
}

echo "==================================="
echo "Bug 2: block-state-file-tampering-bash.sh"
echo "==================================="
echo ""

H2="${HOOK_DIR}/block-state-file-tampering-bash.sh"

mk_json 'gh issue create --title "Bug" --body "factcheck-status.json needs fix"' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T1: gh issue create mentioning state file in body -> PASS"

mk_json 'gh pr create --title "Fix" --body "review-status.json scoping"' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T2: gh pr create mentioning state file in body -> PASS"

mk_json 'gh issue create --title "t" && echo {} > factcheck-status.json' | bash "$H2" >/dev/null 2>&1
check_exit 2 $? "T3: gh && write state file -> BLOCK"

mk_json 'echo {} > factcheck-status.json' | bash "$H2" >/dev/null 2>&1
check_exit 2 $? "T4: echo > state file -> BLOCK"

mk_json 'cat factcheck-status.json' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T5: cat state file -> PASS (read-only)"

mk_json 'ls -la' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T6: ls -la -> PASS (unrelated)"

mk_json 'gh issue view 1 ; echo x > review-status.json' | bash "$H2" >/dev/null 2>&1
check_exit 2 $? "T7: gh ; write state file -> BLOCK"

echo ""
echo "===================================="
echo "Bug 1: enforce-factcheck-github-ops.sh"
echo "==================================="
echo ""

H1="${HOOK_DIR}/enforce-factcheck-github-ops.sh"

set_factcheck "True"
echo "(factcheck=true)"

mk_json 'gh issue create --title "Fix" --body "Depends on #xxx"' | bash "$H1" >/dev/null 2>&1
check_exit 2 $? "T8: body with #xxx -> BLOCK"

mk_json 'gh issue create --title "Feature" --body "Timeline: TBD"' | bash "$H1" >/dev/null 2>&1
check_exit 2 $? "T9: body with TBD -> BLOCK"

mk_json 'gh issue create --title "Bug" --body "FIXME needs work"' | bash "$H1" >/dev/null 2>&1
check_exit 2 $? "T10: body with FIXME -> BLOCK"

mk_json 'gh issue create --title "Task" --body "PLACEHOLDER text"' | bash "$H1" >/dev/null 2>&1
check_exit 2 $? "T11: body with PLACEHOLDER -> BLOCK"

mk_json 'gh issue create --title "R" --body "API name is unverified"' | bash "$H1" >/dev/null 2>&1
check_exit 0 $? "T12: clean body (English) -> PASS"

mk_json 'gh issue create --title "Fix login" --body "Fixed auth issue in login.ts"' | bash "$H1" >/dev/null 2>&1
check_exit 0 $? "T13: clean body -> PASS"

mk_json 'gh pr create --title "Fix" --body "Resolved the issue"' | bash "$H1" >/dev/null 2>&1
check_exit 0 $? "T14: gh pr create clean -> PASS"

mk_json 'gh -R owner/repo pr create --title "Fix" --body "Resolved the issue"' | bash "$H1" >/dev/null 2>&1
check_exit 0 $? "T14b: gh -R pr create clean -> PASS"

mk_json 'gh issue view 123' | bash "$H1" >/dev/null 2>&1
check_exit 0 $? "T15: gh issue view -> PASS (not write op)"

mk_json 'gh issue create --title "Ref" --body "See #123 for context"' | bash "$H1" >/dev/null 2>&1
check_exit 0 $? "T16: valid #123 ref -> PASS"

set_factcheck "False"
echo "(factcheck=false)"

mk_json 'gh issue create --title "Clean" --body "All good"' | bash "$H1" >/dev/null 2>&1
check_exit 2 $? "T17: factcheck=false -> BLOCK"

mk_json 'gh -R owner/repo pr create --title "Clean" --body "All good"' | bash "$H1" >/dev/null 2>&1
check_exit 2 $? "T18: factcheck=false gh -R pr create -> BLOCK"

echo ""
echo "===================================="
echo "RESULTS: ${PASS} passed, ${FAIL} failed (total $((PASS+FAIL)))"
echo "===================================="
exit $FAIL
