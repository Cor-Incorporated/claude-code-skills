#!/bin/bash
# auto-init-permissions.sh — safe no-op
# ============================================================================
# permissions は repo-owned settings.json の source of truth に限定する。
# settings.local.json へ permissions を書くとグローバル allowlist を上書きし、
# Bash(gh:*), Bash(git:*) などが ask/block へ退行するため、ここでは何もしない。
# ============================================================================

set -euo pipefail

echo "[permissions] settings.local.json permissions are disabled; use repo-owned settings.json instead." >&2
exit 0
