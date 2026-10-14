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

# (14) Japanese refusal without an English `not`; (15) prefix target; (16) revocation (Codex r2 P1)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg14","prompt":"rm -rf data は承認していません。"}' | bash "$HOOK" >/dev/null
o14="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg14","tool_name":"Bash","tool_input":{"command":"rm -rf data"}}' | bash "$HOOK")"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg15","prompt":"rm -rf data/archive は承認、進めて"}' | bash "$HOOK" >/dev/null
o15="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg15","tool_name":"Bash","tool_input":{"command":"rm -rf data"}}' | bash "$HOOK")"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg16","prompt":"git push origin feat/x は承認、進めて"}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg16","prompt":"前の承認は取り消します。実行しないでください"}' | bash "$HOOK" >/dev/null
o16="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg16","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | bash "$HOOK")"
if [ -z "$o14" ] && [ -z "$o15" ] && [ -z "$o16" ]; then ok "T14-16 Japanese refusal / prefix target / revocation never allow"; else bad "T14-16: [$o14] [$o15] [$o16]"; fi

# (17) unavailable exit status is UNKNOWN, not success (Codex r2 P1-d) — string tool_response via the Codex entry
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg17","tool_name":"exec_command","tool_input":{"cmd":"pytest -q"},"tool_response":"1 failed, 3 passed"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null
o17="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg17","last_assistant_message":"全テスト完了。\nEvidence: pytest -q | 20 passed | 10:00"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
if printf '%s' "$o17" | grep -q 'unavailable'; then ok "T17 unavailable exit status is UNKNOWN"; else bad "T17: $o17"; fi

# (18) Codex request_user_input is a re-ask; (19) quoted separator is not execution; (20) `not merged` is not a claim
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg18","prompt":"PR作成は承認、進めて"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null
o18="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg18","tool_name":"request_user_input","tool_input":{"questions":[{"question":"PR作成を進めてよいですか？"}]}}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg19","tool_name":"Bash","tool_input":{"command":"printf %s pass;pytest -q"}}' | bash "$HOOK" >/dev/null
printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"neg19\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf '%s' 'pass;pytest -q'\"},\"tool_response\":{\"exit_code\":0,\"stdout\":\"x\"}}" | bash "$HOOK" >/dev/null
o19="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg19","last_assistant_message":"完了。\nEvidence: pytest -q | 20 passed | 10:00"}' | bash "$HOOK")"
o20="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg20","last_assistant_message":"not merged, not deployed, 未保存です。未達。"}' | bash "$HOOK")"
if printf '%s' "$o18" | grep -q 'already-answered\|already decided' && printf '%s' "$o19" | grep -q 'not executed' && [ -z "$o20" ]; then ok "T18-20 request_user_input re-ask blocked / quoted separator not execution / negated claims pass"; else bad "T18-20: [$o18] [$o19] [$o20]"; fi

# (21) a destructive / production question is never suppressed (reviewer-d new 1)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg21","prompt":"認証APIの設計を進めてください"}' | bash "$HOOK" >/dev/null
o21="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg21","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"認証APIの設計で本番DBを削除してもいいですか?"}]}}' | bash "$HOOK")"
if [ -z "$o21" ]; then ok "T21 destructive question not suppressed"; else bad "T21: $o21"; fi

# (22) prefix is not execution: `pytest -q --co` (rc 0) does not satisfy `pytest -q` (reviewer-d #7)
for ev in '{"hook_event_name":"PreToolUse","session_id":"neg22","tool_name":"Bash","tool_input":{"command":"pytest -q --co"}}' \
          '{"hook_event_name":"PostToolUse","session_id":"neg22","tool_name":"Bash","tool_input":{"command":"pytest -q --co"},"tool_response":{"exit_code":0,"stdout":"collected"}}'; do printf '%s' "$ev" | bash "$HOOK" >/dev/null; done
o22="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg22","last_assistant_message":"全テスト完了。\nEvidence: pytest -q | 20 passed | 10:00"}' | bash "$HOOK")"
if printf '%s' "$o22" | grep -q 'not executed'; then ok "T22 prefix match is not execution"; else bad "T22: $o22"; fi

# (23) mentioning a path (cat) does not make it a written artifact (reviewer-d #8)
sha="$(shasum -a 256 /etc/hosts | cut -c1-64)"
for ev in '{"hook_event_name":"PreToolUse","session_id":"neg23","tool_name":"Bash","tool_input":{"command":"cat /etc/hosts"}}' \
          '{"hook_event_name":"PostToolUse","session_id":"neg23","tool_name":"Bash","tool_input":{"command":"cat /etc/hosts"},"tool_response":{"exit_code":0,"stdout":"x"}}' \
          '{"hook_event_name":"PreToolUse","session_id":"neg23","tool_name":"Bash","tool_input":{"command":"bash tests/ok.sh"}}' \
          '{"hook_event_name":"PostToolUse","session_id":"neg23","tool_name":"Bash","tool_input":{"command":"bash tests/ok.sh"},"tool_response":{"exit_code":0,"stdout":"x"}}'; do printf '%s' "$ev" | bash "$HOOK" >/dev/null; done
o23="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"neg23\",\"last_assistant_message\":\"config 保存済み。完了。\\nEvidence: bash tests/ok.sh | x | 10:00\\nReadback: /etc/hosts sha256=$sha\"}" | bash "$HOOK")"
if printf '%s' "$o23" | grep -q 'never written'; then ok "T23 cat-mention does not count as writing"; else bad "T23: $o23"; fi

# (24) hedges / won't never register; the short reply OK does (reviewer-d new 3)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg24","prompt":"git push origin feat/x: OK? 考え中"}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg24","prompt":"I will not approve git push origin feat/x"}' | bash "$HOOK" >/dev/null
o24a="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg24","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | bash "$HOOK")"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg24b","prompt":"git push origin feat/x OK"}' | bash "$HOOK" >/dev/null
o24b="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg24b","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | bash "$HOOK")"
if [ -z "$o24a" ] && printf '%s' "$o24b" | grep -q '"behavior": "allow"'; then ok "T24 hedge/won't never bind; explicit OK binds"; else bad "T24: [$o24a] [$o24b]"; fi

# (25) 5 identical Edits are blocked at the 4th; 5 different edits are not (reviewer-d new 2 / #5)
for i in 1 2 3; do printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg25","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.py","old_string":"a","new_string":"b"}}' | bash "$HOOK" >/dev/null; done
o25a="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg25","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.py","old_string":"a","new_string":"b"}}' | bash "$HOOK")"
for i in 1 2 3 4; do printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"neg25b\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/x.py\",\"old_string\":\"a$i\",\"new_string\":\"b$i\"}}" | bash "$HOOK" >/dev/null; done
o25b="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg25b","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.py","old_string":"a9","new_string":"b9"}}' | bash "$HOOK")"
if printf '%s' "$o25a" | grep -q 'occurrence 4' && [ -z "$o25b" ]; then ok "T25 identical edits blocked, distinct edits allowed"; else bad "T25: [$o25a] [$o25b]"; fi

# (26) approving the dry-run variant never covers the real operation (Codex r3 P1-1)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg26","prompt":"git push origin feat/x --dry-run は承認、進めて"}' | bash "$HOOK" >/dev/null
o26="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg26","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | bash "$HOOK")"
if [ -z "$o26" ]; then ok "T26 dry-run approval does not cover the real push"; else bad "T26: $o26"; fi

# (27) `pytest -q || true` gives the segment an UNKNOWN status (Codex r3 P2-1)
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg27","tool_name":"Bash","tool_input":{"command":"pytest -q || true"}}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg27","tool_name":"Bash","tool_input":{"command":"pytest -q || true"},"tool_response":{"exit_code":0,"stdout":"1 failed"}}' | bash "$HOOK" >/dev/null
o27="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg27","last_assistant_message":"全テスト完了。\nEvidence: pytest -q | 20 passed | 10:00"}' | bash "$HOOK")"
if printf '%s' "$o27" | grep -q 'unavailable'; then ok "T27 compound || rc is UNKNOWN for the segment"; else bad "T27: $o27"; fi

# (28) cp SOURCE is not a written artifact (Codex r3 P2-3)
src="$SB/original.txt"; printf 'v1\n' >"$src"; ssha="$(shasum -a 256 "$src" | cut -c1-64)"
printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"neg28\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $src $SB/backup.txt\"}}" | bash "$HOOK" >/dev/null
printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"neg28\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $src $SB/backup.txt\"},\"tool_response\":{\"exit_code\":0,\"stdout\":\"\"}}" | bash "$HOOK" >/dev/null
o28="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"neg28\",\"last_assistant_message\":\"原本を保存済み。完了。\\nEvidence: cp $src $SB/backup.txt | ok | 10:00\\nReadback: $src sha256=$ssha\"}" | bash "$HOOK")"
if printf '%s' "$o28" | grep -q 'never written'; then ok "T28 cp source is not a written artifact"; else bad "T28: $o28"; fi

# (29) real AskUserQuestion shape (header/options/description) is still matched on the question text (Codex r3 P2-2)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg29","prompt":"PR作成は承認、進めて"}' | bash "$HOOK" >/dev/null
o29="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg29","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"PR作成を進めてよいですか？","header":"Approach","options":[{"label":"Yes, create the pull request now","description":"Opens a PR against develop with the current branch"},{"label":"No, wait for more review","description":"Keep working locally"}],"multiSelect":false}]}}' | bash "$HOOK")"
if printf '%s' "$o29" | grep -q 'already decided'; then ok "T29 real-shape question matched on its text"; else bad "T29: $o29"; fi

# (30) a revocation in the parent reaches a child that already saved the inherited decision (Codex r3 P1-3)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg30p","prompt":"git push origin feat/x は承認、進めて"}' | bash "$HOOK" >/dev/null
PMETA="$AIDD_CC_STATE_DIR/sessions/claude-code__neg30p.json"
printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg30c","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | AIDD_CC_INHERIT="$PMETA" bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg30c","prompt":"進捗を教えて"}' | AIDD_CC_INHERIT="$PMETA" bash "$HOOK" >/dev/null   # child saves its meta (inherited decision inside)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg30p","prompt":"前の承認は取り消します。実行しないでください"}' | bash "$HOOK" >/dev/null
o30="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg30c","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | AIDD_CC_INHERIT="$PMETA" bash "$HOOK")"
if [ -z "$o30" ]; then ok "T30 parent revocation reaches the child"; else bad "T30: $o30"; fi

# (31) questions / conditionals / more refusal forms never bind; case and quotes matter (reviewer-e N1/N2, Codex r4 P1)
fails31=""
for pr in "git push origin feat/x を許可？" "Should I approve git push origin feat/x?" "もし CI が緑なら git push origin feat/x は許可だけど、今は待って" \
          "git push origin feat/x の許可は見送ります" "I refuse to approve git push origin feat/x" "git push origin feat/X は承認、進めて" \
          "echo \"git push origin feat/x\" は承認、進めて" "git push origin feat/x --dry-run は OK"; do
  sid="neg31$(printf '%s' "$pr" | shasum | cut -c1-6)"
  printf '%s' "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$sid\",\"prompt\":$(python3 -I -c 'import json,sys;print(json.dumps(sys.argv[1],ensure_ascii=False))' "$pr")}" | bash "$HOOK" >/dev/null
  o="$(printf '%s' "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"$sid\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin feat/x\"}}" | bash "$HOOK")"
  [ -n "$o" ] && fails31="$fails31 [$pr]"
done
if [ -z "$fails31" ]; then ok "T31 undecided / refused / mismatched-case / quoted / dry-run never allow"; else bad "T31 allowed for:$fails31"; fi

# (32) path approvals bind only with a write-kind operation; cat / 削除 approvals never allow a Write (reviewer-e #2)
for pr in "cat config/prod.yml を許可、進めて" "config/prod.yml の削除は承認、進めて"; do
  sid="neg32$(printf '%s' "$pr" | shasum | cut -c1-6)"
  printf '%s' "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$sid\",\"prompt\":$(python3 -I -c 'import json,sys;print(json.dumps(sys.argv[1],ensure_ascii=False))' "$pr")}" | bash "$HOOK" >/dev/null
  o="$(printf '%s' "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"$sid\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"config/prod.yml\",\"content\":\"x\"}}" | bash "$HOOK")"
  [ -n "$o" ] && fail32="yes"
done
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg32w","prompt":"config/prod.yml の修正は承認、進めて"}' | bash "$HOOK" >/dev/null
o32="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg32w","tool_name":"Write","tool_input":{"file_path":"config/prod.yml","content":"x"}}' | bash "$HOOK")"
if [ -z "${fail32:-}" ] && printf '%s' "$o32" | grep -q '"behavior": "allow"'; then ok "T32 path approval needs a write-kind operation"; else bad "T32: cat/delete allowed=${fail32:-no} write=[$o32]"; fi

# (33) a short OK binds to the last question the agent asked (reviewer-e #8)
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg33","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"git push origin feat/x を実行してよいですか？","header":"Push","options":[{"label":"Yes","description":"push now"},{"label":"No","description":"wait"}]}]}}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg33","prompt":"OK"}' | bash "$HOOK" >/dev/null
o33="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg33","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | bash "$HOOK")"
o33b="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg33","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"git push origin feat/x を実行してよいですか？","header":"Push","options":[{"label":"Yes","description":"push now"}]}]}}' | bash "$HOOK")"
if printf '%s' "$o33" | grep -q '"behavior": "allow"' && printf '%s' "$o33b" | grep -q 'already decided'; then ok "T33 OK binds to the pending question; re-ask blocked"; else bad "T33: [$o33] [$o33b]"; fi

# (34) exit status is read only from a trailing status line; output text cannot fake rc 0 (reviewer-e N4)
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg34","tool_name":"exec_command","tool_input":{"cmd":"pytest -q"},"tool_response":"Tests: 3 failed. rc 0 expected\nmore output"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null
o34="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg34","last_assistant_message":"完了。\nEvidence: pytest -q | 20 passed | 10:00"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg34b","tool_name":"exec_command","tool_input":{"cmd":"pytest -q; echo exit=$?"},"tool_response":"20 passed\nexit=0"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null
o34b="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg34b","last_assistant_message":"完了。\nEvidence: pytest -q; echo exit=$? | 20 passed exit=0 | 10:00"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
if printf '%s' "$o34" | grep -q 'unavailable' && [ -z "$o34b" ]; then ok "T34 status only from a trailing status line; exit=\$? marker works"; else bad "T34: [$o34] [$o34b]"; fi

# (35) Codex apply_patch repeats are edits; masked pipeline rc is UNKNOWN (reviewer-e N5 / N3)
for i in 1 2 3; do printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg35","tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: a.py\n@@\n-x\n+y\n*** End Patch"}}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null; done
o35="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg35","tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: a.py\n@@\n-x\n+y\n*** End Patch"}}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg35b","tool_name":"Bash","tool_input":{"command":"pytest -q | tail -3"}}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg35b","tool_name":"Bash","tool_input":{"command":"pytest -q | tail -3"},"tool_response":{"exit_code":0,"stdout":"3 failed"}}' | bash "$HOOK" >/dev/null
o35b="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg35b","last_assistant_message":"完了。\nEvidence: pytest -q | 20 passed | 10:00"}' | bash "$HOOK")"
if printf '%s' "$o35" | grep -q 'occurrence 4' && printf '%s' "$o35b" | grep -q 'unavailable'; then ok "T35 apply_patch repeats blocked; piped rc is UNKNOWN"; else bad "T35: [$o35] [$o35b]"; fi

# (36) a verb inside the file name is not a write-kind approval (Codex r5 P1)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg36","prompt":"cat /tmp/update.json は承認、進めて"}' | bash "$HOOK" >/dev/null
o36="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg36","tool_name":"Write","tool_input":{"file_path":"/tmp/update.json","content":"x"}}' | bash "$HOOK")"
if [ -z "$o36" ]; then ok "T36 verb in file name is not a write approval"; else bad "T36: $o36"; fi

# (37) whole-line citation of `pytest -q; true` is still UNKNOWN; incomplete trailer rejected (Codex r5 P2-a/P2-h)
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg37","tool_name":"Bash","tool_input":{"command":"pytest -q; true"}}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg37","tool_name":"Bash","tool_input":{"command":"pytest -q; true"},"tool_response":{"exit_code":0,"stdout":"3 failed"}}' | bash "$HOOK" >/dev/null
o37="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg37","last_assistant_message":"全テスト完了。\nEvidence: pytest -q; true | 20 passed | 10:00"}' | bash "$HOOK")"
o37b="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg37","last_assistant_message":"全テスト完了。\nEvidence: pytest -q; true"}' | bash "$HOOK")"
if printf '%s' "$o37" | grep -q 'unavailable' && printf '%s' "$o37b" | grep -q 'incomplete Evidence'; then ok "T37 masked whole-line rc is UNKNOWN; incomplete trailer rejected"; else bad "T37: [$o37] [$o37b]"; fi

# (38) `cp /missing dest || true` does not make dest a written artifact (Codex r5 P2-b)
dst="$SB/dest.txt"; printf 'old\n' >"$dst"; dsha="$(shasum -a 256 "$dst" | cut -c1-64)"
printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"neg38\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp /missing $dst || true\"}}" | bash "$HOOK" >/dev/null
printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"neg38\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp /missing $dst || true\"},\"tool_response\":{\"exit_code\":0,\"stdout\":\"\"}}" | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg38","tool_name":"Bash","tool_input":{"command":"bash tests/ok.sh"}}' | bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg38","tool_name":"Bash","tool_input":{"command":"bash tests/ok.sh"},"tool_response":{"exit_code":0,"stdout":"x"}}' | bash "$HOOK" >/dev/null
o38="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"neg38\",\"last_assistant_message\":\"保存済み。完了。\\nEvidence: bash tests/ok.sh | x | 10:00\\nReadback: $dst sha256=$dsha\"}" | bash "$HOOK")"
if printf '%s' "$o38" | grep -q 'never written'; then ok "T38 masked cp does not count as a write"; else bad "T38: $o38"; fi

# (39) one undecided question keeps a multi-question call (Codex r5 P2-d)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg39","prompt":"PR作成は承認、進めて"}' | bash "$HOOK" >/dev/null
o39="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg39","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"PR作成を進めてよいですか？"},{"question":"release ノート生成を進めてよいですか？"}]}}' | bash "$HOOK")"
o39b="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg39","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"PR作成を進めてよいですか？"}]}}' | bash "$HOOK")"
if [ -z "$o39" ] && printf '%s' "$o39b" | grep -q 'already decided'; then ok "T39 undecided question keeps the call; fully-answered call blocked"; else bad "T39: [$o39] [$o39b]"; fi

# (40) an approved command that is only the argument of another command is not approved (Codex r6 P1-a)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg40","prompt":"echo git push origin feat/x は承認、進めて"}' | bash "$HOOK" >/dev/null
o40="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg40","tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}' | bash "$HOOK")"
if [ -z "$o40" ]; then ok "T40 argument position is not approval"; else bad "T40: $o40"; fi

# (41) the write verb must be in the path's clause (Codex r6 P1-b)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"neg41","prompt":"cat config/prod.yml は承認、README.md を更新して進めて"}' | bash "$HOOK" >/dev/null
o41="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg41","tool_name":"Write","tool_input":{"file_path":"config/prod.yml","content":"x"}}' | bash "$HOOK")"
o41b="$(printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"neg41","tool_name":"Write","tool_input":{"file_path":"README.md","content":"x"}}' | bash "$HOOK")"
if [ -z "$o41" ] && printf '%s' "$o41b" | grep -q '"behavior": "allow"'; then ok "T41 write verb bound to its own clause"; else bad "T41: [$o41] [$o41b]"; fi

# (42) `failing; true; echo exit=$?` cannot launder a failure through the marker (Codex r6 P2-a)
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"neg42","tool_name":"exec_command","tool_input":{"cmd":"bash tests/failing.sh; true; echo exit=$?"},"tool_response":"FAIL\nexit=0"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null
o42="$(printf '%s' '{"hook_event_name":"Stop","session_id":"neg42","last_assistant_message":"完了。\nEvidence: bash tests/failing.sh; true; echo exit=$? | FAIL exit=0 | 10:00"}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
if printf '%s' "$o42" | grep -q 'unavailable'; then ok "T42 laundered marker stays UNKNOWN"; else bad "T42: $o42"; fi

# (43) the same command in four different workdirs is not a repeat (Codex r6 P2-b)
for d in a b c d; do printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"neg43\",\"tool_name\":\"exec_command\",\"tool_input\":{\"cmd\":\"npm test\",\"workdir\":\"/pkg/$d\"}}" | bash "$ROOT/hooks/codex/aidd-cc-codex.sh" >/dev/null; done
o43="$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"neg43","tool_name":"exec_command","tool_input":{"cmd":"npm test","workdir":"/pkg/e"}}' | bash "$ROOT/hooks/codex/aidd-cc-codex.sh")"
if [ -z "$o43" ]; then ok "T43 different workdirs are different operations"; else bad "T43: $o43"; fi

# (44) a verified candidate's sha cannot be swapped on a later transition (Codex r6 P2-d)
o44="$(printf '%s' '{"record":{"state":"candidate_verified","candidate_sha":"aaaa"},"to":"applied","original":"/nonexistent/x","candidate_sha":"bbbb"}' | python3 -I "$ROOT/hooks/lib/aidd_cc.py" eval promote --agent claude-code --session neg44)"
if printf '%s' "$o44" | grep -q 'candidate sha changed'; then ok "T44 candidate sha swap rejected"; else bad "T44: $o44"; fi

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
