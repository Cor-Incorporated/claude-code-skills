#!/usr/bin/env python3
"""Fetch PR review comments and output hookSpecificOutput JSON.

Called by inject-claude-review-on-checks.sh after `gh pr checks`.
Handles three scenarios:
  1. claude-review comments exist -> show severity summary + all comments
  2. No claude-review but other review comments -> show those
  3. No review comments at all -> warn that review is needed

Issue #66 Fix #5: Added head_sha to state file for PR scope validation.
"""

import json
import re
import subprocess
import sys
from dataclasses import dataclass, field


@dataclass
class ReviewSummary:
    """Aggregated review findings."""

    total: int = 0
    critical: int = 0
    high: int = 0
    warning: int = 0
    suggestion: int = 0
    inline_comments: list = field(default_factory=list)
    issue_comments: list = field(default_factory=list)
    has_claude_review: bool = False
    has_any_review: bool = False
    head_sha: str = ""  # Issue #66 Fix #5: track HEAD SHA for scope validation


def gh_api(path: str) -> list | dict:
    """Call gh api and return parsed JSON."""
    import os

    # GH_FORCE_TTY=0 breaks gh api JSON output -- ensure it's unset
    env = {k: v for k, v in os.environ.items() if k != "GH_FORCE_TTY"}
    try:
        r = subprocess.run(
            ["gh", "api", path],
            capture_output=True,
            text=True,
            timeout=20,
            env=env,
        )
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
        return []
    except Exception:
        return []


def gh_api_list(path: str) -> list:
    """Call gh api and return parsed JSON list."""
    result = gh_api(path)
    return result if isinstance(result, list) else []


def count_severity(text: str) -> tuple[int, int, int, int]:
    """Count severity markers in text.

    Detects both traditional keywords (CRITICAL, HIGH, etc.) and
    claude-review header format (### Bug:, ### Security:, etc.).
    Issue #57: claude-review uses header format that was previously undetected.
    """
    critical = len(re.findall(r"(?i)\bcritical\b", text))
    high = len(re.findall(r"(?i)\b(?:P1|high)\b", text))
    warning = len(re.findall(r"(?i)\bwarning\b", text))
    suggestion = len(re.findall(r"(?i)\bsuggestion\b", text))

    # claude-review (Claude Sonnet 4.6) header format
    high += len(re.findall(r"###\s*Bug:", text))
    high += len(re.findall(r"###\s*Security:", text))
    warning += len(re.findall(r"###\s*Performance:", text))
    suggestion += len(re.findall(r"###\s*Minor:", text))

    return critical, high, warning, suggestion


def fetch_reviews(repo: str, pr: str) -> ReviewSummary:
    """Fetch all review data for a PR."""
    summary = ReviewSummary()

    # Get latest commit SHA to filter only current-push comments
    pr_data = gh_api(f"repos/{repo}/pulls/{pr}")
    latest_sha = ""
    if isinstance(pr_data, dict):
        latest_sha = pr_data.get("head", {}).get("sha", "")
    elif isinstance(pr_data, list) and pr_data:
        latest_sha = pr_data[0].get("head", {}).get("sha", "")

    # Issue #66 Fix #5: Store head_sha for scope validation
    summary.head_sha = latest_sha

    # 1. Inline review comments (code-level) -- only latest commit
    raw_inline = gh_api_list(f"repos/{repo}/pulls/{pr}/comments")
    for c in raw_inline:
        if latest_sha and c.get("commit_id", "") != latest_sha:
            continue
        summary.inline_comments.append(
            {
                "path": c.get("path", "?"),
                "line": c.get("line") or c.get("original_line") or "?",
                "body": c.get("body", ""),
                "user": c.get("user", {}).get("login", "?"),
            }
        )

    # 2. Issue comments (Claude Review workflow, bot comments)
    raw_issue = gh_api_list(f"repos/{repo}/issues/{pr}/comments")
    review_keywords = [
        "claude-review", "critical", "warning", "suggestion",
        "pr review", "code review", "lgtm",
    ]
    bot_comments: list[dict] = []
    human_review_comments: list[dict] = []
    for c in raw_issue:
        user = c.get("user", {}).get("login", "")
        body = c.get("body", "")
        body_lower = body.lower()

        is_bot = user in ("github-actions[bot]", "claude[bot]", "claude-review[bot]")
        has_review_keyword = any(kw in body_lower for kw in review_keywords)

        if is_bot:
            bot_comments.append({"user": user, "body": body})
            summary.has_claude_review = True
        elif has_review_keyword:
            human_review_comments.append({"user": user, "body": body})

    if bot_comments:
        summary.issue_comments.append(bot_comments[-1])
    summary.issue_comments.extend(human_review_comments)

    # 3. PR reviews (APPROVED, CHANGES_REQUESTED, etc.)
    raw_reviews = gh_api_list(f"repos/{repo}/pulls/{pr}/reviews")
    for r in raw_reviews:
        state = r.get("state", "")
        if state in ("APPROVED", "CHANGES_REQUESTED", "COMMENTED"):
            summary.has_any_review = True
            body = r.get("body", "")
            if body and body.strip():
                summary.issue_comments.append(
                    {
                        "user": r.get("user", {}).get("login", "?"),
                        "body": f"[{state}] {body}",
                    }
                )

    # Count totals and severity
    summary.total = len(summary.inline_comments) + len(summary.issue_comments)
    all_text = " ".join(
        c.get("body", "") for c in summary.inline_comments + summary.issue_comments
    )
    (summary.critical, summary.high, summary.warning, summary.suggestion) = (
        count_severity(all_text)
    )

    if summary.total > 0:
        summary.has_any_review = True

    return summary


def format_output(repo: str, pr: str, summary: ReviewSummary) -> str:
    """Format the review summary for agent context injection."""
    lines: list[str] = []

    if not summary.has_any_review and summary.total == 0:
        lines.append(f"[review] PR #{pr}: レビューコメントが存在しません")
        lines.append("")
        lines.append("以下のいずれかを実行してください:")
        lines.append("  A) Claude Review workflow の完了を待つ")
        lines.append("  B) code-reviewer エージェントでレビューを実行:")
        lines.append(
            f"     Agent(subagent_type='code-reviewer', prompt='Review PR #{pr}')"
        )
        lines.append("")
        lines.append("レビューなしでのマージ報告は禁止です。")
        return "\n".join(lines)

    lines.append(f"[review] PR #{pr} レビューコメント: {summary.total}件")
    lines.append(
        f"Severity: CRITICAL={summary.critical} HIGH={summary.high} "
        f"WARNING={summary.warning} SUGGESTION={summary.suggestion}"
    )
    lines.append("")

    if summary.critical > 0 or summary.high > 0:
        lines.append("CRITICAL/HIGH指摘あり。全て対応してからマージ判断すること。")
        lines.append("")

    if not summary.has_claude_review:
        lines.append(
            "Claude Review (GitHub Actions bot) のコメントが見つかりません。"
        )
        lines.append(
            "  手動レビューコメントのみ。claude-review workflowが未実行の可能性。"
        )
        lines.append("")

    if summary.inline_comments:
        lines.append(f"--- Inline Review ({len(summary.inline_comments)}件) ---")
        for i, c in enumerate(summary.inline_comments[:25], 1):
            path, line = c["path"], c["line"]
            body = c["body"][:300].replace("\n", " | ")
            lines.append(f"[{i}] {path}:{line} -- {body}")
        if len(summary.inline_comments) > 25:
            lines.append(f"  ... 他{len(summary.inline_comments) - 25}件省略")
        lines.append("")

    if summary.issue_comments:
        lines.append(f"--- Issue/Bot Comments ({len(summary.issue_comments)}件) ---")
        for i, c in enumerate(summary.issue_comments[:5], 1):
            user = c["user"]
            body = c["body"][:500].replace("\n", " | ")
            lines.append(f"[{i}] @{user}: {body}")
        lines.append("")

    if summary.critical > 0 or summary.high > 0:
        lines.append("次のアクション:")
        lines.append("  1. 上記CRITICAL/HIGH指摘を全て修正")
        lines.append("  2. 修正push後、再度 gh pr checks で確認")
        lines.append(
            f"  3. 全コメント再確認: gh api repos/{repo}/pulls/{pr}/comments"
        )
    else:
        lines.append("CRITICAL/HIGH指摘なし。MEDIUM以下はfollow-up可。")

    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(0)

    repo, pr = sys.argv[1], sys.argv[2]
    summary = fetch_reviews(repo, pr)
    output = format_output(repo, pr, summary)

    # Write to state file for other hooks to reference
    state_dir = ""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode == 0:
            state_dir = r.stdout.strip() + "/.claude/state"
    except Exception:
        pass
    if not state_dir:
        import os
        state_dir = os.path.expanduser("~/.claude/state")

    import os
    os.makedirs(state_dir, exist_ok=True)
    pending_file = os.path.join(state_dir, "pending-review-comments.json")

    # Issue #66 Fix #5: Include head_sha for scope validation
    # Consumers validate that state matches current PR/SHA before trusting it.
    with open(pending_file, "w") as f:
        json.dump(
            {
                "pr": pr,
                "repo": repo,
                "head_sha": summary.head_sha,
                "total": summary.total,
                "critical": summary.critical,
                "high": summary.high,
                "output": output,
            },
            f,
            indent=2,
        )

    result = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": output,
        }
    }
    print(json.dumps(result))
    print(output, file=sys.stderr)


if __name__ == "__main__":
    main()
