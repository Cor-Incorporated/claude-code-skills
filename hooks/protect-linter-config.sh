#!/usr/bin/env bash
# PreToolUse Safety Gate — ADR-001, ADR-003
# Blocks modification of linter/formatter/type-checker configuration files.
#
# WHY: Agents tend to weaken linter rules instead of fixing code when they
#      encounter lint errors. This hook deterministically prevents that.
#
# Protected file categories:
#   - Linter configs: .eslintrc*, biome.json*, .oxlintrc*, .ruff.toml, .golangci.*
#   - Formatter configs: .prettierrc*, .editorconfig
#   - Type checker configs: tsconfig.json* (type safety is a quality gate)
#   - Build tool configs: pyproject.toml, Cargo.toml (contain linter sections)
#   - Pre-commit configs: lefthook.yml, .pre-commit-config*
#
# Exit 2 = block the tool call (Claude Code PreToolUse convention)
set -euo pipefail

input="$(cat)"
file="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<< "$input")"

[[ -z "$file" ]] && exit 0

basename_file="$(basename "$file")"

# O(1) pattern matching using case statement (SUGGESTION-3 from review)
case "$basename_file" in
  .eslintrc*|eslint.config*|biome.json*|biome.jsonc|\
  .oxlintrc*|.ruff.toml|ruff.toml|\
  .golangci.yml|.golangci.yaml|\
  .prettierrc*|prettier.config*|.editorconfig|\
  tsconfig.json|tsconfig.*.json|\
  pyproject.toml|Cargo.toml|\
  lefthook.yml|.pre-commit-config*)
    cat >&2 <<MSG
BLOCKED: $basename_file is a protected linter/formatter/type-checker config.

WHY: Agents tend to weaken linter rules instead of fixing code.
     When a linter reports errors, fix the SOURCE CODE, not the config.
     See ADR-001 (docs/adr/001-posttooluse-quality-loop.md)
     See ADR-003 (docs/adr/003-feedback-speed-hierarchy.md)

FIX: Fix the code that violates the rule.
     If the rule is genuinely wrong, propose an ADR to change it.

NOTE: pyproject.toml and Cargo.toml are fully protected because they
      contain linter/formatter configuration sections ([tool.ruff], [lints.clippy]).
      tsconfig.json is protected because type safety is a quality gate.
MSG
    exit 2
    ;;
esac
