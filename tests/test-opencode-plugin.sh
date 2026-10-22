#!/usr/bin/env bash
# OpenCode plugin (opencode/aidd-cc.ts) — drives the plugin object with a fake client and
# asserts it binds to the real python oracle: an evidence-free completion gets the gate
# verdict appended at experimental.text.complete (the headless `opencode run` path), the
# 4th identical bash call throws at tool.execute.before, and a benign report is untouched.
# Regression anchor: 2026-10-14 the text.complete handler was lost while removing
# permission.ask, and all four live lanes silently stopped evaluating.  Needs node >= 22.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${NODE_BIN:-node}"
for cand in "$HOME/.local/share/mise/installs/node/22.17.1/bin/node" "$(command -v node || true)"; do
  [ -x "$cand" ] && "$cand" -e 'process.exit(parseInt(process.versions.node)>=22?0:1)' 2>/dev/null && NODE="$cand" && break
done
command -v bun >/dev/null 2>&1 || { echo "SKIP: bun not installed (plugin uses Bun.spawn)"; exit 0; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export AIDD_CC_PY="$ROOT/hooks/lib/aidd_cc.py" AIDD_CC_STATE_DIR="$SB/state" AIDD_LEDGER_PATH="$SB/ledger.jsonl" AIDD_LEDGER_SOURCE=test
cp "$ROOT/opencode/aidd-cc.ts" "$SB/aidd-cc.ts"
cat >"$SB/drive.ts" <<'JS'
import plugin from "./aidd-cc.ts";
const hooks: any = await plugin({ client: {} });
const out: any = {};
out.has_text_complete = typeof hooks["experimental.text.complete"] === "function";
out.has_permission_ask = typeof hooks["permission.ask"] === "function";
await hooks["chat.message"]({ sessionID: "oc-test-1" }, { parts: [{ type: "text", text: "テスト修正は承認、進めて" }] });
let threw = 0;
for (let i = 0; i < 5; i++) {
  try {
    await hooks["tool.execute.before"]({ tool: "bash", sessionID: "oc-test-1" }, { args: { command: "bash tests/flaky.sh" } });
    await hooks["tool.execute.after"]({ tool: "bash", sessionID: "oc-test-1", args: { command: "bash tests/flaky.sh" } }, { title: "", output: "FAIL", metadata: { exit: 1 } });
  } catch (e) { threw = i + 1; break; }
}
out.iter_throw_at = threw;
const o1 = { text: "実装完了しました。" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-1", messageID: "m", partID: "p" }, o1);
// ADR-009 (review r2 P2): after tool use a text part is not judged by vocabulary at text.complete — the final answer
// is judged (Status required) at session.idle / process exit; so o1 stays untouched here
out.gate_appended = o1.text.includes("[H17 evidence gate]");
// the regression anchor of 2026-10-14 (text.complete handler lost) lives on in a session WITHOUT tool rows: the
// closed-vocabulary backstop still annotates the evidence-free claim at text.complete
await hooks["chat.message"]({ sessionID: "oc-test-3" }, { parts: [{ type: "text", text: "進めて" }] });
const o6 = { text: "実装完了しました。" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-3", messageID: "m6", partID: "p6" }, o6);
out.gate_appended_no_tools = o6.text.includes("[H17 evidence gate]");
const o2 = { text: "途中経過です。次に tests を走らせます。\nStatus: partial" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-1", messageID: "m2", partID: "p2" }, o2);
// ADR-009 (Codex r2 P2): a declared partial answer is not blocked, but its "not verified" note is appended visibly
out.benign_untouched = o2.text.startsWith("途中経過です。次に tests を走らせます。\nStatus: partial") && !o2.text.includes("[H17 evidence gate]") && o2.text.includes("[H17] Status: partial");
const o3 = { text: "I'll run the tests now." };   // ADR-009: an intermediate text part has no Status yet and must not be annotated
await hooks["experimental.text.complete"]({ sessionID: "oc-test-1", messageID: "m3", partID: "p3" }, o3);
out.intermediate_untouched = o3.text === "I'll run the tests now.";
const o5 = { text: "テストは全て完了しました。次に進みます。" };   // review r2 P2: completion words in a mid-turn part are not a claim after tool use
await hooks["experimental.text.complete"]({ sessionID: "oc-test-1", messageID: "m5", partID: "p5" }, o5);
out.intermediate_claim_untouched = o5.text === "テストは全て完了しました。次に進みます。";
// ADR-009 review r2: session 2 uses a tool, then declares Status: partial -> the note is appended at text.complete and
// the exit handler (headless final answer) only notes; session 1's last part (o3, no Status, no tool after it) is
// blocked at process exit: stderr line + H6 block row.  Asserted by the shell after bun exits.
await hooks["tool.execute.before"]({ tool: "bash", sessionID: "oc-test-2" }, { args: { command: "echo ok" } });
await hooks["tool.execute.after"]({ tool: "bash", sessionID: "oc-test-2", args: { command: "echo ok" } }, { title: "", output: "ok", metadata: { exit: 0 } });
const o4 = { text: "Ran echo; nothing else verified.\nStatus: partial" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-2", messageID: "m4", partID: "p4" }, o4);
out.partial_note_appended = o4.text.includes("[H17] Status: partial");
// Codex r3 P2: one message, two text parts — the Evidence line in part 1 and `Status: complete` in part 2 are judged
// together (session oc-test-4 ran `pytest -q` with exit 0 and "3 passed")
await hooks["tool.execute.before"]({ tool: "bash", sessionID: "oc-test-4" }, { args: { command: "pytest -q" } });
await hooks["tool.execute.after"]({ tool: "bash", sessionID: "oc-test-4", args: { command: "pytest -q" } }, { title: "", output: "3 passed in 0.2s", metadata: { exit: 0 } });
const o7 = { text: "Ran the suite.\nEvidence: pytest -q | 3 passed | 2026-10-17T05:00:00Z" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-4", messageID: "m7", partID: "p7" }, o7);
const o8 = { text: "Status: complete" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-4", messageID: "m7", partID: "p8" }, o8);
out.split_parts_untouched = !o7.text.includes("[H17") && !o8.text.includes("[H17");
out.split_texts = [o7.text, o8.text];
// ccs#421: the reverse order — `Status: complete` in part 1, the Evidence trailer in part 2 — is not annotated on part 1
await hooks["tool.execute.before"]({ tool: "bash", sessionID: "oc-test-5" }, { args: { command: "pytest -q" } });
await hooks["tool.execute.after"]({ tool: "bash", sessionID: "oc-test-5", args: { command: "pytest -q" } }, { title: "", output: "3 passed in 0.2s", metadata: { exit: 0 } });
const o9 = { text: "Ran the suite.\nStatus: complete" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-5", messageID: "m9", partID: "p9" }, o9);
const o10 = { text: "Evidence: pytest -q | 3 passed | 2026-10-22T05:00:00Z" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-5", messageID: "m9", partID: "p10" }, o10);
out.reverse_split_untouched = !o9.text.includes("[H17") && !o10.text.includes("[H17");
// a real defect in part 1 (a cited command that never ran) is still annotated at once
const o11 = { text: "Done.\nEvidence: npm test | 12 passing | 2026-10-22T05:00:00Z\nStatus: complete" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-5", messageID: "m11", partID: "p11" }, o11);
out.real_defect_annotated = o11.text.includes("[H17 evidence gate]");
console.log(JSON.stringify(out));
JS
res="$(cd "$SB" && bun run drive.ts 2>"$SB/err.log")" || { echo "FAIL: bun run"; cat "$SB/err.log"; exit 1; }
echo "$res"
python3 -I - "$res" <<'PY' || exit 1
import json, sys
r = json.loads(sys.argv[1])
assert r["has_text_complete"] is True, r
assert r["has_permission_ask"] is False, r          # auto-allow retired 2026-10-14
assert r["reverse_split_untouched"] is True, f"ccs#421: Status in part 1, Evidence in part 2 was annotated: {r}"
assert r["real_defect_annotated"] is True, f"a never-run cited command was not annotated: {r}"
assert r["iter_throw_at"] == 4, r
assert r["gate_appended"] is False, r           # ADR-009: after tool use, text.complete does not judge by vocabulary
assert r["gate_appended_no_tools"] is True, r   # no tool rows: the closed-vocabulary backstop still annotates
assert r["benign_untouched"] is True, r
assert r["intermediate_untouched"] is True, r   # ADR-009 review P1: text parts are not the final answer
assert r["partial_note_appended"] is True, r    # Codex r2 P2: Status: partial is visible on the OpenCode entry
assert r["intermediate_claim_untouched"] is True, r   # review r2 P2: no vocabulary check on mid-turn parts after tool use
assert r["split_parts_untouched"] is True, r   # Codex r3 P2: the parts of one message are judged as one text
print("PASS: text.complete gate present / no permission.ask / 4th identical call throws / benign untouched / partial note")
PY
# ADR-009 review r2 P1 (headless final answer): the last text part of oc-test-1 had no Status and no tool call after it
if grep -q 'H17 evidence gate.*no status declared' "$SB/err.log" && grep -q '"rule": "evidence"' "$AIDD_LEDGER_PATH" && grep -q 'no status declared' "$AIDD_LEDGER_PATH" && grep -q 'Status: partial' "$SB/err.log"; then echo "PASS: T99-oc headless final part without Status is blocked at process exit (stderr + H6 row); the partial one is noted"; else echo "FAIL: T99-oc exit path"; cat "$SB/err.log"; exit 1; fi
grep -q '"component": "H17"' "$AIDD_LEDGER_PATH" && echo "PASS: H6 ledger rows written by the opencode entry" || { echo "FAIL: no ledger rows"; exit 1; }
# aidd-governance#186 P2-2: an oracle that cannot be spawned leaves an H6 error row (decision unavailable), never a silent allow
: >"$SB/err-ledger.jsonl"
(cd "$SB" && AIDD_CC_PY=/nonexistent/aidd_cc.py AIDD_LEDGER_PATH="$SB/err-ledger.jsonl" bun run drive.ts >/dev/null 2>&1) || true
if grep -q '"event":"error"' "$SB/err-ledger.jsonl" && grep -q '"decision":"unavailable"' "$SB/err-ledger.jsonl" && grep -q '"agent":"opencode"' "$SB/err-ledger.jsonl"; then echo "PASS: T84-oc missing oracle -> H6 error rows (unavailable), no silent pass"; else echo "FAIL: T84-oc no error row"; cat "$SB/err-ledger.jsonl"; exit 1; fi
