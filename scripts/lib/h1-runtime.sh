#!/usr/bin/env bash
# H1 非進捗ランタイム — wrapper-side stop conditions for the Codex lane.
#
# Sourced by scripts/codex-parallel.sh and scripts/codex-orchestrate.sh.
# Spec: design/harness-spec.md "### H1." (aidd-governance).
#
# DIVISION OF LABOUR with hooks/codex/h1-stall-runtime.sh:
#   The hook is the sole WRITER of the counters (tool_calls, iterations,
#   same_cmd_streak, spend_*).  This library only READS them, so nothing is
#   double-counted.  The two share one state file per delegation:
#       ${CODEX_H1_STATE_DIR:-$HOME/.codex/hooks/h1-state}/<delegation>.json
#   CODEX_H1_DELEGATION is exported into the Codex child so the hook writes to
#   the file this watchdog polls.
#
# WHY A WRAPPER HALF AT ALL:
#   The hook fires at PreToolUse, so it can only stop an agent that is still
#   calling tools.  An agent that goes silent — waiting on a prompt, spinning
#   inside one long call, deadlocked — never reaches the hook.  That case is
#   this watchdog's job: it trips on state-file staleness (no tool call for
#   no_progress_sec) as well as on the same budget / iteration / no-progress
#   conditions the hook enforces, and terminates the run.
#
# Before this, both wrappers had only a wall-clock kill (CODEX_TIMEOUT_SEC).
set -uo pipefail

H1_LEDGER_LIB=""
_h1_self="${BASH_SOURCE[0]:-$0}"
for _cand in \
  "$(cd "$(dirname "$_h1_self")/../.." 2>/dev/null && pwd)/hooks/lib/aidd-ledger.sh" \
  "$HOME/.claude/hooks/lib/aidd-ledger.sh"
do
  [ -f "$_cand" ] && H1_LEDGER_LIB="$_cand" && break
done
# shellcheck source=/dev/null
[ -n "$H1_LEDGER_LIB" ] && . "$H1_LEDGER_LIB"

h1_enabled() { [[ "${CODEX_H1_WRAPPER_ENFORCE:-1}" != "0" ]]; }

h1_slug() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120
}

h1_state_file() {
    local dir="${CODEX_H1_STATE_DIR:-$HOME/.codex/hooks/h1-state}"
    printf '%s/%s.json' "$dir" "$(h1_slug "$1")"
}

# h1_init <delegation> [codex-cwd] — reset the shared state for a new run and
# export the ids the hook needs.  <codex-cwd> is the directory passed to
# `codex -C`; the hook uses it to pick this delegation's rollout transcript
# instead of whichever one was written to most recently, which is what keeps
# parallel delegations from reading each other's spend.
h1_init() {
    local delegation="$1" file
    file="$(h1_state_file "$delegation")"
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
    CODEX_H1_DELEGATION="$delegation"
    export CODEX_H1_DELEGATION
    if [ -n "${2:-}" ]; then
        CODEX_H1_CWD="$2"
        export CODEX_H1_CWD
    fi
    python3 - "$file" "$delegation" \
        "${CODEX_H1_BUDGET_USD:-25}" \
        "${CODEX_H1_MAX_ITERATIONS:-10}" \
        "${CODEX_H1_NO_PROGRESS_SEC:-2700}" <<'PY' 2>/dev/null || true
import json, sys, time
path, delegation, budget, max_iter, no_progress = sys.argv[1:6]
now = int(time.time())
json.dump({
    "delegation": delegation, "started_ts": now, "last_progress_ts": now,
    "iterations": 0, "tool_calls": 0, "spend_tokens": 0, "spend_usd": 0.0,
    "budget_usd": float(budget), "budget_source": "unknown",
    "max_iterations": int(float(max_iter)),
    "no_progress_sec": int(float(no_progress)),
    "last_cmd_sha256": "", "same_cmd_streak": 0, "last_warn_80": 0,
    "last_heartbeat_ts": 0, "last_block_rule": "", "last_block_ts": 0,
}, open(path, "w"))
PY
}

# h1_check <delegation> — print the tripped rule name, or nothing.
# Reads only; the hook owns every counter this inspects.
h1_check() {
    local file
    file="$(h1_state_file "$1")"
    [ -f "$file" ] || return 0
    python3 - "$file" <<'PY' 2>/dev/null || true
import json, os, sys, time
path = sys.argv[1]
try:
    s = json.load(open(path))
except Exception:
    raise SystemExit(0)
now = int(time.time())
no_progress = int(s.get("no_progress_sec") or 2700)
if s.get("last_block_rule"):
    print(s["last_block_rule"]); raise SystemExit(0)

# 2026-09-02: hook 側と同じく、停止はモデルで絞る。一律の上限は実作業を止めた
# （通常セッションが 301 tool call で spend=$5.34 に達して block）。model は
# hook が rollout から読んで同じ state ファイルへ書く。読めていない（空）なら
# 止めない — 「分からないから止める」が事故の形だった。
restricted_tokens = [
    token.strip().lower()
    for token in (os.environ.get("CODEX_H1_RESTRICTED_MODELS") or "sol").split(",")
    if token.strip()
]
model_name = str(s.get("model") or "").lower()
restricted = ("*" in restricted_tokens) or bool(
    model_name and any(token in model_name for token in restricted_tokens)
)
if not restricted:
    raise SystemExit(0)

budget = float(s.get("budget_usd") or 0)
if budget > 0 and float(s.get("spend_usd") or 0) >= budget:
    print("budget-cap"); raise SystemExit(0)
if int(s.get("iterations") or 0) > int(s.get("max_iterations") or 0):
    print("max-iterations"); raise SystemExit(0)
gap = now - int(s.get("last_progress_ts") or now)
if gap > no_progress and int(s.get("same_cmd_streak") or 0) >= 3:
    print("no-progress-timeout"); raise SystemExit(0)
# Idle stall: the hook cannot see this — no tool call has arrived at all.
if now - int(os.path.getmtime(path)) > no_progress:
    print("no-progress-timeout")
PY
}

h1_mark_stop() {
    local file rule="$2"
    file="$(h1_state_file "$1")"
    [ -f "$file" ] || return 0
    python3 - "$file" "$rule" <<'PY' 2>/dev/null || true
import json, sys, time
path, rule = sys.argv[1:3]
try:
    s = json.load(open(path))
except Exception:
    raise SystemExit(0)
s["forced_stop"] = rule
s["last_block_rule"] = rule
s["last_block_ts"] = int(time.time())
json.dump(s, open(path, "w"))
PY
    if declare -F aidd_ledger_append_record >/dev/null 2>&1; then
        aidd_ledger_append_record "$(h1_stop_record "$1" "$rule")" "codex" >/dev/null 2>&1 || true
    fi
}

h1_stop_record() {
    local file
    file="$(h1_state_file "$1")"
    python3 - "$file" "$2" <<'PY' 2>/dev/null || printf '{"component":"H1","event":"block","rule":"%s","detail":"wrapper watchdog stop","subject":{"delegation":"%s"}}' "$2" "$1"
import json, sys
path, rule = sys.argv[1:3]
try:
    s = json.load(open(path))
except Exception:
    s = {}
print(json.dumps({
    "component": "H1", "event": "block", "rule": rule,
    "detail": "wrapper watchdog stopped the Codex run (%s)" % rule,
    "subject": {
        "delegation": s.get("delegation", ""),
        "spend_usd": s.get("spend_usd", 0.0),
        "budget_usd": s.get("budget_usd", 0.0),
        "budget_source": s.get("budget_source", "unknown"),
        "iterations": s.get("iterations", 0),
        "tool_calls": s.get("tool_calls", 0),
        "enforced_by": "wrapper-watchdog",
    },
}, ensure_ascii=False, separators=(",", ":")))
PY
}

# Terminate the Codex run started by the wrapper whose PID is $1.
# Matches only codex/timeout children, so the watchdog never kills itself, the
# tee in the pipeline, or a Codex run belonging to another wrapper invocation.
h1_kill_run() {
    local parent="$1" pid comm
    for pid in $(pgrep -P "$parent" 2>/dev/null); do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
        case "$comm" in
            *codex*|*timeout*) kill -TERM "$pid" 2>/dev/null || true ;;
        esac
    done
    sleep 5
    for pid in $(pgrep -P "$parent" 2>/dev/null); do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
        case "$comm" in
            *codex*|*timeout*) kill -KILL "$pid" 2>/dev/null || true ;;
        esac
    done
}

# h1_watchdog <delegation> <wrapper-pid> — run in the background during a Codex
# invocation.  Exits when the wrapper's Codex children are gone.
h1_watchdog() {
    local delegation="$1" parent="$2" poll="${CODEX_H1_POLL_SEC:-30}" rule
    while kill -0 "$parent" 2>/dev/null; do
        sleep "$poll"
        rule="$(h1_check "$delegation")"
        if [[ -n "$rule" ]]; then
            h1_mark_stop "$delegation" "$rule"
            printf '[h1] stop condition tripped (%s) for delegation %s; terminating Codex\n' \
                "$rule" "$delegation" >&2
            h1_kill_run "$parent"
            return 0
        fi
    done
}

# h1_start_watchdog <delegation> <wrapper-pid> — background the poller and
# remember its PID.  A no-op when CODEX_H1_WRAPPER_ENFORCE=0, which leaves the
# PreToolUse hook as the only enforcement point.
h1_start_watchdog() {
    H1_WATCHDOG_PID=""
    h1_enabled || return 0
    h1_watchdog "$1" "$2" &
    H1_WATCHDOG_PID=$!
}

h1_stop_watchdog() {
    [ -n "${H1_WATCHDOG_PID:-}" ] || return 0
    kill "$H1_WATCHDOG_PID" 2>/dev/null || true
    wait "$H1_WATCHDOG_PID" 2>/dev/null || true
    H1_WATCHDOG_PID=""
}

# h1_summary <delegation> — one line for the wrapper's run summary.
h1_summary() {
    local file
    file="$(h1_state_file "$1")"
    [ -f "$file" ] || { printf 'H1: no state recorded\n'; return 0; }
    python3 - "$file" <<'PY' 2>/dev/null || printf 'H1: state unreadable\n'
import json, sys
s = json.load(open(sys.argv[1]))
print("H1: spend $%.2f/$%.2f (%s) | tool_calls %s | iterations %s/%s | stop: %s"
      % (float(s.get("spend_usd") or 0), float(s.get("budget_usd") or 0),
         s.get("budget_source", "unknown"), s.get("tool_calls", 0),
         s.get("iterations", 0), s.get("max_iterations", 0),
         s.get("last_block_rule") or "none"))
PY
}
