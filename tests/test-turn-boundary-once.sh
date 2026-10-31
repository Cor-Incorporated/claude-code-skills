#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/aidd-turn-boundary-stop.sh
# 同じセッションで同じ未宣言の持ち越しに止めるのは、時間内に 1 回まで (#458, 2026-10-31; #471 review)。
#
# 起点: local-llm レーンはレーン契約で ~/.claude/state/async-work への書き込みを禁じられたまま、同じ
# nohup の持ち越しで 48 回止められた（2026-10-31T03:27:43Z〜04:57:41Z）。書けないので、宣言も解決もできない。
#
# 検査: 1 回目は止める / 同じ id で 2 回目は止めず、表示と台帳 (warn turn-boundary-repeat) だけ /
# 新しい id が増えれば止める / 目標並列度の不足は毎回止める / 別のセッションは別に数える。
# 反証: 繰り返しの判定を外した変異体では 2 回目も止まる（両方の rc を出す）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/aidd-turn-boundary-stop.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test HOME="$SB/home"
mkdir -p "$HOME/.claude/hooks/lib" "$HOME/.claude/scripts"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HOME/.claude/hooks/lib/"
cp "$ROOT/scripts/async-work.sh" "$HOME/.claude/scripts/"
LEDGER="$HOME/.claude/hooks/ledger/guard-ledger.jsonl"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

reset() { export AIDD_ASYNC_STATE="$SB/aw-$1"; rm -rf "$AIDD_ASYNC_STATE" "$AIDD_ASYNC_STATE.turn-boundary-seen"; mkdir -p "$AIDD_ASYNC_STATE"; }
seed() {  # id session [age_seconds]
  python3 - "$AIDD_ASYNC_STATE" "$1" "$2" "${3:-0}" <<'PY'
import json, os, sys, time
state, ident, session, age = sys.argv[1:5]
json.dump({"id": ident, "kind": "generic", "detail": "nohup: runner " + ident, "owner": "", "check_cmd": "",
           "source": "posttooluse-auto", "session": session, "registered_ts": int(time.time()) - int(age),
           "resolved_ts": 0, "resolved": False, "conclusion": ""},
          open(os.path.join(state, ident + ".json"), "w", encoding="utf-8"))
PY
}
stop() {  # hook session [env...] -> rc
  local hook="$1" session="$2"; shift 2
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","session_id":sys.argv[1]}))' "$session" \
    | env "$@" bash "$hook" >"$SB/out" 2>"$SB/err"
  echo $?
}

reset a
seed nohup-1 s1
r1="$(stop "$HOOK" s1)"; r2="$(stop "$HOOK" s1)"
[[ "$r1" == 2 ]] && ok "1 回目は止める (rc=$r1)" || bad "first stop" "rc=$r1"
[[ "$r2" == 0 ]] && grep -q '"systemMessage"' "$SB/out" && ok "同じ id の 2 回目は止めず、systemMessage で人に見せる (rc=$r2)" \
  || bad "second stop" "rc=$r2 out=$(cat "$SB/out") err=$(head -2 "$SB/err")"
grep -q '"rule":"turn-boundary-repeat"' "$LEDGER" 2>/dev/null && ok "2 回目は台帳に warn turn-boundary-repeat" \
  || bad "repeat ledger row" "$(tail -2 "$LEDGER" 2>/dev/null)"

seed nohup-2 s1
r3="$(stop "$HOOK" s1)"
[[ "$r3" == 2 ]] && ok "新しい持ち越しが増えれば止める (rc=$r3)" || bad "new id" "rc=$r3"

reset b
seed nohup-3 s2
r4="$(stop "$HOOK" s2)"
[[ "$r4" == 2 ]] && ok "別のセッションは別に数える (rc=$r4)" || bad "other session" "rc=$r4"

reset c
d1="$(stop "$HOOK" s3 AIDD_LANE_TARGET=2)"; d2="$(stop "$HOOK" s3 AIDD_LANE_TARGET=2)"
[[ "$d1" == 2 && "$d2" == 2 ]] && ok "目標並列度の不足は毎回止める (rc=$d1, $d2)" || bad "deficit" "rc=$d1, $d2"

reset e
seed nohup-e s6
e1="$(stop "$HOOK" s6 AIDD_TURN_BOUNDARY_REARM_SEC=0)"; e2="$(stop "$HOOK" s6 AIDD_TURN_BOUNDARY_REARM_SEC=0)"
[[ "$e1" == 2 && "$e2" == 2 ]] && ok "時間がたてば、また止める（REARM=0 で 2 回とも rc=2）" || bad "re-arm" "rc=$e1, $e2"

reset f
seed nohup-dead dead-session 10800
f1="$(stop "$HOOK" s7)"; f2="$(stop "$HOOK" s7)"
[[ "$f1" == 2 && "$f2" == 2 ]] && ok "持ち主のいない stale な持ち越しは毎回止める (rc=$f1, $f2)" || bad "orphan" "rc=$f1, $f2"

reset h
seed nohup-own s9
seed nohup-dead2 dead-session 10800
h1="$(stop "$HOOK" s9)"; h2="$(stop "$HOOK" s9)"
[[ "$h1" == 2 && "$h2" == 2 ]] && ok "an own item plus a stale orphan stops every time (rc=$h1, $h2)" || bad "own+orphan" "rc=$h1, $h2"

reset g
seed nohup-g1 s8
stop "$HOOK" s8 >/dev/null
rm -f "$AIDD_ASYNC_STATE/nohup-g1.json"
seed nohup-g2 s8
stop "$HOOK" s8 >/dev/null
seen_ids="$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$AIDD_ASYNC_STATE.turn-boundary-seen/s8.json" 2>/dev/null)"
[[ "$seen_ids" == "nohup-g2" ]] && ok "記録には今も未解決の id だけが残る ($seen_ids)" || bad "prune" "seen: '$seen_ids'"
# GNU `stat -f` is file-system status and succeeds, so read the mode the same way on every OS
perm="$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$AIDD_ASYNC_STATE.turn-boundary-seen/s8.json")"
[[ "$perm" == 600 ]] && ok "記録の権限は 600" || bad "perm" "$perm"

# 反証: 繰り返しの判定を外す
MUT="$SB/mutant.sh"
python3 - "$HOOK" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = 'if [ "$repeat" = "yes" ]; then'
if needle not in text:
    raise SystemExit("mutation target not found")
pathlib.Path(dst).write_text(text.replace(needle, 'if false; then', 1))
PY
reset m
seed nohup-m s4
m1="$(stop "$MUT" s4)"; m2="$(stop "$MUT" s4)"
reset r
seed nohup-r s5
x1="$(stop "$HOOK" s5)"; x2="$(stop "$HOOK" s5)"
[[ "$m2" == 2 && "$x2" == 0 ]] && ok "反証: 2 回目の rc は本物 $x2 / 変異体（判定なし）$m2" \
  || bad "mutation" "second stop real=$x2 mutant=$m2 (want 0 / 2); first real=$x1 mutant=$m1"

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
