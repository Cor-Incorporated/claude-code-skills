#!/bin/bash
# enforce-hook-deploy-integrity.sh — SessionStart hook: enforce hook deployment integrity
# =========================================================================
# Replaces validate-hook-deployment.sh with enhanced checks:
#   1. MD5 comparison of hooks/*.sh vs ~/.claude/hooks/*.sh
#   2. Auto-sync mismatched files (cp from repo to ~/.claude/hooks/)
#   3. Detect orphan deployed hooks (in ~/.claude/hooks/ but not in hooks/)
#   4. Check settings.json registration
#
# SessionStart hook — cannot block (exit 0 always)
# stdout: JSON additionalContext (when issues found)
# stderr: diagnostic information
#
# Ref: Issue #183 — Hook deployment integrity enforcement
# Ref: Epic #130 — hookデプロイメント検証の構造的欠陥
# =========================================================================
set -uo pipefail

# --- Known exclusions (not directly registered in settings.json) ---
EXCLUDED_FROM_REGISTRATION=(
  "inject-claude-review-helper.py"
  "record-codex-review.sh"
  "validate-hook-deployment.sh"
  "README.md"
)

# --- Known orphans (exist in ~/.claude/hooks/ but not in hooks/) ---
KNOWN_ORPHANS=(
  "pre-merge.sh"
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
  case "$filename" in
    gate-modes/*) return 0 ;;
  esac
  for excluded in "${EXCLUDED_FROM_REGISTRATION[@]}"; do
    if [[ "$filename" == "$excluded" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: check if a filename is a known orphan ---
is_known_orphan() {
  local filename="$1"
  for orphan in "${KNOWN_ORPHANS[@]}"; do
    if [[ "$filename" == "$orphan" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: compute md5 hash (macOS md5 / Linux md5sum) ---
compute_md5() {
  local filepath="$1"
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$filepath" 2>/dev/null
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$filepath" 2>/dev/null | awk '{print $1}'
  else
    echo "NO_MD5_COMMAND"
  fi
}

issues=()
synced=()

# --- Phase 1: Collect project hook files ---
project_files=()
while IFS= read -r -d '' filepath; do
  # Preserve relative path from PROJECT_HOOKS_DIR (e.g. gate-modes/stop.sh)
  rel_path="${filepath#$PROJECT_HOOKS_DIR/}"
  project_files+=("$rel_path")
done < <(find "$PROJECT_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)

# --- Phase 2: MD5 compare + auto-sync ---
mkdir -p "$INSTALLED_HOOKS_DIR"
for rel_path in "${project_files[@]}"; do
  repo_file="$PROJECT_HOOKS_DIR/$rel_path"
  deployed_file="$INSTALLED_HOOKS_DIR/$rel_path"

  if [[ ! -f "$deployed_file" ]]; then
    # Not installed at all — create parent dir and copy it
    mkdir -p "$(dirname "$deployed_file")"
    if cp "$repo_file" "$deployed_file" 2>/dev/null && chmod +x "$deployed_file" 2>/dev/null; then
      issues+=("NOT INSTALLED: $rel_path (auto-synced)")
      synced+=("$rel_path")
    else
      issues+=("NOT INSTALLED: $rel_path (SYNC FAILED)")
    fi
    continue
  fi

  # Both files exist — compare MD5
  repo_md5=$(compute_md5 "$repo_file")
  deployed_md5=$(compute_md5 "$deployed_file")

  if [[ "$repo_md5" != "$deployed_md5" ]]; then
    mkdir -p "$(dirname "$deployed_file")"
    if cp "$repo_file" "$deployed_file" 2>/dev/null && chmod +x "$deployed_file" 2>/dev/null; then
      issues+=("MD5 MISMATCH: $rel_path (repo=${repo_md5} deployed=${deployed_md5}, auto-synced)")
      synced+=("$rel_path")
    else
      issues+=("MD5 MISMATCH: $rel_path (repo=${repo_md5} deployed=${deployed_md5}, SYNC FAILED)")
    fi
  fi
done

# --- Phase 3: Detect orphan deployed hooks ---
if [[ -d "$INSTALLED_HOOKS_DIR" ]]; then
  while IFS= read -r -d '' filepath; do
    rel_path="${filepath#$INSTALLED_HOOKS_DIR/}"
    filename=$(basename "$filepath")

    # Skip non-script files
    case "$filename" in
      README.md|*.pyc) continue ;;
    esac

    # Check if this deployed file exists in project hooks
    if [[ ! -f "$PROJECT_HOOKS_DIR/$rel_path" ]]; then
      if is_known_orphan "$filename"; then
        issues+=("KNOWN ORPHAN: $rel_path (in ~/.claude/hooks/ but not in hooks/)")
      else
        issues+=("UNKNOWN ORPHAN: $rel_path (in ~/.claude/hooks/ but not in hooks/)")
      fi
    fi
  done < <(find "$INSTALLED_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)
fi

# --- Phase 4: Check settings.json registration ---
if [[ -f "$SETTINGS_FILE" ]]; then
  settings_content=$(cat "$SETTINGS_FILE")

  while IFS= read -r -d '' filepath; do
    rel_path="${filepath#$INSTALLED_HOOKS_DIR/}"
    filename=$(basename "$filepath")

    # Skip non-script files
    case "$filename" in
      README.md|*.pyc) continue ;;
    esac

    # Skip known exclusions
    if is_excluded "$rel_path" || is_excluded "$filename"; then
      continue
    fi

    # Check if registered in settings.json
    if ! echo "$settings_content" | grep -q "~/.claude/hooks/$rel_path"; then
      issues+=("NOT REGISTERED: $rel_path (not in settings.json)")
    fi
  done < <(find "$INSTALLED_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)
fi

# --- Phase 5: Output results ---
if [[ ${#issues[@]} -gt 0 ]]; then
  issue_count=${#issues[@]}
  sync_count=${#synced[@]}

  # stderr: diagnostic output
  echo "[Hook Deploy Integrity] ${issue_count} issues found:" >&2
  for issue in "${issues[@]}"; do
    echo "  - ${issue}" >&2
  done
  if [[ $sync_count -gt 0 ]]; then
    echo "[Hook Deploy Integrity] Auto-synced ${sync_count} file(s)." >&2
  fi

  # Build warning message for additionalContext
  warning_lines=""
  for issue in "${issues[@]}"; do
    warning_lines="${warning_lines}\\n- ${issue}"
  done
  message="[Hook Deploy Integrity] ${issue_count} issues found:${warning_lines}"
  if [[ $sync_count -gt 0 ]]; then
    message="${message}\\n[Auto-synced ${sync_count} file(s) from repo to ~/.claude/hooks/]"
  fi

  # stdout: JSON additionalContext
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
