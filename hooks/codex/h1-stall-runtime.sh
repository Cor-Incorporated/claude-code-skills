#!/bin/bash
# Codex PreToolUse / UserPromptSubmit: H1 非進捗ランタイム.
#
# Spec: design/harness-spec.md "### H1." and design/ops/harness/h1-stall-runtime.md
#       (aidd-governance).  The measure/warn half already exists on the Claude
#       Code lane as a heartbeat appended by hooks/enforce-hook-deploy-integrity.sh
#       Phase 0.  This hook is the Codex lane and adds block.
#
# 起点事故: 2026-09-01, two Codex lanes ran 4–7h each, exhausted the budget and
# were stopped by a human with near-zero landed value (one produced 96 files /
# +221,199 lines and zero PRs).  71 Codex sessions measured that day burnt
# 790,087,141 tokens at an input:output ratio of 226:1.
#
# --- CODEX HOOK CONTRACT (differs from Claude Code) ----------------------------
#   Input : JSON on stdin. PreToolUse carries tool_input; UserPromptSubmit
#           carries the user's prompt plus session_id/model/turn_id.
#   Deny  : {"hookSpecificOutput":{...,"permissionDecision":"deny",...}} + exit 0
#   Allow : {} + exit 0
#   NEVER exit non-zero.  Codex treats a non-zero hook exit as hook failure and
#   fails OPEN (spike 2026-08-11, documented in protect-branches-codex.sh).  An
#   `exit 2` — the Claude Code convention — would silently disable this guard.
#   `set -e` is deliberately not used for the same reason.
#
# --- WHAT IS ACTUALLY OBSERVED HERE (do not overclaim) -------------------------
# PreToolUse sees the tool input, not the result. For Bash it uses the command
# string. UserPromptSubmit observes an explicit continuation request but does
# not increment tool_calls/iterations. PreToolUse never sees a
# file diff, a commit oid, or an error message.  The H1 spec lists four progress
# signals (commit / file change / new tool type / new error type); this hook
# approximates the first two from the command text and implements neither of the
# last two:
#   progress   — the command matches a write/commit verb (git commit|add|apply|…,
#                editors, patch, tee, touch, mkdir, cp, mv, sed -i, or a `>`/`>>`
#                redirect to a path other than /dev/null).  This is an *intent*
#                signal, not an outcome signal: a `git commit` that fails still
#                refreshes last_progress_ts.  `2>/dev/null` and `>/dev/null` are
#                excluded so that ordinary read-only commands do not read as
#                progress.
#   repetition — sha256(command) equal to the previous command's increments
#                same_cmd_streak; any different command resets it to 1.
# "new tool type" and "new error type" are NOT implemented — they are not
# observable at this hook point.  Consequence: an agent looping over a *varying*
# set of useless read-only commands is not caught by rule (a); only (b)
# budget-cap stops it.
#
# `iterations` is likewise a proxy.  The delegation contract's 最大反復 means
# implement→test loops, which are not visible here.  What is counted instead is
# **repeated-command tool calls**: iterations increments only when a command
# repeats the immediately preceding one.  Varied work never advances it; a
# retry loop (pv2 PV2-5 "same grep repeated 7x") does.
#
# --- SPEND --------------------------------------------------------------------
# The official hook payload's transcript_path selects the active rollout.
# Its JSONL contents are not a stable API. Prefer new token_usage_record rows
# (response_id deduplicates repeated rows); assign each row using turn_context
# model or the observed UserPromptSubmit turn model. A per-file cursor avoids
# rereading old records. If records are absent, use the CHANGE in the cumulative
# total_token_usage counter; if the transcript is missing, estimate by tool
# calls. budget_source labels each path and any uncertainty. spend_usd is an
# estimated lifetime total, not an invoice. A clear user continuation plus a
# session/model transition starts a budget epoch; only epoch spend is capped.
# Old last_block_rule remains history, not the current verdict.
# An unknown model is never treated as free: it is billed at the most expensive
# known rate and budget_source is annotated "unknown-model:<name>@max-rate".
#
# --- FIRING CONDITIONS ---------------------------------------------------------
#   block (a) no-progress-timeout : now-max(last_progress_ts,run_start) > timeout
#                                   AND same_cmd_streak >= 3
#   block (b) budget-cap          : budget_epoch_spend_usd >= budget_usd
#   block (c) max-iterations      : iterations > max_iterations
#   warn      budget-warn-80      : epoch spend >= 80% of budget (once per epoch)
#   warn      no-progress-timeout : same command 3 consecutive (before (a) trips)
#   warn      heartbeat           : no heartbeat for 30 min
#   measure   heartbeat           : every 15 min or 20 tool calls
#
# C4 適用限界 (短時間対話セッションには適用しない): all three block rules are
# self-limiting on short sessions — (a) needs a 45-minute progress gap, (b) needs
# an estimated $25 epoch burn on a restricted model, (c) needs 10 repeated
# commands.  No separate session-length
# knob is introduced.
#
# --- 廃止条件 (H1 spec) --------------------------------------------------------
# 誤停止率 (label:fp among blocks) > 30%/quarter → double the timeout values.
# Two consecutive quarters → demote block to warn and redesign.
# =============================================================================
set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/aidd-ledger.sh"
if [ ! -f "$_LEDGER_LIB" ]; then
  # Deployed layout: ~/.codex/hooks/h1-stall-runtime.sh with the Claude Code
  # hooks tree carrying the shared library.
  _LEDGER_LIB="$HOME/.claude/hooks/lib/aidd-ledger.sh"
fi
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

input=$(cat)
h1_event=$(printf '%s' "$input" | jq -r '.hook_event_name // "PreToolUse"' 2>/dev/null || true)
[[ "$h1_event" == "PreToolUse" || "$h1_event" == "UserPromptSubmit" ]] || { printf '%s\n' '{}'; exit 0; }

emit_allow() {
  printf '%s\n' '{}'
  exit 0
}

emit_deny() {
  local msg="$1"
  jq -n --arg m "$msg" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }' 2>/dev/null || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$msg"
  exit 0
}

command -v python3 >/dev/null 2>&1 || emit_allow

h1_cmd=$(printf '%s' "$input" | jq -r '
  .tool_input.command
  // .tool_input.cmd
  // .tool_input.shell_command
  // .command
  // .cmd
  // empty
' 2>/dev/null || true)
# Best-effort session id.  Whether Codex populates any of these on the hook
# payload is UNVERIFIED against a live run; CODEX_H1_DELEGATION is the
# authoritative id and the wrappers always export it.
h1_sid=$(printf '%s' "$input" | jq -r '
  .session_id // .sessionId // .session.id // empty
' 2>/dev/null || true)
h1_model=$(printf '%s' "$input" | jq -r '.model // empty' 2>/dev/null || true)
h1_turn=$(printf '%s' "$input" | jq -r '.turn_id // empty' 2>/dev/null || true)
h1_transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
# Only the boolean is passed to the decision core. Raw user text is never put
# in state or the H6 ledger. The transition and the user request must BOTH be
# present before an epoch is granted; model/session change alone is insufficient.
h1_resume_intent=$(printf '%s' "$input" | jq -r '
  (.prompt // "" | gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
  test("^(?:(?:作業を|実装を)?続けて(?:実装して)?(?:ください|下さい|お願いします)|(?:作業を)?(?:再開|続行)して(?:ください|下さい|お願いします)|引き続き実装してください|進めて(?:ください|下さい)?|OK[、,]?(?:では)?進めて|モデルを[A-Za-z0-9_.-]+に変更したので[、,]?続けて(?:ください|下さい)|H1予算をリセットして(?:続けて|再開して|続行して)(?:ください|下さい)|(?:please[[:space:]]+)?continue(?: the work| the implementation| implementation)?|(?:please[[:space:]]+)?resume(?: the work| the implementation| implementation)?|proceed)[。！!.]*$"; "i")
' 2>/dev/null || true)
# 北極星の分子（repo/branch 結合キー, aidd-governance#155）を決める cwd。
# 2026-09-04 実測: ~/.codex/hooks.json は CODEX_H1_CWD を渡さないので os.getcwd() に
# 落ち、実セッション 5 件中 2 件で repo が空だった。payload に cwd 系の欄があれば
# それを優先する。
# 2026-09-05 実 Codex（codex-cli 0.151.0）で確定: top-level キーは `cwd`。
#   payload_keys=cwd,hook_event_name,model,permission_mode,session_id,tool_input,
#                tool_name,tool_use_id,transcript_path,turn_id
# 候補列は `.cwd` だけに絞った（#383 で広く取っていた .workdir / .working_directory 系は
# 実在しない）。CODEX_H1_DEBUG_LOG が設定されているときは payload の top-level キーと
# 採用元を stderr へ出す。キー名が変わったらそこで分かる。
h1_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
h1_keys=$(printf '%s' "$input" | jq -r 'if type=="object" then (keys|join(",")) else empty end' 2>/dev/null || true)

verdict=$(H1_CMD="${h1_cmd:-}" H1_SID="${h1_sid:-}" H1_CWD="${h1_cwd:-}" H1_KEYS="${h1_keys:-}" \
  H1_EVENT="${h1_event:-}" H1_MODEL="${h1_model:-}" H1_TURN="${h1_turn:-}" \
  H1_TRANSCRIPT="${h1_transcript:-}" H1_RESUME_INTENT="${h1_resume_intent:-false}" \
  python3 - <<'PY' 2>>"${CODEX_H1_DEBUG_LOG:-/dev/null}"
import hashlib
import fcntl
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

NOW = int(time.time())
CMD = os.environ.get("H1_CMD", "")
PAYLOAD_CWD = os.environ.get("H1_CWD", "")
PAYLOAD_KEYS = os.environ.get("H1_KEYS", "")
SID = os.environ.get("H1_SID", "")
EVENT = os.environ.get("H1_EVENT", "PreToolUse")
PAYLOAD_MODEL = os.environ.get("H1_MODEL", "")
TURN_ID = os.environ.get("H1_TURN", "")
TRANSCRIPT_PATH = os.environ.get("H1_TRANSCRIPT", "")
RESUME_INTENT = os.environ.get("H1_RESUME_INTENT") == "true"


def env_num(name, default, cast=float):
    try:
        value = cast(os.environ[name])
    except (KeyError, TypeError, ValueError):
        return default
    return value if value >= 0 else default


# 既定 $5 は 2026-09-02 に通常作業を止めた（301 tool call で spend=$5.34）。
# block は RESTRICTED_MODELS のみに掛かるようになったが、その最上位モデルも
# PRICES に無く MAX_RATE で見積もられるため、$5 のままでは制限対象モデルの
# 正当な作業まで止まる。通常セッション実測 $5.34 の約 5 倍を既定にし、
# 暴走（2026-09-01 は 1 レーンで 88.8M tokens）は依然捕まえる。
BUDGET_USD = env_num("CODEX_H1_BUDGET_USD", 25.0)
MAX_ITERATIONS = int(env_num("CODEX_H1_MAX_ITERATIONS", 10.0))
NO_PROGRESS_SEC = int(env_num("CODEX_H1_NO_PROGRESS_SEC", 2700.0))
HEARTBEAT_SEC = int(env_num("CODEX_H1_HEARTBEAT_SEC", 900.0))
HEARTBEAT_CALLS = int(env_num("CODEX_H1_HEARTBEAT_CALLS", 20.0))
WARN_GAP_SEC = int(env_num("CODEX_H1_WARN_GAP_SEC", 1800.0))
SAME_CMD_THRESHOLD = 3

# --- token → USD -------------------------------------------------------------
# USD per 1,000,000 tokens as (uncached_input, cached_input, output).
# Source: OpenAI public API pricing (https://openai.com/api/pricing), gpt-5
# family rates as recorded 2026-09-01.  These are NOT fetched at runtime and go
# stale when OpenAI changes a rate — override with CODEX_H1_PRICE_IN /
# CODEX_H1_PRICE_CACHED_IN / CODEX_H1_PRICE_OUT.  Codex on this machine runs
# gpt-5.6-luna, which is absent from this table on purpose: the unknown-model
# path below is the normal path, not an edge case.
PRICES = {
    "gpt-5-codex": (1.25, 0.125, 10.00),
    "gpt-5-mini": (0.25, 0.025, 2.00),
    "gpt-5-nano": (0.05, 0.005, 0.40),
    "gpt-5": (1.25, 0.125, 10.00),
}
# Unknown model → most expensive known rate.  Never silently treat it as free.
MAX_RATE = max(PRICES.values(), key=lambda rate: rate[2])

# --- どのモデルを止めるか（2026-09-02 のインシデントで設計変更） -----------------
# 当初は全モデルに一律 $5 の上限をかけていた。実測でそれが通常作業を止めた:
# 通常の Codex セッションが 301 tool call で spend=$5.34 に達して block し、
# Google Drive の再読込とローカルファイル操作の直前で作業が停止した。
#
# 原因は 2 つが重なったこと。
#   (1) この機械の Codex は gpt-5.6-luna を動かすが PRICES に無く、unknown-model
#       経路が MAX_RATE（既知で最も高い単価）で見積もる。上のコメント自身が
#       「unknown-model 経路は normal path であって edge case ではない」と
#       書いているのに、その normal path を最高単価で評価していた。
#   (2) そもそも全モデルを止める必要が無い。実際に予算を溶かしたのは常に
#       最上位モデル（gpt-5.6-sol の ultra）であって、それ以外ではない。
#
# したがって block はモデルで絞る。既定は名前に "sol" を含むモデル。
# 一致しないモデル（未検出を含む）では block 条件を一切評価せず、measure と
# warn だけ残す。未検出で止めないのは意図的である — 「分からないから止める」は
# 今回まさに実作業を止めた側であり、暴走の実績があるのは最上位モデルだけ。
RESTRICTED_MODELS = [
    token.strip().lower()
    for token in (os.environ.get("CODEX_H1_RESTRICTED_MODELS") or "sol").split(",")
    if token.strip()
]


def is_restricted(model):
    """True only when the model is one we deliberately cap.

    "*" restricts every model including an undetected one. It exists so the
    falsification suite can still exercise the block rules directly, and as an
    opt-in for anyone who wants the old blanket behaviour back. It is NOT the
    default: a blanket cap is what stopped real work on 2026-09-02.
    """
    if "*" in RESTRICTED_MODELS:
        return True
    name = (model or "").lower()
    if not name:
        return False
    return any(token in name for token in RESTRICTED_MODELS)

WRITE_VERB_RE = re.compile(
    r"(?:^|[;&|]\s*|\s)(?:"
    r"git\s+(?:commit|add|apply|am|cherry-pick|revert|merge|rebase|tag|mv|rm|stash)\b"
    r"|(?:sed|perl)\s+(?:-[^\s]*\s+)*-i\b"
    r"|(?:vi|vim|nano|emacs|ed|patch|tee|touch|mkdir|cp|mv|install|dd)\b"
    r")"
)
# `>` or `>>` to a real path.  Excludes 2>, &>, >&, and /dev/null so that a
# plain read-only command with `2>/dev/null` is not misread as progress.
REDIRECT_RE = re.compile(r"(?<![0-9&>])>{1,2}(?![&>])\s*(?!/dev/null)[^\s|&;>]")


def iso(ts):
    if not ts:
        return ""
    return datetime.fromtimestamp(int(ts), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_progress(cmd):
    return bool(cmd) and bool(WRITE_VERB_RE.search(cmd) or REDIRECT_RE.search(cmd))


def resolve_delegation():
    raw = os.environ.get("CODEX_H1_DELEGATION") or SID or "default"
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", raw)[:120]
    return raw, (safe or "default")


# 北極星「着地 PR 数 / 消費予算」の**分子**を後から結合するためのキー
# (aidd-governance#155)。
#
# H1 は spend（分母）を記録していたが、どのリポジトリのどのブランチで作業していたかを
# 記録していなかった。そのため ADR-005 の反証条件 2「H1 が発火したが着地 PR が 0 本」を
# **計算できない**。2026-09-03 実測で block した実運用委任 3 件も、rollout が
# ~/.codex/archived_sessions/ に残っておらず事後の復元ができなかった。
#
# ここで作るのは結合キーだけである。PR の収集も集計もしない。
# 記録した branch に対して `gh pr list --head <branch>` を後から回せばよい。
#
# subprocess は使わない。`.git` を直接読むので PATH に依存せず、タイムアウトも要らず、
# hook の 1 回あたりの遅延をほぼ増やさない。git が無い環境でも壊れない。
MAX_BRANCHES = 20


def _git_dir_of(root):
    """`.git` がディレクトリならそれ、ファイル(worktree)なら gitdir: の指す先。"""
    dot = root / ".git"
    if dot.is_dir():
        return dot
    try:
        text = dot.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return None
    if text.startswith("gitdir:"):
        target = Path(text.split(":", 1)[1].strip())
        if not target.is_absolute():
            target = (root / target).resolve()
        return target
    return None


def resolve_worktree():
    """(repo, branch) を返す。決められなければ ("", "")。

    repo は git root の basename。branch は refs/heads/<name>、detached なら
    "detached:<短縮 sha>"。**例外を投げない** — この関数のために H1 が落ちると、
    ガバナが自分の計測のために停止することになる。
    """
    # 優先順: 明示 env > payload の cwd 欄 > プロセスの cwd。
    # getcwd() は hook プロセスの起動場所であって委任の作業場所とは限らない
    # （2026-09-04 実測で実セッションの 40% が空になった原因）。
    if os.environ.get("CODEX_H1_CWD"):
        start, source = os.environ["CODEX_H1_CWD"], "env"
    elif PAYLOAD_CWD:
        start, source = PAYLOAD_CWD, "payload"
    else:
        start, source = os.getcwd(), "getcwd"
    # CODEX_H1_DEBUG_LOG が無ければ stderr は /dev/null なのでコストは無い。
    print("H1-DEBUG cwd_source=%s start=%s payload_keys=%s" % (source, start, PAYLOAD_KEYS), file=sys.stderr)
    try:
        cur = Path(start).resolve()
    except (OSError, ValueError):
        return "", ""
    root = None
    for cand in [cur] + list(cur.parents):
        if (cand / ".git").exists():
            root = cand
            break
    if root is None:
        return "", ""
    gitdir = _git_dir_of(root)
    if gitdir is None:
        return root.name, ""
    try:
        head = (gitdir / "HEAD").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return root.name, ""
    if head.startswith("ref:"):
        ref = head.split(":", 1)[1].strip()
        return root.name, ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
    if re.fullmatch(r"[0-9a-f]{7,40}", head):
        return root.name, "detached:" + head[:12]
    return root.name, ""


def record_worktree(state):
    """委任がどこで作業したかを state に積む。判定には一切使わない。"""
    repo, branch = resolve_worktree()
    if repo and not state.get("repo"):
        state["repo"] = repo
    if not branch:
        return
    if not state.get("branch_start"):
        state["branch_start"] = branch
    seen = state.get("branches")
    if not isinstance(seen, list):
        seen = []
    if branch not in seen and len(seen) < MAX_BRANCHES:
        seen.append(branch)
    state["branches"] = seen


def state_path(slug):
    base = os.environ.get("CODEX_H1_STATE_DIR") or str(
        Path.home() / ".codex" / "hooks" / "h1-state"
    )
    return Path(base) / (slug + ".json")


def load_state(path, delegation):
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(state, dict):
            raise ValueError("state must be an object")
    except (OSError, ValueError):
        state = {}
    defaults = {
        "delegation": delegation,
        "started_ts": NOW,
        "last_progress_ts": NOW,
        "iterations": 0,
        "tool_calls": 0,
        "spend_tokens": 0,
        "spend_usd": 0.0,
        "budget_usd": BUDGET_USD,
        "budget_source": "unknown",
        "max_iterations": MAX_ITERATIONS,
        "no_progress_sec": NO_PROGRESS_SEC,
        "last_cmd_sha256": "",
        "same_cmd_streak": 0,
        "last_warn_80": 0,
        "last_heartbeat_ts": 0,
        "last_block_rule": "",
        "last_block_ts": 0,
        "budget_epoch": 0,
        "budget_epoch_spend_usd": 0.0,
        "budget_epoch_baseline_tokens": 0,
        "budget_epoch_reason": "",
        "last_reset_turn_id": "",
        "session_id": "",
    }
    for key, value in defaults.items():
        state.setdefault(key, value)
    # Contract values always follow the current environment so that a delegation
    # contract can tighten limits on a resumed run.
    state["budget_usd"] = BUDGET_USD
    state["max_iterations"] = MAX_ITERATIONS
    state["no_progress_sec"] = NO_PROGRESS_SEC
    return state


def find_rollout(started_ts):
    """Locate this delegation's Codex transcript.

    Preference order, most to least trustworthy:
      1. CODEX_H1_ROLLOUT — an explicit path.
      2. The session id, when the hook payload carried one.
      3. CODEX_H1_CWD — the working directory the wrapper passed to `codex -C`.
         Every codex-parallel delegation gets its own worktree, so this is what
         keeps three parallel delegations from reading each other's spend.
      4. Newest mtime.  This is a guess whenever more than one Codex process is
         running; it is the last resort, not the normal path.
    """
    override = TRANSCRIPT_PATH or os.environ.get("CODEX_H1_ROLLOUT")
    if override:
        path = Path(override)
        return path if path.is_file() else None
    root = Path(os.environ.get("CODEX_H1_SESSIONS_DIR") or (Path.home() / ".codex" / "sessions"))
    if not root.is_dir():
        return None
    if SID:
        matches = sorted(root.glob("*/*/*/rollout-*-%s.jsonl" % SID))
        if matches:
            return matches[-1]
    day = datetime.now().strftime("%Y/%m/%d")
    candidates = []
    for scope in (root / day, root):
        if scope.is_dir():
            candidates = [p for p in scope.glob("**/rollout-*.jsonl") if p.is_file()]
        if candidates:
            break
    if not candidates:
        return None
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    cwd = os.environ.get("CODEX_H1_CWD")
    if cwd:
        needle = '"cwd":%s' % json.dumps(cwd)
        for path in candidates[:20]:
            if path.stat().st_mtime + 60 < started_ts:
                continue
            if needle in read_chunk(path, head_bytes=65_536).replace('"cwd": "', '"cwd":"'):
                return path
    return candidates[0]


def read_chunk(path, tail_bytes=0, head_bytes=0):
    try:
        with path.open("rb") as stream:
            if head_bytes:
                return stream.read(head_bytes).decode("utf-8", "replace")
            size = path.stat().st_size
            if size > tail_bytes:
                stream.seek(size - tail_bytes)
            return stream.read().decode("utf-8", "replace")
    except OSError:
        return ""


def rate_for(model):
    """Longest known prefix wins, but only on a name boundary.

    "gpt-5-2025-08-07" is gpt-5; "gpt-5.6-luna" is NOT — it is a different
    model that merely shares five characters, and pricing it as gpt-5 would
    be a silent guess.  Unknown models fall through to the most expensive
    known rate and say so in budget_source.
    """
    if not model:
        return MAX_RATE, "unknown-model:none@max-rate"
    for name in sorted(PRICES, key=len, reverse=True):
        if model == name:
            return PRICES[name], ""
        if model.startswith(name) and model[len(name)] in "-_":
            return PRICES[name], ""
    return MAX_RATE, "unknown-model:%s@max-rate" % model[:40]


def usd_from(usage, model):
    (rate_in, rate_cached, rate_out), note = rate_for(model)
    rate_in = env_num("CODEX_H1_PRICE_IN", rate_in)
    rate_cached = env_num("CODEX_H1_PRICE_CACHED_IN", rate_cached)
    rate_out = env_num("CODEX_H1_PRICE_OUT", rate_out)
    cached = max(0, int(usage.get("cached_input_tokens", 0) or 0))
    total_in = max(0, int(usage.get("input_tokens", 0) or 0))
    uncached = max(0, total_in - cached)
    out = max(0, int(usage.get("output_tokens", 0) or 0))
    usd = (uncached * rate_in + cached * rate_cached + out * rate_out) / 1_000_000.0
    return round(usd, 6), note


def measure_spend(tool_calls, started_ts, state=None):
    """Return (tokens, usd, budget_source)."""
    path = find_rollout(started_ts)
    if path is not None:
        tail = read_chunk(path, tail_bytes=262_144)
        blocks = re.findall(r'"total_token_usage":\s*(\{[^}]*\})', tail)
        head = read_chunk(path, head_bytes=65_536)
        models = re.findall(r'"model"\s*:\s*"([^"]+)"', head + tail)
        if blocks:
            try:
                usage = json.loads(blocks[-1])
            except ValueError:
                usage = {}
            if usage:
                model = PAYLOAD_MODEL or (models[-1] if models else "")
                usd, note = usd_from(usage, model)
                source = "rollout:total_token_usage"
                if note:
                    source += "+" + note
                return int(usage.get("total_tokens", 0) or 0), usd, source, model, usage
        prior = (state or {}).get("usage_snapshot")
        if isinstance(prior, dict):
            model = PAYLOAD_MODEL or (state or {}).get("model", "")
            usd, _note = usd_from(prior, model)
            return int(prior.get("total_tokens", 0) or 0), usd, "rollout:last-observed-total", model, prior
    # Fallback: no transcript.  Estimate from tool calls at a documented rough
    # per-call token figure and label the number as an estimate everywhere.
    # 20k tokens/call is calibrated on the 2026-09-01 measurement: 790,087,141
    # tokens over 71 sessions ≈ 11.1M per session, and the one session inspected
    # in full carried 11.8M tokens over roughly 500 calls.
    # Tokens are priced at the *input* rate, not a blend: the same measurement
    # put input:output at 226:1, so the blended per-token cost
    # ((226·rate_in + rate_out)/227) rounds to rate_in.  This under-counts the
    # cache discount and over-counts output — it is an estimate, and every
    # ledger row carries budget_source="proxy:toolcalls" to say so.
    per_call = env_num("CODEX_H1_PROXY_TOKENS_PER_CALL", 20000.0)
    tokens = int(tool_calls * per_call)
    (rate_in, _cached, _rate_out), _note = rate_for("")
    rate_in = env_num("CODEX_H1_PRICE_IN", rate_in)
    usd = round(tokens * rate_in / 1_000_000.0, 6)
    return tokens, usd, "proxy:toolcalls", PAYLOAD_MODEL, None


def usage_records(path, state):
    """Best-effort per-response costs from the unstable rollout format.

    The official hook payload (model/session/turn/transcript_path) selects the
    active run. The transcript is only a metering source. A response_id is
    charged once even when token_count rows or continuation files repeat it.
    """
    if path is None:
        return []
    key = str(path.resolve())
    try:
        size = path.stat().st_size
    except OSError:
        return []
    previous_path = state.get("meter_path")
    previous_offset = int(state.get("meter_offset") or 0)
    # Existing states were priced from cumulative total_token_usage. Scanning
    # their old records as new responses would double-charge them. Start at
    # EOF once, keeping prior spend and marking the migration as an estimate.
    if not previous_path and float(state.get("spend_usd") or 0) > 0 \
            and "charged_response_ids" not in state:
        state["meter_path"] = key
        state["meter_offset"] = size
        state["charged_response_ids"] = []
        state["meter_mode"] = "record"
        state["budget_source"] = "rollout:legacy-record-baseline-estimate"
        return []
    start = previous_offset if previous_path == key and previous_offset <= size else 0
    turn_models = state.get("turn_models")
    if not isinstance(turn_models, dict):
        turn_models = {}
    records = []
    try:
        with path.open("rb") as stream:
            stream.seek(start)
            cursor = start
            for raw in stream:
                if not raw.endswith(b"\n"):
                    break  # Leave an incomplete JSONL line for the next hook.
                cursor = stream.tell()
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                payload = row.get("payload") or {}
                if not isinstance(payload, dict):
                    continue
                if row.get("type") == "turn_context":
                    if payload.get("turn_id") and payload.get("model"):
                        turn_models[payload["turn_id"]] = payload["model"]
                    continue
                if row.get("type") != "token_usage_record":
                    continue
                usage = payload.get("usage")
                if not isinstance(usage, dict):
                    continue
                rid = payload.get("response_id") or row.get("response_id")
                if not rid:
                    rid = "sha256:" + hashlib.sha256(raw).hexdigest()
                thread = payload.get("thread_token_usage") or {}
                thread_total = int(thread.get("total_tokens", 0) or 0) if isinstance(thread, dict) else 0
                turn = payload.get("turn_id") or payload.get("root_turn_id") or ""
                records.append((str(rid), usage, thread_total, turn, turn_models.get(turn, "")))
            state["meter_offset"] = cursor
    except OSError:
        return []
    state["meter_path"] = key
    state["turn_models"] = dict(list(turn_models.items())[-128:])
    return records


def persist_state(path, state):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            json.dump(state, stream, ensure_ascii=False)
            temp = stream.name
        os.replace(temp, path)
    except OSError:
        pass


def apply_meter(state, records, measured):
    tokens, absolute_usd, source, model, usage = measured
    state["model"] = model
    state["session_id"] = SID or state.get("session_id", "")
    delta_usd = 0.0
    if records:
        state["meter_mode"] = "record"
        seen = set(state.get("charged_response_ids") or [])
        if "charged_response_ids" not in state and float(state.get("spend_usd") or 0) > 0:
            # Migration from the old cumulative-price state: these records may
            # already be included in spend_usd. Mark them as observed without
            # charging a second time. Future response ids are charged once.
            state["charged_response_ids"] = [rid for rid, _, _, _, _ in records]
            state["budget_source"] = "rollout:legacy-record-baseline-estimate"
            state["spend_tokens"] = max(tokens, state.get("spend_tokens", 0))
            state["model"] = model
            state["session_id"] = SID or state.get("session_id", "")
            state["budget_epoch_spend_usd"] = (
                state.get("budget_epoch_spend_usd", 0.0) if state.get("budget_epoch")
                else state["spend_usd"]
            )
            return
        added = 0
        uncertain_model = False
        unknown_rate = False
        recorded_components = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
        for rid, response_usage, thread_total, turn, record_model in records:
            if rid in seen:
                continue
            seen.add(rid)
            turn_model = (state.get("turn_models") or {}).get(turn, "")
            resolved_model = record_model
            if not resolved_model:
                resolved_model = turn_model or model
                uncertain_model = uncertain_model or not bool(turn_model)
            cost, _note = usd_from(response_usage, resolved_model)
            unknown_rate = unknown_rate or bool(_note)
            delta_usd += cost
            added += 1
            for key in recorded_components:
                recorded_components[key] += int(response_usage.get(key, 0) or 0)
            if thread_total:
                tokens = max(tokens, thread_total)
                if state.get("budget_epoch") and not state.get("budget_epoch_baseline_record_tokens"):
                    state["budget_epoch_baseline_record_tokens"] = max(
                        0, thread_total - int(response_usage.get("total_tokens", 0) or 0)
                    )
        pending_usd = float(state.get("meter_gap_estimate_usd") or 0)
        pending_tokens = int(state.get("meter_gap_estimate_tokens") or 0)
        recorded_tokens = recorded_components["input_tokens"] + recorded_components["output_tokens"]
        prior_usage = state.get("usage_snapshot")
        # The current cumulative increase may represent fresh responses in
        # this very batch. Reserve it before assigning delayed records to an
        # older estimate. If either snapshot is missing, the overlap cannot be
        # proved, so retain the provisional charge conservatively.
        current_event_tokens = recorded_tokens
        current_event_cost = 0.0
        if isinstance(usage, dict) and isinstance(prior_usage, dict):
            current_event_tokens = max(
                0, int(usage.get("total_tokens", 0) or 0)
                - int(prior_usage.get("total_tokens", 0) or 0)
            )
            current_event_cost, _note = usd_from({
                key: max(0, int(usage.get(key, 0) or 0)
                         - int(prior_usage.get(key, 0) or 0))
                for key in ("input_tokens", "cached_input_tokens", "output_tokens")
            }, model)
        provisional = 0.0
        if added and pending_usd and pending_tokens and recorded_tokens:
            settle_tokens = min(pending_tokens, max(0, recorded_tokens - current_event_tokens))
            # Never subtract more than the actual new response charge. Unknown
            # model/rate differences then remain conservatively in the budget.
            provisional = min(
                pending_usd, delta_usd,
                round(pending_usd * settle_tokens / pending_tokens, 6),
            )
            state["meter_gap_estimate_usd"] = round(pending_usd - provisional, 6)
            state["meter_gap_estimate_tokens"] = pending_tokens - settle_tokens
        if provisional:
            delta_usd -= provisional
        state["charged_response_ids"] = list(seen)
        state.pop("budget_epoch_pending_baseline", None)
        partial_gap = 0.0
        if isinstance(usage, dict):
            prior = prior_usage
            if isinstance(prior, dict):
                missing = {
                    key: max(0, int(usage.get(key, 0) or 0)
                             - int(prior.get(key, 0) or 0) - recorded_components[key])
                    for key in recorded_components
                }
                if missing["input_tokens"] or missing["output_tokens"]:
                    partial_gap, _note = usd_from(missing, model)
                    delta_usd += partial_gap
                    state["meter_gap_estimate_usd"] = round(
                        float(state.get("meter_gap_estimate_usd") or 0) + partial_gap, 6
                    )
                    state["meter_gap_estimate_tokens"] = int(state.get("meter_gap_estimate_tokens") or 0) + max(
                        0, missing["input_tokens"] + missing["output_tokens"]
                    )
            state["usage_snapshot"] = usage
        # A late response can have a cheaper model than a fresh response whose
        # cumulative tokens arrived without a record. The current interval's
        # event estimate is an independent lower bound on its cost.
        event_floor = max(0.0, round(current_event_cost - delta_usd, 6))
        if event_floor:
            delta_usd += event_floor
        state["budget_source"] = (
            "rollout:token_usage_record"
            + ("+model-attribution-estimate" if uncertain_model else "")
            + ("+unknown-model-max-rate" if unknown_rate else "")
            + ("+reconciled-gap-estimate" if provisional else "")
            + ("+partial-record-gap-estimate" if partial_gap else "")
            + ("+event-price-floor-estimate" if event_floor else "")
            if added or partial_gap or event_floor else state.get("budget_source", source)
        )
    elif state.get("meter_mode") == "record":
        # A turn can call several tools without a new model response. If the
        # cumulative counter advances without records, estimate only its delta
        # and label it; never add the full lifetime total again.
        previous = state.get("usage_snapshot")
        if isinstance(usage, dict):
            if isinstance(previous, dict):
                delta = {
                    key: max(0, int(usage.get(key, 0) or 0) - int(previous.get(key, 0) or 0))
                    for key in ("input_tokens", "cached_input_tokens", "output_tokens")
                }
                delta_usd, _note = usd_from(delta, model)
                observed = max(0, int(usage.get("total_tokens", 0) or 0) - int(previous.get("total_tokens", 0) or 0))
                if observed:
                    state["meter_gap_estimate_tokens"] = int(state.get("meter_gap_estimate_tokens") or 0) + observed
            elif int(state.get("tool_calls") or 0) > 1:
                state["budget_source"] = "rollout:record-gap-unverified"
            state["usage_snapshot"] = usage
        else:
            per_call = env_num("CODEX_H1_PROXY_TOKENS_PER_CALL", 20000.0)
            delta_usd, _note = usd_from({"input_tokens": int(per_call)}, model)
            state["budget_source"] = "proxy:record-gap-estimate"
        if delta_usd:
            state["meter_gap_estimate_usd"] = round(
                float(state.get("meter_gap_estimate_usd") or 0) + delta_usd, 6
            )
            if isinstance(usage, dict):
                state["budget_source"] = "rollout:total_token_usage+record-gap-estimate"
    elif isinstance(usage, dict):
        previous = state.get("usage_snapshot")
        if state.pop("budget_epoch_pending_baseline", False):
            # No response records: this is a lower-confidence fallback. The
            # inherited total is excluded, and the omission is labeled.
            previous = usage
            state["budget_source"] = source + "+pending-baseline-estimate"
        elif isinstance(previous, dict):
            delta = {
                key: max(0, int(usage.get(key, 0) or 0) - int(previous.get(key, 0) or 0))
                for key in ("input_tokens", "cached_input_tokens", "output_tokens")
            }
            delta_usd, _note = usd_from(delta, model)
            state["budget_source"] = source + "+delta"
        else:
            delta_usd = absolute_usd
            state["budget_source"] = source
        state["usage_snapshot"] = usage
    else:
        previous = float(state.get("proxy_spend_usd") or 0)
        delta_usd = max(0.0, absolute_usd - previous)
        state["proxy_spend_usd"] = absolute_usd
        state["budget_source"] = source
    state["spend_usd"] = max(0.0, round(float(state.get("spend_usd") or 0) + delta_usd, 6))
    state["spend_tokens"] = tokens
    if state.get("budget_epoch"):
        state["budget_epoch_spend_usd"] = max(0.0, round(
            float(state.get("budget_epoch_spend_usd") or 0) + delta_usd, 6
        ))
    else:
        state["budget_epoch_spend_usd"] = state["spend_usd"]


def resume_epoch(state, path):
    if not RESUME_INTENT or not SID or not TURN_ID:
        return None
    if state.get("last_reset_turn_id") == TURN_ID and state.get("last_reset_session_id") == SID:
        return None
    previous_sid = state.get("session_id") or state.get("first_prompt_session_id") or ""
    previous_model = state.get("model") or state.get("first_prompt_model") or ""
    if previous_sid and previous_sid != SID:
        reason = "explicit-user-resume:session"
    elif previous_model and PAYLOAD_MODEL and previous_model != PAYLOAD_MODEL:
        reason = "explicit-user-resume:model"
    elif not previous_sid and int(state.get("tool_calls") or 0) == 0:
        reason = "explicit-user-resume:new-session"
    else:
        return None
    transcript = find_rollout(int(state["started_ts"]))
    records = usage_records(transcript, state)
    measured = measure_spend(int(state.get("tool_calls") or 0), int(state["started_ts"]), state)
    if int(state.get("tool_calls") or 0) > 0 or float(state.get("spend_usd") or 0) > 0:
        # Charge responses generated after the previous tool and before this
        # user prompt to the OLD epoch. Then start the new budget interval.
        apply_meter(state, records, measured)
    else:
        # Fresh fork state: inherited history is the baseline, never a charge.
        seen = set(state.get("charged_response_ids") or [])
        seen.update(rid for rid, _, _, _, _ in records)
        state["charged_response_ids"] = list(seen)
        if records:
            state["meter_mode"] = "record"
    # Provisional costs belong to the old epoch. Future responses must never
    # subtract them from a newly granted budget interval.
    state.pop("meter_gap_estimate_usd", None)
    state.pop("meter_gap_estimate_tokens", None)
    baseline = max((total for _, _, total, _, _ in records), default=0)
    if not baseline:
        baseline = max(int(state.get("spend_tokens") or 0), measured[0])
        if isinstance(measured[4], dict):
            state["usage_snapshot"] = measured[4]
            state["budget_epoch_pending_baseline"] = False
        else:
            # No stable usage sample yet. A later record is still counted;
            # only the total_token_usage fallback needs a deferred baseline.
            state["budget_epoch_pending_baseline"] = True
    else:
        state["budget_epoch_pending_baseline"] = False
    state["budget_epoch"] = int(state.get("budget_epoch") or 0) + 1
    state["budget_epoch_spend_usd"] = 0.0
    state["budget_epoch_baseline_tokens"] = baseline
    state["budget_epoch_baseline_record_tokens"] = 0
    state["budget_epoch_baseline_usd"] = float(state.get("spend_usd") or 0)
    state["budget_epoch_reason"] = reason
    if state.get("forced_stop") == "budget-cap":
        state.pop("forced_stop", None)
    state["last_reset_turn_id"] = TURN_ID
    state["last_reset_session_id"] = SID
    try:
        state["budget_epoch_scope_cwd"] = str(Path(
            os.environ.get("CODEX_H1_CWD") or PAYLOAD_CWD or os.getcwd()
        ).resolve())
    except (OSError, ValueError):
        state["budget_epoch_scope_cwd"] = ""
    state["session_id"] = SID
    state["model"] = PAYLOAD_MODEL or previous_model
    state["last_warn_80"] = 0
    return reason


def subject_of(state):
    subject = {
        "delegation": state["delegation"],
        "spend_usd": state["spend_usd"],
        "last_progress_ts": iso(state["last_progress_ts"]),
        "budget_usd": state["budget_usd"],
        "budget_source": state["budget_source"],
        "budget_epoch": state.get("budget_epoch", 0),
        "budget_epoch_spend_usd": state.get("budget_epoch_spend_usd", state["spend_usd"]),
        "budget_epoch_baseline_tokens": state.get("budget_epoch_baseline_tokens", 0),
        "budget_epoch_baseline_record_tokens": state.get("budget_epoch_baseline_record_tokens", 0),
        "budget_epoch_baseline_usd": state.get("budget_epoch_baseline_usd", 0),
        "budget_epoch_reason": state.get("budget_epoch_reason", ""),
        "iterations": state["iterations"],
        "tool_calls": state["tool_calls"],
        "same_cmd_streak": state["same_cmd_streak"],
        # どのモデルだったか / block 対象だったかを台帳から後で読めるようにする。
        # 空文字は「rollout から検出できなかった」であり、"制限外" と同義ではない
        # ことが分かるよう restricted と別欄で出す。
        "model": state.get("model", ""),
        "restricted": is_restricted(state.get("model")),
        # 北極星の分子への結合キー (aidd-governance#155)。
        # spend（分母）だけを記録していたので反証条件 2 が計算できなかった。
        # 空文字/空配列は「決められなかった」であり「PR が無い」ではない。
        "repo": state.get("repo", ""),
        "branch_start": state.get("branch_start", ""),
        "branches": state.get("branches", []),
    }
    # #87 要求 4「既存作用点へ統合する」— 意味分類が宣言されている委任では、
    # 台帳行に fingerprint / oracle / classification / epoch / close_target /
    # transition を機械可読で載せる。宣言がなければ欄ごと出さない。"unknown" で
    # 埋めると「分類していない」と「分類できなかった」が区別できなくなる。
    sem = state.get("h1_semantics")
    if isinstance(sem, dict) and sem.get("transition"):
        subject["iteration_semantics"] = {
            "failure_fingerprint": sem.get("last_fingerprint", ""),
            "oracle_id": sem.get("last_oracle_id", ""),
            "classification": sem.get("classification", ""),
            "epoch": sem.get("epoch", 1),
            "close_target": sem.get("close_target", ""),
            "transition": sem.get("transition", ""),
        }
    return subject


def iteration_verdict(state, effective):
    """反復上限到達時の 3 値遷移 (#87).

    意味分類の宣言が無ければ **従来どおり無条件 STOP** する。これは fail-safe
    であって手抜きではない: 宣言の省略で上限を無効化できるなら、この装置は
    「書かなければ止まらない」抜け道になる。分類は上限を緩める根拠ではなく、
    緩める資格を宣言して初めて検査対象になる、という向きにしてある。
    """
    sem = state.get("h1_semantics")
    sem = sem if isinstance(sem, dict) else {}
    transition = str(sem.get("transition") or "")
    cap = int(state["max_iterations"])
    base = "repeated-command iterations %d exceeded max %d" % (effective, cap)

    if transition == "REBASE_REQUIRED":
        return (
            "rebase-required",
            "%s / 意味進捗 (classification=%s epoch=%s fingerprint=%s). "
            "これは完了ではなく Issue close 可でもない。固定 scope・固定 close "
            "target のまま supervisor の rebase 承認を得てから再開すること。"
            % (
                base,
                sem.get("classification", ""),
                sem.get("epoch", 1),
                str(sem.get("last_fingerprint", ""))[:12],
            ),
        )
    note = {
        "STOP": "意味分類 = %s" % sem.get("classification", ""),
        # CONTINUE 宣言のままランタイム反復が上限を超えている = 宣言が実体から
        # 遅れている。宣言側を信じて通すのではなく、実体側で止める。
        "CONTINUE": "宣言は CONTINUE だがランタイム反復が上限超過（宣言が実体に追随していない）",
        "": "意味分類の宣言なし",
    }.get(transition, "未知の transition=%s" % transition)
    return ("max-iterations", "%s / %s" % (base, note))


def record(state, event, rule, detail):
    subject = subject_of(state)
    if rule == "budget-epoch-reset":
        subject["previous_budget_epoch"] = max(0, int(state.get("budget_epoch") or 0) - 1)
        subject["reset_turn_id"] = TURN_ID
        subject["reset_session_id"] = SID
        subject["scope_cwd"] = state.get("budget_epoch_scope_cwd", "")
    return {
        "component": "H1",
        "event": event,
        "rule": rule,
        "detail": detail,
        "subject": subject,
    }


def decide(state):
    """Return (rule, detail) for the first tripped block rule, else (None, None).

    block は RESTRICTED_MODELS に一致するモデルでのみ評価する。それ以外では
    どの条件も評価せず (None, None) を返す。measure / warn は従来どおり出るので
    消費は台帳から追える。制限対象を広げたいときは
    CODEX_H1_RESTRICTED_MODELS に カンマ区切りで部分文字列を渡す。
    """
    forced = state.get("forced_stop")
    if forced and forced != "budget-cap":
        return (forced, "wrapper stop remains active after budget epoch change")
    if not is_restricted(state.get("model")):
        return (None, None)
    gap = NOW - max(int(state["last_progress_ts"]), int(state.get("watchdog_started_ts") or 0))
    if gap > int(state["no_progress_sec"]) and int(state["same_cmd_streak"]) >= SAME_CMD_THRESHOLD:
        return (
            "no-progress-timeout",
            "%dmin no progress, same command repeated %dx"
            % (gap // 60, state["same_cmd_streak"]),
        )
    effective_spend = state.get("budget_epoch_spend_usd", state["spend_usd"])
    if state["budget_usd"] > 0 and effective_spend >= state["budget_usd"]:
        return (
            "budget-cap",
            "epoch spend $%.2f reached budget $%.2f (%s)"
            % (effective_spend, state["budget_usd"], state["budget_source"]),
        )
    # #87: 反復上限は epoch 基準線からの差で測る。rebase が granted された委任は
    # iteration_baseline が押し上げられており、新 epoch の反復だけが数えられる。
    # 宣言が無い委任では baseline=0 なので、従来と同じ絶対値比較に退化する。
    sem = state.get("h1_semantics")
    baseline = 0
    if isinstance(sem, dict):
        try:
            baseline = max(0, int(sem.get("iteration_baseline") or 0))
        except (TypeError, ValueError):
            baseline = 0
    effective = int(state["iterations"]) - baseline
    if effective > int(state["max_iterations"]):
        return iteration_verdict(state, effective)
    return (None, None)


def advisory(state, records, blocked):
    """Heartbeat + warn rows (appended whether or not the call is blocked)."""
    since_hb = NOW - int(state["last_heartbeat_ts"])
    if state["last_heartbeat_ts"] and since_hb > WARN_GAP_SEC:
        records.append(
            record(state, "warn", "heartbeat", "no heartbeat for %dmin" % (since_hb // 60))
        )
    if (
        state["budget_usd"] > 0
        and not state["last_warn_80"]
        and state.get("budget_epoch_spend_usd", state["spend_usd"]) >= 0.8 * state["budget_usd"]
    ):
        state["last_warn_80"] = NOW
        records.append(
            record(
                state,
                "warn",
                "budget-warn-80",
                "spend $%.2f is >=80%% of budget $%.2f"
                % (state.get("budget_epoch_spend_usd", state["spend_usd"]), state["budget_usd"]),
            )
        )
    if not blocked and int(state["same_cmd_streak"]) >= SAME_CMD_THRESHOLD:
        records.append(
            record(
                state,
                "warn",
                "no-progress-timeout",
                "same command repeated %dx" % state["same_cmd_streak"],
            )
        )
    due = not state["last_heartbeat_ts"] or since_hb >= HEARTBEAT_SEC
    due = due or (int(state["tool_calls"]) % HEARTBEAT_CALLS == 0)
    if due:
        state["last_heartbeat_ts"] = NOW
        records.append(
            record(
                state,
                "measure",
                "heartbeat",
                "HB: %d tool calls, %d iterations | blocked: %s | spend: $%.2f"
                % (
                    state["tool_calls"],
                    state["iterations"],
                    "yes" if blocked else "no",
                    state["spend_usd"],
                ),
            )
        )


def advance_counters(state):
    """Fold this tool call into the delegation's counters.

    iterations advances only on a repeated command — see the header note on why
    that is the only iteration proxy visible at PreToolUse.
    """
    state["tool_calls"] = int(state["tool_calls"]) + 1
    sha = hashlib.sha256(CMD.encode("utf-8")).hexdigest() if CMD else ""
    if sha and sha == state["last_cmd_sha256"]:
        state["same_cmd_streak"] = int(state["same_cmd_streak"]) + 1
        state["iterations"] = int(state["iterations"]) + 1
    else:
        state["same_cmd_streak"] = 1
    state["last_cmd_sha256"] = sha
    if is_progress(CMD):
        state["last_progress_ts"] = NOW


def deny_reason(rule, detail, state, path):
    resume = (
        "予算停止後の続行には、セッション分岐またはモデル変更に加えて、"
        "『続けて下さい』などの明示的な作業指示が必要です。疑問文では再開しません。"
        if rule == "budget-cap" else
        "継続する場合は委任契約の停止条件を見直してください。"
    )
    return (
        "H1 非進捗ランタイム停止 [%s]: %s. "
        "delegation=%s epoch_spend=$%.2f/$%.2f total_estimate=$%.2f iterations=%d source=%s. "
        "状態は %s に保存済み。%s"
        % (
            rule,
            detail,
            state["delegation"],
            state.get("budget_epoch_spend_usd", state["spend_usd"]),
            state["budget_usd"],
            state["spend_usd"],
            state["iterations"],
            state["budget_source"],
            path,
            resume,
        )
    ).replace("\n", " ")


def main():
    delegation, slug = resolve_delegation()
    path = state_path(slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    # State, transcript cursor and epoch grant are one transaction per
    # delegation. A separate lock file survives atomic replacement of JSON.
    with path.with_suffix(".lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        run_locked(delegation, path)


def run_locked(delegation, path):
    state = load_state(path, delegation)
    state["delegation"] = delegation
    if EVENT == "UserPromptSubmit":
        record_worktree(state)
        if TURN_ID and PAYLOAD_MODEL:
            turn_models = state.get("turn_models")
            if not isinstance(turn_models, dict):
                turn_models = {}
            turn_models[TURN_ID] = PAYLOAD_MODEL
            state["turn_models"] = dict(list(turn_models.items())[-128:])
        reason = resume_epoch(state, path)
        if SID and not state.get("first_prompt_session_id"):
            state["first_prompt_session_id"] = SID
        if PAYLOAD_MODEL and not state.get("first_prompt_model"):
            state["first_prompt_model"] = PAYLOAD_MODEL
        records = [record(state, "measure", "budget-epoch-reset", reason)] if reason else []
        if reason or SID or (TURN_ID and PAYLOAD_MODEL):
            persist_state(path, state)
        lines = ["allow", ""]
        lines.extend(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in records)
        print("\n".join(lines))
        return
    advance_counters(state)
    record_worktree(state)
    transcript = find_rollout(int(state["started_ts"]))
    records_from_rollout = usage_records(transcript, state)
    measured = measure_spend(state["tool_calls"], int(state["started_ts"]), state)
    had_record_baseline = bool(state.get("budget_epoch_baseline_record_tokens"))
    apply_meter(state, records_from_rollout, measured)

    rule, detail = decide(state)
    records = []
    if not had_record_baseline and state.get("budget_epoch_baseline_record_tokens"):
        records.append(record(state, "measure", "budget-epoch-record-baseline",
                              "first per-response thread baseline; separate from cumulative token_count"))
    if rule:
        state["last_block_rule"] = rule
        state["last_block_ts"] = NOW
        records.append(record(state, "block", rule, detail))
    advisory(state, records, blocked=bool(rule))

    persist_state(path, state)

    reason = deny_reason(rule, detail, state, path) if rule else ""
    lines = ["deny" if rule else "allow", reason]
    lines.extend(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in records)
    print("\n".join(lines))


main()
PY
) || verdict=""

decision=$(printf '%s\n' "$verdict" | sed -n '1p')
reason=$(printf '%s\n' "$verdict" | sed -n '2p')
records=$(printf '%s\n' "$verdict" | tail -n +3)

# A crashed decision core must not disable H1 *silently*.  Allowing is still the
# right answer — a broken governor must not brick the agent — but say so on
# stderr, which Codex surfaces, so the failure is visible rather than a guard
# that quietly stops guarding.  Set CODEX_H1_DEBUG_LOG to capture the traceback.
if [[ "$decision" != "deny" && "$decision" != "allow" ]]; then
  printf 'H1 WARNING: stall-runtime decision core failed; allowing this call unguarded. Set CODEX_H1_DEBUG_LOG=<path> to capture the error.\n' >&2
  emit_allow
fi

# H6 requirement 4: every fire reaches the defense ledger.
# aidd_ledger_append_record (not aidd_ledger_append) is used because H1 rows
# require a populated "subject" object, which the legacy helper hardcodes to {}.
if [[ -n "$records" ]] && declare -F aidd_ledger_append_record >/dev/null 2>&1; then
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    aidd_ledger_append_record "$rec" "codex" >>"${CODEX_H1_DEBUG_LOG:-/dev/null}" 2>&1 || true
  done <<<"$records"
fi

if [[ "$h1_event" == "UserPromptSubmit" ]]; then
  exit 0
fi
if [[ "$decision" == "deny" ]]; then
  emit_deny "${reason:-H1 非進捗ランタイム停止}"
fi

emit_allow
