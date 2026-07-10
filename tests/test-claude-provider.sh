#!/usr/bin/env bash
# test-claude-provider.sh — provider profile switcher unit tests
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/claude-provider.sh"
HOOK="$ROOT/hooks/validate-provider-env.sh"

echo "=== Claude provider tests ==="

tmpdirs=()
cleanup() {
  set +u
  for dir in "${tmpdirs[@]}"; do
    rm -rf "$dir"
  done
  set -u
}
trap cleanup EXIT

make_home() {
  local dir
  dir=$(mktemp -d)
  tmpdirs+=("$dir")
  mkdir -p "$dir/.claude"
  echo "$dir"
}

# T1: syntax
if bash -n "$SCRIPT" 2>/dev/null; then
  pass "syntax: claude-provider.sh"
else
  fail "syntax: claude-provider.sh"
fi
if bash -n "$HOOK" 2>/dev/null; then
  pass "syntax: validate-provider-env.sh"
else
  fail "syntax: validate-provider-env.sh"
fi

# T2: anthropic strips z.ai + vertex + permissions, migrates secrets
home=$(make_home)
cat > "$home/.claude/settings.json" <<'EOF'
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "secret-token-xyz",
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-4.5-air",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.2[1m]",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "hooks": {"SessionStart": []}
}
EOF
cat > "$home/.claude/settings.local.json" <<'EOF'
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "secret-token-xyz",
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-4.5-air",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.2[1m]",
    "CLAUDE_CODE_USE_VERTEX": "1",
    "ANTHROPIC_VERTEX_PROJECT_ID": "proj",
    "API_TIMEOUT_MS": "3000000",
    "USE_BUILTIN_RIPGREP": "1"
  },
  "permissions": {"allow": ["Bash"]},
  "enabledMcpjsonServers": ["brave-search", "other"]
}
EOF

CLAUDE_PROVIDER_HOME="$home" bash "$SCRIPT" anthropic >/dev/null

if [[ -f "$home/.claude/providers/zai.secrets.json" ]]; then
  tok=$(jq -r '.ANTHROPIC_AUTH_TOKEN' "$home/.claude/providers/zai.secrets.json")
  if [[ "$tok" == "secret-token-xyz" ]]; then
    pass "T2: secrets migrated"
  else
    fail "T2: secrets token mismatch"
  fi
else
  fail "T2: secrets file missing"
fi

local_env=$(jq -c '.env' "$home/.claude/settings.local.json")
if echo "$local_env" | jq -e 'has("ANTHROPIC_BASE_URL") | not' >/dev/null \
  && echo "$local_env" | jq -e 'has("ANTHROPIC_AUTH_TOKEN") | not' >/dev/null \
  && echo "$local_env" | jq -e 'has("CLAUDE_CODE_USE_VERTEX") | not' >/dev/null \
  && echo "$local_env" | jq -e '.API_TIMEOUT_MS == "3000000"' >/dev/null \
  && echo "$local_env" | jq -e '.ANTHROPIC_DEFAULT_HAIKU_MODEL == "claude-haiku-4-5-20251001"' >/dev/null; then
  pass "T2: anthropic env cleaned, prefs kept"
else
  fail "T2: anthropic env unexpected: $local_env"
fi

if jq -e 'has("permissions") | not' "$home/.claude/settings.local.json" >/dev/null; then
  pass "T2: permissions stripped from local"
else
  fail "T2: permissions still present"
fi

if jq -e '.enabledMcpjsonServers == ["other"]' "$home/.claude/settings.local.json" >/dev/null; then
  pass "T2: brave-search removed from enabledMcpjsonServers"
else
  fail "T2: enabledMcpjsonServers=$(jq -c '.enabledMcpjsonServers' "$home/.claude/settings.local.json")"
fi

if [[ "$(cat "$home/.claude/providers/active-profile")" == "anthropic" ]]; then
  pass "T2: active-profile=anthropic"
else
  fail "T2: active-profile wrong"
fi

# Global should not keep token/base
g_env=$(jq -c '.env' "$home/.claude/settings.json")
if echo "$g_env" | jq -e 'has("ANTHROPIC_BASE_URL") | not' >/dev/null \
  && echo "$g_env" | jq -e 'has("ANTHROPIC_AUTH_TOKEN") | not' >/dev/null \
  && echo "$g_env" | jq -e 'has("hooks") or true' >/dev/null \
  && jq -e 'has("hooks")' "$home/.claude/settings.json" >/dev/null; then
  pass "T2: global gateway keys stripped, hooks kept"
else
  fail "T2: global settings unexpected: $g_env"
fi

# T3: status does not leak full token
out=$(CLAUDE_PROVIDER_HOME="$home" bash "$SCRIPT" status 2>&1)
if [[ "$out" != *secret-token-xyz* ]] && [[ "$out" == *ANTHROPIC_AUTH_TOKEN* ]]; then
  pass "T3: status redacts token"
else
  fail "T3: status leak or missing: $out"
fi

# T4: switch to zai restores gateway
CLAUDE_PROVIDER_HOME="$home" bash "$SCRIPT" zai >/dev/null
local_env=$(jq -c '.env' "$home/.claude/settings.local.json")
if echo "$local_env" | jq -e '.ANTHROPIC_BASE_URL | test("z\\.ai")' >/dev/null \
  && echo "$local_env" | jq -e '.ANTHROPIC_AUTH_TOKEN == "secret-token-xyz"' >/dev/null \
  && echo "$local_env" | jq -e '.ANTHROPIC_DEFAULT_SONNET_MODEL | test("glm")' >/dev/null \
  && echo "$local_env" | jq -e 'has("CLAUDE_CODE_USE_VERTEX") | not' >/dev/null; then
  pass "T4: zai profile applied without vertex"
else
  fail "T4: zai env unexpected: $local_env"
fi

# T5: doctor detects conflict
home2=$(make_home)
mkdir -p "$home2/.claude"
cat > "$home2/.claude/settings.local.json" <<'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "CLAUDE_CODE_USE_VERTEX": "1",
    "ANTHROPIC_AUTH_TOKEN": "t"
  }
}
EOF
if CLAUDE_PROVIDER_HOME="$home2" bash "$SCRIPT" doctor >/dev/null 2>&1; then
  fail "T5: doctor should fail on conflict"
else
  pass "T5: doctor fails on gateway+vertex conflict"
fi

# T6: hook is non-blocking even with conflict
home3=$(make_home)
mkdir -p "$home3/.claude"
cat > "$home3/.claude/settings.local.json" <<'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "CLAUDE_CODE_USE_VERTEX": "1",
    "ANTHROPIC_AUTH_TOKEN": "t"
  }
}
EOF
set +e
out=$(HOME="$home3" bash "$HOOK" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && [[ "$out" == *CRITICAL* || "$out" == *provider* ]]; then
  pass "T6: validate-provider-env non-blocking warn"
else
  fail "T6: rc=$rc out=$out"
fi

# T7: zai without secrets fails cleanly
home4=$(make_home)
mkdir -p "$home4/.claude"
echo '{}' > "$home4/.claude/settings.local.json"
set +e
out=$(CLAUDE_PROVIDER_HOME="$home4" bash "$SCRIPT" zai 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && [[ "$out" != *secret-token* ]]; then
  pass "T7: zai without secrets fails without leaking"
else
  fail "T7: rc=$rc out=$out"
fi


# T8: migrate must not clobber existing non-empty secrets
home5=$(make_home)
mkdir -p "$home5/.claude/providers"
cat > "$home5/.claude/providers/zai.secrets.json" <<'EOF'
{"ANTHROPIC_AUTH_TOKEN":"good-rotated-token-999","ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}
EOF
cat > "$home5/.claude/settings.local.json" <<'EOF'
{"env":{"ANTHROPIC_AUTH_TOKEN":"stale-token-from-settings","ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}
EOF
CLAUDE_PROVIDER_HOME="$home5" bash "$SCRIPT" migrate-secrets >/dev/null
tok=$(jq -r '.ANTHROPIC_AUTH_TOKEN' "$home5/.claude/providers/zai.secrets.json")
if [[ "$tok" == "good-rotated-token-999" ]]; then
  pass "T8: migrate does not clobber existing secrets"
else
  fail "T8: secrets clobbered to $tok"
fi
CLAUDE_PROVIDER_HOME="$home5" bash "$SCRIPT" anthropic >/dev/null
tok=$(jq -r '.ANTHROPIC_AUTH_TOKEN' "$home5/.claude/providers/zai.secrets.json")
if [[ "$tok" == "good-rotated-token-999" ]]; then
  pass "T8b: anthropic switch keeps rotated secrets"
else
  fail "T8b: anthropic clobbered secrets to $tok"
fi

# T9: zai switch strips vertex from global so no conflict
home6=$(make_home)
mkdir -p "$home6/.claude/providers"
cat > "$home6/.claude/providers/zai.secrets.json" <<'EOF'
{"ANTHROPIC_AUTH_TOKEN":"zai-tok-abc","ANTHROPIC_DEFAULT_HAIKU_MODEL":"glm-4.5-air","ANTHROPIC_DEFAULT_SONNET_MODEL":"glm-5.2[1m]","ANTHROPIC_DEFAULT_OPUS_MODEL":"glm-5.2[1m]"}
EOF
cat > "$home6/.claude/settings.json" <<'EOF'
{"env":{"CLAUDE_CODE_USE_VERTEX":"1","ANTHROPIC_VERTEX_PROJECT_ID":"proj","VERTEX_REGION_CLAUDE_4_5_SONNET":"global"},"hooks":{}}
EOF
echo '{}' > "$home6/.claude/settings.local.json"
CLAUDE_PROVIDER_HOME="$home6" bash "$SCRIPT" zai >/dev/null
if CLAUDE_PROVIDER_HOME="$home6" bash "$SCRIPT" doctor >/dev/null 2>&1; then
  if jq -e '(.env.CLAUDE_CODE_USE_VERTEX // "") == ""' "$home6/.claude/settings.json" >/dev/null \
    && jq -e '.env.ANTHROPIC_BASE_URL | test("z\\.ai")' "$home6/.claude/settings.local.json" >/dev/null; then
    pass "T9: zai switch strips global vertex; doctor clean"
  else
    fail "T9: unexpected env after zai"
  fi
else
  fail "T9: doctor failed after zai with prior global vertex"
fi

# T10: status redacts token when zai active (token in local env)
out=$(CLAUDE_PROVIDER_HOME="$home6" bash "$SCRIPT" status 2>&1)
if [[ "$out" != *zai-tok-abc* ]] && [[ "$out" == *ANTHROPIC_AUTH_TOKEN* ]]; then
  pass "T10: status redacts live zai token"
else
  fail "T10: redaction failed: $out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
