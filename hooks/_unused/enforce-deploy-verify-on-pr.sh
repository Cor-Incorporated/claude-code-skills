#!/usr/bin/env bash
# enforce-deploy-verify-on-pr.sh — Block PR creation if changed hooks/scripts not deployed
# PreToolUse hook on Bash matcher
# Exit 0 = allow, Exit 2 = block
# Triggers on: gh pr create
# Checks: MD5 of changed hooks/*.sh and scripts/*.sh vs deployed copies
set -euo pipefail

GIT_CONTEXT_DIR="${GIT_CONTEXT_DIR:-}"
DEFAULT_MANAGED_REPO="cor-incorporated/claude-code-skills"

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

def is_gh(token):
    return os.path.basename(token) == "gh"

global_value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
separators = {"&&", "||", ";", "|", "&"}
redirects = {">", ">>", "<", "<<", "<>", ">&", "<&", "&>"}

def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return min(i + 2, len(tokens))
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        return i + 1
    return None

gh_index = -1
i = 0
while i < len(tokens):
    if not is_gh(tokens[i]):
        i += 1
        continue
    end = i + 1
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    j = i + 1
    while j < end:
        token = tokens[j]
        if token in redirects:
            j += 2
            continue
        skipped = skip_value_flag(tokens, j, global_value_flags)
        if skipped is not None:
            j = skipped
            continue
        if token.startswith("-"):
            j += 1
            continue
        if token == "pr" and j + 1 < end and tokens[j + 1] == "create":
            gh_index = i
        break
    if gh_index >= 0:
        break
    i += 1
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

normalize_repo_slug() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || return 1

  while [[ "$ref" == */ ]]; do
    ref="${ref%/}"
  done
  ref="${ref%.git}"
  case "$ref" in
    git@github.com:*) ref="${ref#git@github.com:}" ;;
    ssh://git@github.com/*) ref="${ref#ssh://git@github.com/}" ;;
    https://github.com/*) ref="${ref#https://github.com/}" ;;
    http://github.com/*) ref="${ref#http://github.com/}" ;;
    github.com/*) ref="${ref#github.com/}" ;;
  esac

  if [[ "$ref" =~ ^[^/]+/[^/]+$ ]]; then
    printf '%s' "$ref" | tr '[:upper:]' '[:lower:]'
  else
    return 1
  fi
}

repo_remote_matches() {
  local project_dir="$1"
  local expected_slug="$2"
  local remote url slug

  for remote in origin upstream; do
    url=$(git -C "$project_dir" remote get-url "$remote" 2>/dev/null || true)
    [[ -n "$url" ]] || continue
    slug=$(normalize_repo_slug "$url" || true)
    [[ "$slug" == "$expected_slug" ]] && return 0
  done

  return 1
}

project_path_matches() {
  local project_dir="$1"
  local repo_ref="$2"
  local ref_top project_real ref_real project_git ref_git

  [[ -d "$repo_ref" ]] || return 1
  ref_top=$(git -C "$repo_ref" rev-parse --show-toplevel 2>/dev/null || true)
  [[ -n "$ref_top" ]] || return 1

  project_real=$(cd "$project_dir" && pwd -P)
  ref_real=$(cd "$ref_top" && pwd -P)
  [[ "$project_real" == "$ref_real" ]] && return 0

  project_git=$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  ref_git=$(git -C "$ref_top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [[ -n "$project_git" && -n "$ref_git" ]] || return 1

  project_git=$(cd "$project_git" && pwd -P)
  ref_git=$(cd "$ref_git" && pwd -P)
  [[ "$project_git" == "$ref_git" ]]
}

is_managed_repo() {
  local project_dir="$1"
  local override="${CLAUDE_CODE_SKILLS_REPO:-}"
  local override_slug

  if [[ -n "$override" ]]; then
    if project_path_matches "$project_dir" "$override"; then
      return 0
    fi
    override_slug=$(normalize_repo_slug "$override" || true)
    if [[ -n "$override_slug" ]] && repo_remote_matches "$project_dir" "$override_slug"; then
      return 0
    fi
  fi

  repo_remote_matches "$project_dir" "$DEFAULT_MANAGED_REPO"
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

if ! _COMMAND="$COMMAND" python3 - <<'PY'
import os
import shlex
import sys

cmd = os.environ.get("_COMMAND", "")
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    sys.exit(1)

global_value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
separators = {"&&", "||", ";", "|", "&"}
redirects = {">", ">>", "<", "<<", "<>", ">&", "<&", "&>"}

def is_gh(token):
    return os.path.basename(token) == "gh"

def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return min(i + 2, len(tokens))
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        return i + 1
    return None

i = 0
while i < len(tokens):
    if not is_gh(tokens[i]):
        i += 1
        continue
    end = i + 1
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    j = i + 1
    while j < end:
        token = tokens[j]
        if token in redirects:
            j += 2
            continue
        skipped = skip_value_flag(tokens, j, global_value_flags)
        if skipped is not None:
            j = skipped
            continue
        if token.startswith("-"):
            j += 1
            continue
        if token == "pr" and j + 1 < end and tokens[j + 1] == "create":
            sys.exit(0)
        break
    i += 1
sys.exit(1)
PY
then
  exit 0
fi

_cmd_context=$(command_git_context_dir "$COMMAND")
if [[ -n "$_cmd_context" ]]; then
  export GIT_CONTEXT_DIR="$_cmd_context"
fi

PROJECT_DIR=$(git_ctx rev-parse --show-toplevel 2>/dev/null || echo "")
[[ -n "$PROJECT_DIR" ]] || exit 0

is_managed_repo "$PROJECT_DIR" || exit 0

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
  # Phase 3 robustness: if the source file is missing in the working tree
  # (deleted or moved to hooks/_unused/ in this PR), skip the deploy check.
  # The committed diff may still reference the old path until the move lands,
  # but reading $source would fail under `set -e` and crash the hook.
  [[ -f "$source" ]] || return 0
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
