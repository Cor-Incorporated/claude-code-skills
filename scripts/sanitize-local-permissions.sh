#!/bin/bash
# sanitize-local-permissions.sh — Remove permissions from settings.local.json
set -euo pipefail

clean() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to sanitize $file" >&2
    return 1
  fi

  if [[ "$(jq 'has("permissions")' "$file" 2>/dev/null || echo false)" != "true" ]]; then
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  jq 'del(.permissions)' "$file" >"$tmp"
  mv "$tmp" "$file"
  echo "Sanitized local permissions override: $file"
}

for file in "$@"; do
  clean "$file"
done
