#!/usr/bin/env bash
# Shared adapter for the Claude Code and Codex hook wire formats (H17 common control).
#
#   AIDD_CC_AGENT=claude-code|codex  bash aidd-cc-adapter.sh  < hook-payload.json
#
# Dispatches on hook_event_name and converts the aidd_cc.py verdict into the
# harness wire format.  Both harnesses accept the same JSON shapes:
#   PreToolUse        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":..}}
#   (PermissionRequest: retired 2026-10-14 — H17 never auto-allows)
#   Stop              {"decision":"block","reason":..}
# Always exit 0: a non-zero exit from a hook is treated differently by each
# harness (Codex silently disables, Claude fails closed) and we want neither.
#
# Fail mode: if python3 or the module is missing we print nothing and record an
# `error` row in the H6 ledger; the harness then behaves as if the hook were
# absent.  That is a *visible* degradation (ledger), not a silent pass.
#
# AIDD_CC_DISABLE=1 turns the control off (used as the "before" arm in replay).
set -uo pipefail

AGENT="${AIDD_CC_AGENT:-claude-code}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_PY=""
for cand in "${AIDD_CC_PY:-}" "$HERE/aidd_cc.py" "$HOME/.claude/hooks/lib/aidd_cc.py"; do
  [ -n "$cand" ] || continue
  [ -f "$cand" ] && CC_PY="$cand" && break
done

input="$(cat 2>/dev/null || true)"
[ "${AIDD_CC_DISABLE:-0}" = "1" ] && exit 0

ledger_error() {
  local ledger="${AIDD_LEDGER_PATH:-$HOME/.claude/hooks/ledger/guard-ledger.jsonl}"
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
  printf '{"ts":"%s","component":"H17","hook":"aidd-cc","event":"error","decision":"unavailable","rule":"%s","cmd_head":"","source":"%s","session":"unset","agent":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${AIDD_LEDGER_SOURCE:-real}" "$AGENT" >>"$ledger" 2>/dev/null || true
}

# aidd-governance#186 P2-2: a degraded control is never silent at the harness.  Claude Code and Codex
# accept a top-level `systemMessage` on any hook event (shown to the user, no decision attached), so an
# unavailable / crashed control and a release that WOULD have blocked are both announced there, not only
# in the H6 ledger.  Nothing here ever turns into an allow or a deny on its own.
note() {
  # JSON built by python (review 2026-10-16 P2: a hand-escaped + byte-cut string could end on a lone backslash,
  # keep a tab, or split a multibyte character; macOS and GNU cut differ). Truncation happens BEFORE encoding.
  printf '%s' "$1" | python3 -I -c 'import json,sys
t=" ".join(sys.stdin.read().split())[:400]
print(json.dumps({"systemMessage":"[H17] "+t},ensure_ascii=False))' 2>/dev/null
}

if [ -z "$CC_PY" ] || ! command -v python3 >/dev/null 2>&1; then
  ledger_error "module-or-python-missing"
  note "common control unavailable (module or python3 missing): nothing was evaluated on this event"
  exit 0
fi

event="$(printf '%s' "$input" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("hook_event_name",""))
except Exception: print("")' 2>/dev/null)"

run_cc() {
  local out rc
  out="$(printf '%s' "$input" | AIDD_CC_AGENT="$AGENT" python3 -I "$CC_PY" "$@" --agent "$AGENT" 2>/dev/null)"; rc=$?
  # An import-time crash exits non-zero before _main_guarded can record it: record here.
  [ "$rc" -ne 0 ] && [ -z "$out" ] && ledger_error "python-exit-$rc:$1"
  printf '%s' "$out"
}

field() { printf '%s' "$1" | python3 -I -c "import json,sys
try:
    d=json.load(sys.stdin); print(d.get('$2',''))
except Exception: print('')" 2>/dev/null; }

# Cursor's Claude-Code-hooks compatibility layer calls this adapter with camelCase
# event names (preToolUse / postToolUse / stop / beforeSubmitPrompt / afterAgentResponse):
# observed live 2026-10-14 03:31 UTC as `unknown-event:preToolUse` error rows.
case "$event" in
  preToolUse) event=PreToolUse ;;
  postToolUse) event=PostToolUse ;;
  stop) event=Stop ;;
  userPromptSubmit|beforeSubmitPrompt) event=UserPromptSubmit ;;
  afterAgentResponse) run_cc record-assistant >/dev/null; exit 0 ;;
esac
case "$event" in
  PreToolUse)
    v="$(run_cc pre)"
    if [ "$(field "$v" decision)" = "error" ]; then
      note "control error on PreToolUse — iteration / re-ask NOT evaluated: $(field "$v" reason)"
    elif [ "$(field "$v" decision)" = "block" ]; then
      printf '%s' "$v" | python3 -I -c 'import json,sys
v=json.load(sys.stdin)
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[H17] "+v["reason"]}},ensure_ascii=False))'
    fi
    ;;
  PostToolUse|PostToolUseFailure)
    run_cc post >/dev/null
    ;;
  UserPromptSubmit)
    run_cc prompt >/dev/null
    ;;
  Stop)
    v="$(run_cc stop)"
    case "$(field "$v" decision)" in
      block)
        printf '%s' "$v" | python3 -I -c 'import json,sys
v=json.load(sys.stdin)
print(json.dumps({"decision":"block","reason":"[H17] "+v["reason"]},ensure_ascii=False))'
        ;;
      error)
        note "control error on Stop — this report passed UNVERIFIED: $(field "$v" reason)"
        ;;
      allow)
        # max-blocks / stop_hook_active release that would have blocked (#186 P1-4 / P2-1): the note the
        # Pi / OpenCode entries already show is now visible at the Claude Code / Codex entry too.
        if [ "$(field "$v" would_block)" = "True" ]; then
          note "$(field "$v" note | sed 's/^\[H17\] //') — $(field "$v" reason)"
        fi
        ;;
    esac
    ;;
  *)
    ledger_error "unknown-event:${event:-none}"
    ;;
esac
exit 0
