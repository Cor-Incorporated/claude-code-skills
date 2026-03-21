#!/bin/bash
# =============================================================================
# Domain Naming Convention Hook (PostToolUse)
# =============================================================================
# After editing/writing files in domain/ layer, checks for non-DDD naming
# anti-patterns. Domain layer should use ubiquitous language, not technical names.
#
# Anti-patterns detected:
#   - Manager, Handler, Processor, Helper, Utils, Util, Common
#   - Service (without 'Domain' prefix in domain layer)
#   - Impl suffix (domain layer should define interfaces, not implementations)
#   - DAO, DTO in domain layer (these belong in infrastructure/application)
#
# Exit codes:
#   0 = always (non-blocking, warnings to stderr)
# =============================================================================

set -euo pipefail

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')

# Skip if no file path
if [ -z "$file_path" ]; then
    printf '%s' "$input"
    exit 0
fi

# Only check files in domain/ or core/ layers
if ! printf '%s' "$file_path" | grep -qE '/(domain|core)/'; then
    printf '%s' "$input"
    exit 0
fi

# Only check code files
if ! printf '%s' "$file_path" | grep -qE '\.(ts|tsx|js|jsx|py|go)$'; then
    printf '%s' "$input"
    exit 0
fi

# Get content based on tool type
tool=$(printf '%s' "$input" | jq -r '.tool // ""')
content=""

if [ "$tool" = "Edit" ]; then
    content=$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""')
elif [ "$tool" = "Write" ]; then
    content=$(printf '%s' "$input" | jq -r '.tool_input.content // ""')
fi

if [ -z "$content" ]; then
    printf '%s' "$input"
    exit 0
fi

warnings=()

# Check filename for anti-patterns
filename=$(basename -- "$file_path")
filename_upper=$(printf '%s' "$filename" | tr '[:lower:]' '[:upper:]')

for pattern in "MANAGER" "HANDLER" "PROCESSOR" "HELPER" "UTILS" "UTIL" "COMMON" "IMPL" "DAO" "DTO"; do
    if printf '%s' "$filename_upper" | grep -qF "$pattern"; then
        warnings+=("ファイル名 '$filename' に '$pattern' が含まれています。ドメイン層ではユビキタス言語を使用してください。")
    fi
done

# Check content for anti-pattern class/type/interface names
anti_patterns=$(printf '%s' "$content" | grep -noE \
    '(class|interface|type|struct)\s+\w*(Manager|Handler|Processor|Helper|Utils|Util|Common|Impl|DAO|DTO)\b' \
    2>/dev/null || true)

if [ -n "$anti_patterns" ]; then
    while IFS= read -r line; do
        warnings+=("$line")
    done <<< "$anti_patterns"
fi

# Check for 'Service' without 'Domain' prefix in domain layer
service_patterns=$(printf '%s' "$content" | grep -noE \
    '(class|interface|type|struct)\s+\w*Service\b' 2>/dev/null | \
    grep -v 'DomainService' || true)

if [ -n "$service_patterns" ]; then
    while IFS= read -r line; do
        warnings+=("Service → DomainService推奨: $line")
    done <<< "$service_patterns"
fi

# Output warnings
if [ ${#warnings[@]} -gt 0 ]; then
    echo "" >&2
    echo "========================================" >&2
    echo " [DDD] Domain Naming Convention Warning" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "File: $file_path" >&2
    echo "" >&2
    for w in "${warnings[@]}"; do
        echo "  $w" >&2
    done
    echo "" >&2
    echo "ドメイン層の命名ガイド:" >&2
    echo "  Entity, ValueObject, Aggregate, Repository (Port), DomainService, DomainEvent" >&2
    echo "  NG: Manager, Handler, Processor, Helper, Utils, DAO, DTO, Impl" >&2
    echo "" >&2
    echo "/modern-architecture スキルでDDD命名規約を参照できるわよ。" >&2
    echo "========================================" >&2
fi

printf '%s' "$input"
