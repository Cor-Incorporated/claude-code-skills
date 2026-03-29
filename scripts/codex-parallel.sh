#!/usr/bin/env bash
# codex-parallel.sh — Claude Code → Codex CLI 並列委任スクリプト
# Usage:
#   codex-parallel.sh <repo-path> <branch-name> <prompt>
#   codex-parallel.sh <repo-path> <branch-name> --file <prompt-file>
#   codex-parallel.sh --review <repo-path> [--base <branch>]
#
# Examples:
#   codex-parallel.sh ~/Developer/polls feat/add-tests "UserServiceのunit testを作成"
#   codex-parallel.sh ~/Developer/polls fix/review-feedback --file /tmp/codex-task.md
#   codex-parallel.sh --review ~/Developer/polls --base develop
#
# Environment:
#   CODEX_MODEL    — モデル指定 (default: config.tomlのmodel)
#   CODEX_SANDBOX  — サンドボックス: read-only|workspace-write|danger-full-access (default: workspace-write)
#   CODEX_OUTPUT   — 出力ファイル (default: /tmp/codex-result-{branch}.md)
#
# IMPORTANT:
#   - Do NOT checkout the target branch in the main repo before running this script.
#     This script creates a git worktree for the branch, which fails if the branch
#     is already checked out elsewhere. The script will auto-switch main repo to
#     'develop' if the target branch is currently checked out.
#   - --full-auto only works with sandbox=workspace-write. For danger-full-access,
#     the script uses --sandbox directly without --full-auto.

set -euo pipefail

# --- Color ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[codex-parallel]${NC} $*"; }
warn() { echo -e "${YELLOW}[codex-parallel]${NC} $*"; }
error() { echo -e "${RED}[codex-parallel]${NC} $*" >&2; }
success() { echo -e "${GREEN}[codex-parallel]${NC} $*"; }

validate_sandbox() {
    local sandbox="$1"
    case "$sandbox" in
        read-only|workspace-write|danger-full-access) ;;
        *)
            error "Invalid sandbox value: ${sandbox}"
            error "Valid values: read-only | workspace-write | danger-full-access"
            exit 1
            ;;
    esac
}

# --- Review mode ---
if [[ "${1:-}" == "--review" ]]; then
    REPO_PATH="${2:?repo-path required}"
    shift 2
    BASE_BRANCH="develop"
    CUSTOM_PROMPT=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) BASE_BRANCH="$2"; shift 2 ;;
            *) CUSTOM_PROMPT="$1"; shift ;;
        esac
    done

    REPO_NAME=$(basename "$REPO_PATH")
    OUTPUT_FILE="${CODEX_OUTPUT:-/tmp/codex-review-${REPO_NAME}.md}"

    log "Review mode: ${REPO_NAME} (base: ${BASE_BRANCH})"

    # Capture output and exit code (Issue #203)
    CODEX_OUTPUT_FILE=$(mktemp)
    trap 'rm -f "$CODEX_OUTPUT_FILE"' EXIT
    codex exec \
        -C "$REPO_PATH" \
        ${CODEX_MODEL:+-m "$CODEX_MODEL"} \
        -o "$OUTPUT_FILE" \
        review \
        --base "$BASE_BRANCH" \
        ${CUSTOM_PROMPT:+"$CUSTOM_PROMPT"} 2>&1 | tee "$CODEX_OUTPUT_FILE"
    CODEX_EXIT=${PIPESTATUS[0]}

    # Parse severity from structured review output (#203)
    # Use OUTPUT_FILE (structured -o output) instead of raw stdout/stderr
    # Match severity labels at line start or after bullet/bracket markers
    # to avoid false positives from prose like "No CRITICAL issues found"
    _SEV_SRC="$OUTPUT_FILE"
    if [[ ! -s "$_SEV_SRC" ]]; then
      _SEV_SRC="$CODEX_OUTPUT_FILE"  # Fallback if -o file is empty
    fi
    _CRIT=$(grep -cE '^\s*[-*]?\s*\[?\bCRITICAL\b\]?\s*[:-]' "$_SEV_SRC" 2>/dev/null || echo "0")
    _HIGH=$(grep -cE '^\s*[-*]?\s*\[?\bHIGH\b\]?\s*[:-]' "$_SEV_SRC" 2>/dev/null || echo "0")
    _MED=$(grep -cE '^\s*[-*]?\s*\[?\bMEDIUM\b\]?\s*[:-]' "$_SEV_SRC" 2>/dev/null || echo "0")
    _LOW=$(grep -cE '^\s*[-*]?\s*\[?\bLOW\b\]?\s*[:-]' "$_SEV_SRC" 2>/dev/null || echo "0")
    rm -f "$CODEX_OUTPUT_FILE"

    if [[ "$CODEX_EXIT" -ne 0 ]] && [[ "$_CRIT" -eq 0 ]] && [[ "$_HIGH" -eq 0 ]] && [[ "$_MED" -eq 0 ]] && [[ "$_LOW" -eq 0 ]]; then
      # Codex crashed with no parseable findings — fail-closed
      warn "Codex exec failed with exit code $CODEX_EXIT and no parseable severity data."
      CURRENT_BRANCH=$(cd "$REPO_PATH" && git branch --show-current 2>/dev/null || echo "")
      if [[ -n "$CURRENT_BRANCH" ]]; then
        RECORD_SCRIPT="$(dirname "$0")/../hooks/record-codex-review.sh"
        if [[ -x "$RECORD_SCRIPT" ]]; then
          bash "$RECORD_SCRIPT" "$CURRENT_BRANCH" "$REPO_PATH"
        fi
      fi
      exit "$CODEX_EXIT"
    fi

    success "Review complete: ${OUTPUT_FILE}"
    cat "$OUTPUT_FILE"

    # Record Codex review completion in state file
    CURRENT_BRANCH=$(cd "$REPO_PATH" && git branch --show-current 2>/dev/null || echo "")
    if [[ -n "$CURRENT_BRANCH" ]]; then
        RECORD_SCRIPT="$(dirname "$0")/../hooks/record-codex-review.sh"
        if [[ -x "$RECORD_SCRIPT" ]]; then
            bash "$RECORD_SCRIPT" "$CURRENT_BRANCH" "$REPO_PATH" \
              --critical "$_CRIT" --high "$_HIGH" --medium "$_MED" --low "$_LOW"
        fi
    fi
    exit 0
fi

# --- Implementation mode ---
REPO_PATH="${1:?Usage: codex-parallel.sh <repo-path> <branch-name> <prompt|--file path>}"
BRANCH_NAME="${2:?branch-name required}"
shift 2

# Parse prompt
PROMPT=""
if [[ "${1:-}" == "--file" ]]; then
    PROMPT_FILE="${2:?prompt file path required}"
    PROMPT=$(cat "$PROMPT_FILE")
    shift 2
else
    PROMPT="${1:?prompt required}"
    shift
fi

# Config
REPO_NAME=$(basename "$REPO_PATH")
WORKTREE_PATH="${REPO_PATH}/../.worktrees/${REPO_NAME}-${BRANCH_NAME//\//-}"
OUTPUT_FILE="${CODEX_OUTPUT:-/tmp/codex-result-${BRANCH_NAME//\//-}.md}"

# --- Auto-detect sandbox level based on task type ---
# Valid Codex CLI sandbox values: read-only | workspace-write | danger-full-access
auto_detect_sandbox() {
    local prompt="$1"
    local prompt_lower
    prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

    # system-access patterns (e.g. docker, env vars, file permissions)
    local system_patterns="docker|chmod|chown|systemctl|launchctl|brew |apt |yum |gcloud|aws |terraform"
    if echo "$prompt_lower" | grep -qE "$system_patterns"; then
        echo "danger-full-access"
        return
    fi

    # Default: workspace-write (covers most tasks including network access)
    echo "workspace-write"
}

if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    SANDBOX="$CODEX_SANDBOX"
else
    SANDBOX=$(auto_detect_sandbox "$PROMPT")
    log "Auto-detected sandbox level: ${SANDBOX}"
fi
validate_sandbox "$SANDBOX"

# --- Validate ---
if [[ ! -d "$REPO_PATH/.git" ]] && [[ ! -f "$REPO_PATH/.git" ]]; then
    error "Not a git repo: $REPO_PATH"
    exit 1
fi

# --- Create worktree ---
log "Creating worktree: ${WORKTREE_PATH}"
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Check if branch is currently checked out in main repo
CURRENT_BRANCH=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" == "$BRANCH_NAME" ]]; then
    warn "Branch '${BRANCH_NAME}' is checked out in main repo."
    warn "Switching main repo to 'develop' to free the branch for worktree."
    git -C "$REPO_PATH" checkout develop 2>/dev/null || {
        error "Cannot switch main repo away from '${BRANCH_NAME}'. Checkout a different branch first."
        exit 1
    }
fi

# Create branch if it doesn't exist
if ! git -C "$REPO_PATH" rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    git -C "$REPO_PATH" branch "$BRANCH_NAME" 2>/dev/null || true
fi

# Create worktree (remove stale if exists)
if [[ -d "$WORKTREE_PATH" ]]; then
    warn "Worktree exists, removing stale: ${WORKTREE_PATH}"
    git -C "$REPO_PATH" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || rm -rf "$WORKTREE_PATH"
    git -C "$REPO_PATH" worktree prune 2>/dev/null || true
fi

git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
log "Worktree created: ${WORKTREE_PATH}"

# --- Build full prompt with skill reference ---
FULL_PROMPT="$(cat <<PROMPT_EOF
# Codex delegated task

## Repository
- name: ${REPO_NAME}
- branch: ${BRANCH_NAME}
- worktree: ${WORKTREE_PATH}

## Delegation route
- Route: C
- This task should stay bounded and independent.
- If you discover design ambiguity, user-judgment needs, or cross-task coupling, stop and report back instead of inventing a new design.

## Sub-agent strategy
- If this task involves multiple independent sub-tasks (e.g., modifying several files, writing tests for multiple modules), use spawn_agent to parallelize them.
- If the task involves a batch of similar operations (e.g., applying the same fix to many files), consider spawn_agents_on_csv.
- Each sub-agent should handle one atomic unit of work (one file, one test suite, one module).
- Sub-agents must report results via report_agent_job_result.
- After all sub-agents complete, review their outputs and create a single coherent commit.

## Skill references
Use \$claude-code-delegation and \$codex-delivery-governance.

## Task
${PROMPT}

## Completion requirements
1. Implementation complete
2. Lint, type-check, and tests appropriate to the touched files pass
3. Commit created with conventional commit format
4. Branch name and commit type stay aligned
5. If this is a follow-up fix, record the origin PR or commit in the commit message or final output
6. Operationally Ready checks are called out for env vars, permissions, workflows, migrations, or infra changes
PROMPT_EOF
)"

# --- Execute Codex ---
log "Starting Codex: branch=${BRANCH_NAME}, sandbox=${SANDBOX}"
log "Output: ${OUTPUT_FILE}"

# --full-auto is a convenience alias for: --sandbox workspace-write (+ approval on-request).
# When sandbox != workspace-write, --full-auto conflicts. Use --sandbox directly instead.
# `codex exec` runs non-interactively, so --sandbox alone is sufficient for auto execution.
if [[ "$SANDBOX" == "workspace-write" ]]; then
    codex exec \
        -C "$WORKTREE_PATH" \
        --full-auto \
        -o "$OUTPUT_FILE" \
        ${CODEX_MODEL:+-m "$CODEX_MODEL"} \
        "$FULL_PROMPT"
else
    codex exec \
        -C "$WORKTREE_PATH" \
        --sandbox "$SANDBOX" \
        -o "$OUTPUT_FILE" \
        ${CODEX_MODEL:+-m "$CODEX_MODEL"} \
        "$FULL_PROMPT"
fi

EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    success "Codex completed: ${BRANCH_NAME}"

    # Check if there are commits
    COMMIT_COUNT=$(git -C "$WORKTREE_PATH" log --oneline "$(git -C "$REPO_PATH" rev-parse HEAD)..HEAD" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$COMMIT_COUNT" -gt 0 ]]; then
        success "Commits: ${COMMIT_COUNT}"
        git -C "$WORKTREE_PATH" log --oneline -5
    else
        warn "No commits made"
    fi
else
    error "Codex failed with exit code: ${EXIT_CODE}"
fi

# --- Summary ---
echo ""
log "=== Summary ==="
log "Repo:      ${REPO_NAME}"
log "Branch:    ${BRANCH_NAME}"
log "Worktree:  ${WORKTREE_PATH}"
log "Output:    ${OUTPUT_FILE}"
log "Status:    $([ $EXIT_CODE -eq 0 ] && echo 'SUCCESS' || echo 'FAILED')"
echo ""
log "Next steps:"
log "  Review:  cd ${WORKTREE_PATH} && git log --oneline -10"
log "  Push:    cd ${WORKTREE_PATH} && git push -u origin ${BRANCH_NAME}"
log "  Cleanup: git -C ${REPO_PATH} worktree remove ${WORKTREE_PATH}"

exit $EXIT_CODE
