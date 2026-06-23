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

# Project-scoped state
if git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi

PENDING_FILE="$STATE_DIR/pending-review-comments.json"
[[ ! -f "$PENDING_FILE" ]] && exit 0

input=""
[[ ! -t 0 ]] && input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

extract_gh_pr_merge_target() {
  local merge_cmd="${1:-}"
  [[ -z "$merge_cmd" ]] && return 0
  _CMD="$merge_cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

cmd = os.environ.get("_CMD", "")
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(>>?|<<?|>&|<&|&>)', r'\1\3', cmd)
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    sys.exit(0)

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
separators = {"&&", "||", ";", "|", "&"}
redirects = {">", ">>", "<", "<<", "<>", ">&", "<&", "&>"}
merge_positions = [
    i for i in range(len(tokens) - 2)
    if tokens[i:i + 3] == ["gh", "pr", "merge"]
]

if len(merge_positions) > 1:
    print("__MULTIPLE__")
    sys.exit(0)

for i in merge_positions:
    j = i + 3
    while j < len(tokens):
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

        match = re.search(r"(?:^|/pull/|#)([0-9]+)$", token)
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

cmd = os.environ.get("_CMD", "")
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(>>?|<<?|>&|<&|&>)', r'\1\3', cmd)
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    print(0)
    sys.exit(0)

count = 0
for i in range(len(tokens) - 2):
    if tokens[i:i + 3] == ["gh", "pr", "merge"]:
        count += 1
print(count)
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
MERGE_COUNT=$(count_gh_pr_merge_invocations "$cmd" || echo 0)
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
