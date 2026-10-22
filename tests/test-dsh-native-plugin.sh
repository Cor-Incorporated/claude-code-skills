#!/usr/bin/env bash
# dsh native plugin (dsh/aidd-cc-native.mts) — activates on a DeepSeek Harness headless profile.
# Needs a dsh install (DSH_BIN, or node_modules/.bin/dsh under $DSH_PKG_DIR) and node >= 24; SKIPs otherwise
# (CI has neither). The LLM credential is NOT required: the plugin must be active before the credential check,
# so the only acceptable boot failure is MISSING_CREDENTIAL. A "did not activate" / "failed to import" line fails.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE24="${NODE24_BIN:-$HOME/.local/share/mise/installs/node/24.21.0/bin}"
DSH="${DSH_BIN:-${DSH_PKG_DIR:-}/node_modules/.bin/dsh}"
[ -x "$DSH" ] || { echo "SKIP: dsh not installed (set DSH_BIN or DSH_PKG_DIR)"; exit 0; }
[ -x "$NODE24/node" ] || { echo "SKIP: node 24 not installed"; exit 0; }
DSH="$(cd "$(dirname "$DSH")" && pwd)/$(basename "$DSH")"  # absolute before the probe moves into an empty dir (Codex r2 of #437)
PKG="$(cd "$(dirname "$DSH")/../.." && pwd)"           # the install prefix: imports resolve against its node_modules
[ -d "$PKG/node_modules/@deepseek-ai" ] || { echo "SKIP: $PKG has no @deepseek-ai node_modules (DSH_BIN must be a prefix install)"; exit 0; }
TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 120"; command -v gtimeout >/dev/null 2>&1 && TMO="gtimeout 120"
SB="$(mktemp -d)"; PLUGIN="$PKG/aidd-cc-native.test.mts"; trap 'rm -rf "$SB" "$PLUGIN"' EXIT
mkdir -p "$SB/home/profiles" && cp -R "${DSH_HOME:-$HOME/.dsh-aidd}/profiles/headless" "$SB/home/profiles/" 2>/dev/null || { echo "SKIP: no headless profile under ${DSH_HOME:-$HOME/.dsh-aidd}"; exit 0; }
cp "$ROOT/dsh/aidd-cc-native.mts" "$PLUGIN" || { echo "FAIL: cannot copy the plugin into $PKG"; exit 1; }
cat >"$SB/patch.yml" <<YML
- insert:
    - id: aidd-cc-native
      name: $PLUGIN
      config:
        oracle: $ROOT/hooks/lib/aidd_cc.py
- id: session-log-deepseek
  disabled: true
- id: session-telemetry-otel
  disabled: true
YML
# shellcheck disable=SC2086  # $TMO is intentionally word-split ("timeout 120" or empty)
# Codex r2 P2: an inherited provider key would turn this boot check into a real (billed) LLM call — strip it; the
# copied profile must be credential-free too (a configured profile makes this test FAIL on purpose, not SKIP).
# ccs#421: dsh's loadLayeredEnv() reads the dotenv file of the INVOKING directory and of the Harness home after the
# `env -u` above, so a key kept there came back. The probe runs from an empty directory, and dotenv copies are removed
# from the copied Harness home (their contents are never read). An `apiKeyEnv` alias in the profile is unset too.
mkdir -p "$SB/cwd"
find "$SB/home" -name '.env*' -type f -delete 2>/dev/null
alias_unset=()
while IFS= read -r v; do [ -n "$v" ] && alias_unset+=(-u "$v"); done < <(grep -rhoE 'apiKeyEnv:[[:space:]]*["'"'"']?[A-Z_][A-Z0-9_]*' "$SB/home" 2>/dev/null | sed -E 's/.*[:"'"'"'[:space:]]//')
out="$(cd "$SB/cwd" && env -u DEEPSEEK_API_KEY -u DEEPSEEK_API_BASE -u OPENAI_API_KEY -u ANTHROPIC_API_KEY ${alias_unset[@]+"${alias_unset[@]}"} PATH="$NODE24:$PATH" DSH_HOME="$SB/home" AIDD_LEDGER_PATH="$SB/l.jsonl" AIDD_LEDGER_SOURCE=test $TMO "$DSH" --profile headless --patch "$SB/patch.yml" "probe" 2>&1)"
if printf '%s' "$out" | grep -q 'did not activate\|failed to import'; then echo "FAIL: native plugin did not activate"; printf '%s\n' "$out" | tail -5; exit 1; fi
if printf '%s' "$out" | grep -q 'MISSING_CREDENTIAL'; then echo "PASS: dsh native plugin activates on the headless profile (boot reached the LLM credential check)"; else echo "FAIL: unexpected boot output"; printf '%s\n' "$out" | tail -5; exit 1; fi
