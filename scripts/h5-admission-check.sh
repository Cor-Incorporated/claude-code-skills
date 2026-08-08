#!/usr/bin/env bash
# H5 — Admission fee for block-capable guards / completion verifiers (required check).
# Spec: aidd-governance design/harness-spec.md H5, design/ops/harness/h5-negative-test-gate.md
#
# Exit 0: not a guard PR, or 3-point set present
# Exit 1: guard PR missing negative-test evidence / ledger wiring / retirement condition
# Exit 0 with warn: fail-open structural smell (does not block)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE_REF="${H5_BASE_REF:-origin/develop}"
HEAD_REF="${H5_HEAD_REF:-HEAD}"
PR_BODY="${H5_PR_BODY:-}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
LEDGER_PATH="${H5_LEDGER_PATH:-$HOME/.claude/hooks/ledger/guard-ledger.jsonl}"

log() { printf '%s\n' "$*"; }
warn() { printf 'H5-WARN: %s\n' "$*" >&2; }
fail() { printf 'H5-FAIL: %s\n' "$*" >&2; }

# --- Collect PR body (CI or local override) ---
if [[ -z "$PR_BODY" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
  PR_BODY="$(python3 - <<'PY' 2>/dev/null || true
import json, os
path = os.environ["GITHUB_EVENT_PATH"]
with open(path) as f:
    ev = json.load(f)
body = (ev.get("pull_request") or {}).get("body") or ""
print(body)
PY
)"
fi
if [[ -z "$PR_BODY" && -n "${H5_PR_NUMBER:-}" ]]; then
  PR_BODY="$(gh pr view "$H5_PR_NUMBER" --json body -q .body 2>/dev/null || true)"
fi

# --- Diff paths ---
if [[ -n "${H5_DIFF_FILES:-}" ]]; then
  # newline or space separated override (tests)
  DIFF_FILES="$(printf '%s\n' $H5_DIFF_FILES)"
else
  git fetch --no-tags --depth=1 origin "$(echo "$BASE_REF" | sed 's#^origin/##')" 2>/dev/null || true
  if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    DIFF_FILES="$(git diff --name-only "$BASE_REF"...$HEAD_REF 2>/dev/null || git diff --name-only "$BASE_REF" $HEAD_REF 2>/dev/null || true)"
  else
    DIFF_FILES="$(git diff --name-only HEAD~1...HEAD 2>/dev/null || true)"
  fi
fi

is_guard_pr=0
# Structural triggers: hooks scripts, settings hooks surface, workflows (CI gates)
if printf '%s\n' "$DIFF_FILES" | grep -qE '^(hooks/[^/]+\.sh|settings\.json|\.github/workflows/)'; then
  is_guard_pr=1
fi
# Self-declaration (PR template)
if printf '%s' "$PR_BODY" | grep -qiE 'H5-guard:\s*yes|ブロック権限|完了判定検証器|block-capable guard'; then
  is_guard_pr=1
fi
# Explicit opt-out for pure docs/advisory
if printf '%s' "$PR_BODY" | grep -qiE 'H5-guard:\s*no|H5:\s*not-applicable|H5-skip'; then
  is_guard_pr=0
fi

if [[ "$is_guard_pr" -eq 0 ]]; then
  log "H5-PASS: not a guard/verifier PR (no structural trigger / declared N/A)"
  exit 0
fi

log "H5: guard/verifier PR detected — checking 3-point admission fee"

body_lc="$(printf '%s' "$PR_BODY" | tr '[:upper:]' '[:lower:]')"
missing=()

# (1) Negative test evidence (known-bad → red measured)
if ! printf '%s' "$PR_BODY" | grep -qiE '陰性テスト|negative[[:space:]-]?test|red 実測|known-bad|inject.*red|fail.*実測|FT-11'; then
  missing+=("negative-test-evidence")
fi

# (2) H6 ledger wiring — in PR body or in changed hook sources
has_ledger_body=0
printf '%s' "$PR_BODY" | grep -qiE '台帳|guard-ledger|aidd_ledger|H6|ledger wiring|防御台帳' && has_ledger_body=1
has_ledger_code=0
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  if grep -qE 'aidd_ledger_append|guard-ledger\.jsonl|aidd-ledger' "$f" 2>/dev/null; then
    has_ledger_code=1
    break
  fi
done <<<"$(printf '%s\n' "$DIFF_FILES" | grep -E '^hooks/|^scripts/h5' || true)"
# Workflow-only admission gate may declare ledger at CI layer in body
if [[ "$has_ledger_body" -eq 0 && "$has_ledger_code" -eq 0 ]]; then
  # Allow if this PR only adds the H5 gate itself and documents ledger requirement
  if printf '%s\n' "$DIFF_FILES" | grep -q 'h5-admission' && printf '%s' "$PR_BODY" | grep -qiE '台帳|ledger'; then
    has_ledger_body=1
  fi
fi
if [[ "$has_ledger_body" -eq 0 && "$has_ledger_code" -eq 0 ]]; then
  missing+=("ledger-wiring")
fi

# (3) Retirement condition declared
if ! printf '%s' "$PR_BODY" | grep -qiE '廃止条件|retirement|90[[:space:]]*日|発火ゼロ|false.?positive|FP.?率|退役'; then
  missing+=("retirement-condition")
fi

# Fail-open structural smell (warn only) on changed shell hooks
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  [[ "$f" != hooks/* ]] && continue
  # crude: catch "|| true" / "|| :" after critical decision paths + "exit 0" in error handlers
  if grep -nE '\|\|\s*(true|:)\s*$' "$f" | grep -qiE 'jq|curl|gh |git ' ; then
    warn "possible fail-open (command || true) in $f — review manually"
  fi
done <<<"$(printf '%s\n' "$DIFF_FILES")"

if ((${#missing[@]} > 0)); then
  fail "admission fee incomplete: ${missing[*]}"
  fail "Required: (1) 陰性テスト red 実測記録 (2) H6 台帳配線 (3) 廃止条件宣言 — in PR body and/or code"
  fail "See design/ops/harness/h5-negative-test-gate.md"
  # Optional local ledger (does not affect CI if path missing)
  if [[ -n "$LEDGER_PATH" ]]; then
    mkdir -p "$(dirname "$LEDGER_PATH")" 2>/dev/null || true
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf '{"ts":"%s","component":"H5","event":"block","rule":"negative-test-missing","detail":"%s","agent":"ci"}\n' \
      "$ts" "${missing[*]}" >>"$LEDGER_PATH" 2>/dev/null || true
  fi
  exit 1
fi

log "H5-PASS: 3-point admission fee present (negative-test + ledger + retirement)"
exit 0
