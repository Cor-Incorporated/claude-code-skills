#!/usr/bin/env bash
# record-code-review.sh
# ========================================================================
# PostToolUse hook: Records code-reviewer agent completion in review-status.json.
# When an Agent tool completes with subagent_type "code-reviewer" or
# name containing "review", marks the current branch as reviewed.
#
# Trigger: PostToolUse for Agent tool
# State file: <project>/.claude/state/review-status.json
# ========================================================================

# Subagent hooks should still record reviews
# (no subagent exemption here)

# Read stdin (tool input JSON) — macOS compatible (no timeout command)
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

# Check if this was a code-reviewer agent
IS_REVIEW="false"
if [[ -n "$input" ]] && command -v jq &>/dev/null; then
  # Check subagent_type
  subagent_type=$(echo "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
  # Check agent name
  agent_name=$(echo "$input" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
  # Check prompt for review keywords
  prompt=$(echo "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

  if [[ "$subagent_type" == "code-reviewer" ]] || \
     [[ "$subagent_type" == *"review"* ]] || \
     [[ "$agent_name" == *"review"* ]]; then
    IS_REVIEW="true"
  fi

  # Also detect feature-dev:code-reviewer
  if [[ "$subagent_type" == "feature-dev:code-reviewer" ]]; then
    IS_REVIEW="true"
  fi
fi

# Exit early if not a review agent
if [[ "$IS_REVIEW" != "true" ]]; then
  exit 0
fi

if ! command -v python3 &>/dev/null; then
  echo "[WARN] python3 が見つかりません。レビュー記録をスキップできないため fail-closed します。" >&2
  echo "  python3 をインストールしてください。" >&2
  exit 2
fi

resolve_review_context() {
  _HOOK_INPUT="$input" python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def load_tool_input(raw):
    try:
        payload = json.loads(raw or "{}")
    except (json.JSONDecodeError, TypeError):
        payload = {}
    tool_input = payload.get("tool_input", {})
    if isinstance(tool_input, str):
        try:
            tool_input = json.loads(tool_input)
        except (json.JSONDecodeError, TypeError):
            tool_input = {}
    return tool_input if isinstance(tool_input, dict) else {}


def git_root(path_text):
    if not path_text:
        return ""
    path = Path(os.path.expanduser(os.path.expandvars(path_text))).resolve()
    candidates = [path] if path.is_dir() else [path.parent]
    candidates.extend(candidates[0].parents)
    for candidate in candidates:
        try:
            out = subprocess.check_output(
                ["git", "-C", str(candidate), "rev-parse", "--show-toplevel"],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
        except Exception:
            continue
        if out:
            return out
    return ""


def git_branch(repo):
    if not repo:
        return ""
    try:
        return subprocess.check_output(
            ["git", "-C", repo, "branch", "--show-current"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        return ""


def git_branch_exists(repo, branch):
    """Return True if branch is a real ref in repo (local or remote)."""
    if not repo or not branch:
        return False
    for ref in (
        "refs/heads/%s" % branch,
        "refs/remotes/origin/%s" % branch,
    ):
        try:
            subprocess.check_call(
                ["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return True
        except Exception:
            continue
    return False


# Trailing punctuation that natural-language prompts append to a branch token
# (e.g. "branch: fix/x. Look for ..."). The `.` is a legal git ref char, so the
# greedy regex captures it; strip it here. A real branch never ends in these.
_TRAILING_PUNCT = ".,:;]})\"'`"


def clean_branch_token(value):
    if not isinstance(value, str):
        return ""
    return value.strip().split(":", 1)[-1].strip().rstrip(_TRAILING_PUNCT)


tool_input = load_tool_input(os.environ.get("_HOOK_INPUT", ""))
text_fields = []
for key in ("prompt", "description", "message", "task", "instructions"):
    value = tool_input.get(key)
    if isinstance(value, str):
        text_fields.append(value)
text = "\n".join(text_fields)

# --- Resolve repo FIRST so branch resolution can use it authoritatively ---
repo = ""
for key in ("cwd", "worktree", "worktree_path", "repo_path", "repository_path", "project_path", "working_directory"):
    value = tool_input.get(key)
    if isinstance(value, str):
        repo = git_root(value)
        if repo:
            break

if not repo:
    for raw_path in re.findall(r"/[^\s'\"`<>),]+", text):
        repo = git_root(raw_path.rstrip(".,:;]})"))
        if repo:
            break

if not repo and os.environ.get("CLAUDE_PROJECT_DIR"):
    repo = git_root(os.environ["CLAUDE_PROJECT_DIR"])

if not repo:
    repo = git_root(os.getcwd())

# --- Resolve branch: explicit token (cleaned) is authoritative ---
explicit_branch = ""
for key in ("branch", "head_branch", "head", "target_branch", "review_branch"):
    value = tool_input.get(key)
    if isinstance(value, str) and value.strip():
        explicit_branch = clean_branch_token(value)
        break

if not explicit_branch:
    patterns = [
        r"(?:^|[\s,;])--head(?:=|\s+)([A-Za-z0-9._/-]+)",
        r"(?:^|[\s,;])(?:branch|head|review_branch|target_branch)\s*[:=]\s*`?([A-Za-z0-9._/-]+)`?",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            explicit_branch = clean_branch_token(match.group(1))
            break

repo_branch = git_branch(repo)

# An explicit, punctuation-cleaned token from the prompt is AUTHORITATIVE — it is
# what the caller said to record, and read_review() looks up by that exact key.
# This is the source of the fix: the regex char class [A-Za-z0-9._/-] greedily
# captured a trailing sentence period (e.g. "branch: fix/x." -> "fix/x."), so the
# record landed on a key the gate never reads. clean_branch_token() strips it.
#
# Only when the cleaned token STILL does not resolve to a real ref do we snap to a
# punctuation-equivalent ref. A brand-new branch that is not yet a ref is kept
# as-is (never silently reattributed to the repo's HEAD branch).
branch = explicit_branch
if explicit_branch and repo and not git_branch_exists(repo, explicit_branch):
    stripped = explicit_branch.rstrip(_TRAILING_PUNCT)
    if stripped != explicit_branch and git_branch_exists(repo, stripped):
        branch = stripped

# No explicit token at all -> fall back to the resolved repo's checked-out branch.
if not branch:
    branch = repo_branch

print(json.dumps({"repo": repo, "branch": branch}))
PY
}

CONTEXT_JSON=$(resolve_review_context)
REPO_PATH=$(echo "$CONTEXT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('repo',''))" 2>/dev/null || echo "")
BRANCH=$(echo "$CONTEXT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('branch',''))" 2>/dev/null || echo "")

# Determine state directories — write to BOTH global and project-scoped
# to prevent CWD-dependent state mismatch (Issue #7)
GLOBAL_STATE_DIR="$HOME/.claude/state"
mkdir -p "$GLOBAL_STATE_DIR"
[ ! -f "$GLOBAL_STATE_DIR/review-status.json" ] && echo '{}' > "$GLOBAL_STATE_DIR/review-status.json"

PROJECT_STATE_DIRS=()
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_STATE_DIRS+=("${CLAUDE_PROJECT_DIR}/.claude/state")
fi
if [[ -n "$REPO_PATH" ]]; then
  PROJECT_STATE_DIRS+=("$REPO_PATH/.claude/state")
elif git rev-parse --show-toplevel &>/dev/null; then
  PROJECT_STATE_DIRS+=("$(git rev-parse --show-toplevel)/.claude/state")
fi

# Primary state file (global — always consistent regardless of CWD)
REVIEW_STATE="$GLOBAL_STATE_DIR/review-status.json"

if [[ -z "$BRANCH" ]]; then
  # Hardened fallback: avoid silently failing to record (caused "reviewed but not recorded")
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "")
  fi
  [[ -z "$BRANCH" ]] && BRANCH="${GITHUB_HEAD_REF:-}"
  if [[ -z "$BRANCH" ]]; then
    echo "⚠️ [review-gate] code-reviewer 完了を記録できません（branch 解決失敗）。" >&2
    echo "   レビューは行われましたが状態が未記録です。手動で再レビュー or branch を明示してください。" >&2
    exit 0
  fi
fi

# Update review-status.json: mark code_review as true for this branch
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Fix D: record the SHA of the BRANCH that was reviewed, not the dir's HEAD. HEAD
# is whatever commit happens to be checked out in $_SHA_DIR, which can be a
# DIFFERENT branch than $BRANCH (e.g. reviewing fix/x while sitting on develop).
# Resolve the resolved-branch ref: local refs/heads/<BRANCH>, then origin/<BRANCH>,
# then fall back to HEAD only if neither ref exists.
_SHA_DIR="${REPO_PATH:-${CLAUDE_PROJECT_DIR:-.}}"
REVIEW_SHA=$(git -C "$_SHA_DIR" rev-parse --verify --quiet "refs/heads/${BRANCH}" 2>/dev/null \
  || git -C "$_SHA_DIR" rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}" 2>/dev/null \
  || git -C "$_SHA_DIR" rev-parse HEAD 2>/dev/null || echo "")
if command -v python3 &>/dev/null; then
  # Primary: python3 + fcntl for atomic flock write
  _STATE="$REVIEW_STATE" _BR="$BRANCH" _NOW="$NOW" _SHA="$REVIEW_SHA" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except json.JSONDecodeError:
        s = {}
    s.setdefault(os.environ['_BR'], {})['code_review'] = True
    s[os.environ['_BR']]['code_review_at'] = os.environ['_NOW']
    if os.environ.get('_SHA'):
        s[os.environ['_BR']]['code_review_sha'] = os.environ['_SHA']
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
"
elif command -v jq &>/dev/null; then
  # Fallback: jq (not atomic — no flock)
  tmp=$(mktemp)
  jq --arg b "$BRANCH" --arg t "$NOW" \
    '.[$b] = ((.[$b] // {}) + {"code_review": true, "code_review_at": $t})' \
    "$REVIEW_STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$REVIEW_STATE"
fi

# Also write to project-scoped state if it exists (dual-write for CWD consistency)
for PROJECT_STATE_DIR in "${PROJECT_STATE_DIRS[@]}"; do
  [[ -z "$PROJECT_STATE_DIR" ]] && continue
  [[ "$PROJECT_STATE_DIR" == "$GLOBAL_STATE_DIR" ]] && continue
  PROJECT_REVIEW="$PROJECT_STATE_DIR/review-status.json"
  mkdir -p "$PROJECT_STATE_DIR"
  [ ! -f "$PROJECT_REVIEW" ] && echo '{}' > "$PROJECT_REVIEW"
  if command -v python3 &>/dev/null; then
    # Primary: python3 + fcntl for atomic flock write
    _STATE="$PROJECT_REVIEW" _BR="$BRANCH" _NOW="$NOW" _SHA="$REVIEW_SHA" python3 -c "
import json, os, fcntl
f_path = os.environ['_STATE']
with open(f_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except json.JSONDecodeError:
        s = {}
    s.setdefault(os.environ['_BR'], {})['code_review'] = True
    s[os.environ['_BR']]['code_review_at'] = os.environ['_NOW']
    if os.environ.get('_SHA'):
        s[os.environ['_BR']]['code_review_sha'] = os.environ['_SHA']
    f.seek(0); f.truncate()
    json.dump(s, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)
"
  elif command -v jq &>/dev/null; then
    # Fallback: jq (not atomic — no flock)
    tmp=$(mktemp)
    jq --arg b "$BRANCH" --arg t "$NOW" \
      '.[$b] = ((.[$b] // {}) + {"code_review": true, "code_review_at": $t})' \
      "$PROJECT_REVIEW" > "$tmp" 2>/dev/null && mv "$tmp" "$PROJECT_REVIEW"
  fi
done

echo "✅ [review-gate] code-reviewer 完了を記録: branch=$BRANCH repo=${REPO_PATH:-unknown}" >&2
exit 0
