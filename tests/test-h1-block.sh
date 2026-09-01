#!/usr/bin/env bash
# H1 非進捗ランタイム — block half (hooks/codex/h1-stall-runtime.sh).
#
# 起点事故: 2026-09-01, two Codex lanes ran 4–7h, exhausted the budget and were
# stopped by a human with near-zero landed value.  These are the 陰性テスト the
# H1 spec demands before the block half counts as delivered
# (design/ops/harness/h1-stall-runtime.md "陰性テスト（次セッションで実測）").
#
# Every hook invocation runs under HOME=$SB with AIDD_LEDGER_SOURCE=test, so the
# real ~/.claude ledger and ~/.codex state are never touched.
#
# Falsifiability is asserted, not claimed: for each of the three block rules the
# suite copies the hook, deletes that one condition, replays the same scenario
# and requires the mutant to ALLOW.  A rule whose removal changes nothing was
# never being enforced.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AIDD_LEDGER_SOURCE=test

HOOK="$ROOT/hooks/codex/h1-stall-runtime.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
LEDGER="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
mkdir -p "$SB/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SB/.claude/hooks/lib/aidd-ledger.sh"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}

# run <hook> <delegation> <command> [extra env assignments...]
run() {
  local hook="$1" delegation="$2" cmd="$3"
  shift 3
  payload "$cmd" | env HOME="$SB" \
    CODEX_H1_DELEGATION="$delegation" \
    CODEX_H1_SESSIONS_DIR="$SB/no-sessions" \
    "$@" bash "$hook"
}

decision_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("malformed"); raise SystemExit(0)
print(d.get("hookSpecificOutput", {}).get("permissionDecision", "allow"))
'
}

# Seed a state file as if the delegation had already been running.
seed_state() {
  python3 - "$SB" "$1" "$2" "$3" <<'PY'
import json, os, sys, time
sb, delegation, progress_age, streak = sys.argv[1:5]
now = int(time.time())
path = os.path.join(sb, ".codex", "hooks", "h1-state")
os.makedirs(path, exist_ok=True)
json.dump({
    "delegation": delegation, "started_ts": now - 7200,
    "last_progress_ts": now - int(progress_age),
    "iterations": 0, "tool_calls": 5, "spend_tokens": 0, "spend_usd": 0.0,
    "budget_usd": 5.0, "budget_source": "proxy:toolcalls", "max_iterations": 10,
    "no_progress_sec": 2700, "last_cmd_sha256": "", "same_cmd_streak": int(streak),
    "last_warn_80": 0, "last_heartbeat_ts": now, "last_block_rule": "",
    "last_block_ts": 0,
}, open(os.path.join(path, delegation + ".json"), "w"))
PY
}

# Write a rollout transcript carrying a cumulative token total.
seed_rollout() {
  local dir="$SB/sessions/2026/09/01"
  mkdir -p "$dir"
  cat >"$dir/rollout-2026-09-01T00-00-00-fixture.jsonl" <<EOF
{"type":"session_meta","payload":{"model":"$1"}}
{"total_token_usage":{"input_tokens":$2,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":$3,"reasoning_output_tokens":0,"total_tokens":$(($2 + $3))}}
EOF
}

# Count block rows for one delegation, optionally filtered by rule.
block_rows() {
  python3 - "$LEDGER" "$1" "${2:-}" <<'PY'
import json, os, sys
path, delegation, rule = sys.argv[1:4]
if not os.path.exists(path):
    print(0); raise SystemExit(0)
n = 0
for line in open(path):
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("component") != "H1" or row.get("event") != "block":
        continue
    if row.get("subject", {}).get("delegation") != delegation:
        continue
    if rule and row.get("rule") != rule:
        continue
    n += 1
print(n)
PY
}

# Build a mutant hook with one block condition removed.
mutate_hook() {
  local needle="$1" out="$2"
  python3 - "$HOOK" "$needle" "$out" <<'PY'
import re, sys
src, needle, out = sys.argv[1:4]
text = src and open(src, encoding="utf-8").read()
pattern = re.compile(r"^(\s*)if .*%s.*:$" % re.escape(needle), re.M)
new, n = pattern.subn(lambda m: "%sif False:  # MUTATED" % m.group(1), text)
if n != 1:
    print("mutation target not found (%d matches) for: %s" % (n, needle), file=sys.stderr)
    raise SystemExit(2)
open(out, "w", encoding="utf-8").write(new)
PY
}

echo "=== case 1: same command >=3 with aged progress -> deny (no-progress-timeout) ==="
seed_state c1 4000 0
for _ in 1 2 3; do
  out1=$(run "$HOOK" c1 "grep -rn TODO src/")
  rc1=$?
done
if [[ "$(decision_of "$out1")" == "deny" ]]; then
  ok "case1 3rd repeat denied"
else
  bad "case1 expected deny, got $(decision_of "$out1")"
fi
[[ "$rc1" -eq 0 ]] && ok "case1 deny exits 0 (Codex fails open on non-zero)" \
  || bad "case1 deny exited $rc1, not 0"
[[ "$(block_rows c1 no-progress-timeout)" -ge 1 ]] \
  && ok "case1 ledger has rule=no-progress-timeout block row" \
  || bad "case1 missing no-progress-timeout block row"

echo
echo "=== case 2: spend >= budget -> deny (budget-cap) ==="
seed_rollout "gpt-5-codex" 4000000 400000   # 4M in + 400k out = $5.00 + $4.00
out2=$(run "$HOOK" c2 "ls -la" CODEX_H1_SESSIONS_DIR="$SB/sessions")
rc2=$?
if [[ "$(decision_of "$out2")" == "deny" ]]; then
  ok "case2 over-budget call denied"
else
  bad "case2 expected deny, got $(decision_of "$out2")"
fi
[[ "$rc2" -eq 0 ]] && ok "case2 deny exits 0" || bad "case2 deny exited $rc2, not 0"
[[ "$(block_rows c2 budget-cap)" -ge 1 ]] \
  && ok "case2 ledger has rule=budget-cap block row" \
  || bad "case2 missing budget-cap block row"
if grep -q '"budget_source":"rollout:total_token_usage"' "$LEDGER"; then
  ok "case2 spend came from the rollout transcript, not the proxy"
else
  bad "case2 budget_source is not rollout:total_token_usage"
fi

echo
echo "=== case 3: iterations > max -> deny (max-iterations) ==="
for _ in 1 2 3 4 5; do
  out3=$(run "$HOOK" c3 "rg --files" CODEX_H1_MAX_ITERATIONS=3)
  rc3=$?
done
if [[ "$(decision_of "$out3")" == "deny" ]]; then
  ok "case3 iteration cap denied"
else
  bad "case3 expected deny, got $(decision_of "$out3")"
fi
[[ "$rc3" -eq 0 ]] && ok "case3 deny exits 0" || bad "case3 deny exited $rc3, not 0"
[[ "$(block_rows c3 max-iterations)" -ge 1 ]] \
  && ok "case3 ledger has rule=max-iterations block row" \
  || bad "case3 missing max-iterations block row"

echo
echo "=== case 4: varied commands under budget -> allow, no block row ==="
allow_ok=1
for cmd in "ls -la" "cat README.md" "git status" "rg TODO" "wc -l setup.sh" "git log --oneline -5"; do
  out4=$(run "$HOOK" c4 "$cmd")
  [[ "$(printf '%s' "$out4" | tr -d '[:space:]')" == "{}" ]] || allow_ok=0
done
[[ "$allow_ok" -eq 1 ]] && ok "case4 all varied commands returned {}" \
  || bad "case4 a varied command was not allowed"
[[ "$(block_rows c4)" -eq 0 ]] \
  && ok "case4 no block row for a healthy delegation" \
  || bad "case4 healthy delegation produced $(block_rows c4) block rows"

echo
echo "=== case 5: block rows carry a populated subject (H1 spec 台帳記録形式) ==="
python3 - "$LEDGER" <<'PY' && pass=$((pass + 1)) || { bad "case5 subject shape"; }
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])
        if '"component":"H1"' in l and '"event":"block"' in l]
assert rows, "no H1 block rows at all"
need = {"delegation", "spend_usd", "last_progress_ts"}
for row in rows:
    missing = need - set(row.get("subject", {}))
    assert not missing, "block row subject missing %s: %s" % (missing, row)
    assert row["source"] == "test", row
print("PASS: case5 %d block rows carry delegation/spend_usd/last_progress_ts" % len(rows))
PY

echo
echo "=== falsifiability: remove one condition, the same scenario must ALLOW ==="
MUT="$SB/mutants"
mkdir -p "$MUT"

if mutate_hook 'gap > int(state["no_progress_sec"])' "$MUT/no-progress.sh"; then
  seed_state m1 4000 0
  for _ in 1 2 3; do m1=$(run "$MUT/no-progress.sh" m1 "grep -rn TODO src/"); done
  [[ "$(decision_of "$m1")" == "allow" ]] \
    && ok "mutant without the no-progress condition allows (rule was load-bearing)" \
    || bad "mutant still denied: case1 does not prove the no-progress condition"
else
  bad "no-progress mutation target not found — falsifiability unproven"
fi

if mutate_hook 'state["spend_usd"] >= state["budget_usd"]' "$MUT/budget.sh"; then
  m2=$(run "$MUT/budget.sh" m2 "ls -la" CODEX_H1_SESSIONS_DIR="$SB/sessions")
  [[ "$(decision_of "$m2")" == "allow" ]] \
    && ok "mutant without the budget condition allows (rule was load-bearing)" \
    || bad "mutant still denied: case2 does not prove the budget condition"
else
  bad "budget mutation target not found — falsifiability unproven"
fi

if mutate_hook 'int(state["iterations"]) > int(state["max_iterations"])' "$MUT/iter.sh"; then
  for _ in 1 2 3 4 5; do m3=$(run "$MUT/iter.sh" m3 "rg --files" CODEX_H1_MAX_ITERATIONS=3); done
  [[ "$(decision_of "$m3")" == "allow" ]] \
    && ok "mutant without the iteration condition allows (rule was load-bearing)" \
    || bad "mutant still denied: case3 does not prove the iteration condition"
else
  bad "max-iterations mutation target not found — falsifiability unproven"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
