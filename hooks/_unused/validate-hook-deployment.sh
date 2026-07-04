#!/bin/bash
# validate-hook-deployment.sh — SessionStart hook: verify hook deployment integrity
# =========================================================================
# Checks that all hook scripts in the project are:
#   1. Installed to ~/.claude/hooks/
#   2. Registered in ~/.claude/settings.json
#
# SessionStart hook — cannot block (exit 0 always)
# stdout: JSON additionalContext (when issues found)
# stderr: diagnostic information
#
# Ref: Epic #130 — hookデプロイメント検証の構造的欠陥
# =========================================================================
set -uo pipefail

# --- Known exclusions (not directly registered in settings.json) ---
EXCLUDED_FROM_REGISTRATION=(
  "context-budget-set-mode.sh"
  "inject-claude-review-helper.py"
  "record-codex-review.sh"
  "README.md"
)

# --- Locate project hooks directory ---
PROJECT_HOOKS_DIR=""
for candidate in \
  "${CLAUDE_PROJECT_DIR:-}/hooks" \
  "$HOME/Developer/claude-code-skills/hooks" \
; do
  if [[ -d "$candidate" ]]; then
    PROJECT_HOOKS_DIR="$candidate"
    break
  fi
done

# If no project hooks dir found, skip silently
[[ -z "$PROJECT_HOOKS_DIR" ]] && exit 0

INSTALLED_HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

# --- Helper: check if a filename is in the exclusion list ---
is_excluded() {
  local filename="$1"
  for excluded in "${EXCLUDED_FROM_REGISTRATION[@]}"; do
    if [[ "$filename" == "$excluded" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Phase 1: Collect project hook files ---
# -maxdepth 1 inherently excludes _unused/ and __pycache__/ subdirectories
project_files=()
while IFS= read -r -d '' filepath; do
  filename=$(basename "$filepath")
  project_files+=("$filename")
done < <(find "$PROJECT_HOOKS_DIR" -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)

# --- Phase 2: Check each project file is installed ---
issues=()
for filename in "${project_files[@]}"; do
  if [[ ! -f "$INSTALLED_HOOKS_DIR/$filename" ]]; then
    issues+=("NOT INSTALLED: $filename")
  fi
done

# --- Phase 3: Check each installed file is registered in settings.json ---
if [[ -f "$SETTINGS_FILE" ]]; then
  # Read settings.json content once
  settings_content=$(cat "$SETTINGS_FILE")

  # -maxdepth 1 inherently excludes _unused/ and __pycache__/ subdirectories
  while IFS= read -r -d '' filepath; do
    filename=$(basename "$filepath")
    # Skip non-script files
    case "$filename" in
      README.md|*.pyc) continue ;;
    esac
    # Skip known exclusions
    if is_excluded "$filename"; then
      continue
    fi
    # Check if registered in settings.json
    # Supports both bash and python3 invocation patterns
    if ! echo "$settings_content" | grep -q "~/.claude/hooks/$filename"; then
      issues+=("NOT REGISTERED: $filename")
    fi
  done < <(find "$INSTALLED_HOOKS_DIR" -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)
fi

# --- Phase 4: Output results ---
if [[ ${#issues[@]} -gt 0 ]]; then
  # Build the warning message
  issue_count=${#issues[@]}
  warning_lines=""
  for issue in "${issues[@]}"; do
    warning_lines="${warning_lines}\\n- ${issue}"
  done
  message="[Hook Deployment Check] ${issue_count} issues found:${warning_lines}"

  # stderr: diagnostic output
  echo "[Hook Deployment Check] ${issue_count} issues found:" >&2
  for issue in "${issues[@]}"; do
    echo "  - ${issue}" >&2
  done

  # stdout: JSON additionalContext
  # Use python3 for safe JSON encoding
  python3 -c "
import json, sys
msg = sys.argv[1]
output = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': msg
    }
}
print(json.dumps(output))
" "$message"
fi

exit 0
