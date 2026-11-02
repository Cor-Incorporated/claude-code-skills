#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/lib/access_service_token.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B -I "$ROOT/tests/test-access-service-token.py"
python3 -B -I "$ROOT/tests/test-access-service-runner.py"

# The CI entry includes its own mutant fixture and invokes it (pair18).
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
MUTANT="$SB/tests/test-access-service-token.py"
run_mutant() { python3 -B -I "$@"; }
for CASE in control old-expiry token-scope retired-origin declaration recovery-declaration retired-declaration readback-returncode; do
  MUTANT="$SB/tests/test-access-service-token.py"
  python3 - "$ROOT" "$MUTANT" "$CASE" <<'PY'
from pathlib import Path
import shutil, sys
root, driver, case = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
lib = driver.parent.parent / "scripts/lib"
lib.mkdir(parents=True, exist_ok=True)
driver.parent.mkdir(exist_ok=True)
shutil.copy2(root / "tests/test-access-service-token.py", driver)
source = (root / "scripts/lib/access_service_token.py").read_text()
if case == "control":
    old, new = 'if status != 403:\n                fail("control"', 'if False:\n                fail("control"'
elif case == "old-expiry":
    old, new = 'payload={"previous_client_secret_expires_at": before["expires_at"]}', 'payload={}'
elif case == "token-scope":
    old, new = '    policy_fleet(rec, apps, api, fail)', '    pass  # missing policy-use inspection'
elif case == "retired-origin":
    old, new = '    if retired_matches:', '    if False:  # retired-origin check removed'
else:
    import json
    shutil.copy2(root / "tests/test-access-service-runner.py", driver.parent / "test-access-service-runner.py")
    shutil.copy2(root / "scripts/lib/secret_recipes.py", lib / "secret_recipes.py")
    shutil.copy2(root / "scripts/lib/slack_oauth_code.py", lib / "slack_oauth_code.py")
    docs = driver.parent.parent / "docs/runbooks"
    docs.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "docs/runbooks/access-service-token-registration.md", docs)
    book = json.loads((root / "scripts/lib/secret-verify-recipes.json").read_text())
    if case == "readback-returncode":
        runner = lib / "secret_recipes.py"
        text = runner.read_text()
        check = '    if listing.returncode != 0:\n        raise Refused(4, "readback-failed", "NG: sent to gh, but GitHub metadata readback failed (rc=%d); "\n                      "registration is unconfirmed." % listing.returncode)\n'
        assert text.count(check) == 1, "readback mutation target must be unique"
        runner.write_text(text.replace(check, ""))
    elif case == "retired-declaration":
        book["recipes"]["access-service-token-recovery"]["retired_origins"] = []
    else:
        name = "access-service-token-recovery" if case == "recovery-declaration" else "access-service-token"
        book["recipes"][name]["origins"][0] = "unreviewed.example.com"
    (lib / "secret-verify-recipes.json").write_text(json.dumps(book))
if case not in ("declaration", "recovery-declaration", "retired-declaration", "readback-returncode"):
    assert source.count(old) == 1, "mutation target must be unique"
    source = source.replace(old, new)
(lib / "access_service_token.py").write_text(source)
PY
  if [[ "$CASE" == control ]]; then
    TARGET=VerifyTests.test_wrong_secret_success_is_refused_before_any_real_probe
  elif [[ "$CASE" == old-expiry ]]; then
    TARGET=VerifyTests.test_success_preserves_old_expiry_and_recovery_until_storage
  elif [[ "$CASE" == token-scope ]]; then
    TARGET=VerifyTests.test_service_token_on_another_app_distinct_policy_blocks_before_rotation
  elif [[ "$CASE" == retired-origin ]]; then
    TARGET=VerifyTests.test_retired_origin_in_any_public_app_field_blocks_before_rotation
  elif [[ "$CASE" == readback-returncode ]]; then
    MUTANT="$SB/tests/test-access-service-runner.py"
    TARGET=RunnerBoundaryTests.test_failed_github_readback_with_fresh_stdout_keeps_recovery
  else
    MUTANT="$SB/tests/test-access-service-runner.py"
    TARGET=RunnerBoundaryTests.test_recipe_declaration_and_runbook_match_the_provider_contract_fixture
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
