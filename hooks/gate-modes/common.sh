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

rebind_gate_state_dir() {
  local repo_root="$1"
  [[ -n "$repo_root" ]] || return 0
  STATE_DIR="${repo_root}/.claude/state"
  REVIEW_STATE="$STATE_DIR/review-status.json"
  LOCK_STATE="$STATE_DIR/pr-review-lock.json"
  mkdir -p "$STATE_DIR"
}

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

use_git_context_state_dir() {
  if [[ -n "${GIT_CONTEXT_DIR:-}" ]]; then
    rebind_gate_state_dir "$GIT_CONTEXT_DIR"
  fi
}

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

lock_pr_verified_for_head() {
  local pr="$1"
  local head_sha="$2"
  local lf
  [[ -n "$head_sha" && "$head_sha" != "null" ]] || { echo "no"; return; }
  while IFS= read -r lf; do
    [[ -z "$lf" || ! -f "$lf" ]] && continue
    local val
    val=$(_LOCK="$lf" _PR="$pr" _HEAD_SHA="$head_sha" python3 -c "
import json, os
try:
    with open(os.environ['_LOCK']) as f:
        s = json.load(f)
    entry = s.get(os.environ['_PR'], {})
    stored = entry.get('verified_head_sha') or entry.get('head_sha') or ''
    print('yes' if entry.get('verified', False) and stored == os.environ['_HEAD_SHA'] else 'no')
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

lock_pr_locked_for_head() {
  local pr="$1"
  local head_sha="$2"
  [[ "$(lock_pr_verified_for_head "$pr" "$head_sha")" == "yes" ]] && { echo "no"; return; }
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
#   - numeric PR number when an explicit numeric target is present
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
redirects = {">", ">>", ">|", "<", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>"}
shell_executors = {"bash", "sh", "zsh"}
read_only_commands = {"grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "comm", "diff", "cut", "tr", "uniq", "jq", "ls", "which", "type", "echo", "printf"}

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

def skip_process_substitution_value(tokens, i):
    end = process_substitution_end(tokens, i) if "process_substitution_end" in globals() else None
    if (
        end is not None
        and "is_safe_readonly_process_substitution" in globals()
        and is_safe_readonly_process_substitution(tokens, i, end)
    ):
        return end
    return min(i + 1, len(tokens))


def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return skip_process_substitution_value(tokens, i + 1)
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        if token.endswith("="):
            return skip_process_substitution_value(tokens, i + 1)
        return i + 1
    return None

def split_punctuation_tokens(tokens):
    out = []
    for token in tokens:
        if token in {"<(", ">("}:
            out.extend([token[0], "("])
            continue
        if token.count(chr(96)) == 1 and token != chr(96):
            parts = token.split(chr(96))
            for idx, part in enumerate(parts):
                if idx > 0:
                    out.append(chr(96))
                if part:
                    out.append(part)
            continue
        if token and all(ch in ";()" for ch in token):
            out.extend(token)
            continue
        out.append(token)
    return out


def process_substitution_end(tokens, i):
    if i + 1 >= len(tokens) or tokens[i] not in {"<", ">"} or tokens[i + 1] != "(":
        return None
    depth = 1
    j = i + 2
    while j < len(tokens):
        if tokens[j] == "(":
            depth += 1
        elif tokens[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None


def has_runtime_expansion(tokens):
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "$" and i + 1 < len(tokens) and tokens[i + 1] == "(":
            return True
        if "$" + "(" in token or chr(96) in token:
            return True
        if process_substitution_end(tokens, i) is not None:
            return True
        i += 1
    return False


def is_safe_readonly_process_substitution(tokens, start, end):
    inner = tokens[start + 2:end - 1]
    if not inner:
        return True
    return is_single_readonly_command(inner) and not has_runtime_expansion(inner)


def strip_readonly_process_substitutions(tokens):
    out = []
    i = 0
    while i < len(tokens):
        end = process_substitution_end(tokens, i)
        if end is not None and is_safe_readonly_process_substitution(tokens, i, end):
            out.extend([tokens[i], "(", ")"])
            i = end
            continue
        out.append(tokens[i])
        i += 1
    return out


def strip_value_flag_process_substitutions(tokens):
    out = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token in value_flags and i + 1 < len(tokens):
            out.append(token)
            end = process_substitution_end(tokens, i + 1)
            if end is not None and is_safe_readonly_process_substitution(tokens, i + 1, end):
                out.extend([tokens[i + 1], "(", ")"])
                i = end
                continue
            i += 1
            continue
        if any(token.startswith(f"{flag}=") for flag in value_flags if flag.startswith("--")):
            out.append(token)
            if token.endswith("=") and i + 1 < len(tokens):
                end = process_substitution_end(tokens, i + 1)
                if end is not None and is_safe_readonly_process_substitution(tokens, i + 1, end):
                    out.extend([tokens[i + 1], "(", ")"])
                    i = end
                    continue
            i += 1
            continue
        out.append(token)
        i += 1
    return out


def parse_tokens(text):
    text = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', text)
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = strip_readonly_process_substitutions(split_punctuation_tokens(list(lexer)))
        return strip_value_flag_process_substitutions(tokens)
    except Exception:
        return []

def command_end(tokens, start):
    end = start
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    return end

def runtime_command_strings(token):
    nested = []
    marker = chr(36) + "("
    i = 0
    while True:
        start = token.find(marker, i)
        if start == -1:
            break
        depth = 1
        j = start + len(marker)
        while j < len(token):
            if token[j] == "(":
                depth += 1
            elif token[j] == ")":
                depth -= 1
                if depth == 0:
                    inner = token[start + len(marker):j].strip()
                    if inner:
                        nested.append(inner)
                    i = j + 1
                    break
            j += 1
        else:
            i = start + len(marker)
    tick = chr(96)
    i = 0
    while True:
        start = token.find(tick, i)
        if start == -1:
            break
        end = token.find(tick, start + 1)
        if end == -1:
            break
        inner = token[start + 1:end].strip()
        if inner:
            nested.append(inner)
        i = end + 1
    return nested

def nested_command_strings(tokens):
    nested = []
    i = 0
    while i < len(tokens):
        nested.extend(runtime_command_strings(tokens[i]))
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

def is_single_readonly_command(tokens):
    if not tokens or any(token in separators for token in tokens):
        return False
    i = 0
    while i < len(tokens):
        if tokens[i] in redirects:
            i += 2
            continue
        if is_assignment(tokens[i]):
            i += 1
            continue
        break
    return i < len(tokens) and os.path.basename(tokens[i]) in read_only_commands


def expand_nested_shell(tokens, depth=0):
    if depth >= 3:
        return tokens
    expanded = list(tokens)
    for nested in nested_command_strings(tokens):
        nested_tokens = parse_tokens(nested)
        if nested_tokens:
            if is_single_readonly_command(nested_tokens):
                continue
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
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', cmd)
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
            j = skip_process_substitution_value(tokens, j + 1)
            continue
        if any(token.startswith(f"{flag}=") for flag in value_flags if flag.startswith("--")):
            if token.endswith("="):
                j = skip_process_substitution_value(tokens, j + 1)
            else:
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
  local cmd="${1:-}"
  [[ -z "$cmd" ]] && { echo 0; return 0; }
  _CMD="$cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

global_value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
separators = {"&&", "||", ";", "|", "&"}
redirects = {">", ">>", ">|", "<", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>"}
shell_executors = {"bash", "sh", "zsh"}
read_only_commands = {"grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "comm", "diff", "cut", "tr", "uniq", "jq", "ls", "which", "type", "echo", "printf"}

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

def skip_process_substitution_value(tokens, i):
    end = process_substitution_end(tokens, i) if "process_substitution_end" in globals() else None
    if (
        end is not None
        and "is_safe_readonly_process_substitution" in globals()
        and is_safe_readonly_process_substitution(tokens, i, end)
    ):
        return end
    return min(i + 1, len(tokens))


def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return skip_process_substitution_value(tokens, i + 1)
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        if token.endswith("="):
            return skip_process_substitution_value(tokens, i + 1)
        return i + 1
    return None

def split_punctuation_tokens(tokens):
    out = []
    for token in tokens:
        if token in {"<(", ">("}:
            out.extend([token[0], "("])
            continue
        if token.count(chr(96)) == 1 and token != chr(96):
            parts = token.split(chr(96))
            for idx, part in enumerate(parts):
                if idx > 0:
                    out.append(chr(96))
                if part:
                    out.append(part)
            continue
        if token and all(ch in ";()" for ch in token):
            out.extend(token)
            continue
        out.append(token)
    return out


def process_substitution_end(tokens, i):
    if i + 1 >= len(tokens) or tokens[i] not in {"<", ">"} or tokens[i + 1] != "(":
        return None
    depth = 1
    j = i + 2
    while j < len(tokens):
        if tokens[j] == "(":
            depth += 1
        elif tokens[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None


def has_runtime_expansion(tokens):
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "$" and i + 1 < len(tokens) and tokens[i + 1] == "(":
            return True
        if "$" + "(" in token or chr(96) in token:
            return True
        if process_substitution_end(tokens, i) is not None:
            return True
        i += 1
    return False


def is_safe_readonly_process_substitution(tokens, start, end):
    inner = tokens[start + 2:end - 1]
    if not inner:
        return True
    return is_single_readonly_command(inner) and not has_runtime_expansion(inner)


def strip_readonly_process_substitutions(tokens):
    out = []
    i = 0
    while i < len(tokens):
        end = process_substitution_end(tokens, i)
        if end is not None and is_safe_readonly_process_substitution(tokens, i, end):
            out.extend([tokens[i], "(", ")"])
            i = end
            continue
        out.append(tokens[i])
        i += 1
    return out


def parse_tokens(text):
    text = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', text)
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return strip_readonly_process_substitutions(split_punctuation_tokens(list(lexer)))
    except Exception:
        return []

def command_end(tokens, start):
    end = start
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    return end

def runtime_command_strings(token):
    nested = []
    marker = chr(36) + "("
    i = 0
    while True:
        start = token.find(marker, i)
        if start == -1:
            break
        depth = 1
        j = start + len(marker)
        while j < len(token):
            if token[j] == "(":
                depth += 1
            elif token[j] == ")":
                depth -= 1
                if depth == 0:
                    inner = token[start + len(marker):j].strip()
                    if inner:
                        nested.append(inner)
                    i = j + 1
                    break
            j += 1
        else:
            i = start + len(marker)
    tick = chr(96)
    i = 0
    while True:
        start = token.find(tick, i)
        if start == -1:
            break
        end = token.find(tick, start + 1)
        if end == -1:
            break
        inner = token[start + 1:end].strip()
        if inner:
            nested.append(inner)
        i = end + 1
    return nested

def nested_command_strings(tokens):
    nested = []
    i = 0
    while i < len(tokens):
        nested.extend(runtime_command_strings(tokens[i]))
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

def is_single_readonly_command(tokens):
    if not tokens or any(token in separators for token in tokens):
        return False
    i = 0
    while i < len(tokens):
        if tokens[i] in redirects:
            i += 2
            continue
        if is_assignment(tokens[i]):
            i += 1
            continue
        break
    return i < len(tokens) and os.path.basename(tokens[i]) in read_only_commands


def expand_nested_shell(tokens, depth=0):
    if depth >= 3:
        return tokens
    expanded = list(tokens)
    for nested in nested_command_strings(tokens):
        nested_tokens = parse_tokens(nested)
        if nested_tokens:
            if is_single_readonly_command(nested_tokens):
                continue
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
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', cmd)
tokens = expand_nested_shell(parse_tokens(cmd))
if not tokens:
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
redirects = {">", ">>", ">|", "<", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>"}
shell_executors = {"bash", "sh", "zsh"}
read_only_commands = {"grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "comm", "diff", "cut", "tr", "uniq", "jq", "ls", "which", "type", "echo", "printf"}

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

def skip_process_substitution_value(tokens, i):
    end = process_substitution_end(tokens, i) if "process_substitution_end" in globals() else None
    if (
        end is not None
        and "is_safe_readonly_process_substitution" in globals()
        and is_safe_readonly_process_substitution(tokens, i, end)
    ):
        return end
    return min(i + 1, len(tokens))


def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return skip_process_substitution_value(tokens, i + 1)
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        if token.endswith("="):
            return skip_process_substitution_value(tokens, i + 1)
        return i + 1
    return None

def split_punctuation_tokens(tokens):
    out = []
    for token in tokens:
        if token in {"<(", ">("}:
            out.extend([token[0], "("])
            continue
        if token.count(chr(96)) == 1 and token != chr(96):
            parts = token.split(chr(96))
            for idx, part in enumerate(parts):
                if idx > 0:
                    out.append(chr(96))
                if part:
                    out.append(part)
            continue
        if token and all(ch in ";()" for ch in token):
            out.extend(token)
            continue
        out.append(token)
    return out


def process_substitution_end(tokens, i):
    if i + 1 >= len(tokens) or tokens[i] not in {"<", ">"} or tokens[i + 1] != "(":
        return None
    depth = 1
    j = i + 2
    while j < len(tokens):
        if tokens[j] == "(":
            depth += 1
        elif tokens[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None


def has_runtime_expansion(tokens):
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "$" and i + 1 < len(tokens) and tokens[i + 1] == "(":
            return True
        if "$" + "(" in token or chr(96) in token:
            return True
        if process_substitution_end(tokens, i) is not None:
            return True
        i += 1
    return False


def is_safe_readonly_process_substitution(tokens, start, end):
    inner = tokens[start + 2:end - 1]
    if not inner:
        return True
    return is_single_readonly_command(inner) and not has_runtime_expansion(inner)


def strip_readonly_process_substitutions(tokens):
    out = []
    i = 0
    while i < len(tokens):
        end = process_substitution_end(tokens, i)
        if end is not None and is_safe_readonly_process_substitution(tokens, i, end):
            out.extend([tokens[i], "(", ")"])
            i = end
            continue
        out.append(tokens[i])
        i += 1
    return out


def parse_tokens(text):
    text = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', text)
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return strip_readonly_process_substitutions(split_punctuation_tokens(list(lexer)))
    except Exception:
        return []

def command_end(tokens, start):
    end = start
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    return end

def runtime_command_strings(token):
    nested = []
    marker = chr(36) + "("
    i = 0
    while True:
        start = token.find(marker, i)
        if start == -1:
            break
        depth = 1
        j = start + len(marker)
        while j < len(token):
            if token[j] == "(":
                depth += 1
            elif token[j] == ")":
                depth -= 1
                if depth == 0:
                    inner = token[start + len(marker):j].strip()
                    if inner:
                        nested.append(inner)
                    i = j + 1
                    break
            j += 1
        else:
            i = start + len(marker)
    tick = chr(96)
    i = 0
    while True:
        start = token.find(tick, i)
        if start == -1:
            break
        end = token.find(tick, start + 1)
        if end == -1:
            break
        inner = token[start + 1:end].strip()
        if inner:
            nested.append(inner)
        i = end + 1
    return nested

def nested_command_strings(tokens):
    nested = []
    i = 0
    while i < len(tokens):
        nested.extend(runtime_command_strings(tokens[i]))
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

def is_single_readonly_command(tokens):
    if not tokens or any(token in separators for token in tokens):
        return False
    i = 0
    while i < len(tokens):
        if tokens[i] in redirects:
            i += 2
            continue
        if is_assignment(tokens[i]):
            i += 1
            continue
        break
    return i < len(tokens) and os.path.basename(tokens[i]) in read_only_commands


def expand_nested_shell(tokens, depth=0):
    if depth >= 3:
        return tokens
    expanded = list(tokens)
    for nested in nested_command_strings(tokens):
        nested_tokens = parse_tokens(nested)
        if nested_tokens:
            if is_single_readonly_command(nested_tokens):
                continue
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
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', cmd)
tokens = expand_nested_shell(parse_tokens(cmd))
if not tokens:
    print(0)
    sys.exit(0)

print(count_pr_verb(tokens, "create"))
PY
}

command_pr_merge_text_count() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { echo 0; return 0; }
  _CMD="$cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
separators = {";", "&&", "||", "|", "&", "(", ")"}
redirects = {">", ">>", ">|", "<", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>"}
command_wrappers = {"env", "command", "sudo"}
shell_executors = {"bash", "sh", "zsh"}
read_only_commands = {"grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "comm", "diff", "cut", "tr", "uniq", "jq", "ls", "which", "type", "echo", "printf"}
wrapper_value_flags = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "sudo": {"-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
             "-C", "--close-from", "-T", "--command-timeout", "-A", "--askpass"},
    "command": set(),
}


def split_punctuation_tokens(tokens):
    out = []
    for token in tokens:
        if token in {"<(", ">("}:
            out.extend([token[0], "("])
            continue
        if token.count(chr(96)) == 1 and token != chr(96):
            parts = token.split(chr(96))
            for idx, part in enumerate(parts):
                if idx > 0:
                    out.append(chr(96))
                if part:
                    out.append(part)
            continue
        if token and all(ch in ";()" for ch in token):
            out.extend(token)
            continue
        out.append(token)
    return out


def parse_tokens(text):
    text = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', text)
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return split_punctuation_tokens(list(lexer))
    except ValueError:
        return split_punctuation_tokens(re.findall(r"&&|\|\||[;|&]|[^\s;|&]+", text))


def is_assignment(token):
    return re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) is not None


def is_gh(token):
    return os.path.basename(token) == "gh"


def is_wrapper(token):
    return os.path.basename(token) in command_wrappers


def skip_wrapper_options(tokens, i, wrapper):
    value_flags = wrapper_value_flags.get(wrapper, set())
    while i < len(tokens) and tokens[i].startswith("-"):
        token = tokens[i]
        i += 1
        if token in value_flags and i < len(tokens):
            i += 1
            continue
        if any(token.startswith(f"{flag}=") for flag in value_flags if flag.startswith("--")):
            continue
    if wrapper == "env":
        while i < len(tokens) and is_assignment(tokens[i]):
            i += 1
    return i


def env_payloads(tokens, wrapper_index):
    payloads = []
    j = wrapper_index + 1
    while j < len(tokens):
        token = tokens[j]
        if token in redirects:
            j += 2
            continue
        if token in {"-S", "--split-string"}:
            if j + 1 < len(tokens):
                payloads.append(tokens[j + 1])
            j += 2
            continue
        if token.startswith("--split-string="):
            payloads.append(token.split("=", 1)[1])
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
            value = token.split("=", 1)[1]
            if value:
                payloads.append(value)
            j += 1
            continue
        break
    return payloads


def skip_process_substitution_value(tokens, i):
    end = process_substitution_end(tokens, i) if "process_substitution_end" in globals() else None
    if (
        end is not None
        and "is_safe_readonly_process_substitution" in globals()
        and is_safe_readonly_process_substitution(tokens, i, end)
    ):
        return end
    return min(i + 1, len(tokens))


def skip_value_flag(tokens, i):
    token = tokens[i]
    if token in value_flags:
        return skip_process_substitution_value(tokens, i + 1)
    if any(token.startswith(f"{flag}=") for flag in value_flags):
        if token.endswith("="):
            return skip_process_substitution_value(tokens, i + 1)
        return i + 1
    return None


def shell_payload(segment_tokens, i):
    base = os.path.basename(segment_tokens[i])
    if base in shell_executors:
        j = i + 1
        while j < len(segment_tokens):
            token = segment_tokens[j]
            if token in redirects:
                j += 2
                continue
            if token == "-c" or (token.startswith("-") and not token.startswith("--") and "c" in token[1:]):
                return segment_tokens[j + 1] if j + 1 < len(segment_tokens) else ""
            j += 1
    if base == "eval" and i + 1 < len(segment_tokens):
        return " ".join(segment_tokens[i + 1:])
    return ""


def runtime_command_strings(token):
    nested = []
    marker = chr(36) + "("
    i = 0
    while True:
        start = token.find(marker, i)
        if start == -1:
            break
        depth = 1
        j = start + len(marker)
        while j < len(token):
            if token[j] == "(":
                depth += 1
            elif token[j] == ")":
                depth -= 1
                if depth == 0:
                    inner = token[start + len(marker):j].strip()
                    if inner:
                        nested.append(inner)
                    i = j + 1
                    break
            j += 1
        else:
            i = start + len(marker)
    tick = chr(96)
    i = 0
    while True:
        start = token.find(tick, i)
        if start == -1:
            break
        end = token.find(tick, start + 1)
        if end == -1:
            break
        inner = token[start + 1:end].strip()
        if inner:
            nested.append(inner)
        i = end + 1
    return nested


def shell_payload_token_indexes(segment_tokens):
    indexes = set()
    i = 0
    while i < len(segment_tokens):
        base = os.path.basename(segment_tokens[i])
        end = i + 1
        while end < len(segment_tokens) and segment_tokens[end] not in separators:
            end += 1
        if base in shell_executors:
            j = i + 1
            while j < end:
                token = segment_tokens[j]
                if token in redirects:
                    j += 2
                    continue
                if token == "-c" or (token.startswith("-") and not token.startswith("--") and "c" in token[1:]):
                    if j + 1 < end:
                        indexes.add(j + 1)
                    break
                j += 1
        elif base == "eval" and i + 1 < end:
            indexes.update(range(i + 1, end))
        i += 1
    return indexes


def count_tokens_pr_merge(tokens, depth=0):
    count = 0
    segment = []
    for token in tokens + [";"]:
        if token in separators:
            count += count_segment_pr_merge(segment, depth)
            segment = []
        else:
            segment.append(token)
    return count


def skip_redirects(tokens, i):
    while i < len(tokens) and tokens[i] in redirects:
        i += 2
    return i


def count_segment_pr_merge(segment_tokens, depth=0):
    if depth > 3:
        return 0
    if not segment_tokens:
        return 0

    count = 0
    runtime_skip = shell_payload_token_indexes(segment_tokens)
    for index, token in enumerate(segment_tokens):
        if index in runtime_skip or is_assignment(token):
            continue
        for payload in runtime_command_strings(token):
            count += count_tokens_pr_merge(parse_tokens(payload), depth + 1)

    i = skip_redirects(segment_tokens, 0)
    while i < len(segment_tokens) and is_assignment(segment_tokens[i]):
        value = segment_tokens[i].split("=", 1)[1]
        if value:
            count += count_tokens_pr_merge(parse_tokens(value), depth + 1)
        i += 1
    i = skip_redirects(segment_tokens, i)

    while i < len(segment_tokens):
        i = skip_redirects(segment_tokens, i)
        if i >= len(segment_tokens) or not is_wrapper(segment_tokens[i]):
            break
        wrapper_index = i
        wrapper = os.path.basename(segment_tokens[i])
        if wrapper == "env":
            for payload in env_payloads(segment_tokens, wrapper_index):
                if payload:
                    count += count_tokens_pr_merge(parse_tokens(payload), depth + 1)
        i += 1
        while True:
            before = i
            i = skip_redirects(segment_tokens, i)
            i = skip_wrapper_options(segment_tokens, i, wrapper)
            i = skip_redirects(segment_tokens, i)
            if i == before:
                break

    i = skip_redirects(segment_tokens, i)
    if i < len(segment_tokens):
        payload = shell_payload(segment_tokens, i)
        if payload:
            count += count_tokens_pr_merge(parse_tokens(payload), depth + 1)

    i = skip_redirects(segment_tokens, i)
    if i >= len(segment_tokens) or not is_gh(segment_tokens[i]):
        return count

    i += 1
    while i < len(segment_tokens):
        skipped = skip_value_flag(segment_tokens, i)
        if skipped is not None:
            i = skipped
            continue
        if segment_tokens[i].startswith("-"):
            i += 1
            continue
        break

    if (
        i + 1 < len(segment_tokens)
        and segment_tokens[i] == "pr"
        and segment_tokens[i + 1] == "merge"
    ):
        count += 1
    return count


cmd = os.environ.get("_CMD", "")
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', cmd)
print(count_tokens_pr_merge(parse_tokens(cmd)))
PY
}

command_mentions_pr_merge_text() {
  local cmd="${1:-}"
  local count
  count=$(command_pr_merge_text_count "$cmd" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]]
}

command_uses_shell_executor() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || return 1
  printf '%s' "$cmd" | grep -Eq '(^|[[:space:];|&"'\''`])([[:alnum:]_./-]*/)?(bash|sh|zsh|eval)([[:space:];|&"'\''`]|$)'
}

should_block_unparsed_pr_merge() {
  local cmd="${1:-}"
  local merge_count="${2:-0}"
  local text_count
  command_uses_shell_executor "$cmd" || return 1
  text_count=$(command_pr_merge_text_count "$cmd" 2>/dev/null || echo 0)
  [[ "$text_count" -gt "$merge_count" ]] || return 1
  return 0
}

print_unparsed_pr_merge_block() {
  echo "[BLOCK] gh pr merge を安全に解析できません。shell/eval 経由で隠さず、gh pr merge <number> --repo owner/repo を直接実行してください。" >&2
}
# =========================================================================
# Helper: resolve repository (fork-aware)
# Priority: --repo flag > CLAUDE_FORK_REPO env > upstream remote > origin
# =========================================================================
resolve_repo() {
  local cmd="${1:-}"

  # Priority 1: --repo / -R flag in command
  if [[ -n "$cmd" ]]; then
    local parsed_repo
    parsed_repo=$(_CMD="$cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

global_value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
pr_value_flags = {
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
redirects = {">", ">>", ">|", "<", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>"}
shell_executors = {"bash", "sh", "zsh"}
read_only_commands = {"grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "comm", "diff", "cut", "tr", "uniq", "jq", "ls", "which", "type", "echo", "printf"}

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

def skip_process_substitution_value(tokens, i):
    end = process_substitution_end(tokens, i) if "process_substitution_end" in globals() else None
    if (
        end is not None
        and "is_safe_readonly_process_substitution" in globals()
        and is_safe_readonly_process_substitution(tokens, i, end)
    ):
        return end
    return min(i + 1, len(tokens))


def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return skip_process_substitution_value(tokens, i + 1)
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        if token.endswith("="):
            return skip_process_substitution_value(tokens, i + 1)
        return i + 1
    return None

def split_punctuation_tokens(tokens):
    out = []
    for token in tokens:
        if token in {"<(", ">("}:
            out.extend([token[0], "("])
            continue
        if token.count(chr(96)) == 1 and token != chr(96):
            parts = token.split(chr(96))
            for idx, part in enumerate(parts):
                if idx > 0:
                    out.append(chr(96))
                if part:
                    out.append(part)
            continue
        if token and all(ch in ";()" for ch in token):
            out.extend(token)
            continue
        out.append(token)
    return out


def process_substitution_end(tokens, i):
    if i + 1 >= len(tokens) or tokens[i] not in {"<", ">"} or tokens[i + 1] != "(":
        return None
    depth = 1
    j = i + 2
    while j < len(tokens):
        if tokens[j] == "(":
            depth += 1
        elif tokens[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None


def has_runtime_expansion(tokens):
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "$" and i + 1 < len(tokens) and tokens[i + 1] == "(":
            return True
        if "$" + "(" in token or chr(96) in token:
            return True
        if process_substitution_end(tokens, i) is not None:
            return True
        i += 1
    return False


def is_safe_readonly_process_substitution(tokens, start, end):
    inner = tokens[start + 2:end - 1]
    if not inner:
        return True
    return is_single_readonly_command(inner) and not has_runtime_expansion(inner)


def strip_readonly_process_substitutions(tokens):
    out = []
    i = 0
    while i < len(tokens):
        end = process_substitution_end(tokens, i)
        if end is not None and is_safe_readonly_process_substitution(tokens, i, end):
            out.extend([tokens[i], "(", ")"])
            i = end
            continue
        out.append(tokens[i])
        i += 1
    return out


def strip_pr_value_flag_process_substitutions(tokens):
    out = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token in pr_value_flags and i + 1 < len(tokens):
            out.append(token)
            end = process_substitution_end(tokens, i + 1)
            if end is not None and is_safe_readonly_process_substitution(tokens, i + 1, end):
                out.extend([tokens[i + 1], "(", ")"])
                i = end
                continue
            i += 1
            continue
        if any(token.startswith(f"{flag}=") for flag in pr_value_flags if flag.startswith("--")):
            out.append(token)
            if token.endswith("=") and i + 1 < len(tokens):
                end = process_substitution_end(tokens, i + 1)
                if end is not None and is_safe_readonly_process_substitution(tokens, i + 1, end):
                    out.extend([tokens[i + 1], "(", ")"])
                    i = end
                    continue
            i += 1
            continue
        out.append(token)
        i += 1
    return out


def parse_tokens(text):
    text = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', text)
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = strip_readonly_process_substitutions(split_punctuation_tokens(list(lexer)))
        return strip_pr_value_flag_process_substitutions(tokens)
    except Exception:
        return []

def command_end(tokens, start):
    end = start
    while end < len(tokens) and tokens[end] not in separators:
        end += 1
    return end

def runtime_command_strings(token):
    nested = []
    marker = chr(36) + "("
    i = 0
    while True:
        start = token.find(marker, i)
        if start == -1:
            break
        depth = 1
        j = start + len(marker)
        while j < len(token):
            if token[j] == "(":
                depth += 1
            elif token[j] == ")":
                depth -= 1
                if depth == 0:
                    inner = token[start + len(marker):j].strip()
                    if inner:
                        nested.append(inner)
                    i = j + 1
                    break
            j += 1
        else:
            i = start + len(marker)
    tick = chr(96)
    i = 0
    while True:
        start = token.find(tick, i)
        if start == -1:
            break
        end = token.find(tick, start + 1)
        if end == -1:
            break
        inner = token[start + 1:end].strip()
        if inner:
            nested.append(inner)
        i = end + 1
    return nested

def nested_command_strings(tokens):
    nested = []
    i = 0
    while i < len(tokens):
        nested.extend(runtime_command_strings(tokens[i]))
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

def is_single_readonly_command(tokens):
    if not tokens or any(token in separators for token in tokens):
        return False
    i = 0
    while i < len(tokens):
        if tokens[i] in redirects:
            i += 2
            continue
        if is_assignment(tokens[i]):
            i += 1
            continue
        break
    return i < len(tokens) and os.path.basename(tokens[i]) in read_only_commands


def expand_nested_shell(tokens, depth=0):
    if depth >= 3:
        return tokens
    expanded = list(tokens)
    for nested in nested_command_strings(tokens):
        nested_tokens = parse_tokens(nested)
        if nested_tokens:
            if is_single_readonly_command(nested_tokens):
                continue
            expanded.append(";")
            expanded.extend(expand_nested_shell(nested_tokens, depth + 1))
    return expanded

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
cmd = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', cmd)
tokens = expand_nested_shell(parse_tokens(cmd))
if not tokens:
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

  # Priority 2: CLAUDE_FORK_REPO env var fallback
  if [[ -n "${CLAUDE_FORK_REPO:-}" ]]; then
    echo "$CLAUDE_FORK_REPO"
    return
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
redirects = {">", ">>", ">|", "<", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>"}

def skip_process_substitution_value(tokens, i):
    end = process_substitution_end(tokens, i) if "process_substitution_end" in globals() else None
    if end is not None:
        return end
    return min(i + 1, len(tokens))


def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return skip_process_substitution_value(tokens, i + 1)
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        if token.endswith("="):
            return skip_process_substitution_value(tokens, i + 1)
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
import os
import re
import shlex
import subprocess
import sys

global_value_flags = {"--repo", "-R", "--hostname", "--config-dir"}
separators = {"&&", "||", ";", "|", "&", "(", ")"}
redirects = {">", ">>", ">|", "<", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>"}
shell_executors = {"bash", "sh", "zsh"}
read_only_commands = {"grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "comm", "diff", "cut", "tr", "uniq", "jq", "ls", "which", "type", "echo", "printf"}
command_wrappers = {"env", "command", "sudo"}
wrapper_value_flags = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "sudo": {"-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
             "-C", "--close-from", "-T", "--command-timeout", "-A", "--askpass"},
    "command": set(),
}

def split_punctuation_tokens(tokens):
    out = []
    for token in tokens:
        if token in {"<(", ">("}:
            out.extend([token[0], "("])
            continue
        if token.count(chr(96)) == 1 and token != chr(96):
            parts = token.split(chr(96))
            for idx, part in enumerate(parts):
                if idx > 0:
                    out.append(chr(96))
                if part:
                    out.append(part)
            continue
        if token and all(ch in ";()" for ch in token):
            out.extend(token)
            continue
        out.append(token)
    return out


def parse_tokens(text):
    text = re.sub(r'(^|[ \t\r\n;&|])([0-9]+)(<<<|>>?|>\||<<?|>&|<&|&>>?|&>)', r'\1\3', text)
    try:
        lexer = shlex.shlex(text.replace("\n", ";"), posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return split_punctuation_tokens(list(lexer))
    except Exception:
        return []

def is_gh(token):
    return os.path.basename(token) == "gh"

def is_assignment(token):
    return re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) is not None

def skip_wrapper_options(tokens, i, wrapper):
    value_flags = wrapper_value_flags.get(wrapper, set())
    while i < len(tokens) and tokens[i].startswith("-"):
        token = tokens[i]
        i += 1
        if token in value_flags and i < len(tokens):
            i += 1
            continue
        if any(token.startswith(f"{flag}=") for flag in value_flags if flag.startswith("--")):
            continue
    if wrapper == "env":
        while i < len(tokens) and is_assignment(tokens[i]):
            i += 1
    return i

def env_effects(tokens, wrapper_index):
    payloads = []
    chdir = ""
    j = wrapper_index + 1
    while j < len(tokens):
        token = tokens[j]
        if token in redirects:
            j += 2
            continue
        if token in {"-S", "--split-string"}:
            if j + 1 < len(tokens):
                payloads.append(tokens[j + 1])
            j += 2
            continue
        if token.startswith("--split-string="):
            payloads.append(token.split("=", 1)[1])
            j += 1
            continue
        if token in {"-C", "--chdir"}:
            if j + 1 < len(tokens):
                chdir = tokens[j + 1]
            j += 2
            continue
        if token.startswith("--chdir="):
            chdir = token.split("=", 1)[1]
            j += 1
            continue
        if token in {"-u", "--unset"}:
            j += 2
            continue
        if token.startswith("--unset="):
            j += 1
            continue
        if token.startswith("-") and token != "-":
            j += 1
            continue
        if is_assignment(token):
            value = token.split("=", 1)[1]
            if value:
                payloads.append(value)
            j += 1
            continue
        break
    return payloads, chdir

def command_start(segment):
    i = 0
    while i < len(segment) and is_assignment(segment[i]):
        i += 1
    while i < len(segment) and os.path.basename(segment[i]) in command_wrappers:
        wrapper = os.path.basename(segment[i])
        i += 1
        i = skip_wrapper_options(segment, i, wrapper)
    return i

def skip_process_substitution_value(tokens, i):
    end = process_substitution_end(tokens, i) if "process_substitution_end" in globals() else None
    if end is not None:
        return end
    return min(i + 1, len(tokens))


def skip_value_flag(tokens, i, flags):
    token = tokens[i]
    if token in flags:
        return skip_process_substitution_value(tokens, i + 1)
    if any(token.startswith(f"{flag}=") for flag in flags if flag.startswith("--")):
        if token.endswith("="):
            return skip_process_substitution_value(tokens, i + 1)
        return i + 1
    return None

def is_gh_pr_command(tokens, i, end):
    if not is_gh(tokens[i]):
        return False
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
        return token == "pr" and j + 1 < end and tokens[j + 1] in {"create", "merge"}
    return False

def shell_payload(tokens, i, end):
    base = os.path.basename(tokens[i])
    if base in shell_executors:
        j = i + 1
        while j < end:
            token = tokens[j]
            if token in redirects:
                j += 2
                continue
            if token == "-c" or (token.startswith("-") and not token.startswith("--") and "c" in token[1:]):
                return tokens[j + 1] if j + 1 < end else ""
            j += 1
    if base == "eval" and i + 1 < end:
        return " ".join(tokens[i + 1:end])
    return ""

def split_segments(tokens):
    segments = []
    segment = []
    for token in tokens:
        if token in separators:
            if segment:
                segments.append(segment)
            segment = []
        else:
            segment.append(token)
    if segment:
        segments.append(segment)
    return segments

def resolve_cd_path(path, base_dir):
    if not path or path == "-":
        return ""
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        return os.path.abspath(expanded)
    return os.path.abspath(os.path.join(base_dir or os.getcwd(), expanded))

def context_for_gh_pr(text, base_dir="", base_is_explicit=False, depth=0):
    if depth >= 3:
        return ""
    tokens = parse_tokens(text)
    if not tokens:
        return ""
    candidate = base_dir if base_is_explicit else ""
    for segment in split_segments(tokens):
        if not segment:
            continue
        pre = 0
        while pre < len(segment) and is_assignment(segment[pre]):
            pre += 1
        if pre < len(segment) and os.path.basename(segment[pre]) == "env":
            payloads, chdir = env_effects(segment, pre)
            if chdir:
                candidate = resolve_cd_path(chdir, candidate or base_dir)
                base_dir = candidate or base_dir
                base_is_explicit = bool(candidate)
            for payload in payloads:
                nested = context_for_gh_pr(payload, candidate or base_dir, bool(candidate), depth + 1)
                if nested:
                    return nested
        start = command_start(segment)
        if start >= len(segment):
            continue
        if segment[start] == "cd" and start + 1 < len(segment):
            candidate = resolve_cd_path(segment[start + 1], base_dir)
            base_dir = candidate or base_dir
            base_is_explicit = bool(candidate)
            continue
        if is_gh_pr_command(segment, start, len(segment)):
            return candidate
        payload = shell_payload(segment, start, len(segment))
        if payload:
            nested = context_for_gh_pr(payload, candidate or base_dir, bool(candidate), depth + 1)
            if nested:
                return nested
    return ""

cmd = os.environ.get("_CMD", "")
candidate = context_for_gh_pr(cmd)
if not candidate:
    sys.exit(0)

try:
    top = subprocess.check_output(
        ["git", "-C", candidate, "rev-parse", "--show-toplevel"],
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

review_state_files() {
  local global_state="$HOME/.claude/state/review-status.json"

  echo "$REVIEW_STATE"
  if [[ "$global_state" != "$REVIEW_STATE" ]]; then
    echo "$global_state"
  fi
}

review_sha_field() {
  case "$1" in
    code_review) echo "code_review_sha" ;;
    codex_review|codex_review_ran|codex_critical|codex_high|codex_medium|codex_low) echo "codex_review_sha" ;;
    *) echo "${1}_sha" ;;
  esac
}

gstack_review_file() {
  local branch="$1"
  local slug safe_branch

  slug=$(remote_slug origin 2>/dev/null | tr '/' '-' || echo "")
  [[ -n "$slug" ]] || return 1
  safe_branch=$(printf '%s' "$branch" | tr '/' '-')
  printf '%s\n' "$HOME/.gstack/projects/${slug}/${safe_branch}-reviews.jsonl"
}

gstack_review_for_head() {
  local branch="$1"
  local head_sha="$2"
  local review_file

  [[ -n "$branch" && -n "$head_sha" && "$head_sha" != "null" ]] || { echo "no"; return; }
  review_file=$(gstack_review_file "$branch" || echo "")
  [[ -n "$review_file" && -f "$review_file" ]] || { echo "no"; return; }

  _REVIEW_FILE="$review_file" _HEAD_SHA="$head_sha" python3 - <<'PY' 2>/dev/null || echo "no"
import json
import os

accepted = {"approve", "approved", "pass", "passed", "success", "ok", "lgtm", "clean", "no_findings", "no findings"}
head_sha = os.environ["_HEAD_SHA"]

def same_sha(value):
    value = str(value or "").strip()
    if not value:
        return False
    if value == head_sha:
        return True
    shorter, longer = sorted((value, head_sha), key=len)
    return len(shorter) >= 6 and longer.startswith(shorter)

try:
    with open(os.environ["_REVIEW_FILE"]) as f:
        lines = f.readlines()
except Exception:
    print("no")
    raise SystemExit

for line in reversed(lines):
    try:
        entry = json.loads(line)
    except Exception:
        continue
    entry_sha = entry.get("commit") or entry.get("head_sha") or entry.get("head") or entry.get("sha")
    if not same_sha(entry_sha):
        continue
    status = str(entry.get("status") or entry.get("result") or entry.get("gate") or "").strip().lower()
    if status in accepted:
        print("yes")
        raise SystemExit
    findings = entry.get("findings")
    if isinstance(findings, dict):
        critical = int(findings.get("critical") or findings.get("CRITICAL") or 0)
        high = int(findings.get("high") or findings.get("HIGH") or 0)
        if critical == 0 and high == 0:
            print("yes")
            raise SystemExit

print("no")
PY
}

read_review() {
  local branch="$1"
  local field="$2"
  local state_file

  # Check both state files — return "yes" if EITHER has the field set to true
  while IFS= read -r state_file; do
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
  done < <(review_state_files)

  echo "no"
}

read_review_for_head() {
  local branch="$1"
  local field="$2"
  local head_sha="$3"
  local sha_field state_file

  [[ -n "$head_sha" && "$head_sha" != "null" ]] || { echo "no"; return; }
  sha_field=$(review_sha_field "$field")

  while IFS= read -r state_file; do
    [[ ! -f "$state_file" ]] && continue
    if command -v jq &>/dev/null; then
      local val
      val=$(jq -r --arg b "$branch" --arg f "$field" --arg sf "$sha_field" --arg sha "$head_sha" \
        'if ((.[$b][$f] // false) == true and ((.[$b][$sf] // "") == $sha)) then "yes" else "no" end' \
        "$state_file" 2>/dev/null || echo "no")
      if [[ "$val" == "yes" ]]; then
        echo "yes"
        return
      fi
    else
      local val
      val=$(_STATE="$state_file" _BR="$branch" _FLD="$field" _SHA_FLD="$sha_field" _SHA="$head_sha" python3 -c "
import json, os
try:
    with open(os.environ['_STATE']) as f:
        data = json.load(f)
    row = data.get(os.environ['_BR'], {})
    print('yes' if row.get(os.environ['_FLD']) is True and row.get(os.environ['_SHA_FLD']) == os.environ['_SHA'] else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
      if [[ "$val" == "yes" ]]; then
        echo "yes"
        return
      fi
    fi
  done < <(review_state_files)
  if [[ "$field" == "code_review" ]] && [[ "$(gstack_review_for_head "$branch" "$head_sha")" == "yes" ]]; then
    echo "yes"
    return
  fi
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

read_codex_severity_for_head() {
  local branch="$1"
  local field="$2"
  local head_sha="$3"
  local state_file

  [[ -n "$head_sha" && "$head_sha" != "null" ]] || { echo "-1"; return; }

  while IFS= read -r state_file; do
    [[ ! -f "$state_file" ]] && continue
    if command -v jq &>/dev/null; then
      local val
      val=$(jq -r --arg b "$branch" --arg f "$field" --arg sha "$head_sha" \
        'if ((.[$b].codex_review_sha // "") == $sha) then (.[$b][$f] // -1) else -1 end' \
        "$state_file" 2>/dev/null || echo "-1")
      if [[ "$val" != "-1" ]] && [[ "$val" != "null" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
        return
      fi
    else
      local val
      val=$(_STATE="$state_file" _BR="$branch" _FLD="$field" _SHA="$head_sha" python3 -c "
import json, os
try:
    with open(os.environ['_STATE']) as f:
        data = json.load(f)
    row = data.get(os.environ['_BR'], {})
    v = row.get(os.environ['_FLD'], -1) if row.get('codex_review_sha') == os.environ['_SHA'] else -1
    print(int(v) if isinstance(v, (int, float)) and v >= 0 else -1)
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")
      if [[ "$val" != "-1" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
        return
      fi
    fi
  done < <(review_state_files)
  echo "-1"
}
