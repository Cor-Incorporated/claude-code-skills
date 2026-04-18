#!/usr/bin/env bash
# sync-opencode-background-permissions.sh
# Ensure OpenCode allows the safe shell commands background workers commonly use
# for syntax checks and repo-local script execution.

set -euo pipefail

CONFIG_FILE="${1:-$HOME/.config/opencode/opencode.jsonc}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: OpenCode config not found: $CONFIG_FILE" >&2
  exit 1
fi

python3 - "$CONFIG_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

rules = [
    '"bash -n *": "allow",',
    '"sh -n *": "allow",',
    '"bash *tests/*.sh*": "allow",',
    '"sh *tests/*.sh*": "allow",',
    '"bash *hooks/*.sh*": "allow",',
    '"sh *hooks/*.sh*": "allow",',
    '"bash *scripts/*.sh*": "allow",',
    '"sh *scripts/*.sh*": "allow",',
]

missing = [rule for rule in rules if rule not in text]
if not missing:
    print(f"OpenCode background-safe permissions already present: {path}")
    raise SystemExit(0)

anchor = '      // Linters/formatters\n'
if anchor not in text:
    raise SystemExit(f"anchor not found in {path}")

block = "      // Background-safe shell verification and repo-local scripts\n"
for rule in missing:
    block += f"      {rule}\n"

text = text.replace(anchor, block + anchor, 1)
path.write_text(text)
print(f"Updated OpenCode background-safe permissions: {path}")
PY
