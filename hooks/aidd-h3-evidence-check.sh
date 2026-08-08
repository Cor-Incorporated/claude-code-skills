#!/usr/bin/env bash
# H3: assertion-without-evidence checker (advise/warn only — never blocks)
# Usage: aidd-h3-evidence-check.sh <report-file-or-stdin>
set -euo pipefail
_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

text="${1:-}"
if [[ -z "$text" || "$text" == "-" ]]; then
  text="$(cat)"
elif [[ -f "$text" ]]; then
  text="$(cat "$text")"
fi

if printf '%s' "$text" | grep -qiE '\b(verified|完了|根因確定|fixed|検証済み)\b'; then
  if ! printf '%s' "$text" | grep -qE 'Evidence:'; then
    echo "[H3 warn] assertion-without-evidence: Evidence trailer missing" >&2
    if declare -F aidd_ledger_append >/dev/null 2>&1; then
      aidd_ledger_append "H3" "warn" "warn" "assertion" "assertion-without-evidence"
    fi
    exit 1
  fi
fi
echo "[H3 pass] evidence ok or no assertion phrases"
exit 0
