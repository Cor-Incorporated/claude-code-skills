#!/usr/bin/env bash
# Entry launchers pi/launcher/pi and dsh/launcher/dsh (2026-10-18): syntax, help text, and the fail-closed paths that
# need no agent binary. The real agents are not required (CI has neither pi nor dsh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
bash -n "$ROOT/pi/launcher/pi" && bash -n "$ROOT/dsh/launcher/dsh" && ok "launchers parse" || bad "launcher syntax"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
# dsh: no install under a fake HOME -> exit 1 with the install hint (never a silent bare dsh)
o="$(HOME="$SB" bash "$ROOT/dsh/launcher/dsh" "task" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$o" | grep -q 'has no dsh'; then ok "dsh launcher fails closed without the ~/.dsh-aidd/pkg install"; else bad "dsh launcher: rc=$rc [$o]"; fi
# dsh: no arguments -> help, mentions the three modes and the no-TUI fact
o="$(HOME="$SB" bash "$ROOT/dsh/launcher/dsh" 2>&1)"
printf '%s' "$o" | grep -q 'has no dsh' && ok "dsh launcher checks the install before anything else" || bad "dsh help order: $o"
grep -q 'no terminal TUI' "$ROOT/dsh/launcher/dsh" && grep -q 'dsh web' "$ROOT/dsh/launcher/dsh" && ok "dsh launcher documents one-shot / session / web and the missing TUI" || bad "dsh launcher docs"
# pi: fail closed without the node-24 binary or the extension
o="$(HOME="$SB" bash "$ROOT/pi/launcher/pi" --version 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$o" | grep -q 'missing'; then ok "pi launcher fails closed without the pi binary"; else bad "pi launcher: rc=$rc [$o]"; fi
mkdir -p "$SB/.local/share/mise/installs/node/24.21.0/bin" "$SB/.pi/agent/extensions"
cat >"$SB/.local/share/mise/installs/node/24.21.0/bin/pi" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@"
FAKE
chmod +x "$SB/.local/share/mise/installs/node/24.21.0/bin/pi"; : >"$SB/.pi/agent/extensions/aidd-cc.ts"
# with a key in the environment the launcher runs pi directly, adds the extension and the default model, keeps -p
o="$(HOME="$SB" OPENROUTER_API_KEY=x BW_SESSION= bash "$ROOT/pi/launcher/pi" -p "hello" 2>&1)"
if printf '%s' "$o" | grep -q -- '-e' && printf '%s' "$o" | grep -q 'aidd-cc.ts' && printf '%s' "$o" | grep -q 'google/gemini-2.5-flash' && printf '%s' "$o" | grep -q -- '-p'; then ok "pi launcher: extension + default model + -p pass-through"; else bad "pi launcher args: $o"; fi
# an explicit --model is not overridden; --version bypasses the extension
o="$(HOME="$SB" OPENROUTER_API_KEY=x BW_SESSION= bash "$ROOT/pi/launcher/pi" --model anthropic/claude-haiku-4.5 -p "x" 2>&1)"
printf '%s' "$o" | grep -q 'gemini' && bad "pi launcher overrode --model" || ok "pi launcher keeps an explicit --model"
o="$(HOME="$SB" bash "$ROOT/pi/launcher/pi" --version 2>&1)"
printf '%s' "$o" | grep -q 'aidd-cc.ts' && bad "pi --version loaded the extension" || ok "pi --version is a plain pass-through"
# opencode2 (review #426): fail closed when the plugin cannot load; `run` detection; the ledger tail survives bad lines
L="$ROOT/opencode/launcher/opencode2"
bash -n "$L" && ok "opencode2 parses" || bad "opencode2 syntax"
mkdir -p "$SB/oc2/bin" "$SB/oc2/plugin" "$SB/oc2/cfg/opencode"
cat >"$SB/oc2/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OC2_ARGS_LOG:-/dev/null}"
[ -n "${AIDD_LEDGER_PATH:-}" ] && printf '{"ts":"2099-01-01T00:00:00Z","component":"H17","agent":"opencode","decision":"block","rule":"evidence.pending","session":"ses_t","cmd_head":"no status declared"}\n' >>"$AIDD_LEDGER_PATH"
exit 7
FAKE
chmod +x "$SB/oc2/bin/opencode"
o="$(HOME="$SB" XDG_CONFIG_HOME="$SB/oc2/cfg" OPENCODE_BIN_PATH="$SB/oc2/bin/opencode" AIDD_CC_V2_PLUGIN="$SB/oc2/plugin" OPENCODE_GUARDRAILS_BIN="$SB/none" bash "$L" run x 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$o" | grep -q 'H17 control would be OFF'; then ok "opencode2 fails closed without the plugin"; else bad "opencode2 no plugin: rc=$rc [$o]"; fi
: >"$SB/oc2/plugin/index.ts"
o="$(HOME="$SB" XDG_CONFIG_HOME="$SB/oc2/cfg" OPENCODE_BIN_PATH="$SB/oc2/bin/opencode" AIDD_CC_V2_PLUGIN="$SB/oc2/plugin" OPENCODE_GUARDRAILS_BIN="$SB/none" bash "$L" run x 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$o" | grep -q 'not listed'; then ok "opencode2 fails closed when the plugin is not registered"; else bad "opencode2 unregistered: rc=$rc [$o]"; fi
printf '{"plugins":["%s"]}\n' "$SB/oc2/plugin" >"$SB/oc2/cfg/opencode/opencode.json"
printf 'PREPUSH: not json\n{"ts": "bad \\q escape"}\n' >"$SB/oc2/ledger.jsonl"
o="$(HOME="$SB" XDG_CONFIG_HOME="$SB/oc2/cfg" OPENCODE_BIN_PATH="$SB/oc2/bin/opencode" AIDD_CC_V2_PLUGIN="$SB/oc2/plugin" OPENCODE_GUARDRAILS_BIN="$SB/none" AIDD_LEDGER_PATH="$SB/oc2/ledger.jsonl" bash "$L" run x 2>&1)"; rc=$?
if [ "$rc" -eq 7 ] && printf '%s' "$o" | grep -q '\[H17 block\] evidence.pending (session ses_t)' && ! printf '%s' "$o" | grep -q Traceback; then ok "opencode2 run: CLI rc kept, H17 row printed past malformed ledger lines"; else bad "opencode2 tail: rc=$rc [$o]"; fi
o="$(HOME="$SB" XDG_CONFIG_HOME="$SB/oc2/cfg" OPENCODE_BIN_PATH="$SB/oc2/bin/opencode" AIDD_CC_V2_PLUGIN="$SB/oc2/plugin" OPENCODE_GUARDRAILS_BIN="$SB/none" AIDD_LEDGER_PATH="$SB/oc2/ledger.jsonl" bash "$L" "please run tests" 2>&1)"
printf '%s' "$o" | grep -q '\[H17' && bad "opencode2 tailed for a TUI prompt containing 'run'" || ok "opencode2: 'run' inside a prompt is not the run subcommand"
# 2026-10-19: every invocation runs on a private server (the background service never gets this call's keys / profile)
: >"$SB/oc2/args.log"
for argv in "run -m openrouter/google/gemini-2.5-flash hi" "" "service status" "run --standalone x"; do
  # shellcheck disable=SC2086
  HOME="$SB" XDG_CONFIG_HOME="$SB/oc2/cfg" OPENCODE_BIN_PATH="$SB/oc2/bin/opencode" AIDD_CC_V2_PLUGIN="$SB/oc2/plugin" OPENCODE_GUARDRAILS_BIN="$SB/none" OC2_ARGS_LOG="$SB/oc2/args.log" AIDD_LEDGER_PATH= bash "$L" $argv >/dev/null 2>&1
done
expected="$(printf '%s\n' 'run --standalone -m openrouter/google/gemini-2.5-flash hi' '--standalone' 'service status' 'run --standalone x')"
if [ "$(cat "$SB/oc2/args.log")" = "$expected" ]; then ok "opencode2 adds --standalone (run after the subcommand, TUI first; service / explicit flag untouched)"; else bad "opencode2 args: $(tr '\n' '|' <"$SB/oc2/args.log")"; fi
# setup.sh deploys both launchers when ~/.local/bin exists
grep -q 'pi/launcher/pi' "$ROOT/setup.sh" && grep -q 'dsh/launcher/dsh' "$ROOT/setup.sh" && grep -q 'opencode/launcher/opencode2' "$ROOT/setup.sh" && grep -q 'Registered aidd-cc-v2' "$ROOT/setup.sh" && ok "setup.sh copies the launchers and registers aidd-cc-v2" || bad "setup.sh does not copy the launchers"
echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
