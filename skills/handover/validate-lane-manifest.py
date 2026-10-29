#!/usr/bin/env python3
"""Validate a lane-manifest (skills/handover/lane-manifest.template.yaml).

Exit 0 when every lane can start from the manifest alone, 1 with one line per
problem otherwise. Each problem names the lane and the observed value, so the
orchestrator can fix the manifest before any lane is launched.

The standard prohibition IDs are read from skills/handover/SKILL.md (the
"禁止事項標準枠" table), not from a copy here: dropping an ID from either side
makes this fail.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REQUIRED = ("topic", "cwd", "origin", "base", "worktree", "branch", "commit_allowed", "report_to", "owns")


def load(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore
    except ImportError:
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            raise SystemExit("validate-lane-manifest: PyYAML is not installed; pass the manifest as JSON")
    return yaml.safe_load(text)


def standard_ids(skill: Path) -> list[str]:
    ids = re.findall(r"^\|\s*(HP-\d+)\s*\|", skill.read_text(encoding="utf-8"), re.M)
    return sorted(set(ids), key=lambda s: int(s.split("-")[1]))


def expand(p: str) -> Path:
    return Path(os.path.expanduser(str(p))).resolve()


def git(cwd: Path, *args: str) -> tuple[int, str]:
    try:
        r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    except OSError as exc:  # git not on PATH: report, do not traceback
        return 127, f"<git unavailable: {exc}>"
    return r.returncode, r.stdout.strip()


def redact(u: str) -> str:
    """Hide userinfo (a token in https://user:token@host/...) before printing."""
    return re.sub(r"(://)[^/@\s]+@", r"\1***@", str(u))


def norm_url(u: str) -> str:
    u = u.strip().removesuffix(".git").rstrip("/")
    m = re.match(r"^(?:ssh://)?git@([^:/]+)[:/](.+)$", u) or re.match(r"^https?://([^/]+)/(.+)$", u)
    return f"{m.group(1)}/{m.group(2)}".lower() if m else u.lower()


def check(manifest: dict, skill: Path) -> list[str]:
    problems: list[str] = []
    if manifest.get("schema") != "lane-manifest.v1":
        problems.append(f"schema: want lane-manifest.v1, got {manifest.get('schema')!r}")
    want = standard_ids(skill)
    have = set(manifest.get("standard_prohibitions") or [])
    missing = [i for i in want if i not in have]
    if not want:
        problems.append(f"{skill}: no HP-n rows in the 禁止事項標準枠 table")
    if missing:
        problems.append(f"standard_prohibitions: missing {missing} (SKILL.md declares {want}, manifest has {sorted(have)})")

    lanes = manifest.get("lanes") or []
    if not lanes:
        problems.append("lanes: empty")
    seen_worktrees: dict[str, str] = {}
    seen_reports: dict[str, str] = {}
    seen_topics: dict[str, int] = {}
    owned: list[tuple[str, Path, str]] = []
    for idx, lane in enumerate(lanes):
        if not isinstance(lane, dict):
            problems.append(f"lane #{idx + 1}: must be a mapping, got {type(lane).__name__}")
            continue
        topic = lane.get("topic", "<no topic>")
        if not isinstance(topic, str) or not topic:
            problems.append(f"lane #{idx + 1}: topic must be a non-empty string, got {topic!r}")
            continue
        if topic in seen_topics:
            problems.append(f"{topic}: topic is used by more than one lane")
        seen_topics[topic] = idx
        absent = [k for k in REQUIRED if k not in lane or lane[k] in (None, "")]
        if absent:
            problems.append(f"{topic}: missing {absent}")
            continue
        if not isinstance(lane["owns"], list) or not all(isinstance(p, str) and p for p in lane["owns"]):
            problems.append(f"{topic}: owns must be a list of paths, got {type(lane['owns']).__name__}")
            continue
        if not isinstance(lane["commit_allowed"], bool):
            problems.append(f"{topic}: commit_allowed must be true or false, got {lane['commit_allowed']!r}")
            continue
        cwd = expand(lane["cwd"])
        rc, top = git(cwd, "rev-parse", "--show-toplevel")
        if rc != 0:
            problems.append(f"{topic}: cwd {cwd} is not a git repository")
            continue
        rc, url = git(cwd, "remote", "get-url", "origin")
        if rc != 0 or norm_url(url) != norm_url(lane["origin"]):
            problems.append(f"{topic}: origin declared {redact(lane['origin'])!r}, repo has {redact(url) or '<none>'!r}")
        rc, _ = git(cwd, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{lane['base']}")
        if rc != 0:
            problems.append(f"{topic}: base origin/{lane['base']} not found in {cwd} (run git fetch origin, or fix base)")
        wt = str(lane["worktree"])
        if wt == "none":
            if lane["commit_allowed"] is not False:
                problems.append(f"{topic}: worktree none requires commit_allowed: false")
        else:
            wpath = expand(wt)
            root = Path(top).resolve()
            try:
                rel = wpath.relative_to(root / ".worktrees")
            except ValueError:
                rel = None
            if rel is None or len(rel.parts) != 2:
                problems.append(f"{topic}: worktree {wpath} is not <cwd>/.worktrees/<agent>/<slug> under {root}")
            if str(wpath) in seen_worktrees:
                problems.append(f"{topic}: worktree {wpath} is also used by {seen_worktrees[str(wpath)]}")
            seen_worktrees[str(wpath)] = topic
        report = expand(lane["report_to"])
        if not report.parent.is_dir():
            problems.append(f"{topic}: report_to directory {report.parent} does not exist")
        if str(report) in seen_reports:
            problems.append(f"{topic}: report_to {report} is also written by {seen_reports[str(report)]}")
        seen_reports[str(report)] = topic
        for p in lane["owns"]:
            owned.append((idx, topic, Path(top).resolve(), norm_owned(p)))

    for i, (n1, t1, r1, p1) in enumerate(owned):
        for n2, t2, r2, p2 in owned[i + 1:]:
            if n1 != n2 and r1 == r2 and overlaps(p1, p2):
                problems.append(f"{t1} owns {p1 or '.'!r} and {t2} owns {p2 or '.'!r} in the same repo {r1}")
    return problems


def norm_owned(p: str) -> str:
    """'./src/a/' → 'src/a'; '.', './', '/' and '' → '' (the whole repo)."""
    parts = [x for x in str(p).replace("\\", "/").split("/") if x not in ("", ".")]
    return "/".join(parts)


def overlaps(a: str, b: str) -> bool:
    if a == "" or b == "":
        return True
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: validate-lane-manifest.py <manifest.yaml|json> [SKILL.md]", file=sys.stderr)
        return 2
    manifest = load(Path(argv[1]))
    skill = Path(argv[2]) if len(argv) > 2 else HERE / "SKILL.md"
    if not isinstance(manifest, dict):
        print(f"lane-manifest: the manifest must be a mapping, got {type(manifest).__name__}")
        return 1
    problems = check(manifest, skill)
    for p in problems:
        print(f"lane-manifest: {p}")
    if not problems:
        print(f"lane-manifest: ok ({len(manifest.get('lanes') or [])} lanes)")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
