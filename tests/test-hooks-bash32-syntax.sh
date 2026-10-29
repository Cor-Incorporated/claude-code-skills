#!/usr/bin/env bash
# Every deployed shell file must parse under /bin/bash, which is 3.2 on macOS.
#
# 起点 (2026-10-30 #445 re-review): an apostrophe inside a python heredoc
# inside $( ) parsed under Homebrew bash 5 but not under /bin/bash 3.2, so
# tool-failure-recovery.sh would have exited 2 on every Bash failure on a Mac
# whose hooks run with /bin/bash. The suites stayed green because `bash` on
# PATH was 5.x. `bash -n` in CI runs bash 5 too, so it cannot see this.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pass=0
fail=0
skip=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

if [[ ! -x /bin/bash ]]; then
  echo "SKIP: /bin/bash not present"
  echo "---"
  echo "pass=0 fail=0 skip=1"
  exit 0
fi
echo "INFO: $(/bin/bash --version | head -1)"

for f in "$ROOT"/hooks/*.sh "$ROOT"/hooks/lib/*.sh "$ROOT"/hooks/codex/*.sh "$ROOT"/hooks/cursor/*.sh "$ROOT"/setup.sh; do
  [[ -f "$f" ]] || continue
  if err="$(/bin/bash -n "$f" 2>&1)"; then
    ok "${f#"$ROOT"/}"
  else
    bad "${f#"$ROOT"/} does not parse under /bin/bash" "$err"
  fi
done

# The check itself must see the failure it exists for.
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
printf '%s\n' 'x="$(python3 - <<'"'"'PY'"'"'' "# it's here" 'PY' ')"' >"$probe"
if /bin/bash -n "$probe" >/dev/null 2>&1; then
  if /bin/bash --version | head -1 | grep -q 'version 3\.'; then
    bad "probe" "/bin/bash 3.x parsed the known-bad apostrophe probe"
  else
    ok "probe parses on bash >= 4 (the 3.2 hazard only exists on 3.x)"
  fi
else
  ok "probe: /bin/bash rejects an apostrophe in a heredoc inside \$( )"
fi

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[[ "$fail" -eq 0 ]]
