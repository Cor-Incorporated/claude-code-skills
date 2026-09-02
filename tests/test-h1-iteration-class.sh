#!/usr/bin/env bash
# H1 反復の意味分類 — hooks/lib/h1-iteration-class.py の反証テスト.
#
# Issue: Cor-Incorporated/aidd-governance#87
#
# 起点事故 (2026-08-23, Grift Nagi UAT #2049): 固定 3 反復の契約で 3 つの異なる
# counterexample を RED→GREEN 化した直後、独立 review が固定 scope 内の新しい P1
# を発見した。回数だけは 3/3 のため通常 STOP した。同一失敗ループではなく oracle
# が強化された直後の停止であり、「後段の反証を省略した方が早く進む」という逆
# インセンティブを生んだ。
#
# 本スイートは #87「機械反証」10 項目をそのまま 10 ケースに写したものである。
# 加えて、各判定条件について **その条件を削除した変異体では同じシナリオの判定が
# 変わる** ことを実測する。削除しても何も変わらない条件は、最初から強制されて
# いない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$ROOT/hooks/lib/h1-iteration-class.py"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# record <key=value>... — 反復レコード JSON を組み立てる。
# 既定は「実装変更あり・固定 scope 内・再現可能な RED」の健全な 1 反復。
record() {
  python3 - "$@" <<'PY'
import json, sys
rec = {
    "implementation_changed": True,
    "invariant": "saved-plan validator rejects unknown after_unknown markers",
    "oracle_id": "terraform-saved-plan-negative-oracle",
    "counterexample": "malformed marker with fixed project",
    "red_evidence": "probe: malformed marker ACCEPTED where reject was expected",
    "max_iterations": 3,
    "close_target": "Grift#2049",
    "reserved_successor": "Grift#2006",
}
for arg in sys.argv[1:]:
    key, _, value = arg.partition("=")
    if value in ("true", "false"):
        rec[key] = value == "true"
    elif value.lstrip("-").isdigit():
        rec[key] = int(value)
    elif value.startswith("["):
        rec[key] = json.loads(value)
    else:
        rec[key] = value
print(json.dumps(rec))
PY
}

# classify <module> <state-file> <record-json> — verdict JSON を stdout へ。
classify() {
  printf '%s' "$3" | python3 "$1" classify --state "$2"
}

field() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)[sys.argv[1]])
except Exception:
    print("ERR")
' "$2"
}

fresh_state() {
  local path="$SB/state-$1.json"
  shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
sem = {}
for arg in sys.argv[2:]:
    key, _, value = arg.partition("=")
    sem[key] = value == "true" if value in ("true", "false") else (
        int(value) if value.lstrip("-").isdigit() else value
    )
json.dump({"h1_semantics": sem} if sem else {}, open(path, "w"))
PY
  printf '%s' "$path"
}

# mutate <needle> <replacement> <out> — 1 条件を外した変異体を作る。
mutate() {
  python3 - "$MOD" "$1" "$2" "$3" <<'PY'
import sys
src, needle, replacement, out = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if needle not in text:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(text.replace(needle, replacement, 1))
PY
}

echo "=== #87 機械反証 1: 同一 fingerprint・同一 oracle を 3 回 -> STOP ==="
S=$(fresh_state f1)
for i in 1 2 3; do V=$(classify "$MOD" "$S" "$(record)"); done
[[ "$(field "$V" transition)" == "STOP" ]] \
  && ok "反証1 同一失敗 3 回目が STOP" \
  || bad "反証1 期待 STOP, 実際 $(field "$V" transition)"
[[ "$(field "$V" classification)" == "same_failure" ]] \
  && ok "反証1 classification=same_failure" \
  || bad "反証1 期待 same_failure, 実際 $(field "$V" classification)"

echo
echo "=== #87 機械反証 2: 3 反例を GREEN 化し上限到達時に新 P1 -> REBASE_REQUIRED ==="
echo "    (Grift #2049 replay — 完了条件「3/3 後の新 P1 が通常 STOP ではない」)"
S=$(fresh_state f2)
for c in cx-a cx-b cx-c; do
  V=$(classify "$MOD" "$S" "$(record "counterexample=$c")")
  [[ "$(field "$V" transition)" == "CONTINUE" ]] || bad "反証2 予算内 $c が CONTINUE でない"
done
V=$(classify "$MOD" "$S" "$(record counterexample=independent-review-P1)")
[[ "$(field "$V" transition)" == "REBASE_REQUIRED" ]] \
  && ok "反証2 3/3 後の新 P1 が REBASE_REQUIRED（通常 STOP ではない）" \
  || bad "反証2 期待 REBASE_REQUIRED, 実際 $(field "$V" transition)"
[[ "$(field "$V" classification)" == "novel_counterexample" ]] \
  && ok "反証2 classification=novel_counterexample" \
  || bad "反証2 期待 novel_counterexample, 実際 $(field "$V" classification)"

echo
echo "=== #87 機械反証 3: エラーメッセージ文言だけ変える -> 同一 fingerprint ==="
A=$(printf '%s' "$(record error_message=AssertionError:expected-reject-got-accept)" | python3 "$MOD" fingerprint)
B=$(printf '%s' "$(record 'error_message=panic: totally different explosion text here')" | python3 "$MOD" fingerprint)
[[ "$A" == "$B" ]] \
  && ok "反証3 error_message が違っても fingerprint 同一 ($A)" \
  || bad "反証3 fingerprint が分岐した: $A vs $B"
S=$(fresh_state f3)
V=$(classify "$MOD" "$S" "$(record error_message=first)")
V=$(classify "$MOD" "$S" "$(record error_message=second-and-entirely-different)")
[[ "$(field "$V" classification)" == "same_failure" ]] \
  && ok "反証3 予算 reset なし（same_failure 扱い）" \
  || bad "反証3 期待 same_failure, 実際 $(field "$V" classification)"

echo
echo "=== #87 機械反証 4: 一つの失敗を複数 fixture へ分割 -> 同一 fingerprint ==="
A=$(printf '%s' "$(record 'fixtures=["tests/a_test.go"]')" | python3 "$MOD" fingerprint)
B=$(printf '%s' "$(record 'fixtures=["tests/b1_test.go","tests/b2_test.go","tests/b3_test.go"]')" | python3 "$MOD" fingerprint)
[[ "$A" == "$B" ]] \
  && ok "反証4 fixture 分割で fingerprint は増えない" \
  || bad "反証4 fingerprint が分岐した: $A vs $B"

echo
echo "=== #87 機械反証 5: close target / 要求インベントリ外の finding -> owner decision ==="
S=$(fresh_state f5)
V=$(classify "$MOD" "$S" "$(record 'requirement_inventory=["req-A","req-B"]' requirement=req-A)")
[[ "$(field "$V" transition)" == "CONTINUE" ]] \
  && ok "反証5 インベントリ内の要求は CONTINUE" \
  || bad "反証5 インベントリ内なのに $(field "$V" transition)"
V=$(classify "$MOD" "$S" "$(record counterexample=out-of-scope requirement=req-UNLISTED)")
[[ "$(field "$V" classification)" == "scope_expansion" && "$(field "$V" transition)" == "STOP" ]] \
  && ok "反証5 インベントリ外の finding が scope_expansion/STOP" \
  || bad "反証5 期待 scope_expansion/STOP, 実際 $(field "$V" classification)/$(field "$V" transition)"

echo
echo "=== #87 機械反証 6: security/不可逆 -> 進捗の有無に関係なく即時 STOP ==="
S=$(fresh_state f6 recovery_epoch_preapproved=true)
V=$(classify "$MOD" "$S" "$(record counterexample=brand-new-and-novel security_or_irreversible=true security_detail=credential-in-tool-output)")
[[ "$(field "$V" classification)" == "security_or_irreversible" && "$(field "$V" transition)" == "STOP" ]] \
  && ok "反証6 新反例かつ recovery epoch 承認済みでも即時 STOP" \
  || bad "反証6 期待 security_or_irreversible/STOP, 実際 $(field "$V" classification)/$(field "$V" transition)"
[[ "$(field "$V" rebase_granted)" == "False" ]] \
  && ok "反証6 security は recovery epoch を消費しない" \
  || bad "反証6 security なのに rebase が granted された"

echo
echo "=== #87 機械反証 7: rebase 前後で close target / reserved successor が変わる -> RED ==="
S=$(fresh_state f7)
V=$(classify "$MOD" "$S" "$(record)")
V=$(classify "$MOD" "$S" "$(record counterexample=cx-2 close_target=Grift#9999)")
[[ "$(field "$V" classification)" == "scope_expansion" && "$(field "$V" transition)" == "STOP" ]] \
  && ok "反証7 close_target 変化が scope_expansion/STOP" \
  || bad "反証7 期待 scope_expansion/STOP, 実際 $(field "$V" classification)/$(field "$V" transition)"
S=$(fresh_state f7b)
V=$(classify "$MOD" "$S" "$(record)")
V=$(classify "$MOD" "$S" "$(record counterexample=cx-2 reserved_successor=Grift#7777)")
[[ "$(field "$V" classification)" == "scope_expansion" ]] \
  && ok "反証7 reserved_successor 変化も scope_expansion" \
  || bad "反証7 reserved_successor 変化が素通し: $(field "$V" classification)"

echo
echo "=== #87 機械反証 8: PR数/LOC/tool call数/review件数だけで novel にならない ==="
S=$(fresh_state f8)
V=$(classify "$MOD" "$S" "$(record counterexample=volume-claim 'red_evidence=3 PRs, 420 LOC, 17 tool calls, 5 reviews')")
[[ "$(field "$V" classification)" != "novel_counterexample" ]] \
  && ok "反証8 量的指標だけの red_evidence は novel にならない ($(field "$V" classification))" \
  || bad "反証8 量的指標だけで novel_counterexample になった"
V=$(classify "$MOD" "$S" "$(record counterexample=volume-claim-2 red_evidence=)")
[[ "$(field "$V" classification)" != "novel_counterexample" ]] \
  && ok "反証8 red_evidence 空欄も novel にならない" \
  || bad "反証8 red_evidence 空欄で novel になった"

echo
echo "=== #87 機械反証 9: recovery epoch を無制限に追加できない ==="
S=$(fresh_state f9 recovery_epoch_preapproved=true)
for c in a b c d; do V=$(classify "$MOD" "$S" "$(record "counterexample=cx-$c")"); done
[[ "$(field "$V" rebase_granted)" == "True" && "$(field "$V" epoch)" == "2" ]] \
  && ok "反証9 事前承認済み epoch を 1 回だけ消費して epoch 2 へ" \
  || bad "反証9 1 回目の rebase が成立しない: granted=$(field "$V" rebase_granted) epoch=$(field "$V" epoch)"
for c in e f g h; do V=$(classify "$MOD" "$S" "$(record "counterexample=cx-$c")"); done
[[ "$(field "$V" transition)" == "STOP" ]] \
  && ok "反証9 epoch 上限枯渇後は STOP（無制限に足せない）" \
  || bad "反証9 epoch 2 で上限到達後も $(field "$V" transition)"
[[ "$(field "$V" epoch)" == "2" ]] \
  && ok "反証9 epoch が 3 へ増えていない" \
  || bad "反証9 epoch が $(field "$V" epoch) まで増えた"

echo
echo "=== #87 機械反証 10: REBASE_REQUIRED を通常完了・Issue closeable として扱わない ==="
S=$(fresh_state f10)
for c in a b c; do V=$(classify "$MOD" "$S" "$(record "counterexample=cx-$c")"); done
V=$(classify "$MOD" "$S" "$(record counterexample=late-P1)")
[[ "$(field "$V" transition)" == "REBASE_REQUIRED" ]] || bad "反証10 前提の REBASE_REQUIRED が出ていない"
[[ "$(field "$V" completion)" == "False" && "$(field "$V" issue_closeable)" == "False" ]] \
  && ok "反証10 verdict の completion / issue_closeable が False" \
  || bad "反証10 completion=$(field "$V" completion) issue_closeable=$(field "$V" issue_closeable)"
printf '実装は完了しました。Issue を close します。\n' >"$SB/report-bad.txt"
if python3 "$MOD" check-report --state "$S" --report "$SB/report-bad.txt" >/dev/null 2>&1; then
  bad "反証10 完了語彙を含む REBASE_REQUIRED 報告が素通しした"
else
  ok "反証10 完了語彙を含む報告を check-report が非ゼロで弾いた"
fi
printf 'REBASE_REQUIRED。supervisor の再承認を待って epoch 2 を開始する。\n' >"$SB/report-ok.txt"
if python3 "$MOD" check-report --state "$S" --report "$SB/report-ok.txt" >/dev/null 2>&1; then
  ok "反証10 完了語彙のない報告は通す（恒真 red ではない）"
else
  bad "反証10 正しい報告まで弾いた"
fi

echo
echo "=== 非算入: verification_only は実装反復へ算入しない ==="
S=$(fresh_state fv)
V=$(classify "$MOD" "$S" "$(record implementation_changed=false)")
[[ "$(field "$V" classification)" == "verification_only" && "$(field "$V" implementation_iterations)" == "0" ]] \
  && ok "verification_only が反復 0 のまま CONTINUE" \
  || bad "verification_only が算入された: $(field "$V" implementation_iterations)"

echo
echo "=== 変異体: 条件を 1 つ外すと同じシナリオの判定が変わることの実測 ==="
MUT="$SB/mutants"
mkdir -p "$MUT"

# (1) 数字正規化を外す -> 件数違いが別 fingerprint に割れる
if mutate 'value = _DIGITS_RE.sub("#", value)' 'pass' "$MUT/digits.py"; then
  A=$(printf '%s' "$(record 'counterexample=6/6 markers ACCEPTED')" | python3 "$MUT/digits.py" fingerprint)
  B=$(printf '%s' "$(record 'counterexample=12/12 markers ACCEPTED')" | python3 "$MUT/digits.py" fingerprint)
  [[ "$A" != "$B" ]] \
    && ok "変異(数字正規化除去) 件数違いが別 fingerprint に割れる = 正規化は効いていた" \
    || bad "変異(数字正規化除去) 何も変わらない = 正規化は最初から効いていない"
else
  bad "変異(数字正規化除去) 対象が見つからない — 反証不能"
fi

# (2) fingerprint に error_message を混ぜる -> 反証 3 が破れる
if mutate '_norm(record.get("counterexample")),' '_norm(record.get("counterexample")), _norm(record.get("error_message")),' "$MUT/errmsg.py"; then
  A=$(printf '%s' "$(record error_message=first)" | python3 "$MUT/errmsg.py" fingerprint)
  B=$(printf '%s' "$(record error_message=second)" | python3 "$MUT/errmsg.py" fingerprint)
  [[ "$A" != "$B" ]] \
    && ok "変異(error_message 混入) 反証3 が破れる = 構造的除外は効いていた" \
    || bad "変異(error_message 混入) 何も変わらない = 除外は最初から無意味"
else
  bad "変異(error_message 混入) 対象が見つからない — 反証不能"
fi

# (3) 同一失敗閾値を外す -> 反証 1 の STOP が消える
if mutate 'if occurrences >= SAME_FAILURE_THRESHOLD:' 'if False:' "$MUT/streak.py"; then
  S=$(fresh_state m3)
  for i in 1 2 3; do V=$(classify "$MUT/streak.py" "$S" "$(record)"); done
  [[ "$(field "$V" transition)" != "STOP" ]] \
    && ok "変異(同一失敗閾値除去) 3 回目が STOP しない = 閾値は効いていた" \
    || bad "変異(同一失敗閾値除去) それでも STOP = 反証1 は別条件が出している"
else
  bad "変異(同一失敗閾値除去) 対象が見つからない — 反証不能"
fi

# (4) 量的指標判定を外す -> 反証 8 が破れる
if mutate 'return bool(_VOLUME_ONLY_RE.match(text))' 'return False' "$MUT/volume.py"; then
  S=$(fresh_state m4)
  V=$(classify "$MUT/volume.py" "$S" "$(record counterexample=v 'red_evidence=3 PRs, 420 LOC, 17 tool calls')")
  [[ "$(field "$V" classification)" == "novel_counterexample" ]] \
    && ok "変異(量的指標判定除去) 量だけで novel になる = 判定は効いていた" \
    || bad "変異(量的指標判定除去) 何も変わらない = 反証8 は素通しだった"
else
  bad "変異(量的指標判定除去) 対象が見つからない — 反証不能"
fi

# (5) epoch 上限を外す -> 反証 9 が破れ epoch が 3 以上へ伸びる
if mutate 'elif epoch >= max_epochs:' 'elif False:' "$MUT/epoch.py"; then
  S=$(fresh_state m5 recovery_epoch_preapproved=true)
  for c in a b c d e f g h i; do V=$(classify "$MUT/epoch.py" "$S" "$(record "counterexample=cx-$c")"); done
  [[ "$(field "$V" transition)" != "STOP" ]] \
    && ok "変異(epoch 上限除去) 枯渇後も STOP しない = 上限は効いていた" \
    || bad "変異(epoch 上限除去) それでも STOP = 反証9 は別条件が出している"
else
  bad "変異(epoch 上限除去) 対象が見つからない — 反証不能"
fi

# (6) scope drift 検出を外す -> 反証 5/7 が破れる
if mutate '    drift: list[str] = []' '    return []' "$MUT/scope.py"; then
  S=$(fresh_state m6)
  V=$(classify "$MUT/scope.py" "$S" "$(record)")
  V=$(classify "$MUT/scope.py" "$S" "$(record counterexample=cx-2 close_target=Grift#9999)")
  [[ "$(field "$V" classification)" != "scope_expansion" ]] \
    && ok "変異(scope drift 除去) close_target 変化が素通し = 検出は効いていた" \
    || bad "変異(scope drift 除去) それでも検出 = 反証5/7 は別条件が出している"
else
  bad "変異(scope drift 除去) 対象が見つからない — 反証不能"
fi

# (7) security 分岐を外す -> 反証 6 が破れる
if mutate 'if _truthy(record.get("security_or_irreversible")):' 'if False:' "$MUT/sec.py"; then
  S=$(fresh_state m7)
  V=$(classify "$MUT/sec.py" "$S" "$(record security_or_irreversible=true)")
  [[ "$(field "$V" classification)" != "security_or_irreversible" ]] \
    && ok "変異(security 分岐除去) 即時 STOP が消える = 分岐は効いていた" \
    || bad "変異(security 分岐除去) それでも STOP = 反証6 は別条件が出している"
else
  bad "変異(security 分岐除去) 対象が見つからない — 反証不能"
fi

echo
echo "=== 統合: hooks/codex/h1-stall-runtime.sh の反復上限が 3 値遷移を読むこと ==="
echo "    (#87 完了条件「H1 の『新規エラー種別は進捗』と『最大反復到達』の矛盾を解消する」)"
HOOK="$ROOT/hooks/codex/h1-stall-runtime.sh"
HSB="$SB/hookhome"
mkdir -p "$HSB/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HSB/.claude/hooks/lib/aidd-ledger.sh"
LEDGER="$HSB/.claude/hooks/ledger/guard-ledger.jsonl"
export AIDD_LEDGER_SOURCE=test

# hook_run <hook> <delegation> <cmd> — Codex PreToolUse 呼び出しを 1 回再現する。
hook_run() {
  local hook="$1" delegation="$2" cmd="$3"
  shift 3
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd" \
    | env HOME="$HSB" \
        CODEX_H1_DELEGATION="$delegation" \
        CODEX_H1_SESSIONS_DIR="$HSB/no-sessions" \
        CODEX_H1_MAX_ITERATIONS=3 \
        "$@" bash "$hook"
}

decision_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("hookSpecificOutput", {}).get("permissionDecision", "allow"))
except Exception:
    print("malformed")
'
}

# seed_hook_state <delegation> [semantics key=value...] — H1 state に相乗りさせる。
seed_hook_state() {
  local delegation="$1"
  shift
  python3 - "$HSB" "$delegation" "$@" <<'PY'
import json, os, sys, time
home, delegation = sys.argv[1:3]
now = int(time.time())
sem = {}
for arg in sys.argv[3:]:
    key, _, value = arg.partition("=")
    sem[key] = value == "true" if value in ("true", "false") else (
        int(value) if value.lstrip("-").isdigit() else value
    )
state = {
    "delegation": delegation, "started_ts": now, "last_progress_ts": now,
    "iterations": 0, "tool_calls": 0, "spend_tokens": 0, "spend_usd": 0.0,
    "budget_usd": 5.0, "budget_source": "proxy:toolcalls", "max_iterations": 3,
    "no_progress_sec": 2700, "last_cmd_sha256": "", "same_cmd_streak": 0,
    "last_warn_80": 0, "last_heartbeat_ts": now, "last_block_rule": "",
    "last_block_ts": 0,
}
if sem:
    state["h1_semantics"] = sem
d = os.path.join(home, ".codex", "hooks", "h1-state")
os.makedirs(d, exist_ok=True)
json.dump(state, open(os.path.join(d, delegation + ".json"), "w"))
PY
}

# 反復を上限超過まで積む（同一コマンド反復が hook の iterations を進める）。
drive_over_cap() {
  local hook="$1" delegation="$2" out=""
  for _ in 1 2 3 4 5; do out=$(hook_run "$hook" "$delegation" "rg --files"); done
  printf '%s' "$out"
}

# (a) 宣言なし -> 従来どおり max-iterations で STOP（fail-safe の非回帰）
seed_hook_state h_none
OUT=$(drive_over_cap "$HOOK" h_none)
[[ "$(decision_of "$OUT")" == "deny" ]] \
  && ok "統合 意味分類の宣言なしは従来どおり deny" \
  || bad "統合 宣言なしで deny しなかった（上限が抜け道になっている）"
if grep -q '"rule":"max-iterations"' "$LEDGER" 2>/dev/null; then
  ok "統合 宣言なしの台帳 rule=max-iterations"
else
  bad "統合 宣言なしの台帳に max-iterations 行がない"
fi

# (b) REBASE_REQUIRED 宣言 -> 別ルール rebase-required で deny
seed_hook_state h_rebase transition=REBASE_REQUIRED classification=novel_counterexample \
  epoch=1 close_target=Grift#2049 last_fingerprint=deadbeefcafe last_oracle_id=tf-plan-oracle
OUT=$(drive_over_cap "$HOOK" h_rebase)
[[ "$(decision_of "$OUT")" == "deny" ]] \
  && ok "統合 REBASE_REQUIRED も停止はする（上限撤廃ではない）" \
  || bad "統合 REBASE_REQUIRED が素通しした"
REASON=$(printf '%s' "$OUT" | python3 -c '
import json,sys
print(json.load(sys.stdin).get("hookSpecificOutput",{}).get("permissionDecisionReason",""))')
case "$REASON" in
  *rebase-required*) ok "統合 deny 理由が rebase-required（max-iterations と別ルール）" ;;
  *) bad "統合 deny 理由に rebase-required がない: $REASON" ;;
esac
case "$REASON" in
  *"完了ではなく"*"close 可でもない"*)
    ok "統合 deny 理由が「完了でも Issue close 可でもない」と明示（反証10 の実行時側）" ;;
  *) bad "統合 deny 理由に完了否認の文言がない: $REASON" ;;
esac
if grep -q '"rule":"rebase-required"' "$LEDGER" 2>/dev/null; then
  ok "統合 台帳に rule=rebase-required 行"
else
  bad "統合 台帳に rebase-required 行がない"
fi
python3 - "$LEDGER" <<'PY' && ok "統合 台帳行が iteration_semantics を機械可読で載せる (#87 要求4)" || bad "統合 台帳行に iteration_semantics がない"
import json, sys
rows = [json.loads(x) for x in open(sys.argv[1], encoding="utf-8") if x.strip()]
rows = [r for r in rows if r.get("rule") == "rebase-required"]
assert rows, "no rebase-required row"
sem = rows[-1]["subject"]["iteration_semantics"]
for key in ("failure_fingerprint", "oracle_id", "classification", "epoch",
            "close_target", "transition"):
    assert key in sem, key
assert sem["transition"] == "REBASE_REQUIRED", sem
assert sem["classification"] == "novel_counterexample", sem
PY

# (c) rebase 済み (iteration_baseline あり) -> 新 epoch の反復だけが数えられ allow
seed_hook_state h_granted transition=CONTINUE classification=novel_counterexample \
  epoch=2 iteration_baseline=99
OUT=$(drive_over_cap "$HOOK" h_granted)
[[ "$(decision_of "$OUT")" == "allow" ]] \
  && ok "統合 rebase 後は基準線を引いた反復で判定し allow" \
  || bad "統合 rebase 後も deny（基準線が効いていない）"

# (d) 宣言が CONTINUE でも基準線が無ければ実体側で止める
seed_hook_state h_stale transition=CONTINUE classification=novel_counterexample epoch=1
OUT=$(drive_over_cap "$HOOK" h_stale)
[[ "$(decision_of "$OUT")" == "deny" ]] \
  && ok "統合 CONTINUE 宣言だけでは上限を越えられない（宣言 > 実体にしない）" \
  || bad "統合 CONTINUE と書くだけで上限が無効化された"

echo
echo "--- 変異体(統合): 基準線の減算を外すと (c) が deny へ戻る ---"
MUTHOOK="$MUT/hook-baseline.sh"
if mutate '    effective = int(state["iterations"]) - baseline' '    effective = int(state["iterations"])' "$MUTHOOK" ; then
  :
else
  # mutate() は $MOD 固定なので hook 用に直接置換する
  python3 - "$HOOK" "$MUTHOOK" <<'PY'
import sys
src, out = sys.argv[1:3]
text = open(src, encoding="utf-8").read()
needle = '    effective = int(state["iterations"]) - baseline'
assert needle in text, "baseline subtraction not found"
open(out, "w", encoding="utf-8").write(
    text.replace(needle, '    effective = int(state["iterations"])', 1))
PY
fi
if [[ -s "$MUTHOOK" ]]; then
  seed_hook_state h_mut transition=CONTINUE classification=novel_counterexample \
    epoch=2 iteration_baseline=99
  OUT=$(drive_over_cap "$MUTHOOK" h_mut)
  [[ "$(decision_of "$OUT")" == "deny" ]] \
    && ok "変異(基準線減算除去) rebase 後も deny へ戻る = 基準線は効いていた" \
    || bad "変異(基準線減算除去) 何も変わらない = 基準線は最初から無意味"
else
  bad "変異(基準線減算除去) 変異体を作れない — 反証不能"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
