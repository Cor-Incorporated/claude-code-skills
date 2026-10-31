#!/usr/bin/env python3
"""Write the declared auto-broadcast opt-out into each listed repository.

usage: apply-auto-broadcast-optout.py <config/auto-broadcast-optout.json> [--home DIR] [--check]

For every repository in the declaration that is a git checkout, the declared
file (.claude/sessions/auto-broadcast.json) gets the declared content. A file
that already holds different content is left alone and reported with both
values: someone chose it on purpose. --check changes nothing and exits 1 when a
listed checkout lacks the declared content.

Origin: aidd-governance#230 F8 (2026-10-30/31). The harness plugin broadcast
every .md/.sh/.go edit, including Claude Code memory paths, to other sessions.
"""
import argparse
import json
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("declaration")
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    decl = json.load(open(args.declaration, encoding="utf-8"))
    want = decl["content"]
    missing = 0
    for raw in decl["repos"]:
        repo = os.path.join(args.home, raw[2:]) if raw.startswith("~/") else raw
        if not os.path.isdir(os.path.join(repo, ".git")):
            print(f"  ↻ {raw}: not a git checkout here, skipped")
            continue
        target = os.path.join(repo, decl["file"])
        current = None
        if os.path.exists(target):
            try:
                current = json.load(open(target, encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                current = "<unreadable>"
        if current == want:
            print(f"  = {raw}: already {json.dumps(want)}")
            continue
        if current is not None:
            print(f"  ! {raw}: left as is, it holds {json.dumps(current)} (declared {json.dumps(want)})")
            continue
        if args.check:
            print(f"  ✗ {raw}: {decl['file']} missing")
            missing += 1
            continue
        os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        with open(target, "w", encoding="utf-8") as fh:
            json.dump(want, fh)
            fh.write("\n")
        print(f"  + {raw}: wrote {decl['file']} {json.dumps(want)}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
