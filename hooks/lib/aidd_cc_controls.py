#!/usr/bin/env python3
"""The three controls of the AIDD common control (H17).

  C-ITER     DOT-INC-001/002/009/012/013/019/037  unproductive iteration
  C-DECISION DOT-INC-003/008                      re-asking an answered confirmation (auto-allow retired 2026-10-14)
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
    ADJUDICATION_RE,
    FIX_SUBJECT_RE,
    cmd_in_ledger,
    commit_subject,
    declared_status,
    has_commit_segment,
    strategy_kind,
    segment_runs,
    shell_segments_with_separators,
    is_confirmation_question,
    is_exit_echo_line,
    is_trivial_cmd,
    denominator_mismatch,
    evidence_trailers,
    incomplete_evidence_lines,
    output_field_matches,
    output_numbers_missing,
    has_completion_claim,
    has_persist_claim,
    has_push_claim,
    has_unmet_report,
    matching_decision,
    mutated,
    normalize_cmd,
    readback_claims,
    GIT_COMMIT_SEG_RE,
    shell_segments,
    commit_messages,
    WRAPPER_SEG_RE,
    fix_scopes,
    fix_scopes_from_output,
    landed_fix_scopes,
)

ITER_THRESHOLD = 4  # the 4th occurrence with no progress is blocked
REPAIR_FAMILY_THRESHOLD = (
    3  # aidd-governance#88: 3 same-family fix commits without re-adjudication
)
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

        body = (
            str(tool_input.get("old_string", ""))
            + "\x00"
            + str(tool_input.get("new_string", ""))
            + "\x00"
            + str(tool_input.get("content", ""))
            + "\x00"
            + _json.dumps(
                tool_input.get("edits", ""), ensure_ascii=False, sort_keys=True
            )
        )
        digest = hashlib.sha256(body.encode("utf-8", "replace")).hexdigest()[:12]
        return f"edit:{tool_input.get('file_path', '')}:{digest}"  # distinct edits differ (P2-5)
    wd = str(tool_input.get("workdir") or tool_input.get("cwd") or "")
    return normalize_cmd(str(tool_input.get("command") or ""))[:4000] + (
        f" @{wd}" if wd else ""
    )


def _message_scope(msg: str) -> str | None:
    fm = FIX_SUBJECT_RE.match(msg.split("\n", 1)[0])
    return fm.group(2).strip().lower() if fm else None


def _scope_fix_times(rows: list[dict], scope: str) -> list[float]:
    """ts of this session's successful fix(<scope>) commits (post rows; #186 R4: a log read is not a commit)."""
    return sorted(
        float(r.get("ts", 0))
        for r in rows
        if r.get("event") == "post"
        and r.get("rc") == 0
        and (
            scope
            in landed_fix_scopes(str(r.get("cmd", "")), str(r.get("out_sample", "")))
            or (
                has_commit_segment(str(r.get("cmd", "")))
                and scope in fix_scopes_from_output(str(r.get("out_sample", "")))
            )
        )
    )


def _strategy_cut(meta: dict, fix_times: list[float]) -> tuple[float, bool]:
    """(ts of the last re-adjudication that applies to this scope, HOLD already consumed for it).
    PIVOT / RETIRE always re-arm.  HOLD re-arms ONE time per cycle, and only a HOLD written while this scope had
    a running streak (a fix(<scope>) since the previous cut) counts for this scope — a HOLD recorded for another
    scope's streak is neither consumed nor a cut here (Codex review 2026-10-17 P2: HOLD state per scope)."""
    strat_ts, hold_used = 0.0, False
    for n in sorted(meta.get("notes", []), key=lambda n: n.get("ts", 0)):
        kind, ts = strategy_kind(n.get("hypothesis", "")), float(n.get("ts", 0))
        if kind in ("PIVOT", "RETIRE"):
            strat_ts, hold_used = ts, False
        elif (
            kind == "HOLD"
            and not hold_used
            and any(strat_ts < t <= ts for t in fix_times)
        ):
            strat_ts, hold_used = ts, True
    return strat_ts, hold_used


def repair_family_check(
    rows: list[dict], meta: dict, cmd: str, cwd: str = ""
) -> dict | None:
    """C-ITER-FAMILY (aidd-governance#88 at the session entry, found on
    2026-10-14 when this harness's own author ran 8 review→fix rounds on one
    feature): the 4th `fix(<scope>)` commit of the same scope, with no
    re-adjudication note since the first, is blocked.  A re-adjudication is a
    note whose hypothesis carries `STRATEGY: HOLD|PIVOT|RETIRE` (#88 closed
    vocabulary).  Normal development is untouched: feat/docs/test commits and
    fixes of different scopes never count."""
    if mutated("iter.repair-family"):
        return None
    # acceptance 2026-10-18 P2-b (#421): every fix(<scope>) commit segment of the line is judged, not only the first
    # (`git commit -m 'chore: x' && git commit -m 'fix(h17): …'` escaped both breakers at pre)
    for scope in fix_scopes(cmd):
        verdict = _repair_family_scope(rows, meta, cmd, cwd, scope)
        if verdict:
            return verdict
    return None


def _repair_family_scope(
    rows: list[dict], meta: dict, cmd: str, cwd: str, scope: str
) -> dict | None:
    # 2026-10-17 (this harness's own loop on claude-code-skills#418: 12 fix(h17) commits, 6 STRATEGY notes of
    # which 4 were HOLD, 8 review rounds): a note is a re-adjudication only once.  HOLD re-arms the counter ONE
    # time per PIVOT/RETIRE cycle; a second HOLD is ignored, so the next trip needs PIVOT / RETIRE or the
    # owner's decision (ADJUDICATION: <url> in a commit body, see branch_fix_streak).
    same_scope = [m for m in commit_messages(cmd or "") if _message_scope(m) == scope]
    branch = branch_fix_streak(
        cwd, cmd, scope, meta.get("agent", "claude-code"), meta.get("session", "unset")
    )
    # ADR-013: every fix(<scope>) commit of the line is judged against the branch's rulings — the cap holds whether or
    # not the commit carries a url (Codex: dropping the url re-opened a closed scope), and a line that chains two
    # commits cannot spend one url twice or push past the cap in one call (Codex: `fix a -m U2 && fix b -m U1`)
    verdict = _ruling_verdict(same_scope, branch, scope, meta)
    if verdict:
        return verdict
    if same_scope and ADJUDICATION_RE.search(same_scope[0]):
        # the FIRST fix(<scope>) commit of the line is the one judged (fix_scope reads it); a ruling on a later
        # commit of the same line is not on this commit (Codex r4 P2: `… && false && git commit -m 'fix(x): b' -m
        # 'ADJUDICATION: …'`)
        # the fix commit being made records the owner's decision in ITS OWN message (`-m 'fix(x): …' -m
        # 'ADJUDICATION: <url>'`, review 2026-10-17 P1): the remedy both breakers ask for.  A ruling in another
        # commit of the same line (`… && git commit -m docs -m 'ADJUDICATION: …'`), a shell comment or another
        # argument never lands on this commit (Codex r2/r3 P2).  Surface form by design — the url is auditable.
        return None
    fix_times = _scope_fix_times(rows, scope)
    strat_ts, hold_used = _strategy_cut(meta, fix_times)
    strat_ts = max(
        strat_ts, branch["adjudicated_ts"]
    )  # an adjudication commit also cuts the session streak
    if branch["count"] >= BRANCH_FIX_LIMIT:
        sid = meta.get("session", "<session>")
        return {
            "decision": "block",
            "rule": "iter.repair-family",
            "streak": branch["count"] + 1,
            "reason": (
                f"{branch['count']} fix({scope}) commits already on this branch since {branch['base']} with no owner "
                f"adjudication (this counts across sessions; claude-code-skills#418 ran 12 rounds). Stop repairing: get the "
                f"owner's decision and record it in the next commit body as `ADJUDICATION: <issue or PR comment url>` "
                f"(session {sid})"
            ),
        }
    prior = [t for t in fix_times if t > strat_ts]
    if len(prior) >= REPAIR_FAMILY_THRESHOLD:
        sid = meta.get("session", "<session>")
        subject = (commit_subject(cmd) or "")[:80]
        options = (
            "'STRATEGY: PIVOT|RETIRE — why' (HOLD was already used once for this scope; a second HOLD does not count), "
            "or the owner's decision as `ADJUDICATION: <url>` in the commit body"
            if hold_used
            else "'STRATEGY: HOLD|PIVOT|RETIRE — why'"
        )
        return {
            "decision": "block",
            "rule": "iter.repair-family",
            "streak": len(prior) + 1,
            "reason": (
                f"{len(prior)} fix({scope}) commits already landed in this session with no re-adjudication "
                f"(aidd-governance#88); this commit's subject: `{subject}`. Decide the strategy before the next repair: python3 "
                f"~/.claude/hooks/lib/aidd_cc.py note --agent {meta.get('agent', 'claude-code')} --session {sid} "
                f"--hypothesis {options} --change '...'"
            ),
        }
    return None


def _ruling_verdict(messages: list[str], branch: dict, scope: str, meta: dict) -> dict | None:
    """ADR-013, over every fix(<scope>) commit message of the line in order.  A ruling url releases one commit: the
    same url on a second fix(<scope>) commit of the branch (or twice in one line) is spent.  After
    MAX_ADJUDICATIONS_PER_SCOPE rulings on the branch no fix(<scope>) commit is released, with or without a url —
    the branch is closed for that scope and the work moves to a new branch whose PR states the pivot (opencode#353:
    7 follow-up fixes rode one url and the breaker never fired again).  Block-side; a fresh url below the cap releases."""
    sid = meta.get("session", "<session>")
    seen = list(branch.get("adjudications", []))
    for message in messages:
        if len(seen) >= MAX_ADJUDICATIONS_PER_SCOPE:
            return {
                "decision": "block",
                "rule": "iter.repair-family",
                "streak": branch["count"] + 1,
                "reason": (
                    f"this branch already carries {len(seen)} adjudicated fix({scope}) commits; the cap is "
                    f"{MAX_ADJUDICATIONS_PER_SCOPE} (ADR-013). The branch is closed for fix({scope}), with or without a "
                    f"ruling: move the work to a new branch whose PR states what changed in the approach, and have it "
                    f"accepted anew (session {sid})"
                ),
            }
        ruling = ADJUDICATION_RE.search(message)
        if not ruling:
            continue
        url = ruling.group(1).rstrip(".,;)")
        if url in seen:
            return {
                "decision": "block",
                "rule": "iter.repair-family",
                "streak": branch["count"] + 1,
                "reason": (
                    f"ADJUDICATION {url} was already used by an earlier fix({scope}) commit on this branch; a ruling "
                    f"releases exactly one commit (ADR-013). Stop: this is the repair loop the breaker exists for. Get a "
                    f"NEW decision (a new comment url) for THIS commit, or change the approach and start a new branch "
                    f"(session {sid})"
                ),
            }
        seen.append(url)
    return None


BRANCH_FIX_LIMIT = (
    6  # same-scope fix commits on one branch since its base, across sessions
)
# ADR-013 (owner, 2026-10-25, after 7 fix commits rode one adjudication url on opencode#353): a ruling releases exactly
# ONE commit, and a scope gets at most this many rulings on one branch; after that the branch is closed for fix(<scope>)
# and the work moves to a new branch whose PR states the pivot.
MAX_ADJUDICATIONS_PER_SCOPE = 3
BRANCH_BASES = ("origin/develop", "develop", "origin/main", "main")
GIT_C_RE = re.compile(  # `git [-c k=v | --opt[=v] | -x] … -C <dir>` / `--git-dir=<dir>` (review r2 P3: global options before -C)
    r"""(?:^|\s)(?:\S*/)?git\s+(?:(?:-c\s+\S+|--[\w-]+(?:=\S*)?|-[a-zA-Z]\S*)\s+)*?(?:-C\s*|--git-dir=\s*)(?:'([^']+)'|"([^"]+)"|(\S+))"""
)
CD_SEG_RE = re.compile(r"""^\s*cd\s+(?:'([^']+)'|"([^"]+)"|(\S+))\s*$""")
GIT_BUDGET_SEC = (
    6.0  # the whole branch check stays well inside the harness's 12 s hook budget
)


def _first_group(m) -> str | None:
    return next((g for g in m.groups() if g), None) if m else None


def _repo_for(cwd: str, cmd: str, scope: str | None = None) -> Path:
    """The repository the `git … commit` segment acts on: its own `-C <dir>` / `--git-dir=` (quoted paths allowed),
    resolved against the `cd <dir>` segments that precede it (chained cds apply in order), else that directory;
    no commit segment → cwd.  A `-C` on another git call in the same line is not it (Codex r2 P2: `git -C /other
    status && git -C /target commit`).  Unexpandable shell variables stay literal → not a repository → count 0."""
    cur = Path(cwd or ".")
    for seg in shell_segments(cmd or ""):
        wrapped = WRAPPER_SEG_RE.match(
            seg
        )  # bash -c 'cd /target && git commit …' (Codex r3 P2)
        if wrapped:
            return _repo_for(str(cur), wrapped.group("inner"), scope)
        cd = CD_SEG_RE.match(seg)
        if cd:
            p = Path(_first_group(cd) or ".").expanduser()
            cur = p if p.is_absolute() else cur / p
            continue
        if GIT_COMMIT_SEG_RE.match(seg):
            if (
                scope
                and scope not in fix_scopes(seg)
                and commit_subject(seg) is not None
            ):
                continue  # another commit of the line (chore / other scope); a heredoc commit, whose subject is
                # not inline here, stays a candidate (Codex re-review of #422)
            pick = _first_group(GIT_C_RE.search(seg))
            if not pick:
                return cur
            p = Path(pick).expanduser()
            return p if p.is_absolute() else cur / p
    return cur


def branch_fix_streak(
    cwd: str, cmd: str, scope: str, agent: str = "claude-code", session: str = "unset"
) -> dict:
    """fix(<scope>) commits on the current branch since its merge-base with develop/main (first-parent, so a
    merged-in branch's fixes are not this branch's streak), counted from the newest commit back to the newest
    one whose body carries `ADJUDICATION: <url>` (the owner's decision — for the branch, every scope); that
    commit's time is returned as `adjudicated_ts` so the session counter is cut at the same point.  Surface
    form from `git log`; a directory that is not a repository, or git failing, counts 0 (additive to the
    in-session breaker).  The whole check runs under GIT_BUDGET_SEC; a timeout writes an H6 error row instead
    of passing silently.  Known surface-form limits: `git commit -F file` has no subject here; a scope variant
    (`fix(h17-gate)`) is another scope; a fabricated ADJUDICATION url is accepted as written (auditable in the PR)."""
    import subprocess

    repo = _repo_for(cwd, cmd, scope)
    deadline = time.monotonic() + GIT_BUDGET_SEC
    none = {"count": 0, "base": "?", "adjudicated_ts": 0.0, "adjudications": []}

    def git(*args: str) -> str | None:
        left = deadline - time.monotonic()
        if left <= 0:
            raise subprocess.TimeoutExpired(args, GIT_BUDGET_SEC)
        p = subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            timeout=left,
        )
        return p.stdout if p.returncode == 0 else None

    base_name, base = "", ""
    try:
        for cand in BRANCH_BASES:
            out = git("merge-base", "HEAD", cand)
            if out and out.strip():
                base_name, base = cand, out.strip()
                break
        if not base:
            return none
        if (git("rev-parse", "HEAD") or "").strip() == base:
            return {**none, "base": base_name}
        log_out = (
            git(
                "log",
                "--first-parent",
                "--no-show-signature",
                "--format=%ct%x1f%B%x00",
                f"{base}..HEAD",
            )
            or ""
        )
    except (OSError, subprocess.TimeoutExpired):
        from aidd_cc_session import guard_ledger

        guard_ledger(
            "H17",
            "error",
            "unavailable",
            "iter.repair-family.git-timeout",
            str(repo)[:100],
            agent,
            session,
        )
        return none
    count, adjudicated_ts, cut = 0, 0.0, False
    adjudications: list[str] = []  # every ruling url on a fix(<scope>) commit of the branch, newest first (ADR-013)
    for entry in log_out.split("\x00"):  # newest first
        ct, _, body = entry.strip().partition("\x1f")
        body = body.strip()
        if not body:
            continue
        subject = body.split("\n", 1)[0]
        fm = FIX_SUBJECT_RE.match(subject)
        same = bool(fm) and fm.group(2).strip().lower() == scope
        ruling = ADJUDICATION_RE.search(body)
        if ruling and same:
            adjudications.append(ruling.group(1).rstrip(".,;)"))
        if ruling and not cut:
            # %ct is whole seconds: a session row written in the ruling's own second (before or after it) counts
            # toward the streak — errs to block (Codex r2 P2 chose this over +1 s, which dropped fixes made right
            # after the ruling); an unparsable time is no cut at all.
            try:
                adjudicated_ts = float(ct)
            except ValueError:
                adjudicated_ts = 0.0
            cut = True
        elif same and not cut:
            count += 1
    return {"count": count, "base": base_name, "adjudicated_ts": adjudicated_ts, "adjudications": adjudications}


def iteration_check(
    rows: list[dict], meta: dict, tool: str, tool_input: dict, cwd: str = ""
) -> dict:
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
    family_block = repair_family_check(
        rows,
        meta,
        str(tool_input.get("command") or ""),
        cwd or str(tool_input.get("workdir") or ""),
    )
    if family_block:
        return family_block
    if fam == "other" and not key.startswith("edit:"):
        return {"decision": "allow", "rule": "iter", "streak": 0}
    note_ts = max([n["ts"] for n in meta.get("notes", [])] or [0])
    pres = [r for r in rows if r.get("event") == "pre"][-ITER_WINDOW:]
    same = [r for r in pres if r.get("key") == key]
    if same and note_ts > same[0].get("ts", 0) and not mutated("iter.progress-delta"):
        same = [r for r in same if r.get("ts", 0) > note_ts]
    rcs = [
        r.get("rc")
        for r in rows
        if r.get("event") == "post"
        and r.get("key") == key
        and (mutated("iter.progress-delta") or r.get("ts", 0) > note_ts)
    ]  # same reset point as `same` (Codex r8 P2-a)
    if len(set(rcs)) > 1 and not mutated("iter.progress-delta"):
        last_change = max(i for i in range(1, len(rcs)) if rcs[i] != rcs[i - 1])
        same = (
            same[-(len(rcs) - last_change) :]
            if len(rcs) - last_change < len(same)
            else same[-1:]
        )
    streak = len(same)
    if streak >= ITER_THRESHOLD - 1 and not mutated("iter.threshold"):
        sid = meta.get("session", "<session>")
        return {
            "decision": "block",
            "rule": "iter.repeat-without-delta",
            "streak": streak + 1,
            "reason": (
                f"this would be occurrence {streak + 1} of the same {fam} command with no progress "
                "delta (rc unchanged, no new hypothesis). Record the hypothesis and the minimal "
                f"change first: python3 ~/.claude/hooks/lib/aidd_cc.py note --agent {meta.get('agent', 'claude-code')} --session {sid} "
                "--hypothesis '...' --change '...'"
            ),
        }
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
        meta.setdefault("questions", []).append(
            {"ts": time.time(), "text": question[:600]}
        )
        return {
            "decision": "allow",
            "rule": "decision.not-a-confirmation",
            "remember": True,
        }
    hit = matching_decision(question, meta.get("decisions", []))
    if hit:
        return {
            "decision": "block",
            "rule": "decision.already-answered",
            "reason": (
                f"already decided by the user at {hit['at']} (overlap {hit['score']}): "
                f'"{hit["text"][:160]}" — proceed on that decision instead of re-asking'
            ),
            "decision_ref": hit["sha"],
        }
    meta.setdefault("questions", []).append({"ts": time.time(), "text": question[:600]})
    return {"decision": "allow", "rule": "decision", "remember": True}


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


def _evidence_row(rows: list[dict], cited: str) -> dict | None:
    """The newest post row that ran the cited command: the whole line equals it, or a
    quote-aware segment equals it modulo redirections (same rule as cmd_in_ledger)."""
    norm = re.sub(r"\s+", " ", cited.strip())
    for r in reversed(rows):
        if r.get("event") != "post":
            continue
        line = str(r.get("cmd", ""))
        whole = re.sub(r"\s+", " ", line.strip()) == norm
        seg_hit = any(
            segment_runs(seg, norm) for seg, _sp in shell_segments_with_separators(line)
        )
        if whole or seg_hit:
            return r
    return None


def _rc_for(rows: list[dict], cited: str):
    """Exit status attributable to the cited command.  Whole-line citations and
    segment matches both get the line's rc only when nothing in the line can
    mask a failure (`pytest -q; true` cited verbatim is still UNKNOWN,
    Codex r5 P2-a)."""
    r = _evidence_row(rows, cited)
    if r is None:
        return None, 0
    norm = re.sub(r"\s+", " ", cited.strip())
    line = str(r.get("cmd", ""))
    whole = re.sub(r"\s+", " ", line.strip()) == norm
    parts = shell_segments_with_separators(line)
    if (
        r.get("rc_src") == "marker"
        and is_exit_echo_line(line)  # the same predicate the recorder used (ADR-011)
        and (whole or segment_runs(parts[0][0], norm))
    ):
        return r.get("rc"), r.get(
            "out_bytes", 0
        )  # `X; echo exit=$?`: the marker IS X's status (Codex r6 P2-a)
    return (r.get("rc") if _line_rc_applies(line) else None), r.get("out_bytes", 0)


def _iso(ts) -> str:
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(ts)))
    except (TypeError, ValueError):
        return "?"


def _output_problems(cited: str, claimed: str, row: dict) -> list[str]:
    """aidd-governance#186 P1-1: the trailer's output field must describe what the cited
    command printed (independent-review-probe: `git status` printed "ok", the report
    claimed "47/47 pass").  Rows written before `out_sample` existed are not judged."""
    recorded = row.get("out_sample")
    if recorded is None:
        return []
    head = re.sub(r"\s+", " ", str(recorded).strip())[:60]
    if output_field_matches(claimed, str(recorded)) is False:
        return [
            f"evidence output field does not describe the recorded output of `{cited[:60]}`: "
            f"cited `{claimed[:60]}` but the command printed `{head}` (DOT-INC-017)"
        ]
    missing = output_numbers_missing(claimed, str(recorded))  # #186 R1
    if missing:
        return [
            f"evidence output field cites numbers {missing} that `{cited[:60]}` never printed: "
            f"cited `{claimed[:60]}` but the command printed `{head}` (DOT-INC-017)"
        ]
    return []


def _edit_key_path(key: str) -> str:
    return key[5:].rsplit(":", 1)[0] if key.count(":") >= 2 else key[5:]


def _last_write_row(rows: list[dict]) -> tuple[dict, str, str] | None:
    """Newest successful write in the session: an Edit/Write/MultiEdit post row, or a Bash post
    row that wrote a path (cp/mv destination, tee/touch/sed -i/patch arguments, `>` targets —
    the same rule as _touched_paths).  Returns (row, path, how) with how = "edited" for the
    edit tools and "written" for a shell write (aidd-governance#186 R2: `pytest -q` → `sed -i`
    → citing the old pytest run was allowed because only Edit rows were considered)."""
    last: tuple[dict, str, str] | None = None
    for r in rows:
        if r.get("event") != "post":
            continue
        key = str(r.get("key", ""))
        if key.startswith("edit:"):
            if r.get("rc") not in (0, None):
                continue
            path, how = _edit_key_path(key), "edited"
        else:
            paths = _row_written_paths(r)
            if not paths:
                continue
            path, how = paths[-1], "written"
        if last is None or r.get("ts", 0) >= last[0].get("ts", 0):
            last = (r, path, how)
    return last


def _stale_problems(cited: str, row: dict, rows: list[dict]) -> list[str]:
    """aidd-governance#186 P1-2 / R2: evidence recorded before the newest successful write no
    longer describes the tree (`pytest -q` → Edit a.py → cite the old pytest; `pytest -q` →
    `sed -i … a.py` → same).  Any written file counts — the conservative side."""
    last = _last_write_row(rows)
    if last is None or row.get("ts", 0) >= last[0].get("ts", 0):
        return []
    edit, path, how = last
    by = (
        f" by `{re.sub(r'\\s+', ' ', str(edit.get('cmd', '')).strip())[:80]}`"
        if how == "written"
        else ""
    )
    verb = "edit" if how == "edited" else "write"
    return [
        f"evidence `{cited[:60]}` ran at {_iso(row.get('ts'))} but {path} was {how} later at "
        f"{_iso(edit.get('ts'))}{by}; re-run it after the {verb} (DOT-INC-017)"
    ]


WRITE_CMD_RE = re.compile(
    r"^(cp|mv|tee|install|rsync|ln|touch|dd|patch|git apply|git checkout|sed -i|curl .*-o|wget .*-O|python3? .*\.py|node .*\.m?js|bash .*\.sh)\b"
)


WRITE_LAST_RE = re.compile(r"^(cp|mv|rsync|install|ln)\b")
WRITE_ALL_RE = re.compile(r"^(tee|touch|patch|git apply|git checkout|sed -i)\b")


def _row_written_paths(r: dict) -> list[str]:
    """Absolute paths one successful post row WROTE, in command order: Edit/Write keys, the
    destination of cp/mv/rsync/install/ln (last argument only — the source is not written,
    Codex r3 P2-3), the arguments of tee/touch/patch/sed -i, and `>` redirection targets.
    Merely mentioning a path does not count.  Empty when the row's success is unknown
    (`cp … || true`, Codex r5 P2-b) or it is not a write."""
    if (
        r.get("event") != "post"
        or r.get("rc") not in (0, None)
        or (r.get("rc") is None and not str(r.get("key", "")).startswith("edit:"))
    ):
        return []  # only writes that actually succeeded (Codex r4 P2-e)
    cwd = str(r.get("cwd") or "")
    key = str(r.get("key", ""))
    cands: list[str] = []
    if key.startswith("edit:"):
        cands.append(_edit_key_path(key))
    parts = shell_segments_with_separators(str(r.get("cmd", "")))
    for i, (seg, _sep) in enumerate(parts):
        # A write whose own result is masked (`cp a b || true`) has unknown success (Codex r5 P2-b); a write
        # followed by `;` / `|` / `&&` with the line's rc 0 is counted (review 2026-10-16: `printf x | tee a.py`).
        if i + 1 < len(parts) and parts[i + 1][1] == "||":
            continue
        bare = _unquoted(
            seg
        )  # `git commit -m "a > b"` / `awk '$1 > 5'`: no redirection inside quotes
        args = [t for t in re.findall(r"[\w./~-]+", bare)[1:] if not t.startswith("-")]
        if WRITE_LAST_RE.match(bare) and args:
            cands.append(
                args[-1]
            )  # the destination, whatever it is called (Codex r7 P2-c)
        elif bare.startswith("git checkout"):
            if (
                " -- " in bare
            ):  # only the path form writes files; `git checkout -b feat/x` switches branches
                cands += [
                    t for t in bare.split(" -- ", 1)[1].split() if not t.startswith("-")
                ]
        elif WRITE_ALL_RE.match(bare):
            cands += [t for t in args if "/" in t or "." in t]
        cands += re.findall(r"(?<![<>&\d])\d?>>?\s*([\w./~-]+)", bare)
    out: list[str] = []
    for c in cands:
        if c.startswith("/dev/"):
            continue  # /dev/null is not an artifact (reviewer-g)
        p = Path(c).expanduser()
        if not p.is_absolute():
            p = Path(cwd) / p if cwd else p
        try:
            resolved = str(p.resolve())
        except OSError:
            resolved = str(p)
        if resolved not in out:
            out.append(resolved)
    return out


def _unquoted(seg: str) -> str:
    """The segment with the CONTENT of single/double-quoted strings blanked, so `>` inside an argument
    (`git commit -m "a > b"`, `jq '.a > 3'`) is not read as a redirection (review 2026-10-16 P2)."""
    out, quote = [], None
    for ch in seg:
        if quote:
            if ch == quote:
                quote = None
                out.append(ch)
            else:
                out.append(" ")
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        else:
            out.append(ch)
    return "".join(out)


def _touched_paths(rows: list[dict]) -> set[str]:
    """Absolute paths this session WROTE (union of _row_written_paths over the ledger)."""
    out: set[str] = set()
    for r in rows:
        out.update(_row_written_paths(r))
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
            if re.match(r"(git push|gh pr merge|git merge)\b", seg) and not re.search(
                r"(--dry-run|\s-n\b)", seg
            ):
                return True
    return False


def stop_check(
    meta: dict, rows: list[dict], text: str, cwd: str, require_status: bool = True
) -> dict:
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
    # ADR-009: declared status first, inferred claim only as the no-tool backstop.
    status = declared_status(text)
    trailers = evidence_trailers(text)
    used_tools = any(r.get("event") in ("pre", "post") for r in rows)
    if status in ("partial", "unverified"):
        # A partial answer still may not claim a push/merge or a save it did not do (DOT-INC-026/017,
        # review 2026-10-17 P2): those two bindings run even here; the evidence trailer is not required.
        if (
            has_push_claim(text)
            and not _push_executed(rows)
            and not mutated("evidence.readback")
        ):
            problems.append(
                "push/merge claimed but no successful push/merge command in the session ledger (DOT-INC-026)"
            )
        if has_persist_claim(text) and not mutated("evidence.readback"):
            problems.extend(_readback_problems(text, cwd, _touched_paths(rows)))
        v = _verdict(problems)
        v["status"] = status
        if v["decision"] == "allow":
            v["note"] = f"[H17] Status: {status} — not verified by the evidence gate"
        return v
    if status is None and trailers:
        status = "complete"  # a full Evidence trailer is a completion declaration (T1-T79 compat)
    undeclared = False
    if (
        status is None
        and used_tools
        and require_status
        and text.strip()  # Cursor fires `stop` with an empty text before afterAgentResponse (Codex r2 P1)
        and not mutated("evidence.trailer")
    ):
        undeclared = True
        problems.append(
            "no status declared after tool use: end the answer with one line "
            "`Status: complete | partial | unverified` (ADR-009; complete is bound to Evidence)"
        )
        # fall through: the trailer diagnostics below (incomplete trailer, …) still help the agent
    elif status is None and used_tools and not require_status:
        # an intermediate text part after tool use (OpenCode text.complete): the final answer is judged with the
        # Status requirement at session.idle / process exit; here only a false push / save claim is bound — the
        # vocabulary backstop is for sessions WITHOUT tool rows (ADR-009; independent review r2 P2)
        if (
            has_push_claim(text)
            and not _push_executed(rows)
            and not mutated("evidence.readback")
        ):
            problems.append(
                "push/merge claimed but no successful push/merge command in the session ledger (DOT-INC-026)"
            )
        if has_persist_claim(text) and not mutated("evidence.readback"):
            problems.extend(_readback_problems(text, cwd, _touched_paths(rows)))
        return _verdict(problems)
    elif status is None and not (has_completion_claim(text) or has_persist_claim(text)):
        return _verdict(problems)  # no tools, no declaration, no claim: nothing to bind
    cmds = [c for c, _out, _when in trailers]
    for bad in incomplete_evidence_lines(text):
        if not mutated("evidence.trailer"):
            problems.append(
                f"incomplete Evidence trailer (need <cmd> | <output> | <time>): {bad}"
            )
    if not cmds and not mutated("evidence.trailer"):
        # T2's mutation anchor is this line; the message is skipped when the only defect is the missing Status
        # (review 2026-10-17 P3: no claim was made, so "completion claim without Evidence" would mislead)
        if not undeclared:
            problems.append(
                "completion claim without `Evidence: <cmd> | <output> | <time>` trailer (DOT-INC-010)"
            )
    executed = _executed_commands(rows)
    substantive = False
    for c, claimed_out, _when in trailers:
        if not cmd_in_ledger(c, executed) and not mutated("evidence.executed"):
            # #214 P3-2: a cited chain is never one recorded command when it ran with `; echo exit=$?` after it — say how
            # to cite it, not only that it was not found
            chain = (
                " — a chain is never one recorded command: cite ONE command (pass a directory as an argument: `pytest -q sub/`, `git -C sub …`)"
                if len(shell_segments(c)) > 1
                else ""
            )
            problems.append(
                f"cited evidence command was not executed in this session: {c[:80]}{chain} (DOT-INC-017)"
            )
            continue
        row = _evidence_row(rows, c)
        if row is not None and not mutated("evidence.trailer"):
            problems.extend(_output_problems(c, claimed_out, row))  # #186 P1-1
        if row is not None and not mutated("evidence.executed"):
            problems.extend(_stale_problems(c, row, rows))  # #186 P1-2
        rc, out_bytes = _rc_for(rows, c)
        if rc is None and mutated("evidence.executed"):
            rc = 0  # the old behaviour: a typed command is trusted as if it ran and passed
        if rc in (None, 124, 126, 127) and not mutated("evidence.rc-unknown"):
            line = str((row or {}).get("cmd", ""))
            masked = rc is None and row is not None and row.get("rc") is not None
            # a code read from the output (rc_src=marker, an entry without codes) is not the harness's: that entry
            # is told how its in-band form is accepted, not to run alone (Codex review r6 P2)
            by_marker = masked and row.get("rc_src") == "marker"
            how = (
                " — 124 is a timeout: the command did not finish; rerun it so it completes (a longer timeout or a smaller scope) and cite that run"
                if rc == 124
                else ""
                if rc is not None
                # ADR-011: say which cause it is — 2026-10-20 A-2 got "reported no exit status" for a line dsh had
                # reported 0 for, which sent the agent after the wrong fix. An entry that reports exit codes is told
                # to run the command alone: its in-band `exit=N` is not read (owner PIVOT 2026-10-20)
                else f" — the status line `exit={row.get('rc')}` in the output belongs to the whole line `{line[:60]}`, where `;` / `|` / `||` / `&` can mask a failure; run the cited command alone as `<cmd>; echo exit=$?` so the status is its own"
                if by_marker
                else f" — this harness reports exit codes, and the recorded status {row.get('rc')} belongs to the whole line `{line[:60]}`, where `;` / `|` / `||` / `&` can mask a failure (an in-band `exit=N` is not read here); run the command on its own, not chained, and cite it"
                if masked
                # ADR011-P1-1 / P3-1: an entry with codes that sent none for this call — `; echo exit=$?` cannot help
                # there (its output is not read, and the echo's own code would be recorded), so name the causes
                # (#212 P3: when no single run can finish in the foreground, a shorter command that proves the claim
                # — one test file, one package — is the way out)
                else " — the harness reported none for this call: the command timed out, was killed by a signal, was interrupted, or is still running in the background (an in-band `exit=N` is not read here); run it on its own so it finishes in the foreground (if it cannot, cite a shorter command that proves the claim, e.g. one test file), and cite that run"
                if row is not None and row.get("rc_src") == "harness-missing"
                # #212 P2: a chain cannot carry its own status on an entry without codes (`cd sub && pytest -q; echo
                # exit=$?` is not the echo shape, and the chain is never one recorded command) — ask for ONE command
                else " — this harness reported no exit status; cite ONE command, not a chain (pass a directory as an argument: `pytest -q sub/`, `git -C sub …`), and run it as `<cmd>; echo exit=$?` so the status is in the output"
                if len(shell_segments(c)) > 1
                else " — this harness reported no exit status; run it as `<cmd>; echo exit=$?` so the status is in the output"
            )
            problems.append(
                f"evidence command exit status {rc if rc is not None else 'unavailable'} is UNKNOWN, not a result: {c[:80]}{how} (DOT-INC-043)"
            )
        elif rc != 0 and not mutated("evidence.rc-unknown"):
            problems.append(
                f"evidence command failed (rc={rc}) yet completion is claimed: {c[:80]} (DOT-INC-043)"
            )
        if not is_trivial_cmd(c):
            substantive = True
    if cmds and not substantive and not mutated("evidence.trailer"):
        problems.append(
            "every cited evidence command is trivial (ls/echo/cat/tail…); cite the command that produced the result"
        )
    if has_persist_claim(text) and not mutated("evidence.readback"):
        problems.extend(_readback_problems(text, cwd, _touched_paths(rows)))
    if has_push_claim(text) and not mutated("evidence.readback"):
        if not _push_executed(rows):
            problems.append(
                "push/merge claimed but no successful push/merge command in the session ledger (DOT-INC-026)"
            )
    problems.extend(denominator_mismatch(text, meta.get("denominator")))
    problems.extend(source_set_problems(rows))
    return _verdict(problems)


def control_sha() -> str:
    """sha256 over the control source set (DOT-INC-023: fixed for the whole run)."""
    here = Path(__file__).resolve().parent
    h = hashlib.sha256()
    for name in (
        "aidd_cc.py",
        "aidd_cc_controls.py",
        "aidd_cc_text.py",
        "aidd_cc_eval.py",
        "aidd_cc_session.py",
    ):
        try:
            h.update((here / name).read_bytes())
        except OSError:
            h.update(b"missing:" + name.encode())
    return h.hexdigest()


CONTROL_SET_EXTRA = ("aidd-cc-adapter.sh",)


def control_set_sha() -> str:
    """aidd-governance#186 P2-4: control_sha() is pinned to the five python files (its set and order are
    an identifier other tooling depends on), so the shared adapter — the file that turns a verdict into
    the Claude Code / Codex wire format — is covered by this second digest: control_sha() input plus
    CONTROL_SET_EXTRA, all read from the same directory.  Recorded as `cc_set_sha` on tool rows and
    checked by source_set_problems like cc_sha."""
    here = Path(__file__).resolve().parent
    h = hashlib.sha256(control_sha().encode())
    for name in CONTROL_SET_EXTRA:
        try:
            h.update((here / name).read_bytes())
        except OSError:
            h.update(b"missing:" + name.encode())
    return h.hexdigest()


def source_set_problems(rows: list[dict]) -> list[str]:
    """DOT-INC-023: every tool row of the run must carry the same control sha as now (python set), and
    the same control-set sha (python set + adapter, #186 P2-4) where the row recorded one."""
    if mutated("source-set.pin"):
        return []
    out = []
    now = control_sha()
    seen = {r.get("cc_sha") for r in rows if r.get("cc_sha")}
    if seen and seen != {now}:
        out.append(
            f"control source set changed during the run ({len(seen)} shas seen); acceptance refused (DOT-INC-023)"
        )
    now_set = control_set_sha()
    seen_set = {r.get("cc_set_sha") for r in rows if r.get("cc_set_sha")}
    if seen_set and seen_set != {now_set} and not out:
        out.append(
            f"control set (python + adapter) changed during the run ({len(seen_set)} set shas seen); acceptance refused (DOT-INC-023)"
        )
    return out


def _readback_problems(text: str, cwd: str, touched: set[str]) -> list[str]:
    claims = readback_claims(text)
    if not claims:
        return [
            "save/deploy claimed without `Readback: <path> sha256=<hex>` (DOT-INC-017/026)"
        ]
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
            out.append(
                f"readback mismatch for {path}: claimed {sha[:12]} actual {str(actual)[:12]}"
            )
        elif resolved not in touched:
            out.append(
                f"readback path {path} was never written or touched by a command in this session (not the saved artifact)"
            )
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
