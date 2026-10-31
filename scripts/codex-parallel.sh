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
#   CODEX_H1_BYPASS_TRUST    — 1(default) のとき、登録 hook が全て検証済みなら
#                              --dangerously-bypass-hook-trust を付けて H1 を発火させる。
#                              0 で無効化。--review では常に無効
#   CODEX_REVIEW_TIMEOUT_SEC — review timeout 秒 (default: 1800)
#
# H1 非進捗ランタイム — stop conditions beyond the wall-clock timeout:
#   CODEX_H1_BUDGET_USD      — 全モデルの推定予算 USD (default: 50 / session epoch)
#   CODEX_H1_MAX_ITERATIONS  — 反復上限 (default: 10)
#   CODEX_H1_NO_PROGRESS_SEC — 無進捗タイムアウト秒 (default: 2700 = 45分)
#   CODEX_H1_START_IDLE_SEC  — 起動から tool call 0 のまま止める秒 (default: min(上, 900)。2026-10-31 の stdin 固着)
#   CODEX_REPLACE_WORKTREE   — 1 のとき既存 worktree を差し替える。未 commit の作業は先に
#                              wip(<branch>) commit（Agent-Lane: codex）として branch に残す
#   CODEX_REPLACE_SAVE_WIP   — 0 のとき差し替えで未 commit の作業を捨てる (default: 1)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# --- H1 非進捗ランタイム (shared with hooks/codex/h1-stall-runtime.sh) ---
_H1_LIB="${SCRIPT_DIR}/lib/h1-runtime.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/h1-runtime.sh
[ -f "$_H1_LIB" ] && . "$_H1_LIB"
set -euo pipefail  # the library relaxes errexit; restore this script's mode

# H17: hand the parent's user decisions to the Codex child so an approval given
# here is not re-asked there (DOT-INC-014/025). Scope is never widened: only
# decisions are inherited, and only when the parent session is known.
_cc_parent="${AIDD_CC_SESSION:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
if [ -n "$_cc_parent" ] && [ -z "${AIDD_CC_INHERIT:-}" ]; then
    _cc_meta="${AIDD_CC_STATE_DIR:-$HOME/.claude/state/aidd-cc}/sessions/claude-code__${_cc_parent}.json"
    [ -f "$_cc_meta" ] && export AIDD_CC_INHERIT="$_cc_meta"
fi
if ! declare -F h1_init >/dev/null 2>&1; then
    # Library missing (partial install): run unguarded rather than failing.
    h1_init() { :; }
    h1_start_watchdog() { :; }
    h1_stop_watchdog() { :; }
    h1_summary() { printf 'H1: runtime library not installed\n'; }
fi
declare -F h1_watchdog_status >/dev/null 2>&1 || h1_watchdog_status() { printf 'H1 watchdog: NOT RUNNING (runtime library has no status)\n'; }

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

# Vet every hook Codex would run before asking it to skip its trust prompt.
# Returns 0 only when EVERY *.sh registered in ~/.codex/hooks.json is a known
# AIDD hook AND (when the checkout is reachable) is byte-identical to its
# version-controlled source. Anything unknown or drifted => 1 => no bypass.
CODEX_VETTED_HOOKS="protect-branches-codex.sh h1-stall-runtime.sh aidd-cc-codex.sh"
hooks_verified_against_repo() {
    local hooks_json="$HOME/.codex/hooks.json"
    [[ -f "$hooks_json" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    local registered
    registered=$(python3 - "$hooks_json" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for ms in d.get("hooks", {}).values():
    for m in ms:
        for h in m.get("hooks", []):
            for tok in h.get("command", "").split():
                if tok.endswith(".sh"):
                    print(tok)
PY
    )
    [[ -n "$registered" ]] || return 1

    local src_dir="" cand
    for cand in "$HOME/Developer/claude-code-skills/hooks/codex" \
                "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hooks/codex"; do
        if [[ -f "$cand/protect-branches-codex.sh" ]]; then src_dir="$cand"; break; fi
    done

    local path base
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        base=$(basename "$path")
        case " $CODEX_VETTED_HOOKS " in
            *" $base "*) ;;
            *) return 1 ;;   # unknown hook registered — do not bypass trust
        esac
        [[ -f "$path" ]] || return 1
        if [[ -n "$src_dir" && -f "$src_dir/$base" ]]; then
            [[ "$(md5 -q "$path" 2>/dev/null || md5sum "$path" | awk '{print $1}')" \
               == "$(md5 -q "$src_dir/$base" 2>/dev/null || md5sum "$src_dir/$base" | awk '{print $1}')" ]] || return 1
        fi
    done <<<"$registered"
    return 0
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

    # H1 activation for the implementation lane.
    #
    # Codex persists hook trust in ~/.codex/config.toml keyed by POSITION
    # ("hooks.json:pre_tool_use:<matcher>:<hook>"), not by script path. A hook
    # with no trust entry is skipped SILENTLY — no error, no log. Measured
    # 2026-09-01: h1-stall-runtime.sh was deployed, registered and MD5-matched,
    # yet created no state file and no ledger row until trust was bypassed.
    # (Worse: inserting a hook at index 0 invalidated the entry that used to be
    # there, silently disabling protect-branches-codex too — the ledger stayed
    # at 302 until the order was restored, then advanced to 303.)
    #
    # The flag's own help scopes it to "automation that already vets hook
    # sources", so we actually vet them here rather than blanket-bypassing:
    # every *.sh registered in hooks.json must be byte-identical to its
    # version-controlled source in this repo. If any deployed hook is unknown or
    # has drifted, we do NOT bypass — an untrusted-but-unverified hook set is
    # exactly what the trust prompt exists to catch.
    #
    # Not applied to --review (read-only; no H1 budget to enforce) and not to
    # interactive Codex (still needs a real trust decision, so H1 is inactive
    # there). Set CODEX_H1_BYPASS_TRUST=0 to force it off.
    if [[ "${CODEX_REVIEW_MODE:-}" != "1" && "${CODEX_H1_BYPASS_TRUST:-1}" == "1" ]] \
        && codex --help 2>/dev/null | grep -q -- '--dangerously-bypass-hook-trust' \
        && hooks_verified_against_repo; then
        CODEX_EXEC_ARGS+=(--dangerously-bypass-hook-trust)
    fi

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

    # stdin is always /dev/null. Codex's exec mode reads "additional input from stdin" until EOF, and the prompt is
    # already an argument. 2026-10-31: launched from a background Bash whose stdin stayed open, the second L1 run
    # printed "Reading additional input from stdin..." and waited 2 h 18 m with 0 tool calls.
    if [[ -n "$runner" ]]; then
        "$runner" "${timeout_sec}s" "$@" </dev/null 2>&1 | tee "$event_log"
        local exit_code=${PIPESTATUS[0]}
    else
        warn "timeout/gtimeout not found; running Codex without an outer timeout."
        "$@" </dev/null 2>&1 | tee "$event_log"
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
    CODEX_REVIEW_MODE=1   # read-only lane: no H1 budget to enforce, so no trust bypass
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
    log "$(h1_watchdog_status)"

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
    # Uncommitted work is saved on the branch before the forced removal, unless CODEX_REPLACE_SAVE_WIP=0.
    # 2026-10-31: every L1 relaunch with CODEX_REPLACE_WORKTREE=1 would have deleted the previous run's edits;
    # the orchestrator committed them by hand each time.
    # The worktree must be a valid checkout of this branch with no operation in progress, or the save could land on
    # no branch (detached HEAD, a rebase stopped by a conflict), on the main checkout (a missing .git link makes
    # `git -C` walk up), or be skipped (a failing `git status` read as clean) (claude-code-skills#472 review).
    wt_root="$(git -C "$WORKTREE_PATH" rev-parse --show-toplevel 2>/dev/null)" || wt_root=""
    wt_ref="$(git -C "$WORKTREE_PATH" symbolic-ref -q HEAD 2>/dev/null)" || wt_ref=""
    wt_gitdir="$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir 2>/dev/null)" || wt_gitdir=""
    wt_here="$(cd "$WORKTREE_PATH" && pwd -P)"
    if [[ "$wt_root" != "$wt_here" || "$wt_ref" != "refs/heads/${BRANCH_NAME}" \
          || -z "$wt_gitdir" || -d "$wt_gitdir/rebase-merge" || -d "$wt_gitdir/rebase-apply" \
          || -f "$wt_gitdir/MERGE_HEAD" || -f "$wt_gitdir/CHERRY_PICK_HEAD" ]]; then
        error "Not replacing ${WORKTREE_PATH}: root=${wt_root:-none} HEAD=${wt_ref:-detached};"
        error "  expected its own checkout on refs/heads/${BRANCH_NAME} with no rebase/merge/cherry-pick in progress."
        error "  Finish or abort the operation there, or remove the worktree yourself after saving what you need."
        exit 1
    fi
    if ! wt_status="$(git -C "$WORKTREE_PATH" status --porcelain)"; then
        error "git status failed in ${WORKTREE_PATH}; not replacing it."
        exit 1
    fi
    if [[ -n "$wt_status" ]]; then
        if [[ "${CODEX_REPLACE_SAVE_WIP:-1}" == "1" ]]; then
            # Untracked files that look like secrets or are large are not swept into a commit the wrapper later
            # tells you to push.
            risky="$(git -C "$WORKTREE_PATH" ls-files --others --exclude-standard -z | python3 -c '
import os, re, sys
root = sys.argv[1]
for p in sys.stdin.read().split("\0"):
    if not p:
        continue
    base = os.path.basename(p)
    secret = re.match(r"(\.env($|\.(?!example$|sample$|template$))|id_(rsa|dsa|ecdsa|ed25519)|.*\.(pem|key|p12|pfx|keystore)$|.*credentials)", base)
    try:
        big = os.path.getsize(os.path.join(root, p)) > 10 * 1024 * 1024
    except OSError:
        big = False
    if secret or big:
        print(p + (" (large)" if big and not secret else ""))
' "$WORKTREE_PATH")"
            if [[ -n "$risky" ]]; then
                error "Not replacing ${WORKTREE_PATH}: untracked files that must not be committed automatically:"
                printf '  %s\n' "$risky" >&2
                error "  Move or ignore them, commit what you want yourself, or leave CODEX_REPLACE_WORKTREE unset."
                exit 1
            fi
            log "Saving uncommitted work before the replacement:"
            printf '%s\n' "$wt_status" | sed 's/^/    /'
            if git -C "$WORKTREE_PATH" add -A \
                && git -C "$WORKTREE_PATH" commit -q \
                    -m "chore(wip): save uncommitted work on ${BRANCH_NAME} before the worktree is replaced" \
                    -m "Saved by codex-parallel.sh (CODEX_REPLACE_WORKTREE=1) before git worktree remove --force." \
                    -m "Agent-Lane: codex"; then
                log "Saved uncommitted work: $(git -C "$WORKTREE_PATH" rev-parse --short HEAD) on ${BRANCH_NAME}"
            else
                error "Could not commit the uncommitted work in ${WORKTREE_PATH} (a commit hook may have refused it);"
                error "  not replacing it. Commit it yourself, or leave CODEX_REPLACE_WORKTREE unset."
                exit 1
            fi
        else
            warn "CODEX_REPLACE_SAVE_WIP=0: discarding uncommitted work in ${WORKTREE_PATH}"
        fi
    fi
    warn "Replacing existing worktree: ${WORKTREE_PATH}"
    git -C "$REPO_PATH" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || rm -rf "$WORKTREE_PATH"
    git -C "$REPO_PATH" worktree prune 2>/dev/null || true
fi

git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
log "Worktree created: ${WORKTREE_PATH}"

# --- 発射直前ゲート: レーンの基点検査 (aidd-governance#91) ---
# worktree は「作った時の基点」を保持し、再利用しても更新されない。上の
# `git branch` は REPO_PATH の現 HEAD から切るだけで、既存ブランチなら何もしない。
# どちらの経路でも基点は静かに古くなりうる。基点が古いまま発射すると、その間に
# base へ入った他レーンの成果を知らずに同じ領域を再実装し、マージ時の add/add で
# 成熟度の低い側が破棄される（Grift feat/l-s6-api: develop 650 行 vs ブランチ 290 行）。
# 検出点がマージ時しかなかったことが損失を確定させたので、ここで止める。
# exec ビットではなく -f で判定し bash で起動する。exec ビットが落ちただけで
# ゲートが黙って無効化される（= まさにこの Issue の失敗形）のを避ける。
LANE_CHECK="${SCRIPT_DIR}/lane-basepoint-check.sh"
if [[ -f "$LANE_CHECK" ]]; then
    if ! LANE_LEDGER_SOURCE=codex-parallel bash "$LANE_CHECK" check "$WORKTREE_PATH"; then
        error "レーンの基点検査に失敗したため発射しない: ${BRANCH_NAME}"
        error "  worktree は残してある。上の指示どおり切り直してから再実行すること:"
        error "    git -C ${WORKTREE_PATH} rebase origin/<base>"
        error "  意図的に無視する場合のみ LANE_BASEPOINT_ENFORCE=0（降格は台帳へ記帳される）"
        exit 1
    fi
else
    warn "lane-basepoint-check.sh が見つからない: 基点検査なしで発射する (${LANE_CHECK})"
fi

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
export CODEX_H1_EVENT_LOG="$CODEX_EVENT_LOG"
h1_start_watchdog "$H1_ID" "$$"
log "$(h1_watchdog_status)"

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
