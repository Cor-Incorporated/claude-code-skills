#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/register-secret-verified.sh
# A secret is stored only after its provider says it is valid, and the value never appears in argv or on disk after
# the run (2026-10-31: cor-os' CLOUDFLARE_ACCESS_READ_API_TOKEN took 5 attempts; invalid values were stored twice).
#
# A fake `curl` answers Cloudflare's /tokens/verify (active only for the right value, read from the -H @file header)
# and a fake `gh` records `secret set` (value from stdin) and answers `secret list`. Nothing reaches the network.
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
hdr="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -H) case "\$2" in @*) hdr="\$(cat "\${2#@}")" ;; *) hdr="\$2" ;; esac; shift 2 ;;
        --max-time) shift 2 ;;
        -*) shift ;;
        *) url="\$1"; shift ;;
    esac
done
printf '%s\n' "\$url" >>"$SB/curl-urls"
if [ "\$hdr" = "Authorization: Bearer $GOOD" ]; then
    echo '{"result":{"id":"x","status":"active"},"success":true}'
else
    echo '{"success":false,"errors":[{"code":6111,"message":"Invalid format for Authorization header"}]}'
fi
FAKE
cat >"$SB/bin/gh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SB/gh-argv"
if [ "\$1 \$2" = "secret set" ]; then
    cat >"$SB/gh-set-\$3"
elif [ "\$1 \$2" = "secret list" ]; then
    now="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for f in "$SB"/gh-set-*; do [ -f "\$f" ] && printf '[{"name":"%s","updatedAt":"%s"}]\n' "\${f##*/gh-set-}" "\$now"; done | head -1
fi
FAKE
chmod +x "$SB/bin/curl" "$SB/bin/gh"
export PATH="$SB/bin:$PATH"
reset() { rm -f "$SB"/gh-set-* "$SB/gh-argv" "$SB/curl-argv" "$SB/curl-urls"; }

# 1 the right value, pasted with a trailing newline, is stored without it
reset
out="$(printf '%s\n' "$GOOD" | bash "$SCRIPT" CF_TOKEN o/r --cloudflare-account "$ACC" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SB/gh-set-CF_TOKEN" 2>/dev/null)" == "$GOOD" && "$out" == *"REGISTERED: CF_TOKEN in o/r"*"(fresh)"* ]] \
  && ok "a verified value is stored, the pasted newline dropped, and updatedAt read back" || bad "store" "rc=$rc $out"
grep -q "accounts/$ACC/tokens/verify\|user/tokens/verify" "$SB/curl-urls" && ok "--cloudflare-account calls the verify endpoints" \
  || bad "verify urls" "$(cat "$SB/curl-urls" 2>/dev/null)"
if ! grep -qF "$GOOD" "$SB/curl-argv" "$SB/gh-argv" 2>/dev/null; then ok "the value is in no argv (curl reads a header file, gh reads stdin)"
else bad "argv" "the value appeared in an argv"; fi
[[ -z "$(ls -A "$TMPDIR")" ]] && ok "no temporary file is left" || bad "temp" "$(ls -A "$TMPDIR")"

# 2 a wrong value is never stored: gh is not called at all
reset
out="$(printf 'cfut_wrong\n' | bash "$SCRIPT" CF_TOKEN o/r --cloudflare-account "$ACC" 2>&1)"; rc=$?
[[ $rc -eq 1 && ! -f "$SB/gh-set-CF_TOKEN" && ! -s "$SB/gh-argv" && "$out" == *"Nothing was stored"* ]] \
  && ok "an unverified value is refused (rc=1) and gh is never called" || bad "refuse" "rc=$rc $out $(cat "$SB/gh-argv" 2>/dev/null)"
grep -q '"rule":"secret-unverified"' "$SB/ledger.jsonl" 2>/dev/null && ! grep -qF cfut_wrong "$SB/ledger.jsonl" \
  && ok "the refusal is a ledger row without the value" || bad "ledger deny" "$(tail -1 "$SB/ledger.jsonl" 2>/dev/null)"

# 3 no verify URL: there is no unverified path
reset
out="$(printf '%s' "$GOOD" | bash "$SCRIPT" CF_TOKEN o/r 2>&1)"; rc=$?
[[ $rc -eq 2 && ! -s "$SB/gh-argv" ]] && ok "without --verify-url the script refuses (rc=2) before reading the value" \
  || bad "no verify" "rc=$rc $out"

# 4 an empty value
reset
out="$(printf '\n' | bash "$SCRIPT" CF_TOKEN o/r --cloudflare-account "$ACC" 2>&1)"; rc=$?
[[ $rc -eq 1 && ! -s "$SB/gh-argv" ]] && ok "an empty value is refused" || bad "empty" "rc=$rc $out"

# 5 dry run checks and stops
reset
out="$(printf '%s' "$GOOD" | bash "$SCRIPT" CF_TOKEN o/r --cloudflare-account "$ACC" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *VERIFIED* && "$out" == *"DRY RUN"* && ! -s "$SB/gh-argv" ]] \
  && ok "--dry-run verifies and stores nothing" || bad "dry run" "rc=$rc $out"

# 6 a registration is a ledger row too
grep -q '"rule":"secret-registered"' "$SB/ledger.jsonl" 2>/dev/null && ! grep -qF "$GOOD" "$SB/ledger.jsonl" \
  && ok "a registration is a ledger row without the value" || bad "ledger allow" "$(grep secret-registered "$SB/ledger.jsonl" 2>/dev/null)"

# Mutant: the verify gate removed → a wrong value is stored. The real script refuses it (case 2).
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
