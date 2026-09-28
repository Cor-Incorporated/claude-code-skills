#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/aidd-turn-boundary-stop.sh
# ターン境界の持ち越し検査 — hooks/aidd-turn-boundary-stop.sh /
# hooks/aidd-async-register.sh / scripts/async-work.sh の反証テスト.
#
# Issue: Cor-Incorporated/aidd-governance#96 / #95
#
# 起点事故 (2026-08-27): 監督は Alpha CD run 33091489486 が in_progress
# (success=17/25 step) の状態で「進んでいる」と報告してターンを終えた。11 分後に
# CD は失敗し、ユーザーが翌朝指摘するまで 7 時間 25 分だれも気づかなかった。
# 同日、レーン 12 本が正常終了したが空いた枠は補充されず、ユーザーが 5 回以上
# 指摘した。
#
# 本スイートが実測するのは「持ち越しがある状態で停止しようとしたら止まるか」
# であって「無人区間を検知できるか」ではない。後者は Stop hook では原理的に
# 不可能であり、テストでもそう主張しない。
#
# shellcheck disable=SC2015,SC2016
#   SC2015: ok() は常に 0 を返すので `A && ok || bad` は if-then-else として働く。
#   SC2016: 変異体の置換対象は、展開させない生の文字列として単引用符で書く。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOP_HOOK="$ROOT/hooks/aidd-turn-boundary-stop.sh"
REG_HOOK="$ROOT/hooks/aidd-async-register.sh"
ASYNC="$ROOT/scripts/async-work.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test
export HOME="$SB/home"
# 手で登録した持ち越しは CLAUDE_CODE_SESSION_ID のセッションに紐づく。停止の入力の session_id "t" と
# そろえる（このテストを走らせているセッション自身の id を持ち込まない）。
export CLAUDE_CODE_SESSION_ID=t
mkdir -p "$HOME/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HOME/.claude/hooks/lib/aidd-ledger.sh"
LEDGER="$HOME/.claude/hooks/ledger/guard-ledger.jsonl"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

reset_state() {
  export AIDD_ASYNC_STATE="$SB/aw-$1"
  rm -rf "$AIDD_ASYNC_STATE"
  mkdir -p "$AIDD_ASYNC_STATE"
}

# stop_payload <stop_hook_active>
stop_payload() {
  python3 -c 'import json,sys; print(json.dumps({"stop_hook_active": sys.argv[1]=="true","session_id":"t"}))' "$1"
}

# run_stop <hook> <stop_hook_active> [env...] -> rc、stderr は $SB/stop.err へ
run_stop() {
  local hook="$1" active="$2"
  shift 2
  stop_payload "$active" | env "$@" bash "$hook" 2>"$SB/stop.err"
}

# seed <id> <session> — 未解決・owner 未宣言の持ち越しを 1 件、登録したセッション付きで台帳へ置く。
# register --session を使わず保存形式へ直接書くのは、--session を解さない修正前の CLI に対しても
# 同じ前提を作るため（修正前で実測すると登録が失敗し、「止まらない」が偽 PASS になる）。
seed() {
  python3 - "$AIDD_ASYNC_STATE" "$1" "$2" <<'PY'
import json, os, sys, time
state, ident, session = sys.argv[1:4]
json.dump({"id": ident, "kind": "cd-run", "detail": "seed " + ident, "owner": "",
           "check_cmd": "", "source": "manual", "session": session,
           "registered_ts": int(time.time()), "resolved_ts": 0,
           "resolved": False, "conclusion": ""},
          open(os.path.join(state, ident + ".json"), "w", encoding="utf-8"), ensure_ascii=False)
PY
}

# build_skew_cli <out> — --session を解さない台帳 CLI（この変更より前の CLI と同じく unknown flag で拒否する）
build_skew_cli() {
  python3 - "$ASYNC" "$1" <<'PY'
import sys
src, out = sys.argv[1:3]
text = open(src, encoding="utf-8").read()
needle = '      --session) session="${2:-}"; shift 2 ;;\n'
if text.count(needle) not in (0, 2):
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(text.replace(needle, ""))
PY
}

# skew_cli_ok <cli> — 版ずれ CLI の前提: unresolved は動き、unresolved --session は拒否する
skew_cli_ok() {
  [ -f "$1" ] && bash "$1" unresolved >/dev/null 2>&1 && ! bash "$1" unresolved --session B >/dev/null 2>&1
}

ledger_has() {
  python3 - "$LEDGER" "$1" "$2" <<'PY'
import json, os, sys
path, rule, event = sys.argv[1:4]
if not os.path.exists(path):
    raise SystemExit(1)
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if row.get("rule") == rule and row.get("event") == event:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "=== case 1: 持ち越しなし -> 停止を許す（恒真 block ではない） ==="
reset_state c1
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case1 持ち越しゼロなら素通しする"
else
  bad "case1 持ち越しゼロなのに停止を拒否した (rc=$?)"
fi

echo
echo "=== case 2: 未完了 + owner 未宣言 -> 停止を拒否 (#96 replay) ==="
reset_state c2
bash "$ASYNC" register --id run-33091489486 --kind cd-run \
  --detail "Alpha CD run 33091489486 (in_progress で報告した対象)" >/dev/null
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 2 ]] \
  && ok "case2 exit 2 で停止を拒否した" \
  || bad "case2 期待 exit 2, 実際 rc=$rc"
grep -q "run-33091489486" "$SB/stop.err" \
  && ok "case2 拒否理由が対象の run id を名指しする" \
  || bad "case2 拒否理由に run id がない: $(cat "$SB/stop.err")"
grep -q "status=in_progress は前進の証拠ではない" "$SB/stop.err" \
  && ok "case2 拒否理由が in_progress を前進の根拠にするなと明示する" \
  || bad "case2 拒否理由に in_progress の否認がない"
grep -q "gh run view" "$SB/stop.err" \
  && ok "case2 拒否理由が実行可能な確認コマンドを含む（参照だけで終わらない）" \
  || bad "case2 拒否理由に確認コマンドがない"
ledger_has turn-boundary-unresolved block \
  && ok "case2 台帳に rule=turn-boundary-unresolved event=block 行" \
  || bad "case2 台帳に block 行がない"

echo
echo "=== case 3: stop_hook_active=true -> 必ず素通し（無限ループ防止） ==="
reset_state c3
bash "$ASYNC" register --id run-999 --kind cd-run --detail "still open" >/dev/null
if run_stop "$STOP_HOOK" true AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case3 継続中は持ち越しがあっても素通しする"
else
  bad "case3 継続中に再度拒否した = 停止不能になる"
fi

echo
echo "=== case 4: owner を宣言した持ち越し -> 素通しするが記録は残す ==="
reset_state c4
bash "$ASYNC" register --id run-777 --kind cd-run --detail "Alpha CD" \
  --owner "監督が 2026-08-28 09:00 JST に確認" \
  --check-cmd "gh run view 777 --json conclusion" >/dev/null
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case4 確認主体を宣言すれば終えられる（非同期作業の禁止ではない）"
else
  bad "case4 owner 宣言済みなのに拒否した"
fi
ledger_has async-work-owned warn \
  && ok "case4 宣言済み持ち越しが warn として台帳に残る" \
  || bad "case4 宣言済み持ち越しが記録されない"

echo
echo "=== case 5: resolve 済み -> 素通し ==="
reset_state c5
bash "$ASYNC" register --id run-555 --kind cd-run --detail "Alpha CD" >/dev/null
bash "$ASYNC" resolve --id run-555 --conclusion failure >/dev/null
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case5 conclusion を読んで終端すれば終えられる"
else
  bad "case5 resolve 済みなのに拒否した"
fi

echo
echo "=== case 6: resolve は非終端の status を終端として受け付けない (#96 要求2) ==="
reset_state c6
bash "$ASYNC" register --id run-666 --kind cd-run --detail "Alpha CD" >/dev/null
for word in in_progress queued running pending IN_PROGRESS; do
  if bash "$ASYNC" resolve --id run-666 --conclusion "$word" >/dev/null 2>&1; then
    bad "case6 conclusion=$word が終端として通った"
  else
    ok "case6 conclusion=$word を拒否した"
  fi
done
if bash "$ASYNC" resolve --id run-666 --conclusion success >/dev/null 2>&1; then
  ok "case6 conclusion=success は通る（恒真 red ではない）"
else
  bad "case6 正当な conclusion まで拒否した"
fi

echo
echo "=== case 7 (#95): 目標並列度を下回ったままターンを終えない ==="
reset_state c7
bash "$ASYNC" register --id lane-1 --kind lane --detail "issue #2004" \
  --owner "codex-parallel" >/dev/null
bash "$ASYNC" register --id lane-2 --kind lane --detail "issue #2007" \
  --owner "codex-parallel" >/dev/null
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" AIDD_LANE_TARGET=8
rc=$?
[[ "$rc" -eq 2 ]] \
  && ok "case7 稼働 2 / 目標 8 で停止を拒否した" \
  || bad "case7 レーン欠員を素通しした (rc=$rc)"
grep -q "枠が空いた" "$SB/stop.err" \
  && ok "case7 拒否理由が「完了 = 成果回収 + 枠が空いた」の 2 事実を述べる" \
  || bad "case7 拒否理由に補充の指示がない"
reset_state c7b
for i in 1 2 3 4 5 6 7 8; do
  bash "$ASYNC" register --id "lane-$i" --kind lane --detail "task $i" --owner cp >/dev/null
done
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" AIDD_LANE_TARGET=8; then
  ok "case7 目標に達していれば素通しする（恒真 block ではない）"
else
  bad "case7 目標充足なのに拒否した"
fi

echo
echo "=== case 8: PostToolUse 自動登録 — gh workflow run / nohup ==="
reset_state c8
post_payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}
post_payload 'gh workflow run v2-alpha-cd.yml --ref develop' \
  | env -u AIDD_LEDGER_SOURCE AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -ge 1 ]] \
  && ok "case8 gh workflow run が自動登録された（監督が忘れても登録される）" \
  || bad "case8 gh workflow run が登録されない"
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
[[ "$?" -eq 2 ]] \
  && ok "case8 自動登録された持ち越しでターン終了が止まる" \
  || bad "case8 自動登録後もターンを終えられた"

reset_state c8b
post_payload 'nohup ./scripts/fire-cd.sh > /tmp/fire.log 2>&1 &' \
  | env -u AIDD_LEDGER_SOURCE AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -ge 1 ]] \
  && ok "case8 nohup が自動登録された（#96 の起点コマンド形）" \
  || bad "case8 nohup が登録されない"

echo
echo "=== case 9: 誤検知しない — 読み取り専用コマンドは登録しない ==="
reset_state c9
for c in 'git status' 'ls -la' 'gh run view 123 --json conclusion' 'grep -rn TODO src/'; do
  post_payload "$c" | env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
done
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -eq 0 ]] \
  && ok "case9 読み取り専用 4 種は 1 件も登録しない（ターン終了を無駄に止めない）" \
  || bad "case9 誤検知 $n 件"

echo
echo "=== case 10: テスト実行が共有状態を汚さない（ハーネス共通のテスト規約） ==="
echo "    由来 2026-09-02: 別レーンのテスト検体が監督の共有台帳へ入り、監督のターンが"
echo "    Stop hook で止まった。register hook が AIDD_LEDGER_SOURCE を見ていなかった。"
reset_state c10
post_payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}
post_payload 'gh workflow run v2-alpha-cd.yml --ref develop' \
  | env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" AIDD_LEDGER_SOURCE=test bash "$REG_HOOK" >/dev/null 2>&1
n_all=$(bash "$ASYNC" unresolved --include-test | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
n_gate=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n_all" -eq 1 ]] \
  && ok "case10 test 実行でも登録はする（テスト実行があったことを追える）" \
  || bad "case10 test 実行が登録されない（黙って捨てている）"
[[ "$n_gate" -eq 0 ]] \
  && ok "case10 test 系 source は停止判定の入力に現れない" \
  || bad "case10 test 登録が停止判定に現れた（$n_gate 件）"
src=$(bash "$ASYNC" unresolved --include-test | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["source"])')
[[ "$src" == test:* ]] \
  && ok "case10 source が test 系として記録される（${src}）" \
  || bad "case10 source が test 系でない: $src"
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 0 ]] \
  && ok "case10 test 登録だけならターンを止めない" \
  || bad "case10 test 登録でターンが止まった"

echo "--- 濾しすぎ検査: 未設定なら従来どおり止める ---"
reset_state c10b
post_payload 'gh workflow run v2-alpha-cd.yml --ref develop' \
  | env -u AIDD_LEDGER_SOURCE AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
n_gate=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n_gate" -eq 1 ]] \
  && ok "case10 未設定の登録は従来どおり停止判定に現れる（本物を見逃していない）" \
  || bad "case10 濾しすぎて本物が消えた"
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
[[ "$?" -eq 2 ]] \
  && ok "case10 未設定の登録は従来どおりターンを止める" \
  || bad "case10 本物でターンが止まらなくなった"


echo
echo "=== case 11: 他セッションの持ち越しでは止めない（2026-09-28 の干渉の再現） ==="
echo "    由来: 台帳は全セッションで共有。別セッションが自動登録した corsweb2024 の run と"
echo "    ai-cluster の nohup が、無関係なセッションのターン終了を止めた。"
# stop_payload_as <session|""> -> 停止の入力。空なら session_id を持たない
stop_payload_as() {
  python3 -c 'import json,sys; d={"stop_hook_active": False}
if sys.argv[1]: d["session_id"] = sys.argv[1]
print(json.dumps(d))' "$1"
}
run_stop_as() {
  local hook="$1" who="$2"
  shift 2
  stop_payload_as "$who" | env "$@" bash "$hook" 2>"$SB/stop.err"
}
reset_state c11
seed run-other A
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -eq 1 ]] \
  && ok "case11 前提: セッション A の未宣言の持ち越しが台帳に 1 件ある" \
  || bad "case11 前提: 台帳の持ち越しが $n 件（期待 1）— 以下は反証にならない"
run_stop_as "$STOP_HOOK" B AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 0 ]] \
  && ok "case11 セッション A の未宣言の持ち越しでは、セッション B は止まらない" \
  || bad "case11 セッション A の持ち越しがセッション B を止めた (rc=$rc)"
grep -q "run-other" "$SB/stop.err" && grep -q "他セッション" "$SB/stop.err" \
  && ok "case11 他セッションの持ち越しは情報として名指しする（黙って消さない）" \
  || bad "case11 他セッションの持ち越しが見えない: $(cat "$SB/stop.err")"
ledger_has async-work-other-session warn \
  && ok "case11 台帳に rule=async-work-other-session event=warn 行" \
  || bad "case11 台帳に他セッションの warn 行がない"

echo
echo "=== case 12: 自分のセッションの持ち越しでは従来どおり止める ==="
reset_state c12
seed run-mine B
run_stop_as "$STOP_HOOK" B AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 2 ]] \
  && ok "case12 セッション B の未宣言の持ち越しはセッション B を止める" \
  || bad "case12 自分の持ち越しで止まらない (rc=$rc)"

echo
echo "=== case 13: 自動登録は登録したセッションを記録する ==="
reset_state c13
python3 -c 'import json; print(json.dumps({"session_id":"A","tool_input":{"command":"gh workflow run cd.yml"}}))' \
  | env -u AIDD_LEDGER_SOURCE AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
got=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0].get("session","") if r else "")')
[[ "$got" == "A" ]] \
  && ok "case13 PostToolUse の入力の session_id が台帳に入る" \
  || bad "case13 自動登録の session が '$got'（期待 A）"
run_stop_as "$STOP_HOOK" B AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 0 ]] \
  && ok "case13 他セッションが自動登録した持ち越しでは止まらない" \
  || bad "case13 他セッションの自動登録で止まった"

echo
echo "=== case 14: 手で登録した持ち越しは CLAUDE_CODE_SESSION_ID のセッションに紐づく ==="
reset_state c14
env CLAUDE_CODE_SESSION_ID=C AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$ASYNC" register --id run-manual --kind cd-run --detail m >/dev/null
got=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0].get("session","") if r else "")')
[[ "$got" == "C" ]] \
  && ok "case14 手動登録の session は CLAUDE_CODE_SESSION_ID（C）" \
  || bad "case14 手動登録の session が '$got'（期待 C）"
reset_state c14b
env CLAUDE_CODE_SESSION_ID=C AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$ASYNC" register --id run-flag --kind cd-run --detail m --session D >/dev/null 2>&1
got=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0].get("session","") if r else "")')
[[ "$got" == "D" ]] \
  && ok "case14 --session を渡せば既定より優先する（D）" \
  || bad "case14 --session の session が '$got'（期待 D）"

echo
echo "=== case 15: 停止の入力に session_id が無ければ、区別できないので全件で止める ==="
reset_state c15
seed run-anyone A
run_stop_as "$STOP_HOOK" "" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
[[ "$?" -eq 2 ]] \
  && ok "case15 session_id の無い停止は、他セッションの持ち越しでも止める（ガードを黙って外さない）" \
  || bad "case15 session_id が無いのに止まらなかった"

echo
echo "=== case 16: 台帳 CLI が --session を知らない版ずれでも、黙って素通しにしない ==="
echo "    hooks/ と scripts/ は別々に配られうる。古い CLI は --session を unknown flag で拒否する。"
# 版ずれの配置: 新しい hook + --session を解さない CLI（この変更より前の CLI と同じ拒否をする）
SKEW="$SB/skew"
mkdir -p "$SKEW/hooks" "$SKEW/scripts"
cp "$STOP_HOOK" "$SKEW/hooks/aidd-turn-boundary-stop.sh"
cp "$REG_HOOK" "$SKEW/hooks/aidd-async-register.sh"
build_skew_cli "$SKEW/scripts/async-work.sh"
reset_state c16
skew_cli_ok "$SKEW/scripts/async-work.sh" \
  && ok "case16 前提: 版ずれ CLI は unresolved に答え、--session だけを拒否する" \
  || bad "case16 前提: 版ずれ CLI を作れない — 以下は反証にならない"
seed run-skew A
run_stop_as "$SKEW/hooks/aidd-turn-boundary-stop.sh" B AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 2 ]] \
  && ok "case16 版ずれでは区別できないので、従来どおり全件で止める（空配列で素通ししない）" \
  || bad "case16 版ずれで停止判定が素通しになった (rc=$rc)"
reset_state c16b
post_payload 'gh workflow run v2-alpha-cd.yml --ref develop' \
  | env -u AIDD_LEDGER_SOURCE AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$SKEW/hooks/aidd-async-register.sh" >/dev/null 2>&1
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -eq 1 ]] \
  && ok "case16 版ずれでも自動登録は落とさない（登録元の記録だけを諦める）" \
  || bad "case16 版ずれで自動登録が消えた（$n 件）"

echo
echo "=== case 17: session を持たない登録は、その旨を登録した側に言う ==="
reset_state c17
env -u CLAUDE_CODE_SESSION_ID AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" \
  bash "$ASYNC" register --id run-nosession --kind cd-run --detail n >/dev/null 2>"$SB/reg.err"
grep -q "session が空" "$SB/reg.err" \
  && ok "case17 session が空の登録は stderr で注意する（黙って誰も止めない持ち越しにしない）" \
  || bad "case17 session が空でも無言: $(cat "$SB/reg.err")"
run_stop_as "$STOP_HOOK" B AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 0 ]] && grep -q "session=不明" "$SB/stop.err" \
  && ok "case17 登録元不明の持ち越しは情報として出す（止めない）" \
  || bad "case17 登録元不明の扱いが違う (rc=$rc): $(cat "$SB/stop.err")"

echo
echo "=== 変異体: 条件を外すと同じシナリオが素通しすることの実測 ==="
# 変異体はリポジトリと同じレイアウトへ置く。hooks/ の 1 つ上に scripts/ が無いと
# hook は台帳 CLI を解決できず exit 0 で素通しするため、条件を外した効果ではなく
# 「台帳が無いから通った」だけの偽 PASS になる。
MUT="$SB/mutants/hooks"
mkdir -p "$MUT" "$SB/mutants/scripts"
cp "$ASYNC" "$SB/mutants/scripts/async-work.sh"
mutate() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, needle, replacement, out = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if needle not in text:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(text.replace(needle, replacement, 1))
PY
}

if mutate "$STOP_HOOK" 'unowned = [r for r in rows if not r.get("owned") and mine(r)]' \
      'unowned = []' "$MUT/nounowned.sh"; then
  reset_state m1
  bash "$ASYNC" register --id run-m1 --kind cd-run --detail "open" >/dev/null
  if run_stop "$MUT/nounowned.sh" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
    ok "変異(未宣言持ち越し判定除去) case2 が素通しする = 判定は効いていた"
  else
    bad "変異(未宣言持ち越し判定除去) それでも拒否 = case2 は別条件が出している"
  fi
else
  bad "変異(未宣言持ち越し判定除去) 対象が見つからない — 反証不能"
fi

if mutate "$STOP_HOOK" 'if [ "$active" = "true" ]; then' 'if false; then' "$MUT/noguard.sh"; then
  reset_state m2
  bash "$ASYNC" register --id run-m2 --kind cd-run --detail "open" >/dev/null
  run_stop "$MUT/noguard.sh" true AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
  [[ "$?" -eq 2 ]] \
    && ok "変異(stop_hook_active ガード除去) 継続中も拒否する = ガードは効いていた" \
    || bad "変異(stop_hook_active ガード除去) 何も変わらない = 無限ループ防止が無い"
else
  bad "変異(stop_hook_active ガード除去) 対象が見つからない — 反証不能"
fi

if mutate "$ASYNC" 'for word in $NON_TERMINAL; do' 'for word in ; do' "$MUT/noterm.sh"; then
  reset_state m3
  env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$ASYNC" register --id run-m3 --kind cd-run --detail o >/dev/null
  if env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$MUT/noterm.sh" resolve --id run-m3 --conclusion in_progress >/dev/null 2>&1; then
    ok "変異(非終端語リスト除去) in_progress が終端として通る = リストは効いていた"
  else
    bad "変異(非終端語リスト除去) それでも拒否 = case6 は別条件が出している"
  fi
else
  bad "変異(非終端語リスト除去) 対象が見つからない — 反証不能"
fi

if mutate "$STOP_HOOK" 'unowned = [r for r in rows if not r.get("owned") and mine(r)]' \
      'unowned = [r for r in rows if not r.get("owned")]' "$MUT/allsessions.sh"; then
  reset_state m4
  seed run-m4 A
  run_stop_as "$MUT/allsessions.sh" B AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
  [[ "$?" -eq 2 ]] \
    && ok "変異(セッションで絞らない) 他セッションの持ち越しで止まる = case11 は絞り込みが作っていた" \
    || bad "変異(セッションで絞らない) それでも止まらない = case11 は別条件が出している"
else
  bad "変異(セッションで絞らない) 対象が見つからない — 反証不能"
fi

MUTR="$SB/mutants/hooks/nosession-register.sh"
if mutate "$REG_HOOK" '--source "$REGISTER_SOURCE" --session "$session"' '--source "$REGISTER_SOURCE"' "$MUTR"; then
  reset_state m5
  python3 -c 'import json; print(json.dumps({"session_id":"A","tool_input":{"command":"gh workflow run cd.yml"}}))' \
    | env -u AIDD_LEDGER_SOURCE AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$MUTR" >/dev/null 2>&1
  got=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0].get("session","") if r else "")')
  [[ "$got" != "A" ]] \
    && ok "変異(自動登録で session を渡さない) 登録元が A にならない（${got}）= case13 は受け渡しが作っていた" \
    || bad "変異(自動登録で session を渡さない) それでも A = case13 は別経路が出している"
else
  bad "変異(自動登録で session を渡さない) 対象が見つからない — 反証不能"
fi

if mutate "$STOP_HOOK" 'if ! unresolved="$(bash "$ASYNC_SH" unresolved --session "$session" 2>/dev/null)"; then' \
      'if ! unresolved="$(bash "$ASYNC_SH" unresolved --session "$session" 2>/dev/null || echo "[]")"; then' \
      "$SKEW/hooks/nofallback.sh"; then
  reset_state m6
  seed run-m6 A
  run_stop_as "$SKEW/hooks/nofallback.sh" B AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
  rc=$?
  [[ "$rc" -eq 0 ]] \
    && ok "変異(版ずれ時の再照会除去) 版ずれで素通しになる = case16 の停止は再照会が作っていた" \
    || bad "変異(版ずれ時の再照会除去) それでも止まる (rc=$rc) = case16 は別条件が出している"
else
  bad "変異(版ずれ時の再照会除去) 対象が見つからない — 反証不能"
fi

if mutate "$REG_HOOK" '    || bash "$ASYNC_SH" register --id "$ident" --kind "$kind" --detail "$detail" \
      --source "$REGISTER_SOURCE" >/dev/null 2>&1 \
' '' "$SKEW/hooks/noretry-register.sh"; then
  reset_state m7
  post_payload 'gh workflow run v2-alpha-cd.yml --ref develop' \
    | env -u AIDD_LEDGER_SOURCE AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$SKEW/hooks/noretry-register.sh" >/dev/null 2>&1
  n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  [[ "$n" -eq 0 ]] \
    && ok "変異(版ずれ時の再登録除去) 版ずれで自動登録が消える = case16 の登録は再登録が作っていた" \
    || bad "変異(版ずれ時の再登録除去) それでも登録される（$n 件）= case16 は別経路が出している"
else
  bad "変異(版ずれ時の再登録除去) 対象が見つからない — 反証不能"
fi

echo
echo "=== 適用限界の明示: この装置はターン終了後の無人区間を検知しない ==="
python3 - "$STOP_HOOK" <<'PY' && ok "限界 hook 本体に「Stop hook では代替できない」と明記されている" || bad "限界 未記載（daemon 不要と読めてしまう）"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert "常駐 daemon" in text, "no daemon limitation note"
assert "Stop hook では原理的に代替できない" in text, "limitation not stated as principled"
PY

echo "--- 変異体: source 濾過を外すと test 登録が停止判定へ戻る ---"
MUTA="$SB/mut-async.sh"
if mutate "$ASYNC" 'if not include_test and (source == "test" or source.startswith("test:")):' \
   'if False:' "$MUTA"; then
  reset_state c10c
  post_payload 'gh workflow run v2-alpha-cd.yml' \
    | env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" AIDD_LEDGER_SOURCE=test bash "$REG_HOOK" >/dev/null 2>&1
  n_mut=$(bash "$MUTA" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  [[ "$n_mut" -eq 1 ]] \
    && ok "変異(source 濾過除去) test 登録が停止判定へ戻る = 濾過は効いていた" \
    || bad "変異(source 濾過除去) 何も変わらない = case10 は別条件が出していた"
else
  bad "変異(source 濾過除去) 対象が見つからない — 反証不能"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
