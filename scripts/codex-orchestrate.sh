#!/usr/bin/env bash
# codex-orchestrate.sh — 複数Codexタスクを並列実行するオーケストレーター
#
# Usage:
#   codex-orchestrate.sh <repo-path> <tasks-file.json>
#   codex-orchestrate.sh --csv <repo-path> <tasks-file.csv> <prompt-template>
#
# CSV mode: For batch of SIMILAR tasks (same operation, different targets).
#   Uses Codex's native spawn_agents_on_csv for internal fan-out.
#   CSV must have headers; each row = one sub-agent task.
#   Example: codex-orchestrate.sh --csv ~/Dev/repo tasks.csv "Fix lint errors in {file}"
#
# JSON mode (default): For DIFFERENT tasks needing separate worktrees.
# tasks-file.json format:
# {
#   "tasks": [
#     {
#       "branch": "fix/review-feedback",
#       "prompt": "PR #123 のレビュー指摘を修正",
#       "paths": ["src/features/payments", "tests/unit/payments"]
#     },
#     {
#       "branch": "test/user-service",
#       "prompt_file": "/tmp/test-task.md",
#       "paths": ["apps/api/tests/unit/user_service"]
#     },
#     {
#       "branch": "docs/api-update",
#       "prompt": "APIドキュメントを最新の実装に合わせて更新",
#       "paths": ["docs/api", "docs/openapi.md"]
#     }
#   ]
# }
#
# Environment:
#   CODEX_MAX_PARALLEL      — 最大並列数 (default: 3)
#   CODEX_MODEL             — モデル指定
#   CODEX_SANDBOX           — サンドボックス
#   CODEX_PROFILE           — Codex profile (default: exec-lean; CODEX_ENABLE_MCP=1 のとき rich-mcp)
#   CODEX_ENABLE_MCP        — 1 のとき MCP を明示 opt-in
#   CODEX_PERSIST_SESSION   — 1 のとき --ephemeral を外す
#   CODEX_TIMEOUT_SEC       — CSV fan-out timeout 秒 (default: 3600)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[orchestrate]${NC} $*"; }
success() { echo -e "${GREEN}[orchestrate]${NC} $*"; }
error() { echo -e "${RED}[orchestrate]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[orchestrate]${NC} $*"; }

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
          | grep -v -E '(grep -E|codex-orchestrate.sh)' \
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_PARALLEL="${SCRIPT_DIR}/codex-parallel.sh"

# --- CSV fan-out mode ---
if [[ "${1:-}" == "--csv" ]]; then
    REPO_PATH="${2:?repo-path required}"
    CSV_FILE="${3:?csv file required}"
    PROMPT_TEMPLATE="${4:?prompt template required}"
    SANDBOX="${CODEX_SANDBOX:-workspace-write}"
    OUTPUT_FILE="/tmp/codex-csv-results-$(date +%s).csv"
    validate_sandbox "$SANDBOX"

    if [[ ! -f "$CSV_FILE" ]]; then
        error "CSV file not found: $CSV_FILE"
        exit 1
    fi

    ROW_COUNT=$(tail -n +2 "$CSV_FILE" | wc -l | tr -d ' ')
    log "CSV fan-out mode: ${ROW_COUNT} tasks from $(basename "$CSV_FILE")"
    log "Prompt template: ${PROMPT_TEMPLATE}"
    log "Using Codex native spawn_agents_on_csv (max_threads from config.toml)"

    # Literal {column_name} placeholders remain intact here because only ${...} is expanded by Bash.
    read -r -d '' FULL_PROMPT <<CSVEOF || true
You have a CSV file at ${CSV_FILE} with ${ROW_COUNT} rows of tasks.

Use spawn_agents_on_csv to process this file. For each row, apply this prompt template:
${PROMPT_TEMPLATE}

Each worker sub-agent should:
1. Complete its assigned task
2. Run any relevant lint/type checks on touched files
3. Call report_agent_job_result with the outcome

After all workers complete, review the combined results and create commits as needed.
CSVEOF

    CODEX_EVENT_LOG="${CODEX_EVENT_LOG:-/tmp/codex-csv-events-$(date +%s).jsonl}"
    CODEX_SNAPSHOT_FILE="${CODEX_SNAPSHOT_FILE:-/tmp/codex-csv-mcp-snapshot-$(date +%s).txt}"
    CODEX_TIMEOUT_SEC="${CODEX_TIMEOUT_SEC:-3600}"
    build_codex_exec_args
    MODEL_ARGS=()
    if [[ -n "${CODEX_MODEL:-}" ]]; then
        MODEL_ARGS=(-m "$CODEX_MODEL")
    fi

    set +e
    run_codex_with_timeout "$CODEX_TIMEOUT_SEC" "$CODEX_EVENT_LOG" "$CODEX_SNAPSHOT_FILE" \
        codex exec \
        "${CODEX_EXEC_ARGS[@]}" \
        -C "$REPO_PATH" \
        --sandbox "$SANDBOX" \
        ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
        -o "$OUTPUT_FILE" \
        "$FULL_PROMPT"
    EXIT_CODE=$?
    set -e
    if [[ $EXIT_CODE -eq 0 ]]; then
        success "CSV fan-out complete: ${OUTPUT_FILE}"
    else
        error "CSV fan-out failed with exit code: ${EXIT_CODE}"
    fi
    exit $EXIT_CODE
fi

# --- JSON worktree mode (original) ---
REPO_PATH="${1:?Usage: codex-orchestrate.sh <repo-path> <tasks-file.json> OR --csv <repo-path> <csv-file> <prompt>}"
TASKS_FILE="${2:?tasks-file.json required}"
MAX_PARALLEL="${CODEX_MAX_PARALLEL:-3}"

if [[ ! -f "$TASKS_FILE" ]]; then
    error "Tasks file not found: $TASKS_FILE"
    exit 1
fi

validate_tasks_file() {
    python3 - "$TASKS_FILE" <<'PY'
import json
import re
import sys
from pathlib import PurePosixPath

task_file = sys.argv[1]
data = json.load(open(task_file))
tasks = data.get("tasks")
if not isinstance(tasks, list) or not tasks:
    raise SystemExit("tasks must be a non-empty array")

high_risk_path_patterns = [
    ".github/workflows",
    "terraform",
    "infra",
    "supabase/migrations",
    "migrations",
    "Dockerfile",
    "docker-compose",
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "go.mod",
    "go.sum",
    "pyproject.toml",
    "requirements.txt",
    "requirements-dev.txt",
]
high_risk_prompt_terms = [
    "deploy",
    "release",
    "terraform",
    "migration",
    "ddl",
    "auth",
    "payment",
    "billing",
    "schema",
    "secret",
    "デプロイ",
    "リリース",
    "マイグレーション",
    "認証",
    "決済",
    "課金",
    "シークレット",
    "権限",
]

def normalize_path(value: str) -> PurePosixPath:
    text = value.strip().strip("/")
    if not text:
        raise SystemExit("paths entries must not be empty")
    return PurePosixPath(text)

def overlaps(left: PurePosixPath, right: PurePosixPath) -> bool:
    return left == right or left in right.parents or right in left.parents

branches = set()
scopes = []
errors = []

for idx, task in enumerate(tasks):
    if not isinstance(task, dict):
        errors.append(f"task[{idx}] must be an object")
        continue
    branch = task.get("branch", "")
    prompt = task.get("prompt", "") or ""
    prompt_file = task.get("prompt_file", "") or ""
    paths = task.get("paths")

    if not branch:
        errors.append(f"task[{idx}] missing branch")
    elif branch in branches:
        errors.append(f"duplicate branch: {branch}")
    else:
        branches.add(branch)

    if not prompt and not prompt_file:
        errors.append(f"task[{idx}] must define prompt or prompt_file")

    if not isinstance(paths, list) or not paths:
        errors.append(f"task[{idx}] must define non-empty paths[] for independence proof")
        continue

    normalized_paths = []
    for raw in paths:
        if not isinstance(raw, str):
            errors.append(f"task[{idx}] paths entries must be strings")
            continue
        path = normalize_path(raw)
        normalized_paths.append(path)
        path_text = path.as_posix()
        for risky in high_risk_path_patterns:
            if path_text == risky or path_text.startswith(risky + "/") or risky in path_text:
                errors.append(
                    f"task[{idx}] path '{path_text}' is high-risk for worktree parallelism; run serially or hand back to Claude Code"
                )
                break

    prompt_text = f"{prompt} {prompt_file}".lower()
    for term in high_risk_prompt_terms:
        if term in prompt_text:
            errors.append(
                f"task[{idx}] prompt looks high-risk for orchestration ({term}); run serially or hand back to Claude Code"
            )
            break

    scopes.append((idx, branch, normalized_paths))

for left_idx in range(len(scopes)):
    li, lbranch, lpaths = scopes[left_idx]
    for right_idx in range(left_idx + 1, len(scopes)):
        ri, rbranch, rpaths = scopes[right_idx]
        for lpath in lpaths:
            for rpath in rpaths:
                if overlaps(lpath, rpath):
                    errors.append(
                        f"path overlap between {lbranch} ({lpath.as_posix()}) and {rbranch} ({rpath.as_posix()})"
                    )

if errors:
    for item in errors:
        print(item, file=sys.stderr)
    raise SystemExit(1)
PY
}

log "Running independence preflight..."
if ! validate_tasks_file; then
    error "Task independence preflight failed. Split the batch, run serially, or hand back to Claude Code."
    exit 1
fi
success "Independence preflight passed"

# Parse tasks
TASK_COUNT=$(jq '.tasks | length' "$TASKS_FILE")
log "Tasks: ${TASK_COUNT}, Max parallel: ${MAX_PARALLEL}"
log "Repo: ${REPO_PATH}"
echo ""

# --- Launch tasks ---
PIDS=()
BRANCHES=()
RESULTS_DIR="/tmp/codex-orchestrate-$(date +%s)"
mkdir -p "$RESULTS_DIR"

running=0

for i in $(seq 0 $((TASK_COUNT - 1))); do
    BRANCH=$(jq -r ".tasks[$i].branch" "$TASKS_FILE")
    PROMPT=$(jq -r ".tasks[$i].prompt // empty" "$TASKS_FILE")
    PROMPT_FILE=$(jq -r ".tasks[$i].prompt_file // empty" "$TASKS_FILE")
    TASK_SANDBOX=$(jq -r ".tasks[$i].sandbox // empty" "$TASKS_FILE")

    # Wait if at max parallel
    while [[ $running -ge $MAX_PARALLEL ]]; do
        for pid_idx in "${!PIDS[@]}"; do
            if ! kill -0 "${PIDS[$pid_idx]}" 2>/dev/null; then
                wait "${PIDS[$pid_idx]}" 2>/dev/null || true
                unset "PIDS[$pid_idx]"
                running=$((running - 1))
            fi
        done
        PIDS=("${PIDS[@]}")  # reindex
        if [[ $running -ge $MAX_PARALLEL ]]; then
            sleep 2
        fi
    done

    log "Launching task $((i + 1))/${TASK_COUNT}: ${BRANCH}"

    TASK_LOG="${RESULTS_DIR}/${BRANCH//\//-}.log"

    # Per-task sandbox override (from tasks.json "sandbox" field)
    SANDBOX_ENV=""
    if [[ -n "$TASK_SANDBOX" ]]; then
        validate_sandbox "$TASK_SANDBOX"
        SANDBOX_ENV="CODEX_SANDBOX=$TASK_SANDBOX"
    fi

    if [[ -n "$PROMPT_FILE" ]]; then
        env $SANDBOX_ENV \
            CODEX_OUTPUT="${RESULTS_DIR}/${BRANCH//\//-}-result.md" \
            "$CODEX_PARALLEL" "$REPO_PATH" "$BRANCH" --file "$PROMPT_FILE" \
            > "$TASK_LOG" 2>&1 &
    else
        env $SANDBOX_ENV \
            CODEX_OUTPUT="${RESULTS_DIR}/${BRANCH//\//-}-result.md" \
            "$CODEX_PARALLEL" "$REPO_PATH" "$BRANCH" "$PROMPT" \
            > "$TASK_LOG" 2>&1 &
    fi

    PIDS+=($!)
    BRANCHES+=("$BRANCH")
    running=$((running + 1))
done

# --- Wait for all ---
log "All tasks launched. Waiting for completion..."
echo ""

FAILED=0
SUCCEEDED=0

for pid_idx in "${!PIDS[@]}"; do
    PID="${PIDS[$pid_idx]}"
    BRANCH="${BRANCHES[$pid_idx]}"

    if wait "$PID" 2>/dev/null; then
        success "[DONE] ${BRANCH}"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        error "[FAIL] ${BRANCH}"
        FAILED=$((FAILED + 1))
        warn "  Log: ${RESULTS_DIR}/${BRANCH//\//-}.log"
    fi
done

# --- Summary ---
echo ""
log "========================================="
log "  Orchestration Complete"
log "========================================="
log "  Total:     ${TASK_COUNT}"
success "  Succeeded: ${SUCCEEDED}"
[[ $FAILED -gt 0 ]] && error "  Failed:    ${FAILED}"
log "  Results:   ${RESULTS_DIR}/"
log "========================================="
echo ""

# List worktrees
log "Active worktrees:"
git -C "$REPO_PATH" worktree list 2>/dev/null | grep -v "bare" || true
echo ""

log "Next steps:"
log "  Review results: ls ${RESULTS_DIR}/"
log "  Push all:       for wt in ${REPO_PATH}/../.worktrees/${REPO_PATH##*/}-*; do (cd \"\$wt\" && git push -u origin HEAD); done"
log "  Cleanup all:    git -C ${REPO_PATH} worktree prune"

exit $FAILED
