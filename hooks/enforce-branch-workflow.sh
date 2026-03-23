#!/bin/bash
# enforce-branch-workflow.sh — SessionStart hook
# =========================================================================
# Enforces the develop branch workflow:
#   main ← develop ← feat/* / fix/* / refactor/* / chore/*
#
# On SessionStart:
#   1. Auto-create develop from main if only main exists
#   2. Warn if currently on main/develop (should be on feature branch)
#   3. Inject branch workflow guidance via additionalContext
#
# Ref: git-workflow.md — "保護ブランチ: develop, main, master"
# =========================================================================

set -euo pipefail

# Only run in git repos
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
CONTEXT_LINES=()

# --- 1. Auto-create develop if it doesn't exist ---
_has_develop="no"
git rev-parse --verify origin/develop >/dev/null 2>&1 && _has_develop="yes"
if [[ "$_has_develop" == "no" ]]; then
  git rev-parse --verify develop >/dev/null 2>&1 && _has_develop="yes"
fi

_has_main="no"
git rev-parse --verify origin/main >/dev/null 2>&1 && _has_main="yes"
if [[ "$_has_main" == "no" ]]; then
  git rev-parse --verify main >/dev/null 2>&1 && _has_main="yes"
fi

if [[ "$_has_develop" == "no" ]] && [[ "$_has_main" == "yes" ]]; then
  # Auto-create develop from main
  git branch develop main 2>/dev/null || true
  CONTEXT_LINES+=("[branch-workflow] develop ブランチをローカルに作成しました。")
  CONTEXT_LINES+=("  リモートへのpush: git push -u origin develop")
  CONTEXT_LINES+=("  今後は feat/* → develop → main のフローで開発してください。")
  echo "[branch-workflow] develop ブランチをローカルに作成しました (push未実行)。" >&2
fi

# --- 2. Warn if on protected branch ---
case "$CURRENT_BRANCH" in
  main|master)
    CONTEXT_LINES+=("[branch-workflow] 現在 $CURRENT_BRANCH ブランチです。直接編集は禁止です。")
    CONTEXT_LINES+=("  作業開始前に: git checkout -b feat/<description> develop")
    echo "[branch-workflow] WARNING: $CURRENT_BRANCH ブランチ上です。feature ブランチに切り替えてください。" >&2
    ;;
  develop)
    CONTEXT_LINES+=("[branch-workflow] 現在 develop ブランチです。")
    CONTEXT_LINES+=("  実装作業は feature ブランチで行ってください: git checkout -b feat/<description>")
    CONTEXT_LINES+=("  develop → main のリリースPRは develop 上から作成可能です。")
    ;;
esac

# --- 3. Output additionalContext ---
if [[ ${#CONTEXT_LINES[@]} -gt 0 ]]; then
  JOINED=$(printf '%s\n' "${CONTEXT_LINES[@]}")
  if command -v jq &>/dev/null; then
    jq -n --arg ctx "$JOINED" '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
      }
    }'
  else
    echo "[branch-workflow] jq not found. Context output skipped." >&2
  fi
fi

exit 0
