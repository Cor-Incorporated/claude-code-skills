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
    if not m:
        conf.setdefault("flags", []).append(line.strip())
        continue
    k, v = m.group(1), re.sub(r'\\\\(.)', r'\1', m.group(2))
    headers.append(v) if k == "header" else conf.__setitem__(k, v)
open("$SB/curl-urls", "a").write(conf["url"] + "\n")
if os.environ.get("FAKE_CURL_RC"):
    sys.exit(int(os.environ["FAKE_CURL_RC"]))
auth = next((h[len("Authorization: Basic "):] for h in headers if h.startswith("Authorization: Basic ")), "")
user, _, pw = base64.b64decode(auth).decode().partition(":") if auth else ("", "", "")
status, body = 200, "{}"
if "/applications/" in conf["url"]:
    good = user == "$GID" and pw == "$GSEC" and conf["url"].endswith("/applications/$GID/token")
    status = 404 if good or os.environ.get("FAKE_NODISCRIM") else int(os.environ.get("FAKE_GH_BAD", "401"))
    if good and os.environ.get("FAKE_GH_GOOD"):
        status = int(os.environ["FAKE_GH_GOOD"])
    body = {404: '{"message":"Not Found"}', 401: '{"message":"Bad credentials"}'}.get(status, '{"message":"other"}')
    if status == 404 and os.environ.get("FAKE_HTML_404"):
        body = "<html><body>Not Found</body></html>"
elif "oauth.v2.access" in conf["url"]:
    side = "REAL" if user == "$SID" and pw == "$SSEC" else "CONTROL"
    if os.environ.get("FAKE_NODISCRIM"):
        err = "invalid_code"
    elif user != "$SID":
        err = "invalid_client_id"
    elif pw != "$SSEC":
        err = "bad_client_secret"
    else:
        err = "invalid_code"
    doc = {"error": os.environ.get("FAKE_SLACK_" + side + "_ERROR", err)}
    ok_value = os.environ.get("FAKE_SLACK_" + side + "_OK", "false")
    if ok_value != "missing":
        doc["ok"] = json.loads(ok_value)
    body = json.dumps(doc)
    status = int(os.environ.get("FAKE_SLACK_" + side + "_STATUS", os.environ.get("FAKE_SLACK_STATUS", "200")))
open(conf["output"], "w").write(body)
sys.stdout.write(str(status))
FAKE
cat >"$SB/bin/gh" <<FAKE
#!/usr/bin/env python3
import json, os, sys, datetime
a = sys.argv[1:]
open("$SB/gh-argv", "a").write(" ".join(a) + "\n")
if a[:2] == ["secret", "set"]:
    if os.environ.get("FAKE_GH_SLEEP"):
        import time
        time.sleep(float(os.environ["FAKE_GH_SLEEP"]))
        sys.exit(1)
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
    print(json.dumps({"status": os.environ.get("FAKE_BW_STATUS", "unlocked")}))
elif a == ["sync"]:
    sys.exit(1 if os.environ.get("FAKE_BW_SYNC_FAIL") else 0)
elif a[:2] == ["list", "items"]:
    if os.environ.get("FAKE_BW_LIST_FAIL"):
        sys.exit(1)
    items = [json.load(open(store))] if os.path.exists(store) else []
    if os.environ.get("FAKE_BW_OTHER_NAME"):
        items.append({"id": "other", "name": "env/production/computer-mcp-bearer", "fields": [{"name": "_bw.variable", "value": "MCP_TOKEN"}]})
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
    if os.environ.get("FAKE_NODE_CHECK_ECHO"):
        print("invalid adapter key in " + v, file=sys.stderr)
        sys.exit(1)
    sys.exit(1 if os.environ.get("FAKE_NODE_CHECK_FAIL") or v.endswith("\n") else 0)
FAKE
chmod +x "$SB/bin/"*
export PATH="$SB/bin:$PATH"
CONSUMER="$SB/cor-os"
mkdir -p "$CONSUMER/scripts" && touch "$CONSUMER/scripts/release-secrets.mjs"
git -C "$CONSUMER" init -q && git -C "$CONSUMER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
reset() { rm -rf "$SB/gh/"* "$SB/vault/"* "$SB"/curl-argv "$SB"/curl-urls "$SB"/gh-argv "$SB"/bw-argv "$SB"/node-argv "$SB"/node-checked; }
run() { bash "$SCRIPT" "$@" 2>&1; }
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

# 3 Slack OAuth: simulate discriminating answers; real Slack may answer invalid_code to both (M2).
reset
out="$(printf '%s\n%s\n' "$SID" "$SSEC" | run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r --env production)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SB/gh/SLACK_OAUTH_CLIENT_SECRET" 2>/dev/null)" == "$SSEC" && "$out" == *"error=invalid_code, control status=200 error=bad_client_secret"* \
   && "$(grep -c -- '--env production' "$SB/gh-argv")" -eq 3 ]] \
  && ok "slack-oauth: simulated invalid_code/bad_client_secret stores the fixture pair, --env reaches set and list" || bad "slack good" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$SID" "nope" | run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"error=bad_client_secret"* ]] && ok "slack-oauth: a wrong secret is refused" || bad "slack wrong" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$SID" "nope" | FAKE_NODISCRIM=1 run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"does not discriminate"* ]] && ok "slack-oauth: a control that also says invalid_code refuses" || bad "slack nodiscrim" "rc=$rc $out"
reset
before="$(row recipe-slack-oauth-control-failed)"
out="$(printf '%s\n%s\n' "$SID" "$SSEC" | FAKE_NODISCRIM=1 run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && ! -s "$SB/gh-argv" && -z "$(ls "$SB/gh")" && "$(row recipe-slack-oauth-control-failed)" -eq $((before + 1)) ]] \
  && tail -n 1 "$AIDD_LEDGER_PATH" | grep -q 'real status=200 error=invalid_code; control status=200 error=invalid_code' \
  && ok "slack-oauth: the measured invalid_code/invalid_code pair refuses before any gh call and records both answers" \
  || bad "slack measured nodiscrim" "rc=$rc $out"
for fault in FAKE_SLACK_REAL_STATUS=400 FAKE_SLACK_CONTROL_STATUS=400 \
             FAKE_SLACK_CONTROL_OK=true FAKE_SLACK_CONTROL_OK=missing \
             FAKE_SLACK_REAL_ERROR=undocumented_error FAKE_SLACK_CONTROL_ERROR=undocumented_error \
             FAKE_SLACK_REAL_ERROR=invalid_client_id FAKE_SLACK_CONTROL_ERROR=invalid_client_id; do
  reset
  out="$(printf '%s\n%s\n' "$SID" "$SSEC" | env "$fault" bash "$SCRIPT" --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r 2>&1)"; rc=$?
  [[ $rc -eq 1 && ! -s "$SB/gh-argv" && -z "$(ls "$SB/gh")" && "$out" == *"nothing was stored"* ]] \
    && ok "slack-oauth: $fault refuses before any gh call" || bad "slack $fault" "rc=$rc $out"
done

# 4 values: the line count must match; an empty value is refused; the host is named before any value is read
reset
out="$(printf '%s\n' "$GID" | run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && ! -s "$SB/curl-argv" && "$out" == *"reads 2 lines"* && "$out" == *"will be sent to: api.github.com"* ]] && [[ "$(row recipe-github-oauth-values-count)" -ge 1 ]] \
  && ok "one line for a two-value recipe is refused before any call, after naming the host" || bad "count" "rc=$rc $out"

# 5 usage: unknown recipe, wrong name count, a fixed-name recipe with another name
reset
for args in "--recipe nope X o/r" "--recipe github-oauth ONLY_ONE o/r" "--recipe mcp-token OTHER_NAME Cor-Incorporated/cor-os --keep-in-bitwarden env/production/OTHER_NAME" "--recipe github-oauth A B"; do
  out="$(printf '' | run $args)"; rc=$?
  [[ $rc -eq 2 && ! -s "$SB/curl-argv" ]] || bad "usage: $args" "rc=$rc $out"
done
[[ ! -s "$SB/curl-argv" ]] && ok "an unknown recipe, a wrong name count, a name outside a fixed recipe and a missing repo are usage errors (rc=2)"

# 6 MCP_TOKEN: generated, kept in Bitwarden, read back equal, then stored; the same value in both places
reset
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --env production --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
bwv="$(python3 -c 'import json,sys; print([f["value"] for f in json.load(open(sys.argv[1]))["fields"] if f["name"]=="value"][0])' "$SB/vault/item.json" 2>/dev/null)"
[[ $rc -eq 0 && -n "$bwv" && "$(cat "$SB/gh/MCP_TOKEN" 2>/dev/null)" == "$bwv" && "$out" == *"KEPT MCP_TOKEN in Bitwarden as env/production/MCP_TOKEN (read back equal, length ${#bwv})"* && "$out" != *"$bwv"* ]] \
  && grep '"rule":"recipe-mcp-token-registered"' "$AIDD_LEDGER_PATH" | grep -q "read back equal, length ${#bwv}" \
  && ok "mcp-token: one generated value lands in Bitwarden and GitHub, read back equal, never printed" || bad "mcp good" "rc=$rc $out"
python3 -c 'import json,sys; f={x["name"]:x for x in json.load(open(sys.argv[1]))["fields"]}; assert f["_bw.variable"]["value"]=="MCP_TOKEN" and f["_bw.environment"]["value"]=="production" and f["value"]["type"]==1' "$SB/vault/item.json" 2>/dev/null \
  && ok "mcp-token: the Bitwarden item follows bwenv's layout (_bw.variable, _bw.environment, a hidden value field)" || bad "mcp layout" "$(cat "$SB/vault/item.json" 2>/dev/null | head -c 300)"
! grep -qF -- "$bwv" "$SB/bw-argv" "$SB/gh-argv" "$AIDD_LEDGER_PATH" && ok "mcp-token: the value is in no argv and not in the ledger" || bad "mcp argv" "leaked"
reset
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os)"; rc=$?
[[ $rc -eq 2 && -z "$(ls "$SB/gh")" ]] && ok "mcp-token: without --keep-in-bitwarden it refuses (the administrator needs the value)" || bad "mcp nokeep" "rc=$rc $out"
out="$(printf '' | FAKE_BW_EXISTING=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && ! -s "$SB/vault/item.json" ]] && ok "mcp-token: an existing ledger item refuses (rotation is a separate step)" || bad "mcp exists" "rc=$rc $out"
reset
out="$(printf '' | FAKE_BW_TAMPER=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && -z "$(ls "$SB/gh")" && "$out" == *"did not read back equal"* ]] && ok "mcp-token: a Bitwarden readback that differs stops before GitHub (rc=3)" || bad "mcp tamper" "rc=$rc $out"
[[ "$out" != *"resume"* && "$out" != *"Resume"* ]] && ok "a readback mismatch never suggests resuming that copy (#479 review 2)" || bad "tamper resume word" "$out"
reset
out="$(printf '' | FAKE_BW_LOCKED=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && -z "$(ls "$SB/gh")" && ! -s "$SB/bw-argv" ]] && ok "mcp-token: a locked vault refuses before a value is made" || bad "mcp locked" "rc=$rc $out"
reset
out="$(printf '' | FAKE_BW_STATUS=locked run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && -z "$(ls "$SB/gh")" && ! -e "$SB/vault/item.json" && "$(grep -c 'create item' "$SB/bw-argv" 2>/dev/null || true)" -eq 0 ]] \
  && ok "mcp-token: a session whose vault reports locked refuses with no item created (no empty item, 10-31)" || bad "mcp status locked" "rc=$rc $out"
reset
out="$(printf '' | FAKE_BW_LOCKED=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN --dry-run)"; rc=$?
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

# 10 #479 review: an answer that is not a definite one never stands in for the control
for code in 503 429 403; do
  reset
  out="$(printf '%s\n%s\n' "$GID" "$GSEC" | FAKE_GH_BAD=$code run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
  [[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"not a definite one"* ]] || bad "inconclusive $code" "rc=$rc $out"
done
[[ "$(row recipe-github-oauth-inconclusive)" -ge 3 ]] && ok "a control answering 503, 429 or 403 refuses as inconclusive and stores nothing" || bad "inconclusive rows" "$(row recipe-github-oauth-inconclusive)"
for code in 503 429 403; do
  reset
  out="$(printf '%s\n%s\n' "$GID" "$GSEC" | FAKE_GH_GOOD=$code run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
  [[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"not a definite one"* ]] || bad "real inconclusive $code" "rc=$rc $out"
done
[[ "$(row recipe-github-oauth-inconclusive)" -ge 6 ]] && ok "the real request answering 503, 429 or 403 is held to the same rule: inconclusive, nothing stored" || bad "real inconclusive rows" "$(row recipe-github-oauth-inconclusive)"
reset
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | FAKE_GH_BAD=422 run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"does not discriminate"* ]] \
  && ok "a control that answers a definite 422 (not an authentication failure) refuses: only 401 counts" || bad "control 422" "rc=$rc $out"
for code in 503 429 403; do
  reset
  out="$(printf '%s\n%s\n' "$SID" "$SSEC" | FAKE_SLACK_STATUS=$code run --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r)"; rc=$?
  [[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"not a definite one"* ]] || bad "slack inconclusive $code" "rc=$rc $out"
done
[[ "$(row recipe-slack-oauth-inconclusive)" -ge 3 ]] && ok "slack-oauth answering 503, 429 or 403 refuses as inconclusive" || bad "slack inconclusive rows" "$(row recipe-slack-oauth-inconclusive)"
reset
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | FAKE_HTML_404=1 run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"not a definite one"* ]] && ok "a 404 that is not a JSON object (an HTML page) is inconclusive" || bad "html 404" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | FAKE_CURL_RC=7 run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" && "$out" == *"curl rc=7"* ]] && ok "a curl failure refuses (rc=1) and stores nothing" || bad "curl rc" "rc=$rc $out"
reset
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | run --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r --dry-run)"; rc=$?
[[ $rc -eq 0 && ! -s "$SB/gh-argv" && "$out" == *"DRY RUN"* ]] && ok "a network dry run verifies and never calls gh" || bad "network dry" "rc=$rc $out"

# 11 #479 review: Bitwarden written, GitHub failed → the message names the copy, and --resume-from-bitwarden stores it
reset
out="$(printf '' | FAKE_GH_SET_FAIL=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && -s "$SB/vault/item.json" && "$out" == *"State: Bitwarden has env/production/MCP_TOKEN (id id-1); GitHub does not have it"* && "$out" == *"--resume-from-bitwarden"* ]] \
  && ok "a gh failure after the Bitwarden write names the copy and the resume step" || bad "keep then gh fail" "rc=$rc $out"
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN --resume-from-bitwarden)"; rc=$?
bwv="$(python3 -c 'import json,sys; print([f["value"] for f in json.load(open(sys.argv[1]))["fields"] if f["name"]=="value"][0])' "$SB/vault/item.json" 2>/dev/null)"
[[ $rc -eq 0 && -n "$bwv" && "$(cat "$SB/gh/MCP_TOKEN" 2>/dev/null)" == "$bwv" && "$out" == *"RESUMED MCP_TOKEN"* && "$out" != *"$bwv"* \
   && "$(grep -c '^create item' "$SB/bw-argv")" -eq 1 && "$(grep -c '^delete' "$SB/bw-argv" || true)" -eq 0 ]] \
  && ok "gh failure, then --resume-from-bitwarden: stored from that same copy, one item created in all, none deleted, never printed" || bad "resume" "rc=$rc $out"
reset
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN --resume-from-bitwarden)"; rc=$?
[[ $rc -eq 1 && -z "$(ls "$SB/gh")" ]] && ok "--resume-from-bitwarden with no ledger item refuses" || bad "resume none" "rc=$rc $out"
reset
python3 -c 'import json,sys; json.dump({"id":"id-9","name":"env/production/MCP_TOKEN","fields":[{"type":0,"name":"_bw.variable","value":"MCP_TOKEN"},{"type":0,"name":"_bw.environment","value":"production"},{"type":0,"name":"_bw.service","value":"cor-os"},{"type":1,"name":"value","value":"hand typed value with spaces"}]}, open(sys.argv[1],"w"))' "$SB/vault/item.json"
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN --resume-from-bitwarden)"; rc=$?
[[ $rc -ne 0 && -z "$(ls "$SB/gh")" && "$out" == *"fails the recipe's check"* && "$out" != *"hand typed"* ]] \
  && ok "--resume-from-bitwarden refuses a copy with whitespace (the recipe's check), GitHub untouched" || bad "resume check" "rc=$rc $out"
reset
python3 -c 'import json,sys; json.dump({"id":"id-8","name":"env/staging/MCP_TOKEN","fields":[{"type":0,"name":"_bw.variable","value":"MCP_TOKEN"},{"type":0,"name":"_bw.environment","value":"staging"},{"type":0,"name":"_bw.service","value":"cor-os"},{"type":1,"name":"value","value":"stagingValue_0123456789abcdefghijklmnopqrstu"}]}, open(sys.argv[1],"w"))' "$SB/vault/item.json"
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --env production --keep-in-bitwarden env/staging/MCP_TOKEN --resume-from-bitwarden)"; rc=$?
[[ $rc -ne 0 && -z "$(ls "$SB/gh")" && "$out" == *"_bw.environment=staging"* ]] \
  && ok "--resume-from-bitwarden refuses an item whose _bw.environment differs from --env" || bad "resume env" "rc=$rc $out"
reset
python3 -c 'import json,sys; json.dump({"id":"id-7","name":"env/production/MCP_TOKEN","fields":[{"type":0,"name":"_bw.variable","value":"OTHER_TOKEN"},{"type":1,"name":"value","value":"otherValue_0123456789abcdefghijklmnopqrstuvw"}]}, open(sys.argv[1],"w"))' "$SB/vault/item.json"
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN --resume-from-bitwarden)"; rc=$?
[[ $rc -ne 0 && -z "$(ls "$SB/gh")" && "$out" == *"_bw.variable=OTHER_TOKEN"* ]] \
  && ok "--resume-from-bitwarden refuses an item whose _bw.variable is another secret" || bad "resume variable" "rc=$rc $out"
reset
python3 -c 'import json,sys; json.dump({"id":"id-6","name":"env/production/MCP_TOKEN","fields":[{"type":0,"name":"_bw.variable","value":"MCP_TOKEN"},{"type":0,"name":"_bw.environment","value":"production"},{"type":0,"name":"_bw.service","value":"other-svc"},{"type":1,"name":"value","value":"otherSvcValue_0123456789abcdefghijklmnopqrs"}]}, open(sys.argv[1],"w"))' "$SB/vault/item.json"
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN --resume-from-bitwarden)"; rc=$?
out2="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/other-svc --keep-in-bitwarden env/production/MCP_TOKEN --resume-from-bitwarden)"; rc2=$?
[[ $rc -ne 0 && $rc2 -eq 2 && -z "$(ls "$SB/gh")" && "$out" == *"_bw.service=other-svc"* && "$out2" == *"is for Cor-Incorporated/cor-os only"* ]] \
  && ok "resume refuses an item of another service, and the recipe's declared repository cannot be widened by the argument" || bad "resume service" "rc=$rc $out / rc2=$rc2 $out2"
reset
out="$(printf '' | FAKE_BW_LIST_FAIL=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && ! -e "$SB/vault/item.json" && -z "$(ls "$SB/gh")" ]] && ok "a failing bw list refuses (no duplicate is created blind)" || bad "bw list fail" "rc=$rc $out"
out="$(printf '' | FAKE_BW_SYNC_FAIL=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 3 && ! -e "$SB/vault/item.json" ]] && ok "a failing bw sync refuses before the duplicate check" || bad "bw sync fail" "rc=$rc $out"
out="$(printf '' | FAKE_BW_OTHER_NAME=1 run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/MCP_TOKEN)"; rc=$?
[[ $rc -eq 1 && ! -e "$SB/vault/item.json" ]] && ok "an item under another name with _bw.variable=MCP_TOKEN counts as a duplicate" || bad "dup by variable" "rc=$rc $out"
out="$(printf '' | run --recipe mcp-token MCP_TOKEN Cor-Incorporated/cor-os --keep-in-bitwarden env/production/OTHER)"; rc=$?
[[ $rc -eq 2 && ! -e "$SB/vault/item.json" ]] && ok "a Bitwarden item name that does not end in the secret's name is a usage error" || bad "keep name" "rc=$rc $out"

# 12 consumer: a check that echoes the value never prints it; a checkout without the marker is a usage error
reset
out="$(printf '' | FAKE_NODE_CHECK_ECHO=1 run --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$CONSUMER" --param revision=r1)"; rc=$?
v="$(cat "$SB/node-checked" 2>/dev/null)"
[[ $rc -eq 1 && -n "$v" && "$out" != *"$v"* && "$out" == *"<value>"* ]] && ok "a consumer check that prints the value is shown redacted" || bad "redact" "rc=$rc"
reset
mkdir -p "$SB/nomarker"
out="$(printf '' | run --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$SB/nomarker" --param revision=r1)"; rc=$?
[[ $rc -eq 2 && ! -s "$SB/node-argv" ]] && ok "a checkout without the consumer's script is a usage error before any command runs" || bad "marker" "rc=$rc $out"

# 13 the helper runs isolated (-I): a json.py on PYTHONPATH is not imported
reset
mkdir -p "$SB/pp" && printf 'import sys\nif sys.argv[0] == "-" or "secret_recipes" in sys.argv[0]:\n    open("%s/pp-imported","a").write(sys.argv[0] + "\\n")\ndel sys.modules["json"]\nsys.path = [p for p in sys.path if not p.endswith("/pp")]\nimport json as _j\nsys.modules["json"] = _j\n' "$SB" >"$SB/pp/json.py"
printf '%s\n%s\n' "$GID" "$GSEC" | PYTHONPATH="$SB/pp" bash "$SCRIPT" --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r >/dev/null 2>&1
[[ ! -e "$SB/pp-imported" && -s "$SB/gh/COR_GITHUB_OAUTH_CLIENT_SECRET" ]] \
  && ok "a json.py on PYTHONPATH is imported neither by the helper nor by the ledger library's python" \
  || bad "pythonpath" "imported by: $(cat "$SB/pp-imported" 2>/dev/null | tr '\n' ' ') stored=$(ls "$SB/gh")"

# 14 a signal mid-run leaves no value file
reset
printf '%s\n%s\n' "$SID" "$SSEC" | FAKE_GH_SLEEP=5 bash "$SCRIPT" --recipe slack-oauth SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET o/r >/dev/null 2>&1 &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -n "$(ls "$TMPDIR" 2>/dev/null)" && -s "$SB/gh-argv" ]] && break; sleep 0.3; done
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
[[ -z "$(ls -A "$TMPDIR")" ]] && ok "SIGTERM during gh secret set leaves no temporary value file" || bad "sigterm" "$(ls -A "$TMPDIR")"

# 15 a recipe whose condition is empty or misspelled refuses before any request
reset
mkdir -p "$SB/strict"
cp "$ROOT/scripts/lib/secret_recipes.py" "$SB/strict/"
cp "$ROOT/scripts/lib/slack_oauth_code.py" "$SB/strict/"
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); b["recipes"]["github-oauth"]["pass"]={"stauts":404}; json.dump(b,open(sys.argv[2],"w"))' \
  "$ROOT/scripts/lib/secret-verify-recipes.json" "$SB/strict/secret-verify-recipes.json"
out="$(printf '%s\n%s\n' "$GID" "$GSEC" | python3 -I "$SB/strict/secret_recipes.py" --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r 2>&1)"; rc=$?
[[ $rc -eq 1 && ! -s "$SB/curl-argv" && "$out" == *"empty or has unknown keys"* ]] && ok "a misspelled pass condition refuses before any request" || bad "strict" "rc=$rc $out"

# Mutants (red side). Each writes a changed copy of the helper next to a copy of the recipe file and runs that copy
# itself in this file (pair18: the variable written is the variable executed).
cp "$ROOT/scripts/lib/secret-verify-recipes.json" "$SB/secret-verify-recipes.json"
cp "$ROOT/scripts/lib/slack_oauth_code.py" "$SB/slack_oauth_code.py"
LEDGER_LIB="$ROOT/hooks/lib/aidd-ledger.sh"
MUT1="$SB/mut_control.py"
python3 - "$ROOT/scripts/lib/secret_recipes.py" "$MUT1" "        if not ok:" "        if False:" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if t.count(old) != 1:
    raise SystemExit("mutation target not found: " + old)
open(dst, "w").write(t.replace(old, new))
PY
if [[ -f "$MUT1" ]]; then
  reset
  printf '%s\n%s\n' "$GID" "wrong_secret" | FAKE_NODISCRIM=1 AIDD_SECRET_LEDGER_LIB="$LEDGER_LIB" python3 "$MUT1" \
    --recipe github-oauth COR_GITHUB_OAUTH_CLIENT_ID COR_GITHUB_OAUTH_CLIENT_SECRET o/r >/dev/null 2>&1
  [[ "$(cat "$SB/gh/COR_GITHUB_OAUTH_CLIENT_SECRET" 2>/dev/null)" == "wrong_secret" ]] \
    && ok "mutant (no control check) stores a wrong secret through a non-discriminating endpoint; the real script refuses (case 2)" \
    || bad "mutant control" "the mutant did not store — the control rows prove nothing"
else bad "mutant control" "could not build"; fi
MUT2="$SB/mut_check.py"
python3 - "$ROOT/scripts/lib/secret_recipes.py" "$MUT2" "    if chk.returncode != 0:" "    if False:" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if t.count(old) != 1:
    raise SystemExit("mutation target not found: " + old)
open(dst, "w").write(t.replace(old, new))
PY
if [[ -f "$MUT2" ]]; then
  reset
  printf '' | FAKE_NODE_CHECK_FAIL=1 AIDD_SECRET_LEDGER_LIB="$LEDGER_LIB" python3 "$MUT2" \
    --recipe intake-keys PUBLISHING_INTAKE_KEYS_JSON o/r --repo-dir "$CONSUMER" --param revision=r1 >/dev/null 2>&1
  [[ -s "$SB/gh/PUBLISHING_INTAKE_KEYS_JSON" ]] \
    && ok "mutant (consumer check skipped) stores a value the check refuses; the real script refuses (case 7)" \
    || bad "mutant check" "the mutant did not store — the check row proves nothing"
else bad "mutant check" "could not build"; fi

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
