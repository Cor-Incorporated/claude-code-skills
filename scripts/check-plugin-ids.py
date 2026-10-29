#!/usr/bin/env python3
"""Compare settings.json enabledPlugins with the installed plugin ids.

Usage: check-plugin-ids.py <settings.json> <installed_plugins.json>

Exit 1 (refuse) only for a rename: an enabled id is not installed while an id
from the same marketplace is. Copying that settings.json would switch the
installed plugin off (2026-10-30: claude-code-harness@… vs harness@… would
have removed RUNTIME_FLOOR and R01–R13). An enabled plugin that is simply
not installed on this machine, or an unreadable installed_plugins.json, only
warns: neither is made worse by the copy.

Used by setup.sh and tests/test-runtime-floor-allowlist.sh (L4).
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: check-plugin-ids.py <settings.json> <installed_plugins.json>",
            file=sys.stderr,
        )
        return 2
    try:
        enabled = [
            k
            for k, v in json.load(open(argv[1])).get("enabledPlugins", {}).items()
            if v
        ]
    except (OSError, ValueError, AttributeError) as exc:
        print(f"plugin-ids: cannot read {argv[1]}: {exc}")
        return 1
    try:
        plugins = json.load(open(argv[2])).get("plugins", {})
        installed = set(plugins) if isinstance(plugins, dict) else set()
    except (OSError, ValueError, AttributeError) as exc:
        print(f"plugin-ids: warning: cannot read {argv[2]} ({exc}); skipped")
        return 0
    renamed, absent = [], []
    for pid in enabled:
        if pid in installed:
            continue
        name, _, market = pid.partition("@")
        # A rename keeps the marketplace and one name contains the other
        # (claude-code-harness → harness). Any other installed plugin from the
        # same marketplace is unrelated, not a rename.
        near = sorted(
            i
            for i in installed
            if i not in enabled
            and i.partition("@")[2] == market
            and (i.partition("@")[0] in name or name in i.partition("@")[0])
        )
        (renamed if near else absent).append((pid, near))
    for pid, _ in absent:
        print(
            f"plugin-ids: warning: {pid} is enabled in settings.json but not installed here"
        )
    if renamed:
        for pid, near in renamed:
            print(
                f"plugin-ids: {pid} is enabled in settings.json but not installed; "
                f"installed from the same marketplace: {near}"
            )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
