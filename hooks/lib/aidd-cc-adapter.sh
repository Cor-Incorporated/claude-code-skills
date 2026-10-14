#!/usr/bin/env bash
# Shared adapter for the Claude Code and Codex hook wire formats (H17 common control).
#
#   AIDD_CC_AGENT=claude-code|codex  bash aidd-cc-adapter.sh  < hook-payload.json
#
# Dispatches on hook_event_name and converts the aidd_cc.py verdict into the
# harness wire format.  Both harnesses accept the same JSON shapes:
#   PreToolUse        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":..}}
#   PermissionRequest {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
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

if [ -z "$CC_PY" ] || ! command -v python3 >/dev/null 2>&1; then
  ledger_error "module-or-python-missing"
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

case "$event" in
  PreToolUse)
    v="$(run_cc pre)"
    if [ "$(field "$v" decision)" = "block" ]; then
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
  PermissionRequest)
    v="$(run_cc permission)"
    if [ "$(field "$v" decision)" = "allow" ]; then
      printf '%s' "$v" | python3 -I -c 'import json,sys
v=json.load(sys.stdin)
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}},"systemMessage":"[H17] "+v["reason"]},ensure_ascii=False))'
    fi
    ;;
  Stop)
    v="$(run_cc stop)"
    if [ "$(field "$v" decision)" = "block" ]; then
      printf '%s' "$v" | python3 -I -c 'import json,sys
v=json.load(sys.stdin)
print(json.dumps({"decision":"block","reason":"[H17] "+v["reason"]},ensure_ascii=False))'
    fi
    ;;
  *)
    ledger_error "unknown-event:${event:-none}"
    ;;
esac
exit 0
