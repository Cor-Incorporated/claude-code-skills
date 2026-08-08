#!/usr/bin/env bash
# H3 Stop-hook adapter: warn on assertion without Evidence trailer (never hard-blocks)
# Reads Claude Code Stop hook JSON from stdin; fail-open on parse errors (do not stop session).
set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

input="$(cat 2>/dev/null || true)"
# Prefer last assistant message fields if present; otherwise scan full payload text.
text="$input"
if command -v jq >/dev/null 2>&1; then
  extracted="$(printf '%s' "$input" | jq -r '
    .transcript_path // .last_assistant_message // .message // .content // empty
  ' 2>/dev/null || true)"
  if [[ -n "$extracted" && "$extracted" != "null" ]]; then
    if [[ -f "$extracted" ]]; then
      # transcript_path: scan last 80 lines for assertion+evidence
      text="$(tail -n 80 "$extracted" 2>/dev/null || true)"
    else
      text="$extracted"
    fi
  fi
fi

if printf '%s' "$text" | grep -qiE '\b(verified|完了|根因確定|fixed|検証済み)\b'; then
  if ! printf '%s' "$text" | grep -qE 'Evidence:'; then
    echo "[H3 warn] assertion-without-evidence: add Evidence trailer before treating as verified" >&2
    if declare -F aidd_ledger_append >/dev/null 2>&1; then
      aidd_ledger_append "H3" "warn" "warn" "stop-hook" "assertion-without-evidence"
    fi
    # advise only — do not exit non-zero (would fail Stop hook closed)
  fi
fi
exit 0
