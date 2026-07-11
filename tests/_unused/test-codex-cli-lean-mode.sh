#!/usr/bin/env bash
# test-codex-cli-lean-mode.sh -- Codex CLI launcher uses MCP-off lean mode.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-parallel.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
BIN="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/codex-args.txt"
mkdir -p "$REPO" "$BIN"

git init -b main "$REPO" >/dev/null
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test User"
printf 'test\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -m "init" >/dev/null

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
  printf 'No findings\n' > "$out"
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

assert_contains() {
  local needle="$1"
  grep -F -- "$needle" "$ARGS_FILE" >/dev/null || fail "missing arg: $needle"
}

assert_not_contains() {
  local needle="$1"
  if grep -F -- "$needle" "$ARGS_FILE" >/dev/null; then
    fail "unexpected arg: $needle"
  fi
}

: > "$ARGS_FILE"
CODEX_OUTPUT="$TMP_DIR/review.md" \
CODEX_EVENT_LOG="$TMP_DIR/review.jsonl" \
CODEX_SNAPSHOT_FILE="$TMP_DIR/review-mcp.txt" \
CODEX_REVIEW_TIMEOUT_SEC=30 \
  bash "$SCRIPT" --review "$REPO" --base main >/dev/null

assert_contains "--profile"
assert_contains "exec-lean"
assert_contains "--strict-config"
assert_contains "--json"
assert_contains "--ephemeral"
assert_contains "approval_policy=\\\"never\\\""
assert_contains "mcp_servers.context7.enabled=false"
assert_contains "mcp_servers.github.enabled=false"
assert_contains "mcp_servers.supabase.enabled=false"
assert_contains "mcp_servers.node_repl.enabled=false"
assert_not_contains "--full-auto"

: > "$ARGS_FILE"
CODEX_OUTPUT="$TMP_DIR/impl.md" \
CODEX_EVENT_LOG="$TMP_DIR/impl.jsonl" \
CODEX_SNAPSHOT_FILE="$TMP_DIR/impl-mcp.txt" \
CODEX_TIMEOUT_SEC=30 \
  bash "$SCRIPT" "$REPO" "fix/test-lean-mode" "touch a small file" >/dev/null

assert_contains "--sandbox"
assert_contains "workspace-write"
assert_contains "approval_policy=\\\"never\\\""
assert_contains "mcp_servers.context7.enabled=false"
assert_not_contains "--full-auto"

: > "$ARGS_FILE"
CODEX_ENABLE_MCP=1 \
CODEX_OUTPUT="$TMP_DIR/rich-review.md" \
CODEX_EVENT_LOG="$TMP_DIR/rich-review.jsonl" \
CODEX_SNAPSHOT_FILE="$TMP_DIR/rich-review-mcp.txt" \
CODEX_REVIEW_TIMEOUT_SEC=30 \
  bash "$SCRIPT" --review "$REPO" --base main >/dev/null

assert_contains "rich-mcp"
assert_contains "mcp_servers.context7.enabled=true"
assert_contains "mcp_servers.github.enabled=true"
assert_contains "mcp_servers.supabase.enabled=true"
assert_contains "mcp_servers.node_repl.enabled=true"
assert_not_contains "mcp_servers.context7.enabled=false"

echo "codex CLI lean mode tests passed"
