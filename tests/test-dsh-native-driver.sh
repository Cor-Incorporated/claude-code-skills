#!/usr/bin/env bash
# dsh native plugin (dsh/aidd-cc-native.mts) — drives its handlers with a fake dsh agent against the real python
# oracle. No dsh install and no API key: `@deepseek-ai/dsh-llm` is stubbed in the sandbox. Needs node >= 22.
#   (1) note loop (owner live run 2026-10-19 12:49:53Z-12:50:10Z: 4 would-block rows): a released claim's note must not
#       enter the agent inbox (inject / steer / followup / send wake another model turn) — it goes to stderr.
#   (2) exit status (ccs#421): dsh-tool-bash writes `[exit code: N]` only for N != 0, so the post row must take
#       `result.value.exitCode`; an honest `Status: complete` + Evidence trailer then passes the gate.
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
if grep -rqs '"rc": 0' "$SB/state" || grep -rqs '"rc":0' "$SB/state"; then
  echo "PASS: post row recorded rc 0"
else echo "FAIL: post row has no rc 0"; grep -rh '"post"' "$SB/state" | head -3; fail=1; fi
exit "$fail"
