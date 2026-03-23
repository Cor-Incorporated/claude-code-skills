#!/usr/bin/env bash
# PostToolUse Quality Loop — ADR-001, ADR-003
# Runs linting/formatting after Write/Edit, returns violations via additionalContext
#
# Architecture:
#   1. Auto-fix phase (silent): formatter → linter --fix
#   2. Residual check: re-run linter (no --fix)
#   3. Return remaining violations via JSON additionalContext
#
# Performance: 2s timeout per tool. Silent skip if tool not installed.
set -euo pipefail

TIMEOUT=2
MAX_OUTPUT_LINES=20

input="$(cat)"
file="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<< "$input")"

# Skip if no file or excluded path
[[ -z "$file" ]] && exit 0
case "$file" in
  */node_modules/*|*/dist/*|*/build/*|*/.next/*|*/vendor/*|*/.claude/*|*/__pycache__/*|*/.git/*)
    exit 0 ;;
esac

# Skip if file doesn't exist (was deleted)
[[ ! -f "$file" ]] && exit 0

diagnostics=""

run_with_timeout() {
  timeout "$TIMEOUT" bash -c "$1" 2>&1 || true
}

case "$file" in
  *.ts|*.tsx|*.js|*.jsx)
    # Phase 1: Auto-fix (silent)
    if command -v biome >/dev/null 2>&1; then
      run_with_timeout "biome format --write '$file'" >/dev/null 2>&1
    elif command -v npx >/dev/null 2>&1; then
      run_with_timeout "npx --yes @biomejs/biome format --write '$file'" >/dev/null 2>&1
    fi

    if command -v oxlint >/dev/null 2>&1; then
      run_with_timeout "oxlint --fix '$file'" >/dev/null 2>&1
    elif command -v npx >/dev/null 2>&1; then
      run_with_timeout "npx --yes oxlint --fix '$file'" >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations
    if command -v oxlint >/dev/null 2>&1; then
      diagnostics="$(run_with_timeout "oxlint '$file'" | head -"$MAX_OUTPUT_LINES")"
    elif command -v npx >/dev/null 2>&1; then
      diagnostics="$(run_with_timeout "npx --yes oxlint '$file'" | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.py)
    # Phase 1: Auto-fix (silent)
    if command -v ruff >/dev/null 2>&1; then
      run_with_timeout "ruff check --fix '$file'" >/dev/null 2>&1
      run_with_timeout "ruff format '$file'" >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations
    if command -v ruff >/dev/null 2>&1; then
      diagnostics="$(run_with_timeout "ruff check '$file'" | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.go)
    # Phase 1: Auto-fix (silent)
    if command -v gofumpt >/dev/null 2>&1; then
      run_with_timeout "gofumpt -w '$file'" >/dev/null 2>&1
    fi
    if command -v golangci-lint >/dev/null 2>&1; then
      run_with_timeout "golangci-lint run --fix '$file'" >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations
    if command -v golangci-lint >/dev/null 2>&1; then
      diagnostics="$(run_with_timeout "golangci-lint run '$file'" | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.json|*.css)
    # Phase 1: Auto-fix (silent)
    if command -v biome >/dev/null 2>&1; then
      run_with_timeout "biome check --write '$file'" >/dev/null 2>&1
    elif command -v npx >/dev/null 2>&1; then
      run_with_timeout "npx --yes @biomejs/biome check --write '$file'" >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations
    if command -v biome >/dev/null 2>&1; then
      diagnostics="$(run_with_timeout "biome check '$file'" | head -"$MAX_OUTPUT_LINES")"
    elif command -v npx >/dev/null 2>&1; then
      diagnostics="$(run_with_timeout "npx --yes @biomejs/biome check '$file'" | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *)
    # Unsupported file type — silent skip
    exit 0
    ;;
esac

# Phase 3: Return remaining violations via additionalContext
# Filter out "all clean" messages from various tools
if [[ -n "$diagnostics" ]] \
  && [[ "$diagnostics" != *"No lint violations"* ]] \
  && [[ "$diagnostics" != *"Found 0 error"* ]] \
  && [[ "$diagnostics" != *"All checks passed"* ]] \
  && [[ "$diagnostics" != *"Checked 1 file"*"Found 0"* ]] \
  && [[ "$diagnostics" != *"0 diagnostics"* ]]; then
  jq -Rn --arg msg "$diagnostics" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("Lint violations found. Fix the code (not the linter config):\n\n" + $msg)
    }
  }'
fi
