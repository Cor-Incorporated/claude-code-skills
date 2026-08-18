#!/usr/bin/env bash
# F1 truth table for H5-E2E form admission and repo-declared path scope.
set -euo pipefail
export AIDD_LEDGER_SOURCE=test

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/scripts"
cp "$ROOT/scripts/h5-admission-check.sh" "$TMP_ROOT/scripts/"
CHK="$TMP_ROOT/scripts/h5-admission-check.sh"
LEDGER="$TMP_ROOT/ledger.jsonl"

unset H5_PR_NUMBER GITHUB_EVENT_PATH

guard_fee='H5-NEGATIVE: known-bad red exit 1 measured
H5-LEDGER: aidd_ledger_append on block path
H5-RETIRE: 90 days zero fires then retire
H5-SUBTRACTION: N/A — test fixture'

marker_body() {
  case "$1" in
    none) printf '%s\n' 'H5-E2E: none' ;;
    command-output) printf '%s\n' 'H5-E2E: npm run test:contract' 'H5-E2E-OUT: logs/contract-run-success-20260818.txt' ;;
    description-only) printf '%s\n' 'H5-E2E: integration path was checked manually' ;;
    missing) printf '%s\n' 'no execution-boundary declaration' ;;
    short-output) printf '%s\n' 'H5-E2E: npm test' 'H5-E2E-OUT: too-short' ;;
  esac
}

run_check() {
  local diff_file="$1" body="$2"
  env H5_LEDGER_PATH="$LEDGER" H5_DIFF_FILES="$diff_file" H5_PR_BODY="$body" \
    bash "$CHK" >/dev/null 2>&1
}

pass=0
fail=0
assert_case() {
  local label="$1" expect="$2" diff_file="$3" body="$4"
  set +e
  run_check "$diff_file" "$body"
  rc=$?
  set -e
  if [[ "$rc" -eq "$expect" ]]; then
    printf 'PASS\t%s\texit=%s\n' "$label" "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL\t%s\texpected=%s actual=%s\n' "$label" "$expect" "$rc"
    fail=$((fail + 1))
  fi
}

# 4 marker forms x 2 path classes x .aidd-e2e-paths absent/present = 16 cells.
for config in absent present; do
  if [[ "$config" == present ]]; then
    printf '%s\n' 'services/evaluation/**' >"$TMP_ROOT/.aidd-e2e-paths"
  else
    rm -f "$TMP_ROOT/.aidd-e2e-paths"
  fi

  for path_class in structural declared-path; do
    if [[ "$path_class" == structural ]]; then
      diff_file='hooks/example.sh'
    else
      diff_file='services/evaluation/pipeline.go'
    fi

    for form in none command-output description-only missing; do
      body="$(marker_body "$form")"
      if [[ "$path_class" == structural ]]; then
        body="$guard_fee
$body"
        case "$form" in none|command-output) expect=0 ;; *) expect=1 ;; esac
      elif [[ "$config" == present ]]; then
        case "$form" in none|command-output) expect=0 ;; *) expect=1 ;; esac
      else
        expect=0
      fi
      assert_case "$form/$path_class/config-$config" "$expect" "$diff_file" "$body"
    done
  done
done

# Boundary and false-positive checks outside the 16-cell minimum.
printf '%s\n' 'services/evaluation/**' >"$TMP_ROOT/.aidd-e2e-paths"
assert_case 'output-19-chars-red' 1 'services/evaluation/pipeline.go' \
  "H5-E2E: npm test
H5-E2E-OUT: 1234567890123456789"
assert_case 'output-20-chars-green' 0 'services/evaluation/pipeline.go' \
  "H5-E2E: npm test
H5-E2E-OUT: 12345678901234567890"
assert_case 'docs-only-no-false-positive' 0 'docs/guide.md' 'ordinary documentation update'
assert_case 'declared-file-change-needs-marker' 1 '.aidd-e2e-paths' 'update declared scope'

printf 'RESULT\tpass=%s\tfail=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
