#!/usr/bin/env python3
"""The three controls of the AIDD common control (H17).

  C-ITER     DOT-INC-001/002/009/012/013/019/037  unproductive iteration
  C-DECISION DOT-INC-003/005/007/008/014/025      unnecessary approval waits
  C-EVIDENCE DOT-INC-006/010/017/020/026/033/043  evidence-free completion

Each returns {"decision": "allow"|"block"|"warn", "rule": ..., "reason": ...}.
Adapters translate that into each harness's wire format.
"""

from __future__ import annotations

import hashlib
import re
import time
from pathlib import Path

from aidd_cc_eval import deadline_status, file_sha
from aidd_cc_text import (
    DELETE_KIND_RE,
    WRITE_KIND_RE,
    clause_of,
    cmd_in_ledger,
    command_bound,
    segment_runs,
    shell_segments,
    shell_segments_with_separators,
    is_confirmation_question,
    is_trivial_cmd,
    denominator_mismatch,
    evidence_commands,
    incomplete_evidence_lines,
    has_completion_claim,
    has_persist_claim,
    has_push_claim,
    has_unmet_report,
    matching_decision,
    mutated,
    normalize_cmd,
    readback_claims,
)

ITER_THRESHOLD = 4  # the 4th occurrence with no progress is blocked
ITER_WINDOW = 20
TEST_RE = re.compile(
    r"(pytest|jest|vitest|npm test|pnpm test|bun test|go test|cargo test|bash tests?/|python3? -m unittest|make test)"
)
BUILD_RE = re.compile(r"(npm run build|pnpm build|tsc\b|cargo build|go build|make\b)")
LINT_RE = re.compile(r"(eslint|ruff|flake8|shellcheck|prettier|black\b)")


def family(tool: str, tool_input: dict) -> str:
    """Coarse command family for streak detection (surface form only)."""
    if tool in ("Edit", "Write", "MultiEdit", "edit", "write"):
        return "edit:" + str(
            tool_input.get("file_path") or tool_input.get("path") or "?"
        )
    cmd = str(tool_input.get("command") or tool_input.get("cmd") or "")
    if TEST_RE.search(cmd):
        return "test-run"
    if BUILD_RE.search(cmd):
        return "build"
    if LINT_RE.search(cmd):
        return "lint"
    return "other"


def _norm_key(tool: str, tool_input: dict) -> str:
    if tool in ("Edit", "Write", "MultiEdit"):
        import json as _json
        body = (str(tool_input.get("old_string", "")) + "\x00" + str(tool_input.get("new_string", ""))
                + "\x00" + str(tool_input.get("content", ""))
                + "\x00" + _json.dumps(tool_input.get("edits", ""), ensure_ascii=False, sort_keys=True))
        digest = hashlib.sha256(body.encode("utf-8", "replace")).hexdigest()[:12]
        return f"edit:{tool_input.get('file_path', '')}:{digest}"   # distinct edits differ (P2-5)
    wd = str(tool_input.get("workdir") or tool_input.get("cwd") or "")
    return normalize_cmd(str(tool_input.get("command") or ""))[:4000] + (f" @{wd}" if wd else "")


def iteration_check(rows: list[dict], meta: dict, tool: str, tool_input: dict) -> dict:
    """C-ITER: the same command recurs with no progress delta.

    Counts occurrences of this exact key among the last ITER_WINDOW pre rows
    (interleaved edits / `true` calls do NOT reset the count: edit-test-edit-test
    with the same failing test is the dot loop).  A progress delta resets it:
    (a) the key's recorded rc changed between occurrences, or (b) a hypothesis
    note was recorded after the first occurrence.  The 4th occurrence without
    a delta is blocked.  Mutation `iter.progress-delta` ignores (a)/(b);
    `iter.threshold` disables the block.
    """
    key = _norm_key(tool, tool_input)
    fam = family(tool, tool_input)
    if fam == "other" and not key.startswith("edit:"):
        return {"decision": "allow", "rule": "iter", "streak": 0}
    note_ts = max([n["ts"] for n in meta.get("notes", [])] or [0])
    pres = [r for r in rows if r.get("event") == "pre"][-ITER_WINDOW:]
    same = [r for r in pres if r.get("key") == key]
    if same and note_ts > same[0].get("ts", 0) and not mutated("iter.progress-delta"):
        same = [r for r in same if r.get("ts", 0) > note_ts]
    rcs = [r.get("rc") for r in rows if r.get("event") == "post" and r.get("key") == key]
    if len(set(rcs)) > 1 and not mutated("iter.progress-delta"):
        last_change = max(i for i in range(1, len(rcs)) if rcs[i] != rcs[i - 1])
        same = same[-(len(rcs) - last_change):] if len(rcs) - last_change < len(same) else same[-1:]
    streak = len(same)
    if streak >= ITER_THRESHOLD - 1 and not mutated("iter.threshold"):
        sid = meta.get("session", "<session>")
        return {"decision": "block", "rule": "iter.repeat-without-delta", "streak": streak + 1,
                "reason": (f"this would be occurrence {streak + 1} of the same {fam} command with no progress "
                           "delta (rc unchanged, no new hypothesis). Record the hypothesis and the minimal "
                           f"change first: python3 ~/.claude/hooks/lib/aidd_cc.py note --agent {meta.get('agent', 'claude-code')} --session {sid} "
                           "--hypothesis '...' --change '...'")}
    return {"decision": "allow", "rule": "iter", "streak": streak}


def register_note(meta: dict, hypothesis: str, change: str) -> dict:
    digest = hashlib.sha256((hypothesis + "\n" + change).encode()).hexdigest()
    if any(n["sha"] == digest for n in meta.get("notes", [])) and not mutated(
        "iter.progress-delta"
    ):
        return {
            "decision": "block",
            "rule": "iter.note-duplicate",
            "reason": "identical hypothesis already recorded; a repeat is not a new hypothesis",
        }
    meta.setdefault("notes", []).append(
        {
            "ts": time.time(),
            "sha": digest,
            "hypothesis": hypothesis[:300],
            "change": change[:300],
        }
    )
    return {"decision": "allow", "rule": "iter.note", "sha": digest}


def question_check(meta: dict, question: str) -> dict:
    """C-DECISION: refuse to re-ask a yes/no confirmation the user already gave.

    Only confirmation-shaped questions are candidates (choice / destructive
    questions pass), and only decisions that carried an approval word count.
    A question that passes is remembered as pending so a short `OK` reply can
    bind to it (reviewer-e #8)."""
    if not is_confirmation_question(question):
        meta.setdefault("questions", []).append({"ts": time.time(), "text": question[:600]})
        return {"decision": "allow", "rule": "decision.not-a-confirmation", "remember": True}
    hit = matching_decision(question, meta.get("decisions", []))
    if hit:
        return {"decision": "block", "rule": "decision.already-answered",
                "reason": (f"already decided by the user at {hit['at']} (overlap {hit['score']}): "
                           f"\"{hit['text'][:160]}\" — proceed on that decision instead of re-asking"),
                "decision_ref": hit["sha"]}
    meta.setdefault("questions", []).append({"ts": time.time(), "text": question[:600]})
    return {"decision": "allow", "rule": "decision", "remember": True}


def permission_check(meta: dict, request_text: str, request_cmd: str = "", request_path: str = "") -> dict:
    """C-DECISION for permission prompts: allow only when a user decision binds it.

    Commands: the exact operation must appear whole in the decision text.
    Edit/Write by path: the path must appear whole AND the decision must name a
    write-kind operation (修正 / edit / update …) and no delete-kind word — an
    approval to `cat` or `削除` a file never allows writing it (reviewer-e #2).
    Never denies; absence of a binding decision means "no opinion".
    Mutation `approval.binding` falls back to topical overlap (the defect).
    """
    decisions = meta.get("decisions", [])
    for d in decisions:
        dtext = d.get("text", "")
        if request_cmd and command_bound(dtext, request_cmd):
            return {"decision": "allow", "rule": "decision.inherited", "decision_ref": d["sha"],
                    "reason": f"user decision {d['at']} names this exact request"}
        # The write verb must sit in the SAME clause as the path (Codex r6 P1-b), and verbs
        # inside the file name itself do not count (Codex r5 P1).
        kind_text = clause_of(dtext, request_path).replace(request_path, " ") if request_path else dtext
        if request_path and not request_cmd and command_bound(dtext, request_path) \
                and WRITE_KIND_RE.search(kind_text) and not DELETE_KIND_RE.search(kind_text):
            return {"decision": "allow", "rule": "decision.inherited", "decision_ref": d["sha"],
                    "reason": f"user decision {d['at']} names this path with a write-kind operation"}
    if mutated("approval.binding"):
        hit = matching_decision(request_text, decisions, threshold=0.5)
        if hit:
            return {"decision": "allow", "rule": "decision.unbound", "decision_ref": hit["sha"],
                    "reason": "mutated: topical overlap only"}
    return {"decision": "none", "rule": "decision"}


def _executed_commands(rows: list[dict]) -> list[str]:
    return [
        str(r.get("cmd", "")) for r in rows if r.get("event") == "post" and r.get("cmd")
    ]


def _line_rc_applies(line: str) -> bool:
    """The recorded rc describes every segment only for a single command or a
    pure `&&` chain; `;`, `||`, `|`, `&` can mask a failure."""
    parts = shell_segments_with_separators(line)
    seps = {sp for _x, sp in parts if sp}
    return len(parts) == 1 or seps <= {"&&"}


def _rc_for(rows: list[dict], cited: str):
    """Exit status attributable to the cited command.  Whole-line citations and
    segment matches both get the line's rc only when nothing in the line can
    mask a failure (`pytest -q; true` cited verbatim is still UNKNOWN,
    Codex r5 P2-a)."""
    norm = re.sub(r"\s+", " ", cited.strip())
    for r in reversed(rows):
        if r.get("event") != "post":
            continue
        line = str(r.get("cmd", ""))
        whole = re.sub(r"\s+", " ", line.strip()) == norm
        seg_hit = any(segment_runs(seg, norm) for seg, _sp in shell_segments_with_separators(line))
        if whole or seg_hit:
            parts = shell_segments_with_separators(line)
            if (r.get("rc_src") == "marker" and len(parts) == 2
                    and re.fullmatch(r"echo exit=\$\?", parts[1][0]) and (whole or segment_runs(parts[0][0], norm))):
                return r.get("rc"), r.get("out_bytes", 0)   # `X; echo exit=$?`: the marker IS X's status (Codex r6 P2-a)
            return (r.get("rc") if _line_rc_applies(line) else None), r.get("out_bytes", 0)
    return None, 0


WRITE_CMD_RE = re.compile(r"^(cp|mv|tee|install|rsync|ln|touch|dd|patch|git apply|git checkout|sed -i|curl .*-o|wget .*-O|python3? .*\.py|node .*\.m?js|bash .*\.sh)\b")


WRITE_LAST_RE = re.compile(r"^(cp|mv|rsync|install|ln)\b")
WRITE_ALL_RE = re.compile(r"^(tee|touch|patch|git apply|git checkout|sed -i)\b")


def _touched_paths(rows: list[dict]) -> set[str]:
    """Absolute paths this session WROTE: Edit/Write keys, the destination of
    cp/mv/rsync/install/ln (last argument only — the source is not written,
    Codex r3 P2-3), the arguments of tee/touch/patch/sed -i, and `>` redirection
    targets.  Merely mentioning a path does not count."""
    out = set()
    for r in rows:
        if r.get("event") != "post" or r.get("rc") not in (0, None) or (r.get("rc") is None and not str(r.get("key", "")).startswith("edit:")):
            continue  # only writes that actually succeeded (Codex r4 P2-e)
        cwd = str(r.get("cwd") or "")
        key = str(r.get("key", ""))
        cands = []
        if r.get("cmd") and not _line_rc_applies(str(r.get("cmd"))):
            continue  # `cp … || true`: the copy's own success is unknown (Codex r5 P2-b)
        if key.startswith("edit:"):
            cands.append(key[5:].rsplit(":", 1)[0] if key.count(":") >= 2 else key[5:])
        for seg in shell_segments(str(r.get("cmd", ""))):
            toks = [t for t in re.findall(r"[\w./~-]+", seg) if "/" in t or "." in t]
            if WRITE_LAST_RE.match(seg) and toks:
                cands.append(toks[-1])
            elif WRITE_ALL_RE.match(seg):
                cands += toks
            cands += re.findall(r"\d?>>?\s*([\w./~-]+)", seg)
        for c in cands:
            p = Path(c).expanduser()
            if not p.is_absolute():
                p = Path(cwd) / p if cwd else p
            try:
                out.add(str(p.resolve()))
            except OSError:
                out.add(str(p))
    return out


def _push_executed(rows: list[dict]) -> bool:
    """A push/merge counts only from a successful post row whose line is a
    single segment or an `&&` chain (`false && git push …; true` is not a push)."""
    for r in rows:
        if r.get("event") != "post" or r.get("rc") != 0:
            continue
        parts = shell_segments_with_separators(str(r.get("cmd", "")))
        seps = {s for _x, s in parts if s}
        if len(parts) > 1 and not seps <= {"&&"}:
            continue
        for seg, _sep in parts:
            if re.match(r"(git push|gh pr merge|git merge)\b", seg) and not re.search(r"(--dry-run|\s-n\b)", seg):
                return True
    return False


def stop_check(meta: dict, rows: list[dict], text: str, cwd: str) -> dict:
    """C-EVIDENCE: a completion claim must be bound to executed, readable evidence."""
    problems: list[str] = []
    ds = deadline_status(meta.get("deadline"))
    if (
        ds.get("passed")
        and not has_unmet_report(text)
        and not mutated("deadline.unmet-report")
    ):
        problems.append(
            "deadline passed: report 未達 with the original deadline and real elapsed (DOT-INC-004/045)"
        )
    if not (has_completion_claim(text) or has_persist_claim(text)):
        return _verdict(problems)
    cmds = evidence_commands(text)
    for bad in incomplete_evidence_lines(text):
        if not mutated("evidence.trailer"):
            problems.append(f"incomplete Evidence trailer (need <cmd> | <output> | <time>): {bad}")
    if not cmds and not mutated("evidence.trailer"):
        problems.append(
            "completion claim without `Evidence: <cmd> | <output> | <time>` trailer (DOT-INC-010)"
        )
    executed = _executed_commands(rows)
    substantive = False
    for c in cmds:
        if not cmd_in_ledger(c, executed) and not mutated("evidence.executed"):
            problems.append(f"cited evidence command was not executed in this session: {c[:80]} (DOT-INC-017)")
            continue
        rc, out_bytes = _rc_for(rows, c)
        if rc is None and mutated("evidence.executed"):
            rc = 0  # the old behaviour: a typed command is trusted as if it ran and passed
        if rc in (None, 124, 126, 127) and not mutated("evidence.rc-unknown"):
            how = "" if rc is not None else " — this harness reported no exit status; run it as `<cmd>; echo exit=$?` so the status is in the output"
            problems.append(f"evidence command exit status {rc if rc is not None else 'unavailable'} is UNKNOWN, not a result: {c[:80]}{how} (DOT-INC-043)")
        elif rc != 0 and not mutated("evidence.rc-unknown"):
            problems.append(f"evidence command failed (rc={rc}) yet completion is claimed: {c[:80]} (DOT-INC-043)")
        if not is_trivial_cmd(c):
            substantive = True
    if cmds and not substantive and not mutated("evidence.trailer"):
        problems.append("every cited evidence command is trivial (ls/echo/cat/tail…); cite the command that produced the result")
    if has_persist_claim(text) and not mutated("evidence.readback"):
        problems.extend(_readback_problems(text, cwd, _touched_paths(rows)))
    if has_push_claim(text) and not mutated("evidence.readback"):
        if not _push_executed(rows):
            problems.append("push/merge claimed but no successful push/merge command in the session ledger (DOT-INC-026)")
    problems.extend(denominator_mismatch(text, meta.get("denominator")))
    problems.extend(source_set_problems(rows))
    return _verdict(problems)


def control_sha() -> str:
    """sha256 over the control source set (DOT-INC-023: fixed for the whole run)."""
    here = Path(__file__).resolve().parent
    h = hashlib.sha256()
    for name in ("aidd_cc.py", "aidd_cc_controls.py", "aidd_cc_text.py", "aidd_cc_eval.py", "aidd_cc_session.py"):
        try:
            h.update((here / name).read_bytes())
        except OSError:
            h.update(b"missing:" + name.encode())
    return h.hexdigest()


def source_set_problems(rows: list[dict]) -> list[str]:
    """DOT-INC-023: every tool row of the run must carry the same control sha as now."""
    if mutated("source-set.pin"):
        return []
    now = control_sha()
    seen = {r.get("cc_sha") for r in rows if r.get("cc_sha")}
    if seen and seen != {now}:
        return [f"control source set changed during the run ({len(seen)} shas seen); acceptance refused (DOT-INC-023)"]
    return []


def _readback_problems(text: str, cwd: str, touched: set[str]) -> list[str]:
    claims = readback_claims(text)
    if not claims:
        return ["save/deploy claimed without `Readback: <path> sha256=<hex>` (DOT-INC-017/026)"]
    out = []
    for path, sha in claims:
        p = Path(path).expanduser()
        if not p.is_absolute():
            p = Path(cwd) / p
        try:
            resolved = str(p.resolve())
        except OSError:
            resolved = str(p)
        actual = file_sha(p)
        if actual != sha:
            out.append(f"readback mismatch for {path}: claimed {sha[:12]} actual {str(actual)[:12]}")
        elif resolved not in touched:
            out.append(f"readback path {path} was never written or touched by a command in this session (not the saved artifact)")
    return out


def _verdict(problems: list[str]) -> dict:
    if problems:
        return {
            "decision": "block",
            "rule": "evidence",
            "problems": problems,
            "reason": "H17 evidence gate: " + " / ".join(problems),
        }
    return {"decision": "allow", "rule": "evidence"}
