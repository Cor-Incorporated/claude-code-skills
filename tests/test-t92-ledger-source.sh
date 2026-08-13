#!/usr/bin/env bash
# T9-2: ledger source column — F1 truth table (env × block/allow × hook kinds)
# Falsifiable: rows written with AIDD_LEDGER_SOURCE=test carry source=test,
# rows without it carry source=real. Runs in fake HOME (never touches real ledger).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/hooks/lib/aidd-ledger.sh"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

check_row() {  # $1=expected source, $2=ledger path
  local expect="$1" ledger="$2"
  local got
  got=$(tail -1 "$ledger" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['source'])" 2>/dev/null || echo MISSING)
  if [[ "$got" == "$expect" ]]; then
    ok "ledger row source=$expect (got $got)"
  else
    bad "expected source=$expect got=$got"
  fi
}

# --- 軸1: env 設定あり（test）/ なし（real）× 軸3: hook 4 種 × 軸2: block/allow ---
HOOKS=("block-local-hooks-write.sh" "aidd-h3-evidence-check.sh" "aidd-h3-evidence-stop.sh" "enforce-hook-deploy-integrity.sh")
for h in "${HOOKS[@]}"; do
  for ev in block allow; do
    # real (env unset)
    LED="$SB/real-$h-$ev.jsonl"
    (
      export HOME="$SB"
      unset AIDD_LEDGER_SOURCE
      . "$LIB"
      aidd_ledger_append "$h" "$ev" deny "test cmd" "test-rule" >>/dev/null 2>&1
    ) 2>/dev/null
    # 台帳パスが HOME 基準なので、直接書く
    LEDGER_PATH="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
    check_row "real" "$LEDGER_PATH" && rm -f "$LEDGER_PATH"

    # test (env set)
    (
      export HOME="$SB" AIDD_LEDGER_SOURCE=test
      . "$LIB"
      aidd_ledger_append "$h" "$ev" deny "test cmd" "test-rule" >>/dev/null 2>&1
    ) 2>/dev/null
    check_row "test" "$LEDGER_PATH" && rm -f "$LEDGER_PATH"
  done
done

# --- 実 hook 経路（enforce-hook-deploy-integrity.sh — SessionStart） ---
# env なし → H1 heartbeat 自体が source=real になることを確認。
LEDGER_PATH="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
if env -u AIDD_LEDGER_SOURCE HOME="$SB" bash "$ROOT/hooks/enforce-hook-deploy-integrity.sh" >/dev/null 2>&1; then
  if python3 - "$LEDGER_PATH" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows, "no ledger rows"
assert all(row.get("source") == "real" for row in rows), rows
assert any(row.get("component") == "H1" for row in rows), rows
PY
  then
    ok "real H1 hook run writes source=real with no unattributed rows"
  else
    bad "real H1 hook run produced missing/non-real source"
  fi
else
  bad "enforce-hook failed"
fi

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
