#!/usr/bin/env bash
# enforce-deploy-verify-on-pr.sh — Block PR creation if changed hooks/scripts not deployed
# PreToolUse hook on Bash matcher
# Exit 0 = allow, Exit 2 = block
# Triggers on: gh pr create
# Checks: MD5 of changed hooks/*.sh and scripts/*.sh vs deployed copies
set -euo pipefail

GIT_CONTEXT_DIR="${GIT_CONTEXT_DIR:-}"

git_ctx() {
  if [[ -n "${GIT_CONTEXT_DIR:-}" ]]; then
    git -C "$GIT_CONTEXT_DIR" "$@"
  else
    git "$@"
  fi
}

command_git_context_dir() {
  local cmd="${1:-}"
  [[ -z "$cmd" ]] && return 0
  _CMD="$cmd" python3 - <<'PY'
import os, shlex, subprocess, sys

cmd = os.environ.get("_CMD", "")
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    sys.exit(0)

gh_index = -1
for i in range(len(tokens) - 2):
    if tokens[i:i+3] == ["gh", "pr", "create"]:
        gh_index = i
        break
if gh_index < 0:
    sys.exit(0)

candidate = ""
for i in range(gh_index):
    if tokens[i] == "cd" and i + 1 < gh_index:
        candidate = tokens[i + 1]

if not candidate or candidate == "-":
    sys.exit(0)

path = os.path.abspath(os.path.expanduser(candidate))
try:
    top = subprocess.check_output(
        ["git", "-C", path, "rev-parse", "--show-toplevel"],
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()
except Exception:
    sys.exit(0)

if top:
    print(top)
PY
}

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

COMMAND=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$COMMAND" ]] \
   && [[ "$COMMAND" != *$'\n'* ]] \
   && ! printf '%s' "$COMMAND" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b' || exit 0

_cmd_context=$(command_git_context_dir "$COMMAND")
if [[ -n "$_cmd_context" ]]; then
  export GIT_CONTEXT_DIR="$_cmd_context"
fi

PROJECT_DIR=$(git_ctx rev-parse --show-toplevel 2>/dev/null || echo "")
[[ -n "$PROJECT_DIR" ]] || exit 0

BASE_BRANCH="${DEPLOY_VERIFY_BASE_BRANCH:-$(git_ctx symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "develop")}"
CHANGED_FILES=$(git_ctx diff --name-only "$BASE_BRANCH"...HEAD 2>/dev/null || git_ctx diff --name-only "$BASE_BRANCH" HEAD 2>/dev/null || echo "")
[[ -n "$CHANGED_FILES" ]] || exit 0

HOOK_CHANGES=$(echo "$CHANGED_FILES" | grep -E '^hooks/.*\.sh$' | grep -vE '^hooks/_unused/' || true)
SCRIPT_CHANGES=$(echo "$CHANGED_FILES" | grep -E '^scripts/[^/]+\.sh$' || true)
[[ -n "$HOOK_CHANGES" || -n "$SCRIPT_CHANGES" ]] || exit 0

ERRORS=""

# Common function to check deployment status
check_deploy() {
  local file="$1" deploy_dir="$2"
  [[ -z "$file" ]] && return
  local source="$PROJECT_DIR/$file"
  local rel_path deployed
  case "$file" in
    hooks/*) rel_path="${file#hooks/}" ;;
    scripts/*) rel_path="${file#scripts/}" ;;
    *) rel_path="$(basename "$file")" ;;
  esac
  deployed="$deploy_dir/$rel_path"
  if [[ ! -f "$deployed" ]]; then
    ERRORS="${ERRORS}\n  ❌ $file → $deployed (未デプロイ)"
  else
    local src_md5 dep_md5
    src_md5=$(md5 -q "$source" 2>/dev/null || md5sum "$source" 2>/dev/null | awk '{print $1}')
    dep_md5=$(md5 -q "$deployed" 2>/dev/null || md5sum "$deployed" 2>/dev/null | awk '{print $1}')
    if [[ "$src_md5" != "$dep_md5" ]]; then
      ERRORS="${ERRORS}\n  ❌ $file — MD5不一致 (src:${src_md5:0:8} != dep:${dep_md5:0:8})"
    fi
  fi
}

while IFS= read -r file; do
  check_deploy "$file" "$HOME/.claude/hooks"
done <<< "$HOOK_CHANGES"

while IFS= read -r file; do
  check_deploy "$file" "$HOME/.claude/scripts"
done <<< "$SCRIPT_CHANGES"

[[ -n "$ERRORS" ]] || exit 0

echo "" >&2
echo "🚫 [BLOCKED] PR作成を拒否。変更されたhook/scriptが未デプロイです。" >&2
echo "" >&2
echo "  デプロイ検証結果:" >&2
echo -e "$ERRORS" >&2
echo "" >&2
echo "  解決方法:" >&2
echo "  1. bash setup.sh  # 全hook/scriptをデプロイ" >&2
echo "  2. MD5一致を確認してから再試行" >&2
echo "" >&2
echo "  Epic #130: 「コードがある」≠「動作する」" >&2
exit 2
