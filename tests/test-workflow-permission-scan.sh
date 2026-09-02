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
echo "=== 2.5 any_of（1 つの API 面を複数スコープのどれかが満たす）==="
# `POST /repos/{owner}/{repo}/issues/{issue_number}/comments` は GitHub の
# fine-grained 権限リファレンスで "Issues"(write) と "Pull requests"(write) の
# 両方の節に掲載されている（2026-09-02 実測）。gh pr comment はこれを使う。
# 片側だけを要求として書くと、もう片方を宣言した正しい workflow に偽 MISSING を出す。
PRCOMMENT='      - name: comment
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh pr comment 1 --body "hello"'
assert_verdict B1 "$(fixture b1 '    permissions:
      contents: read' "$PRCOMMENT")" MISSING "pr comment"
assert_verdict B2 "$(fixture b2 '    permissions:
      pull-requests: write' "$PRCOMMENT")" GRANTED "pr comment"
assert_verdict B3 "$(fixture b3 '    permissions:
      issues: write' "$PRCOMMENT")" GRANTED "pr comment"
assert_verdict B4 "$(fixture b4 '    permissions:
      pull-requests: read' "$PRCOMMENT")" MISSING "pr comment"

echo
echo "=== 2.6 シェルの行継続 ==="
# `gh api \` の次行が別トークンになると、パスとして `\` を拾う。
# 実測: opencode review.yml の複数行 gh api が `GET \` と判定されていた。
mkdir -p "$WORK/b5/.github/workflows"
cat >"$WORK/b5/.github/workflows/wf.yml" <<'YML'
name: b5
on: workflow_dispatch
jobs:
  authorize:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: review comment
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh api \
            --method POST \
            /repos/${{ github.repository }}/pulls/1/comments \
            -f 'body=x'
YML
assert_verdict B5 "$WORK/b5" MISSING "pulls/1/comments"

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
echo "=== 5. 追加した map エントリ: 未宣言で MISSING / 宣言で GRANTED（#94 ①②）==="
# 片方向だけでは不足である。「落ちること」と「正しく書けば通ること」の両方を測る。
# 落ちるだけの検査は、正しい workflow も落とせるので装置として使えない。

# --- ① id-token（OIDC クラス）---
oidc_case() { # $1=id $2=uses 行の action 名
  local id="$1" action="$2"
  local steps="      - name: auth
        uses: ${action}@v2"
  local miss granted
  miss="$(fixture "oidc-miss-$id" '    permissions:
      contents: read' "$steps")"
  assert_verdict "①-$id 未宣言" "$miss" "MISSING" "$action"
  granted="$(fixture "oidc-ok-$id" '    permissions:
      contents: read
      id-token: write' "$steps")"
  assert_verdict "①-$id 宣言済み" "$granted" "GRANTED" "$action"
}
oidc_case gcp google-github-actions/auth
oidc_case aws aws-actions/configure-aws-credentials
oidc_case azure azure/login

# action 名の大文字小文字。正本は Azure/login だが workflow では azure/login とも書く。
# 区別すると対応表にある action を綴り違いで見逃す。
assert_verdict "①-case 大文字表記でも突合する" \
  "$(fixture oidc-case '    permissions:
      contents: read' '      - name: auth
        uses: Azure/login@v2')" "MISSING" "Azure/login"

# --- ② deployments ---
DEP_POST='      - name: create deployment
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api -X POST repos/o/r/deployments -f ref=main'
DEP_GET='      - name: list deployments
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api repos/o/r/deployments'
assert_verdict "②-post 未宣言" "$(fixture dep-post-miss '    permissions:
      contents: read' "$DEP_POST")" "MISSING" "POST repos/o/r/deployments"
assert_verdict "②-post 宣言済み" "$(fixture dep-post-ok '    permissions:
      contents: read
      deployments: write' "$DEP_POST")" "GRANTED" "POST repos/o/r/deployments"
assert_verdict "②-get 未宣言" "$(fixture dep-get-miss '    permissions:
      contents: read' "$DEP_GET")" "MISSING" "GET repos/o/r/deployments"
assert_verdict "②-get 宣言済み" "$(fixture dep-get-ok '    permissions:
      contents: read
      deployments: read' "$DEP_GET")" "GRANTED" "GET repos/o/r/deployments"
# read しか要らない GET を write で宣言しても通る（level は >= で判定する）
assert_verdict "②-get write でも足りる" "$(fixture dep-get-write '    permissions:
      contents: read
      deployments: write' "$DEP_GET")" "GRANTED" "GET repos/o/r/deployments"

echo
echo "=== 6. UNDECIDABLE-API の red が actionable であること（#94 ④ の条件）==="
# 「判定できない」で終わると、読んだ人が次に何をすればよいか分からない。
UNK="$(fixture unknown-api '    permissions:
      contents: read' '      - name: unknown
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api repos/o/r/some-unmapped-surface')"
unk_out="$(python3 "$SCAN" --root "$UNK" 2>&1)"
if printf '%s' "$unk_out" | grep -q "UNDECIDABLE-API=1"; then
  ok "④ 未対応の API 面は UNDECIDABLE-API になる"
else
  bad "④ UNDECIDABLE-API にならない" "$unk_out"
fi
if printf '%s' "$unk_out" | grep -q "fix      : scripts/lib/gh-permission-map.yaml の \`rest:\` へ evidence つきで追加する"; then
  ok "④ 解決手段（どのファイルのどの節に何を書くか）が出力に出る"
else
  bad "④ fix 行が出ていない" "$unk_out"
fi
if printf '%s' "$unk_out" | grep -q "根拠を書けないなら足さない"; then
  ok "④ evidence の基準を緩めない旨も併記される"
else
  bad "④ evidence 基準の注意が無い" "$unk_out"
fi
# strict では UNDECIDABLE-API も exit 1（適用条件の維持）
python3 "$SCAN" --root "$UNK" --strict-undecidable >/dev/null 2>&1
if [[ $? -eq 1 ]]; then
  ok "④ strict では UNDECIDABLE-API も exit 1（未宣言を緑と呼ばない）"
else
  bad "④ strict なのに exit 0" "$unk_out"
fi

echo
echo "--- $PASS passed, $FAIL failed ---"
[[ $FAIL -eq 0 ]]
