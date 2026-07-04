#!/bin/bash
# Verify post-pr-create-review-trigger records the command target context.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/post-pr-create-review-trigger.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

SRC_REPO="$TMP_ROOT/source"
WT="$TMP_ROOT/worktree"
TMP_HOME="$TMP_ROOT/home"
TMP_BIN="$TMP_ROOT/bin"
GH_LOG="$TMP_ROOT/gh.log"
mkdir -p "$TMP_HOME/.claude/state" "$TMP_BIN"

git init -q "$SRC_REPO"
git -C "$SRC_REPO" config user.email test@example.com
git -C "$SRC_REPO" config user.name Test
printf '# test\n' > "$SRC_REPO/README.md"
git -C "$SRC_REPO" add README.md
git -C "$SRC_REPO" commit -q -m init
git -C "$SRC_REPO" branch develop
git -C "$SRC_REPO" checkout -q -b hook-cwd-branch
printf 'wrong cwd\n' > "$SRC_REPO/wrong.txt"
git -C "$SRC_REPO" add wrong.txt
git -C "$SRC_REPO" commit -q -m 'wrong cwd branch'
git -C "$SRC_REPO" worktree add -q -b feat/worktree-pr "$WT" develop
printf 'worktree change\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" commit -q -m 'worktree branch'
EXPECTED_SHA="$(git -C "$WT" rev-parse HEAD)"

cat > "$TMP_BIN/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$GH_LOG"

jq_expr=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--jq" ]]; then
    jq_expr="$arg"
    break
  fi
  prev="$arg"
done

if [[ "${1:-}" == "api" && "${2:-}" =~ ^repos/owner/repo/pulls/(456|457)$ ]]; then
  case "$jq_expr" in
    *head.sha*) printf '%s\n' "$EXPECTED_SHA" ;;
    *head.ref*) printf 'feat/worktree-pr\n' ;;
    *) printf '{"head":{"sha":"%s","ref":"feat/worktree-pr"}}\n' "$EXPECTED_SHA" ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  args=" $* "
  if [[ "$args" == *" --repo owner/repo "* && "$args" == *" --head feat/worktree-pr "* ]]; then
    printf '457\n'
  else
    printf '999\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  printf '%s\n' "$EXPECTED_SHA"
  exit 0
fi

exit 1
SH
chmod +x "$TMP_BIN/gh"

payload() {
  local command="$1"
  local response="${2:-}"
  CMD="$command" RESPONSE="$response" python3 - <<'PY'
import json
import os

print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["CMD"]},
    "tool_response": os.environ.get("RESPONSE", ""),
}))
PY
}

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

reset_state() {
  rm -rf "$SRC_REPO/.claude" "$WT/.claude" "$TMP_HOME/.claude"
  mkdir -p "$TMP_HOME/.claude/state"
  : > "$GH_LOG"
}

run_hook() {
  local command="$1"
  local response="${2:-}"
  (
    cd "$SRC_REPO"
    HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" EXPECTED_SHA="$EXPECTED_SHA" \
      bash "$HOOK" <<<"$(payload "$command" "$response")"
  ) >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
}

assert_lock_entry() {
  local file="$1"
  local pr="$2"
  local label="$3"
  if ENTRY_FILE="$file" PR="$pr" EXPECTED_SHA="$EXPECTED_SHA" python3 - <<'PY'
import json
import os
import sys

path = os.environ["ENTRY_FILE"]
with open(path) as f:
    data = json.load(f)

entry = data.get(os.environ["PR"], {})
expected = {
    "status": "review_pending",
    "repo": "owner/repo",
    "branch": "feat/worktree-pr",
    "head_sha": os.environ["EXPECTED_SHA"],
    "ci_green": False,
    "review_lgtm": False,
    "verified": False,
}
for key, value in expected.items():
    if entry.get(key) != value:
        print(f"{key}: expected {value!r}, got {entry.get(key)!r}", file=sys.stderr)
        sys.exit(1)
PY
  then
    pass "$label"
  else
    fail "$label"
    [[ -f "$file" ]] && cat "$file" >&2
  fi
}

assert_no_lock_entry() {
  local file="$1"
  local pr="$2"
  local label="$3"
  if [[ ! -f "$file" ]]; then
    pass "$label"
    return
  fi
  if ENTRY_FILE="$file" PR="$pr" python3 - <<'PY'
import json
import os
import sys

try:
    with open(os.environ["ENTRY_FILE"]) as f:
        data = json.load(f)
except Exception:
    data = {}
sys.exit(1 if os.environ["PR"] in data else 0)
PY
  then
    pass "$label"
  else
    fail "$label"
    cat "$file" >&2
  fi
}

echo "=== post-pr-create review trigger context ==="

CMD="cd '$WT' && gh pr create --repo owner/repo --head feat/worktree-pr --base develop --title 'fix: context' --body 'Refs #1'"

reset_state
if run_hook "$CMD" "https://github.com/owner/repo/pull/456"; then
  pass "T1: hook accepts worktree-context PR create with URL response"
else
  fail "T1: hook failed for URL response"
  cat "$TMP_ROOT/err" >&2 || true
fi
assert_lock_entry "$WT/.claude/state/pr-review-lock.json" "456" "T2: target worktree lock records repo, branch, and head SHA"
assert_lock_entry "$TMP_HOME/.claude/state/pr-review-lock.json" "456" "T3: global lock mirrors target context"
assert_no_lock_entry "$SRC_REPO/.claude/state/pr-review-lock.json" "456" "T4: hook cwd lock does not receive the PR entry"

reset_state
if run_hook "$CMD" ""; then
  pass "T5: hook accepts worktree-context PR create without URL response"
else
  fail "T5: hook failed without URL response"
  cat "$TMP_ROOT/err" >&2 || true
fi
assert_lock_entry "$WT/.claude/state/pr-review-lock.json" "457" "T6: PR fallback uses command repo and head branch"
if grep -q -- "--repo owner/repo --head feat/worktree-pr" "$GH_LOG"; then
  pass "T7: fallback lookup used explicit repo and --head branch"
else
  fail "T7: fallback lookup did not use explicit repo/head"
  cat "$GH_LOG" >&2 || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
