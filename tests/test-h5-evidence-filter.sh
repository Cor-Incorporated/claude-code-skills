#!/usr/bin/env bash
# h5-admission の evidence フィルタが「言及」と「主張」を取り違えないことの反証スイート (#134)
#
# 起点 (2026-09-02): フィルタが **行単位** で否定語を落としていたため、
# `H5-NEGATIVE:` マーカーと同じ行に否定語が 1 語でも入るとマーカーごと
# 証拠から消えた。
#
#   H5-NEGATIVE: 修正前は「未記入」の分岐が red になることを実測（rc=1）
#   H5-NEGATIVE: expect red だった 3 件を修正後 green に反転させた
#
# どちらも本物の陰性テスト証跡だが `未記入` / `expect red` を含むため落ち、
# negative-test-evidence 欠落で exit 1 になった。
# **ゲートが要求している内容を最も自然な語で書くと落ちる。**
#
# ここで守る性質は 2 つあり、**両方向を測らないと意味が無い**:
#   (a) 正当な証跡行を落とさない       — 緩める方向。C 群・D 群が測る
#   (b) メタ行だけの主張を通さない     — 締める方向。E 群が測る。ここが穴
# (b) を落とすと #134 の修正は「フィルタをやめた」だけになる。
#
# 判定は構造（マーカー行か散文行か）だけで引く。内容の真偽は判定しない（C15）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/h5-admission-check.sh"
PASS=0; FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export AIDD_LEDGER_SOURCE=test
export H5_LEDGER_PATH="$WORKDIR/guard-ledger.jsonl"

# 3 点セットのうち、その節で動かさない側は常に満たしておく。落ちたときに
# 「どの欄が欠けたのか」が exit code だけでは分からなくなるのを防ぐ。
TAIL_OK='H5-LEDGER: fires reach guard-ledger.jsonl via aidd_ledger_append
H5-RETIRE: retire when 90 days pass with zero fires
H5-SUBTRACTION: N/A'

# run_gate <diff-files> <pr-body> -> LAST_RC / LAST_OUT
LAST_RC=0; LAST_OUT=""
run_gate() {
  set +e
  # H5_REPAIR_THRESHOLD: 同居する repair-family ゲートは fixture ではなく
  # `origin/main..HEAD` の実 git 履歴から fix commit を数えるため、このブランチに
  # 何が積まれているかで発火する。tests/test-acl-change-gate.sh が同じ理由で
  # CI だけ 13 件落ちた（2026-09-02）。repair 側は test-repair-loop-breaker.sh が覆う。
  LAST_OUT="$(H5_DIFF_FILES="$1" H5_PR_BODY="$2" \
    H5_BASE_REF=origin/main H5_HEAD_REF=HEAD \
    H5_REPAIR_THRESHOLD=999999 \
    bash "${3:-$CHECK}" 2>&1)"
  LAST_RC=$?
  set -e
  # クラッシュを「止まった」と読まない。exit!=0 だけを見ると、未定義変数で
  # 落ちたスクリプトが「正しくブロックした」に化ける（2026-09-02 に 2 件発生）。
  if [[ "$LAST_OUT" == *"unbound variable"* || "$LAST_OUT" == *"command not found"* \
     || "$LAST_OUT" == *"syntax error"* ]]; then
    bad "スクリプトがクラッシュした（判定ではない）:: $LAST_OUT"
    LAST_RC=99
  fi
  # 同居する別ゲートの結論をこの節の結論として読まない。
  if [[ "$LAST_OUT" == *"H5-REPAIR:"* ]]; then
    bad "無関係な repair-family ゲートに当たった（この節の結果は無意味）:: $LAST_OUT"
    LAST_RC=98
  fi
}

# guard PR 本文を組み立てる。$1 = H5-NEGATIVE 行、$2 = 追加の散文行（任意）
guard_body() {
  printf 'H5-guard: yes\nH5-E2E: none\n%s\n%s\n' "$1" "$TAIL_OK"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2"
  return 0
}

expect_rc() {
  local want="$1" label="$2"
  if [[ "$LAST_RC" -eq "$want" ]]; then ok "$label (exit=$want)"
  else bad "$label:: 期待 exit=$want 実測 exit=$LAST_RC :: $LAST_OUT"; fi
}

# --- A: フィルタ語の一覧が 1 箇所に閉じていること --------------------------
# 同じ語彙が 2 箇所にあると、マーカー行では潰されるのに散文行では残る（逆も）。
# 片方だけ語を足す事故を、行数で機械的に縛る。
echo "A. メタ語彙の単一定義"
meta_defs="$(grep -c "^_H5_META_RE=" "$CHECK" || true)"
if [[ "$meta_defs" -eq 1 ]]; then ok "_H5_META_RE の定義は 1 箇所"
else bad "_H5_META_RE の定義が $meta_defs 箇所ある（1 であるべき）"; fi
# shellcheck disable=SC2016  # ソースのリテラルを探している。展開させない。
if grep -q 'grep -viE "\$_H5_META_RE"' "$CHECK"; then
  ok "散文行の除外は _H5_META_RE を参照している（リテラル再掲でない）"
else
  bad "散文行の除外が _H5_META_RE を参照していない（語彙が二重管理になる）"
fi

# --- B: issue #134 の真理値表 ----------------------------------------------
echo "B. issue #134 の真理値表（H5-NEGATIVE）"
run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE: injected known-bad input, measured exit 1 before the fix')"
expect_rc 0 "control: メタ語なしの証跡は数える"

run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE: 修正前は「未記入」の分岐が red になることを実測（rc=1）')"
expect_rc 0 "正当な証跡に「未記入」が含まれても数える"

run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE: expect red だった 3 件を修正後 green に反転させた')"
expect_rc 0 "正当な証跡に expect red が含まれても数える"

run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE: 未記入')"
expect_rc 1 "メタ語だけのマーカーは数えない（元の穴を開けない）"

run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE:')"
expect_rc 1 "値が空のマーカーは数えない"

run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE: expect red')"
expect_rc 1 "expect red だけのマーカーは数えない"

run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE: intentionally missing')"
expect_rc 1 "intentionally missing だけのマーカーは数えない（21 文字あるが通さない）"

run_gate "hooks/foo.sh" "$(guard_body \
  'H5-NEGATIVE: injected known-bad input, measured exit 1 before the fix' \
  '陰性テストは intentionally missing です')"
expect_rc 0 "散文の否定行があってもマーカーが実質を持てば数える"

run_gate "hooks/foo.sh" "$(guard_body '陰性テストは intentionally missing です')"
expect_rc 1 "マーカーが無く散文の否定行だけなら数えない"

# --- C: 大文字小文字とマーカー表記のゆれ ------------------------------------
# has_marker は grep -i なので、フィルタ側も同じ寛容さでなければならない。
# 片側だけ case-sensitive だと `Expect Red` と書くだけでゲートを迂回できる。
echo "C. 大文字小文字の非対称でゲートを迂回できないこと"
run_gate "hooks/foo.sh" "$(guard_body 'H5-NEGATIVE: Expect Red')"
expect_rc 1 "メタ語を大文字化しても迂回できない"

run_gate "hooks/foo.sh" "$(guard_body 'h5-negative: 修正前は「未記入」の分岐が red になることを実測（rc=1）')"
expect_rc 0 "マーカー名が小文字でも正当な証跡は数える"

# --- D: マーカー行以外の消費側でも一貫していること --------------------------
# PR_BODY_EVIDENCE は 9 箇所で読まれる。フィルタは 1 箇所なので、ここが割れると
# 同じ本文に対して 2 つのゲートが違う判定をする。
echo "D. 他の消費側（ACL / E2E-OUT / LEDGER / RETIRE）"

# D-1 ACL ゲート: .github/CODEOWNERS は protected-identity-paths.txt の **/CODEOWNERS に当たる。
#
# **リポジトリの .aidd-h5-gates に依存させない。** 本体は正本から vendor した
# 同一ファイルで、ACL ゲートを on にするかはリポジトリごとに違う（#137）。
# 実測 2026-09-03: claude-code-skills は acl-change を off と宣言しているため、
# リポジトリ設定のまま走らせるとゲート自体が呼ばれず、この 2 件が両方 exit 0 に
# なって「フィルタが正しい」と誤読される。**ゲートを見るテストは、ゲートが
# 有効な状態を自分で作る。** 専用 fixture を建てて判定する。
ACL_FIX="$(mktemp -d)"
mkdir -p "$ACL_FIX/scripts" "$ACL_FIX/design/ops"
cp "$CHECK" "$ACL_FIX/scripts/h5-admission-check.sh"
printf '%s\n' '**/CODEOWNERS' >"$ACL_FIX/design/ops/protected-identity-paths.txt"
printf '%s\n' 'acl-change on requires=design/ops/protected-identity-paths.txt' \
               'repair-family off reason=本 fixture は ACL のみ見る' \
               'h8-identifier-scope off reason=本 fixture は ACL のみ見る' >"$ACL_FIX/.aidd-h5-gates"
ACL_CHECK="$ACL_FIX/scripts/h5-admission-check.sh"

run_gate ".github/CODEOWNERS" \
'H5-E2E: none
ACL-CHANGE: expect red と書いてあるが、CODEOWNERS の owner を A から B へ移す変更である' \
"$ACL_CHECK"
expect_rc 0 "ACL-CHANGE の理由にメタ語が含まれても承認として数える"

run_gate ".github/CODEOWNERS" 'H5-E2E: none
ACL-CHANGE: expect red' "$ACL_CHECK"
expect_rc 1 "ACL-CHANGE がメタ語だけなら承認として数えない"
rm -rf "$ACL_FIX"

# D-2 H5-E2E-OUT: 20 文字判定が残余に対して効くこと
run_gate "hooks/foo.sh" "$(printf 'H5-guard: yes\nH5-E2E: bash tests/test-h5-evidence-filter.sh\nH5-E2E-OUT: expect red と書いた行だが PASS=24 FAIL=0 を実測した\nH5-NEGATIVE: injected known-bad input, measured exit 1\n%s\n' "$TAIL_OK")"
expect_rc 0 "H5-E2E-OUT にメタ語が含まれても 20 文字の残余があれば通る"

# 実測 2026-09-03: この行が本 PR で唯一 red になった。マーカーを潰して
# **値が空のまま残す**と、L478 の `^\s*H5-E2E-OUT:\s*(.*?)\s*$` の `\s*` が
# 改行を跨いで次行 `H5-NEGATIVE: ...`（54 文字）を E2E 出力として掴み、
# exit 0 になった。空マーカーを残さず落とす、が唯一の正解。
run_gate "hooks/foo.sh" "$(printf 'H5-guard: yes\nH5-E2E: bash tests/test-h5-evidence-filter.sh\nH5-E2E-OUT: expect red\nH5-NEGATIVE: injected known-bad input, measured exit 1\n%s\n' "$TAIL_OK")"
expect_rc 1 "H5-E2E-OUT がメタ語だけなら通らない（空マーカーが次行を掴まない）"

# もともと空だったマーカー行の扱いは #134 の対象外。ここを変えると別ゲートの
# 要求が動くので、メタ語を含まない空マーカーには触れないことを固定する。
run_gate "hooks/foo.sh" "$(printf 'H5-guard: yes\nH5-E2E: none\nH5-NEGATIVE: injected known-bad input, measured exit 1\nH5-LEDGER:\nH5-LEDGER: fires reach guard-ledger.jsonl via aidd_ledger_append\nH5-RETIRE: retire when 90 days pass with zero fires\nH5-SUBTRACTION: N/A\n')"
expect_rc 0 "メタ語を含まない空マーカー行はフィルタが触らない（現状維持）"

# D-3 LEDGER / RETIRE も同じマーカー機構を通ること
run_gate "hooks/foo.sh" "$(printf 'H5-guard: yes\nH5-E2E: none\nH5-NEGATIVE: injected known-bad input, measured exit 1\nH5-LEDGER: 未記入だった配線を aidd_ledger_append へ繋いだ\nH5-RETIRE: expect red の状態が 90 日続いたら退役 issue を起票する\nH5-SUBTRACTION: N/A\n')"
expect_rc 0 "H5-LEDGER / H5-RETIRE にメタ語が含まれても数える"

# --- E: 緩めていないことの確認（トークン接合） ------------------------------
# メタ語を「削除」すると前後が接合して新しい判定語が生まれる。空白 1 個への
# 置換ならこれが起きない。宣言（空白置換）と実体（判定結果）を機械で結ぶ。
echo "E. メタ語の除去でトークンが接合しないこと"
run_gate "hooks/foo.sh" "$(printf 'H5-guard: yes\nH5-E2E: nexpect redone\nH5-NEGATIVE: injected known-bad input, measured exit 1\n%s\n' "$TAIL_OK")"
expect_rc 1 "H5-E2E: nexpect redone が none に化けない（H5-E2E-OUT 欠落で落ちる）"

run_gate "hooks/foo.sh" "$(printf 'H5-guard: yes\nH5-E2E: none\nH5-NEGATIVE: injected known-bad input, measured exit 1\nH5-LEDGER: fires reach guard-ledger.jsonl via aidd_ledger_append\nH5-RETIRE: retire when 90 days pass with zero fires\nH5-SUBTRACTION: Nexpect red/A\n')"
expect_rc 1 "H5-SUBTRACTION: Nexpect red/A が N/A に化けない"

# --- F: 落としたこと・残したことが観測できること -----------------------------
# ここが無いと「正当な証跡を持ちながら落とされた PR」は無音で消え、
# 件数を数える手段が無い（#134 の北極星）。
echo "F. 観測点（出力と台帳）"
OBS_LEDGER="$WORKDIR/obs.jsonl"
set +e
OBS_OUT="$(H5_DIFF_FILES="hooks/foo.sh" \
  H5_PR_BODY="$(guard_body \
    'H5-NEGATIVE: 修正前は「未記入」の分岐が red になることを実測（rc=1）' \
    '陰性テストは intentionally missing です')" \
  H5_BASE_REF=origin/main H5_HEAD_REF=HEAD H5_REPAIR_THRESHOLD=999999 \
  H5_LEDGER_PATH="$OBS_LEDGER" bash "$CHECK" 2>&1)"
OBS_RC=$?
set -e
if [[ "$OBS_RC" -eq 0 ]]; then ok "観測ケース自体は通る"
else bad "観測ケースが落ちた:: $OBS_OUT"; fi
if [[ "$OBS_OUT" == *"kept(neutralized): H5-NEGATIVE:"* ]]; then
  ok "メタ語を潰して残したマーカー行を出力している"
else
  bad "潰して残した行が出力に出ていない:: $OBS_OUT"
fi
if [[ "$OBS_OUT" == *"dropped(prose): 陰性テストは intentionally missing です"* ]]; then
  ok "落とした散文行を出力している"
else
  bad "落とした行が出力に出ていない:: $OBS_OUT"
fi
if grep -q '"rule":"evidence-filter"' "$OBS_LEDGER" 2>/dev/null \
  && grep -q '"detail":"rescued=1 marker-dropped=0 prose-dropped=1"' "$OBS_LEDGER" 2>/dev/null; then
  ok "台帳へ rescued/dropped の観測行が届いている"
else
  bad "台帳に観測行が無い:: $(cat "$OBS_LEDGER" 2>/dev/null)"
fi
# 何も落とさなかった本文で観測行を出さない（台帳を無意味に太らせない）
QUIET_LEDGER="$WORKDIR/quiet.jsonl"
set +e
H5_DIFF_FILES="hooks/foo.sh" \
  H5_PR_BODY="$(guard_body 'H5-NEGATIVE: injected known-bad input, measured exit 1')" \
  H5_BASE_REF=origin/main H5_HEAD_REF=HEAD H5_REPAIR_THRESHOLD=999999 \
  H5_LEDGER_PATH="$QUIET_LEDGER" bash "$CHECK" >/dev/null 2>&1
set -e
if grep -q '"rule":"evidence-filter"' "$QUIET_LEDGER" 2>/dev/null; then
  bad "メタ語が 1 件も無い本文で観測行が出ている（台帳が意味を失う）"
else
  ok "メタ語が無い本文では観測行を出さない"
fi

# --- G: F3 片側変異 ---------------------------------------------------------
# 新しい sed 段を消すと B 群の 2・3 行目が再び落ちることを実測する。
# 変異が当たったことを先に確かめないと、この節は無条件 PASS になる。
# 変異体は WORKDIR に置くので ROOT が repo 外になり、ACL / repair の両ゲートは
# 宣言ファイルが見つからず自動的に no-op になる。この節が測るのは evidence 経路
# だけなので問題ない。control が exit 0 を返すことが「環境ごと落ちてはいない」
# の対照になる（それが無いと全件 red を「変異が効いた」と読み違える）。
echo "G. F3 片側変異（sed 段を外すと #134 が再発する）"
MUTANT="$WORKDIR/mutant.sh"
# 末尾は継続行の `\`。単一引用の中では展開されないので、ソースの実物と
# 1 文字ずつ一致する。最後の "\\" は連結したリテラルのバックスラッシュ 1 個。
# shellcheck disable=SC2016  # ソースのリテラルを探している。展開させない。
NEUTRALIZE_LINE='  | sed "${_H5_NEUTRALIZE_MARKERS[@]}" '"\\"
hits="$(grep -Fxc "$NEUTRALIZE_LINE" "$CHECK" || true)"
if [[ "$hits" -ne 1 ]]; then
  bad "変異対象の行が $hits 件（1 件であるべき）。この節は測れていない"
else
  ok "変異対象の行を 1 件特定した"
  grep -Fxv "$NEUTRALIZE_LINE" "$CHECK" > "$MUTANT"
  # 変異体が構文として成立していること。壊れたスクリプトの exit 1 を
  # 「ゲートが正しく落とした」と読み違えない。
  if bash -n "$MUTANT" 2>/dev/null; then
    ok "変異体は構文として成立している"
  else
    bad "変異体が構文エラー（この節の結果は無意味）"
  fi
  run_gate "hooks/foo.sh" \
    "$(guard_body 'H5-NEGATIVE: 修正前は「未記入」の分岐が red になることを実測（rc=1）')" "$MUTANT"
  expect_rc 1 "変異体では「未記入」を含む正当な証跡が再び落ちる"
  run_gate "hooks/foo.sh" \
    "$(guard_body 'H5-NEGATIVE: expect red だった 3 件を修正後 green に反転させた')" "$MUTANT"
  expect_rc 1 "変異体では expect red を含む正当な証跡が再び落ちる"
  run_gate "hooks/foo.sh" \
    "$(guard_body 'H5-NEGATIVE: injected known-bad input, measured exit 1 before the fix')" "$MUTANT"
  expect_rc 0 "変異体でも control は通る（変異が control を巻き添えにしていない）"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
