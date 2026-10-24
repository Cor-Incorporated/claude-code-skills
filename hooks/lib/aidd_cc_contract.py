#!/usr/bin/env python3
"""H17 report contract for the non-Claude entries (owner decision 2026-10-23: ship it to every tool's always-loaded
instructions). The text lives once, in aidd_cc_contract.md next to this file; tests/test-h17-contract.sh ties its
lines to the oracle's own patterns (aidd_cc_text.py), to rules/quality.md, and to the gate's real verdict on each entry.

    python3 -I aidd_cc_contract.py text --agent A                     the contract for entry A (Cursor's sessionStart hook)
    python3 -I aidd_cc_contract.py install --agent A FILE [...]       put the managed block into the file entry A reads
    python3 -I aidd_cc_contract.py register-opencode CONFIG FILE      list FILE in an OpenCode 2.x config's `instructions`

Exit status: Cursor's shell hook carries no exit code, so its text says `<cmd>; echo exit=$?` (the gate then reads the
marker). Every other entry reports codes for shell calls (Codex measured: 1339 harness codes, 10 markers), and a
semicolon there masks the command's own code, so their text says "run it alone" (Codex review r1 P1, r2 P2).

`install` only touches the block between BEGIN and END: an owner's own lines stay as they are. A file that is a
whole-file copy from #440 (first line `<!-- Deployed by claude-code-skills setup.sh …`) is replaced by the block,
since setup.sh owned all of it. A BEGIN without an END is refused (exit 2) rather than guessed at. The file is the
one the tool reads: Pi takes the first EXISTING of AGENTS.override.md / AGENTS.md / AGENTS.MD / CLAUDE.md / CLAUDE.MD
(even an empty one), Codex the first NON-EMPTY of AGENTS.override.md / AGENTS.md (Codex review r1 / r2 P2).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BEGIN = "<!-- BEGIN AIDD H17 report contract (managed by claude-code-skills setup.sh from hooks/lib/aidd_cc_contract.md; edits inside are overwritten) -->"
END = "<!-- END AIDD H17 report contract -->"
LEGACY = "<!-- Deployed by claude-code-skills setup.sh"
ECHO_STYLE = frozenset({"cursor"})  # the entry's shell hook reports no exit code
PI_CANDIDATES = (
    "AGENTS.override.md",
    "AGENTS.md",
    "AGENTS.MD",
    "CLAUDE.md",
    "CLAUDE.MD",
)  # pi resource-loader.js order
VARIANT_RE = re.compile(
    r"<!-- exit-status: (?P<kind>[a-z-]+) -->\n(?P<body>.*?)(?=<!-- (?:exit-status: [a-z-]+|end exit-status) -->)",
    re.S,
)


def contract(agent: str) -> str:
    text = (HERE / "aidd_cc_contract.md").read_text(encoding="utf-8")
    variants = {m["kind"]: m["body"].strip() for m in VARIANT_RE.finditer(text)}
    common = text[: text.index("<!-- exit-status:")].strip()
    return f"{common}\n\n{variants['echo' if agent in ECHO_STYLE else 'alone']}"


def block(agent: str) -> str:
    return f"{BEGIN}\n{contract(agent)}\n{END}\n"


def merged(old: str | None, agent: str) -> str:
    """The file's new text: the block replaced in place, appended, or the whole file for a missing or #440 copy."""
    if old is None or old.startswith(LEGACY):
        return block(agent)
    start, end = old.find(BEGIN), old.find(END)
    if start == -1 and end == -1:
        return old.rstrip("\n") + "\n\n" + block(agent)
    if start == -1 or end < start:
        raise ValueError("unbalanced AIDD H17 contract markers")
    rest = old[end + len(END) :].lstrip("\n")
    return old[:start] + block(agent) + ("\n" + rest if rest else "")


def target(path: Path, agent: str) -> Path:
    """The file the tool actually reads in path's directory (path itself when the tool has no choice to make)."""
    if path.name != "AGENTS.md":
        return path
    if agent == "pi":
        return next(
            (path.with_name(n) for n in PI_CANDIDATES if path.with_name(n).is_file()),
            path,
        )
    override = path.with_name("AGENTS.override.md")
    if (
        agent == "codex"
        and override.is_file()
        and override.read_text(encoding="utf-8").strip()
    ):
        return override
    return path


def install(path: Path, agent: str) -> tuple[str, Path]:
    dest = target(path, agent)
    old = dest.read_text(encoding="utf-8") if dest.exists() else None
    new = merged(old, agent)
    if new == old:
        return "unchanged", dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(new, encoding="utf-8")
    return ("created" if old is None else "updated"), dest


def register_opencode(config: Path, file: Path) -> str:
    """OpenCode 2.x launched through guardrails replaces the global config DIR (so its AGENTS.md is not read) but keeps
    the global config FILE via OPENCODE_CONFIG; a document's `instructions` are loaded either way (Codex review r2 P1)."""
    existed = config.exists()
    data = json.loads(config.read_text(encoding="utf-8")) if existed else {}
    listed = data.get("instructions", []) if isinstance(data, dict) else None
    if not isinstance(listed, list):
        raise ValueError("config is not an object with an `instructions` list")
    if str(file) in listed:
        return "unchanged"
    config.parent.mkdir(parents=True, exist_ok=True)
    tmp = config.with_suffix(config.suffix + ".tmp")
    tmp.write_text(json.dumps({**data, "instructions": [*listed, str(file)]}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.chmod(config.stat().st_mode & 0o7777 if existed else 0o600)  # keep the config's own permissions (Codex review r4 P2)
    tmp.replace(config)
    return "updated" if existed else "created"


def main(argv: list[str]) -> int:
    if argv[:1] == ["register-opencode"] and len(argv) == 3:
        try:
            sys.stdout.write(
                f"{register_opencode(Path(argv[1]).expanduser(), Path(argv[2]).expanduser())}: {argv[1]} instructions\n"
            )
            return 0
        except (OSError, ValueError) as e:
            sys.stderr.write(f"refused: {argv[1]}: {e}\n")
            return 2
    if (
        len(argv) < 3
        or argv[1] != "--agent"
        or argv[0] not in ("text", "install")
        or (argv[0] == "install" and len(argv) < 4)
    ):
        sys.stderr.write(__doc__ or "")
        return 2
    agent = argv[2]
    if argv[0] == "text":
        sys.stdout.write(contract(agent) + "\n")
        return 0
    rc = 0
    for name in argv[3:]:
        try:
            state, dest = install(Path(name).expanduser(), agent)
            sys.stdout.write(f"{state}: {dest} ({agent})\n")
        except (OSError, ValueError) as e:
            sys.stderr.write(f"refused: {name}: {e}\n")
            rc = 2
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
