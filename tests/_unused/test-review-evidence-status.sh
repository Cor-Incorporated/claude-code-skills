#!/bin/bash
# Focused coverage for scripts/review-evidence-status.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/review-evidence-status.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TMP_HOME="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
STATE_DIR="$PROJECT/.claude/state"
GLOBAL_STATE_DIR="$TMP_HOME/.claude/state"
OUT="$TMP_ROOT/out.json"
ERR="$TMP_ROOT/err.txt"
mkdir -p "$STATE_DIR" "$GLOBAL_STATE_DIR"

PASS=0
FAIL=0

write_review_status() {
  local code_sha="$1"
  local codex_sha="$2"
  local omit_sha="${3:-no}"
  STATE_FILE="$STATE_DIR/review-status.json" CODE_SHA="$code_sha" CODEX_SHA="$codex_sha" OMIT_SHA="$omit_sha" python3 - <<'PY'
import json
import os

entry = {"code_review": True, "codex_review": True}
if os.environ["OMIT_SHA"] != "yes":
    entry["code_review_sha"] = os.environ["CODE_SHA"]
    entry["codex_review_sha"] = os.environ["CODEX_SHA"]
with open(os.environ["STATE_FILE"], "w") as f:
    json.dump({"feature/review-evidence": entry}, f)
PY
}

reset_state() {
  rm -f "$STATE_DIR/review-status.json" "$STATE_DIR/pr-review-read.json" "$GLOBAL_STATE_DIR/review-status.json" "$GLOBAL_STATE_DIR/pr-review-read.json"
  printf '{}\n' > "$STATE_DIR/review-status.json"
  printf '{}\n' > "$GLOBAL_STATE_DIR/review-status.json"
}

run_helper() {
  local helper_head="${HELPER_HEAD_SHA:-abc123}"
  HOME="$TMP_HOME" bash "$SCRIPT" \
    --branch feature/review-evidence \
    --head-sha "$helper_head" \
    --pr-number 123 \
    --project-dir "$PROJECT" \
    --global-state-dir "$GLOBAL_STATE_DIR" \
    "$@" \
    --json >"$OUT" 2>"$ERR"
}

expect_rc() {
  local desc="$1"
  local expected="$2"
  shift 2
  local rc=0
  set +e
  "$@"
  rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected $expected, got $rc)" >&2
    cat "$ERR" >&2 || true
  fi
}

assert_json() {
  local desc="$1"
  local expr="$2"
  if python3 - "$OUT" "$expr" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
if not eval(sys.argv[2], {"data": data}):
    raise SystemExit(1)
PY
  then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc" >&2
    cat "$OUT" >&2 || true
  fi
}

echo "=== review evidence status ==="

reset_state
write_review_status abc123 abc123
expect_rc "matching code_review/codex_review SHA satisfies FULL" 0 run_helper --require full
assert_json "FULL result is ok" 'data["ok"] is True and data["missing"] == []'
assert_json "both primary review kinds are current" '"code_review" in data["current"] and "codex_review" in data["current"]'

reset_state
write_review_status old999 abc123
expect_rc "old code_review SHA blocks FULL" 2 run_helper --require full
assert_json "stale code_review is reported" 'any(r["kind"] == "code_review" and r["status"] == "stale" for r in data["records"])'

reset_state
write_review_status "" "" yes
expect_rc "SHA-less review-status evidence blocks FULL" 2 run_helper --require full
assert_json "missing SHA is diagnostic only" 'all(r["status"] == "missing_sha" and r["diagnostic_only"] for r in data["records"] if r["kind"] in ("code_review", "codex_review"))'

reset_state
write_review_status abc123 abc123
HELPER_HEAD_SHA=abc123456 expect_rc "abbreviated review-status SHA blocks FULL" 2 run_helper --require full
assert_json "abbreviated review-status SHA is stale" 'any(r["source"] == "review-status" and r["status"] == "stale" for r in data["records"])'

reset_state
cat > "$TMP_ROOT/gstack.jsonl" <<'JSONL'
{"event":"code_review","result":"pass","source":"gstack"}
{"event":"codex_review","result":"pass","source":"gstack"}
JSONL
expect_rc "gstack review entries without commit/head evidence are diagnostic only" 2 run_helper --require full --gstack-jsonl "$TMP_ROOT/gstack.jsonl"
assert_json "gstack missing SHA records do not satisfy FULL" 'data["ok"] is False and all(r["status"] == "missing_sha" and r["diagnostic_only"] for r in data["records"] if r["source"] == "gstack-jsonl")'

reset_state
write_review_status "" abc123
cat > "$TMP_ROOT/gstack-current.jsonl" <<'JSONL'
{"event":"code_review","result":"pass","head_sha":"abc123"}
{"event":"codex_review","result":"pass","message":"reviewed commit abc123"}
JSONL
expect_rc "gstack code review plus current Codex review satisfies FULL" 0 run_helper --require full --gstack-jsonl "$TMP_ROOT/gstack-current.jsonl"
assert_json "gstack only hydrates code_review" 'data["ok"] is True and "code_review" in data["current"] and "codex_review" in data["current"] and not any(r["kind"] == "codex_review" and r["source"] == "gstack-jsonl" for r in data["records"])'

reset_state
printf '{"123":{"review_read":true,"head_sha":"abc123"}}\n' > "$GLOBAL_STATE_DIR/pr-review-read.json"
expect_rc "pr-review-read head_sha can satisfy read requirement" 0 run_helper --require read
assert_json "review_read is current" '"review_read" in data["current"]'

echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
