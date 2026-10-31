#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/aidd-async-register.sh
# 自動登録が「実行」と「引用」を区別することを検査する (aidd-governance#100)。
#
# 起点事故 (2026-09-02): 文字列として `gh workflow run v2-alpha-cd.yml` を含む
# だけのコマンドが持ち越しとして登録され、Stop hook がターンを止めた。
#
#   registered: wf-20260902T143854-b674599ce2 : gh workflow run v2-alpha-cd.yml
#   実測: Grift の v2-alpha-cd 直近 run は 2026-09-02T00:37:44Z（約 5 時間前）。
#         登録時刻 05:38:53Z に開始された run は存在しない。= 発射されていない。
#
# #100 が言う「承認の有無でなくパターンでゲートを引く誤分類」そのものである。
# 同日、同型の誤検知を他に 2 系統踏んでいる:
#   - protect-branches.sh が commit message 中の `+18` を force refspec と誤読
#   - protect-branches.sh が `set +e` を同様に誤読
#
# 対策は 2 つ。(1) heredoc の本文を照合対象から外す（本文はデータであって
# 実行されるコマンドではない）。(2) コマンド位置に現れたものだけを実行とみなす。
#
# **意図的な取りこぼしがある。** `bash -c "gh workflow run x"` のように引用符の
# 内側から起動する形は登録されない。本 hook は block ではなく登録（可視化）で
# あり、見落とし 1 件より「毎ターン止まる」ほうが害が大きいという判断である。
# したがって case 3 群（登録しない側）を緩めてはならない。
#
# 全て $TMPDIR の HOME サンドボックスで走る。実台帳・実状態には触れない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/aidd-async-register.sh"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/.claude/hooks/lib" "$SB/.claude/scripts"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SB/.claude/hooks/lib/"
cp "$ROOT/scripts/async-work.sh" "$SB/.claude/scripts/"

# --include-test を付ける。本スイートが測るのは **検出の精度**（登録されたか）で
# あって停止判定ではない。fire() は AIDD_LEDGER_SOURCE=test で発火するので、
# test 系 source を除く既定の unresolved では登録が見えない。
registered() {
  HOME="$SB" bash "$SB/.claude/scripts/async-work.sh" unresolved --include-test 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0
}

# fire <hook> <command> [tool_response JSON] -> echoes the delta in registered rows
fire() {
  local before after
  before="$(registered)"
  python3 -c 'import json,sys
d = {"hook_event_name": "PostToolUse", "tool_input": {"command": sys.argv[1]}}
if len(sys.argv) > 2 and sys.argv[2]:
    d["tool_response"] = json.loads(sys.argv[2])
print(json.dumps(d))' "$2" "${3:-}" \
    | HOME="$SB" AIDD_LEDGER_SOURCE=test bash "$1" >/dev/null 2>&1
  after="$(registered)"
  echo $((after - before))
}

expect() { # <label> <expected-delta> <command> [hook] [tool_response JSON]
  local label="$1" want="$2" cmd="$3" hook="${4:-$HOOK}" resp="${5:-}"
  local got
  got="$(fire "$hook" "$cmd" "$resp")"
  if [[ "$got" == "$want" ]]; then
    ok "$label (登録 +$got)"
  else
    bad "$label" "期待 +$want / 実際 +$got"
  fi
}

HEREDOC_CMD="cat <<'EOF' > /tmp/doc.md
gh workflow run v2-alpha-cd.yml
EOF"

echo "=== 1. 実行は登録する ==="
expect "文頭の gh workflow run"        1 'gh workflow run v2-alpha-cd.yml --ref main'
expect "&& の後の gh workflow run"     1 'cd /tmp && gh workflow run deploy.yml'
expect "改行後の gh workflow run"      1 'set -e
gh workflow run release.yml'
expect "gh run watch"                  1 'gh run watch 12345678 --exit-status'
expect "文頭の nohup"                  1 'nohup ./long-job.sh &'

echo
echo "=== 2. 引用は登録しない（今日の事故） ==="
expect "grep のパターン内"             0 "grep -rn 'gh workflow run v2-alpha-cd.yml' design/"
expect "heredoc の本文"                0 "$HEREDOC_CMD"
expect "echo の引数"                   0 'echo "手順: gh workflow run v2-alpha-cd.yml"'
expect "rg のパターン内 (run watch)"   0 "rg 'gh run watch 99999999' ."
expect "コメント文中の nohup"          0 'echo "使うな: nohup foo &"'

echo
echo "=== 2b. 引用の中の括弧 (#459, 2026-10-31 14:06 の事故) ==="
# 統括の Bash: echo のラベルの中の `(` の直後をコマンド位置とみなし、`lines)"` を workflow 名とする cd-run を登録した
expect "echo のラベルの中の ( の後"     0 'echo "--- commands for the owner (gh workflow run lines)"'
expect "printf の引用の中の ; の後"     0 "printf '%s\\n' 'a; gh workflow run x.yml'"
expect "引用が閉じていない"             0 'gh workflow run "x.yml'

echo
echo "=== 2c. 実行結果を根拠にする (#459) ==="
OK_RUN='{"stdout":"✓ Created workflow_dispatch event for deploy.yml at main\nhttps://github.com/o/r/actions/runs/41197183115\n","stderr":"","interrupted":false}'
expect "成功し run の URL がある"       1 'gh workflow run deploy.yml --ref main' "$HOOK" "$OK_RUN"
expect "終了コード 1"                   0 'gh workflow run deploy.yml --ref main' "$HOOK" '{"stdout":"","stderr":"HTTP 422","exit_code":1}'
expect "--help は発射ではない"          0 'gh workflow run --help' "$HOOK" '{"stdout":"Create a workflow_dispatch event…","stderr":"","interrupted":false}'
expect "背景に送った（結果は不明）"     1 'gh workflow run nightly.yml' "$HOOK" '{"stdout":"","stderr":"","backgroundTaskId":"b1"}'
id_of_run="$(HOME="$SB" bash "$SB/.claude/scripts/async-work.sh" unresolved --include-test 2>/dev/null \
  | python3 -c 'import json,sys; print(" ".join(r.get("id","") for r in json.load(sys.stdin)))')"
[[ " $id_of_run " == *" run-41197183115 "* ]] && ok "run の URL があれば id は run-<run id>" \
  || bad "run id" "ids: $id_of_run"

echo
echo "=== 2e. 本物の発射を取りこぼさない (#471 review: tty の無い gh、コメント、\$( )、前置き) ==="
# Claude Code の Bash には tty が無い。gh は run の URL だけを出すか、何も出さない。PostToolUse は exit_code を載せない。
CC_EMPTY='{"stdout":"","stderr":"","interrupted":false}'
expect "出力なしで成功（204 の経路）"     1 'gh workflow run a.yml' "$HOOK" "$CC_EMPTY"
expect "GHES の run URL"                   1 'gh workflow run b.yml' "$HOOK" '{"stdout":"https://ghe.example.com/o/r/actions/runs/555\n","stderr":"","interrupted":false}'
expect "出力を捨てた発射"                 1 'gh workflow run c.yml >/dev/null' "$HOOK" "$CC_EMPTY"
expect "前の行がコメント"                 1 '# release
gh workflow run d.yml' "$HOOK" "$CC_EMPTY"
expect "前の語に # を含む"                 1 'echo a#b; gh workflow run e.yml' "$HOOK" "$CC_EMPTY"
expect "\$# の後"                          1 'echo $#; gh workflow run f.yml' "$HOOK" "$CC_EMPTY"
expect "\$( ) で URL を受ける"             1 'URL="$(gh workflow run g.yml)"' "$HOOK" "$CC_EMPTY"
expect "後ろの grep が 1（発射はした）"    1 'gh workflow run h.yml && gh run list | grep -q h' "$HOOK" '{"stdout":"","stderr":"","interrupted":false,"returnCodeInterpretation":"No matches found"}'
expect "\$'…' の後"                        1 "printf \$'it\\'s'; gh workflow run i.yml" "$HOOK" "$CC_EMPTY"
expect "前の行がコメントの nohup"         1 '# long job
nohup ./job.sh &' "$HOOK" "$CC_EMPTY"
expect "env / timeout の前置き"           1 'env GH_REPO=o/r timeout 60 gh workflow run j.yml' "$HOOK" "$CC_EMPTY"
expect "single quote の中の \$( ) は文字"  0 "echo '\$(gh workflow run k.yml)'" "$HOOK" "$CC_EMPTY"
expect "2 本の発射に 2 本の URL"           2 'gh workflow run l.yml && gh workflow run m.yml' "$HOOK" '{"stdout":"https://github.com/o/r/actions/runs/1001\nhttps://github.com/o/r/actions/runs/1002\n","stderr":"","interrupted":false}'
ids_now="$(HOME="$SB" bash "$SB/.claude/scripts/async-work.sh" unresolved --include-test 2>/dev/null \
  | python3 -c 'import json,sys; print(" ".join(r.get("id","") for r in json.load(sys.stdin)))')"
[[ " $ids_now " == *" run-1001 "* && " $ids_now " == *" run-1002 "* && " $ids_now " == *" run-555 "* ]] \
  && ok "run の URL は発射ごとに順に割り当て、ホストを問わない" || bad "run ids" "ids: $ids_now"

echo
echo "=== 2d. 登録し直しで宣言済みの owner を消さない (2026-10-31、統括の owner が 3 回消えた) ==="
HOME="$SB" bash "$SB/.claude/scripts/async-work.sh" register --id run-777 --kind cd-run --detail "release run 777" \
  --owner "統括: 30 分ごとに gh run view 777" --source manual --session s-owner >/dev/null 2>&1
fire "$HOOK" 'gh run watch 777 --exit-status' >/dev/null
owner_now="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("owner",""))' \
  "$SB/.claude/state/async-work/run-777.json" 2>/dev/null)"
[[ "$owner_now" == "統括: 30 分ごとに gh run view 777" ]] && ok "gh run watch の自動登録は宣言済みの owner を残す" \
  || bad "owner kept" "owner after auto re-register: '$owner_now'"

echo
echo "=== 3. 反証: コマンド位置の判定を外すと事故が戻るか ==="
# 単純コマンドの切り出しを「引用を外した全ての語の位置」に変異させる。判定が効いているなら、2 群が登録され始める。
MUT="$SB/mutant.sh"
python3 - "$HOOK" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = "for words in commands:"
if needle not in text:
    raise SystemExit("mutation target not found: simple_commands loop")
mutant = "for words in [re.sub(\"[\\\"'()]\", \" \", scan).split()[i:] for i in range(len(re.sub(\"[\\\"'()]\", \" \", scan).split()))]:"
pathlib.Path(dst).write_text(text.replace(needle, mutant, 1))
PY
if [[ -f "$MUT" ]]; then
  got="$(fire "$MUT" "grep -rn 'gh workflow run v2-alpha-cd.yml' design/")"
  got2="$(fire "$MUT" 'echo "--- commands for the owner (gh workflow run lines)"')"
  if [[ "$got" -gt 0 && "$got2" -gt 0 ]]; then
    ok "変異体（コマンド位置判定なし）は grep と echo のラベルを登録する = 判定が結論を作っていた (+$got, +$got2)"
  else
    bad "変異体でも登録しない = case 2 はコマンド位置判定を証明していない" "delta=$got / $got2"
  fi
else
  bad "変異体を作れなかった — 反証不能" "mutation target missing"
fi

echo
echo "=== 3b. 反証: 実行結果の確認を外すと、終了コード 1 の発射が登録される ==="
MUT3="$SB/mutant3.sh"
python3 - "$HOOK" "$MUT3" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = "        if (rc is not None and rc != 0 and len(commands) == 1) or \"--help\" in words or \"-h\" in words:\n            continue\n"
if needle not in text:
    raise SystemExit("mutation target not found: rc check")
pathlib.Path(dst).write_text(text.replace(needle, "", 1))
PY
if [[ -f "$MUT3" ]]; then
  got="$(fire "$MUT3" 'gh workflow run deploy.yml --ref main' '{"stdout":"","stderr":"✓ Created workflow_dispatch event for deploy.yml at main","exit_code":1}')"
  [[ "$got" -gt 0 ]] && ok "変異体（rc の確認なし）は rc=1 の発射を登録する (+$got)" \
    || bad "変異体でも登録しない = 2c の rc 行は rc の確認を証明していない" "delta=$got"
else
  bad "変異体 3 を作れなかった — 反証不能" "mutation target missing"
fi

echo
echo "=== 4. 反証: heredoc 除去を外すと事故が戻るか ==="
MUT2="$SB/mutant2.sh"
python3 - "$HOOK" "$MUT2" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = "scan = strip_heredocs(cmd)"
if needle not in text:
    raise SystemExit("mutation target not found: strip_heredocs call")
pathlib.Path(dst).write_text(text.replace(needle, "scan = cmd", 1))
PY
if [[ -f "$MUT2" ]]; then
  got="$(fire "$MUT2" "$HEREDOC_CMD")"
  if [[ "$got" -gt 0 ]]; then
    ok "変異体（heredoc 除去なし）は heredoc 本文を登録する = 除去が効いていた (+$got)"
  else
    bad "変異体でも登録しない = heredoc 除去を証明していない" "delta=$got"
  fi
else
  bad "変異体 2 を作れなかった — 反証不能" "mutation target missing"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
