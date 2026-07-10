#!/bin/bash
# =============================================================================
# Docker Build Args Audit Hook (PreToolUse: Bash)
# =============================================================================
# Before `docker build` commands, checks if any --build-arg contains
# an http:// URL that could cause Mixed Content issues when deployed
# to an HTTPS environment.
#
# Exit codes:
#   0 = safe to proceed
#   2 = blocked (http:// URL found in build args)
# =============================================================================

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only check docker build commands
command_first_line=$(echo "$command" | head -1)
if ! echo "$command_first_line" | grep -q 'docker build'; then
    exit 0
fi

# Extract --build-arg values
BUILD_ARGS=$(echo "$command" | grep -oE '\-\-build-arg[= ][^ ]+' || true)

if [ -z "$BUILD_ARGS" ]; then
    exit 0
fi

# Check each build arg for http:// URLs (excluding localhost/127.0.0.1)
VIOLATIONS=""
while IFS= read -r arg; do
    VALUE=$(echo "$arg" | sed 's/--build-arg[= ]*//')

    # Extract http:// domain from the arg value
    HTTP_DOMAIN=$(echo "$VALUE" | grep -oE 'http://[a-zA-Z0-9._-]+' || true)

    if [ -z "$HTTP_DOMAIN" ]; then
        continue
    fi

    # Skip safe domains (localhost, loopback)
    if echo "$HTTP_DOMAIN" | grep -q 'localhost'; then
        continue
    fi
    if echo "$HTTP_DOMAIN" | grep -q '127\.0\.0\.1'; then
        continue
    fi

    # This is a real http:// URL — flag it
    VIOLATIONS="${VIOLATIONS}\n  → ${VALUE}"
done <<< "$BUILD_ARGS"

if [ -n "$VIOLATIONS" ]; then
    echo "" >&2
    echo "========================================" >&2
    echo " Mixed Content Risk Detected" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "Docker ビルド引数に http:// URL が含まれています:" >&2
    echo -e "$VIOLATIONS" >&2
    echo "" >&2
    echo "HTTPS 環境 (Cloud Run) にデプロイする場合、" >&2
    echo "http:// URL はブラウザの Mixed Content ポリシーで" >&2
    echo "ブロックされます。" >&2
    echo "" >&2
    echo "対応:" >&2
    echo "  1. http:// URL を削除して API プロキシモードを使用" >&2
    echo "  2. または https:// URL に変更" >&2
    echo "========================================" >&2
    exit 2
fi

exit 0
