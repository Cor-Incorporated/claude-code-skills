#!/usr/bin/env python3
"""Register Codex H1's UserPromptSubmit hook without replacing other hooks.

Usage: register-codex-h1-hooks.py HOOKS_JSON CODEX_HOOKS_DIR
The new definition still requires an interactive trust review in Codex /hooks.
"""

import json
import os
import shlex
import stat
import sys
import tempfile
from pathlib import Path


def command_path(handler):
    if not isinstance(handler, dict) or handler.get("type") != "command":
        return None
    try:
        parts = shlex.split(handler.get("command", ""))
    except ValueError:
        return None
    if len(parts) != 2 or parts[0] != "bash":
        return None
    return Path(os.path.expanduser(parts[1])).resolve()


def handlers(groups, event):
    value = groups.get(event, [])
    if not isinstance(value, list):
        raise ValueError(f"{event} must be an array")
    for group in value:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            raise ValueError(f"{event} has an invalid matcher group")
        for handler in group["hooks"]:
            yield group, handler


def register(path, hook_dir):
    h1_path = (hook_dir / "h1-stall-runtime.sh").resolve()
    protect_path = (hook_dir / "protect-branches-codex.sh").resolve()
    if not h1_path.is_file() or not protect_path.is_file():
        raise ValueError("both deployed Codex hook scripts must exist")
    existed = path.exists()
    if existed:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("hooks"), dict):
            raise ValueError("hooks.json must contain a hooks object")
    else:
        data = {"hooks": {"PreToolUse": [{"matcher": ".*", "hooks": [
            {"type": "command", "command": f"bash {shlex.quote(str(protect_path))}"},
            {"type": "command", "command": f"bash {shlex.quote(str(h1_path))}"},
        ]}]}}
    groups = data["hooks"]
    pre = list(handlers(groups, "PreToolUse"))
    protect = [(g, h) for g, h in pre if command_path(h) == protect_path]
    h1 = [(g, h) for g, h in pre if command_path(h) == h1_path]
    if len(protect) != 1 or len(h1) != 1:
        raise ValueError("PreToolUse must contain exactly one protect hook and one H1 hook")
    for group, _ in protect + h1:
        if group.get("matcher", ".*") not in (".*", ""):
            raise ValueError("PreToolUse guard matcher must cover every tool")
    known = {protect_path, h1_path}
    for _, handler in pre:
        p = command_path(handler)
        if p and p.name in {"protect-branches-codex.sh", "h1-stall-runtime.sh"} and p not in known:
            raise ValueError("PreToolUse guard points to a different script")
    ups = list(handlers(groups, "UserPromptSubmit"))
    matches = [(g, h) for g, h in ups if command_path(h) == h1_path]
    if len(matches) > 1:
        raise ValueError("duplicate UserPromptSubmit H1 hooks")
    for _, handler in ups:
        p = command_path(handler)
        if p and p.name == "h1-stall-runtime.sh" and p != h1_path:
            raise ValueError("UserPromptSubmit H1 points to a different script")
    if matches:
        return False
    groups.setdefault("UserPromptSubmit", []).append({"hooks": [
        {"type": "command", "command": f"bash {shlex.quote(str(h1_path))}"}
    ]})
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        if existed:
            os.fchmod(fd, stat.S_IMODE(path.stat().st_mode))
        else:
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    return True


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: register-codex-h1-hooks.py HOOKS_JSON CODEX_HOOKS_DIR")
    try:
        changed = register(Path(sys.argv[1]).expanduser(), Path(sys.argv[2]).expanduser())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Codex H1 registration failed: {exc}")
    print("Codex H1 UserPromptSubmit hook " + ("registered" if changed else "already registered"))
    print("Review and trust the new hook in Codex /hooks; setup does not grant trust.")
