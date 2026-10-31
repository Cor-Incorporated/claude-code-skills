#!/usr/bin/env python3
"""Write the declared auto-broadcast opt-out into each listed repository.

usage: apply-auto-broadcast-optout.py <config/auto-broadcast-optout.json> [--home DIR] [--check]

For every repository in the declaration that is a git checkout at
~/Developer/<name>, the plugin's opt-out file (.claude/sessions/auto-broadcast.json)
gets the content {"enabled": false}. A file that already exists is left
alone: someone chose it on purpose. It is reported with both values when it
holds an opt-out choice ({"enabled": true}); any other content, a symlink or a
FIFO is reported without being shown or followed. --check changes nothing and
exits 1 when a listed checkout lacks the file.

The declaration may only list repositories; the file name and the content are
fixed here, so a declaration cannot make this write anywhere else or anything
else (review of #457: `~/../x`, `../../x`, an absolute file and a symlink all
escaped). A failure in one repository is reported and the others still run,
so setup.sh is never stopped by it.

Origin: aidd-governance#230 F8 (2026-10-30/31). The harness plugin broadcast
every .md/.sh/.go edit, including Claude Code memory paths, to other sessions.
"""
import argparse
import json
import os
import stat
import sys
from typing import Optional

OPTOUT_FILE = os.path.join(".claude", "sessions", "auto-broadcast.json")
OPTOUT_CONTENT = {"enabled": False}


def repo_dir(raw: str, home: str) -> Optional[str]:
    """The real path of a declared repository, or None when it is not ~/Developer/<name>."""
    name = raw[len("~/Developer/"):] if raw.startswith("~/Developer/") else ""
    if not name or "/" in name or name in (".", ".."):
        return None
    root = os.path.realpath(os.path.join(home, "Developer"))
    repo = os.path.realpath(os.path.join(root, name))
    # A direct child only: `a/sub` and a symlink to another place are refused (#457 review round 2).
    if os.path.dirname(repo) != root:
        return None
    return repo


def read_existing(target: str) -> Optional[object]:
    """The JSON in an existing regular opt-out file, or None. Never follows a symlink and never
    blocks on a FIFO (#457 review round 2)."""
    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    with os.fdopen(fd, "rb") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
            return None
        try:
            return json.loads(fh.read(4096).decode("utf-8"))
        except (OSError, ValueError):
            return None


def shown(value: object) -> str:
    """Print an existing choice only when it is an opt-out choice; other content stays unseen, so a
    file planted at the target never lands in an agent's transcript."""
    if isinstance(value, dict) and set(value) == {"enabled"} and isinstance(value["enabled"], bool):
        return f"it holds {json.dumps(value)}"
    return "its content differs and is not shown"


def apply_one(raw: str, home: str, check: bool) -> bool:
    """Handle one repository; returns False when --check finds the file missing."""
    repo = repo_dir(raw, home)
    if repo is None:
        print(f"  ! {raw}: not a repository at ~/Developer/<name>, refused")
        return True
    if not os.path.exists(os.path.join(repo, ".git")):
        print(f"  ↻ {raw}: not a git checkout here, skipped")
        return True
    target = os.path.join(repo, OPTOUT_FILE)
    sessions = os.path.dirname(target)
    # realpath resolves the parts that exist, so a .claude or sessions symlink that points out of
    # the repository is caught before anything is read or created.
    if os.path.commonpath([os.path.realpath(sessions), repo]) != repo:
        print(f"  ! {raw}: {os.path.dirname(OPTOUT_FILE)} leaves the repository, refused")
        return True
    if os.path.lexists(target):
        current = read_existing(target)
        if current == OPTOUT_CONTENT:
            print(f"  = {raw}: already {json.dumps(OPTOUT_CONTENT)}")
        elif current is None:
            print(f"  ! {raw}: left as is, {OPTOUT_FILE} is not a readable regular JSON file (a symlink, a FIFO or broken JSON)")
        else:
            print(f"  ! {raw}: left as is, {shown(current)} (declared {json.dumps(OPTOUT_CONTENT)})")
        return True
    if check:
        print(f"  ✗ {raw}: {OPTOUT_FILE} missing")
        return False
    os.makedirs(sessions, mode=0o700, exist_ok=True)
    # O_EXCL | O_NOFOLLOW: never overwrite, never follow a symlink planted at the target.
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(OPTOUT_CONTENT, fh)
        fh.write("\n")
    print(f"  + {raw}: wrote {OPTOUT_FILE} {json.dumps(OPTOUT_CONTENT)}")
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("declaration")
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    decl = json.load(open(args.declaration, encoding="utf-8"))
    if decl.get("file") != OPTOUT_FILE or decl.get("content") != OPTOUT_CONTENT:
        print(f"  ! declaration must name {OPTOUT_FILE} with {json.dumps(OPTOUT_CONTENT)}; nothing applied")
        return 2
    missing = 0
    for raw in decl["repos"]:
        try:
            if not apply_one(raw, args.home, args.check):
                missing += 1
        except OSError as exc:
            print(f"  ! {raw}: {exc.__class__.__name__}: {exc}; skipped")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
