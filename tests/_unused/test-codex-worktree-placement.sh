#!/usr/bin/env bash
# test-codex-worktree-placement.sh -- Codex delegation uses repo-local worktrees.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-parallel.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/codex-args.txt"
mkdir -p "$BIN"

cat > "$BIN/codex" <<'MOCK'
#!/usr/bin/env bash
printf '%q\n' "$@" >> "$MOCK_CODEX_ARGS"
printf '%s\n' '---' >> "$MOCK_CODEX_ARGS"

out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$arg"
  fi
  prev="$arg"
done

if [[ -n "$out" ]]; then
  printf 'Mock Codex complete\n' > "$out"
fi

printf '{"type":"item.completed","item":{"type":"agent_message","text":"mock"}}\n'
MOCK
chmod +x "$BIN/codex"

export PATH="$BIN:$PATH"
export MOCK_CODEX_ARGS="$ARGS_FILE"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git init -b develop "$repo" >/dev/null
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Test User"
  printf 'test\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "init" >/dev/null
}

assert_no_sibling_layout_reference() {
  if grep -F '../.worktrees' "$ROOT/scripts/codex-parallel.sh" "$ROOT/scripts/codex-orchestrate.sh" >/dev/null; then
    fail "sibling ../.worktrees layout still referenced"
  fi
}

assert_repo_local_worktree() {
  local repo="$TMP_DIR/repo-local"
  local branch="fix/repo-local-placement"
  local slug="fix-repo-local-placement"
  local expected="$repo/.worktrees/codex/$slug"
  local old_sibling="$TMP_DIR/.worktrees/repo-local-$slug"

  init_repo "$repo"

  : > "$ARGS_FILE"
  CODEX_OUTPUT="$TMP_DIR/repo-local.md" \
  CODEX_EVENT_LOG="$TMP_DIR/repo-local.jsonl" \
  CODEX_SNAPSHOT_FILE="$TMP_DIR/repo-local-mcp.txt" \
  CODEX_TIMEOUT_SEC=30 \
    bash "$SCRIPT" "$repo" "$branch" "mock implementation" >/dev/null

  [[ -d "$expected" ]] || fail "repo-local worktree not created: $expected"
  [[ ! -e "$old_sibling" ]] || fail "old sibling worktree was created: $old_sibling"

  local actual_branch
  actual_branch="$(git -C "$expected" branch --show-current)"
  [[ "$actual_branch" == "$branch" ]] || fail "worktree branch mismatch: $actual_branch"

  grep -F -- "$expected" "$ARGS_FILE" >/dev/null || fail "Codex was not launched in repo-local worktree"
}

assert_no_primary_checkout_switch() {
  local repo="$TMP_DIR/no-switch"
  local branch="fix/already-checked-out"
  local expected="$repo/.worktrees/codex/fix-already-checked-out"

  init_repo "$repo"
  git -C "$repo" checkout -b "$branch" >/dev/null

  : > "$ARGS_FILE"
  set +e
  CODEX_OUTPUT="$TMP_DIR/no-switch.md" \
  CODEX_EVENT_LOG="$TMP_DIR/no-switch.jsonl" \
  CODEX_SNAPSHOT_FILE="$TMP_DIR/no-switch-mcp.txt" \
  CODEX_TIMEOUT_SEC=30 \
    bash "$SCRIPT" "$repo" "$branch" "mock implementation" >/dev/null 2>"$TMP_DIR/no-switch.err"
  local rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "script should fail when target branch is already checked out"
  [[ "$(git -C "$repo" branch --show-current)" == "$branch" ]] || fail "primary checkout branch was switched"
  [[ ! -e "$repo/.worktrees" ]] || fail "worktree parent should not be created after preflight failure"
  [[ ! -e "$expected" ]] || fail "worktree should not be created for checked-out branch"
  [[ ! -s "$ARGS_FILE" ]] || fail "Codex should not run after checked-out branch preflight failure"
}

assert_existing_worktree_requires_opt_in() {
  local repo="$TMP_DIR/existing-worktree"
  local branch="fix/existing-worktree"
  local expected="$repo/.worktrees/codex/fix-existing-worktree"

  init_repo "$repo"
  git -C "$repo" branch "$branch"
  mkdir -p "$(dirname "$expected")"
  git -C "$repo" worktree add "$expected" "$branch" >/dev/null

  : > "$ARGS_FILE"
  set +e
  CODEX_OUTPUT="$TMP_DIR/existing.md" \
  CODEX_EVENT_LOG="$TMP_DIR/existing.jsonl" \
  CODEX_SNAPSHOT_FILE="$TMP_DIR/existing-mcp.txt" \
  CODEX_TIMEOUT_SEC=30 \
    bash "$SCRIPT" "$repo" "$branch" "mock implementation" >/dev/null 2>"$TMP_DIR/existing.err"
  local rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "script should fail when worktree exists without opt-in"
  grep -F "CODEX_REPLACE_WORKTREE=1" "$TMP_DIR/existing.err" >/dev/null || fail "missing explicit replace guidance"
  [[ -d "$expected" ]] || fail "existing worktree was removed without opt-in"
  [[ ! -s "$ARGS_FILE" ]] || fail "Codex should not run when existing worktree blocks"
}

assert_no_sibling_layout_reference
assert_repo_local_worktree
assert_no_primary_checkout_switch
assert_existing_worktree_requires_opt_in

echo "codex worktree placement tests passed"
