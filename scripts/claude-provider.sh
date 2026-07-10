#!/usr/bin/env bash
# claude-provider.sh — Switch Claude Code API provider profiles (anthropic | zai)
#
# Claude Code uses one ANTHROPIC_BASE_URL / auth path per process. This script
# rewrites ~/.claude/settings.local.json env and keeps z.ai secrets out of the
# repo-managed settings.json.
#
# Usage:
#   claude-provider status
#   claude-provider anthropic   # official subscription / OAuth (default)
#   claude-provider zai         # z.ai GLM gateway
#   claude-provider doctor      # conflicts + optional z.ai health probe
#   claude-provider migrate-secrets  # copy token from settings → secrets file
#
# Env overrides (tests):
#   CLAUDE_PROVIDER_HOME  — treat as $HOME (default: real $HOME)
set -euo pipefail

HOME_DIR="${CLAUDE_PROVIDER_HOME:-$HOME}"
CLAUDE_DIR="${HOME_DIR}/.claude"
LOCAL_SETTINGS="${CLAUDE_DIR}/settings.local.json"
GLOBAL_SETTINGS="${CLAUDE_DIR}/settings.json"
PROVIDERS_DIR="${CLAUDE_DIR}/providers"
SECRETS_FILE="${PROVIDERS_DIR}/zai.secrets.json"
ACTIVE_FILE="${PROVIDERS_DIR}/active-profile"

ZAI_BASE_URL="https://api.z.ai/api/anthropic"
DEFAULT_ZAI_HAIKU="glm-4.5-air"
DEFAULT_ZAI_SONNET="glm-5.2[1m]"
DEFAULT_ZAI_OPUS="glm-5.2[1m]"
DEFAULT_ANTHROPIC_HAIKU="claude-haiku-4-5-20251001"

# Keys that force a non-subscription routing path
ROUTING_KEYS=(
  ANTHROPIC_BASE_URL
  ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_API_KEY
  ANTHROPIC_DEFAULT_SONNET_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL
  ANTHROPIC_DEFAULT_HAIKU_MODEL
  ANTHROPIC_SMALL_FAST_MODEL
  CLAUDE_CODE_USE_VERTEX
  ANTHROPIC_VERTEX_PROJECT_ID
  CLOUD_ML_REGION
  VERTEX_REGION_CLAUDE_3_5_HAIKU
  VERTEX_REGION_CLAUDE_3_5_SONNET
  VERTEX_REGION_CLAUDE_3_7_SONNET
  VERTEX_REGION_CLAUDE_4_0_OPUS
  VERTEX_REGION_CLAUDE_4_0_SONNET
  VERTEX_REGION_CLAUDE_4_1_OPUS
  VERTEX_REGION_CLAUDE_4_5_SONNET
)

# Vertex-only keys (cleared for both anthropic and zai profiles)
VERTEX_KEYS=(
  CLAUDE_CODE_USE_VERTEX
  ANTHROPIC_VERTEX_PROJECT_ID
  CLOUD_ML_REGION
  VERTEX_REGION_CLAUDE_3_5_HAIKU
  VERTEX_REGION_CLAUDE_3_5_SONNET
  VERTEX_REGION_CLAUDE_3_7_SONNET
  VERTEX_REGION_CLAUDE_4_0_OPUS
  VERTEX_REGION_CLAUDE_4_0_SONNET
  VERTEX_REGION_CLAUDE_4_1_OPUS
  VERTEX_REGION_CLAUDE_4_5_SONNET
)

usage() {
  cat <<'EOF'
Usage: claude-provider <command>

Commands:
  status             Show active profile and routing env (secrets redacted)
  anthropic          Switch to official Claude subscription / OAuth (default)
  zai                Switch to z.ai GLM gateway
  doctor             Detect conflicts; probe z.ai when active
  migrate-secrets    Copy z.ai token from settings into providers/zai.secrets.json

After switching, restart Claude Code so the new env is picked up.
EOF
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required" >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$PROVIDERS_DIR"
  chmod 700 "$PROVIDERS_DIR" 2>/dev/null || true
}

read_json_or_empty() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo '{}'
  fi
}

# Merge global + local env (local wins). Prints JSON object.
merged_env_json() {
  require_jq
  local g l
  g=$(read_json_or_empty "$GLOBAL_SETTINGS")
  l=$(read_json_or_empty "$LOCAL_SETTINGS")
  jq -n --argjson g "$g" --argjson l "$l" \
    '(($g.env // {}) + ($l.env // {}))'
}

get_env_val() {
  local key="$1"
  merged_env_json | jq -r --arg k "$key" '.[$k] // empty'
}

active_profile_file() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    tr -d '[:space:]' <"$ACTIVE_FILE"
  else
    echo ""
  fi
}

# Infer profile from merged env when marker missing
infer_profile() {
  local base token use_vertex
  base=$(get_env_val ANTHROPIC_BASE_URL)
  token=$(get_env_val ANTHROPIC_AUTH_TOKEN)
  use_vertex=$(get_env_val CLAUDE_CODE_USE_VERTEX)

  if [[ -n "$base" && "$base" == *z.ai* ]]; then
    echo "zai"
  elif [[ "$use_vertex" == "1" || "$use_vertex" == "true" ]]; then
    echo "vertex"
  elif [[ -n "$base" || -n "$token" ]]; then
    echo "custom"
  else
    echo "anthropic"
  fi
}

effective_profile() {
  local marked inferred
  marked=$(active_profile_file)
  inferred=$(infer_profile)
  if [[ -z "$marked" ]]; then
    echo "$inferred"
    return 0
  fi
  # Prefer real routing when marker is stale (e.g. marker=zai but env is clean anthropic)
  if [[ "$marked" != "$inferred" && "$inferred" != "custom" ]]; then
    echo "$inferred"
    return 0
  fi
  echo "$marked"
}

redact() {
  local v="$1"
  if [[ -z "$v" ]]; then
    echo "(unset)"
  elif [[ ${#v} -le 8 ]]; then
    echo "***"
  else
    echo "${v:0:4}***${#v}chars"
  fi
}

has_conflict() {
  local base use_vertex
  base=$(get_env_val ANTHROPIC_BASE_URL)
  use_vertex=$(get_env_val CLAUDE_CODE_USE_VERTEX)
  if [[ -n "$base" && ( "$use_vertex" == "1" || "$use_vertex" == "true" ) ]]; then
    return 0
  fi
  return 1
}

cmd_status() {
  require_jq
  local profile inferred base token haiku sonnet opus use_vertex
  profile=$(effective_profile)
  inferred=$(infer_profile)
  base=$(get_env_val ANTHROPIC_BASE_URL)
  token=$(get_env_val ANTHROPIC_AUTH_TOKEN)
  haiku=$(get_env_val ANTHROPIC_DEFAULT_HAIKU_MODEL)
  sonnet=$(get_env_val ANTHROPIC_DEFAULT_SONNET_MODEL)
  opus=$(get_env_val ANTHROPIC_DEFAULT_OPUS_MODEL)
  use_vertex=$(get_env_val CLAUDE_CODE_USE_VERTEX)

  echo "=== Claude provider status ==="
  echo "profile (marker):  $(active_profile_file | sed 's/^$/(none)/')"
  echo "profile (inferred): $inferred"
  echo "profile (effective): $profile"
  echo "ANTHROPIC_BASE_URL: ${base:-'(unset)'}"
  echo "ANTHROPIC_AUTH_TOKEN: $(redact "$token")"
  echo "ANTHROPIC_DEFAULT_HAIKU_MODEL: ${haiku:-'(unset)'}"
  echo "ANTHROPIC_DEFAULT_SONNET_MODEL: ${sonnet:-'(unset)'}"
  echo "ANTHROPIC_DEFAULT_OPUS_MODEL: ${opus:-'(unset)'}"
  echo "CLAUDE_CODE_USE_VERTEX: ${use_vertex:-'(unset)'}"
  echo "secrets file: $SECRETS_FILE ($([ -f "$SECRETS_FILE" ] && echo present || echo missing))"
  echo "local settings: $LOCAL_SETTINGS ($([ -f "$LOCAL_SETTINGS" ] && echo present || echo missing))"

  if has_conflict; then
    echo ""
    echo "CRITICAL: ANTHROPIC_BASE_URL and CLAUDE_CODE_USE_VERTEX are both set."
    echo "  Run: claude-provider anthropic   # or: claude-provider zai"
  fi

  # Shell env may override settings after load-env.sh
  if [[ -n "${ANTHROPIC_BASE_URL:-}" && "${ANTHROPIC_BASE_URL}" != "${base}" ]]; then
    echo ""
    echo "WARNING: shell ANTHROPIC_BASE_URL differs from settings (${ANTHROPIC_BASE_URL})."
    echo "  Open a new shell or unset it; settings alone will not win until restart."
  fi
}

backup_local() {
  if [[ -f "$LOCAL_SETTINGS" ]]; then
    local bak="${LOCAL_SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$LOCAL_SETTINGS" "$bak"
    echo "  backup: $bak"
  fi
}

# Write local settings: merge env updates, delete routing keys, never write permissions/hooks
# Args via env vars set by caller through python for reliability
apply_local_env() {
  require_jq
  ensure_dirs
  mkdir -p "$CLAUDE_DIR"

  local mode="$1" # anthropic | zai
  local token="${2:-}"
  local haiku="${3:-}"
  local sonnet="${4:-}"
  local opus="${5:-}"

  backup_local

  # Token via env (not argv) to avoid process-list leakage
  CLAUDE_PROVIDER_TOKEN="$token" python3 - "$LOCAL_SETTINGS" "$mode" "$haiku" "$sonnet" "$opus" "$ZAI_BASE_URL" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
mode = sys.argv[2]
token = os.environ.get("CLAUDE_PROVIDER_TOKEN", "")
haiku = sys.argv[3]
sonnet = sys.argv[4]
opus = sys.argv[5]
zai_base = sys.argv[6]

routing_keys = {
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "CLAUDE_CODE_USE_VERTEX",
    "ANTHROPIC_VERTEX_PROJECT_ID",
    "CLOUD_ML_REGION",
    "VERTEX_REGION_CLAUDE_3_5_HAIKU",
    "VERTEX_REGION_CLAUDE_3_5_SONNET",
    "VERTEX_REGION_CLAUDE_3_7_SONNET",
    "VERTEX_REGION_CLAUDE_4_0_OPUS",
    "VERTEX_REGION_CLAUDE_4_0_SONNET",
    "VERTEX_REGION_CLAUDE_4_1_OPUS",
    "VERTEX_REGION_CLAUDE_4_5_SONNET",
}

data = {}
if path.is_file():
    with path.open(encoding="utf-8") as f:
        data = json.load(f)

# Never keep permissions/hooks in local (guards rely on this)
data.pop("permissions", None)
data.pop("hooks", None)

env = dict(data.get("env") or {})
for k in list(env.keys()):
    if k in routing_keys:
        del env[k]

if mode == "anthropic":
    # Optional haiku pin matching repo settings.json; leave sonnet/opus to product defaults
    if haiku:
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku
elif mode == "zai":
    env["ANTHROPIC_BASE_URL"] = zai_base
    if token:
        env["ANTHROPIC_AUTH_TOKEN"] = token
    env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku
    env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet
    env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opus
else:
    raise SystemExit(f"unknown mode: {mode}")

# Disable broken brave-search enable list entry if present
enabled = data.get("enabledMcpjsonServers")
if isinstance(enabled, list):
    data["enabledMcpjsonServers"] = [x for x in enabled if x != "brave-search"]
    if not data["enabledMcpjsonServers"]:
        data.pop("enabledMcpjsonServers", None)

data["env"] = env

tmp = path.with_suffix(path.suffix + ".tmp")
with tmp.open("w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
tmp.replace(path)
path.chmod(0o600)
print(f"  wrote {path}")
PY

  echo "$mode" >"$ACTIVE_FILE"
  chmod 600 "$ACTIVE_FILE" 2>/dev/null || true
}

# Strip routing keys from global settings.json env (keep hooks/permissions intact)
sanitize_global_settings_env() {
  [[ -f "$GLOBAL_SETTINGS" ]] || return 0
  require_jq

  local needs
  needs=$(jq -r '
    .env // {}
    | [
        (has("ANTHROPIC_BASE_URL") and .ANTHROPIC_BASE_URL != null and .ANTHROPIC_BASE_URL != ""),
        (has("ANTHROPIC_AUTH_TOKEN") and .ANTHROPIC_AUTH_TOKEN != null and .ANTHROPIC_AUTH_TOKEN != ""),
        (has("ANTHROPIC_API_KEY") and .ANTHROPIC_API_KEY != null and .ANTHROPIC_API_KEY != ""),
        ((.ANTHROPIC_DEFAULT_SONNET_MODEL // "") | test("glm"; "i")),
        ((.ANTHROPIC_DEFAULT_OPUS_MODEL // "") | test("glm"; "i")),
        ((.ANTHROPIC_DEFAULT_HAIKU_MODEL // "") | test("glm"; "i")),
        ((.CLAUDE_CODE_USE_VERTEX // "") == "1" or (.CLAUDE_CODE_USE_VERTEX // "") == "true"),
        (has("ANTHROPIC_VERTEX_PROJECT_ID") and .ANTHROPIC_VERTEX_PROJECT_ID != null and .ANTHROPIC_VERTEX_PROJECT_ID != "")
      ] | any
  ' "$GLOBAL_SETTINGS" 2>/dev/null || echo "false")

  if [[ "$needs" != "true" ]]; then
    return 0
  fi

  local bak="${GLOBAL_SETTINGS}.bak.provider.$(date +%Y%m%d%H%M%S)"
  cp "$GLOBAL_SETTINGS" "$bak"
  echo "  global settings backup: $bak"

  local tmp
  tmp=$(mktemp)
  jq '
    .env //= {}
    | .env |= del(
        .ANTHROPIC_BASE_URL,
        .ANTHROPIC_AUTH_TOKEN,
        .ANTHROPIC_API_KEY,
        .ANTHROPIC_DEFAULT_SONNET_MODEL,
        .ANTHROPIC_DEFAULT_OPUS_MODEL,
        .ANTHROPIC_SMALL_FAST_MODEL,
        .CLAUDE_CODE_USE_VERTEX,
        .ANTHROPIC_VERTEX_PROJECT_ID,
        .CLOUD_ML_REGION,
        .VERTEX_REGION_CLAUDE_3_5_HAIKU,
        .VERTEX_REGION_CLAUDE_3_5_SONNET,
        .VERTEX_REGION_CLAUDE_3_7_SONNET,
        .VERTEX_REGION_CLAUDE_4_0_OPUS,
        .VERTEX_REGION_CLAUDE_4_0_SONNET,
        .VERTEX_REGION_CLAUDE_4_1_OPUS,
        .VERTEX_REGION_CLAUDE_4_5_SONNET
      )
    | if (.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "" | test("glm"; "i"))
      then .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5-20251001"
      else .
      end
  ' "$GLOBAL_SETTINGS" >"$tmp"
  mv "$tmp" "$GLOBAL_SETTINGS"
  chmod 600 "$GLOBAL_SETTINGS" 2>/dev/null || true
  echo "  stripped gateway/GLM routing keys from $GLOBAL_SETTINGS"
}

migrate_secrets_from_settings() {
  ensure_dirs
  require_jq

  # Never clobber a non-empty rotated token already in the secrets file
  if [[ -f "$SECRETS_FILE" ]]; then
    local existing
    existing=$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$SECRETS_FILE" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
      echo "  secrets already present; nothing to migrate"
      return 0
    fi
  fi

  local token=""
  # Prefer local, then global
  if [[ -f "$LOCAL_SETTINGS" ]]; then
    token=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$LOCAL_SETTINGS")
  fi
  if [[ -z "$token" && -f "$GLOBAL_SETTINGS" ]]; then
    token=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$GLOBAL_SETTINGS")
  fi
  if [[ -z "$token" ]]; then
    echo "  no ANTHROPIC_AUTH_TOKEN found in settings to migrate" >&2
    return 1
  fi

  local haiku sonnet opus
  haiku=$(get_env_val ANTHROPIC_DEFAULT_HAIKU_MODEL)
  sonnet=$(get_env_val ANTHROPIC_DEFAULT_SONNET_MODEL)
  opus=$(get_env_val ANTHROPIC_DEFAULT_OPUS_MODEL)
  [[ -z "$haiku" || "$haiku" != glm* ]] && haiku="$DEFAULT_ZAI_HAIKU"
  [[ -z "$sonnet" || "$sonnet" != glm* ]] && sonnet="$DEFAULT_ZAI_SONNET"
  [[ -z "$opus" || "$opus" != glm* ]] && opus="$DEFAULT_ZAI_OPUS"
  # if they were glm, keep them
  local cur_h cur_s cur_o
  cur_h=$(get_env_val ANTHROPIC_DEFAULT_HAIKU_MODEL)
  cur_s=$(get_env_val ANTHROPIC_DEFAULT_SONNET_MODEL)
  cur_o=$(get_env_val ANTHROPIC_DEFAULT_OPUS_MODEL)
  [[ "$cur_h" == glm* ]] && haiku="$cur_h"
  [[ "$cur_s" == glm* || "$cur_s" == *"["* ]] && sonnet="$cur_s"
  [[ "$cur_o" == glm* || "$cur_o" == *"["* ]] && opus="$cur_o"

  jq -n \
    --arg token "$token" \
    --arg base "$ZAI_BASE_URL" \
    --arg haiku "$haiku" \
    --arg sonnet "$sonnet" \
    --arg opus "$opus" \
    '{
      ANTHROPIC_AUTH_TOKEN: $token,
      ANTHROPIC_BASE_URL: $base,
      ANTHROPIC_DEFAULT_HAIKU_MODEL: $haiku,
      ANTHROPIC_DEFAULT_SONNET_MODEL: $sonnet,
      ANTHROPIC_DEFAULT_OPUS_MODEL: $opus
    }' >"$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  echo "  wrote secrets (token redacted) → $SECRETS_FILE"
}

cmd_migrate_secrets() {
  echo "=== Migrating z.ai secrets ==="
  migrate_secrets_from_settings
}

cmd_anthropic() {
  echo "=== Switching provider → anthropic (official subscription / OAuth) ==="
  ensure_dirs
  # Preserve z.ai token if still only in settings
  migrate_secrets_from_settings 2>/dev/null || true
  sanitize_global_settings_env
  apply_local_env anthropic "" "$DEFAULT_ANTHROPIC_HAIKU" "" ""
  echo ""
  echo "Done. Effective profile: anthropic"
  echo "Restart Claude Code (new session) so env takes effect."
  echo "To use z.ai later: bash $0 zai"
}

cmd_zai() {
  echo "=== Switching provider → zai ==="
  ensure_dirs
  require_jq

  if [[ ! -f "$SECRETS_FILE" ]] || [[ -z "$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$SECRETS_FILE" 2>/dev/null || true)" ]]; then
    echo "  secrets missing or empty; attempting migrate from settings..."
    if ! migrate_secrets_from_settings; then
      echo "error: no z.ai secrets. Create $SECRETS_FILE with ANTHROPIC_AUTH_TOKEN," >&2
      echo "  or put the token in settings.local.json env and re-run migrate-secrets." >&2
      exit 1
    fi
  fi

  local token haiku sonnet opus
  token=$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$SECRETS_FILE")
  haiku=$(jq -r --arg d "$DEFAULT_ZAI_HAIKU" '.ANTHROPIC_DEFAULT_HAIKU_MODEL // $d' "$SECRETS_FILE")
  sonnet=$(jq -r --arg d "$DEFAULT_ZAI_SONNET" '.ANTHROPIC_DEFAULT_SONNET_MODEL // $d' "$SECRETS_FILE")
  opus=$(jq -r --arg d "$DEFAULT_ZAI_OPUS" '.ANTHROPIC_DEFAULT_OPUS_MODEL // $d' "$SECRETS_FILE")

  if [[ -z "$token" ]]; then
    echo "error: ANTHROPIC_AUTH_TOKEN empty in $SECRETS_FILE" >&2
    exit 1
  fi

  sanitize_global_settings_env
  apply_local_env zai "$token" "$haiku" "$sonnet" "$opus"
  echo ""
  echo "Done. Effective profile: zai"
  echo "NOTE: When z.ai is unstable, subagents/WebSearch/Bash classifiers may fail."
  echo "  Fall back with: bash $0 anthropic"
  echo "Restart Claude Code (new session) so env takes effect."
}

cmd_doctor() {
  require_jq
  local profile base issues=0
  profile=$(effective_profile)
  base=$(get_env_val ANTHROPIC_BASE_URL)

  echo "=== Claude provider doctor ==="
  cmd_status
  echo ""

  if has_conflict; then
    echo "FAIL: gateway + Vertex both configured"
    issues=$((issues + 1))
  else
    echo "OK: no gateway/Vertex conflict"
  fi

  # Orphan GLM pins without base URL
  local sonnet opus haiku
  sonnet=$(get_env_val ANTHROPIC_DEFAULT_SONNET_MODEL)
  opus=$(get_env_val ANTHROPIC_DEFAULT_OPUS_MODEL)
  haiku=$(get_env_val ANTHROPIC_DEFAULT_HAIKU_MODEL)
  if [[ -z "$base" ]]; then
    if [[ "$sonnet" == glm* || "$opus" == glm* || "$haiku" == glm* ]]; then
      echo "FAIL: GLM model pins present without ANTHROPIC_BASE_URL (orphan routing)"
      issues=$((issues + 1))
    else
      echo "OK: no orphan GLM pins"
    fi
  fi

  if [[ "$profile" == "zai" || ( -n "$base" && "$base" == *z.ai* ) ]]; then
    echo "Probing z.ai (${ZAI_BASE_URL})..."
    if command -v curl >/dev/null 2>&1; then
      local code
      code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 \
        "${ZAI_BASE_URL}/v1/models" \
        -H "Authorization: Bearer $(get_env_val ANTHROPIC_AUTH_TOKEN)" 2>/dev/null || echo "000")
      if [[ "$code" == "000" ]]; then
        echo "WARN: z.ai unreachable (network/timeout). Consider: claude-provider anthropic"
        issues=$((issues + 1))
      elif [[ "$code" == "401" || "$code" == "403" ]]; then
        echo "WARN: z.ai returned HTTP $code (auth). Check token in providers/zai.secrets.json"
        issues=$((issues + 1))
      elif [[ "$code" =~ ^5 ]]; then
        echo "WARN: z.ai returned HTTP $code (server error). Consider: claude-provider anthropic"
        issues=$((issues + 1))
      else
        echo "OK: z.ai responded HTTP $code"
      fi
    else
      echo "SKIP: curl not available for health probe"
    fi
  else
    echo "OK: not on z.ai; skip gateway probe"
  fi

  # brave enable leftover
  if [[ -f "$LOCAL_SETTINGS" ]] && jq -e '.enabledMcpjsonServers | index("brave-search")' "$LOCAL_SETTINGS" >/dev/null 2>&1; then
    echo "WARN: brave-search still in enabledMcpjsonServers (token often invalid)"
    issues=$((issues + 1))
  else
    echo "OK: brave-search not enabled in local settings"
  fi

  echo ""
  if [[ "$issues" -gt 0 ]]; then
    echo "doctor: $issues issue(s) found"
    return 1
  fi
  echo "doctor: clean"
  return 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    status) cmd_status ;;
    anthropic) cmd_anthropic ;;
    zai) cmd_zai ;;
    doctor) cmd_doctor ;;
    migrate-secrets) cmd_migrate_secrets ;;
    -h|--help|help|"") usage; [[ -n "$cmd" ]] || exit 1 ;;
    *) echo "unknown command: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
