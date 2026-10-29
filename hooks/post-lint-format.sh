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

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"
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
  # Physical paths on both sides: rev-parse --show-toplevel is physical, so a
  # logical /var or /tmp path would never equal it and the walk would pass
  # the repo root.
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || return 1
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
# 0 = HEAD version is clean, or the file is new and untracked.
# 1 = not clean, or anything git cannot answer (not a repo, dubious ownership,
#     ignored file, staged-only file): when unsure, do not rewrite.
# The committed copy is looked up once per hook run and reused by every
# check (ruff check + ruff format would otherwise repeat ~8 git calls).
#   _HEAD_STATE: "" (not looked up) | untracked | unknown | committed
_HEAD_STATE=""
_HEAD_DIR=""
head_lookup() { # $1 = file
  [[ -n "$_HEAD_STATE" ]] && return 0
  local file="$1" dir base rel
  _HEAD_STATE="unknown"
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || return 0
  base="$(basename "$file")"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if ! git -C "$dir" ls-files --error-unmatch -- ":(literal)$base" >/dev/null 2>&1; then
    # Not tracked. New work (untracked, not ignored) may be formatted whole.
    if [[ -n "$(git -C "$dir" ls-files --others --exclude-standard -- ":(literal)$base" 2>/dev/null)" ]]; then
      _HEAD_STATE="untracked"
    fi
    return 0
  fi
  # core.quotepath=off: a non-ASCII name would otherwise come back quoted.
  rel="$(git -c core.quotepath=off -C "$dir" ls-files --full-name -- ":(literal)$base" 2>/dev/null)"
  [[ -n "$rel" ]] || return 0
  _HEAD_DIR="$(mktemp -d 2>/dev/null)" || return 0
  if git -C "$dir" show "HEAD:$rel" >"$_HEAD_DIR/committed" 2>/dev/null; then
    _HEAD_STATE="committed"
  fi
}
trap '[[ -n "$_HEAD_DIR" ]] && rm -rf "$_HEAD_DIR"' EXIT

# 0 = HEAD version is clean, or the file is new and untracked.
# 1 = not clean, or anything git cannot answer (not a repo, dubious ownership,
#     ignored file, staged-only file): when unsure, do not rewrite.
# 2 = the check itself timed out (logged separately from "not clean").
head_version_clean() { # $1 = file, $2 = mode (fmt|lint), rest = stdin command
  local file="$1" mode="$2" rc
  shift 2
  head_lookup "$file"
  case "$_HEAD_STATE" in
    untracked) return 0 ;;
    committed) ;;
    *) return 1 ;;
  esac
  if [[ "$mode" == "fmt" ]]; then
    # Compare bytes, not $( ) captures: command substitution drops trailing
    # newlines, which would hide a formatter's end-of-file change.
    run_stdin "$@" <"$_HEAD_DIR/committed" >"$_HEAD_DIR/formatted"
    rc=$?
    [[ $rc -eq 0 ]] && { cmp -s "$_HEAD_DIR/committed" "$_HEAD_DIR/formatted"; rc=$?; }
  else
    run_stdin "$@" <"$_HEAD_DIR/committed" >/dev/null
    rc=$?
  fi
  [[ $rc -eq 124 ]] && return 2
  [[ $rc -eq 0 ]] && return 0
  return 1
}

may_autofix() { # $1 = file, $2 = config names (space separated), $3 = mode, rest = stdin command
  local file="$1" configs="$2" mode="$3"
  shift 3
  local why=""
  # shellcheck disable=SC2086
  if ! has_project_config "$file" $configs; then
    why="no-project-config"
  else
    head_version_clean "$file" "$mode" "$@"
    case $? in
      0) ;;
      2) why="check-timeout" ;;
      *) why="head-not-clean" ;;
    esac
  fi
  [[ -z "$why" ]] && return 0
  # One ledger row per skipped write: how often the gate protects unedited
  # lines is the number that decides whether it stays (ADR-006 rule 6).
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "post-lint-format" "measure" "allow" "$1 $(basename "$file")" "autofix-skipped:$why"
  fi
  return 1
}

case "$file" in
  *.ts|*.tsx|*.js|*.jsx)
    # Phase 1: Auto-fix (silent) — only if tool is installed
    if command -v biome >/dev/null 2>&1 \
      && may_autofix "$file" "biome.json biome.jsonc" fmt biome format --stdin-file-path="$file"; then
      run_lint biome format --write "$file" >/dev/null 2>&1
    fi

    # oxlint --fix fixes old violations anywhere in the file; report only.

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
      # Only the formatter the gate checked; biome check --write would also
      # apply lint fixes to lines the edit did not touch.
      run_lint biome format --write "$file" >/dev/null 2>&1
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
