#!/usr/bin/env bash
# test-codex-task-doc-gate.sh — Tests for codex-task-gate.sh doc detection
# Verifies: design artifacts are exempt; bulk docs warn at >=5; ADR pattern coverage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/hooks/codex-task-gate.sh"
PASS=0; FAIL=0

pass() { echo -e "\033[0;32mPASS\033[0m: $1"; PASS=$(( PASS + 1 )); }
fail() { echo -e "\033[0;31mFAIL\033[0m: $1"; FAIL=$(( FAIL + 1 )); }

# Use a temp state dir to keep test runs isolated
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
export HOME="$STATE_DIR"
mkdir -p "$STATE_DIR/.claude/state"

make_write_input() {
    local fp="$1"
    printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$fp"
}

run_hook() {
    echo "$1" | bash "$HOOK" 2>&1 || true
}

# ── Design artifact exemptions ──────────────────────────────────────────────

out=$(run_hook "$(make_write_input "/repo/docs/adr/ADR-001.md")")
[[ -z "$out" ]] && pass "T01: docs/adr/ADR-001.md exempt (no output)" || fail "T01: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/docs/adr/ADR-002.md")")
[[ -z "$out" ]] && pass "T02: docs/adr/ADR-002.md exempt (no output)" || fail "T02: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/docs/adr/ADR-003.md")")
[[ -z "$out" ]] && pass "T03: docs/adr/ADR-003.md exempt (no output)" || fail "T03: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/docs/adr/ADR-004.md")")
[[ -z "$out" ]] && pass "T04: docs/adr/ADR-004.md exempt (no output)" || fail "T04: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/docs/adr/ADR-005.md")")
[[ -z "$out" ]] && pass "T05: docs/adr/ADR-005.md exempt (no output)" || fail "T05: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/docs/adr/ADR-006.md")")
[[ -z "$out" ]] && pass "T06: docs/adr/ADR-006.md exempt (no output)" || fail "T06: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/DESIGN.md")")
[[ -z "$out" ]] && pass "T07: DESIGN.md exempt (no output)" || fail "T07: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/ARCHITECTURE.md")")
[[ -z "$out" ]] && pass "T08: ARCHITECTURE.md exempt (no output)" || fail "T08: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/SYSTEM-DESIGN.md")")
[[ -z "$out" ]] && pass "T09: SYSTEM-DESIGN.md exempt (no output)" || fail "T09: unexpected output: $out"

out=$(run_hook "$(make_write_input "/repo/docs/design-requirements.md")")
[[ -z "$out" ]] && pass "T10: design-requirements.md exempt (no output)" || fail "T10: unexpected output: $out"

# Reset state for bulk doc tests
echo '{}' > "$STATE_DIR/.claude/state/codex-task-gate.json"

# ── Bulk doc threshold: warn at >=5, not at <5 ───────────────────────────────

for i in 1 2 3 4; do
    out=$(run_hook "$(make_write_input "/repo/docs/guide${i}.md")")
    [[ -z "$out" ]] && pass "T1${i}: doc ${i}/4 — no warning yet" || fail "T1${i}: unexpected warning at ${i}: $out"
done

out=$(run_hook "$(make_write_input "/repo/docs/guide5.md")")
[[ "$out" == *"CODEX DELEGATION"* ]] && pass "T15: doc 5/5 — warning fires" || fail "T15: expected warning at 5: $out"

# ── Non-doc .md files should not count ───────────────────────────────────────

echo '{}' > "$STATE_DIR/.claude/state/codex-task-gate.json"

out=$(run_hook "$(make_write_input "/repo/src/README.md")")
# README matches "readme" → should count as doc
run_hook "$(make_write_input "/repo/src/README.md")" >/dev/null || true

out=$(run_hook "$(make_write_input "/repo/src/component.tsx")")
[[ -z "$out" ]] && pass "T16: source .tsx file — no doc gate" || fail "T16: unexpected output: $out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
