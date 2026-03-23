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
# Security: No npx --yes (supply-chain risk). Only pre-installed tools.
set -uo pipefail
# Note: -e intentionally omitted — timeout exits non-zero and we handle it

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

# Safe timeout wrapper: passes file as argument, not interpolated in bash -c
run_lint() {
  local tool="$1"
  shift
  timeout "$TIMEOUT" "$tool" "$@" 2>&1 || true
}

case "$file" in
  *.ts|*.tsx|*.js|*.jsx)
    # Phase 1: Auto-fix (silent) — only if tool is installed
    if command -v biome >/dev/null 2>&1; then
      run_lint biome format --write "$file" >/dev/null 2>&1
    fi

    if command -v oxlint >/dev/null 2>&1; then
      run_lint oxlint --fix "$file" >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations
    if command -v oxlint >/dev/null 2>&1; then
      diagnostics="$(run_lint oxlint "$file" | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.py)
    # Phase 1: Auto-fix (silent)
    if command -v ruff >/dev/null 2>&1; then
      run_lint ruff check --fix "$file" >/dev/null 2>&1
      run_lint ruff format "$file" >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations
    if command -v ruff >/dev/null 2>&1; then
      diagnostics="$(run_lint ruff check "$file" | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.go)
    # Phase 1: Auto-fix (silent)
    if command -v gofumpt >/dev/null 2>&1; then
      run_lint gofumpt -w "$file" >/dev/null 2>&1
    fi
    if command -v golangci-lint >/dev/null 2>&1; then
      dir=""
      dir="$(dirname "$file")"
      run_lint golangci-lint run --fix "${dir}/..." >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations (directory scope)
    if command -v golangci-lint >/dev/null 2>&1; then
      dir=""
      dir="$(dirname "$file")"
      diagnostics="$(run_lint golangci-lint run "${dir}/..." | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.json|*.css)
    # Phase 1: Auto-fix (silent)
    if command -v biome >/dev/null 2>&1; then
      run_lint biome check --write "$file" >/dev/null 2>&1
    fi

    # Phase 2: Check remaining violations
    if command -v biome >/dev/null 2>&1; then
      diagnostics="$(run_lint biome check "$file" | head -"$MAX_OUTPUT_LINES")"
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
  && [[ "$diagnostics" != *"0 diagnostics"* ]]; then
  jq -Rn --arg msg "$diagnostics" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("Lint violations found. Fix the code (not the linter config):\n\n" + $msg)
    }
  }'
fi
