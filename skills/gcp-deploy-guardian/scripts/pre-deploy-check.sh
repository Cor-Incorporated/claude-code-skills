#!/usr/bin/env bash
# pre-deploy-check.sh — GCP デプロイ前の安全チェック
# Usage: bash pre-deploy-check.sh "<docker-build-command>"
# Exit codes: 0=OK, 1=WARNING, 2=BLOCKED (must fix before proceeding)

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

error() { echo -e "${RED}BLOCKED${NC}: $1"; ((ERRORS++)); }
warn()  { echo -e "${YELLOW}WARNING${NC}: $1"; ((WARNINGS++)); }
ok()    { echo -e "${GREEN}OK${NC}: $1"; }

CMD="${1:-}"

echo "=== GCP Deploy Guardian: Pre-Deploy Check ==="
echo ""

# --- 1. Platform check (Apple Silicon → amd64) ---
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  echo "--- Platform Check (Apple Silicon detected) ---"
  if [[ -n "$CMD" ]]; then
    if echo "$CMD" | grep -q "docker build"; then
      if echo "$CMD" | grep -qi "\-\-platform.*linux/amd64"; then
        ok "--platform linux/amd64 specified"
      else
        error "docker build without --platform linux/amd64 on Apple Silicon"
        echo "  GKE/Cloud Run は amd64。arm64 イメージは ImagePullBackOff になる (Issue #47)"
        echo "  Fix: docker build --platform linux/amd64 ..."
      fi
    fi
  else
    warn "Apple Silicon detected. docker build 時は --platform linux/amd64 を必ず指定"
  fi
else
  ok "Architecture: $ARCH (no platform override needed)"
fi
echo ""

# --- 2. Build-arg audit (http:// check) ---
echo "--- Build Argument Audit ---"
if [[ -n "$CMD" ]]; then
  HTTP_ARGS=$(echo "$CMD" | grep -oiE "\-\-build-arg\s+\S*=http://\S*" || true)
  if [[ -n "$HTTP_ARGS" ]]; then
    error "http:// URL found in build-arg:"
    echo "  $HTTP_ARGS"
    echo "  HTTPS 環境にデプロイすると Mixed Content でブラウザがブロック (Issue #40)"
    echo "  Fix: https:// に変更するか、API プロキシ経由にする"
  else
    ok "No http:// URLs in build-args"
  fi
fi

# Check cloudbuild.yaml files in current directory
for f in cloudbuild*.yaml; do
  if [[ -f "$f" ]]; then
    HTTP_LINES=$(grep -n "http://" "$f" 2>/dev/null | grep -v "^#" || true)
    if [[ -n "$HTTP_LINES" ]]; then
      error "http:// URL found in $f:"
      echo "  $HTTP_LINES"
    else
      ok "$f: no http:// URLs"
    fi
  fi
done

# Check Dockerfile ARG defaults
for f in Dockerfile Dockerfile.*; do
  if [[ -f "$f" ]]; then
    HTTP_DEFAULTS=$(grep -n "^ARG.*=.*http://" "$f" 2>/dev/null || true)
    if [[ -n "$HTTP_DEFAULTS" ]]; then
      error "http:// default value in $f ARG:"
      echo "  $HTTP_DEFAULTS"
    else
      ok "$f: no http:// ARG defaults"
    fi
  fi
done
echo ""

# --- 3. VITE_* build-arg check ---
echo "--- Vite Build Argument Check ---"
if [[ -n "$CMD" ]] && echo "$CMD" | grep -q "VITE_"; then
  if echo "$CMD" | grep -qi "VITE_MILAOS_STT_HTTP_URL"; then
    error "VITE_MILAOS_STT_HTTP_URL is present — causes Mixed Content (Issue #40)"
    echo "  Fix: Remove this build-arg entirely. STT uses API proxy (/v1/stt-proxy/*)"
  else
    ok "No forbidden VITE_* build-args"
  fi
else
  ok "No VITE_* in command (or no command provided)"
fi
echo ""

# --- 4. Summary ---
echo "=== Summary ==="
if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}BLOCKED${NC}: $ERRORS error(s) found. Fix before deploying."
  exit 2
elif [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}WARNING${NC}: $WARNINGS warning(s). Review before proceeding."
  exit 1
else
  echo -e "${GREEN}ALL CLEAR${NC}: Pre-deploy checks passed."
  exit 0
fi
