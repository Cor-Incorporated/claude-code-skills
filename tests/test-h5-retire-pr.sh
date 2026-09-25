#!/usr/bin/env bash
# ADR-002 控除ゲートのもう一方の受理形式（廃止 PR の番号を書く H5-RETIRE-PR 経路）の反証。
#
# 起点 (2026-09-24 実測, bash 3.2.57 / 5.3.20): 本体の番号抽出は
#   grep -oiE 'H5-RETIRE-PR:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+'
# だった。最後の grep は**マーカー名 `H5` の `5` も拾う。** 番号 457 を書くと
# retire_pr=$'5\n457' になり、`gh pr view` は状態を返さず state=UNKNOWN、
# ゲートは必ず subtraction-pr-not-merged で落ちていた。
# 本体の失敗メッセージ（Required subtraction declaration）と AGENTS.md が
# 受理形式として案内している経路が、**一度も通らない形**だった。
# N/A 側しか試験していなかったので、どのテストも緑のまま生き残った。
#
# gh は PATH 先頭のスタブで置き換える（network 不要）。スタブは受け取った引数を
# 1 呼び出し 1 行で記録するので、gh に渡った番号 = retire_pr をバイト単位で照合できる。
# 改行が混ざれば記録の行が割れて一致しない。
#
# F3（片側変異）: 本体の最後の grep を `[0-9]+` に戻すと 6 件すべて red になる。
# 最後の OPEN の件は逆向きの対照で、控除ゲートが「番号さえあれば通す」形に
# 緩んだら red になる。
set -uo pipefail
export AIDD_LEDGER_SOURCE=test
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$ROOT/scripts/h5-admission-check.sh"
# 外側の CI admission job は実 PR コンテキストを export する。fixture が
# それを継承すると、空の H5_PR_BODY が実 PR 本文を読み直してしまう。
unset H5_PR_NUMBER GITHUB_EVENT_PATH
# set -e を使わないので、mktemp の失敗を自分で止める。WORK が空のまま進むと
# スタブを /bin/gh へ書こうとする。
WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d に失敗した"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
export H5_LEDGER_PATH="$WORK/ledger.jsonl"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '<%s>' "$@" >>"$GH_STUB_LOG"
printf '\n' >>"$GH_STUB_LOG"
if [[ "${1-}" == pr && "${2-}" == view ]]; then
  case "${3-}" in
    457) printf 'MERGED\n'; exit 0 ;;
    458) printf 'OPEN\n'; exit 0 ;;
  esac
fi
# 知らない番号には stdout へ何も出さず exit 1 を返す（ゲート側は UNKNOWN と読む）。
printf 'gh-stub: no pull request for %q\n' "${3-}" >&2
exit 1
STUB
chmod +x "$WORK/bin/gh"

pass=0
fail=0

# 3 点会費と E2E 宣言は揃え、控除宣言は番号の行だけにする。N/A を書かないので、
# 控除ゲートを通れるのは番号の経路だけである。
guard_body() { # <番号の行>
  printf '%s\n' \
    'H5-guard: yes' \
    'H5-E2E: none' \
    'H5-NEGATIVE: unit red exit 1 measured' \
    'H5-LEDGER: aidd_ledger_append on every fire' \
    'H5-RETIRE: 90 days zero fires then retire' \
    "$1"
}

run_gate() { # <本文> -> RC / GH_ARGS と $WORK/out, $WORK/err
  : >"$WORK/gh.log"
  GH_STUB_LOG="$WORK/gh.log" PATH="$WORK/bin:$PATH" \
    H5_DIFF_FILES="hooks/example-guard.sh" H5_PR_BODY="$1" \
    bash "$CHK" >"$WORK/out" 2>"$WORK/err"
  RC=$?
  GH_ARGS="$(cat "$WORK/gh.log")"
}

report_fail() { # <名前> <期待>
  # runbook.md rule C: 期待値だけでなく観測値も出す。
  echo "FAIL: $1"
  echo "  expected: $2"
  echo "  observed: exit=$RC gh-args=$(printf '%q' "$GH_ARGS")"
  sed -e 's/^/  stderr: /' "$WORK/err"
  fail=$((fail + 1))
}

expect_merged() { # <名前> <本文>
  local want='<pr><view><457><--json><state><-q><.state>'
  run_gate "$2"
  if [[ "$RC" -eq 0 && "$GH_ARGS" == "$want" ]] \
    && grep -qxF 'H5: subtraction PR #457 state=MERGED' "$WORK/out"; then
    echo "PASS: $1 (exit $RC, gh に渡った番号 = 457)"
    pass=$((pass + 1))
  else
    report_fail "$1" "exit=0 gh-args=$want"
  fi
}

echo "== 番号の経路: マージ済みの廃止 PR を書けば通る =="
expect_merged "canonical" "$(guard_body 'H5-RETIRE-PR: 457')"
expect_merged "no-space" "$(guard_body 'H5-RETIRE-PR:457')"
expect_merged "lowercase-tab" "$(guard_body "$(printf 'h5-retire-pr:\t457')")"
expect_merged "trailing-text" "$(guard_body 'H5-RETIRE-PR: 457 (retired: old guard)')"
# GitHub の Web 編集で保存した本文は CRLF になる。
expect_merged "crlf-body" "$(guard_body 'H5-RETIRE-PR: 457' | sed -e $'s/$/\r/')"

echo "== 対照: 未マージの廃止 PR は通さない =="
run_gate "$(guard_body 'H5-RETIRE-PR: 458')"
want='<pr><view><458><--json><state><-q><.state>'
if [[ "$RC" -eq 1 && "$GH_ARGS" == "$want" ]] \
  && grep -qF 'subtraction PR #458 state=OPEN (need MERGED)' "$WORK/err" \
  && grep -qF 'subtraction-pr-not-merged' "$WORK/err"; then
  echo "PASS: open-pr-stays-red (exit $RC, gh に渡った番号 = 458)"
  pass=$((pass + 1))
else
  report_fail "open-pr-stays-red" "exit=1 gh-args=$want + subtraction-pr-not-merged"
fi

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
