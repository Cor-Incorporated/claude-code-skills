#!/usr/bin/env bash
# classify-review-state.sh — verified updater for pending-review-comments.json
#
# Usage:
#   bash classify-review-state.sh <PR_NUMBER> <VERDICTS_JSON> [OWNER/REPO]
#
# VERDICTS_JSON:
#   [
#     {
#       "index": 0,
#       "comment_hash": "...",
#       "verdict": "false_positive|real|unknown",
#       "reasoning": "..."
#     }
#   ]
#
# Exit codes:
#   0: classification saved and CRITICAL/HIGH are now zero
#   1: invalid input, stale state, or validation failure; state unchanged
#   2: classification saved but real/unknown CRITICAL/HIGH remain

set -euo pipefail

usage() {
  echo "Usage: bash classify-review-state.sh <PR_NUMBER> <VERDICTS_JSON> [OWNER/REPO]" >&2
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 1
fi

PR_NUMBER="$1"
VERDICTS_JSON="$2"
REPO="${3:-}"

if [[ -z "$PR_NUMBER" || -z "$VERDICTS_JSON" ]]; then
  usage
  exit 1
fi

resolve_project_dir() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return
  fi
  git rev-parse --show-toplevel 2>/dev/null || true
}

PROJECT_DIR="$(resolve_project_dir)"
if [[ -n "$PROJECT_DIR" ]]; then
  STATE_DIR="${PROJECT_DIR}/.claude/state"
else
  STATE_DIR="${HOME}/.claude/state"
fi

PENDING_FILE="${STATE_DIR}/pending-review-comments.json"
if [[ ! -f "$PENDING_FILE" ]]; then
  echo "ERROR: pending-review-comments.json not found: $PENDING_FILE" >&2
  exit 1
fi

if [[ -z "$REPO" ]]; then
  REPO="$(
    _PENDING_FILE="$PENDING_FILE" python3 - <<'PY' || true
import json
import os

try:
    with open(os.environ["_PENDING_FILE"]) as f:
        print(json.load(f).get("repo", ""))
except Exception:
    print("")
PY
  )"
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)"
fi

if [[ -z "$REPO" ]]; then
  echo "ERROR: repository could not be resolved" >&2
  exit 1
fi

HEAD_SHA="$(env -u GH_FORCE_TTY gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || true)"
if [[ -z "$HEAD_SHA" ]]; then
  echo "ERROR: PR #${PR_NUMBER} head SHA could not be resolved for ${REPO}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_SCRIPT="${SCRIPT_DIR}/review-comment-set-hash.sh"
if [[ ! -f "$HASH_SCRIPT" ]]; then
  HASH_SCRIPT="${HOME}/.claude/scripts/review-comment-set-hash.sh"
fi
if [[ ! -f "$HASH_SCRIPT" ]]; then
  echo "ERROR: review-comment-set-hash.sh not found" >&2
  exit 1
fi

CURRENT_COMMENT_SET_HASH="$(bash "$HASH_SCRIPT" "$PR_NUMBER" "$REPO" "$HEAD_SHA" 2>/dev/null || true)"
if [[ -z "$CURRENT_COMMENT_SET_HASH" ]]; then
  echo "ERROR: current review comment set could not be resolved for ${REPO}#${PR_NUMBER}" >&2
  exit 1
fi

_PENDING_FILE="$PENDING_FILE" \
_PR_NUMBER="$PR_NUMBER" \
_REPO="$REPO" \
_HEAD_SHA="$HEAD_SHA" \
_CURRENT_COMMENT_SET_HASH="$CURRENT_COMMENT_SET_HASH" \
_VERDICTS_JSON="$VERDICTS_JSON" \
python3 - <<'PY'
import datetime as dt
import fcntl
import json
import os
import re
import tempfile
import sys

pending_file = os.environ["_PENDING_FILE"]
pr_number = os.environ["_PR_NUMBER"]
repo = os.environ["_REPO"]
head_sha = os.environ["_HEAD_SHA"]
current_comment_set_hash = os.environ["_CURRENT_COMMENT_SET_HASH"]
verdicts_text = os.environ["_VERDICTS_JSON"]


def fail(message: str, code: int = 1) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def safe_false_positive_comment(comment: dict) -> bool:
    """Only lines that are themselves severity-zero/negation lines can be cleared."""
    text = str(comment.get("body_preview", ""))
    severity_patterns = [
        r"(?i)\[CRITICAL\]|severity:\s*CRITICAL|\*\*CRITICAL\*\*|^\s*CRITICAL:|>\s*CRITICAL",
        r"(?i)\[HIGH\]|severity:\s*HIGH|\*\*HIGH\*\*|^\s*HIGH[:\s-]|>\s*HIGH|\bP1\b",
        r"###\s*Bug:",
        r"###\s*Security:",
    ]
    negation_patterns = [
        r"(?i)no\s+critical",
        r"(?i)no\s+high",
        r"(?i)no\s+critical/high",
        r"(?i)critical\s*[:=]\s*0",
        r"(?i)high\s*[:=]\s*0",
        r"(?i)0\s+critical",
        r"(?i)0\s+high",
        r"(?i)critical/high\s*(?:=|:)?\s*0",
    ]
    severity_lines = [
        line
        for line in text.splitlines()
        if any(re.search(pattern, line) for pattern in severity_patterns)
    ]
    return bool(severity_lines) and all(
        any(re.search(pattern, line) for pattern in negation_patterns)
        for line in severity_lines
    )


try:
    verdicts = json.loads(verdicts_text)
except Exception as exc:
    fail(f"invalid verdict JSON: {exc}")

if not isinstance(verdicts, list):
    fail("verdict JSON must be an array")

lock_path = f"{pending_file}.lock"
os.makedirs(os.path.dirname(pending_file), exist_ok=True)

with open(lock_path, "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)

    try:
        with open(pending_file) as f:
            state = json.load(f)
    except Exception as exc:
        fail(f"could not read pending state: {exc}")

    if str(state.get("pr", "")) != str(pr_number):
        fail(f"pending state PR mismatch: state={state.get('pr')} requested={pr_number}")

    state_repo = state.get("repo", "")
    if state_repo and state_repo != repo:
        fail(f"pending state repo mismatch: state={state_repo} requested={repo}")

    state_head = state.get("head_sha", "")
    if not state_head:
        fail("pending state has no head_sha")
    if state_head != head_sha:
        fail(f"stale pending state: state={state_head} current={head_sha}")

    state_comment_set_hash = state.get("comment_set_hash", "")
    if not state_comment_set_hash:
        fail("pending state has no comment_set_hash; rerun gh pr checks")
    if state_comment_set_hash != current_comment_set_hash:
        fail("stale pending review comments; rerun gh pr checks")

    raw_comments = state.get("raw_comments")
    if not isinstance(raw_comments, list) or not raw_comments:
        fail("pending state has no raw_comments")

    normalized: dict[int, dict] = {}
    for item in verdicts:
        if not isinstance(item, dict):
            fail("each verdict must be an object")
        if "index" not in item:
            fail("verdict is missing index")
        try:
            index = int(item["index"])
        except Exception:
            fail(f"invalid verdict index: {item.get('index')}")
        if index < 0 or index >= len(raw_comments):
            fail(f"verdict index out of range: {index}")
        if index in normalized:
            fail(f"duplicate verdict index: {index}")

        expected_hash = raw_comments[index].get("comment_hash", "")
        if not expected_hash:
            fail(f"raw_comments[{index}] has no comment_hash; rerun gh pr checks")
        if item.get("comment_hash") != expected_hash:
            fail(f"comment_hash mismatch at index {index}")

        verdict = item.get("verdict")
        if verdict not in ("false_positive", "real", "unknown"):
            fail(f"invalid verdict at index {index}: {verdict}")

        reasoning = str(item.get("reasoning", "")).strip()
        if not reasoning:
            fail(f"verdict at index {index} is missing reasoning")

        normalized[index] = {
            "index": index,
            "comment_hash": expected_hash,
            "user": raw_comments[index].get("user", "?"),
            "source": raw_comments[index].get("source", "?"),
            "verdict": verdict,
            "reasoning": reasoning,
        }

    state_critical = int(state.get("critical", 0) or 0)
    state_high = int(state.get("high", 0) or 0)
    raw_critical = 0
    raw_high = 0
    for comment in raw_comments:
        raw_critical += int(comment.get("critical", 0) or 0)
        raw_high += int(comment.get("high", 0) or 0)

    if raw_critical != state_critical or raw_high != state_high:
        fail(
            "raw comment severity does not match top-level state; rerun gh pr checks "
            f"(raw C/H={raw_critical}/{raw_high}, state C/H={state_critical}/{state_high})"
        )

    missing = []
    for index, comment in enumerate(raw_comments):
        critical = int(comment.get("critical", 0) or 0)
        high = int(comment.get("high", 0) or 0)
        if (critical > 0 or high > 0) and index not in normalized:
            missing.append(index)
    if missing:
        fail(f"missing verdict for severity-bearing comments: {missing}")

    next_critical = 0
    next_high = 0
    for index, comment in enumerate(raw_comments):
        verdict = normalized.get(index, {}).get("verdict")
        if verdict == "false_positive" and safe_false_positive_comment(comment):
            continue
        next_critical += int(comment.get("critical", 0) or 0)
        next_high += int(comment.get("high", 0) or 0)

    classified_at = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    ordered_verdicts = [normalized[i] for i in sorted(normalized)]

    state["classification_method"] = "ai"
    state["critical"] = next_critical
    state["high"] = next_high
    state["ai_classification"] = {
        "critical": next_critical,
        "high": next_high,
        "classified_at": classified_at,
        "classified_by": "classify-review-state.sh",
        "verdicts": ordered_verdicts,
    }

    directory = os.path.dirname(pending_file)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".pending-review-comments.",
        suffix=".tmp",
        dir=directory,
        text=True,
    )
    try:
        with os.fdopen(fd, "w") as tmp:
            json.dump(state, tmp, indent=2, ensure_ascii=False)
            tmp.write("\n")
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_path, pending_file)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

    fcntl.flock(lock, fcntl.LOCK_UN)

if next_critical > 0 or next_high > 0:
    print(
        f"classification saved; unresolved CRITICAL={next_critical} HIGH={next_high}",
        file=sys.stderr,
    )
    raise SystemExit(2)

print("classification saved; CRITICAL=0 HIGH=0")
PY
