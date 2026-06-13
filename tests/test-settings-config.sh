#!/usr/bin/env bash
# test-settings-config.sh -- Validate repo-owned Claude Code settings.

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
SETTINGS="$ROOT/settings.json"

echo "=== Settings config tests ==="

if python3 -m json.tool "$SETTINGS" >/dev/null; then
  pass "T1: settings.json is valid JSON"
else
  fail "T1: settings.json is invalid JSON"
fi

model=$(python3 - <<'PY' "$SETTINGS"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f).get("model", ""))
PY
)

if [[ "$model" == "opus" ]]; then
  pass "T2: model uses the Claude Code opus alias"
else
  fail "T2: expected model 'opus', got '$model'"
fi

if python3 - <<'PY' "$model"
import re
import sys

model = sys.argv[1]
has_control = any(ord(ch) < 32 or ord(ch) == 127 for ch in model)
has_ansi_escape = bool(re.search(r"\x1b\[[0-9;]*m", model))
has_rendered_ansi = bool(re.search(r"\[[0-9;]*m", model))
sys.exit(1 if has_control or has_ansi_escape or has_rendered_ansi else 0)
PY
then
  pass "T3: model contains no ANSI/control fragments"
else
  fail "T3: model contains ANSI/control fragments"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
