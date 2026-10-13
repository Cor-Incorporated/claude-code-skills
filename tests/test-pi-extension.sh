#!/usr/bin/env bash
# Pi extension (pi/aidd-cc.ts) — drives the extension with a fake ExtensionAPI and
# asserts it binds to the real python oracle: 4th identical bash call -> block,
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
console.log(JSON.stringify(out));
JS
res="$("$NODE" --experimental-strip-types --no-warnings "$SB/drive.mts" 2>"$SB/err.log")" || { echo "FAIL: node run"; cat "$SB/err.log"; exit 1; }
echo "$res"
pass=0; fail=0
python3 -I - "$res" <<'PY' && pass=3 || fail=1
import json, sys
r = json.loads(sys.argv[1])
assert r["iter_block_at"] == 5, r           # 4 recorded repeats, 5th call blocked
assert r["evidence_free_continue"] is True, r
assert r["benign_continue"] is False, r
print("PASS: iter block at 5th identical call / evidence-free turn_end forced continuation / benign turn ends")
PY
[ "$fail" -eq 0 ] && grep -q '"component": "H17"' "$SB/ledger.jsonl" && echo "PASS: H6 ledger rows written by the pi entry" || { echo "FAIL"; exit 1; }
