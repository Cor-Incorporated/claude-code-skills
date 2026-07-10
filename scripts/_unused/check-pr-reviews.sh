#!/bin/bash
# check-pr-reviews.sh — Check ALL claude-review sources for a PR
# Sources: (1) review bodies, (2) inline comments, (3) issue comments
# Usage: bash check-pr-reviews.sh <pr-number> [--latest-only] [--json]
set -euo pipefail

PR_NUMBER="${1:-}"
LATEST_ONLY=false
JSON_OUTPUT=false

# Parse flags
shift || true
for arg in "$@"; do
    case "$arg" in
        --latest-only) LATEST_ONLY=true ;;
        --json) JSON_OUTPUT=true ;;
    esac
done

if [ -z "$PR_NUMBER" ]; then
    echo "Usage: check-pr-reviews.sh <pr-number> [--latest-only] [--json]" >&2
    exit 1
fi

# Auto-detect repo from git remote
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
    echo "ERROR: Could not detect repo. Run from a git repo with gh configured." >&2
    exit 1
fi

# Get latest push timestamp and commit
LATEST_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid -q '.headRefOid' 2>/dev/null | head -c 7)
LATEST_PUSH_TIME=$(gh pr view "$PR_NUMBER" --json updatedAt -q '.updatedAt' 2>/dev/null || echo "")

echo "=== PR #${PR_NUMBER} Review Check (repo: ${REPO}) ==="
echo "Latest commit: ${LATEST_SHA}"
echo "Latest push:   ${LATEST_PUSH_TIME}"
echo ""

MUST_FIX=0
SHOULD_FIX=0
TOTAL_COMMENTS=0
STALE_WARNING=""

# --- Source 1: Review bodies (gh api /pulls/{pr}/reviews) ---
echo "--- Source 1: Review Bodies ---"
if $LATEST_ONLY && [ -n "$LATEST_PUSH_TIME" ]; then
    # Only count reviews submitted after the latest push
    REVIEW_BODIES=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
        --jq "[.[] | select(.user.login == \"claude[bot]\" and .body != \"\" and .submitted_at > \"${LATEST_PUSH_TIME}\")] | length" 2>/dev/null || echo "0")
    ALL_REVIEW_BODIES=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
        --jq '[.[] | select(.user.login == "claude[bot]" and .body != "")] | length' 2>/dev/null || echo "0")
    echo "  Found ${REVIEW_BODIES} review(s) after latest push (${ALL_REVIEW_BODIES} total)"
else
    REVIEW_BODIES=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
        --jq '[.[] | select(.user.login == "claude[bot]" and .body != "")] | length' 2>/dev/null || echo "0")
    echo "  Found ${REVIEW_BODIES} review(s) with body text"
fi

if [ "$REVIEW_BODIES" -gt 0 ]; then
    if $LATEST_ONLY && [ -n "$LATEST_PUSH_TIME" ]; then
        LATEST_REVIEW=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
            --jq "[.[] | select(.user.login == \"claude[bot]\" and .body != \"\" and .submitted_at > \"${LATEST_PUSH_TIME}\")] | last | .body" 2>/dev/null || echo "")
    else
        LATEST_REVIEW=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
            --jq '[.[] | select(.user.login == "claude[bot]" and .body != "")] | last | .body' 2>/dev/null || echo "")
    fi
    if [ -n "$LATEST_REVIEW" ]; then
        BODY_MUST=$(echo "$LATEST_REVIEW" | grep -ciE "must fix|bug:|critical" || true)
        BODY_SHOULD=$(echo "$LATEST_REVIEW" | grep -ciE "should fix|recommend" || true)
        MUST_FIX=$((MUST_FIX + BODY_MUST))
        SHOULD_FIX=$((SHOULD_FIX + BODY_SHOULD))
    fi
else
    echo "  No review bodies found"
fi

# --- Source 2: Inline review comments (gh api /pulls/{pr}/comments) ---
echo ""
echo "--- Source 2: Inline Comments ---"
if $LATEST_ONLY; then
    INLINE_COUNT=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
        --jq "[.[] | select(.user.login == \"claude[bot]\" and (.commit_id | startswith(\"${LATEST_SHA}\")))] | length" 2>/dev/null || echo "0")
    ALL_INLINE=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
        --jq '[.[] | select(.user.login == "claude[bot]")] | length' 2>/dev/null || echo "0")
    echo "  Found ${INLINE_COUNT} inline comment(s) on latest commit (${ALL_INLINE} total)"
else
    INLINE_COUNT=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
        --jq '[.[] | select(.user.login == "claude[bot]")] | length' 2>/dev/null || echo "0")
    echo "  Found ${INLINE_COUNT} inline comment(s) total"
fi
TOTAL_COMMENTS=$((TOTAL_COMMENTS + INLINE_COUNT))

# --- Source 3: Issue comments / review summaries (gh api /issues/{pr}/comments) ---
echo ""
echo "--- Source 3: Issue Comments (Review Summaries) ---"

if $LATEST_ONLY && [ -n "$LATEST_PUSH_TIME" ]; then
    # Only count issue comments posted after the latest push
    ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
        --jq "[.[] | select(.user.login == \"claude[bot]\" and .created_at > \"${LATEST_PUSH_TIME}\")] | length" 2>/dev/null || echo "0")
    ALL_ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
        --jq '[.[] | select(.user.login == "claude[bot]")] | length' 2>/dev/null || echo "0")
    echo "  Found ${ISSUE_COMMENTS} issue comment(s) after latest push (${ALL_ISSUE_COMMENTS} total)"

    if [ "$ISSUE_COMMENTS" -eq 0 ] && [ "$ALL_ISSUE_COMMENTS" -gt 0 ]; then
        # Check if latest review is stale (before latest push)
        LATEST_COMMENT_TIME=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
            --jq '[.[] | select(.user.login == "claude[bot]")] | last | .created_at' 2>/dev/null || echo "")
        if [ -n "$LATEST_COMMENT_TIME" ] && [ "$LATEST_COMMENT_TIME" \< "$LATEST_PUSH_TIME" ]; then
            STALE_WARNING="⏳ Latest review summary (${LATEST_COMMENT_TIME}) is OLDER than latest push (${LATEST_PUSH_TIME}). Review may still be pending."
            echo "  ${STALE_WARNING}"
        fi
    fi
else
    ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
        --jq '[.[] | select(.user.login == "claude[bot]")] | length' 2>/dev/null || echo "0")
    echo "  Found ${ISSUE_COMMENTS} issue comment(s) from claude[bot]"
fi

if [ "$ISSUE_COMMENTS" -gt 0 ]; then
    if $LATEST_ONLY && [ -n "$LATEST_PUSH_TIME" ]; then
        LATEST_ISSUE_COMMENT=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
            --jq "[.[] | select(.user.login == \"claude[bot]\" and .created_at > \"${LATEST_PUSH_TIME}\")] | last | .body" 2>/dev/null || echo "")
    else
        LATEST_ISSUE_COMMENT=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
            --jq '[.[] | select(.user.login == "claude[bot]")] | last | .body' 2>/dev/null || echo "")
    fi
    if [ -n "$LATEST_ISSUE_COMMENT" ] && [ "$LATEST_ISSUE_COMMENT" != "null" ]; then
        IC_MUST=$(echo "$LATEST_ISSUE_COMMENT" | grep -ciE "must fix|🔴|bug:" || true)
        IC_SHOULD=$(echo "$LATEST_ISSUE_COMMENT" | grep -ciE "should fix|🟠|recommend" || true)
        IC_OBS=$(echo "$LATEST_ISSUE_COMMENT" | grep -ciE "observation|🟡|minor|nit" || true)
        MUST_FIX=$((MUST_FIX + IC_MUST))
        SHOULD_FIX=$((SHOULD_FIX + IC_SHOULD))
        echo "  Latest summary: MUST_FIX=${IC_MUST}, SHOULD_FIX=${IC_SHOULD}, OBSERVATIONS=${IC_OBS}"
    fi
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  MUST FIX:   ${MUST_FIX}"
echo "  SHOULD FIX: ${SHOULD_FIX}"
echo "  Inline:     ${INLINE_COUNT}"
echo "  Summaries:  ${ISSUE_COMMENTS}"
if [ -n "$STALE_WARNING" ]; then
    echo "  WARNING:    ${STALE_WARNING}"
fi

if [ -n "$STALE_WARNING" ]; then
    echo ""
    echo "⏳ Review still pending — wait for claude-review to post new comments."
    exit 2
elif [ "$MUST_FIX" -gt 0 ]; then
    echo ""
    echo "❌ MUST FIX items remain. Review is NOT LGTM."
    exit 1
elif [ "$SHOULD_FIX" -gt 0 ]; then
    echo ""
    echo "⚠️  SHOULD FIX items remain. Consider addressing before merge."
    exit 0
else
    echo ""
    echo "✅ No blocking issues found."
    exit 0
fi
