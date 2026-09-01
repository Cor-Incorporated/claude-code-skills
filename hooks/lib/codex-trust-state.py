#!/usr/bin/env python3
"""Report Codex hooks that are registered but not actually active.

usage: codex-trust-state.py <hooks.json> <config.toml>

Codex stores hook trust in config.toml keyed by POSITION, e.g.

    [hooks.state."/Users/x/.codex/hooks.json:pre_tool_use:0:0"]
    trusted_hash = "sha256:..."
    enabled = true

A hook that is registered in hooks.json but has `enabled = false`, or has no
trust entry at all, is skipped SILENTLY at runtime -- no error, no log line.

2026-09-01: protect-branches-codex.sh existed in the repo, was copied into
~/.codex/hooks, was registered in hooks.json, and its MD5 matched the repo
source -- all three documented deploy requirements were satisfied -- yet it
fired zero times for 19 days because its entry said `enabled = false`.
pair7 (registration -> file exists) and pair11 (source -> deployed MD5) both
passed the whole time, because neither reads trust state.

Because trust is keyed by position, inserting a hook at index 0 also
invalidates the entry that used to sit there, silently disabling a guard that
was working a moment earlier.

Prints one line per inactive hook; prints nothing when everything is active.
Exits 0 in all cases: this is a warn-only reporter, and a broken reporter must
not break the SessionStart hook that calls it.

Ref: aidd-governance#103
"""

import json
import os
import re
import sys

EVENT_KEY = {"PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use"}
TRUST_BLOCK = re.compile(
    r'\[hooks\.state\."[^"]*:([a-z_]+:\d+:\d+)"\]\n((?:[a-z_]+ = [^\n]*\n)*)'
)


def registered(hooks_json):
    out = {}
    for event, matchers in json.load(open(hooks_json)).get("hooks", {}).items():
        key = EVENT_KEY.get(event, event.lower())
        for mi, matcher in enumerate(matchers):
            for hi, hook in enumerate(matcher.get("hooks", [])):
                command = hook.get("command", "")
                name = os.path.basename(command.split()[-1]) if command else "?"
                out[f"{key}:{mi}:{hi}"] = name
    return out


def trust_state(config_toml):
    text = open(config_toml, encoding="utf-8", errors="replace").read()
    out = {}
    for match in TRUST_BLOCK.finditer(text):
        body = match.group(2)
        if re.search(r"^enabled = false", body, re.M):
            out[match.group(1)] = "disabled"
        elif re.search(r"^enabled = true", body, re.M):
            out[match.group(1)] = "enabled"
        else:
            # Codex treats a missing `enabled` as active, but record it distinctly
            # so a config written by hand is not confused with one Codex wrote.
            out[match.group(1)] = "unset"
    return out


def main():
    if len(sys.argv) != 3:
        return 0
    try:
        reg = registered(sys.argv[1])
        trust = trust_state(sys.argv[2])
    except Exception:
        # Unreadable config is not this reporter's problem to escalate.
        return 0

    for index, script in sorted(reg.items()):
        state = trust.get(index, "absent")
        if state not in ("disabled", "absent"):
            continue
        why = "trust disabled" if state == "disabled" else "no trust entry"
        print(
            f"CODEX HOOK NOT ACTIVE: {script} at {index} ({why}) - registered in "
            f"hooks.json but skipped silently at runtime. Grant trust in an "
            f"interactive `codex` session. Ref: aidd-governance#103"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
