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
# while the guard is dead. Restore the two-entry event map and cases 7-10 go red;
# add only UserPromptSubmit to that map and case 10 stays red; make the reporter
# crash on the entry shape Codex writes and cases 7 and 10 go red.
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
if python3 "$REPORTER" "$SB/nope.json" "$SB/nope.toml" >/dev/null 2>&1; then
  ok "case6 missing inputs exit 0"
else
  bad "case6 missing inputs crashed" ""
fi

# --- cases 7-10: event names other than PreToolUse (2026-09-24 実測) ---
# hooks.json spells events in PascalCase, config.toml keys trust in snake_case.
# The reporter mapped only PreToolUse/PostToolUse and fell back to lower(), so
# the UserPromptSubmit hook that Codex had trusted was looked up as
# "userpromptsubmit:0:0" and reported "no trust entry" at every SessionStart.
cat > "$SB/ups.json" <<'JSON'
{"hooks":{"UserPromptSubmit":[{"hooks":[
  {"type":"command","command":"bash /x/.codex/hooks/h1-stall-runtime.sh"}]}]}}
JSON

run_ups() { python3 "$REPORTER" "$SB/ups.json" "$1" 2>/dev/null; }

# --- case 7: the entry Codex wrote — trusted_hash, no `enabled` line ---
# No output is also what a crashing reporter prints (main() turns errors into
# silence), so the same config is read again with an untrusted sentinel
# registered after the hook: that run must report the sentinel and nothing else.
cat > "$SB/ups-trusted.toml" <<'TOML'
[hooks.state."/x/.codex/hooks.json:user_prompt_submit:0:0"]
trusted_hash = "sha256:ccc"
TOML
cat > "$SB/ups-sentinel.json" <<'JSON'
{"hooks":{"UserPromptSubmit":[{"hooks":[
  {"type":"command","command":"bash /x/.codex/hooks/h1-stall-runtime.sh"},
  {"type":"command","command":"bash /x/.codex/hooks/sentinel.sh"}]}]}}
JSON
n="$(run_ups "$SB/ups-trusted.toml" | grep -c . || true)"
sentinel="$(python3 "$REPORTER" "$SB/ups-sentinel.json" "$SB/ups-trusted.toml" 2>/dev/null)"
if [[ "$n" -eq 0 ]] \
   && [[ "$(printf '%s\n' "$sentinel" | grep -c .)" -eq 1 ]] \
   && printf '%s' "$sentinel" | grep -qF 'sentinel.sh at user_prompt_submit:0:1 (no trust entry)'; then
  ok "case7 trusted UserPromptSubmit hook is not reported (its untrusted sibling is)"
else
  bad "case7 trusted UserPromptSubmit hook misreported" \
    "hook-only=$(run_ups "$SB/ups-trusted.toml") with-sentinel=${sentinel:-<nothing>}"
fi

# --- case 8: no user_prompt_submit entry — still reported, at Codex's key ---
cat > "$SB/ups-absent.toml" <<'TOML'
[hooks.state."/x/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:aaa"
enabled = true
TOML
out="$(run_ups "$SB/ups-absent.toml")"
if printf '%s' "$out" | grep -qF 'h1-stall-runtime.sh at user_prompt_submit:0:0 (no trust entry)'; then
  ok "case8 untrusted UserPromptSubmit hook is reported at user_prompt_submit:0:0"
else
  bad "case8 untrusted UserPromptSubmit hook not reported at the key Codex writes" "$out"
fi

# --- case 9: enabled = false — still reported, as disabled ---
cat > "$SB/ups-disabled.toml" <<'TOML'
[hooks.state."/x/.codex/hooks.json:user_prompt_submit:0:0"]
trusted_hash = "sha256:ccc"
enabled = false
TOML
out="$(run_ups "$SB/ups-disabled.toml")"
if printf '%s' "$out" | grep -qF 'h1-stall-runtime.sh at user_prompt_submit:0:0 (trust disabled)'; then
  ok "case9 disabled UserPromptSubmit hook is reported as trust disabled"
else
  bad "case9 disabled UserPromptSubmit hook not reported as disabled" "$out"
fi

# --- case 10: every event Codex CLI 0.156.0 knows, not only the ones in use ---
# Names: HookEventsToml in the 0.156.0 binary. Keys: the snake_case list that
# precedes "normalized hook identity should serialize to TOML" in the same binary
# holds the 10 multi-word names (strings, 2026-09-24); stop and interrupt are
# single words and are not in it. Only pre_tool_use and user_prompt_submit have
# been seen in a real config.toml. A per-event map passes cases 7-9 once
# UserPromptSubmit is added to it, and fails here.
events=(PreToolUse PermissionRequest PostToolUse PreCompact PostCompact
  SessionStart SessionEnd UserPromptSubmit SubagentStart SubagentStop
  Stop Interrupt)
keys=(pre_tool_use permission_request post_tool_use pre_compact post_compact
  session_start session_end user_prompt_submit subagent_start subagent_stop
  stop interrupt)
{
  printf '{"hooks":{'
  for i in "${!events[@]}"; do
    [[ "$i" -gt 0 ]] && printf ','
    printf '"%s":[{"hooks":[{"type":"command","command":"bash /x/h-%s.sh"}]}]' \
      "${events[$i]}" "${events[$i]}"
  done
  printf '}}\n'
} > "$SB/all.json"

run_all() { python3 "$REPORTER" "$SB/all.json" "$1" 2>/dev/null; }

# Trust every event but one, for each event in turn: the run must report exactly
# that event, at its snake_case key. Each run has to print one line, so the
# silence of the other 11 cannot come from a crash.
wrong=()
for i in "${!events[@]}"; do
  for j in "${!keys[@]}"; do
    [[ "$j" -eq "$i" ]] && continue
    printf '[hooks.state."/x/.codex/hooks.json:%s:0:0"]\ntrusted_hash = "sha256:%s"\n\n' \
      "${keys[$j]}" "${keys[$j]}"
  done > "$SB/all-but-one.toml"
  out="$(run_all "$SB/all-but-one.toml")"
  if [[ "$(printf '%s\n' "$out" | grep -c .)" -ne 1 ]] \
     || ! printf '%s' "$out" | grep -qF "h-${events[$i]}.sh at ${keys[$i]}:0:0 (no trust entry)"; then
    got="$(printf '%s\n' "$out" | sed -n 's/^CODEX HOOK NOT ACTIVE: \([^ ]*\) at \([^ ]*\) .*/\1@\2/p' | tr '\n' ' ')"
    wrong+=("${events[$i]}: want ${keys[$i]}:0:0, got ${got:-nothing};")
  fi
done
# Nothing trusted: every event must be reported, not only the first one.
: > "$SB/none.toml"
out="$(run_all "$SB/none.toml")"
lines="$(printf '%s\n' "$out" | grep -c . || true)"
[[ "$lines" -eq ${#events[@]} ]] \
  || wrong+=("all untrusted: want ${#events[@]} lines, got ${lines};")
if [[ ${#wrong[@]} -eq 0 ]]; then
  ok "case10 all ${#events[@]} events: silent when trusted, reported at the snake_case key when not"
else
  bad "case10 events not keyed the way Codex writes them" "${wrong[*]}"
fi

echo "--- $PASS passed, $FAIL failed ---"
[[ "$FAIL" -eq 0 ]]
