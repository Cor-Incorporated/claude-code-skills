#!/bin/bash
# enforce-review-reading.sh — PreToolUse hook
# If pending-review-comments.json exists with unread CRITICAL/HIGH,
# block gh pr merge AND inject a reminder on any Bash command.
#
# This ensures the agent cannot claim "ready to merge" without having
# addressed review findings.
set -uo pipefail

[[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && exit 0
[[ -n "${CLAUDE_AGENT_ID:-}" ]] && exit 0

input=""
[[ ! -t 0 ]] && input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/gate-modes/common.sh"

# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

MERGE_COUNT=$(count_gh_pr_merge_invocations "$cmd" || echo 0)
if [[ "$MERGE_COUNT" -gt 1 ]]; then
  echo "[BLOCKED] 1つのBashコマンドに複数の gh pr merge が含まれています。PRごとに個別実行してください。" >&2
  exit 2
fi

_cmd_context=$(command_git_context_dir "$cmd")
if [[ -n "$_cmd_context" ]]; then
  export GIT_CONTEXT_DIR="$_cmd_context"
  use_git_context_state_dir
fi

PENDING_FILE="$STATE_DIR/pending-review-comments.json"
[[ ! -f "$PENDING_FILE" ]] && exit 0

extract_gh_pr_merge_target() {
  local merge_cmd="${1:-}"
  [[ -z "$merge_cmd" ]] && return 0
  _CMD="$merge_cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

value_flags = {
    "--repo",
    "-R",
    "--body",
    "-b",
    "--body-file",
    "-F",
    "--subject",
    "-t",
    "--match-head-commit",
    "--author-email",
    "-A",
}
global_value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
separators = {"&&", "||", ";", "|", "&"}
redirects = {">", ">>", "<", "<<", "<>", ">&", "<&", "&>"}
shell_executors = {"bash", "sh", "zsh"}

def is_gh(token):
    return os.path.basename(token) == "gh"

def is_assignment(token):
    return re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) is not None

def env_nested_commands(tokens, i, end):
    nested = []
    j = i + 1
    while j < end:
        token = tokens[j]
        if token in redirects:
            j += 2
            continue
        if token in {"-S", "--split-string"}:
            if j + 1 < end:
                nested.append(tokens[j + 1])
            j += 2
            continue
        if token.startswith("--split-string="):
            nested.append(token.split("=", 1)[1])
            j += 1
            continue
        if token in {"-u", "--unset", "-C", "--chdir"}:
            j += 2
            continue
        if token.startswith("--unset=") or token.startswith("--chdir="):
            j += 1
            continue
        if token.startswith("-") and token != "-":
            j += 1
            continue
        if is_assignment(token):
            j += 1
            continue
        break
    return nested

def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return min(i + 2, len(tokens))
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        return i + 1
    return None

def parse_tokens(text):
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except Exception:
        return []

def command_end(tokens, start):
    end = start
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    return end

def nested_command_strings(tokens):
    nested = []
    i = 0
    while i < len(tokens):
        base = os.path.basename(tokens[i])
        end = command_end(tokens, i + 1)
        if base == "env":
            nested.extend(env_nested_commands(tokens, i, end))
        if base in shell_executors:
            j = i + 1
            while j < end:
                token = tokens[j]
                if token in redirects:
                    j += 2
                    continue
                if token == "-c" or (token.startswith("-") and not token.startswith("--") and "c" in token[1:]):
                    if j + 1 < end:
                        nested.append(tokens[j + 1])
                    break
                j += 1
        elif base == "eval" and i + 1 < end:
            nested.append(" ".join(tokens[i + 1:end]))
        i += 1
    return nested

def expand_nested_shell(tokens, depth=0):
    if depth >= 3:
        return tokens
    expanded = list(tokens)
    for nested in nested_command_strings(tokens):
        nested_tokens = parse_tokens(nested)
        if nested_tokens:
            expanded.append(";")
            expanded.extend(expand_nested_shell(nested_tokens, depth + 1))
    return expanded

def gh_pr_invocations(tokens, verb):
    positions = []
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
            if token == "pr" and j + 1 < end and tokens[j + 1] == verb:
                positions.append((i, j + 2, end))
            break
        i += 1
    return positions

cmd = os.environ.get("_CMD", "")
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(>>?|<<?|>&|<&|&>)', r'\1\3', cmd)
tokens = expand_nested_shell(parse_tokens(cmd))
if not tokens:
    sys.exit(0)

merge_positions = gh_pr_invocations(tokens, "merge")

if len(merge_positions) > 1:
    print("__MULTIPLE__")
    sys.exit(0)

for _, start, end in merge_positions:
    j = start
    while j < end:
        token = tokens[j]
        if token in separators:
            break
        if token in redirects:
            j += 2
            continue
        if token in value_flags:
            j += 2
            continue
        if any(token.startswith(f"{flag}=") for flag in value_flags if flag.startswith("--")):
            j += 1
            continue
        if token.startswith("-"):
            j += 1
            continue

        match = re.search(r"^#?([0-9]+)$", token)
        if match:
            print(match.group(1))
        else:
            print(f"__NON_NUMERIC__:{token}")
        sys.exit(0)

print("")
PY
}

count_gh_pr_merge_invocations() {
  local merge_cmd="${1:-}"
  [[ -z "$merge_cmd" ]] && { echo 0; return 0; }
  _CMD="$merge_cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

global_value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
separators = {"&&", "||", ";", "|", "&"}
redirects = {">", ">>", "<", "<<", "<>", ">&", "<&", "&>"}
shell_executors = {"bash", "sh", "zsh"}

def is_gh(token):
    return os.path.basename(token) == "gh"

def is_assignment(token):
    return re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) is not None

def env_nested_commands(tokens, i, end):
    nested = []
    j = i + 1
    while j < end:
        token = tokens[j]
        if token in redirects:
            j += 2
            continue
        if token in {"-S", "--split-string"}:
            if j + 1 < end:
                nested.append(tokens[j + 1])
            j += 2
            continue
        if token.startswith("--split-string="):
            nested.append(token.split("=", 1)[1])
            j += 1
            continue
        if token in {"-u", "--unset", "-C", "--chdir"}:
            j += 2
            continue
        if token.startswith("--unset=") or token.startswith("--chdir="):
            j += 1
            continue
        if token.startswith("-") and token != "-":
            j += 1
            continue
        if is_assignment(token):
            j += 1
            continue
        break
    return nested

def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return min(i + 2, len(tokens))
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        return i + 1
    return None

def parse_tokens(text):
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except Exception:
        return []

def command_end(tokens, start):
    end = start
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    return end

def nested_command_strings(tokens):
    nested = []
    i = 0
    while i < len(tokens):
        base = os.path.basename(tokens[i])
        end = command_end(tokens, i + 1)
        if base == "env":
            nested.extend(env_nested_commands(tokens, i, end))
        if base in shell_executors:
            j = i + 1
            while j < end:
                token = tokens[j]
                if token in redirects:
                    j += 2
                    continue
                if token == "-c" or (token.startswith("-") and not token.startswith("--") and "c" in token[1:]):
                    if j + 1 < end:
                        nested.append(tokens[j + 1])
                    break
                j += 1
        elif base == "eval" and i + 1 < end:
            nested.append(" ".join(tokens[i + 1:end]))
        i += 1
    return nested

def expand_nested_shell(tokens, depth=0):
    if depth >= 3:
        return tokens
    expanded = list(tokens)
    for nested in nested_command_strings(tokens):
        nested_tokens = parse_tokens(nested)
        if nested_tokens:
            expanded.append(";")
            expanded.extend(expand_nested_shell(nested_tokens, depth + 1))
    return expanded

def count_pr_verb(tokens, verb):
    count = 0
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
            if token == "pr" and j + 1 < end and tokens[j + 1] == verb:
                count += 1
            break
        i += 1
    return count

cmd = os.environ.get("_CMD", "")
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(>>?|<<?|>&|<&|&>)', r'\1\3', cmd)
tokens = expand_nested_shell(parse_tokens(cmd))
if not tokens:
    print(0)
    sys.exit(0)

print(count_pr_verb(tokens, "merge"))
PY
}

resolve_current_branch_merge_pr() {
  local repo="${1:-}"
  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "")
  [[ -z "$branch" ]] && return 0

  if [[ -n "$repo" && "$repo" != "null" ]]; then
    gh pr list --repo "$repo" --head "$branch" --json number -q '.[0].number' 2>/dev/null || echo ""
  else
    gh pr list --head "$branch" --json number -q '.[0].number' 2>/dev/null || echo ""
  fi
}

# Read pending state
REVIEW_DATA=$(_PENDING_FILE="$PENDING_FILE" python3 -c "
import json, os
with open(os.environ['_PENDING_FILE']) as f:
    d = json.load(f)
print(json.dumps(d))
" 2>/dev/null || echo "{}")

TOTAL=$(echo "$REVIEW_DATA" | jq -r '.total // 0' 2>/dev/null || echo "0")
CLASSIFICATION_METHOD=$(echo "$REVIEW_DATA" | jq -r '.classification_method // "regex"' 2>/dev/null || echo "regex")
if [[ "$CLASSIFICATION_METHOD" == "ai" ]]; then
  CRITICAL=$(echo "$REVIEW_DATA" | jq -r '.ai_classification.critical // 0' 2>/dev/null || echo "0")
  HIGH=$(echo "$REVIEW_DATA" | jq -r '.ai_classification.high // 0' 2>/dev/null || echo "0")
else
  CRITICAL=$(echo "$REVIEW_DATA" | jq -r '.critical // 0' 2>/dev/null || echo "0")
  HIGH=$(echo "$REVIEW_DATA" | jq -r '.high // 0' 2>/dev/null || echo "0")
fi
PR=$(echo "$REVIEW_DATA" | jq -r '.pr // ""' 2>/dev/null || echo "")

[[ "$TOTAL" -eq 0 ]] && exit 0

# =========================================================================
# Self-heal: suppress + purge residue for already merged/closed PRs.
# pending-review-comments.json is never auto-cleared when a PR is merged
# (GitHub keeps the comments; nothing deletes the file), so without this the
# hook keeps emitting a banner for an irrelevant PR on EVERY Bash command.
# Confirm the PR is still OPEN before warning; if merged/closed, delete the
# stale state and exit silently. The result is cached (TTL) so `gh` is not
# called on every command while a PR is legitimately open.
# Fail-OPEN on unknown state: a real pending review must never be hidden by a
# transient gh/network failure.
# =========================================================================
REPO=$(echo "$REVIEW_DATA" | jq -r '.repo // ""' 2>/dev/null || echo "")
HEAD_SHA=$(echo "$REVIEW_DATA" | jq -r '.head_sha // ""' 2>/dev/null || echo "")
if [[ -n "$PR" ]] && [[ -n "$REPO" ]]; then
  CACHE_FILE="$STATE_DIR/pending-review-pr-state.cache"

  # Cache hit: reuse a fresh (< TTL) state for the same pr+head_sha.
  PR_STATE=$(_CACHE="$CACHE_FILE" _PR="$PR" _SHA="$HEAD_SHA" python3 -c '
import json, os, time
TTL = 300
try:
    with open(os.environ["_CACHE"]) as f:
        c = json.load(f)
    if (c.get("pr") == os.environ["_PR"]
            and c.get("head_sha") == os.environ["_SHA"]
            and (time.time() - float(c.get("checked_at", 0))) < TTL):
        print(str(c.get("state", "")).lower())
except Exception:
    pass
' 2>/dev/null || echo "")

  # Cache miss/stale: query GitHub once, then refresh the cache.
  if [[ -z "$PR_STATE" ]]; then
    if command -v timeout &>/dev/null; then
      PR_STATE=$(timeout 5 gh api "repos/${REPO}/pulls/${PR}" --jq '.state' 2>/dev/null || echo "")
    elif command -v gtimeout &>/dev/null; then
      PR_STATE=$(gtimeout 5 gh api "repos/${REPO}/pulls/${PR}" --jq '.state' 2>/dev/null || echo "")
    else
      PR_STATE=$(gh api "repos/${REPO}/pulls/${PR}" --jq '.state' 2>/dev/null || echo "")
    fi
    PR_STATE=$(printf '%s' "$PR_STATE" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$PR_STATE" ]]; then
      _CACHE="$CACHE_FILE" _PR="$PR" _SHA="$HEAD_SHA" _STATE="$PR_STATE" python3 -c '
import json, os, time
try:
    with open(os.environ["_CACHE"], "w") as f:
        json.dump({"pr": os.environ["_PR"], "head_sha": os.environ["_SHA"],
                   "state": os.environ["_STATE"], "checked_at": time.time()}, f)
except Exception:
    pass
' 2>/dev/null || true
    fi
  fi

  # gh REST `.state` is "open" or "closed" ("closed" covers merged too).
  if [[ "$PR_STATE" == "closed" ]] || [[ "$PR_STATE" == "merged" ]]; then
    rm -f "$PENDING_FILE" "$CACHE_FILE" 2>/dev/null || true
    exit 0
  fi
fi

# HARD BLOCK: gh pr merge with unresolved findings
if should_block_unparsed_pr_merge "$cmd" "$MERGE_COUNT"; then
  if [[ "$CRITICAL" -gt 0 ]] || [[ "$HIGH" -gt 0 ]]; then
    print_unparsed_pr_merge_block
    echo "[BLOCKED] PR #${PR}: 未対応のCRITICAL/HIGH指摘があります（CRITICAL=${CRITICAL}, HIGH=${HIGH}）。" >&2
    exit 2
  fi
fi
if [[ "$MERGE_COUNT" -gt 0 ]]; then
  MERGE_PR=$(extract_gh_pr_merge_target "$cmd" || echo "")
  if [[ "$CRITICAL" -gt 0 ]] || [[ "$HIGH" -gt 0 ]]; then
    if [[ "$MERGE_COUNT" -gt 1 || "$MERGE_PR" == "__MULTIPLE__" ]]; then
      echo "[BLOCKED] 1つのBashコマンドに複数の gh pr merge が含まれています。未対応レビュー state があるため、PRごとに個別実行してください。" >&2
      exit 2
    fi
    if [[ -z "$MERGE_PR" ]]; then
      MERGE_PR=$(resolve_current_branch_merge_pr "$REPO" || echo "")
    fi
    if [[ "$MERGE_PR" == __NON_NUMERIC__:* ]]; then
      echo "[BLOCKED] gh pr merge target をPR番号として特定できません。未対応レビュー state があるため、PR番号を明示してください。" >&2
      echo "  target: ${MERGE_PR#__NON_NUMERIC__:}" >&2
      exit 2
    fi
    if [[ -z "$MERGE_PR" ]]; then
      echo "[BLOCKED] gh pr merge の暗黙ターゲットを現在ブランチから解決できません。未対応レビュー state があるため、PR番号を明示してください。" >&2
      exit 2
    fi
    if [[ -n "$PR" && "$MERGE_PR" != "$PR" ]]; then
      echo "[INFO] pending-review-comments.json は PR #${PR} の state です。PR #${MERGE_PR} の merge はこの hook では hard block しません。" >&2
    else
      echo "[BLOCKED] PR #${PR}: 未対応のCRITICAL/HIGH指摘があります（CRITICAL=${CRITICAL}, HIGH=${HIGH}）。" >&2
      echo "  レビューコメントを確認し、全て対応してからマージしてください。" >&2
      echo "  確認: gh api repos/.../pulls/${PR}/comments" >&2
      exit 2
    fi
  fi
fi

# SOFT REMINDER: any other command — output pending review info
# This outputs hookSpecificOutput so agent sees the pending reviews
OUTPUT=$(echo "$REVIEW_DATA" | jq -r '.output // ""' 2>/dev/null || echo "")
if [[ -n "$OUTPUT" ]] && [[ "$OUTPUT" != "null" ]]; then
  _OUTPUT="$OUTPUT" _PR="$PR" python3 -c "
import json, os
output = os.environ['_OUTPUT']
# Truncate for context efficiency
if len(output) > 2000:
    output = output[:2000] + '\n... (truncated, see full: gh api repos/.../pulls/' + os.environ['_PR'] + '/comments)'
result = {
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'additionalContext': output
    }
}
print(json.dumps(result))
" 2>/dev/null
fi

exit 0
