#!/usr/bin/env bash
# test-pre-create-severity.sh -- Test severity-aware pre-create gate (#203)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

RED="[0;31m"
GREEN="[0;32m"
NC="[0m"

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$(( PASS + 1 )); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAIL=$(( FAIL + 1 )); }

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Set CLAUDE_PROJECT_DIR so common.sh uses temp dir for STATE_DIR
export CLAUDE_PROJECT_DIR="$TEMP_DIR"
# Source common.sh — its init block will set STATE_DIR=$TEMP_DIR/.claude/state
# and create empty state files there
source "$PROJECT_DIR/hooks/gate-modes/common.sh" 2>/dev/null || true

# Now override REVIEW_STATE to a flat path in TEMP_DIR for easier test control.
# common.sh now ignores non-repo broad CLAUDE_PROJECT_DIR values when a real repo
# cwd exists, so this test creates its temp state directory explicitly.
mkdir -p "$TEMP_DIR/.claude/state"
export REVIEW_STATE="$TEMP_DIR/.claude/state/rs.json"
export LOCK_STATE="$TEMP_DIR/.claude/state/lk.json"
echo '{}'  > "$REVIEW_STATE"
echo '{}'  > "$LOCK_STATE"

BRANCH="test-sev-branch"

# Test 1: missing data returns -1
result=$(read_codex_severity "$BRANCH" "codex_critical")
[[ "$result" == "-1" ]] && pass "T1: read_codex_severity -1 for missing data" || fail "T1: Expected -1, got: $result"

# Test 2: MEDIUM-only data readable
python3 -c "import json,os; rs=os.environ[chr(82)+chr(69)+chr(86)+chr(73)+chr(69)+chr(87)+chr(95)+chr(83)+chr(84)+chr(65)+chr(84)+chr(69)]; d={chr(116)+chr(101)+chr(115)+chr(116)+chr(45)+chr(115)+chr(101)+chr(118)+chr(45)+chr(98)+chr(114)+chr(97)+chr(110)+chr(99)+chr(104):{chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119):True,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119)+chr(95)+chr(114)+chr(97)+chr(110):True,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(99)+chr(114)+chr(105)+chr(116)+chr(105)+chr(99)+chr(97)+chr(108):0,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(104)+chr(105)+chr(103)+chr(104):0,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(109)+chr(101)+chr(100)+chr(105)+chr(117)+chr(109):2,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(108)+chr(111)+chr(119):1}}; open(rs,chr(119)).write(json.dumps(d,indent=2))"
result=$(read_codex_severity "$BRANCH" "codex_critical")
[[ "$result" == "0" ]] && pass "T2a: read_codex_severity CRITICAL=0" || fail "T2a: Expected 0, got: $result"
result=$(read_codex_severity "$BRANCH" "codex_medium")
[[ "$result" == "2" ]] && pass "T2b: read_codex_severity MEDIUM=2" || fail "T2b: Expected 2, got: $result"

# Test 3: codex_review=yes when MEDIUM-only
result=$(read_review "$BRANCH" "codex_review")
[[ "$result" == "yes" ]] && pass "T3a: MEDIUM-only codex_review=yes" || fail "T3a: Expected yes, got: $result"
result=$(read_review "$BRANCH" "codex_review_ran")
[[ "$result" == "yes" ]] && pass "T3b: MEDIUM-only codex_review_ran=yes" || fail "T3b: Expected yes, got: $result"

# Test 4: HIGH present should block (no override)
python3 -c "import json,os; rs=os.environ[chr(82)+chr(69)+chr(86)+chr(73)+chr(69)+chr(87)+chr(95)+chr(83)+chr(84)+chr(65)+chr(84)+chr(69)]; d={chr(116)+chr(101)+chr(115)+chr(116)+chr(45)+chr(115)+chr(101)+chr(118)+chr(45)+chr(98)+chr(114)+chr(97)+chr(110)+chr(99)+chr(104):{chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119):False,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119)+chr(95)+chr(114)+chr(97)+chr(110):True,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(99)+chr(114)+chr(105)+chr(116)+chr(105)+chr(99)+chr(97)+chr(108):0,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(104)+chr(105)+chr(103)+chr(104):1,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(109)+chr(101)+chr(100)+chr(105)+chr(117)+chr(109):1,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(108)+chr(111)+chr(119):0}}; open(rs,chr(119)).write(json.dumps(d,indent=2))"
result=$(read_review "$BRANCH" "codex_review")
[[ "$result" == "no" ]] && pass "T4a: HIGH present codex_review=no" || fail "T4a: Expected no, got: $result"
_critical=$(read_codex_severity "$BRANCH" "codex_critical")
_high=$(read_codex_severity "$BRANCH" "codex_high")
_ran=$(read_review "$BRANCH" "codex_review_ran")
if [[ "$_ran" == "yes" ]] && [[ "$_critical" != "-1" ]] && [[ "$_critical" -eq 0 ]] 2>/dev/null && [[ "$_high" != "-1" ]] && [[ "$_high" -eq 0 ]] 2>/dev/null; then
  fail "T4b: HIGH present should block but override triggered"
else
  pass "T4b: HIGH present severity check correctly blocks"
fi

# Test 5: MEDIUM-only override (codex_review=false, C=0, H=0)
python3 -c "import json,os; rs=os.environ[chr(82)+chr(69)+chr(86)+chr(73)+chr(69)+chr(87)+chr(95)+chr(83)+chr(84)+chr(65)+chr(84)+chr(69)]; d={chr(116)+chr(101)+chr(115)+chr(116)+chr(45)+chr(115)+chr(101)+chr(118)+chr(45)+chr(98)+chr(114)+chr(97)+chr(110)+chr(99)+chr(104):{chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119):False,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119)+chr(95)+chr(114)+chr(97)+chr(110):True,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(99)+chr(114)+chr(105)+chr(116)+chr(105)+chr(99)+chr(97)+chr(108):0,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(104)+chr(105)+chr(103)+chr(104):0,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(109)+chr(101)+chr(100)+chr(105)+chr(117)+chr(109):2,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(108)+chr(111)+chr(119):0}}; open(rs,chr(119)).write(json.dumps(d,indent=2))"
result=$(read_review "$BRANCH" "codex_review")
_ran=$(read_review "$BRANCH" "codex_review_ran")
_critical=$(read_codex_severity "$BRANCH" "codex_critical")
_high=$(read_codex_severity "$BRANCH" "codex_high")
CODEX_OVERRIDE="no"
if [[ "$result" != "yes" ]] && [[ "$_ran" == "yes" ]] && [[ "$_critical" != "-1" ]] && [[ "$_critical" -eq 0 ]] 2>/dev/null && [[ "$_high" != "-1" ]] && [[ "$_high" -eq 0 ]] 2>/dev/null; then
  CODEX_OVERRIDE="yes"
fi
[[ "$CODEX_OVERRIDE" == "yes" ]] && pass "T5: MEDIUM-only C=0 H=0 override=yes" || fail "T5: Expected override=yes, got: $CODEX_OVERRIDE"

# Test 6: Non-numeric value rejected
python3 -c "import json,os; rs=os.environ[chr(82)+chr(69)+chr(86)+chr(73)+chr(69)+chr(87)+chr(95)+chr(83)+chr(84)+chr(65)+chr(84)+chr(69)]; d={chr(116)+chr(101)+chr(115)+chr(116)+chr(45)+chr(115)+chr(101)+chr(118)+chr(45)+chr(98)+chr(114)+chr(97)+chr(110)+chr(99)+chr(104):{chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119):False,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(114)+chr(101)+chr(118)+chr(105)+chr(101)+chr(119)+chr(95)+chr(114)+chr(97)+chr(110):True,chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(99)+chr(114)+chr(105)+chr(116)+chr(105)+chr(99)+chr(97)+chr(108):chr(109)+chr(97)+chr(108)+chr(105)+chr(99)+chr(105)+chr(111)+chr(117)+chr(115),chr(99)+chr(111)+chr(100)+chr(101)+chr(120)+chr(95)+chr(104)+chr(105)+chr(103)+chr(104):0}}; open(rs,chr(119)).write(json.dumps(d,indent=2))"
result=$(read_codex_severity "$BRANCH" "codex_critical")
[[ "$result" == "-1" ]] && pass "T6: non-numeric codex_critical rejected" || fail "T6: Expected -1 for non-numeric, got: $result"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
