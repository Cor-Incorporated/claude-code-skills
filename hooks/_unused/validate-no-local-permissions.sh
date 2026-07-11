#!/bin/bash
# validate-no-local-permissions.sh — Prevent permissions in settings.local.json
# =========================================================================
# settings.local.json に permissions セクションがあると、グローバル settings.json
# の permissions を上書きしてしまう。repo-owned allowlist が消え、gh/git/Bash が
# ask/block されるため、SessionStart 時に検出してブロックする。
# =========================================================================

set -euo pipefail

candidate_files=()
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

candidate_files+=("$HOME/.claude/settings.local.json")
candidate_files+=("$project_dir/.claude/settings.local.json")

seen=""

for local_settings in "${candidate_files[@]}"; do
  [[ -f "$local_settings" ]] || continue

  case ":$seen:" in
    *":$local_settings:"*) continue ;;
  esac
  seen="${seen}:$local_settings"

  if ! command -v jq &>/dev/null; then
    continue
  fi

  has_permissions=$(jq 'has("permissions")' "$local_settings" 2>/dev/null || echo "false")
  if [[ "$has_permissions" != "true" ]]; then
    continue
  fi

  allow_count=$(jq '(.permissions.allow // []) | length' "$local_settings" 2>/dev/null || echo "0")
  deny_count=$(jq '(.permissions.deny // []) | length' "$local_settings" 2>/dev/null || echo "0")

  echo "" >&2
  echo "⚠️  [CRITICAL] settings.local.json に permissions セクションが検出されました！" >&2
  echo "   File: $local_settings" >&2
  echo "   allow=${allow_count}, deny=${deny_count}" >&2
  echo "   これはグローバル settings.json の permissions を上書きし、" >&2
  echo "   repo-owned allowlist (例: Bash(gh:*), Bash(git:*)) を無効化します。" >&2
  echo "" >&2
  echo "   修正方法:" >&2
  echo "   1. $local_settings から permissions セクションを削除" >&2
  echo "   2. 必要な権限は settings.json に追加" >&2
  echo "" >&2
  exit 2
done

exit 0
