#!/usr/bin/env python3
"""Replay engine for aidd-governance#174 (DOT-INC-001..047).

    python3 -I tests/dot-replay/run_replay.py [--deployed] [--out DIR] [--only ID,...]

For every LOCAL case and every agent the oracle runs four arms:
  before           AIDD_CC_DISABLE=1          -> expected: incident NOT blocked (old failure reproduced)
  fixed            control on                 -> expected: incident blocked AND benign allowed
  mutation         AIDD_CC_MUTATE=<control>   -> expected: incident NOT blocked (one-sided mutation goes red)
  positive_control control on, benign input   -> expected: allowed (no over-blocking)
`--deployed` resolves the entry scripts from the *registered* hook configs
(~/.claude/settings.json, ~/.codex/hooks.json, ~/.cursor/hooks.json) instead of
the repo, so the actual_entry column is the real registered path + its sha256.
Non-LOCAL cases are written with their status and reason; nothing is dropped.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "hooks" / "lib"))
import cases as C  # noqa: E402
from oracles import RUNTIME_OK, Ctx  # noqa: E402


def sha(p: Path) -> str | None:
    try:
        return hashlib.sha256(p.read_bytes()).hexdigest()
    except OSError:
        return None


def registered_entries() -> dict:
    """Entry scripts as the harnesses register them (actual entry)."""
    home = Path.home()
    out = {}
    s = json.loads((home / ".claude" / "settings.json").read_text())
    for grp in s["hooks"].get("Stop", []):
        for h in grp["hooks"]:
            if "aidd-cc-claude.sh" in h["command"]:
                out["claude"] = Path(os.path.expanduser(h["command"].split()[-1]))
    cx = json.loads((home / ".codex" / "hooks.json").read_text())
    for grp in cx["hooks"].get("Stop", []):
        for h in grp["hooks"]:
            if "aidd-cc-codex.sh" in h["command"]:
                out["codex"] = Path(os.path.expanduser(h["command"].split()[-1]))
    cu = json.loads((home / ".cursor" / "hooks.json").read_text())
    for h in cu["hooks"].get("stop", []):
        if "aidd-cc-cursor.sh" in h["command"]:
            out["cursor"] = Path(os.path.expanduser(h["command"]))
    out["cc"] = home / ".claude" / "hooks" / "lib" / "aidd_cc.py"
    out["opencode"] = home / ".config" / "opencode" / "plugins" / "aidd-cc.ts"
    out["pi"] = home / ".pi" / "agent" / "extensions" / "aidd-cc.ts"
    return {**out, **_control_set(home / ".claude" / "hooks" / "lib")}


LIB_PINNED = (
    "aidd_cc_controls.py",
    "aidd_cc_text.py",
    "aidd_cc_eval.py",
    "aidd_cc_session.py",
    "aidd-cc-adapter.sh",
)


def _control_set(lib: Path) -> dict:
    """aidd-governance#186 P2-3: pin EVERY file the verdict depends on, not only aidd_cc.py and the
    entry scripts — the #186 repair changed aidd_cc_controls.py / aidd_cc_text.py, which the old
    summary could not tell apart."""
    return {name: lib / name for name in LIB_PINNED}


def control_shas(lib: Path) -> dict:
    """control_sha / control_set_sha as computed by the lib under test (repo or deployed)."""
    code = (
        "import sys; sys.path.insert(0, sys.argv[1]); import aidd_cc_controls as c; import json; "
        "print(json.dumps({'control_sha': c.control_sha(), 'control_set_sha': getattr(c, 'control_set_sha', lambda: None)()}))"
    )
    try:
        p = subprocess.run([sys.executable, "-I", "-c", code, str(lib)], capture_output=True, text=True, timeout=30)
        return json.loads(p.stdout.strip() or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


def repo_entries() -> dict:
    return {
        "claude": ROOT / "hooks" / "aidd-cc-claude.sh",
        "codex": ROOT / "hooks" / "codex" / "aidd-cc-codex.sh",
        "cursor": ROOT / "hooks" / "cursor" / "aidd-cc-cursor.sh",
        "cc": ROOT / "hooks" / "lib" / "aidd_cc.py",
        "opencode": ROOT / "opencode" / "aidd-cc.ts",
        "pi": ROOT / "pi" / "aidd-cc.ts",
        **_control_set(ROOT / "hooks" / "lib"),
    }


def run_arm(
    oracle, agent: str, entry: dict, state_root: Path, env: dict, extra: dict
) -> dict:
    ctx = Ctx(
        entry, state_root / f"{agent}-{int(time.time() * 1000)}", {**env, **extra}
    )
    ctx.state_dir.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    try:
        res = oracle(ctx, agent)
        err = None
    except Exception as e:  # noqa: BLE001 - the error is the evidence
        res, err = {"incident_blocked": None, "benign_allowed": None}, repr(e)
    return {
        **res,
        "error": err,
        "elapsed_sec": round(time.time() - t0, 3),
        "session": ctx.sid,
        "calls": ctx.calls,
        "started_at": t0,
    }


def verdicts(before: dict, fixed: dict, mut: dict) -> dict:
    v = {
        "before": "FAIL_REPRODUCED"
        if before["incident_blocked"] is False
        else ("NOT_REPRODUCED" if before["incident_blocked"] else "ERROR"),
        "fixed": "PASS"
        if (fixed["incident_blocked"] and fixed["benign_allowed"])
        else ("ERROR" if fixed["incident_blocked"] is None else "FAIL"),
        "mutation": "ERROR" if mut["incident_blocked"] is None else ("RED" if not (mut["incident_blocked"] and mut["benign_allowed"]) else "NOT_RED"),
        "positive_control": "PASS" if fixed["benign_allowed"] else "FAIL",
    }
    v["gate"] = all(
        v[k] in ("FAIL_REPRODUCED", "PASS", "RED")
        for k in ("before", "fixed", "mutation", "positive_control")
    )
    return v


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--deployed", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--only")
    args = ap.parse_args()
    entry = registered_entries() if args.deployed else repo_entries()
    out_dir = Path(
        args.out or (HERE / "results" / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    state_root = Path(tempfile.mkdtemp(prefix="dot-replay-"))
    env = {
        "AIDD_LEDGER_PATH": str(out_dir / "h6-ledger.jsonl"),
        "AIDD_LEDGER_SOURCE": "test",
        "AIDD_CC_MAX_STOP_BLOCKS": "99",
    }
    only = set(args.only.split(",")) if args.only else None
    results = []
    skipped_arms: set[str] = set()
    for cid, spec in C.CASES.items():
        if only and cid not in only:
            continue
        rec = {
            "case_id": cid,
            "status": spec["status"],
            "note": spec.get("note", ""),
            "arms": {},
        }
        if spec["oracle"] is None:
            rec["gate"] = False
            results.append(rec)
            continue
        rec["mutation_control"] = spec["mutate"]
        gates = []
        for agent in spec["agents"]:
            if agent in RUNTIME_OK and not RUNTIME_OK[agent]:
                # The arm's runtime (bun / node>=22) is not installed here: recorded, never counted as a pass.
                rec["arms"][agent] = {"verdicts": {"gate": None, "skipped": f"runtime missing for {agent}"}}
                skipped_arms.add(agent)
                continue
            before = run_arm(
                spec["oracle"], agent, entry, state_root, env, {"AIDD_CC_DISABLE": "1"}
            )
            fixed = run_arm(spec["oracle"], agent, entry, state_root, env, {})
            mut = run_arm(
                spec["oracle"],
                agent,
                entry,
                state_root,
                env,
                {"AIDD_CC_MUTATE": spec["mutate"]},
            )
            v = verdicts(before, fixed, mut)
            ep = entry[agent] if agent in entry else entry["cc"]
            rec["arms"][agent] = {
                "verdicts": v,
                "entrypoint": str(ep),
                "entrypoint_sha256": sha(ep),
                "actual_entry": "registered" if args.deployed else "repo-path",
                "before": before,
                "fixed": fixed,
                "mutation": mut,
            }
            gates.append(v["gate"])
        rec["gate"] = all(gates) and bool(gates)
        results.append(rec)
        print(
            f"{cid} {'GATE-OK' if rec['gate'] else 'GATE-FAIL'} "
            + " ".join(f"{a}:{rec['arms'][a]['verdicts']}" for a in rec["arms"] if "gate" in rec["arms"][a]["verdicts"] and rec["arms"][a]["verdicts"]["gate"] is not None),
            flush=True,
        )
    summary = {
        "schema_version": "1.0",
        "issue": "Cor-Incorporated/aidd-governance#174",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": platform.node(),
        "python": platform.python_version(),
        "control_source_sha256": {k: sha(v) for k, v in entry.items()},
        **control_shas(entry["cc"].parent),
        "arm_runtime_skipped": sorted(skipped_arms),
        "actual_entry_mode": "registered" if args.deployed else "repo-path",
        "git_head": subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
        ).stdout.strip(),
        "denominator": len(C.CASES),
        "counts": {
            s: sum(1 for r in results if r["status"] == s)
            for s in ("LOCAL", "BLOCKED_PLATFORM", "BLOCKED_EXTERNAL", "UNRESOLVED")
        },
        "local_gate_ok": sum(
            1 for r in results if r["status"] == "LOCAL" and r["gate"]
        ),
        "overall_status": "NOT_ACCEPTED",  # kept until every case including non-LOCAL ones is closed by a human gate
        "results": results,
    }
    (out_dir / "replay-results.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                k: summary[k]
                for k in (
                    "denominator",
                    "counts",
                    "local_gate_ok",
                    "actual_entry_mode",
                    "git_head",
                )
            },
            ensure_ascii=False,
        )
    )
    print(f"written: {out_dir / 'replay-results.json'}")
    return 0 if summary["local_gate_ok"] == summary["counts"]["LOCAL"] else 1


if __name__ == "__main__":
    sys.exit(main())
