#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/lib/slack_oauth_code.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B -I "$ROOT/tests/test_slack_oauth_code.py"
