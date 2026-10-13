#!/usr/bin/env python3
"""aidd-cc — AIDD common control (H17) CLI used by every harness adapter.

    aidd_cc.py <cmd> --agent <claude-code|codex|cursor|opencode> [--session S] [--cwd C]
    stdin: the harness hook payload as JSON (or {} for CLI-only commands)

Commands (all print one JSON object; exit 0 unless noted):
  pre         PreToolUse: C-ITER + C-DECISION(question) -> decision allow/block
  post        PostToolUse: record rc/output for evidence binding
  prompt      UserPromptSubmit: register user decisions / deadlines
  permission  PermissionRequest: allow only if a user decision binds it
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
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aidd_cc_eval as ev  # noqa: E402
from aidd_cc_controls import (  # noqa: E402
    control_sha,
    iteration_check,
    permission_check,
    question_check,
    register_note,
    stop_check,
)
from aidd_cc_session import guard_ledger, load_meta, load_tools, record_tool, save_meta  # noqa: E402
from aidd_cc_text import is_approval_text, normalize_cmd, parse_deadline_hours  # noqa: E402

COMPONENT = "H17"


def _read_payload() -> dict:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except ValueError:
        # Observation failure is not a pass (harness-spec 0-4): record it.
        guard_ledger(COMPONENT, "error", "unreadable", "payload", raw[:100],
                     os.environ.get("AIDD_CC_AGENT", "?"), "unset")
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
    return args.cwd or payload.get("cwd") or os.getcwd()


def _emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False))


def _tool_input(payload: dict) -> dict:
    ti = payload.get("tool_input") or payload.get("args") or payload.get("input") or {}
    if "command" not in ti and payload.get("command"):
        ti = dict(ti, command=payload["command"])
    return ti if isinstance(ti, dict) else {}


def cmd_pre(args, payload):
    agent, session = args.agent, _session(args, payload)
    tool = payload.get("tool_name") or payload.get("tool") or args.tool or "Bash"
    ti = _tool_input(payload)
    meta, rows = load_meta(agent, session), load_tools(agent, session)
    if tool in ("AskUserQuestion", "ask_user", "question"):
        q = json.dumps(ti.get("questions") or ti, ensure_ascii=False)
        verdict = question_check(meta, q)
    else:
        verdict = iteration_check(rows, meta, tool, ti)
    key = (
        ("edit:" + str(ti.get("file_path", "")))
        if tool in ("Edit", "Write", "MultiEdit")
        else normalize_cmd(str(ti.get("command") or ""))[:400]
    )
    record_tool(
        agent,
        session,
        {
            "event": "pre",
            "tool": tool,
            "key": key, "cc_sha": control_sha(),
            "cmd": str(ti.get("command") or "")[:400],
            "decision": verdict["decision"],
        },
    )
    if verdict["decision"] == "block":
        guard_ledger(COMPONENT, "block", "deny", verdict["rule"], key, agent, session)
    _emit(verdict)


def cmd_post(args, payload):
    agent, session = args.agent, _session(args, payload)
    tool = payload.get("tool_name") or payload.get("tool") or args.tool or "Bash"
    ti = _tool_input(payload)
    resp = payload.get("tool_response") or payload.get("output") or {}
    rc = None
    if isinstance(resp, dict):
        rc = resp.get("exit_code", resp.get("exitCode", resp.get("rc")))
        out = str(resp.get("stdout", "")) + str(resp.get("stderr", ""))
    else:
        out = str(resp)
    if rc is None and payload.get("exit_code") is not None:
        rc = payload.get("exit_code")
    if rc is None:
        rc = 0 if not payload.get("error") and not payload.get("is_error") else 1
    key = (
        ("edit:" + str(ti.get("file_path", "")))
        if tool in ("Edit", "Write", "MultiEdit")
        else normalize_cmd(str(ti.get("command") or ""))[:400]
    )
    record_tool(
        agent,
        session,
        {
            "event": "post",
            "tool": tool,
            "key": key,
            "rc": rc,
            "cmd": str(ti.get("command") or "")[:400],
            "out_bytes": len(out),
        },
    )
    _emit({"decision": "allow", "rule": "record", "rc": rc})


def cmd_prompt(args, payload):
    agent, session = args.agent, _session(args, payload)
    text = str(
        payload.get("prompt") or payload.get("text") or payload.get("message") or ""
    )
    meta = load_meta(agent, session)
    registered = []
    if is_approval_text(text) and len(text.strip()) >= 4:
        import hashlib

        sha = hashlib.sha256(text.encode()).hexdigest()[:16]
        meta["decisions"].append(
            {
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "sha": sha,
                "text": text[:600],
            }
        )
        registered.append("decision")
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


def cmd_permission(args, payload):
    agent, session = args.agent, _session(args, payload)
    ti = _tool_input(payload)
    text = json.dumps(ti, ensure_ascii=False) + " " + str(payload.get("message", ""))
    verdict = permission_check(load_meta(agent, session), text)
    if verdict["decision"] == "allow":
        guard_ledger(
            COMPONENT, "measure", "allow", verdict["rule"], text[:100], agent, session
        )
    _emit(verdict)


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


def cmd_stop(args, payload):
    agent, session = args.agent, _session(args, payload)
    meta, rows = load_meta(agent, session), load_tools(agent, session)
    if payload.get("stop_hook_active") and not args.ignore_active:
        _emit({"decision": "allow", "rule": "evidence.loop-guard"})
        return 0
    if meta.get("stop_blocks", 0) >= args.max_blocks:
        _emit(
            {
                "decision": "allow",
                "rule": "evidence.max-blocks",
                "blocks": meta["stop_blocks"],
            }
        )
        return 0
    text = _last_assistant(payload, meta)
    verdict = stop_check(meta, rows, text, _cwd(args, payload))
    if verdict["decision"] == "block":
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
    """Cursor afterAgentResponse / OpenCode: keep the last assistant text for stop."""
    agent, session = args.agent, _session(args, payload)
    meta = load_meta(agent, session)
    meta["last_assistant"] = str(payload.get("text") or payload.get("message") or "")[
        :20000
    ]
    save_meta(agent, session, meta)
    _emit({"decision": "allow", "rule": "record-assistant"})


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
            "permission",
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
    payload = (
        _read_payload()
        if args.cmd not in ("readback", "deadline", "denominator", "note")
        else {}
    )
    handler = {
        "pre": cmd_pre,
        "post": cmd_post,
        "prompt": cmd_prompt,
        "permission": cmd_permission,
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


if __name__ == "__main__":
    sys.exit(main())
