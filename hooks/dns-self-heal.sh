#!/usr/bin/env bash
# dns-self-heal.sh — SessionStart: detect & repair DNS negative-cache poisoning
#
# Non-blocking (always exit 0). When api.anthropic.com fails to connect
# (ENOTFOUND / "Could not resolve host") — caused by mDNSResponder negative
# cache entries cached during Wi-Fi handoffs (work <-> home) — flush the
# system DNS cache and reload Tailscale DNS so the session can start.
#
# /etc/hosts pin makes the probe effectively always pass; this hook is the
# safety net for other hostnames and for hosts-file regressions.
#
# Only acts when the probe fails; healthy state costs ~2s with no side effects.

set -euo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# Never block session start
trap 'exit 0' EXIT

PROBE_URL="https://api.anthropic.com/v1/models"

probe() {
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    --connect-timeout 2 --max-time 4 "$PROBE_URL" 2>/dev/null) || code="000"
  printf '%s' "$code"
}

# 401/403 = reachable (auth required is fine); 000 = DNS/connect failure
code=$(probe)
case "$code" in
  000)
    echo "⚠️  [dns-self-heal] api.anthropic.com unreachable (negative DNS cache?) — repairing..." >&2
    dscacheutil -flushcache 2>/dev/null || true
    if command -v tailscale >/dev/null 2>&1; then
      tailscale set --accept-dns=false 2>/dev/null || true
      tailscale set --accept-dns=true 2>/dev/null || true
    fi
    code=$(probe)
    case "$code" in
      000)
        echo "ℹ️  [dns-self-heal] repair ran but probe still fails (network down?) — will retry next session" >&2
        if declare -F aidd_ledger_append >/dev/null 2>&1; then
          aidd_ledger_append "dns-self-heal" "warn" "warn" "probe=000" "dns-repair-incomplete"
        fi
        ;;
      *)
        echo "✅ [dns-self-heal] DNS repaired (probe now returns HTTP $code)" >&2
        if declare -F aidd_ledger_append >/dev/null 2>&1; then
          aidd_ledger_append "dns-self-heal" "measure" "allow" "probe=${code}" "dns-repair-ok"
        fi
        ;;
    esac
    ;;
esac

exit 0
