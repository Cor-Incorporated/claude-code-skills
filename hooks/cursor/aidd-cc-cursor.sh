#!/usr/bin/env bash
# Cursor entry for the H17 common control (hooks.json version 1).
#   beforeShellExecution -> pre            {"permission":"deny","agent_message"} | {"permission":"allow"}
#   afterShellExecution  -> post           (record exit/output for evidence binding)
#   beforeSubmitPrompt   -> prompt         {"continue":true}
#   afterAgentResponse   -> record-assistant (last text, for the stop check)
#   stop                 -> stop           {"followup_message": "..."} when a claim lacks evidence
# Session key: conversation_id.  Deployed to ~/.cursor/hooks/aidd-cc-cursor.sh.
set -uo pipefail
CC_PY=""
for cand in "${AIDD_CC_PY:-}" "$HOME/.claude/hooks/lib/aidd_cc.py" \
            "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)/aidd_cc.py"; do
  [ -n "$cand" ] && [ -f "$cand" ] && CC_PY="$cand" && break
done
input="$(cat 2>/dev/null || true)"
[ "${AIDD_CC_DISABLE:-0}" = "1" ] && { printf '{"permission":"allow"}'; exit 0; }
if [ -z "$CC_PY" ]; then
  ledger="${AIDD_LEDGER_PATH:-$HOME/.claude/hooks/ledger/guard-ledger.jsonl}"; mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
  printf '{"ts":"%s","component":"H17","hook":"aidd-cc","event":"error","decision":"unavailable","rule":"module-missing","cmd_head":"","source":"%s","session":"unset","agent":"cursor"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${AIDD_LEDGER_SOURCE:-real}" >>"$ledger" 2>/dev/null || true
  printf '{"permission":"allow"}'; exit 0
fi

py() {
  local out rc
  out="$(printf '%s' "$input" | AIDD_CC_AGENT=cursor python3 -I "$CC_PY" "$@" --agent cursor 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    ledger="${AIDD_LEDGER_PATH:-$HOME/.claude/hooks/ledger/guard-ledger.jsonl}"
    printf '{"ts":"%s","component":"H17","hook":"aidd-cc","event":"error","decision":"unavailable","rule":"python-exit-%s","cmd_head":"","source":"%s","session":"unset","agent":"cursor"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "${AIDD_LEDGER_SOURCE:-real}" >>"$ledger" 2>/dev/null || true
  fi
  printf '%s' "$out"
}
jfield() { printf '%s' "$1" | python3 -I -c "import json,sys
try: print(json.load(sys.stdin).get('$2',''))
except Exception: print('')"; }
event="$(jfield "$input" hook_event_name)"

case "$event" in
  beforeShellExecution)
    v="$(py pre --tool Bash)"
    if [ "$(jfield "$v" decision)" = "block" ]; then
      printf '%s' "$v" | python3 -I -c 'import json,sys
v=json.load(sys.stdin); m="[H17] "+v["reason"]
print(json.dumps({"permission":"deny","user_message":m,"agent_message":m},ensure_ascii=False))'
    else
      printf '{"permission":"allow"}'
    fi
    ;;
  afterShellExecution) py post --tool Bash >/dev/null; printf '{}' ;;
  beforeSubmitPrompt) py prompt >/dev/null; printf '{"continue":true}' ;;
  afterAgentResponse) py record-assistant >/dev/null; printf '{}' ;;
  stop)
    v="$(py stop)"
    if [ "$(jfield "$v" decision)" = "block" ]; then
      printf '%s' "$v" | python3 -I -c 'import json,sys
v=json.load(sys.stdin)
print(json.dumps({"followup_message":"[H17] "+v["reason"]},ensure_ascii=False))'
    else
      printf '{}'
    fi
    ;;
  *) printf '{}' ;;
esac
exit 0
