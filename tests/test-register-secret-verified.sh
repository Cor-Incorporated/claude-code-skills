#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/register-secret-verified.sh
# A secret is stored only after its provider says it is valid, the value never appears in argv, a shell variable or on
# disk after the run, and it is sent only to an allowed https host (2026-10-31: cor-os' CLOUDFLARE_ACCESS_READ_API_TOKEN
# took 5 attempts; invalid values were stored twice; claude-code-skills#473 review).
#
# A fake `curl` answers Cloudflare's /tokens/verify (active only for the right value, read from the -H @file header;
# FAKE_ACCOUNT_ONLY=1 answers active only on the account endpoint) and a fake `gh` records `secret set` (value from
# stdin) and answers `secret list` (FAKE_GH_SET_FAIL / FAKE_GH_OLD change that). Nothing reaches the network.
# The mutant without the verify gate stores a wrong value: that is the red side.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/register-secret-verified.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home" TMPDIR="$SB/tmp" AIDD_LEDGER_SOURCE=test AIDD_LEDGER_PATH="$SB/ledger.jsonl"
mkdir -p "$HOME/.claude/hooks/lib" "$TMPDIR" "$SB/bin"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HOME/.claude/hooks/lib/"
GOOD="cfut_GOODvalue0123456789abcdefghijklmnopqrstuv"
ACC="0123456789abcdef0123456789abcdef"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

cat >"$SB/bin/curl" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SB/curl-argv"
hdr="" url="" out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -H) case "\$2" in @*) hdr="\$(cat "\${2#@}")" ;; *) hdr="\$2" ;; esac; shift 2 ;;
        -o) out="\$2"; shift 2 ;;
        --max-time|--proto|--proto-redir) shift 2 ;;
        --) shift; url="\$1"; shift ;;
        -*) shift ;;
        *) url="\$1"; shift ;;
    esac
done
printf '%s\n' "\$url" >>"$SB/curl-urls"
if [ "\$hdr" = "Authorization: Bearer $GOOD" ] && { [ -z "\${FAKE_ACCOUNT_ONLY:-}" ] || [ "\${url#*accounts/}" != "\$url" ]; }; then
    body='{"result":{"id":"x","status":"active"},"success":true}'
else
    body='{"success":false,"errors":[{"code":6111,"message":"Invalid format for Authorization header"}]}'
fi
if [ -n "\$out" ]; then printf '%s\n' "\$body" >"\$out"; else printf '%s\n' "\$body"; fi
FAKE
cat >"$SB/bin/gh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SB/gh-argv"
if [ "\$1 \$2" = "secret set" ]; then
    [ -n "\${FAKE_GH_SET_FAIL:-}" ] && exit 1
    cat >"$SB/gh-set-\$3"
elif [ "\$1 \$2" = "secret list" ]; then
    now="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"; [ -n "\${FAKE_GH_OLD:-}" ] && now=2020-01-01T00:00:00Z
    for f in "$SB"/gh-set-*; do [ -f "\$f" ] && printf '[{"name":"%s","updatedAt":"%s"}]\n' "\${f##*/gh-set-}" "\$now"; done | head -1
fi
FAKE
chmod +x "$SB/bin/curl" "$SB/bin/gh"
export PATH="$SB/bin:$PATH"
reset() { rm -f "$SB"/gh-set-* "$SB/gh-argv" "$SB/curl-argv" "$SB/curl-urls"; }
run() { bash "$SCRIPT" "$@" 2>&1; }

# 1 the right value, pasted with a trailing newline, is stored without it
reset
out="$(printf '%s\n' "$GOOD" | run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 0 && "$(cat "$SB/gh-set-CF_TOKEN" 2>/dev/null)" == "$GOOD" && "$out" == *"REGISTERED: CF_TOKEN in o/r"* \
   && "$out" == *"will be sent to: api.cloudflare.com"* ]] \
  && ok "a verified value is stored without the pasted newline, after naming the destination host" || bad "store" "rc=$rc $out"
if ! grep -qF "$GOOD" "$SB/curl-argv" "$SB/gh-argv" 2>/dev/null; then ok "the value is in no argv (curl reads a header file, gh reads stdin)"
else bad "argv" "the value appeared in an argv"; fi
[[ -z "$(ls -A "$TMPDIR")" ]] && ok "no temporary file is left after a success" || bad "temp" "$(ls -A "$TMPDIR")"
grep -q -- '-q -sS --proto =https --proto-redir =https' "$SB/curl-argv" && grep -q -- '-- https://' "$SB/curl-argv" \
  && ok "curl ignores ~/.curlrc, speaks https only, and takes the URL after --" || bad "curl options" "$(head -1 "$SB/curl-argv")"

# 2 an account token answers only the account endpoint: the fallback stores it
reset
out="$(printf '%s' "$GOOD" | FAKE_ACCOUNT_ONLY=1 run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 0 && "$(wc -l <"$SB/curl-urls")" -eq 2 && "$(tail -1 "$SB/curl-urls")" == *"accounts/$ACC/tokens/verify" ]] \
  && ok "an account token is verified on the account endpoint after the user endpoint refuses" || bad "account fallback" "rc=$rc $(cat "$SB/curl-urls")"

# 3 a wrong value is never stored: gh is not called, and the refusal shows what was observed
reset
out="$(printf 'cfut_wrong\n' | run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 1 && ! -f "$SB/gh-set-CF_TOKEN" && ! -s "$SB/gh-argv" && "$out" == *"result.status=null errors=6111"* ]] \
  && ok "an unverified value is refused (rc=1), gh is never called, and the observed status and code are printed" \
  || bad "refuse" "rc=$rc $out"
grep -q '"rule":"secret-unverified"' "$SB/ledger.jsonl" 2>/dev/null && ! grep -qF cfut_wrong "$SB/ledger.jsonl" \
  && ok "the refusal is a ledger row without the value" || bad "ledger deny" "$(tail -1 "$SB/ledger.jsonl" 2>/dev/null)"
[[ -z "$(ls -A "$TMPDIR")" ]] && ok "no temporary file is left after a refusal" || bad "temp after refusal" "$(ls -A "$TMPDIR")"

# 4 the destination: https only, allowed hosts only, no credentials in the URL
reset
for bad_url in "http://api.cloudflare.com/client/v4/user/tokens/verify" "file:///tmp/ok.json" "https://evil.example/verify" \
               "-K/tmp/cfg" "https://user:pw@api.cloudflare.com/x"; do
  out="$(printf '%s' "$GOOD" | run CF_TOKEN o/r --verify-url "$bad_url")"; rc=$?
  [[ $rc -eq 2 && ! -s "$SB/curl-argv" && ! -s "$SB/gh-argv" ]] || bad "destination $bad_url" "rc=$rc $out"
done
[[ ! -s "$SB/curl-argv" ]] && ok "http, file:, an unlisted host, a curl option and a URL with credentials are refused before any call"
grep -q '"rule":"secret-host-not-allowed"' "$SB/ledger.jsonl" && ok "a refused verify host is a ledger row" \
  || bad "host ledger" "no secret-host-not-allowed row"
out="$(printf '%s' "$GOOD" | run CF_TOKEN o/r --verify-url 'https://[::1/')"; rc=$?
[[ $rc -eq 2 && "$out" != *Traceback* ]] && ok "a malformed URL is a usage error (rc=2), not a traceback" || bad "malformed url" "rc=$rc $out"
out="$(printf '%s' "$GOOD" | run CF_TOKEN o/r --verify-url "https://verify.example.org/v" --allow-host verify.example.org)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SB/curl-urls" 2>/dev/null)" == "https://verify.example.org/v" ]] \
  && grep -q 'allow-host verify.example.org' "$SB/ledger.jsonl" \
  && ok "--allow-host admits a host and the ledger row records it" || bad "allow-host" "rc=$rc $out $(tail -1 "$SB/ledger.jsonl")"

# 5 no verify URL; empty; multi-line
reset
out="$(printf '%s' "$GOOD" | run CF_TOKEN o/r)"; rc=$?
[[ $rc -eq 2 && ! -s "$SB/gh-argv" ]] && ok "without --verify-url the script refuses (rc=2)" || bad "no verify" "rc=$rc $out"
out="$(printf '\n' | run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 1 && "$out" == *"is empty"* && ! -s "$SB/gh-argv" ]] && ok "an empty value is refused" || bad "empty" "rc=$rc $out"
# the destination is named before the value is read: on a refusal of the read itself the host line is already out
host_line="$(printf '%s\n' "$out" | grep -n 'will be sent to: api.cloudflare.com' | cut -d: -f1)"
ng_line="$(printf '%s\n' "$out" | grep -n 'NG: the value is empty' | cut -d: -f1)"
[[ -n "$host_line" && -n "$ng_line" && "$host_line" -lt "$ng_line" ]] && ok "the destination host is printed before the value is read" \
  || bad "host first" "host line ${host_line:-none}, read result line ${ng_line:-none}"
out="$(printf 'abc\rdef' | run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 1 && "$out" == *"multi-line"* && ! -s "$SB/curl-argv" ]] && ok "a carriage return inside the value is refused like a newline" || bad "cr" "rc=$rc $out"
out="$(printf -- '-----BEGIN KEY-----\nabc\n-----END KEY-----\n' | run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 1 && "$out" == *"multi-line"* && ! -s "$SB/curl-argv" ]] && ok "a multi-line value is refused before any call" || bad "multi-line" "rc=$rc $out"

# 6 dry run; gh failure; stale readback; --env
reset
out="$(printf '%s' "$GOOD" | run CF_TOKEN o/r --cloudflare-account "$ACC" --dry-run)"; rc=$?
[[ $rc -eq 0 && "$out" == *"DRY RUN"* && ! -s "$SB/gh-argv" ]] && grep -q '"rule":"secret-dry-run-verified"' "$SB/ledger.jsonl" \
  && ok "--dry-run verifies, stores nothing, and is a ledger row" || bad "dry run" "rc=$rc $out"
out="$(printf '%s' "$GOOD" | FAKE_GH_SET_FAIL=1 run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 3 && "$out" == *"gh secret set failed"* ]] && grep -q '"rule":"secret-set-failed"' "$SB/ledger.jsonl" \
  && ok "a failing gh secret set is rc=3 with its own ledger row" || bad "gh failure" "rc=$rc $out"
reset
out="$(printf '%s' "$GOOD" | FAKE_GH_OLD=1 run CF_TOKEN o/r --cloudflare-account "$ACC")"; rc=$?
[[ $rc -eq 4 && "$out" == *"readback is stale"* ]] && grep '"rule":"secret-readback-stale"' "$SB/ledger.jsonl" | grep -q '"decision":"warn"' \
  && ok "a stale readback is rc=4, not success, and a warn row (the value was stored, not blocked)" || bad "stale readback" "rc=$rc $out"
reset
out="$(printf '%s' "$GOOD" | run CF_TOKEN o/r --cloudflare-account "$ACC" --env production)"; rc=$?
[[ $rc -eq 0 && "$(grep -c -- '--env production' "$SB/gh-argv")" -eq 2 ]] && ok "--env reaches both secret set and secret list" \
  || bad "env" "rc=$rc $(cat "$SB/gh-argv")"
grep -q '"rule":"secret-registered"' "$SB/ledger.jsonl" && ! grep -qF "$GOOD" "$SB/ledger.jsonl" \
  && ok "a registration is a ledger row without the value" || bad "ledger allow" "$(grep secret-registered "$SB/ledger.jsonl")"

# 7 set -x does not print the value (it is never a shell variable)
reset
out="$(printf '%s' "$GOOD" | bash -x "$SCRIPT" CF_TOKEN o/r --cloudflare-account "$ACC" --dry-run 2>&1)"
[[ "$out" != *"$GOOD"* ]] && ok "bash -x shows no value" || bad "xtrace" "the value appeared under bash -x"

# 8 a json.py in the caller's directory is never imported while the value is on disk (review round 2 M1: the ledger
#   library's `python3 -` put the cwd on sys.path)
reset
mkdir -p "$SB/cwd"
cat >"$SB/cwd/json.py" <<PYMOD
import glob, os
open("$SB/imported", "a").write("imported, value files on disk: %d\\n" % len(glob.glob(os.environ.get("TMPDIR", "/tmp") + "/register-secret.*/value")))
import sys
del sys.modules["json"]
sys.path = [p for p in sys.path if p not in ("", os.getcwd())]
import json as _real
sys.modules["json"] = _real
PYMOD
(cd "$SB/cwd" && printf '%s' "$GOOD" | bash "$SCRIPT" CF_TOKEN o/r --cloudflare-account "$ACC" >/dev/null 2>&1)
(cd "$SB/cwd" && printf 'cfut_wrong' | bash "$SCRIPT" CF_TOKEN o/r --cloudflare-account "$ACC" >/dev/null 2>&1)
[[ ! -e "$SB/imported" ]] && ok "no Python the script starts imports a json.py from the caller's directory (success and refusal)" \
  || bad "cwd import" "$(cat "$SB/imported")"
rm -rf "$SB/cwd" "$SB/imported"

# Mutant: the verify gate removed → a wrong value is stored. The real script refuses it (case 3).
MUT="$SB/register-mutant.sh"
python3 - "$SCRIPT" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = 'if [[ -z "$ok" ]]; then'
if needle not in text:
    raise SystemExit("mutation target not found")
pathlib.Path(dst).write_text(text.replace(needle, "if false; then", 1))
PY
if [[ -f "$MUT" ]]; then
  reset
  printf 'cfut_wrong\n' | bash "$MUT" CF_TOKEN o/r --cloudflare-account "$ACC" >/dev/null 2>&1
  [[ "$(cat "$SB/gh-set-CF_TOKEN" 2>/dev/null)" == cfut_wrong ]] \
    && ok "mutant (no verify gate) stores the wrong value; the real script refuses it" \
    || bad "mutant" "the mutant did not store the wrong value — the test does not prove the gate"
else
  bad "mutant" "could not build the mutant"
fi

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
