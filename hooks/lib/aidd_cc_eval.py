#!/usr/bin/env python3
"""Evaluator-side controls for the AIDD common control (H17).

Covers the measurement / identity / cost / state cases of the dot ledger that
are decidable inside an evaluator (DOT-INC-026, 029, 030, 031, 032, 034, 035,
036, 042, 043, 044).  Each public function names its cases.  All results are
plain dicts so the replay runner can persist them as evidence.

Mutation knock-out points: `mutated("<id>")` from aidd_cc_text.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

from aidd_cc_text import mutated

NOT_PROVEN = "NOT_PROVEN"
UNKNOWN = "UNKNOWN"


# --- attempts: DOT-INC-028 / 029 / 030 ---------------------------------------


def attempt_new(parent: str | None, ancestors: list[str], attempt_id: str) -> dict:
    """Reject reuse of any ancestor id; keep the full chain (never drop the origin)."""
    chain = list(ancestors)
    if parent:
        if parent not in chain:
            chain.append(parent)
    if attempt_id in chain and not mutated("attempt.ancestor-reuse"):
        return {
            "ok": False,
            "reason": f"attempt id {attempt_id} reuses an ancestor",
            "chain": chain,
        }
    return {"ok": True, "attempt_id": attempt_id, "chain": chain}


def chain_check(records: list[dict]) -> dict:
    """DOT-INC-030: every record must link back to the single origin; gaps and
    cycles are rejected (Codex review P2-10).  Total elapsed runs from the origin
    start to the latest end, including gaps and failures.
    """
    by_id = {r["attempt_id"]: r for r in records}
    origins = [r for r in records if not r.get("parent_attempt_id")]
    if len(origins) != 1:
        return {"ok": False, "reason": f"expected exactly one origin, found {len(origins)}"}
    origin = origins[0]["attempt_id"]
    bad = []
    for r in records:
        seen, cur = set(), r["attempt_id"]
        while cur and cur != origin:
            if cur in seen or cur not in by_id:
                bad.append(r["attempt_id"])
                break
            seen.add(cur)
            cur = by_id[cur].get("parent_attempt_id")
    if bad and not mutated("attempt.chain"):
        return {"ok": False, "reason": "chain gap or cycle: not every attempt reaches the origin", "attempts": bad}
    start = min(r["started_at"] for r in records)
    end = max(r["ended_at"] for r in records)
    return {"ok": True, "origin": origin, "total_elapsed_sec": round(end - start, 3)}


def deadline_status(deadline_epoch: float | None, now: float | None = None) -> dict:
    now = time.time() if now is None else now
    if deadline_epoch is None:
        return {"set": False}
    return {
        "set": True,
        "passed": now > deadline_epoch,
        "remaining_sec": round(deadline_epoch - now, 1),
    }


def deadline_set(meta: dict, deadline_epoch: float, reason: str | None) -> dict:
    """Write-once. A later set keeps the original and records the supersede.

    Mutation `deadline.immutable` lets a later set silently replace the original
    (the dot failure: deadline recomputed from the last attempt start).
    """
    history = list(meta.get("deadline_history", []))
    if meta.get("deadline") is not None and not mutated("deadline.immutable"):
        if not reason:
            return {
                "ok": False,
                "reason": "deadline already set; pass --supersede <reason> to add a later one",
                "original": meta["deadline"],
            }
        history.append(
            {"deadline": deadline_epoch, "reason": reason, "at": time.time()}
        )
        return {"ok": True, "deadline": meta["deadline"], "superseded_by": history}
    return {"ok": True, "deadline": deadline_epoch, "deadline_history": history}


# --- speed comparison: DOT-INC-032 / 034 / 035 / 036 ---------------------------


def speed_compare(on: dict, off: dict, required_ratio: float = 2.0) -> dict:
    """Compare two arms strictly.

    Each arm: {model, grader_version, start_checkpoint, elapsed_sec, graded_ok,
               interventions: [..]}.  Returns a verdict dict, never a bare number.
    """
    problems = []
    if on.get("model") != off.get("model") and not mutated("metrics.model-identity"):
        problems.append("model mismatch: harness effect not separable (DOT-INC-034)")
    if on.get("grader_version") != off.get("grader_version") and not mutated(
        "metrics.grader-version"
    ):
        problems.append("grader version differs: confounded (DOT-INC-036)")
    if on.get("start_checkpoint") != off.get("start_checkpoint") and not mutated(
        "metrics.grader-version"
    ):
        problems.append("start checkpoint differs: confounded (DOT-INC-036)")
    for arm_name, arm in (("on", on), ("off", off)):
        if arm.get("interventions") and not mutated("metrics.grader-version"):
            problems.append(
                f"{arm_name} arm had interventions {arm['interventions']}: confounded (DOT-INC-036)"
            )
    if on.get("elapsed_sec") in (None, 0) or off.get("elapsed_sec") in (None, 0):
        return {
            "verdict": NOT_PROVEN,
            "reason": "missing elapsed",
            "problems": problems,
        }
    if not (on.get("graded_ok") is True and off.get("graded_ok") is True):
        return {"verdict": NOT_PROVEN, "reason": "both arms must be graded_ok=true (Codex r2 P2-j)", "problems": problems}
    ratio = off["elapsed_sec"] / on["elapsed_sec"]
    shown = round(ratio, 5) if not mutated("metrics.rounding") else round(ratio)
    # Pass/fail uses the RAW ratio (Codex review P2-11); rounding is display only.
    meets = (ratio if not mutated("metrics.rounding") else shown) >= required_ratio
    verdict = "CONFOUNDED" if problems else ("MET" if meets else "UNMET")
    return {
        "verdict": verdict,
        "ratio": shown,
        "required": required_ratio,
        "problems": problems,
        "single_run": True,
    }


def historic_speedup(historic_elapsed: float | None, new_elapsed: float) -> dict:
    """DOT-INC-032: no historic time -> NOT_PROVEN, never estimated from commit gaps."""
    if historic_elapsed is None and not mutated("metrics.null-history"):
        return {
            "verdict": NOT_PROVEN,
            "historic_elapsed": None,
            "new_elapsed": new_elapsed,
        }
    hist = historic_elapsed if historic_elapsed is not None else 0.0
    return {"verdict": "RATIO", "ratio": (hist / new_elapsed) if new_elapsed else None}


# --- cost: DOT-INC-042 ---------------------------------------------------------


def cost_reconcile(entries: list[dict], contract_cap: float | None) -> dict:
    """Observed, unknown, reserved and billed are kept apart; unknown is never 0."""
    observed = sum(e["usd"] for e in entries if isinstance(e.get("usd"), (int, float)))
    unknown = [e.get("id", "?") for e in entries if e.get("usd") is None]
    if unknown and mutated("cost.unknown-zero"):
        unknown = []
    return {
        "observed_usd": round(observed, 6),
        "unknown_entries": unknown,
        "accepted_total_usd": None if unknown else round(observed, 6),
        "contract_cap_usd": contract_cap,
        "billed_actual_usd": None,
    }


# --- concurrency-safe append: DOT-INC-031 --------------------------------------


def append_row(path: Path, row: dict) -> None:
    """flock-protected O_APPEND write; a mutated version does read-modify-write."""
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(row, ensure_ascii=False) + "\n"
    if mutated("ledger.flock"):
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        time.sleep(0.002)
        path.write_text(existing + line, encoding="utf-8")
        return
    with open(path, "a", encoding="utf-8") as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        fh.write(line)
        fh.flush()
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


# --- collection: DOT-INC-043 / 044 ---------------------------------------------


def collect(cmd: list[str], timeout: float = 60.0) -> dict:
    """Run a probe and classify: OK / NEGATIVE / UNKNOWN.

    rc 127/126 (command missing/not executable), timeout, or a probe that
    produced no output at all are UNKNOWN, never a clean negative.  A
    legitimate negative result is rc!=0 with output explaining it.
    """
    started = time.time()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        rc, out, err = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return {
            "status": UNKNOWN,
            "rc": None,
            "reason": "timeout",
            "elapsed": round(time.time() - started, 3),
        }
    except FileNotFoundError:
        rc, out, err = 127, "", "command not found"
    rec = {
        "rc": rc,
        "stdout_sha": _sha(out),
        "stderr_sha": _sha(err),
        "stdout_bytes": len(out),
        "stderr_bytes": len(err),
        "elapsed": round(time.time() - started, 3),
    }
    if mutated("collect.rc-unknown"):
        rec["status"] = "OK" if rc == 0 else "NEGATIVE"
        return rec
    if rc in (126, 127) or rc is None:
        rec["status"] = UNKNOWN
        rec["reason"] = "collector not executable"
    elif rc != 0 and not out and not err:
        rec["status"] = UNKNOWN
        rec["reason"] = "non-zero without any output"
    elif rc == 0:
        rec["status"] = "OK"
    else:
        rec["status"] = "NEGATIVE"
    return rec


def judge_host(ping: dict, ssh: dict) -> dict:
    """DOT-INC-044: ping and ssh are judged separately; UNKNOWN never passes."""
    if ping["status"] == UNKNOWN or ssh["status"] == UNKNOWN:
        return {
            "verdict": UNKNOWN,
            "reason": "collector abnormal",
            "ping": ping["status"],
            "ssh": ssh["status"],
        }
    if ping["status"] == "NEGATIVE" and ssh["status"] == "NEGATIVE":
        return {
            "verdict": "DOWN_CONFIRMED",
            "ping": ping["status"],
            "ssh": ssh["status"],
        }
    return {"verdict": "UP", "ping": ping["status"], "ssh": ssh["status"]}


# --- candidate vs original: DOT-INC-026 / 027 ----------------------------------

STATES = ("candidate_verified", "applied", "deployed", "actual_entry_verified")


def promote(
    record: dict, to_state: str, original_path: Path, candidate_sha: str
) -> dict:
    """State machine with readback: `applied` requires the original to equal the candidate."""
    if to_state not in STATES:
        return {"ok": False, "reason": f"unknown state {to_state}"}
    order = STATES.index(to_state)
    current = record.get("state")
    if (
        current is not None
        and STATES.index(current) + 1 != order
        and not mutated("state.candidate-as-original")
    ):
        return {"ok": False, "reason": f"cannot jump from {current} to {to_state}"}
    if current is None and order != 0 and not mutated("state.candidate-as-original"):
        return {"ok": False, "reason": "must start at candidate_verified"}
    if to_state == "applied":
        actual = _sha(original_path.read_bytes()) if original_path.exists() else None
        if actual != candidate_sha and not mutated("state.candidate-as-original"):
            return {
                "ok": False,
                "reason": "original sha != candidate sha (readback)",
                "original_sha": actual,
                "candidate_sha": candidate_sha,
            }
    return {"ok": True, "state": to_state, "candidate_sha": candidate_sha}


def _sha(data) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str | None:
    try:
        return _sha(path.read_bytes())
    except OSError:
        return None


def env_fingerprint() -> dict:
    return {"pid": os.getpid(), "cwd": os.getcwd(), "ts": time.time()}
