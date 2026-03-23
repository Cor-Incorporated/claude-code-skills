#!/bin/bash
# =============================================================================
# Version Downgrade Prevention Hook (PreToolUse: Edit)
# =============================================================================
# Blocks ANY version downgrade across all files. When a version string is
# being changed, compares old vs new and blocks if the new version is lower.
# Also requires ADR verification for any version change (up or down).
#
# Scope: ALL files (not limited to K8s/Docker)
# Covers: semver (v1.2.3), Python packages, Go modules, npm, image tags, etc.
#
# Root cause: vLLM image was pinned from :latest to :v0.6.6 (a downgrade
#             from the effective latest) without checking ADR-0011's model
#             compatibility requirements. Qwen3.5 was unsupported in v0.6.6.
#
# Exit codes:
#   0 = allow (no version change detected, or upgrade confirmed)
#   2 = block (downgrade detected, or ADR check required)
# =============================================================================

set -uo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool // ""')

# Only applies to Edit tool (version changes happen via Edit)
if [ "$tool" != "Edit" ]; then
    printf '%s' "$input"
    exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
old_string=$(printf '%s' "$input" | jq -r '.tool_input.old_string // ""')
new_string=$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""')

# Skip .claude/ internal files
if printf '%s' "$file_path" | grep -qE '\.claude/'; then
    printf '%s' "$input"
    exit 0
fi

# Extract version-like strings (semver, image tags, package versions)
# Patterns: v1.2.3, 1.2.3, >=1.2.3, ~=1.2.3, ^1.2.3
extract_versions() {
    printf '%s' "$1" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -5
}

OLD_VERSIONS=$(extract_versions "$old_string")
NEW_VERSIONS=$(extract_versions "$new_string")

# No version strings in either → not a version change, allow
if [ -z "$OLD_VERSIONS" ] && [ -z "$NEW_VERSIONS" ]; then
    printf '%s' "$input"
    exit 0
fi

# Version appears in old but removed/changed in new → check for downgrade
compare_semver() {
    local old_major old_minor old_patch new_major new_minor new_patch
    IFS='.' read -r old_major old_minor old_patch <<< "$(printf '%s' "$1" | sed 's/^v//')"
    IFS='.' read -r new_major new_minor new_patch <<< "$(printf '%s' "$2" | sed 's/^v//')"

    old_major=${old_major:-0}; old_minor=${old_minor:-0}; old_patch=${old_patch:-0}
    new_major=${new_major:-0}; new_minor=${new_minor:-0}; new_patch=${new_patch:-0}

    if [ "$new_major" -lt "$old_major" ] 2>/dev/null; then
        echo "DOWNGRADE"
        return
    elif [ "$new_major" -eq "$old_major" ] 2>/dev/null; then
        if [ "$new_minor" -lt "$old_minor" ] 2>/dev/null; then
            echo "DOWNGRADE"
            return
        elif [ "$new_minor" -eq "$old_minor" ] 2>/dev/null; then
            if [ "$new_patch" -lt "$old_patch" ] 2>/dev/null; then
                echo "DOWNGRADE"
                return
            fi
        fi
    fi
    echo "OK"
}

# Check each old version against corresponding new version
DOWNGRADE_FOUND=""
OLD_VER_ARRAY=($OLD_VERSIONS)
NEW_VER_ARRAY=($NEW_VERSIONS)

for i in "${!OLD_VER_ARRAY[@]}"; do
    old_v="${OLD_VER_ARRAY[$i]}"
    # Find if this version was replaced (same position or context match)
    for new_v in "${NEW_VER_ARRAY[@]}"; do
        result=$(compare_semver "$old_v" "$new_v")
        if [ "$result" = "DOWNGRADE" ]; then
            DOWNGRADE_FOUND="$old_v → $new_v"
            break 2
        fi
    done
done

# Also detect :latest → :vX.Y.Z pin (implicit downgrade risk)
LATEST_PIN=""
if printf '%s' "$old_string" | grep -qE ':latest' && printf '%s' "$new_string" | grep -qE ':v?[0-9]+\.[0-9]+'; then
    LATEST_PIN="true"
fi

if [ -n "$DOWNGRADE_FOUND" ]; then
    cat >&2 <<BLOCK_MSG
[BLOCKED] block-version-downgrade: Version DOWNGRADE detected.

File: $file_path
Downgrade: $DOWNGRADE_FOUND

Version downgrades are prohibited. If this is intentional:
1. Cite the specific ADR or security advisory requiring this downgrade
2. Confirm the downgraded version supports ALL features required by related ADRs
3. Get explicit user approval before proceeding

解決方法: ADR-0011/0014/0006 を確認し、互換性を検証してからユーザー承認を得てください。
BLOCK_MSG
    exit 2
fi

if [ -n "$LATEST_PIN" ]; then
    cat >&2 <<BLOCK_MSG
[BLOCKED] block-version-downgrade: :latest → specific version pin detected.

File: $file_path

Before pinning from :latest, verify:
1. The pinned version supports ALL features required by related ADRs
2. Check the software's supported models/features changelog
3. State which ADR you verified and confirm compatibility

解決方法: 関連ADRの互換性要件を確認し、pinned versionが全要件を満たすことを検証してください。
BLOCK_MSG
    exit 2
fi

# Version change detected but not a downgrade → allow with reminder
if [ -n "$OLD_VERSIONS" ] && [ -n "$NEW_VERSIONS" ]; then
    printf '%s' "$input"
    exit 0
fi

printf '%s' "$input"
exit 0
