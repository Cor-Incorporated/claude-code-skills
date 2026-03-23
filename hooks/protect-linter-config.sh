#!/usr/bin/env bash
# PreToolUse Safety Gate — ADR-001, ADR-003
# Blocks modification of linter/formatter/type-checker configuration files.
#
# WHY: Agents tend to weaken linter rules instead of fixing code when they
#      encounter lint errors. This hook deterministically prevents that.
#
# Exit 2 = block the tool call (Claude Code PreToolUse convention)
set -euo pipefail

input="$(cat)"
file="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<< "$input")"

[[ -z "$file" ]] && exit 0

PROTECTED_PATTERNS=(
  ".eslintrc"
  "eslint.config"
  "biome.json"
  "biome.jsonc"
  ".oxlintrc"
  "pyproject.toml"
  ".golangci."
  "Cargo.toml"
  ".prettierrc"
  "prettier.config"
  ".editorconfig"
  "tsconfig.json"
  "tsconfig."
  "lefthook.yml"
  ".pre-commit-config"
  ".ruff.toml"
  "ruff.toml"
)

basename_file="$(basename "$file")"

for pattern in "${PROTECTED_PATTERNS[@]}"; do
  case "$basename_file" in
    *"$pattern"*)
      cat >&2 <<MSG
BLOCKED: $file is a protected linter/formatter config.

WHY: Agents tend to weaken linter rules instead of fixing code.
     When a linter reports errors, fix the SOURCE CODE, not the config.
     See ADR-001 (docs/adr/001-posttooluse-quality-loop.md)
     See ADR-003 (docs/adr/003-feedback-speed-hierarchy.md)

FIX: Fix the code that violates the rule.
     If the rule is genuinely wrong, propose an ADR to change it.
MSG
      exit 2
      ;;
  esac
done
