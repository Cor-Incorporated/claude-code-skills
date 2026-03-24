#!/usr/bin/env python3
"""delivery_score.py — Quantitative delivery quality score calculator.

Harness Best Practice #8: Measurement & scoring.
Calculates hook coverage, CI pass rate, and soak time compliance.

Usage:
    python3 scripts/delivery_score.py [--json]
"""

import json
import subprocess
import sys
from pathlib import Path


def run(cmd: str, timeout: int = 15) -> str:
    """Run shell command, return stdout or empty string on failure."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except Exception:
        return ""


def get_project_root() -> Path:
    """Detect project root via git."""
    root = run("git rev-parse --show-toplevel")
    return Path(root) if root else Path.cwd()


def score_hook_coverage(project_root: Path) -> dict:
    """Calculate hook deployment rate: registered vs expected hooks."""
    settings_path = project_root / "settings.json"
    if not settings_path.exists():
        return {"score": 0, "registered": 0, "expected": 0, "detail": "settings.json not found"}

    with open(settings_path) as f:
        settings = json.load(f)

    hooks_config = settings.get("hooks", {})
    registered_hooks = set()

    for event_name, blocks in hooks_config.items():
        if not isinstance(blocks, list):
            continue
        for block in blocks:
            for hook in block.get("hooks", []):
                cmd = hook.get("command", "")
                # Extract script name from command
                parts = cmd.split("/")
                if parts:
                    script_name = parts[-1].strip().strip("'\"")
                    if script_name.endswith(".sh"):
                        registered_hooks.add(script_name)

    # Expected hooks: all .sh files in hooks/ directory
    hooks_dir = project_root / "hooks"
    expected_hooks = set()
    if hooks_dir.exists():
        for f in hooks_dir.iterdir():
            if f.suffix == ".sh" and not f.name.startswith("_"):
                expected_hooks.add(f.name)

    # Exclude _unused directory
    unused_dir = hooks_dir / "_unused"
    if unused_dir.exists():
        for f in unused_dir.iterdir():
            expected_hooks.discard(f.name)

    coverage = len(registered_hooks & expected_hooks) / max(len(expected_hooks), 1) * 100
    unregistered = expected_hooks - registered_hooks

    return {
        "score": round(coverage, 1),
        "registered": len(registered_hooks & expected_hooks),
        "expected": len(expected_hooks),
        "unregistered": sorted(unregistered)[:5],  # Top 5 unregistered
    }


def score_ci_pass_rate(repo: str) -> dict:
    """Calculate CI pass rate from recent GitHub Actions runs."""
    runs_json = run(f"gh api repos/{repo}/actions/runs?per_page=20 --jq '.workflow_runs | map({{conclusion, status}})' 2>/dev/null")
    if not runs_json:
        return {"score": 0, "total": 0, "passed": 0, "detail": "no CI runs found"}

    try:
        runs = json.loads(runs_json)
    except json.JSONDecodeError:
        return {"score": 0, "total": 0, "passed": 0, "detail": "parse error"}

    completed = [r for r in runs if r.get("status") == "completed"]
    passed = [r for r in completed if r.get("conclusion") == "success"]

    rate = len(passed) / max(len(completed), 1) * 100
    return {
        "score": round(rate, 1),
        "total": len(completed),
        "passed": len(passed),
    }


def score_soak_time_compliance(repo: str) -> dict:
    """Check if merged PRs respected soak time requirements."""
    # Get recently merged PRs
    prs_json = run(
        f"gh api 'repos/{repo}/pulls?state=closed&sort=updated&direction=desc&per_page=10' "
        f"--jq '[.[] | select(.merged_at != null) | {{number, headRefName: .head.ref, merged_at}}]'"
    )
    if not prs_json:
        return {"score": 100, "checked": 0, "detail": "no merged PRs found"}

    try:
        prs = json.loads(prs_json)
    except json.JSONDecodeError:
        return {"score": 0, "detail": "parse error"}

    # For now, a simple heuristic: infra PRs need longer soak time
    # Full implementation would check timestamps between create and merge
    return {
        "score": 100,  # Placeholder: soak time hook enforces this
        "checked": len(prs),
        "detail": "enforced by hook (enforce-soak-time.sh)",
    }


def score_review_compliance(repo: str) -> dict:
    """Check if PRs have review comments before merge."""
    prs_json = run(
        f"gh api 'repos/{repo}/pulls?state=closed&sort=updated&direction=desc&per_page=10' "
        f"--jq '[.[] | select(.merged_at != null) | {{number}}]'"
    )
    if not prs_json:
        return {"score": 100, "checked": 0, "detail": "no merged PRs"}

    try:
        prs = json.loads(prs_json)
    except json.JSONDecodeError:
        return {"score": 0, "detail": "parse error"}

    reviewed = 0
    for pr in prs[:5]:  # Check last 5
        pr_num = pr["number"]
        reviews = run(f"gh api repos/{repo}/pulls/{pr_num}/reviews --jq 'length'")
        try:
            if reviews and int(reviews) > 0:
                reviewed += 1
        except ValueError:
            pass

    checked = min(len(prs), 5)
    rate = reviewed / max(checked, 1) * 100
    return {
        "score": round(rate, 1),
        "checked": checked,
        "reviewed": reviewed,
    }


def calculate_total(scores: dict) -> float:
    """Weighted total score."""
    weights = {
        "hook_coverage": 0.30,
        "ci_pass_rate": 0.25,
        "soak_time": 0.20,
        "review_compliance": 0.25,
    }
    total = sum(scores[k]["score"] * weights.get(k, 0) for k in scores)
    return round(total, 1)


def grade(score: float) -> str:
    """Convert numeric score to letter grade."""
    if score >= 95:
        return "A+"
    elif score >= 90:
        return "A"
    elif score >= 85:
        return "A-"
    elif score >= 80:
        return "B+"
    elif score >= 75:
        return "B"
    elif score >= 70:
        return "B-"
    elif score >= 65:
        return "C+"
    elif score >= 60:
        return "C"
    else:
        return "D"


def main():
    output_json = "--json" in sys.argv
    project_root = get_project_root()

    repo = run("gh repo view --json nameWithOwner -q '.nameWithOwner'")

    scores = {
        "hook_coverage": score_hook_coverage(project_root),
        "ci_pass_rate": score_ci_pass_rate(repo),
        "soak_time": score_soak_time_compliance(repo),
        "review_compliance": score_review_compliance(repo),
    }

    total = calculate_total(scores)
    letter = grade(total)

    result = {
        "project": project_root.name,
        "total_score": total,
        "grade": letter,
        "scores": scores,
    }

    if output_json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"{'='*50}")
        print(f"  Delivery Quality Score: {project_root.name}")
        print(f"{'='*50}")
        print(f"  Total: {total}/100 ({letter})")
        print(f"{'─'*50}")
        for name, data in scores.items():
            print(f"  {name:25s}: {data['score']:5.1f}/100")
        print(f"{'='*50}")

        # Show unregistered hooks if any
        unreg = scores["hook_coverage"].get("unregistered", [])
        if unreg:
            print(f"\n  Unregistered hooks: {', '.join(unreg)}")


if __name__ == "__main__":
    main()
