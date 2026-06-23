#!/bin/bash
# common.sh — Shared functions for pr-ci-review-gate mode scripts
# =========================================================================
# Sourced by the dispatcher and each mode script.
# All output goes to stderr (Claude Code hooks spec).
# =========================================================================
set -euo pipefail

# Source guard: prevent double-initialization when sourced from standalone hooks
if [[ "${_COMMON_SH_LOADED:-}" == "1" ]]; then
  return 0 2>/dev/null || true
fi
_COMMON_SH_LOADED=1

# Prevent gh CLI TTY hangs
export GH_FORCE_TTY=0
export GH_NO_UPDATE_NOTIFIER=1

# =========================================================================
# Portable timeout: macOS has no timeout command (GNU coreutils)
# =========================================================================
if command -v timeout &>/dev/null; then
  _timeout() { timeout "$@"; }
elif command -v gtimeout &>/dev/null; then
  _timeout() { gtimeout "$@"; }
else
  _timeout() { shift; "$@"; }  # skip timeout arg, run command directly
fi

# =========================================================================
# Helper: map GitHub repo slugs to local remotes
# =========================================================================
remote_slug() {
  local remote="$1" url
  url=$(git_ctx remote get-url "$remote" 2>/dev/null || echo "")
  [[ -z "$url" ]] && return 1
  printf '%s\n' "$url" \
    | sed 's|^git@github.com:||;s|^https://github.com/||;s|^ssh://git@github.com/||;s|\.git$||'
}

remote_for_repo() {
  local repo="$1" remote slug first_remote=""

  for remote in origin upstream; do
    git_ctx remote get-url "$remote" >/dev/null 2>&1 || continue
    [[ -z "$first_remote" ]] && first_remote="$remote"
    slug=$(remote_slug "$remote" || echo "")
    if [[ -n "$repo" && "$slug" == "$repo" ]]; then
      echo "$remote"
      return
    fi
  done

  [[ -n "$first_remote" ]] && echo "$first_remote"
}

# =========================================================================
# Helper: verify the local gate is evaluating the current GitHub base snapshot
# =========================================================================
ensure_pr_base_fresh() {
  local repo="$1" pr_number="$2" base_ref="$3" base_sha="$4"
  local remote local_sha

  if [[ -z "$repo" || -z "$pr_number" || -z "$base_ref" || -z "$base_sha" || "$base_sha" == "null" ]]; then
    echo "🚫 [LOCAL_GATE_BASE_UNKNOWN] PR #${pr_number}: GitHub base ref/SHA を取得できません。" >&2
    echo "  GitHub mergeable 判定とは別に、local gate が現在の base を検証できないためブロックします。" >&2
    echo "  確認: gh pr view ${pr_number} -R ${repo} --json baseRefName,baseRefOid,mergeable" >&2
    return 2
  fi

  remote=$(remote_for_repo "$repo" || echo "")
  if [[ -z "$remote" ]]; then
    echo "🚫 [LOCAL_GATE_BASE_UNKNOWN] PR #${pr_number}: ${repo} に対応する local remote を特定できません。" >&2
    echo "  GitHub mergeable 判定とは別に、local gate の base snapshot が不明です。" >&2
    return 2
  fi

  if [[ -n "${GIT_CONTEXT_DIR:-}" ]]; then
    _fetch_base() { _timeout 20 git -C "$GIT_CONTEXT_DIR" fetch --quiet "$remote" "+refs/heads/${base_ref}:refs/remotes/${remote}/${base_ref}" 2>/dev/null; }
    _rev_parse_base() { git -C "$GIT_CONTEXT_DIR" rev-parse "refs/remotes/${remote}/${base_ref}" 2>/dev/null || echo ""; }
  else
    _fetch_base() { _timeout 20 git fetch --quiet "$remote" "+refs/heads/${base_ref}:refs/remotes/${remote}/${base_ref}" 2>/dev/null; }
    _rev_parse_base() { git rev-parse "refs/remotes/${remote}/${base_ref}" 2>/dev/null || echo ""; }
  fi

  if ! _fetch_base; then
    echo "🚫 [LOCAL_GATE_STALE_BASE] PR #${pr_number}: ${remote}/${base_ref} を取得できません。" >&2
    echo "  GitHub mergeable/CLEAN は GitHub 側の判定です。local gate は base snapshot を更新できないためブロックします。" >&2
    echo "  復旧: git fetch ${remote} ${base_ref}" >&2
    return 2
  fi

  local_sha=$(_rev_parse_base)
  if [[ "$local_sha" != "$base_sha" ]]; then
    echo "🚫 [LOCAL_GATE_STALE_BASE] PR #${pr_number}: local base snapshot が GitHub base と一致しません。" >&2
    echo "  GitHub ${repo}:${base_ref}: ${base_sha}" >&2
    echo "  Local  ${remote}/${base_ref}: ${local_sha:-missing}" >&2
    echo "  GitHub mergeable 判定とは別の local gate blocker です。fetch 後に再試行してください。" >&2
    return 2
  fi

  return 0
}

# =========================================================================
# Helper: pending-review-comments.json stale-state cleanup
# =========================================================================
pending_review_pr_state() {
  local pending_file="$1" fallback_repo="$2"
  local pending_pr pending_repo state

  [[ -f "$pending_file" ]] || return 1
  pending_pr=$(jq -r '.pr // ""' "$pending_file" 2>/dev/null || echo "")
  [[ -n "$pending_pr" && "$pending_pr" != "null" ]] || return 1
  pending_repo=$(jq -r '.repo // ""' "$pending_file" 2>/dev/null || echo "")
  [[ -n "$pending_repo" && "$pending_repo" != "null" ]] || pending_repo="$fallback_repo"
  [[ -n "$pending_repo" ]] || return 1

  state=$(_timeout 10 gh api "repos/${pending_repo}/pulls/${pending_pr}" --jq '.state' 2>/dev/null || echo "")
  printf '%s\n' "$state" | tr '[:upper:]' '[:lower:]'
}

purge_pending_review_state() {
  local pending_file="$1" cache_file
  cache_file="$(dirname "$pending_file")/pending-review-pr-state.cache"
  rm -f "$pending_file" "$cache_file" 2>/dev/null || true
}

# =========================================================================
# Helper: verify pending-review-comments.json still matches GitHub comments
# =========================================================================
review_comment_set_hash_script() {
  local common_dir candidate
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "$HOME/.claude/scripts/review-comment-set-hash.sh" \
    "${common_dir}/../../scripts/review-comment-set-hash.sh"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

pending_comment_set_current() {
  local pending_file="$1"
  local repo="$2"
  local pr_number="$3"
  local head_sha="$4"
  local state_hash script current_hash

  [[ -f "$pending_file" ]] || return 1
  [[ -n "$repo" && -n "$pr_number" && -n "$head_sha" ]] || return 1

  state_hash=$(jq -r '.comment_set_hash // ""' "$pending_file" 2>/dev/null || echo "")
  [[ -n "$state_hash" && "$state_hash" != "null" ]] || return 1

  script="$(review_comment_set_hash_script || true)"
  [[ -n "$script" ]] || return 1

  current_hash=$(_timeout 30 bash "$script" "$pr_number" "$repo" "$head_sha" 2>/dev/null || echo "")
  [[ -n "$current_hash" && "$current_hash" == "$state_hash" ]]
}

# =========================================================================
# State directory — project-scoped
# =========================================================================
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
REVIEW_STATE="$STATE_DIR/review-status.json"
LOCK_STATE="$STATE_DIR/pr-review-lock.json"
mkdir -p "$STATE_DIR"

# =========================================================================
# Dual-location lock files — project-scoped AND global (Issue #19 / Fix8)
# The pessimistic lock (pr-review-lock.json) was written and read from
# INCONSISTENT directories: writers land in the repo-scoped state when run
# inside a repo, but block-merge-without-review.sh (with CLAUDE_PROJECT_DIR
# unset) reads $HOME/.claude/state — so clearing the lock never satisfied the
# merge gate. Mirror the read_review() dual-location pattern: every lock
# read/write must consider BOTH the project-scoped file AND the global one.
# =========================================================================
GLOBAL_STATE_DIR="$HOME/.claude/state"
mkdir -p "$GLOBAL_STATE_DIR" 2>/dev/null || true

# lock_files — echo the deduped list of lock file paths (project, then global)
lock_files() {
  echo "$LOCK_STATE"
  if [[ "$GLOBAL_STATE_DIR/pr-review-lock.json" != "$LOCK_STATE" ]]; then
    echo "$GLOBAL_STATE_DIR/pr-review-lock.json"
  fi
}

# lock_pr_verified <pr> — "yes" if ANY lock file has verified=true for the PR
lock_pr_verified() {
  local pr="$1" lf
  while IFS= read -r lf; do
    [[ -z "$lf" || ! -f "$lf" ]] && continue
    local val
    val=$(_LOCK="$lf" _PR="$pr" python3 -c "
import json, os
try:
    with open(os.environ['_LOCK']) as f:
        s = json.load(f)
    print('yes' if s.get(os.environ['_PR'], {}).get('verified', False) else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
    [[ "$val" == "yes" ]] && { echo "yes"; return; }
  done < <(lock_files)
  echo "no"
}

# lock_pr_locked <pr> — "yes" if a lock entry exists in ANY file AND no file
# has verified=true (i.e. still review_pending somewhere, verified nowhere).
lock_pr_locked() {
  local pr="$1"
  [[ "$(lock_pr_verified "$pr")" == "yes" ]] && { echo "no"; return; }
  local lf
  while IFS= read -r lf; do
    [[ -z "$lf" || ! -f "$lf" ]] && continue
    local has
    has=$(_LOCK="$lf" _PR="$pr" python3 -c "
import json, os
try:
    with open(os.environ['_LOCK']) as f:
        s = json.load(f)
    print('yes' if os.environ['_PR'] in s else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
    [[ "$has" == "yes" ]] && { echo "yes"; return; }
  done < <(lock_files)
  echo "no"
}

# lock_apply <pr> <python-mutator> — run the same python mutation against EVERY
# lock file (dual-write). The mutator (passed via env, dedented + exec'd so its
# indentation is independent of this heredoc) operates on the loaded dict `s`
# with `PR` and `os` in scope; file lock + atomic rewrite handled here.
# SECURITY: <python-mutator> MUST be a static literal. Never interpolate
# shell variables into it (RCE risk via untrusted PR/branch data). Pass
# dynamic values via env (e.g. _BR="$BRANCH" lock_apply ...) and read them
# inside the mutator with os.environ[...].
lock_apply() {
  local pr="$1" mutator="$2" lf rc
  # Fix C: do NOT swallow python failures. A silent failure here means a lock may
  # never be SET (a review-required PR is left unlocked) or never CLEARED (VERIFY
  # reports success but verified=true is never persisted). Capture the python exit
  # status per file; on nonzero, warn to stderr identifying the lock + PR and mark
  # the whole call failed so the caller can react. Callers that tolerate partial
  # failure may ignore the return; happy path (rc 0) is unchanged.
  local failed=0
  while IFS= read -r lf; do
    [[ -z "$lf" ]] && continue
    mkdir -p "$(dirname "$lf")" 2>/dev/null || true
    [[ ! -f "$lf" ]] && echo '{}' > "$lf"
    _LOCK="$lf" _PR="$pr" _MUTATOR="$mutator" python3 -c "
import json, os, fcntl, textwrap
f_path = os.environ['_LOCK']
PR = os.environ['_PR']
mutator = textwrap.dedent(os.environ['_MUTATOR'])
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except Exception:
        s = {}
    _ns = {'s': s, 'PR': PR, 'os': os, 'json': json}
    exec(mutator, _ns)
    s = _ns['s']
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "[lock_apply] WARNING: lock write FAILED (exit $rc) for PR #${pr} on '${lf}'." >&2
      echo "[lock_apply]   Lock state may be inconsistent (not set/cleared). Investigate before merging." >&2
      failed=1
    fi
  done < <(lock_files)
  return "$failed"
}

# Fail-closed: python3 is required for state file operations
if ! command -v python3 &>/dev/null; then
  echo "[pr-ci-review-gate] python3 not found. Blocking for safety." >&2
  exit 2
fi

# Initialize state files if missing
[ ! -f "$REVIEW_STATE" ] && echo '{}' > "$REVIEW_STATE"
[ ! -f "$LOCK_STATE" ] && echo '{}' > "$LOCK_STATE"

# =========================================================================
# Helper: extract command from tool input JSON
# =========================================================================
extract_cmd() {
  if [[ -n "${input:-}" ]] && command -v jq &>/dev/null; then
    echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Extract the explicit PR target from a `gh pr merge` command. Supports valid
# gh forms where flags appear before the positional PR argument, e.g.
# `gh pr merge --repo owner/repo 123 --merge`, and gh global flags before
# the `pr` subcommand, e.g. `gh -R owner/repo pr merge 123 --merge`.
#
# Output:
#   - numeric PR number when an explicit numeric/URL target is present
#   - __NON_NUMERIC__:<target> when an explicit non-numeric target is present
#   - empty when the command relies on the current branch implicit target
extract_gh_pr_merge_target() {
  local cmd="${1:-}"
  [[ -z "$cmd" ]] && return 0
  _CMD="$cmd" python3 - <<'PY'
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

def is_gh(token):
    return os.path.basename(token) == "gh"

def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return min(i + 2, len(tokens))
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        return i + 1
    return None

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
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
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
  local cmd="${1:-}"
  [[ -z "$cmd" ]] && { echo 0; return 0; }
  _CMD="$cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

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
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    print(0)
    sys.exit(0)

print(count_pr_verb(tokens, "merge"))
PY
}

count_gh_pr_create_invocations() {
  local cmd="${1:-}"
  [[ -z "$cmd" ]] && { echo 0; return 0; }
  _CMD="$cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

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
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    print(0)
    sys.exit(0)

print(count_pr_verb(tokens, "create"))
PY
}
# =========================================================================
# Helper: resolve repository (fork-aware)
# Priority: CLAUDE_FORK_REPO env > --repo flag > upstream remote > origin
# =========================================================================
resolve_repo() {
  local cmd="${1:-}"

  # Priority 1: CLAUDE_FORK_REPO env var
  if [[ -n "${CLAUDE_FORK_REPO:-}" ]]; then
    echo "$CLAUDE_FORK_REPO"
    return
  fi

  # Priority 2: --repo / -R flag in command
  if [[ -n "$cmd" ]]; then
    local parsed_repo
    parsed_repo=$(_CMD="$cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

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

def gh_pr_invocations(tokens, verbs):
    invocations = []
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
            if token == "pr" and j + 1 < end and tokens[j + 1] in verbs:
                invocations.append((i, j + 2, end))
            break
        i += 1
    return invocations

def repo_in_range(tokens, start, end):
    i = start
    while i < end:
        token = tokens[i]
        if token in separators:
            break
        if token in redirects:
            i += 2
            continue
        if token in {"--repo", "-R"} and i + 1 < len(tokens):
            return tokens[i + 1]
        if token.startswith("--repo="):
            return token.split("=", 1)[1]
        i += 1
    return ""

cmd = os.environ.get("_CMD", "")
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(>>?|<<?|>&|<&|&>)', r'\1\3', cmd)
try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    sys.exit(0)

merge_invocations = gh_pr_invocations(tokens, {"merge"})
for gh_start, _, end in merge_invocations:
    repo = repo_in_range(tokens, gh_start + 1, end)
    if repo:
        print(repo)
        sys.exit(0)

if merge_invocations:
    sys.exit(0)

create_invocations = gh_pr_invocations(tokens, {"create"})
for gh_start, _, end in create_invocations:
    repo = repo_in_range(tokens, gh_start + 1, end)
    if repo:
        print(repo)
        sys.exit(0)

if create_invocations:
    sys.exit(0)

i = 0
while i < len(tokens):
    token = tokens[i]
    if token in separators:
        i += 1
        continue
    if token in redirects:
        i += 2
        continue
    if token in {"--repo", "-R"} and i + 1 < len(tokens):
        print(tokens[i + 1])
        sys.exit(0)
    if token.startswith("--repo="):
        print(token.split("=", 1)[1])
        sys.exit(0)
    i += 1
PY
)
    if [[ -n "$parsed_repo" ]]; then
      echo "$parsed_repo"
      return
    fi
  fi

  # Priority 3: upstream remote (fork workflow)
  if git_ctx remote get-url upstream &>/dev/null; then
    git_ctx remote get-url upstream 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||'
    return
  fi

  # Priority 4: origin (default)
  git_ctx remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo ""
}


# =========================================================================
# Helper: run git in the command's repository context when known
# =========================================================================
GIT_CONTEXT_DIR="${GIT_CONTEXT_DIR:-}"

git_ctx() {
  if [[ -n "${GIT_CONTEXT_DIR:-}" ]]; then
    git -C "$GIT_CONTEXT_DIR" "$@"
  else
    git "$@"
  fi
}

# Extract --head from a gh pr create command. Supports:
#   gh pr create --head branch
#   gh pr create --head=branch
#   gh pr create --head owner:branch
extract_pr_head_branch() {
  local cmd="${1:-}"
  [[ -z "$cmd" ]] && return 0
  _CMD="$cmd" python3 - <<'PY'
import os, shlex, sys

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
        if token != "pr" or j + 1 >= end or tokens[j + 1] != "create":
            break
        k = j + 2
        while k < end:
            token = tokens[k]
            if token in redirects:
                k += 2
                continue
            if token == "--head" and k + 1 < end:
                value = tokens[k + 1]
                print(value.split(":", 1)[-1])
                sys.exit(0)
            if token.startswith("--head="):
                value = token.split("=", 1)[1]
                print(value.split(":", 1)[-1])
                sys.exit(0)
            k += 1
        break
    i += 1
PY
}

# Resolve a leading `cd <path> && gh pr create/merge ...` context from the raw
# Bash command without executing it. Claude hooks run before Bash, so the
# hook process cannot observe subshell cd effects directly.
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
        if token == "pr" and j + 1 < end and tokens[j + 1] in {"create", "merge"}:
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

# =========================================================================
# Helper: get current branch
# =========================================================================
current_branch() {
  local cmd="${1:-}"
  local b
  b=$(extract_pr_head_branch "$cmd")
  if [[ -n "$b" ]]; then
    echo "$b"
    return
  fi

  b=$(git_ctx branch --show-current 2>/dev/null || echo "")
  # GitHub Actions PR builds checkout a detached HEAD; GITHUB_HEAD_REF
  # carries the actual source branch name in that context.
  if [[ -z "$b" ]]; then
    b="${GITHUB_HEAD_REF:-}"
  fi
  echo "$b"
}

# =========================================================================
# Review Tier Classification (content-based)
# =========================================================================
# Tier 1 (FULL)   : Source code changes -> code-reviewer + Codex CLI
# Tier 2 (LIGHT)  : CI/config/docs-only changes -> code-reviewer only
# Tier 3 (EXEMPT) : Branch-based exemption (docs/*, chore/*, ci/*)
#
# Low-risk file patterns (Tier 2):
#   .github/*, Dockerfile, .dockerignore, .gitignore, *.md, CLAUDE.md,
#   .claude/*, tsconfig.json, .eslintrc*, .prettierrc*, renovate.json
# =========================================================================
classify_review_tier() {
  local branch="$1"
  local pr_number="${2:-}"

  # Tier 3: Branch-based exemption
  case "$branch" in docs/*|chore/*|ci/*) echo "EXEMPT"; return ;; esac

  # Issue #141: Use GitHub API for PR changed files instead of local git diff.
  # Local `git diff base...HEAD` gives wrong results when run from develop branch.
  local changed_files=""

  # Try GitHub API first if PR number and repo are available
  if [[ -n "$pr_number" ]] && [[ -n "${REPO:-}" ]]; then
    changed_files=$(_timeout 10 gh api "repos/${REPO}/pulls/${pr_number}/files" --jq '.[].filename' 2>/dev/null || echo "")
  fi

  # Fallback to local git diff if API failed
  if [[ -z "$changed_files" ]]; then
    local base_branch="main"
    if git_ctx rev-parse --verify develop &>/dev/null; then
      base_branch="develop"
    elif git_ctx rev-parse --verify main &>/dev/null; then
      base_branch="main"
    elif git_ctx rev-parse --verify master &>/dev/null; then
      base_branch="master"
    fi

    local head_ref="HEAD"
    if [[ -n "$branch" ]] && git_ctx rev-parse --verify "$branch" &>/dev/null; then
      head_ref="$branch"
    fi
    changed_files=$(git_ctx diff --name-only "${base_branch}...${head_ref}" 2>/dev/null || git_ctx diff --name-only "$base_branch" "$head_ref" 2>/dev/null || echo "")
  fi

  if [[ -z "$changed_files" ]]; then
    # Detection failure (API timeout / run-from-develop / pre-push) must NOT
    # escalate docs/small PRs to 2-reviewer FULL. Default to LIGHT (code-reviewer
    # only, warn-only at create). Genuine source PRs classify FULL once files are
    # detected at merge time (GitHub API reliable).
    echo "LIGHT"
    return
  fi

  # Check each changed file: if ANY file is NOT in the low-risk pattern, it's Tier 1
  local has_source_changes="false"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
      # Low-risk: All .github config files
      .github/*) ;;
      # Low-risk: Docker config
      Dockerfile|Dockerfile.*|.dockerignore|docker-compose*.yml|docker-compose*.yaml) ;;
      # Low-risk: Documentation
      *.md|docs/*|LICENSE|CHANGELOG*|CONTRIBUTING*) ;;
      # Low-risk: Claude/editor config
      .claude/*|CLAUDE.md|.cursor/*|.vscode/*|.editorconfig) ;;
      # Low-risk: Linter/formatter config
      .eslintrc*|.prettierrc*|.stylelintrc*|biome.json|.biomeignore) ;;
      # Low-risk: Git config
      .gitignore|.gitattributes) ;;
      # Low-risk: Renovate/Dependabot
      renovate.json|.renovaterc*) ;;
      # Low-risk: tsconfig (build config, not source)
      tsconfig*.json) ;;
      # Everything else is source code -> Tier 1
      *)
        has_source_changes="true"
        break
        ;;
    esac
  done <<< "$changed_files"

  if [[ "$has_source_changes" == "true" ]]; then
    echo "FULL"
  else
    echo "LIGHT"
  fi
}

# =========================================================================
# Helper: low-risk (non-source) path test — mirrors classify_review_tier globs.
# Returns 0 if the path is low-risk (docs/config), 1 if it is source code.
# =========================================================================
is_low_risk_path() {
  case "$1" in
    .github/*) return 0 ;;
    Dockerfile|Dockerfile.*|.dockerignore|docker-compose*.yml|docker-compose*.yaml) return 0 ;;
    *.md|docs/*|LICENSE|CHANGELOG*|CONTRIBUTING*) return 0 ;;
    .claude/*|CLAUDE.md|.cursor/*|.vscode/*|.editorconfig) return 0 ;;
    .eslintrc*|.prettierrc*|.stylelintrc*|biome.json|.biomeignore) return 0 ;;
    .gitignore|.gitattributes) return 0 ;;
    renovate.json|.renovaterc*) return 0 ;;
    tsconfig*.json) return 0 ;;
    *) return 1 ;;
  esac
}

# =========================================================================
# Helper: did any SOURCE file change between two git refs?
# Returns 0 (true) if a non-low-risk file changed OR the diff cannot be computed
# / baseline unknown (fail-closed); 1 (false) if only low-risk files changed.
# =========================================================================
source_changed_between() {
  local from_ref="$1" to_ref="${2:-HEAD}"
  [[ -z "$from_ref" ]] && return 0
  local files
  files=$(git_ctx diff --name-only "${from_ref}..${to_ref}" 2>/dev/null) || return 0
  [[ -z "$files" ]] && return 1
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_low_risk_path "$f" || return 0
  done <<< "$files"
  return 1
}

# =========================================================================
# Helper: read review status for a branch (jq-based, no python3 dependency)
# Issue #60 Bug C: Check BOTH project-scoped AND global state (OR logic)
# to prevent path mismatch causing permanent blocks.
# =========================================================================
# Non-CI check run exclusion pattern (#187)
# These check runs are NOT CI jobs and should be excluded from CI status checks.
# Case-insensitive match against check run name.
# =========================================================================
NON_CI_CHECK_PATTERN="^(Agent|copilot|dependabot|CodeRabbit)"

# jq filter to exclude non-CI check runs from CI status counting
# Usage: gh api .../check-runs --jq "$(jq_ci_failures_filter)"
jq_ci_failures_filter() {
  echo "[.check_runs[] | select(.conclusion==\"failure\") | select(.name | test(\"${NON_CI_CHECK_PATTERN}\"; \"i\") | not)] | length"
}

jq_ci_pending_filter() {
  echo "[.check_runs[] | select(.status!=\"completed\") | select(.name | test(\"${NON_CI_CHECK_PATTERN}\"; \"i\") | not)] | length"
}

read_review() {
  local branch="$1"
  local field="$2"
  local global_state="$HOME/.claude/state/review-status.json"

  # Check both state files — return "yes" if EITHER has the field set to true
  local files_to_check=("$REVIEW_STATE")
  if [[ "$global_state" != "$REVIEW_STATE" ]]; then
    files_to_check+=("$global_state")
  fi

  for state_file in "${files_to_check[@]}"; do
    [[ ! -f "$state_file" ]] && continue
    if command -v jq &>/dev/null; then
      local val
      val=$(jq -r --arg b "$branch" --arg f "$field" '.[$b][$f] // false' "$state_file" 2>/dev/null)
      if [[ "$val" == "true" ]]; then
        echo "yes"
        return
      fi
    else
      if grep -q "\"$branch\"" "$state_file" 2>/dev/null && \
         grep -A5 "\"$branch\"" "$state_file" 2>/dev/null | grep -q "\"$field\".*true"; then
        echo "yes"
        return
      fi
    fi
  done
  echo "no"
}

# =========================================================================
# Helper: read Codex severity count from state file (#203)
# Returns numeric count for the specified field, or -1 if not available.
# Fields: codex_critical, codex_high, codex_medium, codex_low
# =========================================================================
read_codex_severity() {
  local branch="$1"
  local field="$2"
  local global_state="$HOME/.claude/state/$(basename "$REVIEW_STATE")"

  local files_to_check=("$REVIEW_STATE")
  if [[ "$global_state" != "$REVIEW_STATE" ]]; then
    files_to_check+=("$global_state")
  fi

  for state_file in "${files_to_check[@]}"; do
    [[ ! -f "$state_file" ]] && continue
    if command -v jq &>/dev/null; then
      local val
      val=$(jq -r --arg b "$branch" --arg f "$field" '.[$b][$f] // -1' "$state_file" 2>/dev/null)
      if [[ "$val" != "-1" ]] && [[ "$val" != "null" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
        return
      fi
    elif command -v python3 &>/dev/null; then
      local val
      val=$(_BR="$branch" _FLD="$field" python3 -c "
import json, os
try:
    with open('$state_file') as f:
        data = json.load(f)
    v = data.get(os.environ['_BR'], {}).get(os.environ['_FLD'], -1)
    print(int(v) if isinstance(v, (int, float)) and v >= 0 else -1)
except Exception:
    print(-1)
" 2>/dev/null)
      if [[ "$val" != "-1" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
        return
      fi
    fi
  done
  echo "-1"
}
