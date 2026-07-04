#!/bin/bash
# Regression harness for repo-scoped pr-review-read state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TMP_HOME="$TMP_ROOT/home"
TMP_PARENT="$TMP_ROOT/parent"
TMP_REPO="$TMP_PARENT/repo"
TMP_OTHER_REPO="$TMP_PARENT/other"
TMP_BIN="$TMP_ROOT/bin"
GH_LOG="$TMP_ROOT/gh.log"
mkdir -p "$TMP_HOME/.claude/state" "$TMP_PARENT" "$TMP_BIN"

git init -q "$TMP_REPO"
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf '# test\n' > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -q -m init
git -C "$TMP_REPO" remote add origin git@github.com:owner/repo.git
mkdir -p "$TMP_REPO/.claude/state"

git init -q "$TMP_OTHER_REPO"
git -C "$TMP_OTHER_REPO" config user.email test@example.com
git -C "$TMP_OTHER_REPO" config user.name Test
printf '# other\n' > "$TMP_OTHER_REPO/README.md"
git -C "$TMP_OTHER_REPO" add README.md
git -C "$TMP_OTHER_REPO" commit -q -m init
git -C "$TMP_OTHER_REPO" remote add origin git@github.com:owner/other.git
mkdir -p "$TMP_OTHER_REPO/.claude/state"

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"

if [[ "${1:-}" != "api" ]]; then
  printf '{}\n'
  exit 0
fi

path="${2:-}"
jq_expr=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--jq" ]]; then
    jq_expr="$arg"
    break
  fi
  prev="$arg"
done

case "$path" in
  repos/owner/repo/pulls/123)
    case "$jq_expr" in
      ".head.sha"|".head.sha // \"\"") printf 'abc123\n' ;;
      ".head.ref"|".head.ref // \"\"") printf 'fix/review-state\n' ;;
      ".base.ref // \"\"") printf 'develop\n' ;;
      *) printf '{"head":{"sha":"abc123","ref":"fix/review-state"},"base":{"ref":"develop"}}\n' ;;
    esac
    ;;
  repos/owner/repo/commits/abc123/check-runs)
    case "$jq_expr" in
      *'status != "completed"'*) printf '0\n' ;;
      *'conclusion == "failure"'*) printf '0\n' ;;
      *'test("claude-review"'*) printf 'success\n' ;;
      *) printf '{"check_runs":[{"name":"claude-review","status":"completed","conclusion":"success"}]}\n' ;;
    esac
    ;;
  repos/owner/repo/pulls/123/reviews)
    printf '[]\n'
    ;;
  repos/owner/repo/issues/123/comments)
    case "$jq_expr" in
      length) printf '1\n' ;;
      *'.[].body'*) printf 'review LGTM\n' ;;
      *)
        cat <<'JSON'
[{"body":"review LGTM","user":{"login":"claude[bot]","type":"Bot"},"updated_at":"2026-07-03T00:00:00Z"}]
JSON
        ;;
    esac
    ;;
  *)
    printf '{}\n'
    ;;
esac
FAKEGH
chmod +x "$TMP_BIN/gh"

PASS=0
FAIL=0

payload() {
  jq -n --arg cmd "$1" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

reset_state() {
  rm -rf "$TMP_HOME/.claude/state" "$TMP_PARENT/.claude" "$TMP_REPO/.claude/state" "$TMP_OTHER_REPO/.claude/state"
  mkdir -p "$TMP_HOME/.claude/state" "$TMP_REPO/.claude/state" "$TMP_OTHER_REPO/.claude/state"
  printf '{}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
  printf '{}\n' > "$TMP_REPO/.claude/state/pr-review-read.json"
  printf '{}\n' > "$TMP_OTHER_REPO/.claude/state/pr-review-read.json"
}

run_verify_review() {
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_PARENT" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/scripts/verify-pr-review.sh" 123 owner/repo
  )
}

run_verify_review_from_foreign_cwd() {
  (
    cd "$TMP_OTHER_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_PARENT" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/scripts/verify-pr-review.sh" 123 owner/repo
  )
}

run_merge_gate() {
  (
    cd "$TMP_REPO"
    env -u CLAUDE_PROJECT_DIR HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/hooks/pr-merge-claude-review-gate.sh" \
        <<<"$(payload 'gh pr merge 123 --merge --repo owner/repo')"
  )
}

has_review_entry() {
  local file="$1" repo="$2" pr="$3" head="$4"
  python3 - "$file" "$repo" "$pr" "$head" <<'PY'
import json
import sys

path, repo, pr, head = sys.argv[1:]

try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

def entry_matches(entry):
    return (
        isinstance(entry, dict)
        and entry.get("review_read") is True
        and entry.get("repo") == repo
        and entry.get("head_sha") == head
    )

candidates = []
if isinstance(data, dict):
    candidates.append(data.get(pr))
    nested = data.get(repo)
    if isinstance(nested, dict):
        candidates.append(nested.get(pr))
    for key in (f"{repo}#{pr}", f"{repo}:{pr}", f"{repo}/{pr}"):
        candidates.append(data.get(key))

sys.exit(0 if any(entry_matches(entry) for entry in candidates) else 1)
PY
}

has_pr_entry_anywhere() {
  local file="$1" pr="$2"
  python3 - "$file" "$pr" <<'PY'
import json
import sys

path, pr = sys.argv[1:]

try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)
if pr in data:
    sys.exit(0)
for value in data.values():
    if isinstance(value, dict) and pr in value:
        sys.exit(0)
sys.exit(1)
PY
}

expect_success() {
  local desc="$1"
  shift
  local rc
  set +e
  "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (exit $rc)" >&2
    cat "$TMP_ROOT/err" >&2 || true
  fi
}

expect_block() {
  local desc="$1"
  shift
  local rc
  set +e
  "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected block exit 2, got $rc)" >&2
    cat "$TMP_ROOT/err" >&2 || true
  fi
}

echo "=== review-read state root and identity ==="

reset_state
expect_success "verify-pr-review succeeds with broad CLAUDE_PROJECT_DIR fixture" run_verify_review

if has_review_entry "$TMP_REPO/.claude/state/pr-review-read.json" owner/repo 123 abc123; then
  PASS=$((PASS + 1))
  echo "  PASS: repo-local review_read entry records repo, PR, and head"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: repo-local review_read entry missing repo/PR/head identity" >&2
  cat "$TMP_REPO/.claude/state/pr-review-read.json" >&2 || true
fi

if has_pr_entry_anywhere "$TMP_PARENT/.claude/state/pr-review-read.json" 123; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: broad CLAUDE_PROJECT_DIR wrote pr-review-read state to parent" >&2
  cat "$TMP_PARENT/.claude/state/pr-review-read.json" >&2 || true
else
  PASS=$((PASS + 1))
  echo "  PASS: broad CLAUDE_PROJECT_DIR did not receive review_read state"
fi

reset_state
expect_success "verify-pr-review maps --repo to repo-local state from foreign cwd" run_verify_review_from_foreign_cwd

if has_review_entry "$TMP_REPO/.claude/state/pr-review-read.json" owner/repo 123 abc123; then
  PASS=$((PASS + 1))
  echo "  PASS: foreign cwd verify wrote target repo-local review_read"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: foreign cwd verify missed target repo-local review_read" >&2
  cat "$TMP_REPO/.claude/state/pr-review-read.json" >&2 || true
fi

if has_pr_entry_anywhere "$TMP_OTHER_REPO/.claude/state/pr-review-read.json" 123; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: foreign cwd verify wrote review_read to cwd repo" >&2
  cat "$TMP_OTHER_REPO/.claude/state/pr-review-read.json" >&2 || true
else
  PASS=$((PASS + 1))
  echo "  PASS: foreign cwd verify did not write target PR to cwd repo"
fi

reset_state
printf '{"123":{"review_read":true,"repo":"owner/other","head_sha":"abc123"}}\n' \
  > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_block "merge gate rejects review_read for same PR/head from another repo" run_merge_gate

echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
