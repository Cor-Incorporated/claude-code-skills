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
out.partial_resume = out.synthetic.find((s: any) => s.sessionID === sid2)?.resume;
// a third session: the native 2.x `patch` tool ({ patchText }) is normalized to an edit → the 4th identical patch is denied
const sid3 = "ses_v2test3";
const patchText = "*** Begin Patch\n*** Update File: src/app.ts\n@@\n-old\n+new\n*** End Patch\n";
let patchDenied = 0;
for (let i = 0; i < 5; i++) {
  try {
    await hooks["tool.execute.before"]({ tool: "patch", sessionID: sid3, agent: "build", messageID: "m3", id: `p${i}`, input: { patchText } });
    await hooks["tool.execute.after"]({ tool: "patch", sessionID: sid3, agent: "build", messageID: "m3", id: `p${i}`, input: { patchText }, status: "completed", result: { content: "Success. Updated the following files:\nM src/app.ts" } });
  } catch (e) { patchDenied = i + 1; out.patch_deny_message = String((e as Error).message).slice(0, 80); break; }
}
out.patch_denied_at = patchDenied;
// review #426 M1: a two-file patch records a post row for each file
const two = "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-1\n+2\n*** Update File: src/b.ts\n@@\n-3\n+4\n*** End Patch\n";
await hooks["tool.execute.before"]({ tool: "patch", sessionID: "ses_v2test4", agent: "build", messageID: "m4", id: "q1", input: { patchText: two } });
await hooks["tool.execute.after"]({ tool: "patch", sessionID: "ses_v2test4", agent: "build", messageID: "m4", id: "q1", input: { patchText: two }, status: "completed", result: { content: "Success" } });
// ADR011-P1-1 (independent acceptance 2026-10-21, adr011-falsify/oc2-timeout.sh): the 2.x shell drops `exit` on a
// timeout / signal / background call (core shell/result.ts, tool/plugin/shell.ts). Timeout and signal carry a code
// (124 / 128+N); a call with none sends none — never one read from the output text (X can print `[exit code: 0]`)
const runOut = "suite-a ... ok\nsuite-b ... FAILED (1 of 12)\nexit code: 0";
const shellCases: [string, Record<string, unknown>, string[]][] = [
  ["ses_v2rc_timeout", { status: "completed", truncated: false, timeout: true }, [runOut, "Timed out before completion"]],
  ["ses_v2rc_signal", { status: "completed", truncated: false, signal: "SIGKILL" }, [runOut, "Killed by SIGKILL"]],
  ["ses_v2rc_exit1", { status: "completed", truncated: false, exit: 1 }, [runOut, "Exited with code 1"]],
  ["ses_v2rc_nocode", { status: "completed", truncated: false }, ["suite-a ... ok\n[exit code: 0]"]],
  ["ses_v2rc_bg", { status: "running", truncated: false, shellID: "sh_1" }, ["Command moved to the background (shell ID: sh_1).\nOutput is streaming to: /tmp/sh_1.log", "Read it with the shell tools."]],
];
for (const [sid, metadata, parts] of shellCases) {
  const input = { command: "bash tests/run-suites.sh" };
  await hooks["tool.execute.before"]({ tool: "shell", sessionID: sid, agent: "build", messageID: "r1", id: "r1c", input });
  await hooks["tool.execute.after"]({ tool: "shell", sessionID: sid, agent: "build", messageID: "r1", id: "r1c", input, status: "completed",
    result: { content: parts.map((text) => ({ type: "text", text })), metadata } });
}
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
assert r["partial_resume"] is False, r            # Codex #426 P1-a: a display-only note must not resume the session
assert r["patch_denied_at"] == 4 and "edit" in r["patch_deny_message"].lower(), r  # Codex #426 P1-b: native patch counts as an edit
print("PASS: v2 plugin — prompt/tool hooks registered, 4th identical call denied, final answer without Status re-prompted, Status: partial passes with a synthetic note (resume:false), native patch normalized to an edit")
PY
python3 -I - "$AIDD_CC_STATE_DIR" <<'PY' || exit 1
import glob, json, os, sys
rc = {}
for p in glob.glob(os.path.join(sys.argv[1], "**", "*.jsonl"), recursive=True):
    for line in open(p, encoding="utf-8"):
        r = json.loads(line)
        if r.get("event") == "post" and "ses_v2rc_" in os.path.basename(p):
            rc[os.path.basename(p).split("ses_v2rc_")[1].split(".")[0]] = r.get("rc")
want = {"timeout": 124, "signal": 137, "exit1": 1, "nocode": None, "bg": None}
assert rc == want, f"post rc per 2.x shell outcome: got {rc}, want {want}"
print("PASS: 2.x shell outcomes -> rc (timeout 124, SIGKILL 137, exit 1); a call without a code sends none, never one read from the output")
PY
if grep -rqs 'edit:[^"]*src/a.ts' "$AIDD_CC_STATE_DIR" && grep -rqs 'edit:[^"]*src/b.ts' "$AIDD_CC_STATE_DIR"; then echo "PASS: two-file patch -> a post row per touched file"; else echo "FAIL: per-file post rows missing"; grep -rho 'edit:[^"]*' "$AIDD_CC_STATE_DIR" | sort -u | head; exit 1; fi
grep -q '"component": "H17"' "$AIDD_LEDGER_PATH" && echo "PASS: H6 ledger rows written by the v2 entry" || { echo "FAIL: no ledger rows"; exit 1; }
# owner live run 2026-10-19: `opencode2 run` returns on session.execution.succeeded and the CLI stops its private
# server with SIGTERM to the process group; the stop oracle died mid-judgment (`python-exit-null:stop`). The oracle
# now runs in its own process group, so killing the plugin's group leaves it to finish and write its ledger row.
cat >"$SB/drive-kill.ts" <<'JS'
import plugin from "./plugin/index.ts";
const queue: any[] = []; let wake: (() => void) | null = null;
const push = (ev: any) => { queue.push(ev); wake?.(); };
async function* events() { while (true) { if (queue.length) { yield queue.shift(); continue; } await new Promise<void>((r) => (wake = r)); wake = null; } }
const hooks: Record<string, Function> = {};
await plugin.setup({
  session: { hook: async (n: string, f: Function) => { hooks["session." + n] = f; }, prompt: async () => {}, synthetic: async () => {} },
  tool: { hook: async (n: string, f: Function) => { hooks["tool." + n] = f; } },
  event: { subscribe: () => events() },
  location: { directory: process.cwd() },
});
const sid = "ses_v2kill";
await hooks["session.prompt"]({ sessionID: sid, messageID: "k1", prompt: { text: "a.txt を表示して", files: [] }, delivery: "steer" });
await hooks["tool.execute.before"]({ tool: "shell", sessionID: sid, agent: "build", messageID: "k1", id: "k1c", input: { command: "cat a.txt" } });
await hooks["tool.execute.after"]({ tool: "shell", sessionID: sid, agent: "build", messageID: "k1", id: "k1c", input: { command: "cat a.txt" }, status: "completed", result: { content: "hello", metadata: { exit: 0 } } });
push({ type: "session.text.ended", data: { sessionID: sid, assistantMessageID: "k2", ordinal: 0, text: "実装完了しました。" } });
push({ type: "session.execution.succeeded", data: { sessionID: sid } });
await new Promise((r) => setTimeout(r, 300));
console.log("SPAWNED");
await new Promise((r) => setTimeout(r, 60000));
JS
# the live stop judgment took seconds (cold python + ledger I/O); a 2 s delay on `stop` reproduces that window here
cat >"$SB/slow_cc.py" <<'PYW'
import os, runpy, sys, time
if len(sys.argv) > 1 and sys.argv[1] == "stop":
    time.sleep(2)
real = os.environ["AIDD_CC_PY_REAL"]
sys.argv = [real] + sys.argv[1:]
sys.path.insert(0, os.path.dirname(real))
runpy.run_path(real, run_name="__main__")
PYW
set -m
(cd "$SB" && AIDD_CC_PY_REAL="$AIDD_CC_PY" AIDD_CC_PY="$SB/slow_cc.py" exec bun run drive-kill.ts >"$SB/kill.out" 2>&1) &
kpid=$!
set +m
for _ in $(seq 1 100); do grep -q SPAWNED "$SB/kill.out" 2>/dev/null && break; sleep 0.1; done
kill -TERM -- "-$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
for _ in $(seq 1 60); do grep -q '"session": "ses_v2kill"' "$AIDD_LEDGER_PATH" 2>/dev/null && grep '"session": "ses_v2kill"' "$AIDD_LEDGER_PATH" | grep -q '"decision": "block"' && break; sleep 0.1; done
if grep '"session": "ses_v2kill"' "$AIDD_LEDGER_PATH" | grep -q '"decision": "block"'; then echo "PASS: SIGTERM to the plugin's process group -> the stop oracle still writes its block row"; else echo "FAIL: no block row after the group SIGTERM"; grep 'ses_v2kill' "$AIDD_LEDGER_PATH" | tail -3; cat "$SB/kill.out"; exit 1; fi
: >"$SB/err-ledger.jsonl"
(cd "$SB" && AIDD_CC_PY=/nonexistent/aidd_cc.py AIDD_LEDGER_PATH="$SB/err-ledger.jsonl" timeout 30 bun run drive.ts >/dev/null 2>&1) || true
if grep -q '"event":"error"' "$SB/err-ledger.jsonl" && grep -q '"decision":"unavailable"' "$SB/err-ledger.jsonl"; then echo "PASS: missing oracle -> H6 error rows (unavailable), no silent pass"; else echo "FAIL: no error row"; cat "$SB/err-ledger.jsonl"; exit 1; fi
