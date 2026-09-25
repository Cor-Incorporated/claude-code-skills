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
after it was trusted; Codex lists it as "modified"). It reads as active.
Entries are matched by position alone, so one written for another hooks.json
at the same position is read together with this one.

Prints one line per inactive hook; prints nothing when everything is active.
Exits 0 in all cases: this is a warn-only reporter, and a broken reporter must
not break the SessionStart hook that calls it.

Ref: aidd-governance#103
"""

import json
import os
import re
import sys

# One segment of a dotted key: bare, "basic" (escapes allowed) or 'literal'.
SEGMENT = r"""(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*')"""
KEY_PATH = SEGMENT + r"(?:[ \t]*\.[ \t]*" + SEGMENT + r")*"
STRING = r"""(?:"(?:[^"\\]|\\.)*"|'[^']*')"""
# [a.b."c"] or [[a.b]], with the whitespace and trailing comment TOML allows.
HEADER = re.compile(
    r"^[ \t]*\[(\[?)[ \t]*(" + KEY_PATH + r")[ \t]*\]\]?[ \t]*(?:#.*)?$"
)
# Any other line that opens with [ still starts a table, just not one read here.
TABLE_START = re.compile(r"^[ \t]*\[")
PAIR = re.compile(r"^[ \t]*(" + KEY_PATH + r")[ \t]*=[ \t]*(.*)$")
INLINE_PAIR = re.compile("(" + KEY_PATH + r")[ \t]*=[ \t]*(" + STRING + r"|[^,}]*)")
ESCAPE = re.compile(r"\\(?:u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8})|(.))")
SHORT_ESCAPES = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r",
                 '"': '"', "\\": "\\"}
FIELDS = ("enabled", "trusted_hash")
POSITION = re.compile(r":([a-z_]+:\d+:\d+)$")

# Only these states stay quiet. A state missing from REASONS is still reported
# (under its own name): nothing is accepted as active by default.
ACTIVE = ("enabled", "unset")
REASONS = {
    "absent": "no trust entry",
    "untrusted": "no trusted_hash",
    "disabled": "trust disabled",
    "invalid": "config.toml rejected",
}
# The states of an entry, worst first.
RANK = ("invalid", "disabled", "untrusted", "unset", "enabled")


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


def _unescape(text):
    """Decode the escapes of a TOML basic string ("\\u0065" -> "e")."""

    def one(match):
        code = match.group(1) or match.group(2)
        if code:
            point = int(code, 16)
            return chr(point) if point <= 0x10FFFF else match.group(0)
        return SHORT_ESCAPES.get(match.group(3), match.group(0))

    return ESCAPE.sub(one, text)


def _segments(key_path):
    """The unquoted segments of a dotted key: 'hooks."a.b"' -> ["hooks", "a.b"]."""
    out = []
    for segment in re.findall(SEGMENT, key_path):
        if segment[0] == '"':
            out.append(_unescape(segment[1:-1]))
        elif segment[0] == "'":
            out.append(segment[1:-1])
        else:
            out.append(segment)
    return out


def _carry(text, closer=None, depth=0):
    """Follow a TOML value across one line.

    `closer` is the delimiter of a multi-line string still open and `depth`
    the number of arrays or inline tables still open; both are returned for
    the next line. Lines inside such a value are neither keys nor headers.
    The third value is the index just past the bracket that first brings
    `depth` back to 0 on this line (-1 if none): where an inline table ends.
    """
    i, end = 0, -1
    while i < len(text):
        char = text[i]
        if closer:
            if closer == '"""' and char == "\\":
                i += 2  # \" inside """...""" does not close it
            elif text.startswith(closer, i):
                while i < len(text) and text[i] == char:
                    i += 1  # 3 to 5 quotes close; any past 3 belong to the string
                closer = None
            else:
                i += 1
        elif text.startswith('"""', i) or text.startswith("'''", i):
            closer, i = text[i:i + 3], i + 3
        elif char in "\"'":
            i += 1
            while i < len(text) and text[i] != char:
                i += 2 if char == '"' and text[i] == "\\" else 1
            i += 1
        elif char == "#":
            break
        else:
            depth += {"[": 1, "{": 1, "]": -1, "}": -1}.get(char, 0)
            if char in "]}" and depth == 0 and end < 0:
                end = i + 1
            i += 1
    return closer, depth, end


def _events(text):
    """(table, key, value) per key/value line and (table, None, None) per header.

    Tables and keys come as lists of unquoted segments. After an [[array of
    tables]] or a header this reader cannot parse, keys are skipped until the
    next header it can.
    """
    table, closer, depth = [], None, 0
    for line in text.split("\n"):
        if closer or depth > 0:
            closer, depth, _ = _carry(line, closer, depth)
            continue
        header = HEADER.match(line)
        if header and not header.group(1):
            table = _segments(header.group(2))
            yield table, None, None
        elif TABLE_START.match(line):
            table = None
        else:
            pair = PAIR.match(line)
            if pair:
                closer, depth, _ = _carry(pair.group(2))
                if table is not None:
                    yield table, _segments(pair.group(1)), pair.group(2)


def _field(entry, name, rest, value):
    """Record key `name` of a trust entry; `rest` follows it in a dotted key."""
    if name not in FIELDS:
        return  # Codex ignores other keys
    if rest or value is None:
        entry["invalid"] = True  # `enabled.x = ...` or [..."<key>".enabled]: a table
    elif name == "enabled":
        entry["enabled"].append(value.split("#", 1)[0].strip())
    else:
        entry["trusted_hash"].append(value.strip())


def _inline(entry, value):
    """The fields of `"<key>" = { ... }`, written under [hooks.state]."""
    text = value.strip()
    end = _carry(text)[2]
    if not text.startswith("{") or end < 0:
        entry["invalid"] = True  # not a table, or one that goes on past this line
        return
    # Up to the closing brace only: a comment after it is not part of the table.
    for key_path, item in INLINE_PAIR.findall(text[:end]):
        segments = _segments(key_path)
        _field(entry, segments[0], segments[1:], item)


def _define(entry, how):
    """Record how an entry's table is written. TOML allows one way, once:
    a [header], an inline table, or dotted keys from a parent table (which may
    repeat). Anything else is a TOML error, and Codex refuses the file."""
    if entry["defined"] and (how not in entry["defined"] or how != "parent"):
        entry["invalid"] = True
    entry["defined"].add(how)


def _record(entries, table, key, value):
    """Fold one event of _events() into the entries under [hooks.state]."""
    path = table + (key or [])
    if len(path) < 3 or path[:2] != ["hooks", "state"]:
        return
    entry = entries.setdefault(
        path[2], {"enabled": [], "trusted_hash": [], "invalid": False, "defined": set()}
    )
    if key is None and len(path) == 3:
        _define(entry, "header")
    elif len(path) == 3:
        _define(entry, "inline")
        _inline(entry, value)
    else:
        if key is not None and len(table) < 3:
            _define(entry, "parent")  # "<key>".enabled = ... under [hooks.state] etc.
        _field(entry, path[3], path[4:], value)


def _entry_state(entry):
    """What Codex makes of one trust entry (hook_enabled, hook_trust_status)."""
    enabled, hashes = entry["enabled"], entry["trusted_hash"]
    if (
        entry["invalid"]
        or len(enabled) > 1
        or len(hashes) > 1
        or any(value not in ("true", "false") for value in enabled)
        or any(value[:1] not in ("'", '"') for value in hashes)
    ):
        # Not a boolean / not a string / written twice: Codex refuses config.toml.
        return "invalid"
    if enabled == ["false"]:
        return "disabled"
    if not hashes:
        return "untrusted"
    # Codex treats a missing `enabled` as active, but record it distinctly
    # so a config written by hand is not confused with one Codex wrote.
    return "enabled" if enabled else "unset"


def trust_state(config_toml):
    """Map "<event>:<matcher>:<hook>" to the state of its trust entry.

    config.toml is read the way TOML reads it, as far as a trust entry can be
    spelled: headers with quoted segments, whitespace and trailing comments;
    dotted keys at any level; inline tables; quoted keys and their escapes;
    comments, blank lines, CRLF, a byte order mark and a last line without a
    newline. Lines inside a multi-line string or array are never read as keys
    or headers.

    Codex refuses the whole file when any entry has a value of the wrong type
    or is written twice, so one such entry makes every entry "invalid". Where
    two entries share a position (one per hooks.json), the worse state counts.

    Until 2026-09-25 one regex took only lines of the exact form `key = value`
    plus a newline, directly under the header. Codex reads `enabled=false`, or
    an `enabled = false` on the last line of the file, as disabled; this
    reporter read those two and 11 more spellings that Codex CLI 0.156.0 skips
    as active. tests/lib/codex-trust-forms.txt lists the spellings with what
    Codex does with each.
    """
    # Text mode turns CRLF into "\n" (universal newlines), so a CR never reaches
    # the patterns; the CRLF rows of the table fail if that changes.
    text = open(config_toml, encoding="utf-8-sig", errors="replace").read()
    entries = {}
    for table, key, value in _events(text):
        _record(entries, table, key, value)
    states = {key: _entry_state(entry) for key, entry in entries.items()}
    rejected = "invalid" in states.values()
    out = {}
    for key, state in states.items():
        found = POSITION.search(key.strip())  # Codex trims the key
        if not found:
            continue
        state = "invalid" if rejected else state
        position = found.group(1)
        if position not in out or RANK.index(state) < RANK.index(out[position]):
            out[position] = state
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
                "Codex refuses to load config.toml, so no hook runs, while a trust "
                "entry has a value of the wrong type (enabled: true or false, "
                "trusted_hash: a string) or is written twice; `codex` names the line"
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
