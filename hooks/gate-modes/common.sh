#!/bin/bash
# common.sh — Shared functions for pr-ci-review-gate mode scripts
# =========================================================================
# Sourced by the dispatcher and each mode script.
# All output goes to stderr (Claude Code hooks spec).
# =========================================================================
set -euo pipefail

# Source guard: prevent double-initialization when sourced from standalone hooks
if [[ "${_COMMON_SH_LOADED:-}" == "1" ]]; then
  return 0 2>/dev/null || true
fi
_COMMON_SH_LOADED=1

# Prevent gh CLI TTY hangs
export GH_FORCE_TTY=0
export GH_NO_UPDATE_NOTIFIER=1

# =========================================================================
# Portable timeout: macOS has no timeout command (GNU coreutils)
# =========================================================================
if command -v timeout &>/dev/null; then
  _timeout() { timeout "$@"; }
elif command -v gtimeout &>/dev/null; then
  _timeout() { gtimeout "$@"; }
else
  _timeout() { shift; "$@"; }  # skip timeout arg, run command directly
fi

# =========================================================================
# State directory — project-scoped
# =========================================================================
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR}/.claude/state"
elif git rev-parse --show-toplevel &>/dev/null; then
  STATE_DIR="$(git rev-parse --show-toplevel)/.claude/state"
else
  STATE_DIR="$HOME/.claude/state"
fi
REVIEW_STATE="$STATE_DIR/review-status.json"
LOCK_STATE="$STATE_DIR/pr-review-lock.json"
mkdir -p "$STATE_DIR"

# Fail-closed: python3 is required for state file operations
if ! command -v python3 &>/dev/null; then
  echo "[pr-ci-review-gate] python3 not found. Blocking for safety." >&2
  exit 2
fi

# Initialize state files if missing
[ ! -f "$REVIEW_STATE" ] && echo '{}' > "$REVIEW_STATE"
[ ! -f "$LOCK_STATE" ] && echo '{}' > "$LOCK_STATE"

# =========================================================================
# Helper: extract command from tool input JSON
# =========================================================================
extract_cmd() {
  if [[ -n "${input:-}" ]] && command -v jq &>/dev/null; then
    echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo ""
  else
    echo ""
  fi
}
# =========================================================================
# Helper: resolve repository (fork-aware)
# Priority: CLAUDE_FORK_REPO env > --repo flag > upstream remote > origin
# =========================================================================
resolve_repo() {
  local cmd="${1:-}"

  # Priority 1: CLAUDE_FORK_REPO env var
  if [[ -n "${CLAUDE_FORK_REPO:-}" ]]; then
    echo "$CLAUDE_FORK_REPO"
    return
  fi

  # Priority 2: --repo / -R flag in command
  if [[ -n "$cmd" ]]; then
    local expect_repo=0
    local arg
    for arg in $cmd; do
      if [[ "$expect_repo" -eq 1 ]]; then
        if [[ -n "$arg" ]]; then
          echo "$arg"
          return
        fi
      fi
      case "$arg" in
        --repo=*)
          echo "${arg#--repo=}"
          return
          ;;
        --repo|-R)
          expect_repo=1
          ;;
        *)
          expect_repo=0
          ;;
      esac
    done
  fi

  # Priority 3: upstream remote (fork workflow)
  if git remote get-url upstream &>/dev/null; then
    git remote get-url upstream 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||'
    return
  fi

  # Priority 4: origin (default)
  git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo ""
}


# =========================================================================
# Helper: get current branch
# =========================================================================
current_branch() {
  git branch --show-current 2>/dev/null || echo ""
}

# =========================================================================
# Review Tier Classification (content-based)
# =========================================================================
# Tier 1 (FULL)   : Source code changes -> code-reviewer + Codex CLI
# Tier 2 (LIGHT)  : CI/config/docs-only changes -> code-reviewer only
# Tier 3 (EXEMPT) : Branch-based exemption (docs/*, chore/*, ci/*)
#
# Low-risk file patterns (Tier 2):
#   .github/*, Dockerfile, .dockerignore, .gitignore, *.md, CLAUDE.md,
#   .claude/*, tsconfig.json, .eslintrc*, .prettierrc*, renovate.json
# =========================================================================
classify_review_tier() {
  local branch="$1"
  local pr_number="${2:-}"

  # Tier 3: Branch-based exemption
  case "$branch" in docs/*|chore/*|ci/*) echo "EXEMPT"; return ;; esac

  # Issue #141: Use GitHub API for PR changed files instead of local git diff.
  # Local `git diff base...HEAD` gives wrong results when run from develop branch.
  local changed_files=""

  # Try GitHub API first if PR number and repo are available
  if [[ -n "$pr_number" ]] && [[ -n "${REPO:-}" ]]; then
    changed_files=$(_timeout 10 gh api "repos/${REPO}/pulls/${pr_number}/files" --jq '.[].filename' 2>/dev/null || echo "")
  fi

  # Fallback to local git diff if API failed
  if [[ -z "$changed_files" ]]; then
    local base_branch="main"
    if git rev-parse --verify develop &>/dev/null; then
      base_branch="develop"
    elif git rev-parse --verify main &>/dev/null; then
      base_branch="main"
    elif git rev-parse --verify master &>/dev/null; then
      base_branch="master"
    fi
    changed_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || git diff --name-only "${base_branch}" 2>/dev/null || echo "")
  fi

  if [[ -z "$changed_files" ]]; then
    # Cannot determine changes — default to FULL for safety
    echo "FULL"
    return
  fi

  # Check each changed file: if ANY file is NOT in the low-risk pattern, it's Tier 1
  local has_source_changes="false"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
      # Low-risk: All .github config files
      .github/*) ;;
      # Low-risk: Docker config
      Dockerfile|Dockerfile.*|.dockerignore|docker-compose*.yml|docker-compose*.yaml) ;;
      # Low-risk: Documentation
      *.md|docs/*|LICENSE|CHANGELOG*|CONTRIBUTING*) ;;
      # Low-risk: Claude/editor config
      .claude/*|CLAUDE.md|.cursor/*|.vscode/*|.editorconfig) ;;
      # Low-risk: Linter/formatter config
      .eslintrc*|.prettierrc*|.stylelintrc*|biome.json|.biomeignore) ;;
      # Low-risk: Git config
      .gitignore|.gitattributes) ;;
      # Low-risk: Renovate/Dependabot
      renovate.json|.renovaterc*) ;;
      # Low-risk: tsconfig (build config, not source)
      tsconfig*.json) ;;
      # Everything else is source code -> Tier 1
      *)
        has_source_changes="true"
        break
        ;;
    esac
  done <<< "$changed_files"

  if [[ "$has_source_changes" == "true" ]]; then
    echo "FULL"
  else
    echo "LIGHT"
  fi
}

# =========================================================================
# Helper: read review status for a branch (jq-based, no python3 dependency)
# Issue #60 Bug C: Check BOTH project-scoped AND global state (OR logic)
# to prevent path mismatch causing permanent blocks.
# =========================================================================
# Non-CI check run exclusion pattern (#187)
# These check runs are NOT CI jobs and should be excluded from CI status checks.
# Case-insensitive match against check run name.
# =========================================================================
NON_CI_CHECK_PATTERN="^(Agent|copilot|dependabot|CodeRabbit)"

# jq filter to exclude non-CI check runs from CI status counting
# Usage: gh api .../check-runs --jq "$(jq_ci_failures_filter)"
jq_ci_failures_filter() {
  echo "[.check_runs[] | select(.conclusion==\"failure\") | select(.name | test(\"${NON_CI_CHECK_PATTERN}\"; \"i\") | not)] | length"
}

jq_ci_pending_filter() {
  echo "[.check_runs[] | select(.status!=\"completed\") | select(.name | test(\"${NON_CI_CHECK_PATTERN}\"; \"i\") | not)] | length"
}

read_review() {
  local branch="$1"
  local field="$2"
  local global_state="$HOME/.claude/state/review-status.json"

  # Check both state files — return "yes" if EITHER has the field set to true
  local files_to_check=("$REVIEW_STATE")
  if [[ "$global_state" != "$REVIEW_STATE" ]]; then
    files_to_check+=("$global_state")
  fi

  for state_file in "${files_to_check[@]}"; do
    [[ ! -f "$state_file" ]] && continue
    if command -v jq &>/dev/null; then
      local val
      val=$(jq -r --arg b "$branch" --arg f "$field" '.[$b][$f] // false' "$state_file" 2>/dev/null)
      if [[ "$val" == "true" ]]; then
        echo "yes"
        return
      fi
    else
      if grep -q "\"$branch\"" "$state_file" 2>/dev/null && \
         grep -A5 "\"$branch\"" "$state_file" 2>/dev/null | grep -q "\"$field\".*true"; then
        echo "yes"
        return
      fi
    fi
  done
  echo "no"
}

# =========================================================================
# Helper: read Codex severity count from state file (#203)
# Returns numeric count for the specified field, or -1 if not available.
# Fields: codex_critical, codex_high, codex_medium, codex_low
# =========================================================================
read_codex_severity() {
  local branch="$1"
  local field="$2"
  local global_state="$HOME/.claude/state/$(basename "$REVIEW_STATE")"

  local files_to_check=("$REVIEW_STATE")
  if [[ "$global_state" != "$REVIEW_STATE" ]]; then
    files_to_check+=("$global_state")
  fi

  for state_file in "${files_to_check[@]}"; do
    [[ ! -f "$state_file" ]] && continue
    if command -v jq &>/dev/null; then
      local val
      val=$(jq -r --arg b "$branch" --arg f "$field" '.[$b][$f] // -1' "$state_file" 2>/dev/null)
      if [[ "$val" != "-1" ]] && [[ "$val" != "null" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
        return
      fi
    fi
  done
  echo "-1"
}
