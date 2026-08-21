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
# CI の shallow checkout には docs/handover が存在しない場合があるため、
# fixture は repository tree ではなく OS の一時ディレクトリへ隔離する。
H8_FIX=$(mktemp -d "${TMPDIR:-/tmp}/handover-fixtures.XXXXXX")
H8_LEDGER=$(mktemp)
H8_NAMES=(
  "一次資料"
  "要求インベントリ"
  "突合表"
  "標準質問"
  "北極星"
  "反証軸"
  "撤収"
)
H8_VALUES=(
  "- 原指示: repos/_session-zero.md（要求と受入基準の出典）"
  "1. 委任契約の空欄発射を止め、欠落欄名を台帳に記録する"
  "| 要求 | 受入基準 | 証跡 |\n|---|---|---|\n| 空欄を止める | exit 1 | 生ログ |"
  "- ユーザー像と安全境界とセキュリティ境界を実装前に明文化する"
  "- メトリクス: H8 欠落欄の台帳発火数 / 測定周期: 日次"
  "F1 の軸と真理値表を実装前に列挙し、欠落入力が red になることを測る"
  "active: 作業中の worktree は完了コミットの回収先が決まるまで保持する"
)

write_h8_fixture() {
  local path="$1" omit_indexes="$2" short_index="$3" falsification="$4" withdrawal="$5"
  local i value
  {
    printf '%s\n\n' '# Handover: H8 truth-table fixture'
    printf '%s\n' '## 委任契約（必須）'
    printf '%s\n\n' '1. 停止条件と最大反復: 既定 10 回で止めて監督へ報告する'
    for ((i = 0; i < ${#H8_NAMES[@]}; i++)); do
      case ",$omit_indexes," in
        *",$i,"*) continue ;;
      esac
      value="${H8_VALUES[$i]}"
      [[ "$i" -eq 5 ]] && value="$falsification"
      [[ "$i" -eq 6 ]] && value="$withdrawal"
      [[ "$i" -eq "$short_index" ]] && value="短文"
      printf '## %s\n%s\n\n' "${H8_NAMES[$i]}" "$value"
    done
  } >"$path"
}

H8_F1="${H8_VALUES[5]}"
H8_F2="F2 の事故入力と再現入力を実装前に固定し、既知の欠落が red になることを測る"
H8_F3="F3 の片側変異を実装前に固定し、対の一方だけを変える mutation が red になることを測る"
H8_ACTIVE="${H8_VALUES[6]}"
H8_RECOVER="recover: 検収後は成果 commit を回収用 branch へ取り込み、作業 worktree は後続検査まで保持する"
H8_PRESERVE="preserve: 完了コミットの証跡を再検査するため、専用 worktree と branch を明示的に残す"
H8_RETIRE="retire: 完了コミットが PR に回収された後、利用中でない worktree と branch を廃止候補にする"

# 修正前は通った既存 5 欄だけの契約を、修正後は拒否する。
write_h8_fixture "$H8_FIX/five-fields-only.md" "5,6" -1 "$H8_F1" "$H8_ACTIVE"
run_case "h8-five-fields-only-red" 1 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/five-fields-only.md" H5_PR_BODY="" bash "$CHK"

# 軸 1: 7 欄のうち、見出しが 1 つでも無ければ red。
for h8_i in 0 1 2 3 4 5 6; do
  write_h8_fixture "$H8_FIX/missing-$h8_i.md" "$h8_i" -1 "$H8_F1" "$H8_ACTIVE"
  run_case "h8-missing-${H8_NAMES[$h8_i]}-red" 1 \
    env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/missing-$h8_i.md" H5_PR_BODY="" bash "$CHK"
done

# 軸 2: 見出しがあっても各欄 20 文字未満は red。
for h8_i in 0 1 2 3 4 5 6; do
  write_h8_fixture "$H8_FIX/short-$h8_i.md" "" "$h8_i" "$H8_F1" "$H8_ACTIVE"
  run_case "h8-short-${H8_NAMES[$h8_i]}-red" 1 \
    env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/short-$h8_i.md" H5_PR_BODY="" bash "$CHK"
done

# 軸 3: 反証軸 F1/F2/F3 と撤収 4 値の受理。
write_h8_fixture "$H8_FIX/f1-active.md" "" -1 "$H8_F1" "$H8_ACTIVE"
run_case "h8-f1-active-green" 0 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/f1-active.md" H5_PR_BODY="" bash "$CHK"
write_h8_fixture "$H8_FIX/f2-recover.md" "" -1 "$H8_F2" "$H8_RECOVER"
run_case "h8-f2-recover-green" 0 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/f2-recover.md" H5_PR_BODY="" bash "$CHK"
write_h8_fixture "$H8_FIX/f3-preserve.md" "" -1 "$H8_F3" "$H8_PRESERVE"
run_case "h8-f3-preserve-green" 0 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/f3-preserve.md" H5_PR_BODY="" bash "$CHK"
write_h8_fixture "$H8_FIX/f1-retire.md" "" -1 "$H8_F1" "$H8_RETIRE"
run_case "h8-f1-retire-green" 0 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/f1-retire.md" H5_PR_BODY="" bash "$CHK"

# 「テスト green」のみ、および inactive の active 部分一致は拒否する。
write_h8_fixture "$H8_FIX/falsification-invalid.md" "" -1 \
  "この作業ではテスト green を確認して完了と報告する予定である" "$H8_ACTIVE"
run_case "h8-test-green-only-red" 1 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/falsification-invalid.md" H5_PR_BODY="" bash "$CHK"
write_h8_fixture "$H8_FIX/withdrawal-invalid.md" "" -1 "$H8_F1" \
  "inactive: 作業が終わったら worktree の取り扱いは後続セッションが任意に判断する"
run_case "h8-withdrawal-invalid-red" 1 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="$H8_FIX/withdrawal-invalid.md" H5_PR_BODY="" bash "$CHK"

run_case "h8-nondelegation-doc" 0 \
  env H5_LEDGER_PATH="$H8_LEDGER" H5_DIFF_FILES="README.md" H5_PR_BODY="" bash "$CHK"

if python3 - "$H8_LEDGER" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows, "no H8 rows"
assert all(row.get("component") == "H8" for row in rows), rows
assert all(row.get("source") == "test" for row in rows), rows
assert all(row.get("rule") == "inventory-field-empty" for row in rows), rows
PY
then
  echo "PASS: H8 ledger rows are isolated and source=test"
  pass=$((pass + 1))
else
  echo "FAIL: H8 ledger source/isolation"
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
