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

# Detect timeout command (macOS compatibility)
TIMEOUT_CMD="timeout"
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
  else
    # macOS fallback: skip timeout wrapper
    TIMEOUT_CMD=""
  fi
fi

# Safe timeout wrapper: passes file as argument, not interpolated in bash -c
run_lint() {
  local tool="$1"
  shift
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$TIMEOUT" "$tool" "$@" 2>&1 || true
  else
    "$tool" "$@" 2>&1 || true
  fi
}

# Write-mode fixers (format --write, --fix) rewrite the whole file. They only
# run when they cannot touch lines the edit did not touch:
#   1. the project declares the tool (a config file between the file and the
#      repo root), so the style is the project's, not the tool's default; and
#   2. the committed version of the file was already clean under the same
#      check, so a whole-file pass can only change lines edited since HEAD.
#      An untracked file is new work and passes this condition.
# Otherwise the hook only reports diagnostics.
# 2026-10-29 ai-cluster: an Edit to test_judge_f64.py (no ruff config in the
# repo) was reformatted to ruff's default 88 columns end to end, and the lane
# had to `git checkout --` and redo the edit. tests/test-post-lint-format.sh
has_project_config() { # $1 = file, rest = config names
  local file="$1"
  shift
  local dir top
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)" || return 1
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")"
  while :; do
    local name
    for name in "$@"; do
      if [[ "$name" == "pyproject.toml" ]]; then
        [[ -f "$dir/$name" ]] && grep -q '^\[tool\.ruff' "$dir/$name" && return 0
      elif [[ -f "$dir/$name" ]]; then
        return 0
      fi
    done
    [[ "$dir" == "$top" || "$dir" == "/" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

run_stdin() { # rest = command; stdin passes through; keeps the exit status
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$TIMEOUT" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# $1 = file, $2 = mode, rest = command reading the committed content on stdin.
#   mode "fmt":  clean when the formatter prints the content back unchanged
#   mode "lint": clean when the command exits 0
# 0 = HEAD version is clean (or the file is untracked); 1 = not clean / unknown.
head_version_clean() {
  local file="$1" mode="$2"
  shift 2
  local dir rel committed
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)" || return 1
  rel="$(git -C "$dir" ls-files --full-name -- "$(basename "$file")" 2>/dev/null)"
  [[ -z "$rel" ]] && return 0
  committed="$(git -C "$dir" show "HEAD:$rel" 2>/dev/null)" || return 0
  if [[ "$mode" == "fmt" ]]; then
    local formatted
    formatted="$(printf '%s\n' "$committed" | run_stdin "$@")" || return 1
    [[ "$formatted" == "$committed" ]]
  else
    printf '%s\n' "$committed" | run_stdin "$@" >/dev/null
  fi
}

may_autofix() { # $1 = file, $2 = config names (space separated), $3 = mode, rest = stdin command
  local file="$1" configs="$2" mode="$3"
  shift 3
  # shellcheck disable=SC2086
  has_project_config "$file" $configs || return 1
  head_version_clean "$file" "$mode" "$@"
}

case "$file" in
  *.ts|*.tsx|*.js|*.jsx)
    # Phase 1: Auto-fix (silent) — only if tool is installed
    if command -v biome >/dev/null 2>&1 \
      && may_autofix "$file" "biome.json biome.jsonc" fmt biome format --stdin-file-path="$file"; then
      run_lint biome format --write "$file" >/dev/null 2>&1
    fi

    if command -v oxlint >/dev/null 2>&1 \
      && has_project_config "$file" .oxlintrc.json oxlintrc.json; then
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
      ruff_configs="pyproject.toml ruff.toml .ruff.toml"
      if may_autofix "$file" "$ruff_configs" lint ruff check --quiet --stdin-filename "$file" -; then
        run_lint ruff check --fix "$file" >/dev/null 2>&1
      fi
      if may_autofix "$file" "$ruff_configs" fmt ruff format --stdin-filename "$file" -; then
        run_lint ruff format "$file" >/dev/null 2>&1
      fi
    fi

    # Phase 2: Check remaining violations
    if command -v ruff >/dev/null 2>&1; then
      diagnostics="$(run_lint ruff check "$file" | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.go)
    # Phase 1: Auto-fix (silent)
    # gofumpt is stricter than gofmt and has no config file of its own; go.mod
    # marks the module, and the HEAD check keeps it from restyling a gofmt-only
    # file end to end.
    if command -v gofumpt >/dev/null 2>&1 \
      && may_autofix "$file" "go.mod" fmt gofumpt; then
      run_lint gofumpt -w "$file" >/dev/null 2>&1
    fi
    # golangci-lint --fix rewrites every file under the directory, which no
    # condition here can limit to the edit; it only reports (Phase 2).

    # Phase 2: Check remaining violations (directory scope)
    if command -v golangci-lint >/dev/null 2>&1; then
      dir=""
      dir="$(dirname "$file")"
      diagnostics="$(run_lint golangci-lint run "${dir}/..." | head -"$MAX_OUTPUT_LINES")"
    fi
    ;;

  *.json|*.css)
    # Phase 1: Auto-fix (silent)
    if command -v biome >/dev/null 2>&1 \
      && may_autofix "$file" "biome.json biome.jsonc" fmt biome format --stdin-file-path="$file"; then
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

exit 0
