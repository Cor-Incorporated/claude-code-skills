#!/usr/bin/env bash
# test-local-permissions-guard.sh — local settings permissions guardrails
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRITE_HOOK="$ROOT/hooks/block-local-permissions-write.sh"
VALIDATE_HOOK="$ROOT/hooks/validate-no-local-permissions.sh"
AUTO_INIT_HOOK="$ROOT/hooks/auto-init-permissions.sh"
SANITIZE_SCRIPT="$ROOT/scripts/sanitize-local-permissions.sh"
SETTINGS="$ROOT/settings.json"
SETUP_FILE="$ROOT/setup.sh"

echo "=== Local permissions guard tests ==="

tmpdirs=()
cleanup() {
  for dir in "${tmpdirs[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

make_tmpdir() {
  local dir
  dir=$(mktemp -d)
  tmpdirs+=("$dir")
  echo "$dir"
}

# T1-T3: Syntax checks
for hook in "$WRITE_HOOK" "$VALIDATE_HOOK" "$AUTO_INIT_HOOK" "$SANITIZE_SCRIPT"; do
  if bash -n "$hook" 2>/dev/null; then
    pass "syntax check: $(basename "$hook")"
  else
    fail "syntax check failed: $(basename "$hook")"
  fi
done

# T4: Write hook blocks permissions in settings.local.json
payload='{"tool_input":{"file_path":"/tmp/project/.claude/settings.local.json","content":"{\"permissions\":{\"allow\":[\"Bash(gh:*)\"]}}"}}'
if out=$(echo "$payload" | bash "$WRITE_HOOK" 2>&1); then
  fail "T4: permissions write should be blocked"
else
  if [[ "$out" == *"[BLOCKED]"* ]]; then
    pass "T4: permissions write blocked"
  else
    fail "T4: expected block message"
  fi
fi

# T5: Write hook ignores non-settings-local files
payload='{"tool_input":{"file_path":"/tmp/project/settings.json","content":"{\"permissions\":{}}"}}'
if out=$(echo "$payload" | bash "$WRITE_HOOK" 2>&1); then
  if [[ -z "$out" ]]; then
    pass "T5: non-settings.local write allowed"
  else
    fail "T5: expected no output for non-settings.local write"
  fi
else
  fail "T5: non-settings.local write should not be blocked"
fi

# T6: Validate hook blocks HOME settings.local.json permissions
home_dir=$(make_tmpdir)
project_dir=$(make_tmpdir)
mkdir -p "$home_dir/.claude"
cat > "$home_dir/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(node:*)"]
  }
}
EOF
if out=$(HOME="$home_dir" CLAUDE_PROJECT_DIR="$project_dir" bash "$VALIDATE_HOOK" 2>&1); then
  fail "T6: HOME settings.local permissions should be blocked"
else
  if [[ "$out" == *"[CRITICAL]"* && "$out" == *"settings.local.json"* ]]; then
    pass "T6: HOME settings.local permissions blocked"
  else
    fail "T6: expected CRITICAL message for HOME settings.local"
  fi
fi

# T7: Validate hook blocks project settings.local.json permissions
home_dir=$(make_tmpdir)
project_dir=$(make_tmpdir)
mkdir -p "$project_dir/.claude"
cat > "$project_dir/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(node:*)"]
  }
}
EOF
if out=$(HOME="$home_dir" CLAUDE_PROJECT_DIR="$project_dir" bash "$VALIDATE_HOOK" 2>&1); then
  fail "T7: project settings.local permissions should be blocked"
else
  if [[ "$out" == *"File: $project_dir/.claude/settings.local.json"* ]]; then
    pass "T7: project settings.local permissions blocked"
  else
    fail "T7: expected project file path in block message"
  fi
fi

# T8: Validate hook allows settings.local without permissions
home_dir=$(make_tmpdir)
project_dir=$(make_tmpdir)
mkdir -p "$project_dir/.claude"
cat > "$project_dir/.claude/settings.local.json" <<'EOF'
{
  "enabledMcpjsonServers": ["brave-search"]
}
EOF
if out=$(HOME="$home_dir" CLAUDE_PROJECT_DIR="$project_dir" bash "$VALIDATE_HOOK" 2>&1); then
  if [[ -z "$out" ]]; then
    pass "T8: settings.local without permissions allowed"
  else
    fail "T8: expected no output for safe settings.local"
  fi
else
  fail "T8: safe settings.local should not be blocked"
fi

# T9: Auto-init hook is a safe no-op
project_dir=$(make_tmpdir)
if out=$(cd "$project_dir" && bash "$AUTO_INIT_HOOK" 2>&1); then
  if [[ ! -e "$project_dir/.claude/settings.local.json" ]]; then
    pass "T9: auto-init does not create settings.local permissions"
  else
    fail "T9: auto-init should not create settings.local.json"
  fi
else
  fail "T9: auto-init hook should exit successfully"
fi

# T10-T11: settings.json registration checks
if grep -q 'validate-no-local-permissions.sh' "$SETTINGS"; then
  pass "T10: validate-no-local-permissions registered"
else
  fail "T10: validate-no-local-permissions not registered"
fi

if grep -q 'block-local-permissions-write.sh' "$SETTINGS"; then
  pass "T11: block-local-permissions-write registered"
else
  fail "T11: block-local-permissions-write not registered"
fi

# T12: sanitize script removes permissions but keeps other keys
local_file=$(make_tmpdir)/settings.local.json
cat > "$local_file" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(gh:*)"]
  },
  "enabledMcpjsonServers": ["brave-search"]
}
EOF
if out=$(bash "$SANITIZE_SCRIPT" "$local_file" 2>&1); then
  if [[ "$out" == *"Sanitized local permissions override"* ]] && \
     [[ "$(jq 'has("permissions")' "$local_file")" == "false" ]] && \
     [[ "$(jq -r '.enabledMcpjsonServers[0]' "$local_file")" == "brave-search" ]]; then
    pass "T12: sanitize script strips permissions and preserves safe keys"
  else
    fail "T12: sanitize script did not preserve expected data"
  fi
else
  fail "T12: sanitize script should succeed"
fi

# T13: setup.sh invokes sanitize script
if grep -q 'sanitize-local-permissions.sh' "$SETUP_FILE"; then
  pass "T13: setup.sh sanitizes local settings overrides"
else
  fail "T13: setup.sh does not sanitize local settings overrides"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
