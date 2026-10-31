#!/usr/bin/env bash
# register-secret-verified.sh — check a secret value with its provider, then store it as a GitHub secret.
# There is no path that stores a value without a passing check.
#
# usage:
#   register-secret-verified.sh <SECRET_NAME> <owner/repo> --verify-url <https URL> [--verify-url …]
#       [--cloudflare-account <account id>] [--allow-host <host>] [--expect <json.path>=<value>]
#       [--auth '<header line with %s>'] [--env <environment>] [--dry-run]
#
#   - The value comes from a hidden prompt (or stdin when stdin is not a terminal). Python reads it straight into a 0600
#     file, so it is never an argument, a shell variable or a `set -x` line. Leading and trailing whitespace is dropped
#     (a pasted value often ends in a newline); a value with a newline inside (a PEM key) is refused when it comes on
#     stdin, while the hidden prompt reads one line only. Nothing else is assumed about its length or characters.
#   - Verify URLs must be https and their host must be allowed: api.cloudflare.com by default, others only with
#     --allow-host (recorded in the ledger), because the value is sent to that host. The hosts are printed before the
#     value is read. curl gets the header from a 0600 file (`-H @file`), ignores ~/.curlrc (-q), speaks https only and
#     does not follow redirects. --cloudflare-account <id> adds Cloudflare's two verify endpoints (user tokens, and that
#     account's tokens: account tokens answer only the second). Get the id with `wrangler whoami`.
#   - The value is stored only when a URL answers JSON whose --expect path has the expected value (default
#     result.status=active). A refusal prints curl's exit code, the observed value at that path and the provider's
#     error codes, never the body.
#   - `gh secret set` reads the value from stdin; then updatedAt is read back and must be fresh.
#   - Exit codes: 0 stored (or verified with --dry-run), 1 refused (empty, multi-line or not verified), 2 usage,
#     3 gh secret set failed, 4 stored but the readback is missing or stale. Every outcome is a guard-ledger row with the
#     name and the repository, never the value, except a usage error (2) other than a refused verify host.
#   - The script runs from / once its ledger library is found, so no file in the caller's directory (a json.py) is
#     imported by any Python it starts while the value is on disk (claude-code-skills#473 review round 2).
#
# Origin (2026-10-31 22:4x–23:35, orchestrator incident note): registering cor-os' CLOUDFLARE_ACCESS_READ_API_TOKEN took
# 5 attempts and about 50 minutes. Invalid values reached the GitHub secret twice (6111 Invalid format, 400
# Authentication failed), and two release runs failed at authentication. The steps left the order to the person
# (copying the token, then pasting a command, overwrote the clipboard). Their one-liner also ran `gh secret set` even
# when the verify call did not say active. The orchestrator's ~/Developer/bin/cf-register-access-read-token.sh fixed
# it; this is that script made general, with the review of claude-code-skills#473.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077

die() { printf 'register-secret-verified: %s\n' "$*" >&2; exit 2; }

NAME="${1:-}"; REPO="${2:-}"
[[ -n "$NAME" && -n "$REPO" && "$NAME" != -* && "$REPO" == */* ]] || die "usage: $0 <SECRET_NAME> <owner/repo> --verify-url <URL> …"
shift 2
URLS=() HOSTS=(api.cloudflare.com) EXTRA_HOSTS="" EXPECT="result.status=active" AUTH="Authorization: Bearer %s"
ENVNAME="" DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-url) [[ $# -ge 2 ]] || die "--verify-url needs a URL"; URLS+=("$2"); shift 2 ;;
        --cloudflare-account)
            [[ $# -ge 2 && "$2" =~ ^[0-9a-f]{32}$ ]] || die "--cloudflare-account needs a 32-hex account id (wrangler whoami)"
            URLS+=("https://api.cloudflare.com/client/v4/user/tokens/verify"
                   "https://api.cloudflare.com/client/v4/accounts/$2/tokens/verify")
            shift 2 ;;
        --allow-host) [[ $# -ge 2 && "$2" =~ ^[A-Za-z0-9.-]+$ ]] || die "--allow-host needs a host name"
            HOSTS+=("$2"); EXTRA_HOSTS="$EXTRA_HOSTS $2"; shift 2 ;;
        --expect) [[ $# -ge 2 && "$2" == *=* ]] || die "--expect needs <json.path>=<value>"; EXPECT="$2"; shift 2 ;;
        --auth) [[ $# -ge 2 && "$2" == *%s* ]] || die "--auth needs a header line containing %s"; AUTH="$2"; shift 2 ;;
        --env) [[ $# -ge 2 ]] || die "--env needs an environment name"; ENVNAME="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hooks/lib/aidd-ledger.sh"
[[ -f "$_LEDGER_LIB" ]] || _LEDGER_LIB="$HOME/.claude/hooks/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[[ -f "$_LEDGER_LIB" ]] && . "$_LEDGER_LIB"
ledger() {  # <decision> <rule>
    declare -F aidd_ledger_append_record >/dev/null 2>&1 || return 0
    local row
    row="$(python3 -I -c 'import json,sys
d, rule, name, repo, env, hosts = sys.argv[1:7]
print(json.dumps({"component": "secret-register", "hook": "register-secret-verified",
                  "event": "block" if d == "deny" else "measure", "decision": d, "rule": rule,
                  "cmd_head": "register-secret-verified %s %s%s%s" % (
                      name, repo, " --env " + env if env else "", " --allow-host" + hosts if hosts else "")},
                 separators=(",", ":")))' "$1" "$2" "$NAME" "$REPO" "$ENVNAME" "$EXTRA_HOSTS")" || return 0
    aidd_ledger_append_record "$row" "${AIDD_LEDGER_AGENT:-claude-code}" >/dev/null 2>&1 || true
}
cd /  # see the header: nothing in the caller's directory is imported

[[ ${#URLS[@]} -gt 0 ]] || die "no --verify-url / --cloudflare-account: a value is never stored without a check"
for url in "${URLS[@]}"; do
    host="$(python3 -I -c 'import sys, urllib.parse
try:
    u = urllib.parse.urlsplit(sys.argv[1])
    print(u.hostname or "" if u.scheme == "https" and not u.username and not u.password else "")
except ValueError:
    print("")' "$url")"
    [[ -n "$host" ]] || die "verify URL must be https with a host and no credentials: $url"
    allowed=0
    for h in "${HOSTS[@]}"; do [[ "$host" == "$h" ]] && allowed=1; done
    [[ $allowed == 1 ]] || { ledger deny secret-host-not-allowed; die "verify host $host is not allowed (default api.cloudflare.com; add --allow-host $host if you trust it — the value is sent there)"; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/register-secret.XXXXXX")"
cleanup() { rm -P -f "$WORK"/* 2>/dev/null || rm -f "$WORK"/*; rm -rf "$WORK"; }
trap cleanup EXIT

printf 'The value of %s will be sent to: %s\n' "$NAME" "$(printf '%s\n' "${URLS[@]}" | python3 -I -c 'import sys, urllib.parse
print(", ".join(sorted({urllib.parse.urlsplit(u.strip()).hostname for u in sys.stdin if u.strip()})))')" >&2
reason="$(python3 -I -c 'import getpass, sys
name, path = sys.argv[1], sys.argv[2]
v = getpass.getpass("Paste the value of %s and press Enter (input is not shown): " % name) if sys.stdin.isatty() else sys.stdin.read()
v = v.strip()
if not v:
    print("empty")
elif "\n" in v or "\r" in v:
    print("multi-line")
else:
    open(path, "w").write(v)
    print("ok")' "$NAME" "$WORK/value")"
if [[ "$reason" != ok ]]; then
    ledger deny "secret-$reason"
    printf 'NG: the value is %s; nothing was stored.\n' "$reason" >&2
    exit 1
fi
python3 -I -c 'import sys
v = open(sys.argv[1]).read()
open(sys.argv[3], "w").write(sys.argv[2].replace("%s", v) + "\n")' "$WORK/value" "$AUTH" "$WORK/header"

ok="" seen=""
for url in "${URLS[@]}"; do
    rc=0
    curl -q -sS --proto =https --proto-redir =https --max-time 20 -H @"$WORK/header" -o "$WORK/answer" -- "$url" \
        2>/dev/null || rc=$?
    verdict="$(python3 -I -c 'import json,sys
path, want = sys.argv[2].split("=", 1)
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("no JSON"); sys.exit(1)
v = doc
try:
    for k in path.split("."):
        v = v[int(k)] if isinstance(v, list) else v[k]
except Exception:
    v = None
codes = [str(e.get("code")) for e in (doc.get("errors") or []) if isinstance(e, dict)] if isinstance(doc, dict) else []
ok = v is not None and str(v).lower() == want.lower()
shown = "<%s>" % type(v).__name__ if isinstance(v, (dict, list)) else json.dumps(v)[:60]
print("%s=%s%s" % (path, shown, " errors=" + ",".join(codes[:5]) if codes else ""))
sys.exit(0 if ok else 1)' "$WORK/answer" "$EXPECT" 2>/dev/null)" && { ok="$url"; break; }
    seen="$seen
  $url: curl rc=$rc, ${verdict:-no answer}"
    rm -f "$WORK/answer"
done
if [[ -z "$ok" ]]; then
    ledger deny secret-unverified
    printf 'NG: no verify URL answered %s; nothing was stored. Observed:%s\n' "$EXPECT" "$seen" >&2
    exit 1
fi
printf 'VERIFIED: %s by %s\n' "$EXPECT" "$ok"
if [[ "$DRY" == 1 ]]; then
    ledger allow secret-dry-run-verified
    printf 'DRY RUN: %s was not stored.\n' "$NAME"
    exit 0
fi

ENVARGS=()
[[ -n "$ENVNAME" ]] && ENVARGS=(--env "$ENVNAME")
if ! gh secret set "$NAME" --repo "$REPO" ${ENVARGS[@]+"${ENVARGS[@]}"} <"$WORK/value"; then
    ledger deny secret-set-failed
    printf 'NG: gh secret set failed for %s in %s (the value was verified but not stored).\n' "$NAME" "$REPO" >&2
    exit 3
fi
updated="$(gh secret list --repo "$REPO" ${ENVARGS[@]+"${ENVARGS[@]}"} --json name,updatedAt 2>/dev/null | python3 -I -c 'import json,sys
from datetime import datetime, timezone
for s in json.load(sys.stdin):
    if s.get("name") == sys.argv[1]:
        t = datetime.fromisoformat(s["updatedAt"].replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - t).total_seconds()
        print(("fresh " if age < 300 else "stale ") + s["updatedAt"])
' "$NAME" 2>/dev/null || true)"
if [[ "$updated" != fresh* ]]; then
    ledger warn secret-readback-stale
    printf 'NG: %s was sent to gh, but the readback is %s; check `gh secret list --repo %s`.\n' "$NAME" "${updated:-missing}" "$REPO" >&2
    exit 4
fi
ledger allow secret-registered
printf 'REGISTERED: %s in %s%s, updatedAt %s\n' "$NAME" "$REPO" "${ENVNAME:+ (environment $ENVNAME)}" "${updated#fresh }"
