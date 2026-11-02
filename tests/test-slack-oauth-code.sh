#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/lib/slack_oauth_code.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B -I "$ROOT/tests/test_slack_oauth_code.py"

# Keep the red side in this CI entry too (pair18): write the mutant fixture here,
# then execute that same fixture, rather than relying on an external/manual probe.
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
MUTANT="$SB/tests/test_slack_oauth_code.py"
run_mutant() { python3 -B -I "$@"; }
for CASE in control revoke; do
  python3 - "$ROOT" "$MUTANT" "$CASE" <<'PY'
from pathlib import Path
import shutil, sys
root, driver, case = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
lib = driver.parent.parent / "scripts/lib"
lib.mkdir(parents=True, exist_ok=True)
driver.parent.mkdir(exist_ok=True)
for name in ["secret_recipes.py", "secret-verify-recipes.json"]:
    shutil.copy2(root / "scripts/lib" / name, lib / name)
shutil.copy2(root / "tests/test_slack_oauth_code.py", driver)
source = (root / "scripts/lib/slack_oauth_code.py").read_text()
if case == "control":
    old = '''        if (status != 200 or not isinstance(control, dict) or set(control) != {"ok", "error"} or
                control.get("ok") is not False or control.get("error") != "bad_client_secret"):'''
    new = "        if False:"
else:
    old, new = 'answer.get("revoked") is not True', 'False'
assert source.count(old) == 1, "mutation target must be unique"
(lib / "slack_oauth_code.py").write_text(source.replace(old, new))
PY
  if [[ "$CASE" == control ]]; then
    TARGET=CodeFlowTests.test_indistinguishable_or_transient_controls_stop_before_real_pair
  else
    TARGET=CodeFlowTests.test_revocation_failure_retains_private_recovery_and_never_stores
  fi
  if run_mutant "$MUTANT" "$TARGET" >"$SB/$CASE.log" 2>&1; then
    echo "FAIL: $CASE mutant passed unexpectedly" >&2
    exit 1
  else
    rc=$?
    if [[ "$rc" != 1 ]] || ! grep -q 'FAIL:' "$SB/$CASE.log"; then
      cat "$SB/$CASE.log" >&2
      echo "FAIL: $CASE mutant did not reach the expected assertion" >&2
      exit 1
    fi
  fi
  echo "PASS: $CASE mutation reaches a failing assertion (exit 1)"
done
