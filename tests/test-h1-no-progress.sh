#!/usr/bin/env bash
# T7-2: H1 no-progress visibility — heartbeat + gap warn (NOT a block).
# Falsifiable: a fake HOME ledger with an old H1 row must produce
#   - H1 rows >= 2 (measure + warn)
#   - rule:no-progress-timeout >= 1
# Run with HOME=fake so the real ~/.claude/hooks ledger is never touched.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AIDD_LEDGER_SOURCE=test  # T9-2: ledger rows from test harness are source=test

HOOK="$ROOT/hooks/enforce-hook-deploy-integrity.sh"
chmod +x "$HOOK"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

# --- first run: no prior H1 rows → heartbeat only ---
env HOME="$SB" bash "$HOOK" >/dev/null 2>&1
LEDGER="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
if [[ -f "$LEDGER" ]]; then
  n=$(grep -c '"component":"H1"' "$LEDGER" || true)
  if [[ "$n" -eq 1 ]]; then
    ok "first run appends 1 H1 heartbeat (got $n)"
  else
    bad "first run expected 1 H1 row, got $n"
  fi
else
  bad "ledger not created at $LEDGER"
fi

# --- second run with an aged row: warn (no-progress-timeout) + heartbeat ---
# Rewrite the H1 row's ts to 60 minutes ago, then re-run.
python3 - "$LEDGER" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
path = sys.argv[1]
old = datetime.now(timezone.utc) - timedelta(minutes=60)
rows = []
for line in open(path):
    try:
        row = json.loads(line)
    except Exception:
        rows.append(line.rstrip("\n"))
        continue
    if row.get("component") == "H1":
        row["ts"] = old.strftime("%Y-%m-%dT%H:%M:%SZ")
    rows.append(json.dumps(row))
open(path, "w").write("\n".join(rows) + "\n")
PY
env HOME="$SB" bash "$HOOK" >/dev/null 2>&1

h1=$(grep -c '"component":"H1"' "$LEDGER" || true)
npt=$(grep -c '"rule":"no-progress-timeout"' "$LEDGER" || true)
if [[ "$h1" -ge 2 ]]; then
  ok "ledger has >=2 H1 rows (got $h1)"
else
  bad "expected >=2 H1 rows, got $h1"
fi
if [[ "$npt" -ge 1 ]]; then
  ok "ledger has >=1 no-progress-timeout (got $npt)"
else
  bad "expected no-progress-timeout row, got $npt"
fi
missing_source=$(python3 - "$LEDGER" <<'PY'
import json, sys
print(sum(1 for line in open(sys.argv[1]) if (row := json.loads(line)).get("component") == "H1" and row.get("source") != "test"))
PY
)
if [[ "$missing_source" -eq 0 ]]; then
  ok "all H1 test rows carry source=test"
else
  bad "H1 rows without source=test: $missing_source"
fi
grep '"rule":"no-progress-timeout"' "$LEDGER" | python3 -c "
import json, sys
row = json.loads(sys.stdin.readline())
assert row['component'] == 'H1' and row['event'] == 'warn' and row['source'] == 'test', row
print('PASS: warn row shape', json.dumps(row, ensure_ascii=False)[:120])
" && pass=$((pass + 1)) || { bad "warn row shape"; }

# --- third run (no gap): heartbeat only, no extra warn ---
env HOME="$SB" bash "$HOOK" >/dev/null 2>&1
npt2=$(grep -c '"rule":"no-progress-timeout"' "$LEDGER" || true)
if [[ "$npt2" -eq 1 ]]; then
  ok "no new warn when gap < 45min (got $npt2)"
else
  bad "expected warn count unchanged (1), got $npt2"
fi

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
