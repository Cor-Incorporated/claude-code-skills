#!/usr/bin/env bash
# H5 structural-path scope — polarity is "enumerate the exclusions", not
# "enumerate the covered extensions". Ref: aidd-governance#137.
#
# 起点 (2026-09-02 実測): 旧 `_H5_STRUCT_RE='^(hooks/.+\.sh|scripts/.+\.sh|...)'`
# は拡張子を列挙する形だったため、**列挙されていない拡張子を黙って免除**した。
# aidd-governance に実在する `hooks/pre-commit` / `hooks/pre-push`（拡張子なしの
# git hook = 実物の block 権限）が guard fee の外に出ていた。
#
# 本テストは 2 本の片側変異 (F3) を持つ。どちらの側を戻しても red になる。
set -euo pipefail
export AIDD_LEDGER_SOURCE=test
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$ROOT/scripts/h5-admission-check.sh"
chmod +x "$CHK"
# 外側の CI admission job は実 PR コンテキストを export する。fixture が
# それを継承すると、空の H5_PR_BODY が実 PR 本文を読み直してしまう。
unset H5_PR_NUMBER GITHUB_EVENT_PATH
H5_TEST_LEDGER=$(mktemp)
MUTDIR=$(mktemp -d)
export H5_LEDGER_PATH="$H5_TEST_LEDGER"
trap 'rm -f "$H5_TEST_LEDGER"; rm -rf "$MUTDIR"' EXIT

pass=0
fail=0

# guard fee を要求したか。`H5-E2E: none` を与えて E2E ゲートを通すので、
# exit 1 は 3 点会費（= is_guard_pr==1）からしか来ない。
verdict() { # <script> <path> -> prints DEMAND | EXEMPT
  local script="$1" p="$2" rc
  set +e
  H5_DIFF_FILES="$p" H5_PR_BODY="H5-E2E: none" H5_REPAIR_THRESHOLD=999999 \
    bash "$script" >/dev/null 2>&1
  rc=$?
  set -e
  case "$rc" in
    0) printf 'EXEMPT' ;;
    1) printf 'DEMAND' ;;
    *) printf 'rc%s' "$rc" ;;
  esac
}

expect() { # <name> <script> <path> <DEMAND|EXEMPT>
  local name="$1" script="$2" p="$3" want="$4" got
  got="$(verdict "$script" "$p")"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $name ($p -> $got)"
    pass=$((pass + 1))
  else
    # runbook.md rule C: 期待値だけでなく観測値も出す。
    echo "FAIL: $name — path=$p expected=$want observed=$got"
    fail=$((fail + 1))
  fi
}

echo "== 構造パス判定（拡張子ではなく所在で引く）=="
# block 権限・完了判定に関与しうるものは、拡張子に関わらず会費を要求する。
expect "extensionless git hook (pre-commit)" "$CHK" "hooks/pre-commit"                   DEMAND
expect "extensionless git hook (pre-push)"   "$CHK" "hooks/pre-push"                     DEMAND
expect "python hook helper"                  "$CHK" "hooks/lib/h1-iteration-class.py"    DEMAND
expect "python script"                       "$CHK" "scripts/turn-carryover-scan.py"     DEMAND
expect "yaml consumed by a script"           "$CHK" "scripts/lib/gh-permission-map.yaml" DEMAND
expect "shell hook (unchanged behaviour)"    "$CHK" "hooks/protect-branches.sh"          DEMAND
expect "shell script (unchanged behaviour)"  "$CHK" "scripts/h5-admission-check.sh"      DEMAND
expect "settings.json (unchanged behaviour)" "$CHK" "settings.json"                      DEMAND
expect "workflow (unchanged behaviour)"      "$CHK" ".github/workflows/ci.yml"           DEMAND

echo "== 文書は除外する（D1 の過検出を再現しない）=="
expect "scripts/README.md is documentation"  "$CHK" "scripts/README.md"                  EXEMPT
expect "hooks/README.md is documentation"    "$CHK" "hooks/README.md"                    EXEMPT
expect "docs/ untouched"                     "$CHK" "docs/foo.md"                        EXEMPT
expect "hooks-adjacent dir is not hooks/"    "$CHK" "hooks-old/legacy.sh"                EXEMPT

echo "== F3 片側変異: 変異させると red になることを実測する =="
# 変異体は必ずコピー上で作る。正本は書き換えない。
mut() { # <name> <sed-expr> -> path to mutated script
  mkdir -p "$MUTDIR/$1/scripts"
  sed "$2" "$CHK" >"$MUTDIR/$1/scripts/h5-admission-check.sh"
  printf '%s' "$MUTDIR/$1/scripts/h5-admission-check.sh"
}

# 変異 1: 文書除外を無効化する → scripts/README.md が block へ戻るはず。
M1="$(mut nodoc "s#^_H5_STRUCT_DOC_RE=.*#_H5_STRUCT_DOC_RE='\$^'#")"
got="$(verdict "$M1" "scripts/README.md")"
if [[ "$got" == "DEMAND" ]]; then
  echo "PASS: mutation(文書除外を削除) turns scripts/README.md into DEMAND"
  pass=$((pass + 1))
else
  echo "FAIL: mutation(文書除外を削除) expected=DEMAND observed=$got — 除外条件が判定に効いていない"
  fail=$((fail + 1))
fi

# 変異 2: 極性を旧形（拡張子列挙）へ戻す → hooks/pre-commit が allow へ戻るはず。
M2="$(mut oldpolarity "s#^_H5_STRUCT_RE=.*#_H5_STRUCT_RE='^(hooks/.+\\\\.sh|scripts/.+\\\\.sh|settings\\\\.json|\\\\.github/workflows/)'#")"
got="$(verdict "$M2" "hooks/pre-commit")"
if [[ "$got" == "EXEMPT" ]]; then
  echo "PASS: mutation(旧極性へ戻す) turns hooks/pre-commit into EXEMPT (= the bug this test pins)"
  pass=$((pass + 1))
else
  echo "FAIL: mutation(旧極性へ戻す) expected=EXEMPT observed=$got — 変異が効いていない（テストが無効）"
  fail=$((fail + 1))
fi

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
