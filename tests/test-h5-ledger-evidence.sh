#!/usr/bin/env bash
# H5 の台帳の証拠とマーカーの長さの反証（network なし）。
#
# 起点: Cor-Incorporated/corsweb2024 #371・#375（2026-10-01）。vendor 先の写しで見つかって直した穴を、
# 正本へ移した。直す前の本体では、次の形がすべて通っていた。
#   - 本文に guard-ledger.jsonl・aidd_ledger_append と書くだけで台帳の証拠になる（「配線は無い」という否定の文でも）
#   - h5-admission を触る PR は、本文に「台帳」「ledger」と書くだけで通る
#   - コードの証拠は、ファイルにその文字があるだけ（コメントでも、この検査のスクリプト自身でも）で通る
#   - マーカーは grep の `\S.{8,}`（9 文字以上。C ロケールではバイト数）で、中身の無い宣言が通る
#   - 「## Negative test」の節は、節の名前の POSIX の [[:space:]] を Python が入れ子の集合と読むので数えられない
#
# 後半は、このテストが自分で変異体（直す前の形に戻した本体）を書き出し、同じ実行の中で動かして、
# その変異体では通ってしまうことを確かめる（照合が空振りしていないことの反証）。
set -euo pipefail
export AIDD_LEDGER_SOURCE=test
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$ROOT/scripts/h5-admission-check.sh"
# 外側の CI の PR の文脈を引き継がない（空の H5_PR_BODY が本物の PR 本文を読み直さないように）
unset H5_PR_NUMBER GITHUB_EVENT_PATH
WORK="$(mktemp -d "${TMPDIR:-/tmp}/h5-ledger-evidence.XXXXXX")"
export H5_LEDGER_PATH="$WORK/ledger.jsonl"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
# check <名前> <期待する exit> <出力に含まれるべき文字列（空なら見ない）> <コマンド...>
check() {
  local name="$1" expect="$2" needle="$3" code
  shift 3
  set +e
  "$@" >"$WORK/out.txt" 2>"$WORK/err.txt"
  code=$?
  set -e
  if [[ "$code" -eq "$expect" ]] && { [[ -z "$needle" ]] || grep -qF -- "$needle" "$WORK/out.txt" "$WORK/err.txt"; }; then
    echo "PASS: $name (exit $code)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name: expected exit $expect${needle:+ and \"$needle\"}, got $code"
    cat "$WORK/out.txt" "$WORK/err.txt"
    fail=$((fail + 1))
  fi
}

NEGATIVE='H5-NEGATIVE: the known-bad input was red before the fix (exit 1) and green after'
LEDGER='H5-LEDGER: 発火の記録は GitHub Actions の実行履歴と PR のコメントに残る'
RETIRE='H5-RETIRE: the workflow is retired, or 90 days pass without a single fire'
SUBTRACTION='H5-SUBTRACTION: N/A'
E2E='H5-E2E: none'
WORKFLOW='.github/workflows/example.yml'
# 日本語でちょうど n 文字の中身
ja() { python3 -c 'import sys; print("あいうえおかきくけこさしすせそたちつてとなにぬねの"[:int(sys.argv[1])])' "$1"; }
# ガードの PR の本文（NEGATIVE・RETIRE・SUBTRACTION・E2E はそろえ、残りを引数で足す）
body() { printf '%s\n' "$NEGATIVE" "$RETIRE" "$SUBTRACTION" "$E2E" "$@"; }
# run <本体> <差分のファイル> <本文>
run() { env H5_DIFF_FILES="$2" H5_PR_BODY="$3" bash "$1"; }
# 本体のコピーを置いた、リポジトリの形の一時ディレクトリ（本体の ROOT はコピーの親。そこのファイルをコードの証拠として読む）
fake_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts" "$dir/hooks"
  cp "${2:-$CHK}" "$dir/scripts/h5-admission-check.sh"
  printf '%s' "$dir"
}

echo "=== 台帳の証拠: 本文で触れるだけでは数えない ==="
check "否定の文で guard-ledger.jsonl に触れるだけ" 1 "ledger-wiring" \
  run "$CHK" "$WORKFLOW" "$(body 'この PR は guard-ledger.jsonl への配線は無い')"
check "aidd_ledger_append に触れるだけ" 1 "ledger-wiring" \
  run "$CHK" "$WORKFLOW" "$(body 'aidd_ledger_append は使っていない')"
check "h5-admission を触る PR でも、本文に ledger と書くだけ" 1 "ledger-wiring" \
  run "$CHK" ".github/workflows/h5-admission.yml" "$(body 'ledger の話をしているだけの行')"
check "台帳の節の中身が 19 文字" 1 "ledger-wiring" \
  run "$CHK" "$WORKFLOW" "$(body '## 台帳' "$(ja 19)")"
check "H5-LEDGER: の行（20 文字以上）で通る" 0 "" \
  run "$CHK" "$WORKFLOW" "$(body "$LEDGER")"
check "台帳の節（20 文字以上）で通る" 0 "" \
  run "$CHK" "$WORKFLOW" "$(body '## 台帳' '発火すると hooks/ledger/guard-ledger.jsonl に 1 行追記する（aidd_ledger_append）')"

echo "=== 台帳の証拠: コードは本当に書き込むときだけ ==="
repo="$(fake_repo comment-only)"
printf '%s\n' '#!/usr/bin/env bash' \
  '# この hook は guard-ledger.jsonl への配線は無い（aidd_ledger_append も使わない）' \
  '# check && aidd_ledger_append "g" "block"' 'echo ok' >"$repo/hooks/comment-only.sh"
check "コメントにしか書いていないフック" 1 "ledger-wiring" \
  run "$repo/scripts/h5-admission-check.sh" "hooks/comment-only.sh" "$(body)"
repo="$(fake_repo real-call)"
printf '%s\n' '#!/usr/bin/env bash' 'aidd_ledger_append "guard" "block"' >"$repo/hooks/real-call.sh"
check "aidd_ledger_append をコマンドとして呼ぶフックは通る" 0 "" \
  run "$repo/scripts/h5-admission-check.sh" "hooks/real-call.sh" "$(body)"
# このリポジトリのフックの多くは aidd_ledger_append_record で書き、hooks/lib/aidd-ledger.sh は "$ledger" へ >> で書く
repo="$(fake_repo record-call)"
printf '%s\n' '#!/usr/bin/env bash' '[ -n "$row" ] && aidd_ledger_append_record "$row" "claude-code" >/dev/null 2>&1 || true' >"$repo/hooks/record-call.sh"
check "aidd_ledger_append_record をコマンドとして呼ぶフックは通る" 0 "" \
  run "$repo/scripts/h5-admission-check.sh" "hooks/record-call.sh" "$(body)"
repo="$(fake_repo lower-ledger)"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$row" >>"$ledger" 2>/dev/null || true' >"$repo/hooks/lower-ledger.sh"
check "名前に ledger を含む小文字の変数への >> 追記も数える" 0 "" \
  run "$repo/scripts/h5-admission-check.sh" "hooks/lower-ledger.sh" "$(body)"
repo="$(fake_repo big-hook)"
{
  printf '%s\n' '#!/usr/bin/env bash' 'aidd_ledger_append "guard" "block"'
  for _ in $(seq 1 6000); do printf '%s\n' 'echo filler-line-to-make-the-file-larger'; done
} >"$repo/hooks/big.sh"
# grep -q がパイプを先に閉じると、前の grep が SIGPIPE で落ちて、先頭の呼び出しを数え損ねる（約 60 KiB 以上で再現）
check "大きなフック（約 230 KB）でも、2 行目の本当の呼び出しを数える" 0 "" \
  run "$repo/scripts/h5-admission-check.sh" "hooks/big.sh" "$(body)"
repo="$(fake_repo self)"
check "検査の本体自身は、台帳へ >> 追記する行があるので通る" 0 "" \
  run "$repo/scripts/h5-admission-check.sh" "scripts/h5-admission-check.sh" "$(body)"
python3 - "$CHK" "$WORK/no-write.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
assert src.count('>>"$LEDGER_PATH"') >= 1, "anchor"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace('>>"$LEDGER_PATH"', '>/dev/null'))
PY
repo="$(fake_repo no-write "$WORK/no-write.sh")"
check "台帳への >> 追記を消した本体は通らない（自分の名前やコメントでは数えない）" 1 "ledger-wiring" \
  run "$repo/scripts/h5-admission-check.sh" "scripts/h5-admission-check.sh" "$(body)"

echo "=== マーカーの長さ: 同じ行に 20 文字以上（文字数で数える） ==="
check "H5-LEDGER: の中身が日本語で 19 文字" 1 "ledger-wiring" \
  run "$CHK" "$WORKFLOW" "$(body "H5-LEDGER: $(ja 19)")"
check "H5-LEDGER: の中身が日本語で 20 文字" 0 "" \
  run "$CHK" "$WORKFLOW" "$(body "H5-LEDGER: $(ja 20)")"
check "H5-RETIRE: の中身が日本語で 19 文字" 1 "retirement-condition" \
  run "$CHK" "$WORKFLOW" "$(printf '%s\n' "$NEGATIVE" "$LEDGER" "H5-RETIRE: $(ja 19)" "$SUBTRACTION" "$E2E")"
check "H5-NEGATIVE: の中身が日本語で 19 文字" 1 "negative-test-evidence" \
  run "$CHK" "$WORKFLOW" "$(printf '%s\n' "H5-NEGATIVE: $(ja 19)" "$LEDGER" "$RETIRE" "$SUBTRACTION" "$E2E")"
check "C ロケールでも、バイトではなく文字で数える（19 文字は通らない）" 1 "retirement-condition" \
  env LC_ALL=C H5_DIFF_FILES="$WORKFLOW" \
  H5_PR_BODY="$(printf '%s\n' "$NEGATIVE" "$LEDGER" "H5-RETIRE: $(ja 19)" "$SUBTRACTION" "$E2E")" bash "$CHK"
check "中身が次の行にあるマーカーは数えない" 1 "retirement-condition" \
  run "$CHK" "$WORKFLOW" "$(printf '%s\n' "$NEGATIVE" "$LEDGER" "H5-RETIRE:" "$(ja 25)" "$SUBTRACTION" "$E2E")"
check "コロンのあとの全角の空白は許す" 0 "" \
  run "$CHK" "$WORKFLOW" "$(printf '%s\n' "$NEGATIVE" "$LEDGER" "H5-RETIRE:　$(ja 20)" "$SUBTRACTION" "$E2E")"
check "<...> のままのプレースホルダーは数えない" 1 "retirement-condition" \
  run "$CHK" "$WORKFLOW" "$(printf '%s\n' "$NEGATIVE" "$LEDGER" 'H5-RETIRE: <ここに 20 文字以上の撤収の条件を書く（プレースホルダー）>' "$SUBTRACTION" "$E2E")"

echo "=== 節の名前と、失敗のメッセージ ==="
NEG_SECTION="$(printf '%s\n' '## Negative test' '直す前の入力では赤になり、直したあとは緑になることを、手元で 3 回くり返して確かめた' "$LEDGER" "$RETIRE" "$SUBTRACTION" "$E2E")"
check "陰性テストの節（## Negative test）で通る" 0 "" run "$CHK" "$WORKFLOW" "$NEG_SECTION"
check "失敗したら、見つかったマーカーの長さ（観測値）を出す" 1 "H5-RETIRE: longest 18 chars (each needs >= 20 chars on the same line)" \
  run "$CHK" "$WORKFLOW" "$(printf '%s\n' "$NEGATIVE" "$LEDGER" "H5-RETIRE: $(ja 18)" "$SUBTRACTION" "$E2E")"
check "数えない語の一覧は _H5_META_RE から作る" 1 "the words intentionally missing / expect red / do not merge" \
  run "$CHK" "$WORKFLOW" "$(body)"
check "構造パスを触らない PR は対象外（変えていない判定）" 0 "not a guard/verifier PR" \
  run "$CHK" "README.md" "ふつうの PR"

echo "=== 自分で書き出した変異体（直す前の形）では、上の穴が通ってしまう ==="
# mutant <名前> <置き換える前> <置き換えた後>: 本体のコピーを 1 か所だけ書き換える。
# 置き換える場所がちょうど 1 つでなければ、このテスト自体を落とす（本体が変わって空振りしないように）。
# mutant は $(...) の中で動くので、失敗の数は呼び出し側の else で数える。
mutant() {
  local out="$WORK/mutant-$1.sh"
  if python3 - "$CHK" "$out" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[3], sys.argv[4]
if src.count(old) != 1:
    sys.exit(f"anchor found {src.count(old)} times: {old!r}")
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  then
    printf '%s' "$out"
  else
    echo "FAIL: mutant $1: 置き換える場所が見つからない（本体が変わった。変異体を直すこと）" >&2
    return 1
  fi
}
bypass_line="printf '%s' \"\$PR_BODY_EVIDENCE\" | grep -qiE 'aidd_ledger_append|guard-ledger\\.jsonl' && has_ledger_body=1"
if m="$(mutant body-mention "has_section_content '台帳|ledger|防御台帳' && has_ledger_body=1" \
  "has_section_content '台帳|ledger|防御台帳' && has_ledger_body=1
$bypass_line")"; then
  check "変異体: 本文で触れるだけで数える形に戻すと、否定の文が通る" 0 "" \
    run "$m" "$WORKFLOW" "$(body 'この PR は guard-ledger.jsonl への配線は無い')"
else
  fail=$((fail + 1))
fi
if m="$(mutant marker-min "H5_MARKER_MIN=20" "H5_MARKER_MIN=9")"; then
  check "変異体: 最低を 9 文字に戻すと、19 文字の H5-RETIRE: が通る" 0 "" \
    run "$m" "$WORKFLOW" "$(printf '%s\n' "$NEGATIVE" "$LEDGER" "H5-RETIRE: $(ja 19)" "$SUBTRACTION" "$E2E")"
else
  fail=$((fail + 1))
fi
if m="$(mutant comment-lines "grep -vE '^[[:space:]]*#' \"\$f\" 2>/dev/null" "cat \"\$f\" 2>/dev/null")"; then
  repo="$(fake_repo mutant-comment "$m")"
  cp "$WORK/comment-only/hooks/comment-only.sh" "$repo/hooks/comment-only.sh"
  check "変異体: コメントの行も読むと、コメントの中の呼び出しが通る" 0 "" \
    run "$repo/scripts/h5-admission-check.sh" "hooks/comment-only.sh" "$(body)"
else
  fail=$((fail + 1))
fi
if m="$(mutant section-title "'陰性テスト|negative[\\s-]?test'" "'陰性テスト|negative[[:space:]-]?test'")"; then
  check "変異体: 節の名前を POSIX の形に戻すと、## Negative test が数えられない" 1 "negative-test-evidence" \
    run "$m" "$WORKFLOW" "$NEG_SECTION"
else
  fail=$((fail + 1))
fi

if m="$(mutant record-name "aidd_ledger_append(_record)?[[:space:]]" "aidd_ledger_append[[:space:]]")"; then
  repo="$(fake_repo mutant-record "$m")"
  cp "$WORK/record-call/hooks/record-call.sh" "$repo/hooks/record-call.sh"
  check "変異体: aidd_ledger_append_record を数えない形に戻すと、本当の書き込みを見落とす" 1 "ledger-wiring" \
    run "$repo/scripts/h5-admission-check.sh" "hooks/record-call.sh" "$(body)"
else
  fail=$((fail + 1))
fi
if m="$(mutant ledger-case "[A-Za-z_]*[Ll][Ee][Dd][Gg][Ee][Rr]" "[A-Z_]*LEDGER")"; then
  repo="$(fake_repo mutant-case "$m")"
  cp "$WORK/lower-ledger/hooks/lower-ledger.sh" "$repo/hooks/lower-ledger.sh"
  check "変異体: 大文字の LEDGER だけを数えると、\"\$ledger\" への追記を見落とす" 1 "ledger-wiring" \
    run "$repo/scripts/h5-admission-check.sh" "hooks/lower-ledger.sh" "$(body)"
else
  fail=$((fail + 1))
fi

echo "=== 台帳はテスト用の一時ファイルだけに書く ==="
if [[ ! -s "$H5_LEDGER_PATH" ]] || python3 - "$H5_LEDGER_PATH" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert all(row.get("source") == "test" for row in rows), rows
PY
then
  echo "PASS: ledger rows are isolated and source=test"
  pass=$((pass + 1))
else
  echo "FAIL: ledger rows are not all source=test"
  fail=$((fail + 1))
fi

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
