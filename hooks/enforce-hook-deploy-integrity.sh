#!/bin/bash
# enforce-hook-deploy-integrity.sh — SessionStart hook: enforce hook deployment integrity
# =========================================================================
# Successor to validate-hook-deployment.sh (archived to hooks/_unused/ per ADR-006):
#   1. MD5 comparison of hooks/*.sh vs ~/.claude/hooks/*.sh (report only)
#   2. Detect orphan deployed hooks (in ~/.claude/hooks/ but not in hooks/)
#   3. Check settings.json registration
#   NO auto-sync (loop-break T2): never cp from checkout branch into deploy dir
#
# SessionStart hook — cannot block (exit 0 always)
# stdout: JSON additionalContext (when issues found)
# stderr: diagnostic information
#
# Ref: Issue #183 — Hook deployment integrity enforcement
# Ref: Epic #130 — hookデプロイメント検証の構造的欠陥
# =========================================================================
set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# --- Known exclusions (not directly registered in settings.json) ---
# aidd-h3-evidence-check.sh: CLI helper (stdin/file report); Stop path is aidd-h3-evidence-stop.sh
# lib/*: support libraries sourced by hooks, not SessionStart/PreToolUse entries
EXCLUDED_FROM_REGISTRATION=(
  "README.md"
  "aidd-h3-evidence-check.sh"
  "lib/aidd-ledger.sh"
  "aidd-ledger.sh"
)

# --- Known orphans (exist in ~/.claude/hooks/ but not in hooks/) ---
# Empty as of ADR-006 (minimal safety net) — retired hooks/gate-modes are
# pruned by setup.sh, not suppressed here.
KNOWN_ORPHANS=()

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

# --- Phase 0: H1 no-progress visibility (T7-2) ---
# NOT a block: the stall signal lives outside agent turns, so no same-turn
# consequence is possible (proposition-enforcement-narrowing.md 区分D).
# Visibility only — heartbeat row every SessionStart; if the previous H1 row
# is >= 45 min old, append a no-progress-timeout warn row first.
# Spec: aidd-governance design/harness-spec.md H1
_H1_LEDGER="${HOME}/.claude/hooks/ledger/guard-ledger.jsonl"
mkdir -p "$(dirname "$_H1_LEDGER")" 2>/dev/null || true
_H1_LAST_TS=""
if [[ -f "$_H1_LEDGER" ]]; then
  _H1_LAST_TS="$(python3 - "$_H1_LEDGER" <<'PY'
import json, sys
last = ""
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("component") == "H1":
        last = row.get("ts", "")
print(last)
PY
)"
  if [[ -n "$_H1_LAST_TS" ]]; then
    _H1_AGE="$(python3 - "$_H1_LAST_TS" <<'PY'
import sys
from datetime import datetime, timezone
try:
    last = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
except Exception:
    print("-1")
    sys.exit(0)
print(int((datetime.now(timezone.utc) - last).total_seconds()))
PY
)"
    if [[ "${_H1_AGE:-0}" -ge 2700 ]]; then
      _h1_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
      printf '{"ts":"%s","component":"H1","event":"warn","rule":"no-progress-timeout","detail":"%ss since last H1 heartbeat (45min threshold)","subject":{},"agent":"claude-code"}\n' \
        "$_h1_ts" "${_H1_AGE}" >>"$_H1_LEDGER" 2>/dev/null || true
    fi
  fi
fi
_h1_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
printf '{"ts":"%s","component":"H1","event":"measure","rule":"heartbeat","detail":"session start HB","subject":{},"agent":"claude-code"}\n' \
  "$_h1_ts" >>"$_H1_LEDGER" 2>/dev/null || true

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

# --- Helper: check if a filename is a known orphan ---
is_known_orphan() {
  local filename="$1"
  for orphan in "${KNOWN_ORPHANS[@]:-}"; do
    [[ -z "$orphan" ]] && continue
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

# --- Phase 1: Collect project hook files ---
project_files=()
while IFS= read -r -d '' filepath; do
  # Preserve relative path from PROJECT_HOOKS_DIR (e.g. gate-modes/stop.sh)
  rel_path="${filepath#$PROJECT_HOOKS_DIR/}"
  project_files+=("$rel_path")
done < <(find "$PROJECT_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)

# --- Phase 2: MD5 compare + report only (NO auto-sync cp) ---
# loop-break T2: auto-sync copied from whichever branch was checked out at
# SessionStart and re-deployed retired hooks (main 52 → disk 63). Detect only.
for rel_path in "${project_files[@]}"; do
  repo_file="$PROJECT_HOOKS_DIR/$rel_path"
  deployed_file="$INSTALLED_HOOKS_DIR/$rel_path"

  if [[ ! -f "$deployed_file" ]]; then
    issues+=("NOT INSTALLED: $rel_path (detect-only; run setup.sh from develop)")
    continue
  fi

  # Both files exist — compare MD5 (do not copy)
  repo_md5=$(compute_md5 "$repo_file")
  deployed_md5=$(compute_md5 "$deployed_file")

  if [[ "$repo_md5" != "$deployed_md5" ]]; then
    issues+=("MD5 MISMATCH: $rel_path (repo=${repo_md5} deployed=${deployed_md5}; no auto-sync)")
  fi
done

# --- Phase 3: Detect orphan deployed hooks ---
if [[ -d "$INSTALLED_HOOKS_DIR" ]]; then
  while IFS= read -r -d '' filepath; do
    rel_path="${filepath#$INSTALLED_HOOKS_DIR/}"
    filename=$(basename "$filepath")

    # Skip non-script files and support libs (not standalone hooks)
    case "$filename" in
      README.md|*.pyc) continue ;;
    esac
    case "$rel_path" in
      lib/*) continue ;;
    esac

    # Check if this deployed file exists in project hooks
    if [[ ! -f "$PROJECT_HOOKS_DIR/$rel_path" ]]; then
      if is_known_orphan "$filename"; then
        issues+=("KNOWN ORPHAN: $rel_path (in ~/.claude/hooks/ but not in hooks/)")
      else
        issues+=("UNKNOWN ORPHAN: $rel_path (in ~/.claude/hooks/ but not in hooks/)")
      fi
    fi
  done < <(find "$INSTALLED_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' -not -path '*/lib/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)
fi

# --- Phase 4: Check settings.json registration ---
if [[ -f "$SETTINGS_FILE" ]]; then
  settings_content=$(cat "$SETTINGS_FILE")

  while IFS= read -r -d '' filepath; do
    rel_path="${filepath#$INSTALLED_HOOKS_DIR/}"
    filename=$(basename "$filepath")

    # Skip non-script files and support libs
    case "$filename" in
      README.md|*.pyc) continue ;;
    esac
    case "$rel_path" in
      lib/*) continue ;;
    esac

    # Skip known exclusions
    if is_excluded "$rel_path" || is_excluded "$filename"; then
      continue
    fi

    # Check if registered in settings.json
    if ! echo "$settings_content" | grep -q "~/.claude/hooks/$rel_path"; then
      issues+=("NOT REGISTERED: $rel_path (not in settings.json)")
    fi
  done < <(find "$INSTALLED_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' -not -path '*/lib/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)
fi

# --- Phase 5: Output results (warn only; never mutate deploy dir) ---
if [[ ${#issues[@]} -gt 0 ]]; then
  issue_count=${#issues[@]}

  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "enforce-hook-deploy-integrity" "warn" "warn" "issues=${issue_count}" "hook-deploy-integrity"
  fi

  # stderr: diagnostic output
  echo "[Hook Deploy Integrity] ${issue_count} issues found:" >&2
  for issue in "${issues[@]}"; do
    echo "  - ${issue}" >&2
  done
  echo "[Hook Deploy Integrity] detect-only (no auto-sync). Fix: checkout develop && bash setup.sh" >&2

  # Build warning message for additionalContext
  warning_lines=""
  for issue in "${issues[@]}"; do
    warning_lines="${warning_lines}\\n- ${issue}"
  done
  message="[Hook Deploy Integrity] ${issue_count} issues found:${warning_lines}\\n(detect-only; no auto-sync)"

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
