#!/usr/bin/env bash
# Unit falsification for H5 admission script (no network)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$ROOT/scripts/h5-admission-check.sh"
chmod +x "$CHK"

pass=0
fail=0
run_case() {
  local name="$1" expect="$2"
  shift 2
  set +e
  "$@" >/tmp/h5-out.txt 2>/tmp/h5-err.txt
  code=$?
  set -e
  if [[ "$code" -eq "$expect" ]]; then
    echo "PASS: $name (exit $code)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name expected $expect got $code"
    cat /tmp/h5-err.txt || true
    fail=$((fail + 1))
  fi
}

# Non-guard PR → pass
run_case "non-guard" 0 \
  env H5_DIFF_FILES="README.md" H5_PR_BODY="docs only" bash "$CHK"

# Guard PR missing all three → fail
run_case "missing-3set" 1 \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="add guard" bash "$CHK"

# Guard PR with complete 3-set + subtraction → pass
run_case "complete-3set" 0 \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="$(cat <<'EOF'
## H5-guard: yes
## 陰性テスト
red 実測: echo '{"command":"git push origin main"}' | hook → exit 2
## 台帳
aidd_ledger_append / guard-ledger.jsonl wiring present in hook
## 廃止条件
90日発火ゼロ or FP率50%超で退役 issue
H5-SUBTRACTION: N/A — net +0 (wiring only)
EOF
)" bash "$CHK"

# Explicit markers form
run_case "marker-3set" 0 \
  env H5_DIFF_FILES="hooks/x.sh" H5_PR_BODY="H5-NEGATIVE: unit red exit 1 measured
H5-LEDGER: aidd_ledger_append on block
H5-RETIRE: 90 days zero fires -> retire
H5-SUBTRACTION: N/A — test fixture" bash "$CHK"

# Mention keywords while saying missing → still fail
run_case "negation-not-evidence" 1 \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="H5-guard: yes. Intentionally missing 陰性テスト red log, 台帳 wiring, 廃止条件. Do not merge. Expect red." bash "$CHK"

# H5-skip must NOT self-exempt a hook change
run_case "h5-skip-no-longer-works" 1 \
  env H5_DIFF_FILES="hooks/foo.sh" H5_PR_BODY="H5-skip please ignore" bash "$CHK"

# scripts/** is now in scope
run_case "scripts-in-scope" 1 \
  env H5_DIFF_FILES="scripts/evil.sh" H5_PR_BODY="add script guard" bash "$CHK"

# hooks/lib/** is now in scope
run_case "hooks-lib-in-scope" 1 \
  env H5_DIFF_FILES="hooks/lib/aidd-ledger.sh" H5_PR_BODY="touch ledger lib" bash "$CHK"

# Complete set must include subtraction N/A or merged retire PR
run_case "complete-with-subtraction" 0 \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="$(cat <<'EOF'
## H5-guard: yes
## 陰性テスト
red 実測: unit missing-3set exit 1
## 台帳
aidd_ledger_append present
## 廃止条件
90日発火ゼロで退役
H5-SUBTRACTION: N/A — tightens existing hard block only, net +0 guards
EOF
)" bash "$CHK"

# H5-guard: no alone without hook sh change can pass (workflow-only docs)
run_case "advisory-no-on-workflow" 0 \
  env H5_DIFF_FILES=".github/workflows/ci.yml" H5_PR_BODY="H5-guard: no — docs only workflow rename" bash "$CHK"

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]