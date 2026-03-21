#!/bin/bash
# enforce-seed-data-verification.sh
# PreToolUse hook: Block writes to knowledge/seed files without verification
#
# Root cause (2026-02-14, AP-4): 6 critical data errors in seed_knowledge.py

set -euo pipefail

# Read tool input from stdin (Claude Code hook protocol)
INPUT="$(cat)"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
CONTENT="$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)"

# Guard: empty path → pass through
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Only trigger for knowledge/seed data files
case "$FILE_PATH" in
  *seed_knowledge*|*knowledge*.yaml|*knowledge*.yml|*knowledge*.json)
    ;;
  *)
    exit 0
    ;;
esac

# If no content available (Edit tool), pass through — matcher already filtered
if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# Check if content contains factual claims without verification source
if echo "$CONTENT" | grep -qE '(電話|phone|営業時間|hours|休[館日]|holiday|料金|price|住所|address)'; then
  if ! echo "$CONTENT" | grep -qiE '(verified|検証済|参照元|source:|ref:|project-reference)'; then
    cat <<'ERRMSG' >&2

KNOWLEDGE DATA VERIFICATION REQUIRED

This file contains factual claims (hours, phone, prices).
Verify against: docs/reference/project-reference.md

Known errors (2026-02-14):
  Phone: 080-6742-7231 (NOT 092-986-8026)
  Holidays: 毎月最終月曜 (NOT 毎週月曜)
  Food: 原則不可 (NOT 持ち込み可)
  Registration: 当日受付で会員登録必須 (NOT 不要)

Add verification source as comment, or this write will be blocked.

ERRMSG
    exit 2
  fi
fi

exit 0
