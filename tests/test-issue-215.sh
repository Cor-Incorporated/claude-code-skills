#!/usr/bin/env bash
# test-issue-215.sh — Severity regex: bullet+bold + delimiter mismatch (#215)
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

echo "=== Issue #215: Severity regex tests ==="

# The regex pattern used in codex-parallel.sh (paired delimiters)
REGEX_CRIT='^\s*(#{1,6}\s+|[-*]\s+)?(\*\*CRITICAL\*\*|\[CRITICAL\]|CRITICAL)\s*[:(-]'
REGEX_HIGH='^\s*(#{1,6}\s+|[-*]\s+)?(\*\*HIGH\*\*|\[HIGH\]|HIGH)\s*[:(-]'

assert_match() {
  local label="$1" pattern="$2" input="$3"
  if echo "$input" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label: '$input' should match"
  fi
}

assert_no_match() {
  local label="$1" pattern="$2" input="$3"
  if echo "$input" | grep -qE "$pattern"; then
    fail "$label: '$input' should NOT match"
  else
    pass "$label"
  fi
}

# T1: Plain format
assert_match "T1: plain CRITICAL:" "$REGEX_CRIT" "CRITICAL: SQL injection found"

# T2: Bold format
assert_match "T2: bold **CRITICAL**:" "$REGEX_CRIT" "**CRITICAL**: SQL injection found"

# T3: Bracket format
assert_match "T3: bracket [CRITICAL]:" "$REGEX_CRIT" "[CRITICAL]: SQL injection found"

# T4: Header format
assert_match "T4: header ## CRITICAL:" "$REGEX_CRIT" "## CRITICAL: SQL injection found"

# T5: Bullet format
assert_match "T5: bullet - CRITICAL:" "$REGEX_CRIT" "- CRITICAL: SQL injection found"

# T6: Bullet + bold (the main fix for #215)
assert_match "T6: bullet+bold - **CRITICAL**:" "$REGEX_CRIT" "- **CRITICAL**: SQL injection found"

# T7: Bullet + bold with asterisk
assert_match "T7: bullet+bold * **CRITICAL**:" "$REGEX_CRIT" "* **CRITICAL**: SQL injection found"

# T8: Delimiter mismatch — should NOT match
assert_no_match "T8: mismatch **CRITICAL]:" "$REGEX_CRIT" "**CRITICAL]: SQL injection found"

# T9: Delimiter mismatch — should NOT match
assert_no_match "T9: mismatch [CRITICAL**:" "$REGEX_CRIT" "[CRITICAL**: SQL injection found"

# T10: Prose — should NOT match
assert_no_match "T10: prose 'No CRITICAL issues'" "$REGEX_CRIT" "No CRITICAL issues found in this review"

# T11: HIGH pattern works similarly
assert_match "T11: bold **HIGH**:" "$REGEX_HIGH" "- **HIGH**: Missing validation"

# T12: Multi-line file test
TMPFILE=$(mktemp)
cat > "$TMPFILE" <<'EOF'
## Review Results

- **CRITICAL**: SQL injection in login.ts
[CRITICAL]: XSS vulnerability
CRITICAL: Hardcoded API key
- **HIGH**: Missing input validation
**HIGH**: No rate limiting
No CRITICAL issues in the summary
This is HIGH quality code
EOF

_CRIT=$(grep -cE "$REGEX_CRIT" "$TMPFILE" 2>/dev/null || echo "0")
_HIGH=$(grep -cE "$REGEX_HIGH" "$TMPFILE" 2>/dev/null || echo "0")
rm -f "$TMPFILE"

if [[ "$_CRIT" -eq 3 ]]; then
  pass "T12a: multi-line CRITICAL count = 3"
else
  fail "T12a: multi-line CRITICAL count expected 3, got $_CRIT"
fi

if [[ "$_HIGH" -eq 2 ]]; then
  pass "T12b: multi-line HIGH count = 2"
else
  fail "T12b: multi-line HIGH count expected 2, got $_HIGH"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
