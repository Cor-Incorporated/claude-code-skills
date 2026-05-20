#!/usr/bin/env bash
# test-opencode-background-permissions.sh
# Verify the effective OpenCode config allows safe background-worker shell commands.

set -euo pipefail

PASS=0
FAIL=0
TOTAL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC_SCRIPT="$ROOT/scripts/sync-opencode-background-permissions.sh"
CONFIG_FILE="${OPENCODE_CONFIG_FILE:-$HOME/.config/opencode/opencode.jsonc}"
SETUP_FILE="$ROOT/setup.sh"

# Temporary config directory for CI or machines without OpenCode installed.
TMP_CONF_DIR=""
cleanup() { [[ -n "$TMP_CONF_DIR" ]] && rm -rf "$TMP_CONF_DIR"; }
trap cleanup EXIT

echo "=== OpenCode background-safe permissions tests ==="

if bash -n "$SYNC_SCRIPT" 2>/dev/null; then
  pass "T1: sync script syntax check"
else
  fail "T1: sync script syntax check failed"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_OUTPUT="$(cat "$CONFIG_FILE")"
  pass "T2: OpenCode global config file exists"
else
  # Config absent (CI runner without OpenCode): seed a minimal stub that the
  # sync script can patch, then run the sync script on it.
  TMP_CONF_DIR="$(mktemp -d)"
  CONFIG_FILE="$TMP_CONF_DIR/opencode.jsonc"
  cat > "$CONFIG_FILE" <<'STUB'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": "anthropic",
  "model": "claude-opus-4-5",
  "keybinds": {},
  "permission": {
      // Linters/formatters
  }
}
STUB
  if OPENCODE_CONFIG_FILE="$CONFIG_FILE" bash "$SYNC_SCRIPT" "$CONFIG_FILE" >/dev/null 2>&1; then
    CONFIG_OUTPUT="$(cat "$CONFIG_FILE")"
    pass "T2: sync script patched temp config (CI mode)"
  else
    CONFIG_OUTPUT=""
    fail "T2: sync script failed on temp config"
  fi
fi

assert_contains() {
  local label="$1"
  local needle="$2"
  if echo "$CONFIG_OUTPUT" | grep -Fq "$needle"; then
    pass "$label"
  else
    fail "$label (missing: $needle)"
  fi
}

assert_contains "T3: bash -n is allowlisted" '"bash -n *": "allow"'
assert_contains "T4: sh -n is allowlisted" '"sh -n *": "allow"'
assert_contains "T5: bash tests/*.sh is allowlisted" '"bash *tests/*.sh*": "allow"'
assert_contains "T6: sh tests/*.sh is allowlisted" '"sh *tests/*.sh*": "allow"'
assert_contains "T7: bash hooks/*.sh is allowlisted" '"bash *hooks/*.sh*": "allow"'
assert_contains "T8: bash scripts/*.sh is allowlisted" '"bash *scripts/*.sh*": "allow"'
# T9: check setup.sh directly — assert_contains works on CONFIG_OUTPUT only.
if grep -Fq 'sync-opencode-background-permissions.sh' "$SETUP_FILE"; then
  pass "T9: setup.sh runs OpenCode permission sync"
else
  fail "T9: setup.sh does not reference sync-opencode-background-permissions.sh"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
