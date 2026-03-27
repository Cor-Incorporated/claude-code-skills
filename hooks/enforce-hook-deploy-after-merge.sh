#!/bin/bash
# enforce-hook-deploy-after-merge.sh — PostToolUse:Bash hook
# Auto-deploys hooks after a PR merge that changed hooks/ files.
#
# Flow: gh pr merge → detect hooks/ changes → cp to ~/.claude/hooks/ → md5 verify
#
# Issue #183: PRマージ後にhooksを自動デプロイし、
# 「コードはあるがデプロイされていない」状態を防止する。
#
# Exit: always 0 (PostToolUse hooks must not block)
set -uo pipefail

# --- Dependency check: jq required ---
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# --- Early exit: only trigger on gh pr merge ---
cmd_first_line=$(echo "$cmd" | head -1)
if ! echo "$cmd_first_line" | grep -q 'gh.*pr.*merge'; then
  exit 0
fi

# --- Extract PR number ---
PR_NUM=$(echo "$cmd_first_line" | grep -oE 'pr\s+merge(\s+--[a-z-]+)*\s+[0-9]+' | grep -oE '[0-9]+$' || echo "")
if [ -z "$PR_NUM" ]; then
  exit 0
fi

# --- Verify PR was actually merged ---
PR_STATE=$(gh pr view "$PR_NUM" --json state -q '.state' 2>/dev/null || echo "")
if [ "$PR_STATE" != "MERGED" ]; then
  exit 0
fi

# --- Find project directory ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
fi
if [ -z "$PROJECT_DIR" ]; then
  echo "WARNING [hook-deploy] プロジェクトディレクトリが見つかりません。" >&2
  exit 0
fi

HOOKS_SRC="${PROJECT_DIR}/hooks"
HOOKS_DEST="${HOME}/.claude/hooks"

# --- Check if merged PR contained hooks/ changes ---
CHANGED_FILES=$(gh pr diff "$PR_NUM" --name-only 2>/dev/null || echo "")
HOOK_FILES=$(echo "$CHANGED_FILES" | grep '^hooks/.*\.sh$' || true)

if [ -z "$HOOK_FILES" ]; then
  # No hooks/ changes in this PR
  exit 0
fi

# --- Deploy hooks ---
mkdir -p "$HOOKS_DEST"

# Pull latest to ensure local hooks/ matches merged state
if ! git pull --ff-only 2>/dev/null; then
  echo "[hook-deploy] WARNING: git pull --ff-only failed. Deployed hooks may be stale." >&2
fi

DEPLOYED=0
FAILED=0
RESULTS=""

while IFS= read -r hook_path; do
  [ -z "$hook_path" ] && continue
  hook_rel="${hook_path#hooks/}"
  src="${HOOKS_SRC}/${hook_rel}"
  dst="${HOOKS_DEST}/${hook_rel}"
  mkdir -p "$(dirname "$dst")"

  if [ ! -f "$src" ]; then
    # File was deleted in PR, skip
    continue
  fi

  cp "$src" "$dst" 2>/dev/null
  chmod +x "$dst" 2>/dev/null

  # --- MD5 verification ---
  if command -v md5sum >/dev/null 2>&1; then
    src_md5=$(md5sum "$src" | awk '{print $1}')
    dst_md5=$(md5sum "$dst" | awk '{print $1}')
  elif command -v md5 >/dev/null 2>&1; then
    src_md5=$(md5 -q "$src")
    dst_md5=$(md5 -q "$dst")
  else
    src_md5="unknown"
    dst_md5="unknown"
  fi

  if [ "$src_md5" = "$dst_md5" ]; then
    DEPLOYED=$((DEPLOYED + 1))
    RESULTS="${RESULTS}  OK  ${hook_rel} (md5: ${src_md5})\n"
  else
    FAILED=$((FAILED + 1))
    RESULTS="${RESULTS}  FAIL ${hook_rel} (src: ${src_md5} != dst: ${dst_md5})\n"
  fi
done <<< "$HOOK_FILES"

# --- Report results to stderr ---
if [ "$DEPLOYED" -gt 0 ] || [ "$FAILED" -gt 0 ]; then
  echo "" >&2
  echo "=== [Hook Auto-Deploy] PR #${PR_NUM} ===" >&2
  printf "%b" "$RESULTS" >&2
  if [ "$FAILED" -eq 0 ]; then
    echo "Result: ${DEPLOYED} hooks deployed, all MD5 verified" >&2
  else
    echo "WARNING: ${FAILED} hooks failed MD5 verification!" >&2
    echo "  Run: bash ${PROJECT_DIR}/setup.sh to re-deploy all hooks" >&2
  fi
  echo "========================================" >&2
fi

exit 0
