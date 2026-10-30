#!/usr/bin/env python3
"""Refuse a settings.json copy that would switch an installed plugin off by drift.

Usage: check-plugin-ids.py <repo settings.json> <installed_plugins.json> [<live settings.json>]

setup.sh copies the repo settings.json over the live one. Exit 1 (refuse) when
the repo enables an id that is not installed AND the copy would turn off a
plugin that is installed and enabled in the live file, from the same
marketplace or under the same plugin name. That is the drift of 2026-10-30:
the repo enabled claude-code-harness@…, the live file enabled the installed
harness@…; the copy would have removed RUNTIME_FLOOR and R01–R13.

Everything else only warns: an enabled plugin that is simply not installed
here, a live plugin the repo deliberately leaves off, an unreadable file, or
no live file yet (a fresh machine has nothing to turn off).

Used by setup.sh and tests/test-runtime-floor-allowlist.sh (L4).
"""

from __future__ import annotations

import json
import sys


def enabled_ids(path: str) -> list[str]:
    data = json.load(open(path)).get("enabledPlugins", {})
    return [k for k, v in data.items() if v] if isinstance(data, dict) else []


def split(pid: str) -> tuple[str, str]:
    name, _, market = pid.partition("@")
    return name, market


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    try:
        repo = enabled_ids(argv[1])
    except (OSError, ValueError, AttributeError) as exc:
        print(f"plugin-ids: cannot read {argv[1]}: {exc}")
        return 1
    try:
        plugins = json.load(open(argv[2])).get("plugins", {})
        installed = set(plugins) if isinstance(plugins, dict) else set()
    except (OSError, ValueError, AttributeError) as exc:
        print(f"plugin-ids: warning: cannot read {argv[2]} ({exc}); skipped")
        return 0
    live: list[str] = []
    if len(argv) == 4:
        try:
            live = enabled_ids(argv[3])
        except (OSError, ValueError, AttributeError) as exc:
            print(
                f"plugin-ids: warning: cannot read {argv[3]} ({exc}); no live comparison"
            )

    missing = [p for p in repo if p not in installed]
    turned_off = [p for p in live if p in installed and p not in repo]
    per_market: dict[str, int] = {}
    for p in installed:
        per_market[split(p)[1]] = per_market.get(split(p)[1], 0) + 1

    def related(off: str, name: str, market: str) -> bool:
        # Same plugin name anywhere is a marketplace rename. Same marketplace is
        # a rename only when that marketplace ships one plugin here; a catalog
        # such as claude-plugins-official holds unrelated plugins.
        o_name, o_market = split(off)
        return o_name == name or (
            o_market == market and per_market.get(o_market, 0) == 1
        )

    refused = False
    for pid in missing:
        name, market = split(pid)
        hit = sorted(p for p in turned_off if related(p, name, market))
        if hit:
            refused = True
            print(
                f"plugin-ids: settings.json enables {pid}, which is not installed, and the copy "
                f"would turn off the installed, live-enabled {hit}"
            )
        else:
            print(
                f"plugin-ids: warning: {pid} is enabled in settings.json but not installed here"
            )
    for pid in turned_off:
        if not any(related(pid, *split(m)) for m in missing):
            print(
                f"plugin-ids: warning: the copy turns off {pid} (enabled live, not in settings.json)"
            )
    return 1 if refused else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
