#!/usr/bin/env bash

set -u

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "${repo_root:-}" ]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

cd "$repo_root" || exit 1

npm run ci:v2:docs-stale
docs_stale_status=$?

node scripts/check-v2-docs-placeholder.mjs
docs_placeholder_status=$?

if [ "$docs_stale_status" -eq 0 ] && [ "$docs_placeholder_status" -eq 0 ]; then
  exit 0
fi

if [ "$docs_stale_status" -ne 0 ]; then
  cat >&2 <<EOF
error: docs-stale guardrail exited with status $docs_stale_status.
error: commit blocked; run "npm run ci:v2:docs-stale" to inspect stale docs.
EOF
fi

if [ "$docs_placeholder_status" -ne 0 ]; then
  cat >&2 <<EOF
error: docs-placeholder guardrail exited with status $docs_placeholder_status.
error: commit blocked; run "node scripts/check-v2-docs-placeholder.mjs" to inspect placeholder docs.
EOF
fi

exit 1
