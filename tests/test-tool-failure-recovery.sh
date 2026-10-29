#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/tool-failure-recovery.sh
# tool-failure-recovery.sh の Bash 分類を、2026-10-30 の夜に実際に出た誤案内で検査する。
#
# 起点 (harness-pdca F4): grep の不一致に「コマンド 'zsh' が見つかりません」、
# rg の一部パス欠落に「ファイル/ディレクトリが存在しません」(検索結果は有効だった)。
# error 欄は "Exit code N" + コマンドの stdout/stderr 全体なので、句をどこかに含むか
# だけで判定すると、検索対象の本文やテスト名に引きずられる。
#
# 反証可能性: HOOK=<旧版> で同じ表を流すと red になる (PR に実測を貼る)。
#   git show origin/develop~:hooks/tool-failure-recovery.sh > /tmp/old.sh
#   HOOK=/tmp/old.sh bash tests/test-tool-failure-recovery.sh   # → fail>0
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK:-$ROOT/hooks/tool-failure-recovery.sh}"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/hooks/lib"
cp "$HOOK" "$SB/hooks/tool-failure-recovery.sh"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SB/hooks/lib/aidd-ledger.sh"

guide() { # $1 = command, $2 = error field → prints additionalContext or "(silent)"
  python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"error":sys.argv[2],"is_interrupt":False}))' "$1" "$2" \
    | HOME="$SB" AIDD_LEDGER_SOURCE=test bash "$SB/hooks/tool-failure-recovery.sh" \
    | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
print(json.loads(raw)["hookSpecificOutput"]["additionalContext"] if raw else "(silent)")'
}

expect() { # $1 = name, $2 = command, $3 = error, $4 = must contain, $5 = must not contain (optional)
  local got
  got="$(guide "$2" "$3")"
  if [[ "$got" != *"$4"* ]]; then
    bad "$1" "want '$4' in: $got"
  elif [[ -n "${5:-}" && "$got" == *"$5"* ]]; then
    bad "$1" "must not contain '$5': $got"
  else
    ok "$1"
  fi
}

NL=$'\n'
expect "grep no-match whose output quotes an error is not an error" \
  "grep -n 'command not found' build.log" "Exit code 1${NL}build.log:12: bash: foo: command not found" "(silent)"
expect "grep exit 1 with a count is silent" \
  "grep -c xyz README.md" "Exit code 1${NL}0" "(silent)"
expect "zsh format names the missing command, not zsh" \
  "foo --version" "Exit code 127${NL}zsh: command not found: foo" "'foo'" "'zsh'"
expect "exit 127 names the shell's own line, not a quoted log line before it" \
  "cat build.log; foo" "Exit code 127${NL}build.log:12: bash: bar: command not found${NL}zsh: command not found: foo" "'foo'" "'bar'"
expect "bash format names the missing command" \
  "bash -c foo" "Exit code 127${NL}bash: line 1: foo: command not found" "'foo'"
expect "zsh = expansion is explained, not called a missing command" \
  "echo ====" "Exit code 1${NL}(eval):1: === not found" "= 展開" "見つかりません"
expect "rg with one missing path says the rest of the search is valid" \
  "rg -n TODO src nope" "Exit code 2${NL}src/a.py:3:# TODO fix${NL}rg: nope: No such file or directory (os error 2)" "検索自体は実行済み"
expect "grep on a missing file names the path" \
  "grep -n x missing.txt" "Exit code 2${NL}grep: missing.txt: No such file or directory" "missing.txt"
expect "ssh publickey is an auth failure, not a file permission" \
  "ssh evo-x2 uptime" "Exit code 255${NL}terisuke@evo-x2: Permission denied (publickey)." "SSH 認証" "chmod"
expect "exit 126 is not-executable" \
  "./run.sh" "Exit code 126${NL}zsh: permission denied: ./run.sh" "実行権限"
expect "cat on a missing file names the path" \
  "cat notes/missing.md" "Exit code 1${NL}cat: notes/missing.md: No such file or directory" "notes/missing.md"
expect "a failing test named *timeout* is not a network timeout" \
  "pytest -q" "Exit code 1${NL}FAILED tests/test_net.py::test_timeout_retry - AssertionError${NL}1 failed, 20 passed" "(silent)"
expect "a real connect timeout still gets guidance" \
  "curl -sS http://127.0.0.1:9/" "Exit code 28${NL}curl: (28) Connection timed out after 3001 milliseconds" "タイムアウト"
expect "a logged 'command not found' after a non-127 failure is not a missing command" \
  "tail -5 build.log; false" "Exit code 1${NL}bash: foo: command not found" "(silent)"
expect "a tool's own Permission denied line gets guidance" \
  "touch /etc/x" "Exit code 1${NL}touch: /etc/x: Permission denied" "権限エラー"
expect "python can't open file names the path" \
  "python3 nope.py" "Exit code 2${NL}python3: can't open file '/w/nope.py': [Errno 2] No such file or directory" "/w/nope.py"
expect "npm fallback still fires" \
  "npm run build" "Exit code 1${NL}npm ERR! code ELIFECYCLE" "パッケージマネージャ"

# --- 変異体: error lines no longer anchored ---
# 同じ表をこの変異体に流し、少なくとも 1 件 red になることを実測する。
if [[ -z "${IN_MUTANT:-}" ]]; then
  MUT="$SB/mutant-hook.sh"
  python3 - "$HOOK" "$MUT" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = 'hit = re.match(pat, line.strip())'
assert old in src, "mutation anchor not found"
open(sys.argv[2], "w").write(src.replace(old, 'hit = re.search(pat.lstrip("^"), line)', 1))
PY
  if [[ ! -s "$MUT" ]] || cmp -s "$HOOK" "$MUT"; then
    bad "mutation could not be applied" "anchor not found in $HOOK — update the mutant"
  elif IN_MUTANT=1 HOOK="$MUT" bash "$0" >/dev/null 2>&1; then
    bad "mutant (error lines no longer anchored) stays green" "the table above does not detect it"
  else
    ok "mutant (error lines no longer anchored) goes red"
  fi
fi

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
