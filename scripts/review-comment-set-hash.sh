#!/usr/bin/env bash
# review-comment-set-hash.sh — deterministic hash for current PR review comments
#
# Usage:
#   bash review-comment-set-hash.sh <PR_NUMBER> [OWNER/REPO] [HEAD_SHA]

set -euo pipefail

usage() {
  echo "Usage: bash review-comment-set-hash.sh <PR_NUMBER> [OWNER/REPO] [HEAD_SHA]" >&2
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage
  exit 1
fi

PR_NUMBER="$1"
REPO="${2:-}"
HEAD_SHA="${3:-}"

if [[ -z "$PR_NUMBER" ]]; then
  usage
  exit 1
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)"
fi

if [[ -z "$REPO" ]]; then
  echo "ERROR: repository could not be resolved" >&2
  exit 1
fi

if [[ -z "$HEAD_SHA" ]]; then
  HEAD_SHA="$(env -u GH_FORCE_TTY gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || true)"
fi

if [[ -z "$HEAD_SHA" ]]; then
  echo "ERROR: PR #${PR_NUMBER} head SHA could not be resolved for ${REPO}" >&2
  exit 1
fi

_REPO="$REPO" _PR_NUMBER="$PR_NUMBER" _HEAD_SHA="$HEAD_SHA" python3 - <<'PY'
import hashlib
import json
import os
import re
import subprocess

repo = os.environ["_REPO"]
pr = os.environ["_PR_NUMBER"]
head_sha = os.environ["_HEAD_SHA"]


def gh_api(path: str):
    env = {k: v for k, v in os.environ.items() if k != "GH_FORCE_TTY"}
    try:
        r = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=20, env=env)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
    except Exception:
        pass
    return []


def gh_api_list(path: str) -> list:
    result = gh_api(path)
    return result if isinstance(result, list) else []


def strip_negation_lines(text: str) -> str:
    patterns = [
        r"(?i)no\s+critical",
        r"(?i)no\s+high",
        r"(?i)no\s+critical/high",
        r"(?i)critical[=/]high\s*(?:issues?|findings?|指摘)?\s*(?::|=|なし|ゼロ|0)",
        r"(?i)critical\s*=\s*0",
        r"(?i)high\s*=\s*0",
        r"(?i)0\s+critical",
        r"(?i)0\s+high",
        r"(?i)critical.*(?:free|なし|ありません|ゼロ|0件)",
        r"(?i)high.*(?:free|なし|ありません|ゼロ|0件)",
        r"(?i)no\s+(?:bug|warning|suggestion)",
        r"(?i)critical\s+\w+.*:\s*0\s*$",
        r"(?i)high\s+\w+.*:\s*0\s*$",
    ]
    return "\n".join(line for line in text.split("\n") if not any(re.search(p, line) for p in patterns))


def count_severity(text: str) -> tuple[int, int, int, int]:
    cleaned = re.sub(r"<details>.*?</details>", "", text, flags=re.DOTALL)
    cleaned = re.sub(r"<!--.*?-->", "", cleaned, flags=re.DOTALL)
    cleaned = re.sub(r"<[^>]+>", "", cleaned)
    cleaned = strip_negation_lines(cleaned)
    critical = len(re.findall(r"(?i)\[CRITICAL\]|severity:\s*CRITICAL|\*\*CRITICAL\*\*|^\s*CRITICAL:|>\s*CRITICAL", cleaned, re.MULTILINE))
    high = len(re.findall(r"(?i)\[HIGH\]|severity:\s*HIGH|\*\*HIGH\*\*|^\s*HIGH[:\s-]|>\s*HIGH|\bP1\b", cleaned, re.MULTILINE))
    warning = len(re.findall(r"(?i)\[WARNING\]|severity:\s*WARNING|\*\*WARNING\*\*|^\s*WARNING:", cleaned, re.MULTILINE))
    suggestion = len(re.findall(r"(?i)\[SUGGESTION\]|severity:\s*SUGGESTION|\*\*SUGGESTION\*\*|^\s*SUGGESTION:", cleaned, re.MULTILINE))
    high += len(re.findall(r"###\s*Bug:", text))
    high += len(re.findall(r"###\s*Security:", text))
    warning += len(re.findall(r"###\s*Performance:", text))
    suggestion += len(re.findall(r"###\s*Minor:", text))
    return critical, high, warning, suggestion


def raw_entry(source: str, user: str, body: str, **extra) -> dict:
    critical, high, warning, suggestion = count_severity(body)
    entry = {
        "user": user,
        "body_preview": body[:500],
        "source": source,
        "critical": critical,
        "high": high,
        "warning": warning,
        "suggestion": suggestion,
    }
    for key in ("path", "line", "comment_id", "updated_at"):
        if extra.get(key) is not None:
            entry[key] = extra[key]
    digest_src = json.dumps(entry, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    entry["comment_hash"] = hashlib.sha256(digest_src.encode("utf-8")).hexdigest()
    return entry


inline = []
for c in gh_api_list(f"repos/{repo}/pulls/{pr}/comments"):
    if head_sha and c.get("commit_id", "") != head_sha:
        continue
    inline.append(
        {
            "path": c.get("path", "?"),
            "line": c.get("line") or c.get("original_line") or "?",
            "body": c.get("body", ""),
            "user": c.get("user", {}).get("login", "?"),
            "id": c.get("id"),
            "updated_at": c.get("updated_at"),
        }
    )

review_keywords = ["claude-review", "critical", "warning", "suggestion", "pr review", "code review", "lgtm"]
bot_comments = []
human_review_comments = []
for c in gh_api_list(f"repos/{repo}/issues/{pr}/comments"):
    user = c.get("user", {}).get("login", "")
    body = c.get("body", "")
    is_bot = user in ("github-actions[bot]", "claude[bot]", "claude-review[bot]")
    has_review_keyword = any(kw in body.lower() for kw in review_keywords)
    entry = {"user": user, "body": body, "id": c.get("id"), "updated_at": c.get("updated_at")}
    if is_bot:
        bot_comments.append(entry)
    elif has_review_keyword:
        human_review_comments.append(entry)

issue_comments = []
if bot_comments:
    issue_comments.append(bot_comments[-1])
issue_comments.extend(human_review_comments)

for r in gh_api_list(f"repos/{repo}/pulls/{pr}/reviews"):
    state = r.get("state", "")
    body = r.get("body", "")
    if state in ("APPROVED", "CHANGES_REQUESTED", "COMMENTED") and body and body.strip():
        issue_comments.append(
            {
                "user": r.get("user", {}).get("login", "?"),
                "body": f"[{state}] {body}",
                "id": r.get("id"),
                "updated_at": r.get("submitted_at"),
            }
        )

raw_comments = []
for c in inline:
    raw_comments.append(
        raw_entry(
            "inline",
            c.get("user", "?"),
            c.get("body", ""),
            path=c.get("path", "?"),
            line=c.get("line", "?"),
            comment_id=c.get("id"),
            updated_at=c.get("updated_at"),
        )
    )
for c in issue_comments:
    raw_comments.append(
        raw_entry(
            "issue_comment",
            c.get("user", "?"),
            c.get("body", ""),
            comment_id=c.get("id"),
            updated_at=c.get("updated_at"),
        )
    )

digest_src = json.dumps(
    [
        {
            "comment_hash": c.get("comment_hash", ""),
            "critical": c.get("critical", 0),
            "high": c.get("high", 0),
        }
        for c in raw_comments
    ],
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
)
print(hashlib.sha256(digest_src.encode("utf-8")).hexdigest())
PY
