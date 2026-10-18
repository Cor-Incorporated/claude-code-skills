#!/usr/bin/env bash
# OpenCode 2.x plugin (opencode/aidd-cc-v2/index.ts) — drives the `{ id, setup }` object with a fake 2.x context
# (session.hook / tool.hook / event.subscribe / session.prompt / session.synthetic) against the real python oracle:
#   - the prompt hook registers the user decision; the 4th identical bash call is DENIED (execute.before throws);
#   - a final answer after tool use with no Status line is blocked at session.execution.succeeded and re-prompted
#     through ctx.session.prompt with the gate reason; a `Status: partial` answer passes with a synthetic note;
#   - text parts followed by a tool call are intermediate (not judged); the oracle-missing path writes H6 error rows.
# Needs bun (the CLI's own runtime) or node >= 22.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v bun >/dev/null 2>&1 || { echo "SKIP: bun not installed"; exit 0; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export AIDD_CC_PY="$ROOT/hooks/lib/aidd_cc.py" AIDD_CC_STATE_DIR="$SB/state" AIDD_LEDGER_PATH="$SB/ledger.jsonl" AIDD_LEDGER_SOURCE=test
mkdir -p "$SB/plugin" && cp "$ROOT/opencode/aidd-cc-v2/index.ts" "$SB/plugin/index.ts"
cat >"$SB/drive.ts" <<'JS'
import plugin from "./plugin/index.ts";
const out: any = { prompts: [], synthetic: [] };
const hooks: Record<string, Function> = {};
const queue: any[] = []; let wake: (() => void) | null = null;
function push(ev: any) { queue.push(ev); wake?.(); }
async function* events() { while (true) { if (queue.length) { yield queue.shift(); continue; } await new Promise<void>((r) => (wake = r)); wake = null; } }
const ctx = {
  session: {
    hook: async (name: string, fn: Function) => { hooks["session." + name] = fn; },
    prompt: async (input: any) => { out.prompts.push(input); },
    synthetic: async (input: any) => { out.synthetic.push(input); },
  },
  tool: { hook: async (name: string, fn: Function) => { hooks["tool." + name] = fn; } },
  event: { subscribe: () => events() },
};
await plugin.setup(ctx);
out.id = plugin.id;
out.registered = Object.keys(hooks).sort();
const sid = "ses_v2test1";
await hooks["session.prompt"]({ sessionID: sid, messageID: "m1", prompt: { text: "テスト修正は承認、進めて", files: [] }, delivery: "steer" });
let denied = 0;
for (let i = 0; i < 5; i++) {
  try {
    await hooks["tool.execute.before"]({ tool: "bash", sessionID: sid, agent: "build", messageID: "m1", id: `c${i}`, input: { command: "bash tests/flaky.sh" } });
    await hooks["tool.execute.after"]({ tool: "bash", sessionID: sid, agent: "build", messageID: "m1", id: `c${i}`, input: { command: "bash tests/flaky.sh" }, status: "completed", result: { content: "FAIL\n[exit code: 1]", metadata: { exit: 1 } } });
  } catch (e) { denied = i + 1; out.deny_message = String((e as Error).message).slice(0, 60); break; }
}
out.iter_denied_at = denied;
// intermediate text, then a tool call, then the final answer without Status -> block + re-prompt
push({ type: "session.text.ended", data: { sessionID: sid, assistantMessageID: "a1", ordinal: 0, text: "I'll run the tests now." } });
push({ type: "session.tool.called", data: { sessionID: sid, assistantMessageID: "a1" } });
push({ type: "session.text.ended", data: { sessionID: sid, assistantMessageID: "a1", ordinal: 1, text: "実装完了しました。" } });
push({ type: "session.execution.succeeded", data: { sessionID: sid } });
await new Promise((r) => setTimeout(r, 4000));
out.reprompted = out.prompts.length;
out.reprompt_text = out.prompts[0]?.text?.slice(0, 80) ?? null;
// a second session: Status: partial after tool use -> allowed with a synthetic note
const sid2 = "ses_v2test2";
await hooks["tool.execute.before"]({ tool: "bash", sessionID: sid2, agent: "build", messageID: "m2", id: "c9", input: { command: "echo ok" } });
await hooks["tool.execute.after"]({ tool: "bash", sessionID: sid2, agent: "build", messageID: "m2", id: "c9", input: { command: "echo ok" }, status: "completed", result: { content: "ok", metadata: { exit: 0 } } });
push({ type: "session.text.ended", data: { sessionID: sid2, assistantMessageID: "a2", ordinal: 0, text: "Ran echo; nothing else verified.\nStatus: partial" } });
push({ type: "session.execution.succeeded", data: { sessionID: sid2 } });
await new Promise((r) => setTimeout(r, 4000));
out.partial_prompts = out.prompts.length - out.reprompted;
out.partial_note = out.synthetic.find((s: any) => s.sessionID === sid2)?.text?.slice(0, 60) ?? null;
console.log(JSON.stringify(out));
process.exit(0);
JS
res="$(cd "$SB" && bun run drive.ts 2>"$SB/err.log")" || { echo "FAIL: bun run"; cat "$SB/err.log"; exit 1; }
echo "$res"
python3 -I - "$res" <<'PY' || exit 1
import json, sys
r = json.loads(sys.argv[1])
assert r["id"] == "aidd-cc", r
assert r["registered"] == ["session.prompt", "tool.execute.after", "tool.execute.before"], r
assert r["iter_denied_at"] == 4 and r["deny_message"].startswith("[H17]"), r      # C-ITER: 4th identical call denied via throw
assert r["reprompted"] == 1 and "no status declared" in (r["reprompt_text"] or ""), r  # ADR-009 on the final answer
assert r["partial_prompts"] == 0 and r["partial_note"] and "Status: partial" in r["partial_note"], r
print("PASS: v2 plugin — prompt/tool hooks registered, 4th identical call denied, final answer without Status re-prompted, Status: partial passes with a synthetic note")
PY
grep -q '"component": "H17"' "$AIDD_LEDGER_PATH" && echo "PASS: H6 ledger rows written by the v2 entry" || { echo "FAIL: no ledger rows"; exit 1; }
: >"$SB/err-ledger.jsonl"
(cd "$SB" && AIDD_CC_PY=/nonexistent/aidd_cc.py AIDD_LEDGER_PATH="$SB/err-ledger.jsonl" timeout 30 bun run drive.ts >/dev/null 2>&1) || true
if grep -q '"event":"error"' "$SB/err-ledger.jsonl" && grep -q '"decision":"unavailable"' "$SB/err-ledger.jsonl"; then echo "PASS: missing oracle -> H6 error rows (unavailable), no silent pass"; else echo "FAIL: no error row"; cat "$SB/err-ledger.jsonl"; exit 1; fi
