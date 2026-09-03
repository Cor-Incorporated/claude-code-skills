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

# fire <hook> <command> -> echoes the delta in registered rows
fire() {
  local before after
  before="$(registered)"
  printf '{"tool_input":{"command":%s}}' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")" \
    | HOME="$SB" AIDD_LEDGER_SOURCE=test bash "$1" >/dev/null 2>&1
  after="$(registered)"
  echo $((after - before))
}

expect() { # <label> <expected-delta> <command> [hook]
  local label="$1" want="$2" cmd="$3" hook="${4:-$HOOK}"
  local got
  got="$(fire "$hook" "$cmd")"
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
echo "=== 3. 反証: コマンド位置の判定を外すと事故が戻るか ==="
# AT_COMMAND を「どこでも可」に変異させる。判定が効いているなら、2 群が登録され始める。
MUT="$SB/mutant.sh"
python3 - "$HOOK" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = 'AT_COMMAND = r"(?:\\A|[\\n;&|(){}]\\s*)"'
if needle not in text:
    raise SystemExit("mutation target not found: AT_COMMAND")
pathlib.Path(dst).write_text(text.replace(needle, 'AT_COMMAND = r""', 1))
PY
if [[ -f "$MUT" ]]; then
  got="$(fire "$MUT" "grep -rn 'gh workflow run v2-alpha-cd.yml' design/")"
  if [[ "$got" -gt 0 ]]; then
    ok "変異体（コマンド位置判定なし）は grep を登録する = 判定が結論を作っていた (+$got)"
  else
    bad "変異体でも登録しない = case 2 はコマンド位置判定を証明していない" "delta=$got"
  fi
else
  bad "変異体を作れなかった — 反証不能" "mutation target missing"
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
