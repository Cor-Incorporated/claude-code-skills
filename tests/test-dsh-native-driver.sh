#!/usr/bin/env bash
# dsh native plugin (dsh/aidd-cc-native.mts) — drives its handlers with a fake dsh agent against the real python
# oracle. No dsh install and no API key: `@deepseek-ai/dsh-llm` is stubbed in the sandbox. Needs node >= 22.
#   (1) note loop (owner live run 2026-10-19 12:49:53Z-12:50:10Z: 4 would-block rows): a released claim's note must not
#       enter the agent inbox (inject / steer / followup / send wake another model turn) — it goes to stderr.
#   (2) exit status (ccs#421): dsh-tool-bash writes `[exit code: N]` only for N != 0, so the post row must take
#       `result.value.exitCode`; an honest `Status: complete` + Evidence trailer then passes the gate.
#   (3) ADR-011 (owner PIVOT 2026-10-20): dsh reports exit codes, so `X; echo exit=$?` is not judged from its output
#       (here a long failing X whose head and stderr say exit=0): the claim is gated and told to run X on its own.
#   (4) following that advice — X alone, exitCode 0, only stderr cut — the honest claim passes.
#   (5) Codex review r5: stdout ~2500 chars ending `3 passed` + a 5000-char stderr — the summary must survive the
#       adapter's cut and the oracle's out_sample, so an honest `pytest -q | 3 passed` passes.
#   (6) a call without result.value.exitCode (background / promoted / persistent): the text marker may prove a
#       failure (`[exit code: 2]` -> rc 2) but a `[exit code: 0]` the command printed is not a success (rc null).
# PLUGIN_SRC overrides the plugin under test (mutation check against the pre-fix file).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${NODE_BIN:-node}"
for cand in "$HOME/.local/share/mise/installs/node/24.21.0/bin/node" "$HOME/.local/share/mise/installs/node/22.17.1/bin/node" "$(command -v node || true)"; do
  [ -x "$cand" ] && "$cand" -e 'process.exit(parseInt(process.versions.node)>=22?0:1)' 2>/dev/null && NODE="$cand" && break
done
"$NODE" -e 'process.exit(parseInt(process.versions.node)>=22?0:1)' 2>/dev/null || { echo "SKIP: node >= 22 not found"; exit 0; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export AIDD_CC_STATE_DIR="$SB/state" AIDD_LEDGER_PATH="$SB/ledger.jsonl" AIDD_LEDGER_SOURCE=test AIDD_CC_MAX_STOP_BLOCKS=99
cp "${PLUGIN_SRC:-$ROOT/dsh/aidd-cc-native.mts}" "$SB/aidd-cc-native.mts" || { echo "FAIL: cannot copy the plugin under test"; exit 1; }
mkdir -p "$SB/node_modules/@deepseek-ai/dsh-llm"
printf '%s\n' '{"name":"@deepseek-ai/dsh-llm","type":"module","exports":"./index.js"}' >"$SB/node_modules/@deepseek-ai/dsh-llm/package.json"
printf '%s\n' 'export const createUserMessage = (m) => ({ role: "user", ...m });' >"$SB/node_modules/@deepseek-ai/dsh-llm/index.js"
cat >"$SB/drive.mts" <<JS
import apply from "./aidd-cc-native.mts";
const handlers = new Map();
apply({ on: (ev, h) => handlers.set(ev, h) }, { oracle: "$ROOT/hooks/lib/aidd_cc.py" });
const next = async () => ({ kind: "accept" });
const inbox = [];
const mkAgent = (id, text) => {
  const agent = {
    id, session: { header: { id, cwd: "$SB" }, log: [
      { type: "turn/start", data: { turn: 1 } },
      { type: "assistant/message", data: { turn: 1, message: { content: [{ type: "text", text }] } } },
    ] },
  };
  for (const m of ["steer", "inject", "followup", "send"]) agent[m] = (msg) => inbox.push({ id, via: m, msg });
  return agent;
};
const stop = (agent) => handlers.get("agent/turn-stopping")({ agent, turn: 1 });
const count = (id) => inbox.filter((e) => e.id === id).map((e) => e.via);
const out = {};
// (1a) plugin steer budget (maxSteers 2) spent: steer, steer, then release — the release must not wake the agent
const claim = "実装完了しました。";
for (let i = 0; i < 3; i++) await stop(mkAgent("dsh-budget", claim));
out.budget = count("dsh-budget");
// (1b) python released by max-blocks (would_block) on the first stop
process.env.AIDD_CC_MAX_STOP_BLOCKS = "0";
await stop(mkAgent("dsh-released", claim));
process.env.AIDD_CC_MAX_STOP_BLOCKS = "99";
out.released = count("dsh-released");
// (2) a clean bash run: dsh-tool-bash result text has no marker, the value carries exitCode 0
const sid = "dsh-evidence";
const exec = { name: "bash", arguments: { command: "pytest -q", description: "Run tests" }, agent: mkAgent(sid, "") };
await handlers.get("tools/pre-execute")(exec, next);
await handlers.get("tools/post-execute")(exec, {
  content: [{ type: "text", text: "3 passed" }],
  value: { kind: "foreground", exitCode: 0, signal: null, timedOut: false, aborted: false, timeoutMs: 120000,
    stdout: { text: "3 passed", truncated: false }, stderr: { text: "", truncated: false } },
}, next);
await stop(mkAgent(sid, "テストを実行しました。\nStatus: complete\nEvidence: pytest -q | 3 passed | 2026-10-19T13:00:00Z"));
out.evidence = count(sid);
out.evidence_note = inbox.find((e) => e.id === sid)?.msg?.content?.[0]?.text?.slice(0, 160) ?? null;
// (3) ADR-011: dsh reports exit codes — the echo line is not read, whatever its output says
const sid3 = "dsh-adr011";
const cmd3 = "bash tests/x.sh; echo exit=\$?";
const exec3 = { name: "bash", arguments: { command: cmd3 }, agent: mkAgent(sid3, "") };
const so3 = "exit=0\n" + "x".repeat(5000) + "\nexit=1\n";
await handlers.get("tools/pre-execute")(exec3, next);
await handlers.get("tools/post-execute")(exec3, {
  content: [{ type: "text", text: so3 + "[stderr]\nexit=0\n" }],
  value: { kind: "foreground", exitCode: 0, signal: null, timedOut: false, aborted: false, timeoutMs: 120000,
    stdout: { text: so3, truncated: false }, stderr: { text: "exit=0\n", truncated: false } },
}, next);
await stop(mkAgent(sid3, "ok.\nStatus: complete\nEvidence: " + cmd3 + " | exit=0 | 2026-10-20T04:00:00Z"));
out.adr011 = count(sid3);
out.adr011_note = inbox.find((e) => e.id === sid3)?.msg?.content?.[0]?.text?.slice(0, 900) ?? null;
// (4) the advice followed: X alone; a cut stderr changes nothing
const sid4 = "dsh-adr011-alone";
const cmd4 = "bash tests/x.sh";
const exec4 = { name: "bash", arguments: { command: cmd4 }, agent: mkAgent(sid4, "") };
await handlers.get("tools/pre-execute")(exec4, next);
await handlers.get("tools/post-execute")(exec4, {
  content: [{ type: "text", text: "ok\n[stderr]\n" + "w".repeat(100) }],
  value: { kind: "foreground", exitCode: 0, signal: null, timedOut: false, aborted: false, timeoutMs: 120000,
    stdout: { text: "ok\n", truncated: false }, stderr: { text: "w".repeat(100), truncated: true } },
}, next);
await stop(mkAgent(sid4, "ok.\nStatus: complete\nEvidence: " + cmd4 + " | ok | 2026-10-20T04:00:00Z"));
out.adr011_alone = count(sid4);
out.adr011_alone_note = inbox.find((e) => e.id === sid4)?.msg?.content?.[0]?.text?.slice(0, 300) ?? null;
// (5) a long stderr must not push stdout's last line out of the recorded sample
const sid5 = "dsh-adr011-sample";
const exec5 = { name: "bash", arguments: { command: "pytest -q" }, agent: mkAgent(sid5, "") };
const so5 = "y".repeat(2500) + "\n3 passed\n";
await handlers.get("tools/pre-execute")(exec5, next);
await handlers.get("tools/post-execute")(exec5, {
  content: [{ type: "text", text: so5 + "[stderr]\n" + "w".repeat(5000) }],
  value: { kind: "foreground", exitCode: 0, signal: null, timedOut: false, aborted: false, timeoutMs: 120000,
    stdout: { text: so5, truncated: false }, stderr: { text: "w".repeat(5000), truncated: false } },
}, next);
await stop(mkAgent(sid5, "ok.\nStatus: complete\nEvidence: pytest -q | 3 passed | 2026-10-20T04:00:00Z"));
out.adr011_sample = count(sid5);
out.adr011_sample_note = inbox.find((e) => e.id === sid5)?.msg?.content?.[0]?.text?.slice(0, 300) ?? null;
// (6) no structured exit code: the text marker proves failure only
for (const [id, tail] of [["dsh-fb-0", "[exit code: 0]"], ["dsh-fb-2", "[exit code: 2]"]]) {
  const e6 = { name: "bash", arguments: { command: "bash tests/x.sh" }, agent: mkAgent(id, "") };
  await handlers.get("tools/pre-execute")(e6, next);
  await handlers.get("tools/post-execute")(e6, { content: [{ type: "text", text: "output\n" + tail }], value: { kind: "promoted" } }, next);
}
console.log(JSON.stringify(out));
JS
res="$(cd "$SB" && "$NODE" --experimental-strip-types --no-warnings drive.mts 2>"$SB/err.log")" || { echo "FAIL: node run"; cat "$SB/err.log"; exit 1; }
echo "$res"
fail=0
python3 -I - "$res" <<'PY' || fail=1
import json, sys
r = json.loads(sys.argv[1])
assert r["budget"] == ["steer", "steer"], f"steer budget spent: the release note entered the inbox {r['budget']}"
assert r["released"] == [], f"python release (would_block): the note entered the inbox {r['released']}"
print("PASS: released claims never wake the agent (steer x2 then no inbox delivery; would_block -> no delivery)")
PY
if [ "$(grep -c 'evidence unverified' "$SB/err.log")" -ge 2 ]; then
  echo "PASS: both release notes are visible on stderr"
else echo "FAIL: release note missing from stderr"; cat "$SB/err.log"; fail=1; fi
python3 -I - "$res" <<'PY' || fail=1
import json, sys
r = json.loads(sys.argv[1])
assert r["evidence"] == [], f"honest Status: complete + Evidence was gated: {r['evidence']} {r['evidence_note']}"
print("PASS: rc from result.value.exitCode -> honest Evidence trailer passes the gate")
PY
python3 -I - "$res" <<'PY' || fail=1
import json, sys
r = json.loads(sys.argv[1])
assert r["adr011"] == ["steer"] and "run the command on its own" in (r["adr011_note"] or ""), f"echo line judged from its output on a code-reporting entry: {r['adr011']} {r['adr011_note']}"
print("PASS: ADR-011 dsh reports exit codes -> the echo line is gated and told to run the command on its own")
assert r["adr011_alone"] == [], f"the advice followed (X alone, rc 0) was gated: {r['adr011_alone']} {r['adr011_alone_note']}"
print("PASS: ADR-011 the advice followed (X alone, exitCode 0, stderr cut) passes")
assert r["adr011_sample"] == [], f"stdout summary lost to a long stderr: {r['adr011_sample']} {r['adr011_sample_note']}"
print("PASS: ADR-011 a long stderr keeps stdout's last line in the recorded sample")
PY
python3 -I - "$SB/state" <<'PY' || fail=1
import glob, json, sys
rc = {}
for f in glob.glob(sys.argv[1] + "/sessions/dsh__dsh-fb-*.jsonl"):
    for line in open(f, encoding="utf-8"):
        r = json.loads(line)
        if r.get("event") == "post":
            rc[f.split("dsh__")[1].split(".")[0]] = r.get("rc")
assert rc == {"dsh-fb-0": None, "dsh-fb-2": 2}, f"text fallback: {rc}"
print("PASS: ADR-011 the dsh text fallback proves failure only ([exit code: 0] -> rc null, [exit code: 2] -> rc 2)")
PY
if grep -rqs '"rc": 0' "$SB/state" || grep -rqs '"rc":0' "$SB/state"; then
  echo "PASS: post row recorded rc 0"
else echo "FAIL: post row has no rc 0"; grep -rh '"post"' "$SB/state" | head -3; fail=1; fi
exit "$fail"
