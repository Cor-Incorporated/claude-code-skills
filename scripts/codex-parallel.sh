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
#   CODEX_MODEL              — モデル指定 (default: config.tomlのmodel)
#   CODEX_SANDBOX            — サンドボックス: read-only|workspace-write|danger-full-access (default: workspace-write)
#   CODEX_OUTPUT             — 出力ファイル (default: /tmp/codex-result-{branch}.md)
#   CODEX_PROFILE            — Codex profile (default: exec-lean; CODEX_ENABLE_MCP=1 のとき rich-mcp)
#   CODEX_ENABLE_MCP         — 1 のとき MCP を明示 opt-in
#   CODEX_PERSIST_SESSION    — 1 のとき --ephemeral を外す
#   CODEX_TIMEOUT_SEC        — 実装タスク timeout 秒 (default: 3600)
#   CODEX_REVIEW_TIMEOUT_SEC — review timeout 秒 (default: 1800)
#
# H1 非進捗ランタイム — stop conditions beyond the wall-clock timeout:
#   CODEX_H1_BUDGET_USD      — 委任あたり課金上限 USD (default: 5)
#   CODEX_H1_MAX_ITERATIONS  — 反復上限 (default: 10)
#   CODEX_H1_NO_PROGRESS_SEC — 無進捗タイムアウト秒 (default: 2700 = 45分)
#   CODEX_H1_DELEGATION      — 委任 ID (default: codex-parallel:<branch>)
#   CODEX_H1_WRAPPER_ENFORCE — 0 で watchdog 無効化（hook 側の block は残る）
#   Counters are written by hooks/codex/h1-stall-runtime.sh (PreToolUse) and
#   only read here, so the two halves never double-count.
#
# IMPORTANT:
#   - Do NOT checkout the target branch in the main repo before running this script.
#     This script creates a git worktree for the branch, which fails if the branch
#     is already checked out elsewhere. It will not switch the main repo branch.
#   - Codex CLI runs are MCP-off by default to avoid startup hangs from user
#     config MCP bootstrap. Set CODEX_ENABLE_MCP=1 only when a task needs MCP.

set -euo pipefail

# --- H1 非進捗ランタイム (shared with hooks/codex/h1-stall-runtime.sh) ---
_H1_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/h1-runtime.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/h1-runtime.sh
[ -f "$_H1_LIB" ] && . "$_H1_LIB"
set -euo pipefail  # the library relaxes errexit; restore this script's mode
if ! declare -F h1_init >/dev/null 2>&1; then
    # Library missing (partial install): run unguarded rather than failing.
    h1_init() { :; }
    h1_start_watchdog() { :; }
    h1_stop_watchdog() { :; }
    h1_summary() { printf 'H1: runtime library not installed\n'; }
fi

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

timeout_bin() {
    if command -v timeout >/dev/null 2>&1; then
        command -v timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        command -v gtimeout
    fi
}

capture_mcp_snapshot() {
    local snapshot_file="$1"
    {
        echo "# MCP process snapshot"
        date
        ps -axo pid,ppid,stat,etime,time,args \
          | grep -E '(@upstash/context7-mcp|@modelcontextprotocol/server-github|@supabase/mcp-server-supabase|node_repl|SkyComputerUseClient mcp|codex mcp-server)' \
          | grep -v -E '(grep -E|codex-parallel.sh)' \
          | sed -E 's/(SUPABASE_ACCESS_TOKEN=)[^ ]+/\1REDACTED/g; s/(GITHUB_TOKEN=)[^ ]+/\1REDACTED/g; s/(--access-token)[= ]?[^ ]+/\1 REDACTED/g; s/(token=)[^ ]+/\1REDACTED/g' \
          || true
    } > "$snapshot_file"
}

build_codex_exec_args() {
    CODEX_EXEC_ARGS=()

    local profile
    if [[ "${CODEX_ENABLE_MCP:-}" == "1" ]]; then
        profile="${CODEX_PROFILE:-rich-mcp}"
    else
        profile="${CODEX_PROFILE:-exec-lean}"
    fi

    CODEX_EXEC_ARGS+=(--profile "$profile" --strict-config --json)
    if [[ "${CODEX_PERSIST_SESSION:-}" != "1" ]]; then
        CODEX_EXEC_ARGS+=(--ephemeral)
    fi

    CODEX_EXEC_ARGS+=(-c 'approval_policy="never"')

    if [[ "${CODEX_ENABLE_MCP:-}" == "1" ]]; then
        CODEX_EXEC_ARGS+=(
            -c 'mcp_servers.context7.enabled=true'
            -c 'mcp_servers.github.enabled=true'
            -c 'mcp_servers.supabase.enabled=true'
            -c 'mcp_servers.node_repl.enabled=true'
            -c 'plugins."computer-use@openai-bundled".enabled=true'
        )
    else
        CODEX_EXEC_ARGS+=(
            -c 'mcp_servers.context7.enabled=false'
            -c 'mcp_servers.github.enabled=false'
            -c 'mcp_servers.supabase.enabled=false'
            -c 'mcp_servers.node_repl.enabled=false'
            -c 'plugins."computer-use@openai-bundled".enabled=false'
            -c 'notify=[]'
        )
    fi
}

run_codex_with_timeout() {
    local timeout_sec="$1"
    local event_log="$2"
    local snapshot_file="$3"
    shift 3

    local runner
    runner="$(timeout_bin || true)"

    if [[ -n "$runner" ]]; then
        "$runner" "${timeout_sec}s" "$@" 2>&1 | tee "$event_log"
        local exit_code=${PIPESTATUS[0]}
    else
        warn "timeout/gtimeout not found; running Codex without an outer timeout."
        "$@" 2>&1 | tee "$event_log"
        local exit_code=${PIPESTATUS[0]}
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        capture_mcp_snapshot "$snapshot_file"
        if [[ "$exit_code" -eq 124 ]]; then
            warn "Codex timed out after ${timeout_sec}s."
        fi
        warn "Codex event log: ${event_log}"
        warn "MCP snapshot: ${snapshot_file}"
    fi

    return "$exit_code"
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
    CODEX_EVENT_LOG="${CODEX_EVENT_LOG:-/tmp/codex-review-${REPO_NAME}-events-$(date +%s).jsonl}"
    CODEX_SNAPSHOT_FILE="${CODEX_SNAPSHOT_FILE:-/tmp/codex-review-${REPO_NAME}-mcp-snapshot-$(date +%s).txt}"
    CODEX_REVIEW_TIMEOUT_SEC="${CODEX_REVIEW_TIMEOUT_SEC:-1800}"

    log "Review mode: ${REPO_NAME} (base: ${BASE_BRANCH})"

    # Capture output and exit code (Issue #203)
    CODEX_OUTPUT_FILE="$CODEX_EVENT_LOG"
    build_codex_exec_args
    MODEL_ARGS=()
    if [[ -n "${CODEX_MODEL:-}" ]]; then
        MODEL_ARGS=(-m "$CODEX_MODEL")
    fi
    # H1: review runs get the same stop conditions as implementation runs.
    H1_ID="${CODEX_H1_DELEGATION:-codex-review:${REPO_NAME}}"
    h1_init "$H1_ID" "$REPO_PATH"
    h1_start_watchdog "$H1_ID" "$$"

    set +e
    run_codex_with_timeout "$CODEX_REVIEW_TIMEOUT_SEC" "$CODEX_EVENT_LOG" "$CODEX_SNAPSHOT_FILE" \
        codex exec \
        "${CODEX_EXEC_ARGS[@]}" \
        -C "$REPO_PATH" \
        ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
        -o "$OUTPUT_FILE" \
        review \
        --base "$BASE_BRANCH" \
        ${CUSTOM_PROMPT:+"$CUSTOM_PROMPT"}
    CODEX_EXIT=${PIPESTATUS[0]}
    set -e
    h1_stop_watchdog
    log "$(h1_summary "$H1_ID")"

    # Parse severity from structured review output (#203)
    # Use OUTPUT_FILE (structured -o output) instead of raw stdout/stderr
    # Match severity labels at line start or after bullet/bracket markers
    # Paired delimiters prevent mismatch (e.g. **CRITICAL]: won't match)
    _SEV_SRC="$OUTPUT_FILE"
    if [[ ! -s "$_SEV_SRC" ]]; then
      _SEV_SRC="$CODEX_OUTPUT_FILE"  # Fallback if -o file is empty
    fi
    _CRIT=$(grep -cE '^\s*(#{1,6}\s+|[-*]\s+)?(\*\*CRITICAL\*\*|\[CRITICAL\]|CRITICAL)\s*[:(-]' "$_SEV_SRC" 2>/dev/null || true)
    _HIGH=$(grep -cE '^\s*(#{1,6}\s+|[-*]\s+)?(\*\*HIGH\*\*|\[HIGH\]|HIGH)\s*[:(-]' "$_SEV_SRC" 2>/dev/null || true)
    _MED=$(grep -cE '^\s*(#{1,6}\s+|[-*]\s+)?(\*\*MEDIUM\*\*|\[MEDIUM\]|MEDIUM)\s*[:(-]' "$_SEV_SRC" 2>/dev/null || true)
    _LOW=$(grep -cE '^\s*(#{1,6}\s+|[-*]\s+)?(\*\*LOW\*\*|\[LOW\]|LOW)\s*[:(-]' "$_SEV_SRC" 2>/dev/null || true)

    if [[ "$CODEX_EXIT" -ne 0 ]] && [[ "$_CRIT" -eq 0 ]] && [[ "$_HIGH" -eq 0 ]] && [[ "$_MED" -eq 0 ]] && [[ "$_LOW" -eq 0 ]]; then
      # Codex crashed with no parseable findings — fail-closed
      warn "Codex exec failed with exit code $CODEX_EXIT and no parseable severity data."
      exit "$CODEX_EXIT"
    fi

    success "Review complete: ${OUTPUT_FILE}"
    cat "$OUTPUT_FILE"
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
BRANCH_SLUG="${BRANCH_NAME//\//-}"
WORKTREE_PATH="${REPO_PATH}/.worktrees/codex/${BRANCH_SLUG}"
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

# Check if branch is currently checked out in main repo
CURRENT_BRANCH=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" == "$BRANCH_NAME" ]]; then
    warn "Branch '${BRANCH_NAME}' is checked out in main repo."
    error "Cannot create a worktree for a branch already checked out at ${REPO_PATH}."
    error "Checkout a different branch first, or choose a different target branch."
    exit 1
fi

# --- Create worktree ---
log "Creating worktree: ${WORKTREE_PATH}"
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Create branch if it doesn't exist
if ! git -C "$REPO_PATH" rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    git -C "$REPO_PATH" branch "$BRANCH_NAME" 2>/dev/null || true
fi

# Create worktree. Existing worktrees are only replaced with an explicit opt-in
# so delegation cannot silently delete in-progress work.
if [[ -d "$WORKTREE_PATH" ]]; then
    if [[ "${CODEX_REPLACE_WORKTREE:-0}" != "1" ]]; then
        error "Worktree already exists: ${WORKTREE_PATH}"
        error "Review or remove it manually, or set CODEX_REPLACE_WORKTREE=1 to replace it."
        exit 1
    fi
    warn "Replacing existing worktree: ${WORKTREE_PATH}"
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
CODEX_EVENT_LOG="${CODEX_EVENT_LOG:-/tmp/codex-result-${BRANCH_NAME//\//-}-events-$(date +%s).jsonl}"
CODEX_SNAPSHOT_FILE="${CODEX_SNAPSHOT_FILE:-/tmp/codex-result-${BRANCH_NAME//\//-}-mcp-snapshot-$(date +%s).txt}"
CODEX_TIMEOUT_SEC="${CODEX_TIMEOUT_SEC:-3600}"

build_codex_exec_args
MODEL_ARGS=()
if [[ -n "${CODEX_MODEL:-}" ]]; then
    MODEL_ARGS=(-m "$CODEX_MODEL")
fi

# H1: budget / iteration / no-progress stop conditions for this delegation.
H1_ID="${CODEX_H1_DELEGATION:-codex-parallel:${BRANCH_NAME}}"
h1_init "$H1_ID" "$WORKTREE_PATH"
h1_start_watchdog "$H1_ID" "$$"

set +e
run_codex_with_timeout "$CODEX_TIMEOUT_SEC" "$CODEX_EVENT_LOG" "$CODEX_SNAPSHOT_FILE" \
    codex exec \
    "${CODEX_EXEC_ARGS[@]}" \
    -C "$WORKTREE_PATH" \
    --sandbox "$SANDBOX" \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    -o "$OUTPUT_FILE" \
    "$FULL_PROMPT"

EXIT_CODE=$?
set -e
h1_stop_watchdog
log "$(h1_summary "$H1_ID")"

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
