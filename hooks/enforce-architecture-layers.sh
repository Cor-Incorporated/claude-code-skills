#!/bin/bash
# =============================================================================
# Architecture Layer Enforcement Hook (PreToolUse)
# =============================================================================
# Blocks imports from infrastructure/adapter layers in domain/core files.
# Enforces the Dependency Rule: domain → ports/interfaces ← infrastructure
#
# Exit codes:
#   0 = allow (outputs JSON unchanged)
#   2 = block (domain→infra import detected)
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

# Get content to check based on tool type
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

# Check for forbidden imports from infrastructure/adapter layers
# TS/JS: import ... from '...infrastructure/...'
# Python: from infrastructure. / from adapters.
# ORM direct: import from 'prisma' / 'typeorm' / etc.

ts_violations=$(printf '%s' "$content" | grep -nE \
    "^\s*(import|export)\s+.*from\s+['\"].*(/infrastructure/|/infra/|/adapters?/|/external/|/drivers/)" \
    2>/dev/null || true)

python_violations=$(printf '%s' "$content" | grep -nE \
    '^\s*from\s+(infrastructure|adapters?|external|drivers)\.' \
    2>/dev/null || true)

orm_violations=$(printf '%s' "$content" | grep -nE \
    "^\s*(import|from)\s+['\"]?(prisma|typeorm|mongoose|knex|sqlalchemy|gorm)['\"/]" \
    2>/dev/null || true)

violations=""
[ -n "$ts_violations" ] && violations="$ts_violations"
[ -n "$python_violations" ] && violations="${violations}${violations:+$'\n'}${python_violations}"
[ -n "$orm_violations" ] && violations="${violations}${violations:+$'\n'}${orm_violations}"

if [ -n "$violations" ]; then
    echo "" >&2
    echo "========================================" >&2
    echo " [BLOCKED] Architecture Layer Violation" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "File: $file_path" >&2
    echo "Layer: domain/core (inner layer)" >&2
    echo "" >&2
    echo "Forbidden imports detected:" >&2
    printf '%s\n' "$violations" | head -5 | while IFS= read -r line; do
        echo "  $line" >&2
    done
    echo "" >&2
    echo "Dependency Rule: domain/core は外部層に依存してはならない。" >&2
    echo "" >&2
    echo "Fix: Port（インターフェース）を domain/ports/ に定義し、" >&2
    echo "     infrastructure層でimplementしてください。" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  // domain/ports/UserRepository.ts" >&2
    echo "  export interface UserRepository { findById(id: string): Promise<User | null> }" >&2
    echo "" >&2
    echo "  // infrastructure/persistence/PrismaUserRepository.ts" >&2
    echo "  import { UserRepository } from '../../domain/ports/UserRepository'" >&2
    echo "========================================" >&2
    exit 2
fi

printf '%s' "$input"
