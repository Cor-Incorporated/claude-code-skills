#!/bin/bash
# enforce-endpoint-dataflow.sh
# PostToolUse hook: When editing API route files, remind to verify full data flow
#
# Root cause (2026-03-08, AP-1/AP-6):
#   /api/marp proxied to /api/slides, but backend doesn't handle render_with_narration.

set -euo pipefail

# Read tool input from stdin (Claude Code hook protocol)
INPUT="$(cat)"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

# Guard: empty path → pass through
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Only trigger for API route files
case "$FILE_PATH" in
  */api/*/route.ts|*/api/*/route.tsx|*/main.py)
    ;;
  *)
    exit 0
    ;;
esac

cat >&2 <<'MSG'

ENDPOINT DATA FLOW CHECK REQUIRED
Before reporting this endpoint as "fixed":
1. CLIENT: What action/params does the component send?
2. ROUTE: What does this API route do with the request?
3. BACKEND: Does the backend accept this action? (check action_map)
4. RESPONSE: Does the format match client expectations?
All 4 must match. Missing any = broken.

MSG

exit 0
