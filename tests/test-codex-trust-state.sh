#!/usr/bin/env bash
# Issue #103: a Codex hook can satisfy all three documented deploy requirements
# (file in repo / copied into ~/.codex/hooks / registered in hooks.json) and still
# never run, because config.toml carries a per-position trust entry and an
# untrusted hook is skipped SILENTLY.
#
# 2026-09-01 実測: protect-branches-codex.sh fired zero times for 19 days with
# `enabled = false`. pair7 (registration -> file exists) and pair11 (source ->
# deployed MD5) both PASSED throughout, because neither reads trust state.
#
# Falsifiable: make the reporter ignore the `enabled` field and cases 1-2 go green
# while the guard is dead.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORTER="$ROOT/hooks/lib/codex-trust-state.py"
export AIDD_LEDGER_SOURCE=test

PASS=0
FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; echo "  $2"; FAIL=$((FAIL + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

cat > "$SB/hooks.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[
  {"type":"command","command":"bash /x/.codex/hooks/protect-branches-codex.sh"},
  {"type":"command","command":"bash /x/.codex/hooks/h1-stall-runtime.sh"}]}]}}
JSON

run() { python3 "$REPORTER" "$SB/hooks.json" "$1" 2>/dev/null; }

# --- case 1: the actual 19-day outage — enabled = false at 0:0 ---
cat > "$SB/disabled.toml" <<'TOML'
[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:aaa"
enabled = false

[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:1"]
trusted_hash = "sha256:bbb"
enabled = true
TOML
out="$(run "$SB/disabled.toml")"
if [[ "$(printf '%s' "$out" | grep -c 'protect-branches-codex.sh')" -eq 1 ]] \
   && printf '%s' "$out" | grep -q 'trust disabled' \
   && [[ "$(printf '%s' "$out" | grep -c 'h1-stall-runtime.sh')" -eq 0 ]]; then
  ok "case1 disabled hook reported, enabled sibling not reported"
else
  bad "case1 disabled hook not reported correctly" "$out"
fi

# --- case 2: registered but never trusted (no entry at all) ---
cat > "$SB/absent.toml" <<'TOML'
[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:aaa"
enabled = true
TOML
out="$(run "$SB/absent.toml")"
if printf '%s' "$out" | grep -q 'h1-stall-runtime.sh' \
   && printf '%s' "$out" | grep -q 'no trust entry'; then
  ok "case2 hook without a trust entry is reported"
else
  bad "case2 missing trust entry not reported" "$out"
fi

# --- case 3: everything trusted — the guard must stay quiet ---
cat > "$SB/ok.toml" <<'TOML'
[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:0"]
enabled = true

[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:1"]
enabled = true
TOML
n="$(run "$SB/ok.toml" | grep -c . || true)"
if [[ "$n" -eq 0 ]]; then
  ok "case3 no false positive when every hook is trusted"
else
  bad "case3 false positive" "$(run "$SB/ok.toml")"
fi

# --- case 4: `enabled` omitted. Codex treats that as active, so must stay quiet ---
cat > "$SB/unset.toml" <<'TOML'
[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:aaa"

[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:1"]
trusted_hash = "sha256:bbb"
TOML
n="$(run "$SB/unset.toml" | grep -c . || true)"
if [[ "$n" -eq 0 ]]; then
  ok "case4 omitted 'enabled' is not treated as disabled"
else
  bad "case4 false positive on omitted enabled" "$(run "$SB/unset.toml")"
fi

# --- case 5: unreadable config must not break the SessionStart hook ---
printf 'not toml [[[\n' > "$SB/broken.toml"
run "$SB/broken.toml" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "case5 unreadable config exits 0 (warn-only reporter never breaks its caller)"
else
  bad "case5 reporter exited non-zero" "rc=$rc"
fi

# --- case 6: missing files are a no-op, not a crash ---
python3 "$REPORTER" "$SB/nope.json" "$SB/nope.toml" >/dev/null 2>&1
if [[ "$?" -eq 0 ]]; then
  ok "case6 missing inputs exit 0"
else
  bad "case6 missing inputs crashed" ""
fi

echo "--- $PASS passed, $FAIL failed ---"
[[ "$FAIL" -eq 0 ]]
