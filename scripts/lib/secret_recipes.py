"""register-secret-verified.sh --recipe: check secrets with a reviewed recipe, then store them as GitHub secrets.

usage (through the wrapper):
  register-secret-verified.sh --recipe <name> <NAME>... <owner/repo> [--env <environment>] [--param k=v]...
      [--repo-dir <consumer checkout>] [--keep-in-bitwarden env/<environment>/<NAME>] [--dry-run]

Recipes live in secret-verify-recipes.json next to this file and land only by PR (claude-code-skills#478). Kinds:
  network    the values are pasted (a hidden prompt each, or one per stdin line) and sent to the recipe's https host.
             The same request with one value replaced by a random string is the negative control: it must answer
             differently, so each run proves the endpoint tells a right value from a wrong one. Nothing in argv: the
             URL, the headers and the body go to curl through a 0600 config file.
  generated  the value is made here (CSPRNG) and never shown. With keep=bitwarden it is first written to the env
             ledger (Bitwarden item env/<environment>/<NAME>) and read back equal, because someone else needs it.
  consumer   the consumer's own generator and check, run in its checkout, decide the value (cor-os#126). A missing
             command refuses.
Exit codes: 0 stored (or verified with --dry-run), 1 refused, 2 usage, 3 gh or Bitwarden failed, 4 stored but the
readback is missing or stale. Every outcome but a usage error is a guard-ledger row; no row carries a value.
"""
import base64
import getpass
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
RECIPES = os.path.join(HERE, "secret-verify-recipes.json")
NAME_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class Refused(Exception):
    def __init__(self, code, rule, message):
        super().__init__(message)
        self.code, self.rule, self.message = code, rule, message


def usage(message):
    raise Refused(2, "", "register-secret-verified: " + message)


class Run:
    def __init__(self, argv):
        self.ledger_lib = ""
        self.recipe_name = ""
        self.names, self.repo, self.env, self.params = [], "", "", {}
        self.repo_dir, self.keep_item, self.dry = "", "", False
        self.detail = ""
        self.parse(argv)

    def parse(self, argv):
        args = list(argv)
        positional = []
        while args:
            a = args.pop(0)
            if a in ("--ledger-lib", "--recipe", "--env", "--param", "--repo-dir", "--keep-in-bitwarden"):
                if not args:
                    usage(a + " needs a value")
                v = args.pop(0)
                if a == "--ledger-lib":
                    self.ledger_lib = v
                elif a == "--recipe":
                    self.recipe_name = v
                elif a == "--env":
                    self.env = v
                elif a == "--param":
                    if "=" not in v:
                        usage("--param needs k=v")
                    k, val = v.split("=", 1)
                    self.params[k] = val
                elif a == "--repo-dir":
                    self.repo_dir = v
                else:
                    self.keep_item = v
            elif a == "--dry-run":
                self.dry = True
            elif a.startswith("-"):
                usage("unknown argument: " + a)
            else:
                positional.append(a)
        repos = [p for p in positional if "/" in p]
        self.names = [p for p in positional if "/" not in p]
        if len(repos) != 1 or not REPO_RE.match(repos[0]):
            usage("give exactly one <owner/repo>")
        self.repo = repos[0]
        bad = [n for n in self.names if not NAME_RE.match(n)]
        if bad or not self.names:
            usage("secret names must be UPPER_SNAKE: %s" % (" ".join(bad) or "(none)"))
        try:
            book = json.load(open(RECIPES, encoding="utf-8"))["recipes"]
        except (OSError, ValueError, KeyError) as exc:
            usage("cannot read the recipe file %s: %s" % (RECIPES, exc))
        if self.recipe_name not in book:
            usage("unknown recipe %r; the reviewed recipes are: %s" % (self.recipe_name, ", ".join(sorted(book))))
        self.recipe = book[self.recipe_name]
        roles = self.recipe["values"]
        if len(self.names) != len(roles):
            usage("recipe %s takes %d secret names (%s), got %d" % (
                self.recipe_name, len(roles), ", ".join(roles), len(self.names)))
        fixed = self.recipe.get("names")
        if fixed and fixed != self.names:
            usage("recipe %s is for %s only" % (self.recipe_name, " ".join(fixed)))
        for p in self.recipe.get("params", []):
            if not self.params.get(p):
                usage("recipe %s needs --param %s=<value>" % (self.recipe_name, p))

    # --- ledger ------------------------------------------------------------------------------------------------
    def ledger(self, decision, rule):
        if not self.ledger_lib or not os.path.isfile(self.ledger_lib):
            return
        head = "register-secret-verified --recipe %s %s %s%s" % (
            self.recipe_name, " ".join(self.names), self.repo, " --env " + self.env if self.env else "")
        row = {"component": "secret-register", "hook": "register-secret-verified",
               "event": "block" if decision == "deny" else "measure", "decision": decision,
               "rule": "recipe-%s-%s" % (self.recipe_name, rule), "cmd_head": head}
        if self.detail:
            row["detail"] = self.detail
        subprocess.run(["bash", "-c", '. "$1" && aidd_ledger_append_record "$2" "${3:-claude-code}"', "_",
                        self.ledger_lib, json.dumps(row, separators=(",", ":")),
                        os.environ.get("AIDD_LEDGER_AGENT", "claude-code")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    # --- values ------------------------------------------------------------------------------------------------
    def read_values(self):
        roles = self.recipe["values"]
        if sys.stdin.isatty():
            values = [getpass.getpass("Paste %s (%s) and press Enter (input is not shown): " % (n, r)).strip()
                      for n, r in zip(self.names, roles)]
        else:
            lines = sys.stdin.read().splitlines()
            while lines and not lines[-1].strip():
                lines.pop()
            if len(lines) != len(roles):
                raise Refused(1, "values-count", "NG: recipe %s reads %d lines from stdin (%s), got %d; nothing was "
                              "stored." % (self.recipe_name, len(roles), " / ".join(self.names), len(lines)))
            values = [ln.strip() for ln in lines]
        for n, v in zip(self.names, values):
            if not v:
                raise Refused(1, "empty", "NG: %s is empty; nothing was stored." % n)
            if any(c in v for c in "\r\n"):
                raise Refused(1, "multi-line", "NG: %s has a line break inside; nothing was stored." % n)
        return dict(zip(roles, values))


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(data)


def curl_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def substitute(text, values, rnd):
    def repl(m):
        key = m.group(1)
        if key == "random":
            return rnd
        return urllib.parse.quote(values[key], safe="") if key in values else m.group(0)
    return re.sub(r"\{([a-z_]+)\}", repl, text)


def matches(cond, status, doc):
    if "status" in cond and status != cond["status"]:
        return False
    for k, v in cond.get("json", {}).items():
        if not isinstance(doc, dict) or doc.get(k) != v:
            return False
    return True


def observed(status, doc):
    err = doc.get("error") if isinstance(doc, dict) else None
    return "status=%s%s" % (status, " error=%s" % err if isinstance(err, str) else "")


class Network:
    def __init__(self, run, work):
        self.run, self.work, self.n = run, work, 0

    def hosts(self):
        req = self.run.recipe["request"]
        host = urllib.parse.urlsplit(req["url"].replace("{", "").replace("}", "")).hostname or ""
        scheme = urllib.parse.urlsplit(req["url"]).scheme
        if scheme != "https" or host not in self.run.recipe["hosts"]:
            raise Refused(1, "recipe-host", "NG: recipe %s points at %s://%s, outside its hosts; nothing was sent."
                          % (self.run.recipe_name, scheme, host))
        return host

    def ask(self, values):
        """One request with <values>; returns (status, json doc or None)."""
        self.n += 1
        req = self.run.recipe["request"]
        rnd = secrets.token_hex(16)
        url = substitute(req["url"], values, rnd)
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != "https" or parts.hostname not in self.run.recipe["hosts"]:
            raise Refused(1, "recipe-host", "NG: the request left the recipe's hosts; nothing was stored.")
        cfg, body, answer = (os.path.join(self.work, "%s%d" % (k, self.n)) for k in ("curl", "body", "answer"))
        lines = ["url = " + curl_quote(url), "request = " + curl_quote(req.get("method", "GET")),
                 "output = " + curl_quote(answer), "write-out = " + curl_quote("%{http_code}")]
        if req.get("basic"):
            user, pw = (values[r] for r in req["basic"])
            token = base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()
            lines.append("header = " + curl_quote("Authorization: Basic " + token))
        for h in req.get("headers", []):
            lines.append("header = " + curl_quote(h))
        if "json_body" in req:
            payload = json.loads(substitute(json.dumps(req["json_body"]), values, rnd))
            write_private(body, json.dumps(payload))
            lines += ["header = " + curl_quote("Content-Type: application/json"), "data-binary = " + curl_quote("@" + body)]
        elif "form" in req:
            form = {k: substitute(v, values, rnd) for k, v in req["form"].items()}
            write_private(body, urllib.parse.urlencode(form))
            lines.append("data-binary = " + curl_quote("@" + body))
        write_private(cfg, "\n".join(lines) + "\n")
        p = subprocess.run(["curl", "-q", "-sS", "--proto", "=https", "--proto-redir", "=https", "--max-time", "20",
                            "-K", cfg], capture_output=True, text=True, check=False)
        try:
            status = int((p.stdout or "0").strip()[-3:])
        except ValueError:
            status = 0
        doc = None
        try:
            with open(answer, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            pass
        for f in (cfg, body, answer):
            if os.path.exists(f):
                os.unlink(f)
        if p.returncode != 0:
            raise Refused(1, "unreachable", "NG: curl rc=%d to %s; nothing was stored." % (p.returncode, parts.hostname))
        return status, doc

    def verify(self, values):
        rec = self.run.recipe
        status, doc = self.ask(values)
        real = observed(status, doc)
        control = dict(values)
        control[rec["control"]["replace"]] = secrets.token_urlsafe(24)
        cstatus, cdoc = self.ask(control)
        ctrl = observed(cstatus, cdoc)
        self.run.detail = "real %s; control %s" % (real, ctrl)
        if not matches(rec["pass"], status, doc):
            raise Refused(1, "unverified", "NG: %s did not answer as a valid pair (%s; control %s); nothing was stored."
                          % (self.run.recipe_name, real, ctrl))
        c = rec["control"]
        ok = (not matches(c["fail_unless_not"], cstatus, cdoc)) if "fail_unless_not" in c else matches(
            c["fail_unless"], cstatus, cdoc)
        if not ok:
            raise Refused(1, "control-failed", "NG: the negative control (a wrong %s) answered %s, which does not tell "
                          "it from the real value (%s); the endpoint does not discriminate, nothing was stored."
                          % (c["replace"], ctrl, real))
        print("VERIFIED %s: real %s, control %s" % (self.run.recipe_name, real, ctrl))


def bw_session():
    p = subprocess.run(["security", "find-generic-password", "-a", os.environ.get("USER", ""), "-s", "bw-session",
                        "-w"], capture_output=True, text=True, check=False)
    session = p.stdout.strip()
    if not session:
        raise Refused(3, "bitwarden-locked", "NG: no Bitwarden session in the keychain (bw-session); unlock first: "
                      "see AGENTS.md (bwenv). Nothing was generated.")
    env = dict(os.environ, BW_SESSION=session)
    st = subprocess.run(["bw", "status"], capture_output=True, text=True, env=env, check=False)
    try:
        if json.loads(st.stdout).get("status") != "unlocked":
            raise ValueError
    except ValueError:
        raise Refused(3, "bitwarden-locked", "NG: Bitwarden is not unlocked; nothing was generated.") from None
    return env


def bw_field(item, name):
    for f in item.get("fields") or []:
        if f.get("name") == name:
            return f.get("value")
    return None


def keep_in_bitwarden(run, name, value):
    item_name = run.keep_item
    m = re.match(r"^env/([A-Za-z0-9._-]+)/%s$" % re.escape(name), item_name or "")
    if not m:
        raise Refused(2, "", "register-secret-verified: recipe %s needs --keep-in-bitwarden env/<environment>/%s"
                      % (run.recipe_name, name))
    env = bw_session()
    listed = subprocess.run(["bw", "list", "items", "--search", name], capture_output=True, text=True, env=env,
                            check=False)
    try:
        existing = [i for i in json.loads(listed.stdout or "[]") if bw_field(i, "_bw.variable") == name
                    or i.get("name") == item_name]
    except ValueError:
        raise Refused(3, "bitwarden-failed", "NG: could not list Bitwarden items; nothing was stored.") from None
    if existing:
        raise Refused(1, "bitwarden-exists", "NG: the env ledger already has %s (%d item); rotating is a separate "
                      "step. Nothing was stored." % (name, len(existing)))
    item = {"type": 1, "name": item_name, "favorite": False, "reprompt": 0, "notes": None, "passwordHistory": [],
            "fields": [{"type": 0, "name": "_bw.variable", "value": name},
                       {"type": 0, "name": "_bw.environment", "value": m.group(1)},
                       {"type": 0, "name": "_bw.service", "value": run.repo.split("/", 1)[1]},
                       {"type": 1, "name": "value", "value": value}]}
    encoded = base64.b64encode(json.dumps(item).encode()).decode()
    made = subprocess.run(["bw", "create", "item"], input=encoded, capture_output=True, text=True, env=env, check=False)
    try:
        item_id = json.loads(made.stdout)["id"]
    except (ValueError, KeyError, TypeError):
        raise Refused(3, "bitwarden-failed", "NG: bw create item failed (rc=%d); nothing was stored." % made.returncode) \
            from None
    back = subprocess.run(["bw", "get", "item", item_id], capture_output=True, text=True, env=env, check=False)
    try:
        same = bw_field(json.loads(back.stdout), "value") == value
    except ValueError:
        same = False
    if not same:
        raise Refused(3, "bitwarden-readback", "NG: the Bitwarden item %s (%s) did not read back equal; GitHub was "
                      "not touched. Delete or fix that item by hand." % (item_name, item_id))
    print("KEPT %s in Bitwarden as %s (read back equal)" % (name, item_name))


def generated(run):
    rec = run.recipe
    gen = rec["generate"]
    if gen.get("type") != "token_urlsafe":
        raise Refused(1, "recipe-invalid", "NG: unknown generator %r" % gen.get("type"))
    if rec.get("keep") == "bitwarden" and not run.keep_item:
        raise Refused(2, "", "register-secret-verified: recipe %s needs --keep-in-bitwarden env/<environment>/%s"
                      % (run.recipe_name, run.names[0]))
    if rec.get("keep") == "bitwarden" and not run.dry:
        bw_session()  # refuse before making a value nobody can keep (a dry run keeps nothing)
    value = secrets.token_urlsafe(int(gen["bytes"]))
    chk = rec.get("check", {})
    if (chk.get("no_whitespace") and re.search(r"\s", value)) or len(value.encode()) > int(chk.get("max_bytes", 1 << 30)):
        raise Refused(1, "unverified", "NG: the generated value fails the consumer's rules; nothing was stored.")
    return {rec["values"][0]: value}


def consumer(run, work):
    rec = run.recipe
    repo_dir = os.path.abspath(run.repo_dir) if run.repo_dir else ""
    if not repo_dir or not os.path.isfile(os.path.join(repo_dir, rec["repo_marker"])):
        raise Refused(2, "", "register-secret-verified: recipe %s needs --repo-dir <the consumer checkout with %s>"
                      % (run.recipe_name, rec["repo_marker"]))
    head = subprocess.run(["git", "-C", repo_dir, "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
    commit = head.stdout.strip()[:12]
    if head.returncode != 0 or not commit:
        raise Refused(1, "consumer-checkout", "NG: %s is not a git checkout; nothing was stored." % repo_dir)
    run.detail = "consumer %s@%s" % (os.path.basename(repo_dir), commit)
    cmd = list(rec["generate_cmd"])
    for k in rec.get("params", []):
        cmd = [a.replace("{%s}" % k, run.params[k]) for a in cmd]
    out = os.path.join(work, "generated")
    with open(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as fh:
        gen = subprocess.run(cmd, cwd=repo_dir, stdout=fh, stderr=subprocess.PIPE, text=True, check=False)
    if gen.returncode != 0:
        tail = (gen.stderr or "").strip().splitlines()[-1:] or [""]
        raise Refused(1, "consumer-generate", "NG: the consumer's generator failed (rc=%d at %s: %s); nothing was "
                      "stored. cor-os needs this command (cor-os#126)." % (gen.returncode, commit, tail[0][:160]))
    value = open(out, encoding="utf-8").read()
    if value.endswith("\n"):
        value = value[:-1]
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(value)
    with open(out, encoding="utf-8") as fh:
        chk = subprocess.run(rec["check_cmd"], cwd=repo_dir, stdin=fh, capture_output=True, text=True, check=False)
    if chk.returncode != 0:
        tail = (chk.stderr or chk.stdout or "").strip().splitlines()[-1:] or [""]
        raise Refused(1, "consumer-check", "NG: the consumer's check refused the value (rc=%d at %s: %s); nothing was "
                      "stored." % (chk.returncode, commit, tail[0][:160]))
    print("VERIFIED %s: the consumer's check passed at %s" % (run.recipe_name, commit))
    return {rec["values"][0]: value}


def store(run, values, work):
    envargs = ["--env", run.env] if run.env else []
    stored = []
    for name, role in zip(run.names, run.recipe["values"]):
        path = os.path.join(work, "set-" + name)
        write_private(path, values[role])
        with open(path, encoding="utf-8") as fh:
            p = subprocess.run(["gh", "secret", "set", name, "--repo", run.repo] + envargs, stdin=fh,
                               capture_output=True, text=True, check=False)
        os.unlink(path)
        if p.returncode != 0:
            raise Refused(3, "set-failed", "NG: gh secret set failed for %s in %s (stored before it: %s)."
                          % (name, run.repo, ", ".join(stored) or "none"))
        stored.append(name)
    listing = subprocess.run(["gh", "secret", "list", "--repo", run.repo] + envargs + ["--json", "name,updatedAt"],
                             capture_output=True, text=True, check=False)
    try:
        rows = {s["name"]: s["updatedAt"] for s in json.loads(listing.stdout or "[]")}
    except (ValueError, KeyError, TypeError):
        rows = {}
    stale = []
    for name in run.names:
        at = rows.get(name)
        try:
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(at.replace("Z", "+00:00"))).total_seconds()
        except (AttributeError, ValueError):
            age = None
        if age is None or age >= 300:
            stale.append("%s=%s" % (name, at or "missing"))
    if stale:
        raise Refused(4, "readback-stale", "NG: sent to gh, but the readback is %s; check `gh secret list --repo %s`."
                      % (", ".join(stale), run.repo))
    print("REGISTERED: %s in %s%s" % (", ".join(run.names), run.repo, " (environment %s)" % run.env if run.env else ""))


def main(argv):
    try:
        run = Run(argv)
    except Refused as r:
        print(r.message, file=sys.stderr)
        return r.code
    work = tempfile.mkdtemp(prefix="register-secret.")
    try:
        kind = run.recipe["kind"]
        if kind == "network":
            net = Network(run, work)
            print("The values of %s will be sent to: %s" % (", ".join(run.names), net.hosts()), file=sys.stderr)
            values = run.read_values()
            net.verify(values)
        elif kind == "generated":
            values = generated(run)
        elif kind == "consumer":
            values = consumer(run, work)
        else:
            raise Refused(1, "recipe-invalid", "NG: recipe %s has an unknown kind %r" % (run.recipe_name, kind))
        if run.dry:
            run.ledger("allow", "dry-run-verified")
            print("DRY RUN: %s were not stored." % ", ".join(run.names))
            return 0
        if run.recipe.get("keep") == "bitwarden":
            keep_in_bitwarden(run, run.names[0], values[run.recipe["values"][0]])
        store(run, values, work)
        run.ledger("allow", "registered")
        return 0
    except Refused as r:
        if r.rule:
            run.ledger("warn" if r.code == 4 else "deny", r.rule)
        print(r.message, file=sys.stderr)
        return r.code
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
