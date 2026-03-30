#!/usr/bin/env bash
# test-issue-205-206.sh -- Test severity regex (#205) and set +e wrapper (#206)
set -euo pipefail

PASS=0
FAIL=0

RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m"

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$(( PASS + 1 )); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAIL=$(( FAIL + 1 )); }

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Issue #205: Severity regex matches Markdown heading/bold formats ---

# The regex pattern used in codex-parallel.sh (extracted for testing)
REGEX_CRIT='^\s*(#{1,6}\s+|[-*]\s+)?(\[|\*\*)?CRITICAL(\]|\*\*)?\s*[:(-]'
REGEX_HIGH='^\s*(#{1,6}\s+|[-*]\s+)?(\[|\*\*)?HIGH(\]|\*\*)?\s*[:(-]'
REGEX_MED='^\s*(#{1,6}\s+|[-*]\s+)?(\[|\*\*)?MEDIUM(\]|\*\*)?\s*[:(-]'
REGEX_LOW='^\s*(#{1,6}\s+|[-*]\s+)?(\[|\*\*)?LOW(\]|\*\*)?\s*[:(-]'

# Helper: test that a pattern matches a given line
assert_match() {
    local label="$1" pattern="$2" line="$3"
    echo "$line" | grep -cE "$pattern" >/dev/null 2>&1\
        && pass "$label" \
        || fail "$label: pattern did not match '$line'"
}

# Helper: test that a pattern does NOT match a given line
assert_no_match() {
    local label="$1" pattern="$2" line="$3"
    echo "$line" | grep -cE "$pattern" >/dev/null 2>&1\
        && fail "$label: false positive on '$line'" \
        || pass "$label"
}

# T1: Markdown H2 heading
assert_match "T1a: ## CRITICAL: desc" "$REGEX_CRIT" "## CRITICAL: security vulnerability"
assert_match "T1b: ## HIGH: desc"     "$REGEX_HIGH" "## HIGH: missing auth check"
assert_match "T1c: ## MEDIUM: desc"   "$REGEX_MED"  "## MEDIUM: error handling gap"
assert_match "T1d: ## LOW: desc"      "$REGEX_LOW"  "## LOW: naming convention"

# T2: Markdown H3 heading
assert_match "T2a: ### CRITICAL - desc" "$REGEX_CRIT" "### CRITICAL - injection risk"
assert_match "T2b: ### HIGH - desc"     "$REGEX_HIGH" "### HIGH - auth bypass"

# T2c: Markdown H4 heading with parenthetical (code-reviewer documented format)
assert_match "T2c: #### CRITICAL (block merge)" "$REGEX_CRIT" "#### CRITICAL (block merge)"
assert_match "T2d: #### HIGH (fix before merge)" "$REGEX_HIGH" "#### HIGH (fix before merge)"
assert_match "T2e: ##### MEDIUM (consider)"      "$REGEX_MED"  "##### MEDIUM (consider)"
assert_match "T2f: ###### LOW (optional)"         "$REGEX_LOW"  "###### LOW (optional)"

# T3: Bold format
assert_match "T3a: **CRITICAL**: desc" "$REGEX_CRIT" "**CRITICAL**: SQL injection"
assert_match "T3b: **HIGH**: desc"     "$REGEX_HIGH" "**HIGH**: XSS vulnerability"
assert_match "T3c: **MEDIUM**: desc"   "$REGEX_MED"  "**MEDIUM**: input validation"
assert_match "T3d: **LOW**: desc"      "$REGEX_LOW"  "**LOW**: minor style issue"

# T4: Bullet format (original pattern still works)
assert_match "T4a: - CRITICAL: desc" "$REGEX_CRIT" "- CRITICAL: finding"
assert_match "T4b: * HIGH: desc"     "$REGEX_HIGH" "* HIGH: finding"
assert_match "T4c: - MEDIUM: desc"   "$REGEX_MED"  "- MEDIUM: finding"
assert_match "T4d: - LOW: desc"      "$REGEX_LOW"  "- LOW: finding"

# T5: Plain format (no prefix)
assert_match "T5a: CRITICAL: desc" "$REGEX_CRIT" "CRITICAL: bare line"
assert_match "T5b: HIGH: desc"     "$REGEX_HIGH" "HIGH: bare line"


# T5b: Bracketed format
assert_match "T5c: [CRITICAL]: desc"     "$REGEX_CRIT" "[CRITICAL]: bare bracket"
assert_match "T5d: [HIGH]: desc"         "$REGEX_HIGH" "[HIGH]: finding"
assert_match "T5e: [MEDIUM]: desc"       "$REGEX_MED"  "[MEDIUM]: finding"
assert_match "T5f: [LOW]: desc"          "$REGEX_LOW"  "[LOW]: finding"

# T5c: Bullet + bracketed format
assert_match "T5g: - [CRITICAL]: desc"   "$REGEX_CRIT" "- [CRITICAL]: finding"
assert_match "T5h: - [HIGH]: desc"       "$REGEX_HIGH" "- [HIGH]: finding"
assert_match "T5i: * [MEDIUM]: desc"     "$REGEX_MED"  "* [MEDIUM]: finding"
assert_match "T5j: - [LOW]: desc"        "$REGEX_LOW"  "- [LOW]: finding"

# T6: False positive rejection -- prose containing severity keywords
assert_no_match "T6a: 'No CRITICAL issues found'" "$REGEX_CRIT" "No CRITICAL issues found"
assert_no_match "T6b: 'All HIGH severity items resolved'" "$REGEX_HIGH" "All HIGH severity items resolved"
assert_no_match "T6c: 'MEDIUM risk was mitigated'" "$REGEX_MED" "MEDIUM risk was mitigated"
assert_no_match "T6d: 'Found 0 LOW findings'" "$REGEX_LOW" "Found 0 LOW findings"
assert_no_match "T6e: 'the CRITICAL path'" "$REGEX_CRIT" "the CRITICAL path"

# T7: Multi-line file test (simulates actual review output)
REVIEW_FILE="$TEMP_DIR/review-output.md"
cat > "$REVIEW_FILE" <<'REVIEW'
# Code Review

## Summary
Overall the code is well-structured. No CRITICAL issues found in the main module.

## Findings

### CRITICAL - SQL injection in user input handler
The query builder concatenates user input directly.

## HIGH: Missing authentication on admin endpoint
The /admin route has no auth middleware.

**MEDIUM**: Error messages expose internal paths
Stack traces are returned to the client.

- LOW: Variable naming inconsistency
Some variables use camelCase, others use snake_case.

[CRITICAL]: Hardcoded API key in config
The config file contains a plaintext API key.

- [HIGH]: Missing rate limiting
No rate limiter on public endpoints.

#### HIGH (fix before merge)
Missing input validation on the upload endpoint.

#### CRITICAL (block merge)
Unauthenticated access to admin API.

##### MEDIUM (consider)
Logging could include request IDs for traceability.

All HIGH severity items from previous review have been resolved.
REVIEW

CRIT_COUNT=$(grep -cE "$REGEX_CRIT" "$REVIEW_FILE" 2>/dev/null || echo "0")
HIGH_COUNT=$(grep -cE "$REGEX_HIGH" "$REVIEW_FILE" 2>/dev/null || echo "0")
MED_COUNT=$(grep -cE "$REGEX_MED" "$REVIEW_FILE" 2>/dev/null || echo "0")
LOW_COUNT=$(grep -cE "$REGEX_LOW" "$REVIEW_FILE" 2>/dev/null || echo "0")

[[ "$CRIT_COUNT" -eq 3 ]] && pass "T7a: CRITICAL count=3" || fail "T7a: Expected CRITICAL=3, got $CRIT_COUNT"
[[ "$HIGH_COUNT" -eq 3 ]] && pass "T7b: HIGH count=3" || fail "T7b: Expected HIGH=3, got $HIGH_COUNT"
[[ "$MED_COUNT" -eq 2 ]] && pass "T7c: MEDIUM count=2" || fail "T7c: Expected MEDIUM=2, got $MED_COUNT"
[[ "$LOW_COUNT" -eq 1 ]] && pass "T7d: LOW count=1" || fail "T7d: Expected LOW=1, got $LOW_COUNT"

# --- Issue #206: set +e wrapper exists in codex-parallel.sh ---

# T8: Verify set +e is present before the codex exec pipe
SCRIPT_FILE="$PROJECT_DIR/scripts/codex-parallel.sh"
if grep -q 'set +e' "$SCRIPT_FILE" 2>/dev/null; then
    pass "T8a: set +e found in codex-parallel.sh"
else
    fail "T8a: set +e NOT found in codex-parallel.sh"
fi

# T9: Verify set -e is restored after PIPESTATUS capture
if awk '/CODEX_EXIT=\$\{PIPESTATUS\[0\]\}/,/set -e/' "$SCRIPT_FILE" | grep -q 'set -e'; then
    pass "T9a: set -e restored after PIPESTATUS capture"
else
    fail "T9a: set -e NOT restored after PIPESTATUS capture"
fi

# T10: Verify set +e appears before codex exec (correct order)
SET_PLUS_E_LINE=$(grep -n 'set +e' "$SCRIPT_FILE" | head -1 | cut -d: -f1)
CODEX_EXEC_LINE=$(grep -n 'codex exec' "$SCRIPT_FILE" | head -1 | cut -d: -f1)
if [[ -n "$SET_PLUS_E_LINE" ]] && [[ -n "$CODEX_EXEC_LINE" ]] && [[ "$SET_PLUS_E_LINE" -lt "$CODEX_EXEC_LINE" ]]; then
    pass "T10a: set +e (line $SET_PLUS_E_LINE) before codex exec (line $CODEX_EXEC_LINE)"
else
    fail "T10a: set +e should appear before codex exec"
fi

# T11: Verify set -e is restored after EXIT_CODE=$? in implementation mode
# Implementation mode codex exec is the second occurrence (after review mode)
IMPL_EXIT_LINE=$(grep -n 'EXIT_CODE=\$?' "$SCRIPT_FILE" | head -1 | cut -d: -f1)
if [[ -n "$IMPL_EXIT_LINE" ]]; then
    NEXT_LINE=$(( IMPL_EXIT_LINE + 1 ))
    NEXT_CONTENT=$(sed -n "${NEXT_LINE}p" "$SCRIPT_FILE")
    if [[ "$NEXT_CONTENT" == "set -e" ]]; then
        pass "T11a: set -e immediately after EXIT_CODE=\$? (line $IMPL_EXIT_LINE)"
    else
        fail "T11a: Expected 'set -e' on line $NEXT_LINE after EXIT_CODE=\$?, got '$NEXT_CONTENT'"
    fi
else
    fail "T11a: EXIT_CODE=\$? not found in implementation mode"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
