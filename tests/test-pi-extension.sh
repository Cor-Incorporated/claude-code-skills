#!/usr/bin/env bash
# Pi extension (pi/aidd-cc.ts) — drives the extension with a fake ExtensionAPI and
# asserts it binds to the real python oracle: 4th identical bash call -> block (3 prior),
# evidence-free completion at turn_end -> continue:true with the gate message,
# benign progress report -> no continuation.  Needs node >= 22 (strip-types).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${NODE_BIN:-node}"
for cand in "$HOME/.local/share/mise/installs/node/22.17.1/bin/node" "$(command -v node || true)"; do
  [ -x "$cand" ] && "$cand" -e 'process.exit(parseInt(process.versions.node)>=22?0:1)' 2>/dev/null && NODE="$cand" && break
done
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export AIDD_CC_PY="$ROOT/hooks/lib/aidd_cc.py" AIDD_CC_STATE_DIR="$SB/state" AIDD_LEDGER_PATH="$SB/ledger.jsonl" AIDD_LEDGER_SOURCE=test AIDD_CC_MAX_STOP_BLOCKS=99
cp "$ROOT/pi/aidd-cc.ts" "$SB/aidd-cc.ts"
cat >"$SB/drive.mts" <<'JS'
import ext from "./aidd-cc.ts";
const handlers = new Map();
const pi = { on: (ev, h) => { handlers.set(ev, h); return () => {}; } };
ext(pi);
const call = (ev, e, ctx = {}) => handlers.get(ev)(e, ctx);
const out = {};
await call("session_start", {}, { sessionManager: { getSessionId: () => "pi-test-1" } });
await call("before_agent_start", { messageType: "user", prompt: "テスト修正は承認。進めて" });
let blocked = null;
for (let i = 0; i < 5; i++) {
  const r = await call("tool_call", { toolName: "bash", input: { command: "bash tests/flaky.sh" } });
  await call("tool_result", { toolName: "bash", input: { command: "bash tests/flaky.sh" }, isError: true, content: [{ type: "text", text: "FAIL" }] });
  if (r && r.block) { blocked = i + 1; break; }
}
out.iter_block_at = blocked;
const t1 = await call("turn_end", { message: { content: [{ type: "text", text: "実装完了しました。" }] }, toolResults: [] });
out.evidence_free_continue = !!(t1 && t1.continue);
out.gate_message = t1?.entries?.[0]?.content?.slice(0, 40) ?? null;
const t2 = await call("turn_end", { message: { content: [{ type: "text", text: "途中経過です。次に tests を走らせます。" }] }, toolResults: [] });
out.benign_continue = !!(t2 && t2.continue);
// aidd-governance#186 P1-4: once the extension's own continuation budget is spent, a block-worthy
// final answer must still get a visible note (no silent pass-through).
await call("turn_end", { message: { content: [{ type: "text", text: "実装完了しました。" }] }, toolResults: [] });
const t4 = await call("turn_end", { message: { content: [{ type: "text", text: "実装完了しました。" }] }, toolResults: [] });
out.exhausted_continue = !!(t4 && t4.continue);
out.exhausted_note = t4?.entries?.[0]?.content ?? null;
// The Pi live incident (2026-10-14 08:35Z): the python side released by evidence.max-blocks (blocks=2) and the
// fabricated third turn (never-executed tool calls, 2024 timestamps) reached the final output unmarked.
process.env.AIDD_CC_MAX_STOP_BLOCKS = "2";
await call("session_start", {}, { sessionManager: { getSessionId: () => "pi-test-2" } });
await call("before_agent_start", { messageType: "user", prompt: "実装して" });
for (let i = 0; i < 2; i++) await call("turn_end", { message: { content: [{ type: "text", text: "実装完了しました。" }] }, toolResults: [] });
const fab = "実装完了しました。\n\nEvidence: `write(path='test_file.txt')` | {\"write_response\": \"ok\"} | 2024-07-29 10:05:00";
const t7 = await call("turn_end", { message: { content: [{ type: "text", text: fab }] }, toolResults: [] });
out.released_continue = !!(t7 && t7.continue);
out.released_note = t7?.entries?.[0]?.content ?? null;
console.log(JSON.stringify(out));
JS
res="$("$NODE" --experimental-strip-types --no-warnings "$SB/drive.mts" 2>"$SB/err.log")" || { echo "FAIL: node run"; cat "$SB/err.log"; exit 1; }
echo "$res"
pass=0; fail=0
python3 -I - "$res" <<'PY' && pass=3 || fail=1
import json, sys
r = json.loads(sys.argv[1])
assert r["iter_block_at"] == 4, r           # 3 recorded repeats, 4th call blocked
assert r["evidence_free_continue"] is True, r
assert r["benign_continue"] is False, r
print("PASS: iter block at 4th identical call / evidence-free turn_end forced continuation / benign turn ends")
PY
# aidd-governance#186 P1-4 (T69-pi): both release paths leave a visible note instead of a silent pass-through
python3 -I - "$res" <<'PY' && pass=$((pass + 1)) || fail=$((fail + 1))
import json, sys
r = json.loads(sys.argv[1])
assert r["exhausted_continue"] is False and r["exhausted_note"] and "evidence unverified" in r["exhausted_note"], r
assert r["released_continue"] is False and r["released_note"] and "max-blocks released" in r["released_note"], r
print("PASS: T69-pi continuation budget exhausted / python max-blocks release -> visible [H17] evidence unverified note")
PY
if grep -q '"rule": "evidence.max-blocks.would-block"' "$SB/ledger.jsonl"; then pass=$((pass + 1)); echo "PASS: T69-pi would-block row in the H6 ledger"; else fail=$((fail + 1)); echo "FAIL: T69-pi no would-block row"; fi
# aidd-governance#186 P2-2: an oracle that cannot be spawned leaves an H6 error row (decision unavailable), never a silent allow
: >"$SB/err-ledger.jsonl"
AIDD_CC_PY=/nonexistent/aidd_cc.py AIDD_LEDGER_PATH="$SB/err-ledger.jsonl" "$NODE" --experimental-strip-types --no-warnings "$SB/drive.mts" >/dev/null 2>&1 || true
if grep -q '"event":"error"' "$SB/err-ledger.jsonl" && grep -q '"decision":"unavailable"' "$SB/err-ledger.jsonl" && grep -q '"agent":"pi"' "$SB/err-ledger.jsonl"; then pass=$((pass + 1)); echo "PASS: T84-pi missing oracle -> H6 error rows (unavailable), no silent pass"; else fail=$((fail + 1)); echo "FAIL: T84-pi no error row"; fi
[ "$fail" -eq 0 ] && grep -q '"component": "H17"' "$SB/ledger.jsonl" && echo "PASS: H6 ledger rows written by the pi entry" || { echo "FAIL"; exit 1; }
