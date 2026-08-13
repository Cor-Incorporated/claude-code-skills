#!/usr/bin/env bash
# Phase 18 T18-3: ledger rows attribute a firing to the declared lane/session.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/hooks/lib/aidd-ledger.sh"
SB=$(mktemp -d)
LEDGER="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
pass=0
fail=0

check() {
  local env_axis="$1" event="$2" expected="$3"
  if [[ "$env_axis" == "set" ]]; then
    (
      export HOME="$SB" AIDD_LEDGER_SOURCE=test AIDD_LEDGER_SESSION=Lane-CX
      . "$LIB"
      aidd_ledger_append "phase18-session" "$event" "deny" "probe" "session-attribution"
    )
  else
    (
      export HOME="$SB" AIDD_LEDGER_SOURCE=test
      unset AIDD_LEDGER_SESSION
      . "$LIB"
      aidd_ledger_append "phase18-session" "$event" "deny" "probe" "session-attribution"
    )
  fi

  actual=$(tail -1 "$LEDGER" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session", "MISSING"))')
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS: env=%s event=%s session=%s\n' "$env_axis" "$event" "$actual"
    pass=$((pass + 1))
  else
    printf 'FAIL: env=%s event=%s expected=%s actual=%s\n' "$env_axis" "$event" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

for event in block warn; do
  check set "$event" Lane-CX
  check unset "$event" unset
done

python3 - "$LEDGER" <<'PY' || fail=$((fail + 1))
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert len(rows) == 4, rows
assert all("session" in row for row in rows), rows
print("PASS: all new rows contain the session field")
PY

printf '%s\n' "--- $pass matrix cells passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
