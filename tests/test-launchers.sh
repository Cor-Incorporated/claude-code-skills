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
# dsh key injection (2026-10-25): a fake install, a fake bw-secrets and a fake `security` stand in for the real ones.
DH="$SB/dshhome"; mkdir -p "$DH/.dsh-aidd/pkg/node_modules/.bin" "$SB/dbin"
cat >"$DH/.dsh-aidd/pkg/node_modules/.bin/dsh" <<'FAKE'
#!/usr/bin/env bash
printf 'dsh-bin key=%s bw=%s args=%s\n' "${DEEPSEEK_API_KEY:-unset}" "${BW_SESSION:-unset}" "$*"
printf 'dsh-env s=%s\n' "${s:-unset}"
FAKE
cat >"$SB/dbin/bw-secrets" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = check ]; then printf 'bw-secrets check %s bw=%s\n' "$2" "${BW_SESSION:-unset}"; exit "${FAKE_BW_CHECK_RC:-0}"; fi
printf 'bw-secrets %s %s %s bw=%s\n' "$1" "$2" "$3" "${BW_SESSION:-unset}"; shift 3
# like the real one: the child gets the key and no vault session (Codex r2 P2: keep `env`, really start the child)
exec env -u BW_SESSION DEEPSEEK_API_KEY=fake-from-bw "$@"
FAKE
mkdir -p "$DH/.local/bin"; cp "$SB/dbin/bw-secrets" "$DH/.local/bin/bw-secrets"
cat >"$SB/dbin/security" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SEC_LOG:?}"; printf '%s\n' "${FAKE_SESSION:?}"
FAKE
chmod +x "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh" "$SB/dbin/"* "$DH/.local/bin/bw-secrets"
dshrun() { HOME="$DH" PATH="$SB/dbin:$PATH" DSH_SECURITY_BIN="$SB/dbin/security" SEC_LOG="$SB/sec.log" bash "$ROOT/dsh/launcher/dsh" "$@" 2>&1; }
# Every row checks the fake dsh's own line (it really started: Codex r2 P2) and the launcher's exit code; a vault
# session must never reach dsh (`bw=unset` on every dsh-bin line: Codex r2 P1).
INJ='^dsh-bin key=fake-from-bw bw=unset args=web --patch'
# (1) a key in the environment: run directly, never touch the keychain, BW_SESSION from the shell is dropped
: >"$SB/sec.log"; o="$(DEEPSEEK_API_KEY=k BW_SESSION=shellsess FAKE_SESSION=x dshrun web --no-open)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q '^dsh-bin key=k bw=unset args=web --patch' && [ ! -s "$SB/sec.log" ]; then ok "dsh launcher: env key runs directly without a keychain read or BW_SESSION"; else bad "dsh env key: rc=$rc $o $(cat "$SB/sec.log")"; fi
# (2a) BW_SESSION in the shell: bw-secrets injects, the keychain is not read, dsh starts with the key
: >"$SB/sec.log"; o="$(DEEPSEEK_API_KEY= BW_SESSION=shellsess FAKE_SESSION=x dshrun web --no-open)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q '^bw-secrets run DEEPSEEK_API_KEY=DEEPSEEK_API_KEY -- bw=shellsess' && printf '%s' "$o" | grep -q "$INJ" && [ ! -s "$SB/sec.log" ]; then ok "dsh launcher: shell BW_SESSION injects through bw-secrets"; else bad "dsh shell session: rc=$rc $o"; fi
# (2b) no BW_SESSION, keychain holds a session: it is exported and bw-secrets injects — the owner's `dsh web` case
: >"$SB/sec.log"; o="$(DEEPSEEK_API_KEY= BW_SESSION= FAKE_SESSION='AbC123+/=AbC123+/=' dshrun web --no-open)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q '^bw-secrets run DEEPSEEK_API_KEY=DEEPSEEK_API_KEY -- bw=AbC123+/=AbC123+/=' && printf '%s' "$o" | grep -q "$INJ" && grep -q 'find-generic-password -s bw-session -a .* -w' "$SB/sec.log"; then ok "dsh launcher: keychain bw-session is used when the shell has none"; else bad "dsh keychain session: rc=$rc $o / $(cat "$SB/sec.log")"; fi
# (2c) a keychain value that is not a session token (spaces, too short) is ignored: start without a key and say so
for junk in 'not a token at all' 'short'; do
  o="$(DEEPSEEK_API_KEY= BW_SESSION= FAKE_SESSION="$junk" dshrun web --no-open)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'starting without a key' && printf '%s' "$o" | grep -q '^dsh-bin key=unset bw=unset args=web --patch' && ! printf '%s' "$o" | grep -q bw-secrets; then ok "dsh launcher: keychain junk [$junk] is ignored, no bw-secrets, notice printed"; else bad "dsh keychain junk [$junk]: rc=$rc $o"; fi
done
# (2d) Codex r1 P2 / r2 P1: a well-formed but unusable session (`check` fails) must not stop dsh, and the session read
# from the keychain or the shell must not reach the bare dsh
for sess in '' shellsess; do
  o="$(DEEPSEEK_API_KEY= BW_SESSION="$sess" FAKE_SESSION='AbC123+/=AbC123+/=' FAKE_BW_CHECK_RC=1 dshrun web --no-open)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'could not be read from it' && printf '%s' "$o" | grep -q '^dsh-bin key=unset bw=unset args=web --patch' && ! printf '%s' "$o" | grep -q 'bw-secrets run'; then ok "dsh launcher: unusable session [shell=${sess:-none}] falls back to a bare start without BW_SESSION"; else bad "dsh unusable session [shell=${sess:-none}]: rc=$rc $o"; fi
done
# (2d') Codex r3 P2: an exported `s` in the caller must not carry the keychain session into the child
o="$(export s=caller-exported; DEEPSEEK_API_KEY= BW_SESSION= FAKE_SESSION='AbC123+/=AbC123+/=' FAKE_BW_CHECK_RC=1 dshrun web --no-open)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q '^dsh-env s=unset$' && printf '%s' "$o" | grep -q '^dsh-bin key=unset bw=unset'; then ok "dsh launcher: an exported caller variable s does not leak the session"; else bad "dsh exported s: rc=$rc $o"; fi
# (2e) Codex r1 P2: a GUI launch has no ~/.local/bin on PATH; bw-secrets is resolved from its install path
o="$(HOME="$DH" PATH="/usr/bin:/bin" DSH_SECURITY_BIN="$SB/dbin/security" SEC_LOG="$SB/sec.log" DEEPSEEK_API_KEY= BW_SESSION= FAKE_SESSION='AbC123+/=AbC123+/=' bash "$ROOT/dsh/launcher/dsh" web --no-open 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q '^bw-secrets run DEEPSEEK_API_KEY=DEEPSEEK_API_KEY -- bw=AbC123+/=AbC123+/=' && printf '%s' "$o" | grep -q "$INJ"; then ok "dsh launcher: bw-secrets found at ~/.local/bin on a minimal PATH"; else bad "dsh minimal PATH: rc=$rc $o"; fi
# mutation (red): the fake dsh exits 3 -> the launcher's exit code is the child's, so the rc checks above are live
printf '#!/usr/bin/env bash\nexit 3\n' >"$DH/.dsh-aidd/pkg/node_modules/.bin/dsh.rc3"; chmod +x "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh.rc3"
mv "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh" "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh.ok"; cp "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh.rc3" "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh"
DEEPSEEK_API_KEY= BW_SESSION= FAKE_SESSION='AbC123+/=AbC123+/=' dshrun web --no-open >/dev/null; rc=$?
[ "$rc" -eq 3 ] && ok "dsh launcher: the child's exit code is the launcher's (mutation rc=3 seen)" || bad "dsh launcher rc pass-through: rc=$rc"
mv -f "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh.ok" "$DH/.dsh-aidd/pkg/node_modules/.bin/dsh"
# the notice goes to stderr only, so a headless answer on stdout stays clean
o="$(HOME="$DH" PATH="$SB/dbin:$PATH" DSH_SECURITY_BIN="$SB/dbin/security" SEC_LOG="$SB/sec.log" DEEPSEEK_API_KEY= BW_SESSION= FAKE_SESSION=short bash "$ROOT/dsh/launcher/dsh" "task" 2>/dev/null)"
printf '%s' "$o" | grep -q 'starting without a key' && bad "dsh launcher notice leaked to stdout" || ok "dsh launcher notice stays on stderr"
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
grep -q 'pi/launcher/pi' "$ROOT/setup.sh" && grep -q 'dsh/launcher/dsh' "$ROOT/setup.sh" && grep -q 'opencode/launcher/opencode2' "$ROOT/setup.sh" && grep -q 'Registered aidd-cc-v2' "$ROOT/setup.sh" && grep -q 'dsh/aidd-cc-native.mts" "$HOME/.dsh-aidd/pkg/aidd-cc-native.mts' "$ROOT/setup.sh" && ok "setup.sh copies the launchers, registers aidd-cc-v2 and deploys the dsh plugin" || bad "setup.sh does not copy the launchers"
echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
