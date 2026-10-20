#!/usr/bin/env python3
"""aidd-cc — AIDD common control (H17) CLI used by every harness adapter.

    aidd_cc.py <cmd> --agent <claude-code|codex|cursor|opencode> [--session S] [--cwd C]
    stdin: the harness hook payload as JSON (or {} for CLI-only commands)

Commands (all print one JSON object; exit 0 unless noted):
  pre         PreToolUse: C-ITER + C-DECISION(question) -> decision allow/block
  post        PostToolUse: record rc/output for evidence binding
  prompt      UserPromptSubmit: register user decisions / deadlines
  (permission: retired 2026-10-14 — H17 never auto-allows)
  stop        Stop: C-EVIDENCE; --exit-style claude exits 2 on block
  note        --hypothesis --change : progress delta for C-ITER
  deadline    set <iso|+Nh> [--supersede reason] | show
  denominator set N | show
  readback    <path> : print sha256 line for the report trailer
  eval        speed|history|cost|chain|attempt|collect|judge|promote (JSON on stdin)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aidd_cc_eval as ev  # noqa: E402
from aidd_cc_controls import (  # noqa: E402
    _norm_key,
    control_set_sha,
    control_sha,
    iteration_check,
    question_check,
    register_note,
    stop_check,
)
from aidd_cc_session import guard_ledger, load_meta, load_tools, record_tool, save_meta  # noqa: E402
from aidd_cc_text import (
    NEGATION_RE,
    is_approval_text,
    is_exit_echo_line,
    is_short_affirmative,
    parse_deadline_hours,
    parse_denominator,
    trailing_exit_marker,
)  # noqa: E402

COMPONENT = "H17"


def _read_payload() -> dict:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except ValueError:
        # Observation failure is not a pass (harness-spec 0-4): record it.
        guard_ledger(
            COMPONENT,
            "error",
            "unreadable",
            "payload",
            raw[:100],
            os.environ.get("AIDD_CC_AGENT", "?"),
            "unset",
        )
        return {"_raw": raw, "_unreadable": True}


def _session(args, payload) -> str:
    return (
        args.session
        or payload.get("session_id")
        or payload.get("conversation_id")
        or payload.get("sessionID")
        or os.environ.get("AIDD_CC_SESSION")
        or "unset"
    )


def _cwd(args, payload) -> str:
    ti = (
        payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    )
    # A tool's own workdir wins over the session cwd (Codex r7 P2-b).
    return str(
        (ti or {}).get("workdir")
        or (ti or {}).get("cwd")
        or args.cwd
        or payload.get("cwd")
        or os.getcwd()
    )


def _emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False))


def _tool_input(payload: dict) -> dict:
    """Normalise harness-specific shapes to {command, file_path, ...}.
    Codex `exec_command` passes `cmd` (P1-3); OpenCode passes `filePath`."""
    ti = payload.get("tool_input") or payload.get("args") or payload.get("input") or {}
    if not ti and payload.get(
        "file_path"
    ):  # Cursor afterFileEdit: top-level file_path + edits
        ti = {"file_path": payload["file_path"], "edits": payload.get("edits")}
    if not isinstance(ti, dict):
        return {}
    ti = dict(ti)
    for alt in ("cmd", "shell_command", "script"):
        if "command" not in ti and ti.get(alt):
            ti["command"] = ti[alt]
    if isinstance(ti.get("command"), list):
        ti["command"] = " ".join(str(x) for x in ti["command"])
    if "command" not in ti and payload.get("command"):
        ti["command"] = payload["command"]
    for alt in ("filePath", "path", "file"):
        if "file_path" not in ti and ti.get(alt):
            ti["file_path"] = ti[alt]
    if "content" not in ti and ti.get("patch"):  # Codex apply_patch
        ti["content"] = str(ti["patch"])
        mfile = re.search(r"\*\*\* (?:Update|Add|Delete) File: (\S+)", str(ti["patch"]))
        if mfile and "file_path" not in ti:
            ti["file_path"] = mfile.group(1)
    if "old_string" not in ti and ti.get("oldString"):
        ti["old_string"], ti["new_string"] = ti.get("oldString"), ti.get("newString")
    return ti


def _tool_name(payload: dict, default: str) -> str:
    name = str(payload.get("tool_name") or payload.get("tool") or default)
    return {
        "edit": "Edit",
        "write": "Write",
        "bash": "Bash",
        "shell": "Bash",
        "exec_command": "Bash",
        "multiedit": "MultiEdit",
        "apply_patch": "Edit",
        "request_user_input": "AskUserQuestion",
        "ask_user": "AskUserQuestion",
        "askuserquestion": "AskUserQuestion",
    }.get(name.lower(), name)


def _question_texts(ti: dict) -> list[str]:
    qs = ti.get("questions")
    if isinstance(qs, list):
        out = [
            str(q.get("question") or q.get("prompt") or "")
            if isinstance(q, dict)
            else str(q)
            for q in qs
        ]
        return [q for q in out if q] or [""]
    return [_question_text(ti)]


def _question_text(ti: dict) -> str:
    """Only the question sentences — never headers / option labels / descriptions
    (Codex r3 P2-2: those words dilute the overlap denominator)."""
    qs = ti.get("questions")
    if isinstance(qs, list):
        parts = [
            str(q.get("question") or q.get("prompt") or "")
            if isinstance(q, dict)
            else str(q)
            for q in qs
        ]
        return "\n".join(p for p in parts if p)
    return str(
        ti.get("question")
        or ti.get("prompt")
        or ti.get("message")
        or json.dumps(ti, ensure_ascii=False)
    )


def cmd_pre(args, payload):
    agent, session = args.agent, _session(args, payload)
    tool = _tool_name(payload, args.tool or "Bash")
    ti = _tool_input(payload)
    meta, rows = load_meta(agent, session), load_tools(agent, session)
    if tool in ("AskUserQuestion", "ask_user", "question"):
        qs = _question_texts(ti)
        verdicts = [question_check(meta, q) for q in qs]
        blocked = [v for v in verdicts if v["decision"] == "block"]
        # Block only when EVERY question is already answered; one undecided
        # question keeps the whole call (Codex r5 P2-d).
        verdict = (
            blocked[0]
            if blocked and len(blocked) == len(verdicts)
            else {"decision": "allow", "rule": "decision"}
        )
        if any(v.get("remember") for v in verdicts):
            save_meta(agent, session, meta)
    else:
        verdict = iteration_check(rows, meta, tool, ti, _cwd(args, payload))
    key = _norm_key(tool, ti)
    record_tool(
        agent,
        session,
        {
            "event": "pre",
            "cwd": _cwd(args, payload),
            "tool": tool,
            "key": key,
            "cc_sha": control_sha(),
            "cc_set_sha": control_set_sha(),
            "cmd": str(ti.get("command") or "")[:4000],
            "decision": verdict["decision"],
        },
    )
    if verdict["decision"] == "block":
        guard_ledger(COMPONENT, "block", "deny", verdict["rule"], key, agent, session)
    _emit(verdict)


def _exit_status(payload: dict, resp, agent: str, cmd: str = ""):
    """Exit status for the ledger.  Dict responses carry it; string responses are
    parsed for `exit code N`; otherwise it is UNKNOWN (None) — never assumed 0
    (Codex r2 P1-d).  Claude Code is the one harness whose PostToolUse fires
    only on success (failures go to PostToolUseFailure), so its success event is
    rc 0 by construction.  `X; echo exit=$?` is read from its own status line
    even when the harness reported a code (ADR-011)."""
    rc = None
    if isinstance(resp, dict):
        rc = resp.get("exit_code", resp.get("exitCode", resp.get("rc")))
        out = (
            str(resp.get("stdout", ""))
            + str(resp.get("stderr", ""))
            + str(resp.get("output", ""))
        )
    else:
        out = str(resp)
    if rc is None and payload.get("exit_code") is not None:
        rc = payload.get("exit_code")
    failed = (
        payload.get("hook_event_name") == "PostToolUseFailure"
        or payload.get("is_error")
        or payload.get("error")
    )
    if failed:
        err = str(payload.get("error") or out)
        return (
            (
                127
                if "command not found" in err
                else 124
                if "timed out" in err.lower()
                else (rc if rc not in (None, 0) else 1)
            ),
            out,
            "harness",
        )
    # The echo writes to stdout: when the streams come separately, a failing X's stderr `exit=0` must not be read
    # after the echo's stdout `exit=1` (ADR-011, Codex review P2); a merged stream is in write order.
    status_text = (
        str(resp["stdout"])
        if isinstance(resp, dict) and str(resp.get("stdout") or "").strip()
        else out
    )
    if is_exit_echo_line(cmd) and rc in (None, 0):
        # ADR-011: a harness code 0 for `X; echo exit=$?` is echo's and says nothing about X; the echo's line is X's
        # status. Owner live run 2026-10-20 A-1: dsh reported 0 for the line, the judge refused it as masked, and the
        # honest trailer the gate itself had asked for was blocked as UNKNOWN twice. A NON-zero line code means the
        # echo never ran normally (`exec`, a kill) and is kept: no printed `exit=0` overrides it (Codex review P1).
        marker = trailing_exit_marker(status_text)
        if marker is not None:
            return marker, out, "marker"
    if rc is None:
        # status lines only, at the end (reviewer-e N4); the last one wins (ADR-011: X may print its own first)
        marker = trailing_exit_marker(
            status_text, r"(?:exit(?: code| status)?|rc)[:= ]+(-?\d{1,3})"
        )
        if marker is not None:
            return marker, out, "marker"  # the command's own trailing status line
        if agent == "claude-code" and isinstance(resp, dict):
            rc = 0
    return rc, out, "harness"


def _register_answers(agent: str, session: str, ti: dict, resp) -> int:
    """AskUserQuestion answers come back as tool_response.answers (not a new prompt).
    An affirmative answer binds to its question like a short `OK` (Codex r8 P2-c)."""
    answers = resp.get("answers") if isinstance(resp, dict) else None
    if not isinstance(answers, dict) or not answers:
        return 0
    import hashlib

    meta = load_meta(agent, session)
    n = 0
    for q, a in answers.items():
        a = str(a)
        if not is_short_affirmative(a):
            continue
        asked = re.sub(
            r"[?？]|よいですか|いいですか|よろしいですか|してもいい|ますか|ですか|should i|can i|may i|shall i",
            "",
            str(q),
            flags=re.IGNORECASE,
        )
        dtext = asked.strip() + " " + a
        if is_approval_text(dtext):
            sha = hashlib.sha256(dtext.encode()).hexdigest()[:16]
            meta["decisions"].append(
                {
                    "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "sha": sha,
                    "text": dtext[:600],
                }
            )
            n += 1
    meta["questions"] = []
    save_meta(agent, session, meta)
    return n


def cmd_post(args, payload):
    agent, session = args.agent, _session(args, payload)
    tool = _tool_name(payload, args.tool or "Bash")
    ti = _tool_input(payload)
    if tool == "AskUserQuestion":
        n = _register_answers(agent, session, ti, payload.get("tool_response") or {})
        _emit({"decision": "allow", "rule": "record-answers", "registered": n})
        return
    resp = payload.get("tool_response") or payload.get("output") or {}
    rc, out, rc_src = _exit_status(payload, resp, agent, str(ti.get("command") or ""))
    key = _norm_key(tool, ti)
    record_tool(
        agent,
        session,
        {
            "event": "post",
            "cwd": _cwd(args, payload),
            "rc_src": rc_src,
            "tool": tool,
            "key": key,
            "rc": rc,
            "cmd": str(ti.get("command") or "")[:4000],
            "out_bytes": len(out),
            "out_sample": _out_sample(out),
        },
    )
    _emit({"decision": "allow", "rule": "record", "rc": rc})


OUT_SAMPLE_CHARS = 4000


def _out_sample(out: str) -> str:
    """Head + tail of the tool output kept on the post row so the Evidence output field can
    be checked against what the command printed (aidd-governance#186 P1-1).  The tail is
    kept because test summaries are last lines.  Exposure: the same text already sits in
    the harness transcript on this disk; the state dir is per-user.  Do not point
    AIDD_CC_STATE_DIR at a shared location."""
    if len(out) <= OUT_SAMPLE_CHARS:
        return out
    half = OUT_SAMPLE_CHARS // 2
    return out[:half] + "\n…\n" + out[-half:]


def cmd_prompt(args, payload):
    agent, session = args.agent, _session(args, payload)
    text = str(
        payload.get("prompt") or payload.get("text") or payload.get("message") or ""
    )
    meta = load_meta(agent, session)
    if text.lstrip().startswith("[H17 evidence gate]"):
        _emit({"decision": "allow", "rule": "prompt.gate-reprompt", "registered": []})
        return  # the gate's own re-prompt is not a user turn: budgets stay (Codex r4 P1-c)
    meta["stop_blocks"] = (
        0  # the loop guard is per stop attempt, not per session (P2-4)
    )
    registered = []
    if NEGATION_RE.search(text):
        # A refusal / withdrawal is the latest instruction: every earlier decision in
        # this session (and anything inherited) stops binding (Codex r2 P1-c).
        if meta.get("decisions"):
            registered.append(f"revoked={len(meta['decisions'])}")
        meta["decisions"] = []
        meta["revoked_at"] = time.time()
    decision_text = text
    if not is_short_affirmative(text):
        meta[
            "questions"
        ] = []  # a new instruction supersedes the pending question (reviewer-g D4)
    if is_short_affirmative(text) and meta.get("questions"):
        # `OK` alone answers the last question the agent asked (reviewer-e #8)
        asked = re.sub(
            r"[?？]|よいですか|いいですか|よろしいですか|してもいい|ますか|ですか|should i|can i|may i|shall i",
            "",
            meta["questions"][-1]["text"],
            flags=re.IGNORECASE,
        )
        decision_text = asked.strip() + " " + text
        registered.append("bound-to-question")
    if is_approval_text(decision_text) and len(decision_text.strip()) >= 2:
        import hashlib

        sha = hashlib.sha256(decision_text.encode()).hexdigest()[:16]
        meta["decisions"].append(
            {
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "sha": sha,
                "text": decision_text[:600],
            }
        )
        registered.append("decision")
    den = parse_denominator(text)
    if den:
        meta["denominator"] = den
        registered.append(f"denominator={den}")
    hours = parse_deadline_hours(text)
    if hours is not None:
        res = ev.deadline_set(meta, time.time() + hours * 3600, None)
        if res["ok"]:
            meta["deadline"] = res["deadline"]
            registered.append(f"deadline+{hours}h")
        else:
            registered.append("deadline-kept-original")
    save_meta(agent, session, meta)
    _emit({"decision": "allow", "rule": "prompt", "registered": registered})


def _last_assistant(payload: dict, meta: dict) -> str:
    text = (
        payload.get("last_assistant_message")
        or payload.get("text")
        or payload.get("message")
    )
    if text:
        return str(text)
    tp = payload.get("transcript_path")
    if tp and Path(tp).exists():
        return _tail_assistant(Path(tp))
    return str(meta.get("last_assistant") or "")


def _tail_assistant(tp: Path) -> str:
    """Claude Code transcript (JSONL): last assistant text parts."""
    last = ""
    for line in tp.read_text(encoding="utf-8", errors="replace").splitlines()[-400:]:
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        msg = obj.get("message") if isinstance(obj, dict) else None
        if obj.get("type") == "assistant" and isinstance(msg, dict):
            parts = msg.get("content") or []
            txt = "".join(
                p.get("text", "")
                for p in parts
                if isinstance(p, dict) and p.get("type") == "text"
            )
            if txt.strip():
                last = txt
    return last


RELEASE_NOTE = "[H17] evidence unverified ({why})"


def _release(args, payload, meta, rows, rule: str, detail: str, why: str) -> int:
    """A loop-guard / max-blocks release never passes silently.  The allow row stays
    (T11), and the text is STILL evaluated: when it would have been blocked, a
    `<rule>.would-block` row is written and the verdict carries `would_block` plus the
    visible note for the harness to show (aidd-governance#186 P1-4 — Pi live 2026-10-14
    08:35Z: a fabricated third turn passed through the max-blocks release unmarked; the
    Claude Code stop_hook_active re-entry is the same path, P2-1).  The release itself
    is kept: removing it would be an infinite block."""
    agent, session = args.agent, _session(args, payload)
    guard_ledger(COMPONENT, "measure", "allow", rule, detail, agent, session)
    out: dict = {"decision": "allow", "rule": rule}
    if rule == "evidence.max-blocks":
        out["blocks"] = meta.get("stop_blocks", 0)
    text = _last_assistant(payload, meta)
    verdict = (
        stop_check(meta, rows, text, _cwd(args, payload), not args.no_status_required)
        if text.strip()
        else {"decision": "allow"}
    )
    if verdict["decision"] == "block":
        guard_ledger(
            COMPONENT,
            "measure",
            "would-block",
            rule + ".would-block",
            verdict["problems"][0],
            agent,
            session,
        )
        out.update(
            would_block=True,
            problems=verdict["problems"],
            reason=verdict["reason"],
            note=RELEASE_NOTE.format(why=why),
        )
    elif verdict.get("status") in ("partial", "unverified"):
        # ADR-009 on the release path too (Codex review 2026-10-17 P2): the corrected `Status: partial` answer
        # after a block arrives through stop_hook_active / max-blocks and must stay visible — note + its own row.
        guard_ledger(
            COMPONENT,
            "measure",
            "allow",
            "evidence.status-partial",
            verdict["status"],
            agent,
            session,
        )
        out.update(status=verdict["status"], note=verdict.get("note", ""))
    _emit(out)
    return 0


def cmd_stop(args, payload):
    agent, session = args.agent, _session(args, payload)
    meta, rows = load_meta(agent, session), load_tools(agent, session)
    if payload.get("stop_hook_active") and not args.ignore_active:
        # Claude Code re-enters Stop with this flag after a block; passing is required to
        # avoid an infinite loop, and the pass is visible in the ledger (not a silent off).
        return _release(
            args,
            payload,
            meta,
            rows,
            "evidence.loop-guard",
            "stop_hook_active",
            "stop_hook_active re-entry",
        )
    if meta.get("stop_blocks", 0) >= args.max_blocks:
        return _release(
            args,
            payload,
            meta,
            rows,
            "evidence.max-blocks",
            f"blocks={meta['stop_blocks']}",
            "max-blocks released",
        )
    text = _last_assistant(payload, meta)
    if not text.strip() and meta.get("pending_block_reason"):
        reason = meta.pop("pending_block_reason")
        meta["stop_blocks"] = meta.get("stop_blocks", 0) + 1
        save_meta(agent, session, meta)
        guard_ledger(
            COMPONENT, "block", "deny", "evidence.pending", reason[:100], agent, session
        )
        _emit(
            {
                "decision": "block",
                "rule": "evidence.pending",
                "problems": [reason],
                "reason": reason,
            }
        )
        return 2 if args.exit_style == "claude" else 0
    verdict = stop_check(
        meta, rows, text, _cwd(args, payload), not args.no_status_required
    )
    if verdict.get("status") in ("partial", "unverified"):
        # ADR-009: a declared partial / unverified answer passes, visibly (note + its own row).
        guard_ledger(
            COMPONENT,
            "measure",
            "allow",
            "evidence.status-partial",
            verdict["status"],
            agent,
            session,
        )
    # Every evaluation leaves a measure row: live runs prove the gate ran at the
    # registered entry even when nothing was blocked (DOT-INC-012/022).
    guard_ledger(
        COMPONENT,
        "measure",
        verdict["decision"],
        "evidence.evaluated",
        text[:60],
        agent,
        session,
    )
    if verdict["decision"] == "block":
        if not args.no_count:
            meta["stop_blocks"] = meta.get("stop_blocks", 0) + 1
            save_meta(agent, session, meta)
        guard_ledger(
            COMPONENT,
            "block",
            "deny",
            verdict["rule"],
            verdict["problems"][0],
            agent,
            session,
        )
    _emit(verdict)
    if verdict["decision"] == "block" and args.exit_style == "claude":
        sys.stderr.write(verdict["reason"] + "\n")
        return 2
    return 0


def cmd_note(args, payload):
    agent, session = args.agent, _session(args, payload)
    meta = load_meta(agent, session)
    res = register_note(meta, args.hypothesis or "", args.change or "")
    if res["decision"] == "allow":
        save_meta(agent, session, meta)
    _emit(res)


def cmd_record_assistant(args, payload):
    """Cursor afterAgentResponse / OpenCode: keep the last assistant text for stop.

    Cursor IDE fires `stop` BEFORE `afterAgentResponse` (observed 2026-10-14
    04:56:20Z: stop evaluated an empty text, the text arrived 1 event later), so
    the evidence check also runs here and a block is parked as
    `pending_block_reason`; the next `stop` returns it as the followup."""
    agent, session = args.agent, _session(args, payload)
    meta, rows = load_meta(agent, session), load_tools(agent, session)
    text = str(
        payload.get("text") or payload.get("message") or payload.get("response") or ""
    )
    # judge the whole answer (its Status line is at the END); store a bounded copy for the next stop
    # (Codex r4 P2: a 24k-char partial report lost its `Status: partial` to the [:20000] cut and was blocked)
    meta["last_assistant"] = text[-20000:]
    verdict = (
        stop_check(meta, rows, text, _cwd(args, payload), not args.no_status_required)
        if text.strip()
        else {"decision": "allow"}
    )
    guard_ledger(
        COMPONENT,
        "measure",
        verdict["decision"],
        "evidence.evaluated",
        text[:60],
        agent,
        session,
    )
    if verdict.get("status") in ("partial", "unverified"):
        # ADR-009 visibility on the Cursor path: the ledger row (Cursor's stop output has no message-only form)
        guard_ledger(
            COMPONENT,
            "measure",
            "allow",
            "evidence.status-partial",
            verdict["status"],
            agent,
            session,
        )
    if verdict["decision"] == "block":
        meta["pending_block_reason"] = verdict["reason"]
        guard_ledger(
            COMPONENT,
            "block",
            "deny",
            verdict["rule"],
            verdict["problems"][0],
            agent,
            session,
        )
    save_meta(agent, session, meta)
    _emit(
        {
            "decision": verdict["decision"],
            "rule": "record-assistant",
            "reason": verdict.get("reason", ""),
        }
    )


def _parse_when(s: str) -> float:
    if s.startswith("+") and s.endswith("h"):
        return time.time() + float(s[1:-1]) * 3600
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def cmd_deadline(args, payload):
    agent, session = args.agent, _session(args, payload)
    meta = load_meta(agent, session)
    if args.action == "show":
        _emit(
            {
                "deadline": meta.get("deadline"),
                "history": meta.get("deadline_history", []),
                **ev.deadline_status(meta.get("deadline")),
            }
        )
        return
    res = ev.deadline_set(meta, _parse_when(args.value), args.supersede)
    if res["ok"]:
        meta["deadline"] = res["deadline"]
        meta["deadline_history"] = res.get(
            "superseded_by", res.get("deadline_history", [])
        )
        save_meta(agent, session, meta)
    _emit(res)


def cmd_denominator(args, payload):
    agent, session = args.agent, _session(args, payload)
    meta = load_meta(agent, session)
    if args.action == "set":
        meta["denominator"] = int(args.value)
        save_meta(agent, session, meta)
    _emit({"denominator": meta.get("denominator")})


def cmd_readback(args, payload):
    sha = ev.file_sha(Path(args.path).expanduser())
    print(
        f"Readback: {args.path} sha256={sha}"
        if sha
        else f"Readback: {args.path} UNKNOWN"
    )


def cmd_eval(args, payload):
    kind = args.kind
    if kind == "speed":
        _emit(
            ev.speed_compare(
                payload["on"], payload["off"], payload.get("required", 2.0)
            )
        )
    elif kind == "history":
        _emit(
            ev.historic_speedup(payload.get("historic_elapsed"), payload["new_elapsed"])
        )
    elif kind == "cost":
        _emit(ev.cost_reconcile(payload["entries"], payload.get("contract_cap")))
    elif kind == "chain":
        _emit(ev.chain_check(payload["records"]))
    elif kind == "attempt":
        _emit(
            ev.attempt_new(
                payload.get("parent"),
                payload.get("ancestors", []),
                payload["attempt_id"],
            )
        )
    elif kind == "collect":
        _emit(ev.collect(payload["cmd"], payload.get("timeout", 60)))
    elif kind == "judge":
        _emit(ev.judge_host(payload["ping"], payload["ssh"]))
    elif kind == "promote":
        _emit(
            ev.promote(
                payload.get("record", {}),
                payload["to"],
                Path(payload["original"]),
                payload["candidate_sha"],
            )
        )
    else:
        _emit({"error": f"unknown eval kind {kind}"})


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="aidd-cc")
    ap.add_argument(
        "cmd",
        choices=[
            "pre",
            "post",
            "prompt",
            "stop",
            "note",
            "record-assistant",
            "deadline",
            "denominator",
            "readback",
            "eval",
        ],
    )
    ap.add_argument("--agent", default=os.environ.get("AIDD_CC_AGENT", "claude-code"))
    ap.add_argument("--session")
    ap.add_argument("--cwd")
    ap.add_argument("--tool")
    ap.add_argument("--exit-style", default="json", choices=["json", "claude"])
    ap.add_argument(
        "--max-blocks",
        type=int,
        default=int(os.environ.get("AIDD_CC_MAX_STOP_BLOCKS", "2")),
    )
    ap.add_argument("--ignore-active", action="store_true")
    ap.add_argument(
        "--no-status-required",
        action="store_true",
        help="ADR-009: do not demand a Status line (intermediate text parts, not the final answer)",
    )
    ap.add_argument(
        "--no-count",
        action="store_true",
        help="evaluate without consuming a stop-block slot",
    )
    ap.add_argument("--hypothesis")
    ap.add_argument("--change")
    ap.add_argument("--supersede")
    ap.add_argument("action", nargs="?")
    ap.add_argument("value", nargs="?")
    ap.add_argument("--path")
    ap.add_argument("--kind")
    args = ap.parse_args(argv)
    if args.cmd == "readback" and not args.path:
        args.path = args.action
    if args.cmd == "eval" and not args.kind:
        args.kind = args.action
    if args.cmd in ("note", "denominator", "deadline") and not (
        args.session or os.environ.get("AIDD_CC_SESSION")
    ):
        _emit(
            {
                "decision": "error",
                "rule": "session-required",
                "reason": f"{args.cmd} needs --session <id> (the hook payload session_id); refusing to write to 'unset'",
            }
        )
        return 1
    payload = (
        _read_payload()
        if args.cmd not in ("readback", "deadline", "denominator", "note")
        else {}
    )
    handler = {
        "pre": cmd_pre,
        "post": cmd_post,
        "prompt": cmd_prompt,
        "stop": cmd_stop,
        "note": cmd_note,
        "record-assistant": cmd_record_assistant,
        "deadline": cmd_deadline,
        "denominator": cmd_denominator,
        "readback": cmd_readback,
        "eval": cmd_eval,
    }[args.cmd]
    rc = handler(args, payload)
    return int(rc or 0)


def _main_guarded() -> int:
    """A crash must not become a silent pass (harness-spec 0-4): record it."""
    try:
        return main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        guard_ledger(
            COMPONENT,
            "error",
            "crash",
            type(exc).__name__,
            str(exc)[:100],
            os.environ.get("AIDD_CC_AGENT", "?"),
            os.environ.get("AIDD_CC_SESSION", "unset"),
        )
        # "error" is neither allow nor block: adapters print nothing, so the harness's own
        # prompt stays (a crash must never become a PermissionRequest allow — Codex r8 P1).
        _emit(
            {
                "decision": "error",
                "rule": "error",
                "reason": f"{type(exc).__name__}: {str(exc)[:200]}",
            }
        )
        return 0


if __name__ == "__main__":
    sys.exit(_main_guarded())
