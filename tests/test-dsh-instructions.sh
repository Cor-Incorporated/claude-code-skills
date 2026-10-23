#!/usr/bin/env bash
# dsh delivery of the H17 report contract (hooks/lib/aidd_cc_contract.md; #440 started it as dsh/AGENTS.md, and the
# owner's decision of 2026-10-23 made it one contract for every non-Claude entry). tests/test-h17-contract.sh checks
# the wording against the oracle; this file checks that dsh actually sends it.
# Part 1 (always): setup.sh installs the contract into $DSH_HOME/AGENTS.md.
# Part 2 (needs a dsh install + node 24, SKIP otherwise): dsh puts $DSH_HOME/AGENTS.md into the first model request.
#   A local stub stands in for the DeepSeek Messages endpoint (DEEPSEEK_BASE_URL), so no real key or network call is
#   used; the same run without the file must not carry the text, or the check proves nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

INSTALL="$ROOT/hooks/lib/aidd_cc_contract.py"
if grep -q '\.dsh-aidd/AGENTS.md' "$ROOT/setup.sh" && grep -q 'aidd_cc_contract.py" install' "$ROOT/setup.sh"; then
  ok "setup.sh installs the H17 report contract into ~/.dsh-aidd/AGENTS.md"
else bad "setup.sh has no contract install for ~/.dsh-aidd/AGENTS.md"; fi

NODE24="${NODE24_BIN:-$HOME/.local/share/mise/installs/node/24.21.0/bin}"
DSH="${DSH_BIN:-${DSH_PKG_DIR:-$HOME/.dsh-aidd/pkg}/node_modules/.bin/dsh}"
PROFILE="${DSH_HOME:-$HOME/.dsh-aidd}/profiles/headless"
if [ ! -x "$DSH" ] || [ ! -x "$NODE24/node" ] || [ ! -d "$PROFILE" ]; then
  echo "SKIP: part 2 needs dsh, node 24 and a headless profile (DSH_BIN / NODE24_BIN / DSH_HOME)"
# Codex review P2: a profile that pins its own endpoint or key variable would send the probe there, with whatever
# credential it names, instead of to the stub. Such a profile is never run here.
elif grep -rqsE 'baseURL|apiKeyEnv' "$PROFILE"; then
  echo "SKIP: part 2: $PROFILE pins baseURL / apiKeyEnv, so the probe would not stay on the local stub"
else
  DSH="$(cd "$(dirname "$DSH")" && pwd)/$(basename "$DSH")"  # absolute before probe() changes directory (Codex P2)
  TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 120"; command -v gtimeout >/dev/null 2>&1 && TMO="gtimeout 120"
  SB="$(mktemp -d)"; trap 'kill "${STUB:-0}" 2>/dev/null; rm -rf "$SB"' EXIT
  cat >"$SB/stub.py" <<'PY'
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        with open(out, "ab") as f:
            f.write(body + b"\n")
        msg = b'{"type":"error","error":{"type":"invalid_request_error","message":"test stub"}}'
        self.send_response(400); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(msg))); self.end_headers(); self.wfile.write(msg)
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  python3 -I "$SB/stub.py" "$SB/requests.log" "$SB/port" & STUB=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SB/port" ] && break; sleep 0.3; done
  printf -- '- id: session-log-deepseek\n  disabled: true\n- id: session-telemetry-otel\n  disabled: true\n' >"$SB/patch.yml"
  probe() { # $1 = DSH_HOME; prints nothing, appends the requests dsh made to the stub
    mkdir -p "$1/profiles" "$SB/cwd" && cp -R "$PROFILE" "$1/profiles/" && find "$1" -name '.env*' -type f -delete
    # shellcheck disable=SC2086  # $TMO is intentionally word-split ("timeout 120" or empty)
    (cd "$SB/cwd" && env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY PATH="$NODE24:$PATH" DSH_HOME="$1" \
      DEEPSEEK_API_KEY=test-not-a-key DEEPSEEK_BASE_URL="http://127.0.0.1:$(cat "$SB/port")" \
      $TMO "$DSH" --profile headless --patch "$SB/patch.yml" "probe" >/dev/null 2>&1)
  }
  probe "$SB/without"
  : >"$SB/without.log"; [ -f "$SB/requests.log" ] && mv "$SB/requests.log" "$SB/without.log"
  python3 -I "$INSTALL" install --agent dsh "$SB/with/AGENTS.md" >/dev/null
  probe "$SB/with"
  if [ ! -s "$SB/requests.log" ] || [ ! -s "$SB/without.log" ]; then
    bad "dsh sent no request to the stub (with file: $(wc -l <"$SB/requests.log" 2>/dev/null || echo 0) request(s), without: $(wc -l <"$SB/without.log") request(s); DEEPSEEK_BASE_URL not used?)"
  elif grep -q 'AIDD H17 report contract' "$SB/requests.log" && ! grep -q 'AIDD H17 report contract' "$SB/without.log"; then
    ok "the first model request carries \$DSH_HOME/AGENTS.md, and the run without the file does not"
  else
    bad "with-file request has the guidance: $(grep -c 'AIDD H17 report contract' "$SB/requests.log"); without-file: $(grep -c 'AIDD H17 report contract' "$SB/without.log")"
  fi
fi
echo "dsh instructions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
