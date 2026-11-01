#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/lib/secret_recipes.py
# register-secret-verified.sh --recipe (claude-code-skills#478): a value is stored only when its reviewed recipe passes.
# For an OAuth client pair, the provider must accept the pair, and a negative control (the same request with a wrong
# secret) must answer differently. A generated MCP_TOKEN is kept in the env ledger and read back equal before GitHub.
# PUBLISHING_INTAKE_KEYS_JSON comes from the consumer's own generator and check, and a missing command refuses.
#
# Fakes: curl (GitHub check-a-token and Slack oauth.v2.access, read from the -K config file), gh (secret set from stdin,
# secret list), security and bw (an unlocked vault in a file), node (a cor-os checkout). Nothing reaches the network.
# Red side: a mutant without the control check stores through an endpoint that answers 404 to everything, and a mutant
# that skips the consumer's check stores a value the check refuses.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/register-secret-verified.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home" TMPDIR="$SB/tmp" AIDD_LEDGER_SOURCE=test AIDD_LEDGER_PATH="$SB/ledger.jsonl" USER=tester
mkdir -p "$HOME" "$TMPDIR" "$SB/bin" "$SB/gh" "$SB/vault"
GID="Iv1.goodclientid0001" GSEC="goodsecret_0123456789abcdef0123456789abcdef"
SID="1234567890.0987654321" SSEC="slacksecret0123456789abcdef"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

cat >"$SB/bin/curl" <<FAKE
#!/usr/bin/env python3
import base64, json, os, re, sys
open("$SB/curl-argv", "a").write(" ".join(sys.argv[1:]) + "\n")
cfg = sys.argv[sys.argv.index("-K") + 1]
conf, headers = {}, []
for line in open(cfg):
    m = re.match(r'(\S+) = "((?:[^"\\\\]|\\\\.)*)"', line.strip())
    k, v = m.group(1), re.sub(r'\\\\(.)', r'\1', m.group(2))
    headers.append(v) if k == "header" else conf.__setitem__(k, v)
open("$SB/curl-urls", "a").write(conf["url"] + "\n")
auth = next((h[len("Authorization: Basic "):] for h in headers if h.startswith("Authorization: Basic ")), "")
user, _, pw = base64.b64decode(auth).decode().partition(":") if auth else ("", "", "")
status, body = 200, "{}"
if "/applications/" in conf["url"]:
    good = user == "$GID" and pw == "$GSEC" and conf["url"].endswith("/applications/$GID/token")
    status = 404 if good or os.environ.get("FAKE_NODISCRIM") else int(os.environ.get("FAKE_GH_BAD", "401"))
    body = '{"message":"Not Found"}' if status == 404 else '{"message":"Bad credentials"}'
elif "oauth.v2.access" in conf["url"]:
    if os.environ.get("FAKE_NODISCRIM"):
        err = "invalid_code"
    elif user != "$SID":
        err = "invalid_client_id"
    elif pw != "$SSEC":
        err = "bad_client_secret"
    else:
        err = "invalid_code"
    body = json.dumps({"ok": False, "error": err})
open(conf["output"], "w").write(body)
sys.stdout.write(str(status))
FAKE
cat >"$SB/bin/gh" <<FAKE
#!/usr/bin/env python3
import json, os, sys, datetime
a = sys.argv[1:]
open("$SB/gh-argv", "a").write(" ".join(a) + "\n")
if a[:2] == ["secret", "set"]:
    if os.environ.get("FAKE_GH_SET_FAIL"):
        sys.exit(1)
    open("$SB/gh/" + a[2], "w").write(sys.stdin.read())
elif a[:2] == ["secret", "list"]:
    now = "2020-01-01T00:00:00Z" if os.environ.get("FAKE_GH_OLD") else datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(json.dumps([{"name": n, "updatedAt": now} for n in sorted(os.listdir("$SB/gh"))]))
FAKE
cat >"$SB/bin/security" <<FAKE
#!/usr/bin/env bash
[ -n "\${FAKE_BW_LOCKED:-}" ] && exit 44
echo "SESSION-TEST"
FAKE
cat >"$SB/bin/bw" <<FAKE
#!/usr/bin/env python3
import base64, json, os, sys
a = sys.argv[1:]
open("$SB/bw-argv", "a").write(" ".join(a) + "\n")
assert os.environ.get("BW_SESSION") == "SESSION-TEST", "no session"
store = "$SB/vault/item.json"
if a == ["status"]:
    print(json.dumps({"status": "unlocked"}))
elif a[:2] == ["list", "items"]:
    items = [json.load(open(store))] if os.path.exists(store) else []
    if os.environ.get("FAKE_BW_EXISTING"):
        items.append({"id": "old", "name": "env/production/MCP_TOKEN", "fields": [{"name": "_bw.variable", "value": "MCP_TOKEN"}]})
    print(json.dumps(items))
elif a[:2] == ["create", "item"]:
    item = json.loads(base64.b64decode(sys.stdin.read()))
    item["id"] = "id-1"
    json.dump(item, open(store, "w"))
    print(json.dumps(item))
elif a[:2] == ["get", "item"]:
    item = json.load(open(store))
    if os.environ.get("FAKE_BW_TAMPER"):
        for f in item["fields"]:
            if f["name"] == "value":
                f["value"] = "tampered"
    print(json.dumps(item))
FAKE
cat >"$SB/bin/node" <<FAKE
#!/usr/bin/env python3
import base64, json, os, secrets, sys
a = sys.argv[1:]
open("$SB/node-argv", "a").write(" ".join(a) + "\n")
if a[:2] != ["scripts/release-secrets.mjs", a[1]] or a[1] not in ("generate", "check") or os.environ.get("FAKE_NODE_OLD"):
    print("Release secret files failed. --directory is required", file=sys.stderr)
    sys.exit(1)
if a[1] == "generate":
    rev = a[3].split("=", 1)[1]
    doc = {k: {"key": base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="), "revision": rev}
           for k in ["cms-v1", "drive-approved-v1", "official-export-v1", "rss-v1"]}
    print(json.dumps(doc, separators=(",", ":")))
else:
    v = sys.stdin.read()
    open("$SB/node-checked", "w").write(v)
    sys.exit(1 if os.environ.get("FAKE_NODE_CHECK_FAIL") or v.endswith("\n") else 0)
FAKE
chmod +x "$SB/bin/"*
export PATH="$SB/bin:$PATH"
CONSUMER="$SB/cor-os"
mkdir -p "$CONSUMER/scripts" && touch "$CONSUMER/scripts/release-secrets.mjs"
git -C "$CONSUMER" init -q && git -C "$CONSUMER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
reset() { rm -rf "$SB/gh/"* "$SB/vault/"* "$SB"/curl-argv "$SB"/curl-urls "$SB"/gh-argv "$SB"/bw-argv "$SB"/node-argv "$SB"/node-checked; }
run() { bash "${SCRIPT_UNDER_TEST:-$SCRIPT}" "$@" 2>&1; }
row() { grep -c "\"rule\":\"$1\"" "$AIDD_LEDGER_PATH" 2>/dev/null || true; }

# 1 GitHub OAuth: the right pair is stored, the control is measured and recorded
reset
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SB/gh/COR_GITHUB_OAUTH_CLIENT_ID" 2>/dev/null)" == "$GID" && "$(cat "$SB/gh/COR_GITHUB_OAUTH_CLIENT_SECRET" 2>/dev/null)" == "$GSEC" \
   && "$out" == *"real status=404, control status=401"* && "$(wc -l <"$SB/curl-urls")" -eq 2 ]] \
  && ok "github-oauth: a valid pair is stored after the provider answers 404 and the wrong-secret control 401" || bad "github good" "rc=$rc $out"
grep '"rule":"recipe-github-oauth-registered"' "$AIDD_LEDGER_PATH" | grep -q 'real status=404; control status=401' \
  && ok "github-oauth: the ledger row records both answers (the M1 measurement), never a value" || bad "github ledger" "$(tail -1 "$AIDD_LEDGER_PATH")"
! grep -qF "$GSEC" "$SB/curl-argv" "$SB/gh-argv" "$AIDD_LEDGER_PATH" && ! grep -qF "$GID" "$SB/curl-argv" "$SB/gh-argv" \
  && ok "github-oauth: neither value is in any argv or in the ledger (URL and auth go through a 0600 curl config)" || bad "github argv" "a value leaked"
[[ -z "$(ls -A "$TMPDIR")" ]] && ok "no temporary file is left" || bad "temp" "$(ls -A "$TMPDIR")"

# 2 GitHub OAuth: a wrong secret is refused; an endpoint that answers 404 to everything is refused by the control
reset
out="$(printf '%s\n%s\n' "$GID" "wrong_secret" | run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"did not answer as a valid pair (status=401"* ]] \
  && ok "github-oauth: a wrong secret is refused (rc=1) and nothing is stored" || bad "github wrong" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$GID" "wrong_secret" | FAKE_NODISCRIM=1 run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"does not discriminate"* ]] && [[ "$(row recipe-github-oauth-control-failed)" -ge 1 ]] \
  && ok "github-oauth: when the wrong-secret control also answers 404, the run refuses and records control-failed" || bad "github nodiscrim" "rc=$rc $out"

# 3 Slack OAuth: invalid_code for the pair, bad_client_secret for the control
reset
out="$(printf '%s\n%s\n' "$SID" "$SSEC" | run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r --env production)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SB/gh/SLACK_OAUTH_CLIENT_SECRET" 2>/dev/null)" == "$SSEC" && "$out" == *"error=invalid_code, control status=200 error=bad_client_secret"* \
   && "$(grep -c -- '--env production' "$SB/gh-argv")" -eq 3 ]] \
  && ok "slack-oauth: a valid pair is stored (invalid_code), the control says bad_client_secret, --env reaches set and list" || bad "slack good" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$SID" "nope" | run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"error=bad_client_secret"* ]] && ok "slack-oauth: a wrong secret is refused" || bad "slack wrong" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$SID" "nope" | FAKE_NODISCRIM=1 run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"does not discriminate"* ]] && ok "slack-oauth: a control that also says invalid_code refuses" || bad "slack nodiscrim" "rc=$rc $out"

# 4 values: the line count must match; an empty value is refused; the host is named before any value is read
reset
out="$(printf '%s\n' "$GID" | run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && ! -s "$SB/curl-argv" && "$out" == *"reads 2 lines"* && "$out" == *"will be sent to: api.github.com"* ]] && [[ "$(row recipe-github-oauth-values-count)" -ge 1 ]] \
  && ok "one line for a two-value recipe is refused before any call, after naming the host" || bad "count" "rc=$rc $out"

# 5 usage: unknown recipe, wrong name count, a fixed-name recipe with another name
reset
for args in "--recipe nope X o/r" "--recipe github-oauth ONLY_ONE o/r" "--recipe mcp-token OTHER_NAME o/r --keep-in-bitwarden env/production/OTHER_NAME" "--recipe github-oauth A B"; do
  out="$(printf '' | run $args)"; rc=$?
  [[ $rc -eq 2 && ! -s "$SB/curl-argv" ]] || bad "usage: $args" "rc=$rc $out"
done
[[ ! -s "$SB/curl-argv" ]] && ok "an unknown recipe, a wrong name count, a name outside a fixed recipe and a missing repo are usage errors (rc=2)"

# 6 MCP_TOKEN: generated, kept in Bitwarden, read back equal, then stored; the same value in both places
reset
out="$(printf '' | run --recipe mcp-token MCP_TOKEN o/r --env production --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
bwv="$(python3 -c 'import json,sys; print([f["value"] for f in json.load(open(sys.argv[1]))["fields"] if f["name"]=="value"][0])' "$SB/vault/item.json" 2>/dev/null)"
[[ $rc -eq 0 && -n "$bwv" && "$(cat "$SB/gh/MCP_TOKEN" 2>/dev/null)" == "$bwv" && "$out" == *"KEPT MCP_TOKEN in Bitwarden as env/production/MCP_TOKEN"* && "$out" != *"$bwv"* ]] \
  && ok "mcp-token: one generated value lands in Bitwarden and GitHub, read back equal, never printed" || bad "mcp good" "rc=$rc $out"
python3 -c 'import json,sys; f={x["name"]:x for x in json.load(open(sys.argv[1]))["fields"]}; assert f["_bw.variable"]["value"]=="MCP_TOKEN" and f["_bw.environment"]["value"]=="production" and f["value"]["type"]==1' "$SB/vault/item.json" 2>/dev/null \
  && ok "mcp-token: the Bitwarden item follows bwenv's layout (_bw.variable, _bw.environment, a hidden value field)" || bad "mcp layout" "$(cat "$SB/vault/item.json" 2>/dev/null | head -c 300)"
! grep -qF "$bwv" "$SB/bw-argv" "$SB/gh-argv" "$AIDD_LEDGER_PATH" && ok "mcp-token: the value is in no argv and not in the ledger" || bad "mcp argv" "leaked"
reset
out="$(printf '' | run --recipe mcp-token MCP_TOKEN o/r)"; rc=$?
[[ $rc -eq 2 && -z "$(ls "$SB/gh")" ]] && ok "mcp-token: without --keep-in-bitwarden it refuses (the administrator needs the value)" || bad "mcp nokeep" "rc=$rc $out"
out="$(printf '' | FAKE_BW_EXISTING=1 run --recipe mcp-token MCP_TOKEN o/r --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && ! -s "$SB/vault/item.json" ]] && ok "mcp-token: an existing ledger item refuses (rotation is a separate step)" || bad "mcp exists" "rc=$rc $out"
reset
out="$(printf '' | FAKE_BW_TAMPER=1 run --recipe mcp-token MCP_TOKEN o/r --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && -z "$(ls "$SB/gh")" && "$out" == *"did not read back equal"* ]] && ok "mcp-token: a Bitwarden readback that differs stops before GitHub (rc=3)" || bad "mcp tamper" "rc=$rc $out"
reset
out="$(printf '' | FAKE_BW_LOCKED=1 run --recipe mcp-token MCP_TOKEN o/r --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && -z "$(ls "$SB/gh")" && ! -s "$SB/bw-argv" ]] && ok "mcp-token: a locked vault refuses before a value is made" || bad "mcp locked" "rc=$rc $out"
reset
out="$(printf '' | FAKE_BW_LOCKED=1 run --recipe mcp-token MCP_TOKEN o/r --keep-in-bitwarden env/production/MCP_TOKEN --dry-run)"; rc=$?
[[ $rc -eq 0 && -z "$(ls "$SB/gh")" && ! -s "$SB/bw-argv" && "$out" == *"DRY RUN"* ]] && ok "mcp-token: a dry run touches neither Bitwarden nor GitHub" || bad "mcp dry" "rc=$rc $out"

# 7 PUBLISHING_INTAKE_KEYS_JSON: the consumer's generator and check decide; a consumer without them refuses
reset
out="$(printf '' | run --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$CONSUMER" --param revision=2026-11-01)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SB/gh/PUBLISHING_INTAKE_KEYS_JSON" 2>/dev/null)" == "$(cat "$SB/node-checked" 2>/dev/null)" && "$out" == *"consumer's check passed"* ]] \
  && grep -q -- '--revision=2026-11-01' "$SB/node-argv" && ok "intake-keys: the consumer's value passes its own check and is stored exactly as checked" || bad "intake good" "rc=$rc $out"
reset
out="$(printf '' | FAKE_NODE_OLD=1 run --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$CONSUMER" --param revision=r1)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"cor-os#126"* ]] && [[ "$(row recipe-intake-keys-consumer-generate)" -ge 1 ]] \
  && ok "intake-keys: a consumer without the generator refuses (today's cor-os) and says what it needs" || bad "intake old" "rc=$rc $out"
reset
out="$(printf '' | FAKE_NODE_CHECK_FAIL=1 run --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$CONSUMER" --param revision=r1)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" ]] && ok "intake-keys: a value the consumer's check refuses is not stored" || bad "intake check" "rc=$rc $out"
out="$(printf '' | run --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$SB")"; rc=$?
[[ $rc -eq 2 ]] && ok "intake-keys: no --param revision or no consumer checkout is a usage error" || bad "intake usage" "rc=$rc $out"

# 8 gh failures: set fails → rc 3; stale readback → rc 4 as a warn row
reset
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | FAKE_GH_SET_FAIL=1 run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 3 ]] && ok "a failing gh secret set is rc=3" || bad "set fail" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | FAKE_GH_OLD=1 run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 4 ]] && grep '"rule":"recipe-github-oauth-readback-stale"' "$AIDD_LEDGER_PATH" | grep -q '"decision":"warn"' \
  && ok "a stale readback is rc=4 with a warn row" || bad "stale" "rc=$rc $out"

# 9 a caller-side json.py is never imported (the wrapper runs from /, the helper with -I)
reset
mkdir -p "$SB/cwd" && printf 'open("%s/imported","w").write("x")\nraise SystemExit(9)\n' "$SB" >"$SB/cwd/json.py"
(cd "$SB/cwd" && printf '%s\n%s\n' "$GID" "$GSEC" | bash "$SCRIPT" --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r >/dev/null 2>&1)
[[ ! -e "$SB/imported" && -s "$SB/gh/COR_GITHUB_OAUTH_CLIENT_SECRET" ]] && ok "a json.py in the caller's directory is not imported" || bad "cwd" "imported or not stored"

# Mutants (red side)
mutant() {  # <name> <old> <new>: a copy of the script tree with one change to the helper
  local d="$SB/mut-$1"
  mkdir -p "$d/scripts/lib" "$d/hooks/lib"
  cp "$SCRIPT" "$d/scripts/" && cp "$ROOT/scripts/lib/secret-verify-recipes.json" "$d/scripts/lib/" && cp "$ROOT/hooks/lib/aidd-ledger.sh" "$d/hooks/lib/"
  python3 - "$ROOT/scripts/lib/secret_recipes.py" "$d/scripts/lib/secret_recipes.py" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if t.count(old) != 1:
    raise SystemExit("mutation target not found: " + old)
open(dst, "w").write(t.replace(old, new))
PY
  [[ -f "$d/scripts/lib/secret_recipes.py" ]] && echo "$d/scripts/register-secret-verified.sh"
}
M1="$(mutant control "        if not ok:" "        if False:")"
if [[ -n "$M1" ]]; then
  reset
  printf '%s\n%s\n' "$GID" "wrong_secret" | FAKE_NODISCRIM=1 SCRIPT_UNDER_TEST="$M1" run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r >/dev/null
  [[ "$(cat "$SB/gh/COR_GITHUB_OAUTH_CLIENT_SECRET" 2>/dev/null)" == "wrong_secret" ]] \
    && ok "mutant (no control check) stores a wrong secret through a non-discriminating endpoint; the real script refuses (case 2)" \
    || bad "mutant control" "the mutant did not store — the control rows prove nothing"
else bad "mutant control" "could not build"; fi
M2="$(mutant check "    if chk.returncode != 0:" "    if False:")"
if [[ -n "$M2" ]]; then
  reset
  printf '' | FAKE_NODE_CHECK_FAIL=1 SCRIPT_UNDER_TEST="$M2" run --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$CONSUMER" --param revision=r1 >/dev/null
  [[ -s "$SB/gh/PUBLISHING_INTAKE_KEYS_JSON" ]] \
    && ok "mutant (consumer check skipped) stores a value the check refuses; the real script refuses (case 7)" \
    || bad "mutant check" "the mutant did not store — the check row proves nothing"
else bad "mutant check" "could not build"; fi

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
