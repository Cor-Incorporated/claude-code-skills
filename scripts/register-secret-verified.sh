#!/usr/bin/env bash
# register-secret-verified.sh — check a secret value with its provider, then store it as a GitHub secret.
# There is no path that stores a value without a passing check.
#
# usage:
#   register-secret-verified.sh <SECRET_NAME> <owner/repo> --verify-url <URL> [--verify-url <URL> …]
#       [--cloudflare-account <account id>] [--expect <json.path>=<value>] [--auth '<header line with %s>']
#       [--env <environment>] [--dry-run]
#
#   The value comes from a hidden prompt (or stdin when stdin is not a terminal), never from an argument, so it is
#   not in shell history or `ps`. Leading and trailing whitespace is dropped (a pasted value often ends in a newline);
#   nothing else is assumed about its length or characters.
#   Each --verify-url is called with the value in a header (`--auth`, default `Authorization: Bearer %s`) read from a
#   0600 file, not from argv. The value is stored only when one of them answers with JSON whose `--expect` path has
#   the expected value (default `result.status=active`, Cloudflare's /tokens/verify).
#   --cloudflare-account <id> adds both Cloudflare verify endpoints (user tokens and that account's tokens).
#   --dry-run checks and stops. After `gh secret set` (value on stdin) the secret's updatedAt is read back.
#   Every refusal and every registration leaves a guard-ledger row with the name and the repository, never the value.
#
# Origin (2026-10-31 22:4x–23:35, aidd-governance#230 follow-up, orchestrator incident note): registering cor-os'
# CLOUDFLARE_ACCESS_READ_API_TOKEN took 5 attempts and about 50 minutes. Invalid values reached the GitHub secret
# twice (6111 Invalid format, 400 Authentication failed) and two release runs failed at authentication. The steps
# handed over left the order to the person (copying the token, then pasting a command, overwrote the clipboard), and
# their one-liner ran `gh secret set` even when the verify call did not say active. The orchestrator's
# ~/Developer/bin/cf-register-access-read-token.sh fixed it; this is that script made general.
set -euo pipefail
umask 077

die() { printf 'register-secret-verified: %s\n' "$*" >&2; exit 2; }

NAME="${1:-}"; REPO="${2:-}"
[[ -n "$NAME" && -n "$REPO" && "$NAME" != -* && "$REPO" == */* ]] || die "usage: $0 <SECRET_NAME> <owner/repo> --verify-url <URL> …"
shift 2
URLS=() EXPECT="result.status=active" AUTH="Authorization: Bearer %s" ENVNAME="" DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-url) [[ $# -ge 2 ]] || die "--verify-url needs a URL"; URLS+=("$2"); shift 2 ;;
        --cloudflare-account)
            [[ $# -ge 2 && "$2" =~ ^[0-9a-f]{32}$ ]] || die "--cloudflare-account needs a 32-hex account id"
            URLS+=("https://api.cloudflare.com/client/v4/user/tokens/verify"
                   "https://api.cloudflare.com/client/v4/accounts/$2/tokens/verify")
            shift 2 ;;
        --expect) [[ $# -ge 2 && "$2" == *=* ]] || die "--expect needs <json.path>=<value>"; EXPECT="$2"; shift 2 ;;
        --auth) [[ $# -ge 2 && "$2" == *%s* ]] || die "--auth needs a header line containing %s"; AUTH="$2"; shift 2 ;;
        --env) [[ $# -ge 2 ]] || die "--env needs an environment name"; ENVNAME="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ ${#URLS[@]} -gt 0 ]] || die "no --verify-url / --cloudflare-account: a value is never stored without a check"

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hooks/lib/aidd-ledger.sh"
[[ -f "$_LEDGER_LIB" ]] || _LEDGER_LIB="$HOME/.claude/hooks/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[[ -f "$_LEDGER_LIB" ]] && . "$_LEDGER_LIB"
ledger() {  # <decision> <rule>
    declare -F aidd_ledger_append_record >/dev/null 2>&1 || return 0
    local row
    row="$(python3 -c 'import json,sys
d, rule, name, repo, env = sys.argv[1:6]
print(json.dumps({"component": "secret-register", "hook": "register-secret-verified",
                  "event": "measure" if d == "allow" else "block", "decision": d, "rule": rule,
                  "cmd_head": "register-secret-verified %s %s%s" % (name, repo, " --env " + env if env else "")},
                 separators=(",", ":")))' "$1" "$2" "$NAME" "$REPO" "$ENVNAME")" || return 0
    aidd_ledger_append_record "$row" "${AIDD_LEDGER_AGENT:-claude-code}" >/dev/null 2>&1 || true
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/register-secret.XXXXXX")"
cleanup() { rm -P -f "$WORK"/* 2>/dev/null || rm -f "$WORK"/*; rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -t 0 ]]; then
    printf 'Paste the value of %s and press Enter (input is not shown): ' "$NAME" >&2
    IFS= read -rs V || V=""
    echo >&2
else
    V="$(cat)"
fi
printf '%s' "$V" | python3 -c 'import sys
v = sys.stdin.read().strip()
open(sys.argv[1], "w").write(v)' "$WORK/value"
unset V
if [[ ! -s "$WORK/value" ]]; then
    ledger deny secret-empty
    printf 'NG: the value is empty; nothing was stored.\n' >&2
    exit 1
fi
python3 -c 'import sys
v = open(sys.argv[1]).read()
open(sys.argv[3], "w").write(sys.argv[2].replace("%s", v) + "\n")' "$WORK/value" "$AUTH" "$WORK/header"

ok=""
for url in "${URLS[@]}"; do
    if curl -sS --max-time 20 -H @"$WORK/header" "$url" >"$WORK/answer" 2>/dev/null \
        && python3 -c 'import json,sys
path, want = sys.argv[2].split("=", 1)
try:
    v = json.load(open(sys.argv[1]))
    for k in path.split("."):
        v = v[int(k)] if isinstance(v, list) else v[k]
except Exception:
    sys.exit(1)
sys.exit(0 if str(v).lower() == want.lower() else 1)' "$WORK/answer" "$EXPECT"; then
        ok="$url"
        break
    fi
done
if [[ -z "$ok" ]]; then
    ledger deny secret-unverified
    printf 'NG: no verify URL answered %s (wrong value, another account, or not active yet). Nothing was stored.\n' "$EXPECT" >&2
    exit 1
fi
printf 'VERIFIED: %s by %s\n' "$EXPECT" "$ok"
if [[ "$DRY" == 1 ]]; then
    printf 'DRY RUN: %s was not stored.\n' "$NAME"
    exit 0
fi

ENVARGS=()
[[ -n "$ENVNAME" ]] && ENVARGS=(--env "$ENVNAME")
gh secret set "$NAME" --repo "$REPO" ${ENVARGS[@]+"${ENVARGS[@]}"} <"$WORK/value"
updated="$(gh secret list --repo "$REPO" ${ENVARGS[@]+"${ENVARGS[@]}"} --json name,updatedAt 2>/dev/null | python3 -c 'import json,sys
from datetime import datetime, timezone
name = sys.argv[1]
for s in json.load(sys.stdin):
    if s.get("name") == name:
        t = datetime.fromisoformat(s["updatedAt"].replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - t).total_seconds()
        print(s["updatedAt"] + (" (fresh)" if age < 300 else " (OLD: %ds ago)" % age))
' "$NAME" 2>/dev/null || true)"
ledger allow secret-registered
printf 'REGISTERED: %s in %s%s, updatedAt %s\n' "$NAME" "$REPO" "${ENVNAME:+ (environment $ENVNAME)}" "${updated:-unknown}"
