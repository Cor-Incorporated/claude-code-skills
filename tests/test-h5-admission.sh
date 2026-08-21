#!/usr/bin/env bash
# Unit falsification for H5 admission script (no network)
set -euo pipefail
export AIDD_LEDGER_SOURCE=test  # T9-2: ledger rows from test harness are source=test
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$ROOT/scripts/h5-admission-check.sh"
chmod +x "$CHK"
# The outer CI admission job exports the real PR context. Unit fixtures must
# not inherit it, or an empty H5_PR_BODY silently reloads the live PR body and
# turns non-guard H8/README cases into guard cases.
unset H5_PR_NUMBER GITHUB_EVENT_PATH
H5_TEST_LEDGER=$(mktemp)
export H5_LEDGER_PATH="$H5_TEST_LEDGER"
trap 'rm -f "$H5_TEST_LEDGER"' EXIT

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

run_case_stderr_contains() {
  local name="$1" expect="$2" needle="$3"
  shift 3
  set +e
  "$@" >/tmp/h5-out.txt 2>/tmp/h5-err.txt
  code=$?
  set -e
  if [[ "$code" -eq "$expect" ]] && grep -qF "$needle" /tmp/h5-err.txt; then
    echo "PASS: $name (exit $code; diagnostic present)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name expected exit $expect and diagnostic: $needle"
    cat /tmp/h5-err.txt || true
    fail=$((fail + 1))
  fi
}

# Non-guard PR → pass
run_case "non-guard" 0 \
  env H5_DIFF_FILES="README.md" H5_PR_BODY="docs only" bash "$CHK"

# Guard PR missing all three → fail
run_case "missing-3set" 1 \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="add guard
H5-E2E: none" bash "$CHK"

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
H5-E2E: none
EOF
)" bash "$CHK"

# Explicit markers form
run_case "marker-3set" 0 \
  env H5_DIFF_FILES="hooks/x.sh" H5_PR_BODY="H5-NEGATIVE: unit red exit 1 measured
H5-LEDGER: aidd_ledger_append on block
H5-RETIRE: 90 days zero fires -> retire
H5-SUBTRACTION: N/A — test fixture
H5-E2E: none" bash "$CHK"

# Mention keywords while saying missing → still fail
run_case "negation-not-evidence" 1 \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="H5-guard: yes. Intentionally missing 陰性テスト red log, 台帳 wiring, 廃止条件. Do not merge. Expect red.
H5-E2E: none" bash "$CHK"

# H5-skip must NOT self-exempt a hook change
run_case "h5-skip-no-longer-works" 1 \
  env H5_DIFF_FILES="hooks/foo.sh" H5_PR_BODY="H5-skip please ignore
H5-E2E: none" bash "$CHK"

# scripts/** is now in scope
run_case "scripts-in-scope" 1 \
  env H5_DIFF_FILES="scripts/evil.sh" H5_PR_BODY="add script guard
H5-E2E: none" bash "$CHK"

# hooks/lib/** is now in scope
run_case "hooks-lib-in-scope" 1 \
  env H5_DIFF_FILES="hooks/lib/aidd-ledger.sh" H5_PR_BODY="touch ledger lib
H5-E2E: none" bash "$CHK"

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
H5-E2E: none
EOF
)" bash "$CHK"

# A missing subtraction declaration must name both accepted recovery forms.
run_case_stderr_contains "missing-subtraction-diagnostic" 1 \
  "H5-SUBTRACTION: N/A OR H5-RETIRE-PR: <merged PR number>" \
  env H5_DIFF_FILES="hooks/git-push-guard.sh" H5_PR_BODY="H5-guard: yes
H5-E2E: none
H5-NEGATIVE: unit red exit 1 measured
H5-LEDGER: aidd_ledger_append on every fire
H5-RETIRE: 90 days zero fires then retire" bash "$CHK"

# R1: H5-guard: no MUST NOT exempt structural paths (symmetric with triggers)
run_case "no-exempt-workflow" 1 \
  env H5_DIFF_FILES=".github/workflows/h5-admission.yml" H5_PR_BODY="H5-guard: no
H5-E2E: none" bash "$CHK"

run_case "no-exempt-script" 1 \
  env H5_DIFF_FILES="scripts/h5-admission-check.sh" H5_PR_BODY="H5-guard: no
H5-E2E: none" bash "$CHK"

run_case "no-exempt-hooks-subdir" 1 \
  env H5_DIFF_FILES="hooks/sub/x.sh" H5_PR_BODY="H5-guard: no
H5-E2E: none" bash "$CHK"

run_case "no-exempt-ci-workflow" 1 \
  env H5_DIFF_FILES=".github/workflows/ci.yml" H5_PR_BODY="H5-guard: no — docs only workflow rename
H5-E2E: none" bash "$CHK"

# Non-structural path + H5-guard: no still passes (not a guard PR)
run_case "advisory-no-on-readme" 0 \
  env H5_DIFF_FILES="README.md" H5_PR_BODY="H5-guard: no" bash "$CHK"

# --- H8 requirement inventory gate (T7-1) ---
H8_FIX="$ROOT/docs/handover/.h8-fixtures"
mkdir -p "$H8_FIX"
cat > "$H8_FIX/2026-08-12-empty.md" <<'EOF'
# Handover: fixture empty

## 委任契約（必須）
1. 停止条件: 既定 10

## 一次資料
## 要求インベントリ
## 突合表
## 標準質問
## 北極星
EOF
cat > "$H8_FIX/2026-08-12-full.md" <<'EOF'
# Handover: fixture full

## 委任契約（必須）
1. 停止条件: 既定 10

## 一次資料
- 原指示: repos/_session-zero.md（要求の出典）

## 要求インベントリ
1. 委任契約に要求インベントリ欄が空のまま発射しようとしたら止まる
2. 台帳に inventory-field-empty が 1 行以上記録される

## 突合表
| # | 要求 | 受入基準 |
|---|---|---|
| 1 | 空欄で止まる | red 実測 |

## 標準質問
- ユーザー像: 監督エージェントと実装エージェント
- 安全境界: 台帳以外に書き込まない

## 北極星
- メトリクス: H8 台帳発火数 / 測定周期: 日次
EOF

H8_LEDGER=$(mktemp)
run_case "h8-empty-red" 1 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/2026-08-12-empty.md" H5_PR_BODY="" bash "$CHK"
run_case "h8-full-green" 0 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/2026-08-12-full.md" H5_PR_BODY="" bash "$CHK"
run_case "h8-nondelegation-doc" 0 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="README.md" H5_PR_BODY="" bash "$CHK"

if grep -q '"rule":"inventory-field-empty"' "$H8_LEDGER"; then
  echo "PASS: h8 ledger row present (inventory-field-empty)"
  pass=$((pass + 1))
else
  echo "FAIL: h8 ledger row missing (inventory-field-empty)"
  fail=$((fail + 1))
fi

if python3 - "$H5_TEST_LEDGER" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows, "no H5 rows"
assert any(row.get("component") == "H5" for row in rows), rows
assert all(row.get("source") == "test" for row in rows), rows
PY
then
  echo "PASS: H5 test rows are isolated and source=test"
  pass=$((pass + 1))
else
  echo "FAIL: H5 test ledger source/isolation"
  fail=$((fail + 1))
fi
rm -rf "$H8_FIX" "$H8_LEDGER"

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
