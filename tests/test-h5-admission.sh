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

# Guard PR with complete 3-set → pass
run_case "complete-3set" 0 \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="$(cat <<'EOF'
## H5-guard: yes
## 陰性テスト
red 実測: echo '{"command":"git push origin main"}' | hook → exit 2
## 台帳
aidd_ledger_append / guard-ledger.jsonl wiring
## 廃止条件
90日発火ゼロ or FP率50%超で退役 issue
EOF
)" bash "$CHK"

# Explicit skip
run_case "explicit-skip" 0 \
  env H5_DIFF_FILES="hooks/foo.sh" H5_PR_BODY="H5-guard: no — advisory only" bash "$CHK"

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
