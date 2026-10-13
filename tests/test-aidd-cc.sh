#!/usr/bin/env bash
# H17 common control — negative tests (aidd-governance#174).
# NEGATIVE-TEST-FOR: hooks/aidd-cc-claude.sh
#
# 起点事故: 2026-10-12/13 の dot 実運用。既存 H3 は warn のみで、証拠なしの
# 「完了」でターンが終わり、同一コマンドの反復と既決事項の再質問を誰も止めなかった。
#
# Falsifiability: (1) 元の hook は証拠なし完了宣言を block する。(2) このファイルが
# 書き出す変異体（evidence trailer 検査を外した aidd_cc_controls.py）は同じ入力で
# allow する。(3) tests/dot-replay の 47 ケースで LOCAL 全件の 4 腕ゲートが通る。
# 全て HOME 外の sandbox で走り、本番台帳・state には触れない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test AIDD_LEDGER_PATH="$SB/ledger.jsonl" AIDD_CC_STATE_DIR="$SB/state" AIDD_CC_MAX_STOP_BLOCKS=99
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

HOOK="$ROOT/hooks/aidd-cc-claude.sh"
CLAIM='{"hook_event_name":"Stop","session_id":"neg1","last_assistant_message":"実装完了しました。"}'

# (1) original blocks an evidence-free completion claim
out="$(printf '%s' "$CLAIM" | bash "$HOOK")"
if printf '%s' "$out" | grep -q '"decision": "block"'; then ok "T1 original blocks evidence-free 完了 (DOT-INC-010)"; else bad "T1 original did not block: $out"; fi

# (2) mutant: same hook tree, evidence-trailer check removed -> must ALLOW
MUTANT_DIR="$SB/mutant"
mkdir -p "$MUTANT_DIR/lib"
cp "$ROOT/hooks/aidd-cc-claude.sh" "$MUTANT_DIR/aidd-cc-claude.sh"
cp "$ROOT"/hooks/lib/aidd_cc*.py "$ROOT/hooks/lib/aidd-cc-adapter.sh" "$MUTANT_DIR/lib/"
MUTANT="$MUTANT_DIR/aidd-cc-claude.sh"
MUTANT_CTRL="$MUTANT_DIR/lib/aidd_cc_controls.py"
python3 - "$ROOT/hooks/lib/aidd_cc_controls.py" "$MUTANT_CTRL" "$MUTANT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = 'if not cmds and not mutated("evidence.trailer"):'
assert needle in text, "mutation anchor missing"
open(dst, "w", encoding="utf-8").write(text.replace(needle, "if False:"))
PY
out="$(printf '%s' "$CLAIM" | bash "$MUTANT")"
if printf '%s' "$out" | grep -q '"decision": "block"'; then bad "T2 mutant still blocks (check is not the enforcing line)"; else ok "T2 mutant (trailer check removed) allows -> original line is load-bearing"; fi

# (3) benign progress report passes the original (no over-blocking)
out="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg2","last_assistant_message":"途中経過です。次に tests を走らせます。"}' | bash "$HOOK")"
if [ -z "$out" ]; then ok "T3 benign progress report not blocked"; else bad "T3 benign report blocked: $out"; fi

# (4) 47-case replay, repo-path entries: every LOCAL case must pass all four arms
if python3 -I "$ROOT/tests/dot-replay/run_replay.py" --out "$SB/replay" >"$SB/replay.log" 2>&1; then
  ok "T4 dot-replay: all LOCAL cases pass before/fixed/mutation/positive-control ($(grep -c GATE-OK "$SB/replay.log") cases)"
else
  bad "T4 dot-replay gate failure:"; grep -E "GATE-FAIL|denominator" "$SB/replay.log" | head -20
fi

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
