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
# setup.sh deploys both launchers when ~/.local/bin exists
grep -q 'pi/launcher/pi' "$ROOT/setup.sh" && grep -q 'dsh/launcher/dsh' "$ROOT/setup.sh" && ok "setup.sh copies both launchers" || bad "setup.sh does not copy the launchers"
echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
