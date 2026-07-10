#!/bin/bash
# enforce-doc-update-scope.sh
# PostToolUse hook: When editing docs, remind to update ALL related docs

set -euo pipefail

# Read tool input from stdin (Claude Code hook protocol)
INPUT="$(cat)"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Only trigger for doc files
case "$FILE_PATH" in
  */docs/*.md|*/Plans.md|*/CLAUDE.md|*MEMORY.md)
    ;;
  *)
    exit 0
    ;;
esac

cat >&2 <<'MSG'

DOC UPDATE SCOPE: Also check/update:
  docs/STATUS.md, docs/DEVELOPER-GUIDE.md, Plans.md, MEMORY.md, CLAUDE.md files
  grep for changed keywords to find other references.

MSG

exit 0
