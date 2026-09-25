#!/usr/bin/env python3
"""Report Codex hooks that are registered but not actually active.

usage: codex-trust-state.py <hooks.json> <config.toml>

Codex stores hook trust in config.toml keyed by POSITION, e.g.

    [hooks.state."/Users/x/.codex/hooks.json:pre_tool_use:0:0"]
    trusted_hash = "sha256:..."
    enabled = true

The event part of that key is the hooks.json event name in snake_case
(UserPromptSubmit -> user_prompt_submit); see event_key().

Codex CLI 0.156.0 runs a registered hook only when its entry has a
`trusted_hash` equal to the hook's current hash and `enabled` is not false
(codex-rs/hooks/src/engine/discovery.rs: hook_enabled, hook_trust_status).
Every other registered hook -- `enabled = false`, no entry, an entry without a
`trusted_hash` -- is skipped SILENTLY at runtime: no error, no log line.

2026-09-01: protect-branches-codex.sh existed in the repo, was copied into
~/.codex/hooks, was registered in hooks.json, and its MD5 matched the repo
source -- all three documented deploy requirements were satisfied -- yet it
fired zero times for 19 days because its entry said `enabled = false`.
pair7 (registration -> file exists) and pair11 (source -> deployed MD5) both
passed the whole time, because neither reads trust state.

Because trust is keyed by position, inserting a hook at index 0 also
invalidates the entry that used to sit there, silently disabling a guard that
was working a moment earlier.

Not detected, because the reporter cannot recompute Codex's hash: a
`trusted_hash` that no longer matches (the hook's command or matcher changed
after it was trusted; Codex lists it as "modified"). An entry written for
another hooks.json at the same position is not told apart either. Both read as
active.

Prints one line per inactive hook; prints nothing when everything is active.
Exits 0 in all cases: this is a warn-only reporter, and a broken reporter must
not break the SessionStart hook that calls it.

Ref: aidd-governance#103
"""

import json
import os
import re
import sys

# A line that opens any table ([x] or [[x]]) ends the table above it.
TABLE_HEADER = re.compile(r"^[ \t]*\[")
# [hooks.state."<key>"], with the whitespace and trailing comment TOML allows.
TRUST_HEADER = re.compile(
    r"""^[ \t]*\[[ \t]*hooks[ \t]*\.[ \t]*state[ \t]*\.[ \t]*"""
    r"""(?:"([^"]*)"|'([^']*)')[ \t]*\][ \t]*(?:#.*)?$"""
)
# key = value, with the key bare, "quoted" or 'literal'.
KEY_VALUE = re.compile(
    r"""^[ \t]*(?:([A-Za-z0-9_-]+)|"([^"]*)"|'([^']*)')[ \t]*=[ \t]*(.*)$"""
)
POSITION = re.compile(r":([a-z_]+:\d+:\d+)$")

# Only these states stay quiet. A state missing from REASONS is still reported
# (under its own name): nothing is accepted as active by default.
ACTIVE = ("enabled", "unset")
REASONS = {
    "absent": "no trust entry",
    "untrusted": "no trusted_hash",
    "disabled": "trust disabled",
    "invalid": "invalid trust entry",
}


def event_key(event):
    """Spell a hooks.json event name the way config.toml keys it.

    hooks.json uses PascalCase (UserPromptSubmit); Codex keys trust in
    snake_case (user_prompt_submit). Convert generally instead of listing
    events: until 2026-09-24 this was a two-entry map (PreToolUse,
    PostToolUse) with an `event.lower()` fallback, so the UserPromptSubmit
    hook that Codex had trusted was looked up as "userpromptsubmit:0:0" and
    reported "no trust entry" at every SessionStart.

    All 12 events of Codex CLI 0.156.0 (PreToolUse ... Interrupt) are plain
    PascalCase, which this rule converts exactly. A future name that it
    converts differently from Codex usually shows up as a false "no trust
    entry" line; it stays silent only if the wrong key happens to equal the
    key of another trusted entry.
    """
    return re.sub(r"(?<!^)(?=[A-Z])", "_", event).lower()


def registered(hooks_json):
    out = {}
    for event, matchers in json.load(open(hooks_json)).get("hooks", {}).items():
        key = event_key(event)
        for mi, matcher in enumerate(matchers):
            for hi, hook in enumerate(matcher.get("hooks", [])):
                command = hook.get("command", "")
                name = os.path.basename(command.split()[-1]) if command else "?"
                out[f"{key}:{mi}:{hi}"] = name
    return out


def _position(line):
    """Return "<event>:<matcher>:<hook>" of a [hooks.state."..."] header, or None."""
    header = TRUST_HEADER.match(line)
    if not header:
        return None
    key = header.group(1) if header.group(1) is not None else header.group(2)
    found = POSITION.search(key.strip())  # Codex trims the key
    return found.group(1) if found else None


def _entry_state(lines):
    """State of one trust entry, from the lines of its table."""
    enabled, hashes = [], []
    for line in lines:
        pair = KEY_VALUE.match(line)
        if not pair:
            continue  # blank line, comment, or no key/value on this line
        key = next(part for part in pair.groups()[:3] if part is not None)
        if key == "enabled":
            enabled.append(pair.group(4).split("#", 1)[0].strip())
        elif key == "trusted_hash":
            hashes.append(pair.group(4).strip())
    if "false" in enabled:
        return "disabled"
    if any(value != "true" for value in enabled) or any(
        value[:1] not in ("'", '"') for value in hashes
    ):
        # Not a boolean / not a string: Codex refuses to load config.toml.
        return "invalid"
    if not hashes:
        return "untrusted"
    # Codex treats a missing `enabled` as active, but record it distinctly
    # so a config written by hand is not confused with one Codex wrote.
    return "enabled" if enabled else "unset"


def trust_state(config_toml):
    """Map "<event>:<matcher>:<hook>" to the state of its trust entry.

    Every line of a [hooks.state."..."] table counts, up to the next table
    header, read with the rules TOML has for them: whitespace and indentation,
    comments, blank lines, quoted keys, CRLF, no newline after the last line.
    Until 2026-09-25 one regex took only lines of the exact form `key = value`
    plus a newline, directly under the header. Codex reads `enabled=false`, or
    an `enabled = false` on the last line of the file, as disabled; this
    reporter read those two and 11 more spellings that Codex CLI 0.156.0 skips
    as active. tests/lib/codex-trust-forms.txt lists them.
    """
    # Text mode turns CRLF into "\n" (universal newlines), so a CR never reaches
    # the patterns; the CRLF rows of the table fail if that changes.
    text = open(config_toml, encoding="utf-8", errors="replace").read()
    out = {}
    position, lines = None, []
    for line in text.split("\n"):
        if TABLE_HEADER.match(line):
            if position:
                out[position] = _entry_state(lines)
            position, lines = _position(line), []
        else:
            lines.append(line)
    if position:
        out[position] = _entry_state(lines)
    return out


def inactive(registered_hooks, trust):
    """[(position, script, state)] for every registered hook Codex does not run.

    tests/test-pairs-link.sh pair15 calls this too, so the SessionStart report
    and the link test cannot disagree about which states are active.
    """
    states = [
        (position, script, trust.get(position, "absent"))
        for position, script in sorted(registered_hooks.items())
    ]
    return [entry for entry in states if entry[2] not in ACTIVE]


def main():
    if len(sys.argv) != 3:
        return 0
    try:
        reg = registered(sys.argv[1])
        trust = trust_state(sys.argv[2])
    except Exception:
        # Unreadable config is not this reporter's problem to escalate.
        return 0

    for position, script, state in inactive(reg, trust):
        if state == "invalid":
            effect = (
                "Codex refuses to load config.toml until the value has the right "
                "type (enabled: true or false, trusted_hash: a string)"
            )
        else:
            effect = (
                "registered in hooks.json but skipped silently at runtime. "
                "Grant trust in an interactive `codex` session"
            )
        print(
            f"CODEX HOOK NOT ACTIVE: {script} at {position} "
            f"({REASONS.get(state, state)}) - {effect}. Ref: aidd-governance#103"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
