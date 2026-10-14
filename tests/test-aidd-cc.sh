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

# (5) refusal is never registered as an approval (Codex P1-1 / reviewer CRITICAL)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg5","prompt":"rm -rf data は絶対に許可しない。do NOT proceed."}' | bash "$HOOK" >/dev/null
out="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg5","tool_name":"Bash","tool_input":{"command":"rm -rf data"}}' | bash "$HOOK")"
if [ -z "$out" ]; then ok "T5 refusal does not auto-allow the refused command"; else bad "T5 refusal became allow: $out"; fi

# (6) strict binding: approving feat/x never allows feat/y or a forced variant (Codex P1-2)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg6","prompt":"git push origin feat/x は承認する、進めて"}' | bash "$HOOK" >/dev/null
o1="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg6","tool_name":"Bash","tool_input":{"command":"git push origin feat/y"}}' | bash "$HOOK")"
o2="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg6","tool_name":"Bash","tool_input":{"command":"git push -f origin feat/x"}}' | bash "$HOOK")"
o3="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg6","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | bash "$HOOK")"
if [ -z "$o1" ] && [ -z "$o2" ] && printf '%s' "$o3" | grep -q '"behavior": "allow"'; then ok "T6 allow only for the exact approved command"; else bad "T6 binding too loose: y=[$o1] forced=[$o2] exact=[$o3]"; fi

# (7) a task request is not a decision; a choice question must pass (reviewer HIGH)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg7","prompt":"認証APIの設計を進めてください"}' | bash "$HOOK" >/dev/null
out="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg7","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"認証APIの設計はJWTとセッションどちらにしますか?"}]}}' | bash "$HOOK")"
if [ -z "$out" ]; then ok "T7 choice question not suppressed by the task request"; else bad "T7 over-block: $out"; fi

# (8) failing / trivial evidence does not satisfy a completion claim (reviewer HIGH)
for ev in '{"hook_event_name":"PreToolUse","session_id":"neg8","tool_name":"Bash","tool_input":{"command":"pytest -q"}}' \
          '{"hook_event_name":"PostToolUse","session_id":"neg8","tool_name":"Bash","tool_input":{"command":"pytest -q"},"tool_response":{"exit_code":1,"stdout":"1 failed"}}' \
          '{"hook_event_name":"PreToolUse","session_id":"neg8","tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
          '{"hook_event_name":"PostToolUse","session_id":"neg8","tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"exit_code":0,"stdout":"x"}}'; do printf '%s' "$ev" | bash "$HOOK" >/dev/null; done
o1="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg8","last_assistant_message":"全テスト完了。\nEvidence: pytest -q | 20 passed | 10:00"}' | bash "$HOOK")"
o2="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg8","last_assistant_message":"全テスト完了。\nEvidence: ls -la | ok | 10:00"}' | bash "$HOOK")"
if printf '%s' "$o1" | grep -q 'failed (rc=1)' && printf '%s' "$o2" | grep -q 'trivial'; then ok "T8 failing and trivial evidence both rejected"; else bad "T8: [$o1] [$o2]"; fi

# (9) readback must point at an artifact this session touched (reviewer HIGH)
sha="$(shasum -a 256 /etc/hosts | cut -c1-64)"
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg9","tool_name":"Bash","tool_input":{"command":"bash tests/ok.sh"}}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg9","tool_name":"Bash","tool_input":{"command":"bash tests/ok.sh"},"tool_response":{"exit_code":0,"stdout":"x"}}' | bash "$HOOK" >/dev/null
out="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"neg9\",\"last_assistant_message\":\"config 保存済み。完了。\\nEvidence: bash tests/ok.sh | x | 10:00\\nReadback: /etc/hosts sha256=$sha\"}" | bash "$HOOK")"
if printf '%s' "$out" | grep -q 'never written or touched'; then ok "T9 readback of an untouched file rejected"; else bad "T9: $out"; fi

# (10) honest unmet reports are not completion claims (Codex P2-7)
out="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg10","last_assistant_message":"まだ未完了です。Not done yet. 期限超過・未達。"}' | bash "$HOOK")"
if [ -z "$out" ]; then ok "T10 未完了 / not done is not a claim"; else bad "T10 over-block: $out"; fi

# (11) the loop guard never passes silently: max-blocks and stop_hook_active leave ledger rows
for i in 1 2 3; do printf '%s' '{"hook_event_name":"Stop","session_id":"neg11","last_assistant_message":"完了です。"}' | AIDD_CC_MAX_STOP_BLOCKS=2 bash "$HOOK" >/dev/null; done
printf '%s' '{"hook_event_name":"Stop","session_id":"neg11","stop_hook_active":true,"last_assistant_message":"完了です。"}' | bash "$HOOK" >/dev/null
if grep -q '"rule": "evidence.max-blocks"' "$AIDD_LEDGER_PATH" && grep -q '"rule": "evidence.loop-guard"' "$AIDD_LEDGER_PATH"; then ok "T11 loop-guard passes are visible in the H6 ledger"; else bad "T11 silent pass"; fi

# (12) Codex `cmd` input is normalised (Codex P1-3); (13) a crash is visible, not a pass
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg12","tool_name":"exec_command","tool_input":{"cmd":"bash tests/real.sh"},"tool_response":{"exit_code":0,"stdout":"ok"}}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null
out="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg12","last_assistant_message":"完了。\nEvidence: bash tests/real.sh | ok | 10:00"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
if [ -z "$out" ]; then ok "T12 Codex cmd field binds evidence"; else bad "T12: $out"; fi
printf '%s' '{"hook_event_name":"Stop","session_id":"neg12b","last_assistant_message":"完了です。"}' | AIDD_CC_STATE_DIR=/dev/null/nope bash "$HOOK" >/dev/null
if grep -q '"event": "error"' "$AIDD_LEDGER_PATH"; then ok "T13 crash recorded as H6 error row (no silent pass)"; else bad "T13 crash not recorded"; fi

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
