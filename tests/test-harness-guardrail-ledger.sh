#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/harness-guardrail-ledger.sh
# harness-guardrail-ledger.sh の検査: plugin の監査ファイルの発火が
# guard-ledger.jsonl へ 1 回だけ、生コマンドなしで届くこと。
#
# 起点 (2026-10-30 harness-pdca F3): 一晩で RUNTIME_FLOOR が 9 レーン中 6 レーンで
# 発火したのに guard-ledger.jsonl は 0 行だった。H6 の退役判定は台帳を読むので、
# 届かない発火は「発火しなかった」と同じに見える。
#
# 反証可能性: 変異体 2 本で同じ入力を流して red を実測する。
#   M1 cursor を進めない → 2 回目の呼び出しで二重計上する
#   M2 project root へ昇らない → 副ディレクトリの cwd から 1 行も届かない
#
# 全て $TMPDIR の HOME サンドボックスで走る。実台帳には触れない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/harness-guardrail-ledger.sh"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test

install_hook() { # $1 = hook source, $2 = HOME sandbox
  mkdir -p "$2/hooks/lib"
  cp "$1" "$2/hooks/harness-guardrail-ledger.sh"
  cp "$ROOT/hooks/lib/aidd-ledger.sh" "$2/hooks/lib/aidd-ledger.sh"
}

fire() { # $1 = audit file, $2 = ts, $3 = rule_id, $4 = decision, $5 = tool
  local cat=""
  case "$3" in RUNTIME_FLOOR:*) cat=",\"category\":\"${3#RUNTIME_FLOOR:}\"" ;; esac
  printf '{"schema_version":"guardrail-fire.v1","ts":"%s","host":"claude","tool":"%s","rule_id":"%s"%s,"decision":"%s","command_sha256":"deadbeef","command_len":12}\n' \
    "$2" "$5" "$3" "$cat" "$4" >>"$1"
}

run_hook() { # $1 = HOME sandbox, $2 = cwd
  printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"true"}}' "$2" \
    | HOME="$1" bash "$1/hooks/harness-guardrail-ledger.sh"
}

ledger_rows() { # $1 = HOME sandbox
  local f="$1/.claude/hooks/ledger/guard-ledger.jsonl"
  [[ -f "$f" ]] && grep -c . "$f" || echo 0
}

setup_project() { # $1 = HOME sandbox → prints project dir
  local p="$1/work/proj"
  mkdir -p "$p/.git" "$p/sub/deep" "$p/.claude/state/audit"
  printf '%s' "$p"
}

# --- 正常系 -----------------------------------------------------------------
H="$SB/h1"; mkdir -p "$H"; install_hook "$HOOK" "$H"
P="$(setup_project "$H")"
A="$P/.claude/state/audit/guardrail-fires.jsonl"
fire "$A" "2026-10-29T16:22:10Z" "RUNTIME_FLOOR:secret-read" deny Bash
fire "$A" "2026-10-29T16:31:01Z" "RUNTIME_FLOOR:egress" deny Bash
fire "$A" "2026-10-29T16:40:00Z" "R04:confirm-write-outside-project" ask Write

run_hook "$H" "$P/sub/deep"
n="$(ledger_rows "$H")"
[[ "$n" == 3 ]] && ok "3 fires reach the ledger from a nested cwd" || bad "nested cwd ingest" "rows=$n (want 3)"

L="$H/.claude/hooks/ledger/guard-ledger.jsonl"
if python3 - "$L" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
floor = [r for r in rows if r["rule"].startswith("RUNTIME_FLOOR:")]
assert len(floor) == 2, rows
assert floor[0]["ts"] == "2026-10-29T16:22:10Z", floor[0]
assert floor[0]["event"] == "block" and floor[0]["decision"] == "deny", floor[0]
assert floor[0]["category"] == "secret-read", floor[0]
assert floor[0]["hook"] == "harness-guardrail" and floor[0]["component"] == "H6", floor[0]
assert floor[0]["agent"] == "claude-code" and floor[0]["source"] == "test", floor[0]
ask = [r for r in rows if r["rule"].startswith("R04")][0]
assert ask["event"] == "measure" and ask["decision"] == "ask", ask
for r in rows:
    blob = json.dumps(r)
    assert "deadbeef" not in blob and "command" not in r, r
PY
then ok "rows keep plugin ts/rule/category and carry no command or hash"
else bad "row shape" "$(tail -3 "$L")"
fi

run_hook "$H" "$P"
n="$(ledger_rows "$H")"
[[ "$n" == 3 ]] && ok "no growth → no duplicate rows" || bad "idempotent re-run" "rows=$n (want 3)"

printf '{"schema_version":"guardrail-fire.v1","ts":"2026-10-29T17:00:00Z","host":"codex","tool":"Bash","rule_id":"RUNTIME_FLOOR:egress","category":"egress","decision":"deny"}' >>"$A"
run_hook "$H" "$P"
n="$(ledger_rows "$H")"
[[ "$n" == 3 ]] && ok "a half-written line (no newline yet) is not ingested" || bad "partial line" "rows=$n (want 3)"
printf '\n' >>"$A"
run_hook "$H" "$P"
n="$(ledger_rows "$H")"
[[ "$n" == 4 ]] && ok "the line is ingested once completed" || bad "completed line" "rows=$n (want 4)"
tail -1 "$L" | grep -q '"agent":"codex"' && ok "codex host maps to agent=codex" || bad "agent map" "$(tail -1 "$L")"

printf 'not json\n' >>"$A"
fire "$A" "2026-10-29T17:05:00Z" "RUNTIME_FLOOR:egress" deny Bash
run_hook "$H" "$P"
n="$(ledger_rows "$H")"
[[ "$n" == 5 ]] && ok "an unreadable audit line is skipped, the next one still lands" || bad "invalid line" "rows=$n (want 5)"
python3 -c "import json,sys;[json.loads(l) for l in open(sys.argv[1])]" "$L" 2>/dev/null \
  && ok "every ledger row parses as JSON" || bad "ledger JSON" "unparseable row"

# --- 並行: 2 セッションが同時に取り込んでも二重計上しない ---------------------
for i in 1 2 3 4 5; do fire "$A" "2026-10-29T18:0$i:00Z" "RUNTIME_FLOOR:secret-read" deny Bash; done
run_hook "$H" "$P" & run_hook "$H" "$P/sub" & run_hook "$H" "$P/sub/deep" & wait
n="$(ledger_rows "$H")"
[[ "$n" == 10 ]] && ok "3 concurrent runs add exactly the 5 new fires" || bad "concurrency" "rows=$n (want 10)"

# --- 監査ファイルが無い / project の外 ---------------------------------------
H2="$SB/h2"; mkdir -p "$H2/elsewhere"; install_hook "$HOOK" "$H2"
run_hook "$H2" "$H2/elsewhere"
[[ "$(ledger_rows "$H2")" == 0 ]] && ok "no audit file → no ledger write" || bad "no audit" "unexpected rows"

# --- 変異体 -----------------------------------------------------------------
# M1: cursor を書かない
M1="$SB/m1"; mkdir -p "$M1"
python3 - "$HOOK" "$SB/m1.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(src.replace("    os.replace(tmp, cursor_file)\n", "    pass\n", 1))
PY
if cmp -s "$HOOK" "$SB/m1.sh"; then bad "M1 mutant applies" "the mutation did not change the hook"; fi
install_hook "$SB/m1.sh" "$M1"
PM="$(setup_project "$M1")"
fire "$PM/.claude/state/audit/guardrail-fires.jsonl" "2026-10-29T16:22:10Z" "RUNTIME_FLOOR:secret-read" deny Bash
run_hook "$M1" "$PM"; run_hook "$M1" "$PM"
n="$(ledger_rows "$M1")"
[[ "$n" == 2 ]] && ok "M1 (no cursor) double-counts: rows=$n — the real hook's 1 is meaningful" \
  || bad "M1 should go red" "rows=$n (want 2 for the mutant)"

# M2: root へ昇らない
M2="$SB/m2"; mkdir -p "$M2"
python3 - "$HOOK" "$SB/m2.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(src.replace('root="$(resolve_root "$cwd")"', 'root="$cwd"', 1))
PY
if cmp -s "$HOOK" "$SB/m2.sh"; then bad "M2 mutant applies" "the mutation did not change the hook"; fi
install_hook "$SB/m2.sh" "$M2"
PM="$(setup_project "$M2")"
fire "$PM/.claude/state/audit/guardrail-fires.jsonl" "2026-10-29T16:22:10Z" "RUNTIME_FLOOR:secret-read" deny Bash
run_hook "$M2" "$PM/sub/deep"
n="$(ledger_rows "$M2")"
[[ "$n" == 0 ]] && ok "M2 (no ascend) loses the fire from a nested cwd: rows=$n" \
  || bad "M2 should go red" "rows=$n (want 0 for the mutant)"

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
