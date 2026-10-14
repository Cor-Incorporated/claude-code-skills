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
out.gate_appended = o1.text.includes("[H17 evidence gate]");
const o2 = { text: "途中経過です。次に tests を走らせます。" };
await hooks["experimental.text.complete"]({ sessionID: "oc-test-1", messageID: "m2", partID: "p2" }, o2);
out.benign_untouched = o2.text === "途中経過です。次に tests を走らせます。";
console.log(JSON.stringify(out));
JS
res="$(cd "$SB" && bun run drive.ts 2>"$SB/err.log")" || { echo "FAIL: bun run"; cat "$SB/err.log"; exit 1; }
echo "$res"
python3 -I - "$res" <<'PY' || exit 1
import json, sys
r = json.loads(sys.argv[1])
assert r["has_text_complete"] is True, r
assert r["has_permission_ask"] is False, r          # auto-allow retired 2026-10-14
assert r["iter_throw_at"] == 4, r
assert r["gate_appended"] is True, r
assert r["benign_untouched"] is True, r
print("PASS: text.complete gate present / no permission.ask / 4th identical call throws / benign untouched")
PY
grep -q '"component": "H17"' "$AIDD_LEDGER_PATH" && echo "PASS: H6 ledger rows written by the opencode entry" || { echo "FAIL: no ledger rows"; exit 1; }
