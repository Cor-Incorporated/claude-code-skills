#!/usr/bin/env bash
# pair15 of tests/test-pairs-link.sh (hooks.json registration <-> config.toml
# trust) against a fake HOME. CI runners have no ~/.codex, so without this CI
# only ever runs pair15's skip path.
#
# Since 2026-09-25 pair15 takes the inactive states from the reporter's
# inactive(). Before that it named them itself (disabled, absent), and the
# states the reporter gained that day would have passed pair15 without a word:
# measured with a fake HOME, a header-only entry (Codex: untrusted) gave PASS.
# Falsifiable: restore that two-state loop and the untrusted and invalid cases
# below go red.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AIDD_LEDGER_SOURCE=test

PASS=0
FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; echo "  $2"; FAIL=$((FAIL + 1)); }

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/.codex"
cat > "$FAKE/.codex/hooks.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[
  {"type":"command","command":"bash /x/.codex/hooks/a.sh"},
  {"type":"command","command":"bash /x/.codex/hooks/b.sh"}]}]}}
JSON
K="$FAKE/.codex/hooks.json"
TRUSTED_A="[hooks.state.\"$K:pre_tool_use:0:0\"]
trusted_hash = \"sha256:a\"
"

# pair15 <config.toml>: the pair15 line of test-pairs-link.sh and its detail line.
pair15() {
  printf '%s' "$1" > "$FAKE/.codex/config.toml"
  HOME="$FAKE" bash "$ROOT/tests/test-pairs-link.sh" 2>&1 | grep -A1 'pair15'
}

out="$(pair15 "${TRUSTED_A}
[hooks.state.\"$K:pre_tool_use:0:1\"]
trusted_hash = \"sha256:b\"
enabled = true
")"
if printf '%s' "$out" | grep -q '^PASS: pair15'; then
  ok "pair15 passes when both registered hooks are trusted"
else
  bad "pair15 did not pass on a trusted config" "${out:-<no pair15 line>}"
fi

# red <label> <state> <config.toml>: pair15 must fail and name b.sh with <state>.
red() {
  local out
  out="$(pair15 "$3")"
  if printf '%s' "$out" | grep -q '^FAIL: pair15' \
     && printf '%s' "$out" | grep -qF "pre_tool_use:0:1(b.sh) trust=$2"; then
    ok "pair15 fails on $1 (trust=$2)"
  else
    bad "pair15 missed $1" "${out:-<no pair15 line>}"
  fi
}

red "a header-only entry" untrusted "${TRUSTED_A}
[hooks.state.\"$K:pre_tool_use:0:1\"]
"
red "enabled=false without spaces" disabled "${TRUSTED_A}
[hooks.state.\"$K:pre_tool_use:0:1\"]
trusted_hash = \"sha256:b\"
enabled=false
"
red "a stale entry of the wrong type" invalid "${TRUSTED_A}
[hooks.state.\"$K:pre_tool_use:0:1\"]
trusted_hash = \"sha256:b\"

[hooks.state.\"$K:pre_tool_use:0:7\"]
enabled = \"no\"
"

echo "--- $PASS passed, $FAIL failed ---"
[[ "$FAIL" -eq 0 ]]
