#!/usr/bin/env python3
"""Session state for the AIDD common control (H17).

One JSON meta file + one JSONL tool ledger per (agent, session).
State dir: $AIDD_CC_STATE_DIR (default ~/.claude/state/aidd-cc).
"""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path

from aidd_cc_eval import append_row

LEDGER_DEFAULT = Path.home() / ".claude" / "hooks" / "ledger" / "guard-ledger.jsonl"


def state_dir() -> Path:
    d = Path(
        os.environ.get(
            "AIDD_CC_STATE_DIR", str(Path.home() / ".claude" / "state" / "aidd-cc")
        )
    )
    (d / "sessions").mkdir(parents=True, exist_ok=True)
    return d


def _slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", s or "unknown")[:120]


def meta_path(agent: str, session: str) -> Path:
    return state_dir() / "sessions" / f"{_slug(agent)}__{_slug(session)}.json"


def tools_path(agent: str, session: str) -> Path:
    return state_dir() / "sessions" / f"{_slug(agent)}__{_slug(session)}.jsonl"


def inherited_decisions() -> list[dict]:
    """DOT-INC-014/025: a parent passes its user decisions to the child via
    AIDD_CC_INHERIT=<parent meta json>.  Only decisions are inherited (scope is
    never widened); the child still records its own."""
    src = os.environ.get("AIDD_CC_INHERIT", "")
    if not src or not Path(src).exists():
        return []
    try:
        parent = json.loads(Path(src).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [
        dict(d, inherited_from=parent.get("session", "?"))
        for d in parent.get("decisions", [])
    ]


def load_meta(agent: str, session: str) -> dict:
    p = meta_path(agent, session)
    meta = None
    if p.exists():
        try:
            meta = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            meta = None
    if meta is not None:
        inherited_now = inherited_decisions()
        live = {d.get("sha") for d in inherited_now}
        # Drop inherited decisions the parent no longer holds (revoked there): the
        # parent's current state wins, every time the child loads (Codex r3 P1-3).
        meta["decisions"] = [
            d
            for d in meta.get("decisions", [])
            if not d.get("inherited_from") or d.get("sha") in live
        ]
        own = {d.get("sha") for d in meta["decisions"]}
        if not meta.get("revoked_at"):
            meta["decisions"] += [d for d in inherited_now if d.get("sha") not in own]
        return meta
    return {
        "agent": agent,
        "session": session,
        "created": time.time(),
        "decisions": inherited_decisions(),
        "notes": [],
        "deadline": None,
        "deadline_history": [],
        "denominator": None,
        "stop_blocks": 0,
        "last_assistant": "",
        "questions": [],
    }


def save_meta(agent: str, session: str, meta: dict) -> None:
    p = meta_path(agent, session)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, p)


def record_tool(agent: str, session: str, row: dict) -> None:
    row = dict(row, ts=time.time())
    append_row(tools_path(agent, session), row)


def load_tools(agent: str, session: str) -> list[dict]:
    p = tools_path(agent, session)
    if not p.exists():
        return []
    rows = []
    for line in p.read_text(encoding="utf-8").splitlines():
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def guard_ledger(
    component: str,
    event: str,
    decision: str,
    rule: str,
    detail: str,
    agent: str,
    session: str,
) -> None:
    """H6 defence ledger row (append-only, flock)."""
    path = Path(os.environ.get("AIDD_LEDGER_PATH", str(LEDGER_DEFAULT)))
    row = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "component": component,
        "hook": "aidd-cc",
        "event": event,
        "decision": decision,
        "rule": rule,
        "cmd_head": (detail or "")[:120],
        "source": os.environ.get("AIDD_LEDGER_SOURCE", "real"),
        "session": (session or "unset")[:80],
        "agent": agent,
    }
    try:
        append_row(path, row)
    except OSError:
        pass
