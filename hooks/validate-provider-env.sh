#!/usr/bin/env bash
# validate-provider-env.sh — SessionStart: warn on conflicting / flaky provider routing
#
# Non-blocking (always exit 0). Prints warnings to stderr when:
# - z.ai gateway is active (subagents/WebSearch/Bash classifier depend on it)
# - ANTHROPIC_BASE_URL + CLAUDE_CODE_USE_VERTEX both set
# - GLM model pins without a gateway base URL
# - z.ai health probe fails (short timeout)
#
# Does NOT rewrite settings. Switch with:
#   bash ~/.claude/scripts/claude-provider.sh anthropic|zai
set -euo pipefail

# Never block session start
trap 'exit 0' EXIT

CLAUDE_DIR="${HOME}/.claude"
GLOBAL_SETTINGS="${CLAUDE_DIR}/settings.json"
LOCAL_SETTINGS="${CLAUDE_DIR}/settings.local.json"
ACTIVE_FILE="${CLAUDE_DIR}/providers/active-profile"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

merged_env() {
  local g l
  g="{}"
  l="{}"
  [[ -f "$GLOBAL_SETTINGS" ]] && g=$(cat "$GLOBAL_SETTINGS")
  [[ -f "$LOCAL_SETTINGS" ]] && l=$(cat "$LOCAL_SETTINGS")
  jq -n --argjson g "$g" --argjson l "$l" '(($g.env // {}) + ($l.env // {}))' 2>/dev/null || echo '{}'
}

ENV_JSON=$(merged_env)
get() {
  jq -r --arg k "$1" '.[$k] // empty' <<<"$ENV_JSON"
}

base=$(get ANTHROPIC_BASE_URL)
token=$(get ANTHROPIC_AUTH_TOKEN)
use_vertex=$(get CLAUDE_CODE_USE_VERTEX)
haiku=$(get ANTHROPIC_DEFAULT_HAIKU_MODEL)
sonnet=$(get ANTHROPIC_DEFAULT_SONNET_MODEL)
opus=$(get ANTHROPIC_DEFAULT_OPUS_MODEL)
profile=""
[[ -f "$ACTIVE_FILE" ]] && profile=$(tr -d '[:space:]' <"$ACTIVE_FILE")

warn() {
  echo "⚠️  [provider] $*" >&2
}

info() {
  echo "ℹ️  [provider] $*" >&2
}

# Conflict: gateway + Vertex
if [[ -n "$base" && ( "$use_vertex" == "1" || "$use_vertex" == "true" ) ]]; then
  warn "CRITICAL: ANTHROPIC_BASE_URL and CLAUDE_CODE_USE_VERTEX are both set."
  warn "  Subagent/model routing is undefined. Fix: bash ~/.claude/scripts/claude-provider.sh anthropic"
fi

# Orphan GLM pins
if [[ -z "$base" ]]; then
  if [[ "$haiku" == glm* || "$sonnet" == glm* || "$opus" == glm* ]]; then
    warn "GLM model pins present without ANTHROPIC_BASE_URL."
    warn "  Fix: bash ~/.claude/scripts/claude-provider.sh anthropic"
  fi
fi

# z.ai active notice + optional probe (require real base URL; ignore stale marker alone)
if [[ -n "$base" && "$base" == *z.ai* ]]; then
  info "Active provider routes through z.ai ($base)."
  info "  If Explore/Plan/WebSearch/Bash classifier fail, switch: bash ~/.claude/scripts/claude-provider.sh anthropic"

  if command -v curl >/dev/null 2>&1; then
    # Prefer unauthenticated reachability probe to avoid putting token on argv
    code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 5 \
      "${base%/}/v1/models" 2>/dev/null || echo "000")
    # 401/403 still means host is up; only fail hard on network/5xx
    if [[ "$code" == "401" || "$code" == "403" ]]; then
      code="200"
    fi
    if [[ "$code" == "000" || "$code" =~ ^5 || "$code" == "401" || "$code" == "403" ]]; then
      warn "z.ai health probe returned HTTP ${code}. Gateway may be unstable."
      warn "  Recommended: bash ~/.claude/scripts/claude-provider.sh anthropic && restart Claude Code"
    fi
  fi
fi

exit 0
