#!/usr/bin/env bash
# workflow-permission-scan の反証テスト（aidd-governance#94）
#
# workflow-permission-scan: fixtures-only
#   このファイルに現れる `gh api` / `gh pr` は、検査器へ食わせる fixture を
#   組み立てる文字列であって、実際の API 呼び出しではない。CI がこのファイルを
#   `bash tests/...` で起動するため、検査器はここまで追ってきて偽の MISSING を
#   6 件出した（実測）。シェルには literal と code の一般的な境界が無いので、
#   推測ではなく**対象ファイルの自己申告**で止める。この宣言は走査結果の
#   「追跡をやめたスクリプト」節に必ず印字されるので、黙って消えることはない。
#
# 3 種類を回す:
#   1. 陰性テスト  — 2026-08-27 の実欠陥を注入して red になることを実測する
#   2. 真理値表    — 5 値判定規則 A1..A14 を 1 行ずつ固定する（#111「検証器自身」）
#   3. 厳格 YAML   — 重複キーで exit 2（#98 同型 #1: safe_load が見逃し HTTP 422）
#
# 判定規則を 1 つ書き換えると、対応する行が両側の値を挙げて落ちる。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/scripts/workflow-permission-scan.py"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL: PyYAML が無いので検査器を走らせられない（fail-open しない）"
  echo "  remedy: python3 -m pip install pyyaml"
  exit 1
fi

ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n  %s\n' "$1" "$2"; }

# fixture <name> <permissions-yaml-block> <steps-yaml-block>
fixture() {
  local name="$1" perms="$2" steps="$3" dir="$WORK/$1"
  mkdir -p "$dir/.github/workflows"
  {
    printf 'name: %s\non: workflow_dispatch\njobs:\n  authorize:\n    runs-on: ubuntu-latest\n' "$name"
    printf '%s\n' "$perms"
    printf '    steps:\n'
    printf '%s\n' "$steps"
  } >"$dir/.github/workflows/wf.yml"
  printf '%s' "$dir"
}

# assert_verdict <id> <dir> <expected verdict> <substring that must appear>
assert_verdict() {
  local id="$1" dir="$2" want="$3" needle="$4" out got
  out="$(python3 "$SCAN" --root "$dir" 2>&1)"
  got="$(printf '%s' "$out" | awk '/^\[/{v=$1} /call     :/{if (index($0, "'"$needle"'")) {print v; exit}}' \
        | tr -d '[]')"
  if [[ "$got" == "$want" ]]; then
    ok "$id verdict=$want ($needle)"
  else
    bad "$id verdict mismatch" "expected=$want actual=${got:-<none>} needle=$needle
--- scanner output ---
$out
----------------------"
  fi
}

CHECKRUNS='      - name: verify
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api "repos/${{ github.repository }}/commits/$SHA/check-runs"'
COMMENT='      - name: comment
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api repos/o/r/issues/1/comments -f body=hi'

echo "=== 1. 陰性テスト: 2026-08-27 Grift Alpha CD の実欠陥を注入 ==="
# 復元された step は check-runs を読むのに job は contents: read だけだった。
# 実測: HTTP 403 "Resource not accessible by integration"。
DEFECT="$(fixture defect '    permissions:
      contents: read' "$CHECKRUNS")"
out="$(python3 "$SCAN" --root "$DEFECT" 2>&1)"
rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q "MISSING=1"; then
  ok "陰性: 欠陥注入で exit 1 / MISSING=1"
else
  bad "陰性: 欠陥を注入したのに red にならない" "exit=$rc
$out"
fi
# 両側の値を出すこと（runbook.md 宣言と実体の二重管理 rule B）
if printf '%s' "$out" | grep -q "required : checks: read" \
  && printf '%s' "$out" | grep -q "granted  : {contents: read}"; then
  ok "陰性: 失敗時に required と granted の両側を印字する"
else
  bad "陰性: 片側しか出ていない" "$out"
fi
# 修正版（checks: read を足す）は緑
FIXED="$(fixture fixed '    permissions:
      contents: read
      checks: read' "$CHECKRUNS")"
if python3 "$SCAN" --root "$FIXED" >/dev/null 2>&1; then
  ok "陰性の対: checks: read を足すと exit 0"
else
  bad "陰性の対: 修正版が緑にならない" "$(python3 "$SCAN" --root "$FIXED" 2>&1)"
fi

echo
echo "=== 2. 真理値表: 5 値判定規則 ==="
assert_verdict A1 "$(fixture a1 '    permissions:
      checks: read' "$CHECKRUNS")" GRANTED "check-runs"
assert_verdict A2 "$DEFECT" MISSING "check-runs"
assert_verdict A3 "$(fixture a3 '' "$CHECKRUNS")" UNDECIDABLE-PERMS "check-runs"
assert_verdict A4 "$(fixture a4 '    permissions: read-all' "$CHECKRUNS")" GRANTED "check-runs"
assert_verdict A5 "$(fixture a5 '    permissions: read-all' "$COMMENT")" MISSING "issues/1/comments"
assert_verdict A6 "$(fixture a6 '    permissions: write-all' "$COMMENT")" GRANTED "issues/1/comments"
assert_verdict A7 "$(fixture a7 '    permissions: {}' "$CHECKRUNS")" MISSING "check-runs"
assert_verdict A8 "$(fixture a8 '    permissions:
      checks: read' '      - name: verify
        env:
          GH_TOKEN: ${{ secrets.RELEASE_PAT }}
        run: gh api "repos/${{ github.repository }}/commits/$SHA/check-runs"')" \
  NOT-APPLICABLE "check-runs"
assert_verdict A9 "$(fixture a9 '    permissions:
      contents: read' '      - name: verify
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api repos/o/r/some-unmapped-endpoint')" \
  UNDECIDABLE-API "some-unmapped-endpoint"
assert_verdict A12 "$(fixture a12 '    permissions:
      issues: read' "$COMMENT")" MISSING "issues/1/comments"

# A10 / A11: job の permissions は workflow の permissions を **置換**する（併合しない）。
mkdir -p "$WORK/a10/.github/workflows"
cat >"$WORK/a10/.github/workflows/wf.yml" <<'YML'
name: a10
on: workflow_dispatch
permissions:
  checks: read
jobs:
  authorize:
    runs-on: ubuntu-latest
    steps:
      - name: verify
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api "repos/${{ github.repository }}/commits/$SHA/check-runs"
YML
assert_verdict A10 "$WORK/a10" GRANTED "check-runs"

mkdir -p "$WORK/a11/.github/workflows"
cat >"$WORK/a11/.github/workflows/wf.yml" <<'YML'
name: a11
on: workflow_dispatch
permissions:
  checks: read
jobs:
  authorize:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: verify
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api "repos/${{ github.repository }}/commits/$SHA/check-runs"
YML
assert_verdict A11 "$WORK/a11" MISSING "check-runs"

# A13 / A14: 呼び出しが `run:` の 1 段先（ローカルスクリプト）にいる場合。
# 本リポジトリの h5-admission がまさにこの形なので、追えない検査器は 0 件を返す。
for pair in "a13:checks: read:GRANTED" "a14:contents: read:MISSING"; do
  id="${pair%%:*}"; rest="${pair#*:}"; perm="${rest%:*}"; want="${rest##*:}"
  mkdir -p "$WORK/$id/.github/workflows" "$WORK/$id/scripts"
  cat >"$WORK/$id/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
gh api "repos/${GITHUB_REPOSITORY}/commits/$SHA/check-runs" --jq '.check_runs[]'
SH
  cat >"$WORK/$id/.github/workflows/wf.yml" <<YML
name: $id
on: workflow_dispatch
jobs:
  authorize:
    runs-on: ubuntu-latest
    permissions:
      $perm
    steps:
      - name: verify
        env:
          GH_TOKEN: \${{ github.token }}
        run: bash scripts/verify.sh
YML
  assert_verdict "$id" "$WORK/$id" "$want" "check-runs"
done

# A15: heredoc の**後ろ**にある本物の呼び出しが消えないこと。
# strip_shell_data は冪等でなく、2 回掛けると開始行に残った `<<'PY'` の終端を
# 見つけられずファイル末尾まで飲み込む。実測でこの形の h5-admission-check.sh:49
# `gh pr view` が消えた。検査器が何も見ずに緑を返す壊れ方なので行で固定する。
mkdir -p "$WORK/a15/.github/workflows" "$WORK/a15/scripts"
cat >"$WORK/a15/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
BODY="$(python3 - <<'PY' 2>/dev/null || true
import json
print("hello")
PY
)"
gh api "repos/${GITHUB_REPOSITORY}/commits/$SHA/check-runs"
SH
cat >"$WORK/a15/.github/workflows/wf.yml" <<'YML'
name: a15
on: workflow_dispatch
jobs:
  authorize:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: verify
        env:
          GH_TOKEN: ${{ github.token }}
        run: bash scripts/verify.sh
YML
assert_verdict A15 "$WORK/a15" MISSING "check-runs"

echo
echo "=== 3. 厳格 YAML: 重複キー（#98 同型 #1 / GitHub は HTTP 422 を返す）==="
mkdir -p "$WORK/dup/.github/workflows"
cat >"$WORK/dup/.github/workflows/wf.yml" <<'YML'
name: dup
on: workflow_dispatch
jobs:
  authorize:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    permissions:
      checks: read
    steps:
      - run: echo hi
YML
python3 -c "import yaml,sys; yaml.safe_load(open('$WORK/dup/.github/workflows/wf.yml'))" 2>/dev/null
lenient=$?
out="$(python3 "$SCAN" --root "$WORK/dup" 2>&1)"
rc=$?
if [[ $rc -eq 2 ]] && printf '%s' "$out" | grep -q "duplicate YAML key"; then
  ok "厳格 YAML: 重複キーで exit 2（yaml.safe_load 単体は exit $lenient で素通し）"
else
  bad "厳格 YAML: 重複キーを検出できていない" "exit=$rc
$out"
fi

echo
echo "=== 3.5 防御台帳（ADR-006 入場料 4）==="
# block したら guard-ledger.jsonl へ 1 行残す。残らないと「90 日発火ゼロ」を
# 測れず、退役条件（入場料 6）が判定できない。
LEDGER="$WORK/guard-ledger.jsonl"
WPS_LEDGER_PATH="$LEDGER" AIDD_LEDGER_SOURCE=test \
  python3 "$SCAN" --root "$DEFECT" >/dev/null 2>&1
if [[ -s "$LEDGER" ]] \
  && grep -q '"component":"workflow-permission-scan"' "$LEDGER" \
  && grep -q '"event":"block"' "$LEDGER" \
  && grep -q '"source":"test"' "$LEDGER"; then
  ok "台帳: block 時に guard-ledger.jsonl へ追記される ($(wc -l <"$LEDGER" | tr -d ' ') 行)"
else
  bad "台帳: block したのに台帳行が無い" "path=$LEDGER content=$(cat "$LEDGER" 2>&1)"
fi
# 緑のときは書かない（発火数を水増ししない）
LEDGER2="$WORK/guard-ledger-green.jsonl"
WPS_LEDGER_PATH="$LEDGER2" AIDD_LEDGER_SOURCE=test \
  python3 "$SCAN" --root "$FIXED" >/dev/null 2>&1
if [[ ! -s "$LEDGER2" ]]; then
  ok "台帳: 合格時は追記しない"
else
  bad "台帳: 合格なのに block 行が入った" "$(cat "$LEDGER2")"
fi

echo
echo "=== 4. 非回帰: 本リポジトリ自身の workflow ==="
if python3 "$SCAN" --root "$ROOT" >/dev/null 2>&1; then
  ok "非回帰: 自リポジトリの .github/workflows に MISSING なし"
else
  bad "非回帰: 自リポジトリで MISSING が出た" "$(python3 "$SCAN" --root "$ROOT" 2>&1)"
fi

echo
echo "--- $PASS passed, $FAIL failed ---"
[[ $FAIL -eq 0 ]]
