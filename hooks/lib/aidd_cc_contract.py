#!/usr/bin/env python3
"""H17 report contract for the non-Claude entries (owner decision 2026-10-23: ship it to every tool's always-loaded
instructions). The text lives once, in aidd_cc_contract.md next to this file; tests/test-h17-contract.sh ties its
example lines to the oracle's own patterns (aidd_cc_text.py) and to rules/quality.md.

    python3 -I aidd_cc_contract.py text                 the contract body (the Cursor sessionStart hook prints it)
    python3 -I aidd_cc_contract.py install FILE [...]   put the managed block into each FILE

`install` only touches the block between BEGIN and END: an owner's own lines stay as they are. A file that is a
whole-file copy from #440 (first line `<!-- Deployed by claude-code-skills setup.sh …`) is replaced by the block,
since setup.sh owned all of it. A BEGIN without an END is refused (exit 2) rather than guessed at.
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BEGIN = "<!-- BEGIN AIDD H17 report contract (managed by claude-code-skills setup.sh from hooks/lib/aidd_cc_contract.md; edits inside are overwritten) -->"
END = "<!-- END AIDD H17 report contract -->"
LEGACY = "<!-- Deployed by claude-code-skills setup.sh"


def contract() -> str:
    return (HERE / "aidd_cc_contract.md").read_text(encoding="utf-8").strip()


def block() -> str:
    return f"{BEGIN}\n{contract()}\n{END}\n"


def merged(old: str | None) -> str:
    """The file's new text: the block replaced in place, appended, or the whole file for a missing or #440 copy."""
    if old is None or old.startswith(LEGACY):
        return block()
    start, end = old.find(BEGIN), old.find(END)
    if start == -1 and end == -1:
        return old.rstrip("\n") + "\n\n" + block()
    if start == -1 or end < start:
        raise ValueError("unbalanced AIDD H17 contract markers")
    rest = old[end + len(END) :].lstrip("\n")
    return old[:start] + block() + ("\n" + rest if rest else "")


def install(path: Path) -> str:
    old = path.read_text(encoding="utf-8") if path.exists() else None
    new = merged(old)
    if new == old:
        return "unchanged"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new, encoding="utf-8")
    return "created" if old is None else "updated"


def main(argv: list[str]) -> int:
    if argv[:1] == ["text"]:
        sys.stdout.write(contract() + "\n")
        return 0
    if argv[:1] != ["install"] or len(argv) < 2:
        sys.stderr.write(__doc__ or "")
        return 2
    rc = 0
    for name in argv[1:]:
        try:
            sys.stdout.write(f"{install(Path(name).expanduser())}: {name}\n")
        except (OSError, ValueError) as e:
            sys.stderr.write(f"refused: {name}: {e}\n")
            rc = 2
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
