#!/usr/bin/env python3
"""Register the H17 common control at the Codex, Cursor and OpenCode entries.

Usage: register-aidd-cc-hooks.py [--codex ~/.codex/hooks.json] [--cursor ~/.cursor/hooks.json]
                                  [--opencode ~/.config/opencode/opencode.jsonc] [--check]

Idempotent: an entry that is already present is left untouched.  New Codex
handlers are APPENDED to each event array so existing position-keyed trust
entries in config.toml stay valid (aidd-governance#103).  The new Codex
handlers still need an interactive trust review (`/hooks` inside Codex) before
they fire in interactive sessions; `codex exec --dangerously-bypass-hook-trust`
(what codex-parallel.sh already passes) runs them without it.  --check only
reports and exits 1 when something is missing (used by SessionStart integrity).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

CODEX_SCRIPT = "~/.codex/hooks/aidd-cc-codex.sh"
CURSOR_SCRIPT = "~/.cursor/hooks/aidd-cc-cursor.sh"
OPENCODE_PLUGIN = "./plugins/aidd-cc.ts"
CODEX_EVENTS = (
    "PreToolUse",
    "PostToolUse",
    "UserPromptSubmit",
    "PermissionRequest",
    "Stop",
)
CURSOR_EVENTS = (
    "beforeShellExecution",
    "afterShellExecution",
    "beforeSubmitPrompt",
    "afterAgentResponse",
    "stop",
)


def _write(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def codex(path: Path, check: bool) -> list[str]:
    data = (
        json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"hooks": {}}
    )
    hooks = data.setdefault("hooks", {})
    cmd = f"bash {os.path.expanduser(CODEX_SCRIPT)}"
    missing = []
    for ev in CODEX_EVENTS:
        groups = hooks.setdefault(ev, [])
        present = any(
            h.get("command") == cmd for g in groups for h in g.get("hooks", [])
        )
        if present:
            continue
        missing.append(f"codex:{ev}")
        if check:
            continue
        entry = {
            "type": "command",
            "command": cmd,
            "timeout": 12,
            "statusMessage": f"AIDD H17 common control ({ev})",
        }
        if groups and ev in ("PreToolUse", "PostToolUse"):
            groups[0].setdefault("hooks", []).append(
                entry
            )  # append: keeps 0:0 / 0:1 trust keys
        else:
            groups.append(
                {
                    **(
                        {"matcher": ".*"} if ev in ("PreToolUse", "PostToolUse") else {}
                    ),
                    "hooks": [entry],
                }
            )
    if missing and not check:
        _write(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return missing


def cursor(path: Path, check: bool) -> list[str]:
    data = (
        json.loads(path.read_text(encoding="utf-8"))
        if path.exists()
        else {"version": 1, "hooks": {}}
    )
    hooks = data.setdefault("hooks", {})
    cmd = os.path.expanduser(CURSOR_SCRIPT)
    missing = []
    for ev in CURSOR_EVENTS:
        arr = hooks.setdefault(ev, [])
        if any(h.get("command") == cmd for h in arr):
            continue
        missing.append(f"cursor:{ev}")
        if not check:
            arr.append({"command": cmd, "type": "command", "timeout": 12})
    if missing and not check:
        _write(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return missing


def opencode(path: Path, check: bool) -> list[str]:
    if not path.exists():
        return ["opencode:config-missing"]
    text = path.read_text(encoding="utf-8")
    if OPENCODE_PLUGIN in text:
        return []
    if check:
        return ["opencode:plugin"]
    m = re.search(r'"plugin"\s*:\s*\[', text)
    if not m:
        return ["opencode:plugin-key-missing"]
    text = text[: m.end()] + f'"{OPENCODE_PLUGIN}", ' + text[m.end() :]
    _write(path, text)
    return ["opencode:plugin"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--codex", default="~/.codex/hooks.json")
    ap.add_argument("--cursor", default="~/.cursor/hooks.json")
    ap.add_argument("--opencode", default="~/.config/opencode/opencode.jsonc")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    out = []
    out += codex(Path(os.path.expanduser(a.codex)), a.check)
    out += cursor(Path(os.path.expanduser(a.cursor)), a.check)
    out += opencode(Path(os.path.expanduser(a.opencode)), a.check)
    label = "missing" if a.check else "registered"
    print(f"aidd-cc {label}: {out if out else 'nothing'}")
    return 1 if (a.check and out) else 0


if __name__ == "__main__":
    sys.exit(main())
