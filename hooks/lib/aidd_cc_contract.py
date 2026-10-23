#!/usr/bin/env python3
"""H17 report contract for the non-Claude entries (owner decision 2026-10-23: ship it to every tool's always-loaded
instructions). The text lives once, in aidd_cc_contract.md next to this file; tests/test-h17-contract.sh ties its
example lines to the oracle's own patterns (aidd_cc_text.py) and to rules/quality.md.

    python3 -I aidd_cc_contract.py text --agent A                the contract for entry A (Cursor's sessionStart hook)
    python3 -I aidd_cc_contract.py install --agent A FILE [...]  put the managed block into each FILE

The exit-status paragraph follows the oracle (ADR-011): an entry in aidd_cc.CODE_REPORTING_AGENTS reports exit codes
and gets "run it alone"; any other entry gets "run it as `<cmd>; echo exit=$?`", the form the gate reads when the
harness sent no code (Codex review of this change, P1).

`install` only touches the block between BEGIN and END: an owner's own lines stay as they are. A file that is a
whole-file copy from #440 (first line `<!-- Deployed by claude-code-skills setup.sh …`) is replaced by the block,
since setup.sh owned all of it. A BEGIN without an END is refused (exit 2) rather than guessed at. Codex and Pi read
only a non-empty AGENTS.override.md when there is one, so for them the block goes there instead (Codex review P2).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BEGIN = "<!-- BEGIN AIDD H17 report contract (managed by claude-code-skills setup.sh from hooks/lib/aidd_cc_contract.md; edits inside are overwritten) -->"
END = "<!-- END AIDD H17 report contract -->"
LEGACY = "<!-- Deployed by claude-code-skills setup.sh"
OVERRIDE_READERS = frozenset(
    {"codex", "pi"}
)  # read <dir>/AGENTS.override.md instead of AGENTS.md when it is non-empty
VARIANT_RE = re.compile(
    r"<!-- exit-status: (?P<kind>[a-z-]+) -->\n(?P<body>.*?)(?=<!-- (?:exit-status: [a-z-]+|end exit-status) -->)",
    re.S,
)


def reports_codes(agent: str) -> bool:
    """agent is in aidd_cc.CODE_REPORTING_AGENTS. Read from the oracle's source rather than imported, so the text also
    renders on a python3 too old to import the oracle (the Cursor hook must never start a session without it);
    tests/test-h17-contract.sh compares this reading with the imported set."""
    m = re.search(r"^CODE_REPORTING_AGENTS = frozenset\(\{([^}]*)\}\)", (HERE / "aidd_cc.py").read_text(encoding="utf-8"), re.M)
    if not m:
        raise ValueError("CODE_REPORTING_AGENTS not found in aidd_cc.py")
    return agent in re.findall(r'"([a-z0-9-]+)"', m.group(1))


def contract(agent: str) -> str:
    text = (HERE / "aidd_cc_contract.md").read_text(encoding="utf-8")
    variants = {m["kind"]: m["body"].strip() for m in VARIANT_RE.finditer(text)}
    common = text[: text.index("<!-- exit-status:")].strip()
    return f"{common}\n\n{variants['code-reporting' if reports_codes(agent) else 'no-code']}"


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
    override = path.with_name("AGENTS.override.md")
    if (
        agent in OVERRIDE_READERS
        and path.name == "AGENTS.md"
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


def main(argv: list[str]) -> int:
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
