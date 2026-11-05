"""register-secret-verified.sh --recipe: check secrets with a reviewed recipe, then store them as GitHub secrets.

usage (through the wrapper; the wrapper passes the ledger library in AIDD_SECRET_LEDGER_LIB):
  register-secret-verified.sh --recipe <name> <NAME>... <owner/repo> [--env <environment>] [--param k=v]...
      [--repo-dir <consumer checkout>] [--keep-in-bitwarden env/<environment>/<NAME>] [--resume-from-bitwarden]
      [--dry-run]

Recipes live in secret-verify-recipes.json next to this file and land only by PR (claude-code-skills#478). Kinds:
  network    the values are pasted (a hidden prompt each, or one per stdin line) and sent to the recipe's https host.
             The same request with one value replaced by a random string is the negative control: it must answer
             differently, so each run proves the endpoint tells a right value from a wrong one. An answer that is not
             a definite one (no answer, 403, 429, 5xx, or a body that is not a JSON object) refuses as inconclusive:
             a transient error must never stand in for the control (#479 review). Nothing in argv: the URL, the
             headers and the body go to curl through a 0600 config file.
  generated  the value is made here (CSPRNG) and never shown. With keep=bitwarden it is first written to the env
             ledger (Bitwarden item env/<environment>/<NAME>) and read back equal, because someone else needs it.
             The item is created with _bw.status=unverified and set to active only after that readback (#480).
             If GitHub then fails, --resume-from-bitwarden stores that same copy instead of making a new one; it
             takes only an active item whose path, _bw.environment, _bw.variable and _bw.service all match and
             whose value has the generator's shape. Without --env the item path chosen by the operator decides
             the environment. keep is allowed only on a generated recipe with one value.
  consumer   the consumer's own generator and check, run in its checkout, decide the value (cor-os#126). A missing
             command refuses.
  slack-oauth-code  a new, operator-approved temporary user grant; wrong-secret control first, then real code
             exchange, exact app/team/user/scope, and token revocation before storage. Hidden terminal input only.
  access-service-token  read back the fixed Access app/policy, rotate its existing service token with the old
             expiry preserved, and require three wrong-secret controls and three real origin probes before storage.
             --dry-run is read-only preflight, not evidence of a generated or verified pair.
Exit codes: 0 stored (or verified with --dry-run), 1 refused, 2 usage, 3 gh or Bitwarden failed, 4 stored but the
readback is missing or stale. Every outcome but a usage error is a guard-ledger row; no row carries a value.
"""
import base64
import getpass
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import urllib.parse
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
# -I excludes the script directory too. Load only this reviewed sibling, never cwd/PYTHONPATH.
_slack_spec = importlib.util.spec_from_file_location("slack_oauth_code", os.path.join(HERE, "slack_oauth_code.py"))
_slack_code = importlib.util.module_from_spec(_slack_spec)
_slack_spec.loader.exec_module(_slack_code)
RECIPES = os.path.join(HERE, "secret-verify-recipes.json")
NAME_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
KEEP_RE = re.compile(r"^env/([A-Za-z0-9._-]+)/([A-Z_][A-Z0-9_]*)$")
CONDITION_KEYS = {"status", "json"}
# bwenv lists _bw.status; the env ledger already uses "unverified" and "active" (ENV-INDEX.md, #480)
BW_UNVERIFIED, BW_ACTIVE = "unverified", "active"


class Refused(Exception):
    def __init__(self, code, rule, message):
        super().__init__(message)
        self.code, self.rule, self.message = code, rule, message


def usage(message):
    raise Refused(2, "", "register-secret-verified: " + message)


def check_condition(cond, where):
    """A pass / control condition: a non-empty object of status and/or a non-empty json map, nothing else."""
    if (not isinstance(cond, dict) or not cond or set(cond) - CONDITION_KEYS
            or ("json" in cond and (not isinstance(cond["json"], dict) or not cond["json"]))
            or ("status" in cond and not isinstance(cond["status"], int))):
        raise Refused(1, "recipe-invalid", "NG: the recipe's %s condition %r is empty or has unknown keys; nothing "
                      "was sent." % (where, cond))


class Run:
    def __init__(self, argv):
        self.ledger_lib = os.environ.get("AIDD_SECRET_LEDGER_LIB", "")
        self.recipe_name = ""
        self.names, self.repo, self.env, self.params = [], "", "", {}
        self.repo_dir, self.keep_item, self.dry, self.resume = "", "", False, False
        self.detail = ""
        self.created = None  # (item name, item id) once a Bitwarden item exists, verified or not
        self.kept = None  # (item name, item id) once that item read back equal (or a resume read a valid copy)
        self.parse(argv)

    def parse(self, argv):
        args = list(argv)
        positional = []
        while args:
            a = args.pop(0)
            if a in ("--recipe", "--env", "--param", "--repo-dir", "--keep-in-bitwarden"):
                if not args:
                    usage(a + " needs a value")
                v = args.pop(0)
                if a == "--recipe":
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
            elif a == "--resume-from-bitwarden":
                self.resume = True
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
            with open(RECIPES, encoding="utf-8") as source:
                book = json.load(source)["recipes"]
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
        # a recipe that declares its repository is for that repository only; no argument widens it (#479 review 3)
        declared = self.recipe.get("repo")
        if declared and declared != self.repo:
            usage("recipe %s is for %s only, not %s" % (self.recipe_name, declared, self.repo))
        self.service = (declared or self.repo).split("/", 1)[1]
        for p in self.recipe.get("params", []):
            if not self.params.get(p):
                usage("recipe %s needs --param %s=<value>" % (self.recipe_name, p))
        keep = self.recipe.get("keep")
        if self.resume and keep != "bitwarden":
            usage("--resume-from-bitwarden is only for a recipe that keeps a Bitwarden copy")
        kept_path = KEEP_RE.match(self.keep_item or "")
        if kept_path and self.env and kept_path.group(1) != self.env:
            # refuse before a value is made: the create path would write an item resume can never take (#480)
            usage("--env %s does not match the Bitwarden item %s (environment %s); nothing was generated"
                  % (self.env, self.keep_item, kept_path.group(1)))
        if self.recipe["kind"] == "access-service-token":
            if self.env or self.keep_item or self.repo_dir or self.resume:
                usage("access-service-token only registers the fixed repository-level pair")
            operation = self.recipe.get("operation", "rotate")
            if operation == "recover":
                if set(self.params) != {"recovery-dir"} or not self.params["recovery-dir"]:
                    usage("access-service-token recovery requires only --param recovery-dir=<private-directory>")
            elif operation != "rotate":
                usage("access-service-token operation is not reviewed")
            elif set(self.params) != {"rotate-confirmed"} or self.params["rotate-confirmed"] != "yes":
                usage("access-service-token requires only --param rotate-confirmed=yes")

    def check_keep(self):
        """keep=bitwarden only on a generated recipe with one value: a kept copy of a network or consumer value
        would be resumed without its check (#480). Called in main, so the refusal is a ledger row."""
        rec = self.recipe
        if "keep" in rec and (rec["keep"] != "bitwarden" or rec.get("kind") != "generated"
                              or len(rec.get("values") or []) != 1):
            raise Refused(1, "recipe-invalid", "NG: recipe %s keeps a copy (keep=%r), but keep=bitwarden is only "
                          "for a generated recipe with one value; nothing was sent." % (self.recipe_name, rec["keep"]))

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
        return dict(zip(roles, values))


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data.encode("utf-8") if isinstance(data, str) else data)


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


def inconclusive(status, doc):
    """No definite answer: nothing came back, a rate limit or a server error, or a body that is not a JSON object."""
    return status == 0 or status in (403, 429) or status >= 500 or not isinstance(doc, dict)


class Network:
    def __init__(self, run, work):
        self.run, self.work, self.n = run, work, 0
        rec = run.recipe
        check_condition(rec.get("pass"), "pass")
        ctrl = rec.get("control") or {}
        if ctrl.get("replace") not in rec["values"] or len(set(ctrl) & {"fail_unless", "fail_unless_not"}) != 1:
            raise Refused(1, "recipe-invalid", "NG: recipe %s has no negative control on one of its values."
                          % run.recipe_name)
        check_condition(ctrl.get("fail_unless", ctrl.get("fail_unless_not")), "control")

    def hosts(self):
        req = self.run.recipe["request"]
        host = urllib.parse.urlsplit(req["url"].replace("{", "").replace("}", "")).hostname or ""
        scheme = urllib.parse.urlsplit(req["url"]).scheme
        if scheme != "https" or host not in self.run.recipe["hosts"]:
            raise Refused(1, "recipe-host", "NG: recipe %s points at %s://%s, outside its hosts; nothing was sent."
                          % (self.run.recipe_name, scheme, host))
        return host

    def ask(self, values, *, request=None, form=None, received=None):
        """One request with <values>; returns (status, json doc or None)."""
        self.n += 1
        req = self.run.recipe["request"] if request is None else request
        rnd = secrets.token_hex(16)
        url = substitute(req["url"], values, rnd)
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != "https" or parts.hostname not in self.run.recipe["hosts"]:
            raise Refused(1, "recipe-host", "NG: the request left the recipe's hosts; nothing was stored.")
        cfg, body, answer = (os.path.join(self.work, "%s%d" % (k, self.n)) for k in ("curl", "body", "answer"))
        lines = ["url = " + curl_quote(url), "request = " + curl_quote(req.get("method", "GET")),
                 "output = " + curl_quote(answer), "write-out = " + curl_quote("%{http_code}"), "globoff"]
        if req.get("basic"):
            user, pw = (values[r] for r in req["basic"])
            token = base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()
            lines.append("header = " + curl_quote("Authorization: Basic " + token))
        for h in req.get("headers", []):
            lines.append("header = " + curl_quote(h))
        if "json_body" in req:
            payload = json.loads(substitute(json.dumps(req["json_body"]), {}, rnd))
            write_private(body, json.dumps(payload))
            lines += ["header = " + curl_quote("Content-Type: application/json"), "data-binary = " + curl_quote("@" + body)]
        elif form is not None or "form" in req:
            payload = form if form is not None else {k: substitute(v, {}, rnd) for k, v in req["form"].items()}
            write_private(body, urllib.parse.urlencode(payload))
            lines.append("data-binary = " + curl_quote("@" + body))
        write_private(cfg, "\n".join(lines) + "\n")
        try:
            p = subprocess.run(["curl", "-q", "-sS", "--proto", "=https", "--proto-redir", "=https", "--max-time", "20",
                                "-K", cfg], capture_output=True, text=True, check=False)
        finally:
            for f in (cfg, body):
                if os.path.exists(f):
                    os.unlink(f)
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
        if received is not None:
            received(doc)
        if os.path.exists(answer):
            os.unlink(answer)
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
        if inconclusive(status, doc) or inconclusive(cstatus, cdoc):
            raise Refused(1, "inconclusive", "NG: %s got an answer that is not a definite one (%s; control %s): a "
                          "rate limit, a server error or a non-JSON body. Nothing was stored; run it again later."
                          % (self.run.recipe_name, real, ctrl))
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
    except (ValueError, AttributeError, TypeError):
        raise Refused(3, "bitwarden-locked", "NG: Bitwarden is not unlocked; nothing was generated.") from None
    return env


def bw_field(item, name):
    for f in (item.get("fields") if isinstance(item, dict) else None) or []:
        if isinstance(f, dict) and f.get("name") == name:
            return f.get("value")
    return None


def bw_ledger_items(env, name, item_name):
    """Every env-ledger item for <name>, read after a sync and searched the way bwenv searches (env/, then fields)."""
    sync = subprocess.run(["bw", "sync"], capture_output=True, text=True, env=env, check=False)
    if sync.returncode != 0:
        raise Refused(3, "bitwarden-failed", "NG: bw sync failed (rc=%d); nothing was stored." % sync.returncode)
    listed = subprocess.run(["bw", "list", "items", "--search", "env/"], capture_output=True, text=True, env=env,
                            check=False)
    try:
        if listed.returncode != 0 or not listed.stdout.strip():
            raise ValueError
        items = json.loads(listed.stdout)
        if not isinstance(items, list):
            raise ValueError
    except ValueError:
        raise Refused(3, "bitwarden-failed", "NG: could not list the env ledger (rc=%d); nothing was stored."
                      % listed.returncode) from None
    return [i for i in items if isinstance(i, dict)
            and (bw_field(i, "_bw.variable") == name or i.get("name") == item_name)]


def bw_read(env, item_id):
    """(item, its value field) as `bw get item` returns it; (None, None) when the answer is not an item."""
    got = subprocess.run(["bw", "get", "item", item_id], capture_output=True, text=True, env=env, check=False)
    try:
        item = json.loads(got.stdout)
    except ValueError:
        return None, None
    return (item, bw_field(item, "value")) if isinstance(item, dict) else (None, None)


def mark_active(env, item, item_name, item_id, value):
    """Set _bw.status=active on a copy that read back equal, then read it back again (#480)."""
    fields = [dict(f, value=BW_ACTIVE) if isinstance(f, dict) and f.get("name") == "_bw.status" else f
              for f in item.get("fields") or []]
    encoded = base64.b64encode(json.dumps(dict(item, fields=fields)).encode()).decode()
    edit = subprocess.run(["bw", "edit", "item", item_id], input=encoded, capture_output=True, text=True, env=env,
                          check=False)
    after, kept = bw_read(env, item_id)
    status = bw_field(after, "_bw.status")
    if edit.returncode != 0 or kept != value or status != BW_ACTIVE:
        same = "unreadable" if not isinstance(kept, str) else ("equal" if kept == value else "different")
        if same != "equal" and status == BW_ACTIVE:
            # an active item whose value changed must not be resumable (#480 review 2): mark it unverified again
            back = [dict(f, value=BW_UNVERIFIED) if isinstance(f, dict) and f.get("name") == "_bw.status" else f
                    for f in after.get("fields") or []]
            subprocess.run(["bw", "edit", "item", item_id], capture_output=True, text=True, env=env, check=False,
                           input=base64.b64encode(json.dumps(dict(after, fields=back)).encode()).decode())
            status = bw_field(bw_read(env, item_id)[0], "_bw.status")
        step = ("Set _bw.status=active on it by hand, then re-run with --resume-from-bitwarden." if same == "equal"
                else "Delete that item by hand and run again without --resume-from-bitwarden; do not resume it.")
        raise Refused(3, "bitwarden-status", "NG: the Bitwarden item %s (%s) read back equal, but marking it %s "
                      "did not hold: bw edit rc=%d, _bw.status now %s, value now %s. GitHub was not touched. %s" % (
                          item_name, item_id, BW_ACTIVE, edit.returncode, status, same, step))


def next_step(status, name, repo):
    """What to do with an existing ledger item, by its _bw.status (#480 reviews). Never deletion by default: the
    item may be the copy the administrator uses, and a new value would overwrite the GitHub secret."""
    check = "`gh secret list --repo %s --json name,updatedAt` for %s" % (repo, name)
    if status == BW_ACTIVE:
        return ("If an earlier run kept it and GitHub failed (see %s), re-run the same command with "
                "--resume-from-bitwarden." % check)
    if status == BW_UNVERIFIED:
        return ("It was not marked active. If the run that made it printed 'did not read back equal', delete that "
                "item by hand and run again without --resume-from-bitwarden. If it printed 'marking it active did "
                "not hold ... value now equal', set _bw.status=active on it by hand and re-run with "
                "--resume-from-bitwarden.")
    return ("It has no _bw.status (an item made before #480, or by hand). Do not delete it: it may be the copy the "
            "administrator uses. Check %s: if GitHub has it, nothing is left to do. If GitHub does not have it "
            "and the run that made the item printed 'KEPT ... (read back equal ...)', set _bw.status=active on it "
            "by hand and re-run with --resume-from-bitwarden. Rotating the value is a separate step." % check)


def keep_in_bitwarden(run, name, value):
    item_name = run.keep_item
    m = re.match(r"^env/([A-Za-z0-9._-]+)/%s$" % re.escape(name), item_name or "")
    if not m:
        raise Refused(2, "", "register-secret-verified: recipe %s needs --keep-in-bitwarden env/<environment>/%s"
                      % (run.recipe_name, name))
    env = bw_session()
    existing = bw_ledger_items(env, name, item_name)
    if run.resume:
        if len(existing) != 1 or existing[0].get("name") != item_name:
            raise Refused(1, "bitwarden-resume", "NG: --resume-from-bitwarden needs exactly one item %s (found %d); "
                          "nothing was stored." % (item_name, len(existing)))
        # the field must agree with the item's own path, not only with --env (#480): without --env a copy whose
        # field names another environment would otherwise resume into the repository-level secret
        if bw_field(existing[0], "_bw.variable") != name or bw_field(existing[0], "_bw.service") != run.service or (
                bw_field(existing[0], "_bw.environment") != m.group(1)) or (
                run.env and bw_field(existing[0], "_bw.environment") != run.env):
            raise Refused(1, "bitwarden-resume", "NG: the item %s is for _bw.variable=%s, _bw.service=%s, "
                          "_bw.environment=%s, not %s of %s in %s; nothing was stored." % (
                              item_name, bw_field(existing[0], "_bw.variable"), bw_field(existing[0], "_bw.service"),
                              bw_field(existing[0], "_bw.environment"), name, run.service, run.env or m.group(1)))
        if bw_field(existing[0], "_bw.status") != BW_ACTIVE:
            # a copy whose readback never matched stays unverified; only a checked copy may reach GitHub (#480)
            raise Refused(1, "bitwarden-resume-unverified", "NG: the item %s has _bw.status=%s, not %s; nothing was "
                          "stored. A copy this tool makes is set active only after it read back equal, and an item "
                          "marked active by hand is taken as checked by whoever marked it. %s" % (
                              item_name, bw_field(existing[0], "_bw.status"), BW_ACTIVE,
                              next_step(bw_field(existing[0], "_bw.status"), name, run.repo)))
        got = subprocess.run(["bw", "get", "item", existing[0].get("id", "")], capture_output=True, text=True, env=env,
                             check=False)
        try:
            kept = bw_field(json.loads(got.stdout), "value")
        except ValueError:
            kept = None
        if not isinstance(kept, str) or not kept:
            raise Refused(3, "bitwarden-readback", "NG: could not read %s back from Bitwarden; nothing was stored."
                          % item_name)
        if not passes_check(run.recipe, kept):
            raise Refused(1, "bitwarden-resume-check", "NG: the Bitwarden copy %s (length %d) fails the recipe's "
                          "check; nothing was stored. Fix that item in Bitwarden by hand first." % (item_name, len(kept)))
        if not generated_shape(run.recipe, kept):
            raise Refused(1, "bitwarden-resume-shape", "NG: the Bitwarden copy %s (length %d) is not the shape the "
                          "recipe's generator makes (%s); nothing was stored." % (
                              item_name, len(kept), shape_text(run.recipe)))
        run.kept = (item_name, existing[0].get("id", ""))
        run.detail = "bitwarden %s resumed, length %d" % (item_name, len(kept))
        print("RESUMED %s from Bitwarden %s (length %d)" % (name, item_name, len(kept)))
        return kept
    if existing:
        statuses = ", ".join("%s (_bw.status=%s)" % (i.get("name"), bw_field(i, "_bw.status")) for i in existing)
        if len(existing) != 1:
            hint = "Leave exactly one item for %s by hand first." % name
        elif existing[0].get("name") != item_name:
            hint = ("The existing item is %s, not %s: name that path with --keep-in-bitwarden if it is the copy you "
                    "mean, or leave it." % (existing[0].get("name"), item_name))
        else:
            hint = next_step(bw_field(existing[0], "_bw.status"), name, run.repo)
        raise Refused(1, "bitwarden-exists", "NG: the env ledger already has %s: %s. Rotating is a separate step. "
                      "%s Nothing was stored." % (name, statuses, hint))
    item = {"type": 1, "name": item_name, "favorite": False, "reprompt": 0, "notes": None, "passwordHistory": [],
            "fields": [{"type": 0, "name": "_bw.variable", "value": name},
                       {"type": 0, "name": "_bw.environment", "value": m.group(1)},
                       {"type": 0, "name": "_bw.service", "value": run.service},
                       {"type": 0, "name": "_bw.status", "value": BW_UNVERIFIED},
                       {"type": 1, "name": "value", "value": value}]}
    encoded = base64.b64encode(json.dumps(item).encode()).decode()
    run.creating = item_name  # a signal from here on may leave an unverified item (#480 review)
    made = subprocess.run(["bw", "create", "item"], input=encoded, capture_output=True, text=True, env=env, check=False)
    try:
        item_id = json.loads(made.stdout)["id"]
    except (ValueError, KeyError, TypeError):
        raise Refused(3, "bitwarden-failed", "NG: bw create item failed (rc=%d); check the env ledger for %s by "
                      "hand. GitHub was not touched." % (made.returncode, item_name)) from None
    run.created = (item_name, item_id)
    back_item, kept = bw_read(env, item_id)
    if kept != value:
        raise Refused(3, "bitwarden-readback", "NG: the Bitwarden item %s (%s) did not read back equal (length %s, "
                      "made %d); GitHub was not touched. Fix or remove that item in Bitwarden by hand before any "
                      "further run." % (item_name, item_id, len(kept) if isinstance(kept, str) else "none", len(value)))
    mark_active(env, back_item, item_name, item_id, value)
    run.kept = (item_name, item_id)
    run.detail = "bitwarden %s read back equal, length %d" % (item_name, len(value))
    print("KEPT %s in Bitwarden as %s (read back equal, length %d)" % (name, item_name, len(value)))
    return value


def passes_check(rec, value):
    chk = rec.get("check", {})
    if chk.get("no_whitespace") and re.search(r"\s", value):
        return False
    return len(value.encode()) <= int(chk.get("max_bytes", 1 << 30))


def shape_length(rec):
    """token_urlsafe(n) is the unpadded URL-safe base64 of n bytes: 43 characters for 32 bytes."""
    gen = rec.get("generate") or {}
    if gen.get("type") != "token_urlsafe":
        return None
    return len(base64.urlsafe_b64encode(bytes(int(gen["bytes"]))).rstrip(b"="))


def shape_text(rec):
    n = shape_length(rec)
    return "%d URL-safe characters" % n if n else "no known generator"


def generated_shape(rec, value):
    """The value has exactly the shape the recipe's own generator makes (#480: resume must not take less)."""
    n = shape_length(rec)
    return n is not None and re.fullmatch(r"[A-Za-z0-9_-]{%d}" % n, value) is not None


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
    if run.resume:
        return None  # the value comes from the Bitwarden copy
    value = secrets.token_urlsafe(int(gen["bytes"]))
    if not passes_check(rec, value) or not generated_shape(rec, value):
        raise Refused(1, "unverified", "NG: the generated value fails the consumer's rules; nothing was stored.")
    return {rec["values"][0]: value}


TOKENISH = re.compile(r"[A-Za-z0-9+/_=-]{20,}")


def json_leaves(value):
    """Every string leaf of <value> when it is JSON (each adapter key of PUBLISHING_INTAKE_KEYS_JSON)."""
    try:
        doc = json.loads(value)
    except (TypeError, ValueError):
        return []
    leaves, stack = [], [doc]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, str):
            leaves.append(node)
    return leaves


def looks_random(token):
    """A run that reads like key material (mixed case and a digit, or long hex), not a name or a path (#480)."""
    if re.fullmatch(r"[0-9a-fA-F]{32,}", token):
        return True
    return bool(re.search(r"[0-9]", token) and re.search(r"[a-z]", token) and re.search(r"[A-Z]", token))


def redacted_tail(text, value):
    """The last line of the consumer's output with the value, each JSON leaf of it, and any other run that reads
    like key material replaced: the generator's own failure output may print a key it never wrote (#480)."""
    tail = (text or "").strip().splitlines()[-1:] or [""]
    line = tail[0]
    for known in sorted({s for s in [value] + json_leaves(value) if isinstance(s, str) and len(s) >= 8},
                        key=len, reverse=True):
        line = line.replace(known, "<value>")
    line = TOKENISH.sub(lambda m: "<redacted>" if looks_random(m.group(0)) or (len(m.group(0)) >= 40 and "/" not in
                                                                             m.group(0)) else m.group(0), line)
    return line[:160]


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
    dirty = subprocess.run(["git", "-C", repo_dir, "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True, check=False).stdout.strip()
    run.detail = "consumer %s@%s%s" % (os.path.basename(repo_dir), commit, " (dirty)" if dirty else "")
    cmd = list(rec["generate_cmd"])
    for k in rec.get("params", []):
        cmd = [a.replace("{%s}" % k, run.params[k]) for a in cmd]
    out = os.path.join(work, "generated")
    with open(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as fh:
        gen = subprocess.run(cmd, cwd=repo_dir, stdout=fh, stderr=subprocess.PIPE, check=False)
    raw = open(out, "rb").read()
    err = gen.stderr.decode("utf-8", "replace")
    if gen.returncode != 0:
        raise Refused(1, "consumer-generate", "NG: the consumer's generator failed (rc=%d at %s: %s); nothing was "
                      "stored. cor-os needs this command (cor-os#126)." % (gen.returncode, commit,
                                                                          redacted_tail(err, raw.decode("utf-8", "replace"))))
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused(1, "consumer-generate", "NG: the consumer's generator wrote non-UTF-8 output; nothing was "
                      "stored.") from None
    with open(out, "wb") as fh:
        fh.write(raw)
    with open(out, "rb") as fh:
        chk = subprocess.run(rec["check_cmd"], cwd=repo_dir, stdin=fh, capture_output=True, check=False)
    if chk.returncode != 0:
        raise Refused(1, "consumer-check", "NG: the consumer's check refused the value (rc=%d at %s: %s); nothing was "
                      "stored." % (chk.returncode, commit, redacted_tail(chk.stderr.decode("utf-8", "replace"), value)))
    print("VERIFIED %s: the consumer's check passed at %s%s" % (run.recipe_name, commit, " (dirty tree)" if dirty else ""))
    return {rec["values"][0]: value}


def store(run, values, work):
    envargs = ["--env", run.env] if run.env else []
    stored = []
    for name, role in zip(run.names, run.recipe["values"]):
        path = os.path.join(work, "set-" + name)
        write_private(path, values[role])
        try:
            with open(path, "rb") as fh:
                p = subprocess.run(["gh", "secret", "set", name, "--repo", run.repo] + envargs, stdin=fh,
                                   capture_output=True, check=False)
        finally:
            os.unlink(path)
        if p.returncode != 0:
            raise Refused(3, "set-failed", "NG: gh secret set failed for %s in %s (stored before it: %s)."
                          % (name, run.repo, ", ".join(stored) or "none"))
        stored.append(name)
    listing = subprocess.run(["gh", "secret", "list", "--repo", run.repo] + envargs + ["--json", "name,updatedAt"],
                             capture_output=True, text=True, check=False)
    if listing.returncode != 0:
        raise Refused(4, "readback-failed", "NG: sent to gh, but GitHub metadata readback failed (rc=%d); "
                      "registration is unconfirmed." % listing.returncode)
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


def after_keep(run, message, rule):
    """A failure once the Bitwarden copy exists names that copy, what GitHub has, and the way back (#479 review)."""
    if not run.kept:
        if run.created and rule not in ("bitwarden-readback", "bitwarden-status"):
            return message + (" State: Bitwarden has an unverified item %s (id %s); GitHub was not touched. Fix or "
                              "remove that item by hand before any further run." % run.created)
        return message
    item_name, item_id = run.kept
    github = {"set-failed": "GitHub does not have it",
              "readback-stale": "GitHub was sent it but its readback is stale"}.get(rule, "GitHub may not have it")
    return (message + " State: Bitwarden has %s (id %s); %s. To store that same copy, re-run the same command with "
            "--resume-from-bitwarden. Do not make a new value, a second item, or delete this one." % (
                item_name, item_id, github))


def access_service_verify(run, work):
    # -I intentionally excludes this directory from sys.path; load only the adjacent reviewed source.
    spec = importlib.util.spec_from_file_location("access_service_token", os.path.join(HERE, "access_service_token.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.verify(run, work, Refused)


def access_recovery_notice(run, work):
    if run.recipe["kind"] == "access-service-token" and getattr(run, "preserve_work", False):
        print("Access rotation or GitHub storage is incomplete. Private recovery directory: " + work,
              file=sys.stderr)
        print("Keep the old secret valid. Do not rotate again; inspect this attempt before a reviewed recovery.",
              file=sys.stderr)


def main(argv):
    # children (the ledger library's `python3 -`, consumer commands) must not load code from the caller's Python
    # settings while a value file exists; this helper itself runs with -I (#477, #479 review)
    for var in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE", "PYTHONSAFEPATH"):
        os.environ.pop(var, None)
    try:
        run = Run(argv)
    except Refused as r:
        print(r.message, file=sys.stderr)
        return r.code

    def on_signal(signum, _frame):
        raise SystemExit(128 + signum)

    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(s, on_signal)
    work = tempfile.mkdtemp(prefix="register-secret.")
    try:
        run.check_keep()
        kind = run.recipe["kind"]
        if kind == "network":
            net = Network(run, work)
            print("The values of %s will be sent to: %s" % (", ".join(run.names), net.hosts()), file=sys.stderr)
            values = run.read_values()
            net.verify(values)
        elif kind == "slack-oauth-code":
            net = Network(run, work)
            print("The values of %s will be sent to: %s" % (", ".join(run.names), net.hosts()), file=sys.stderr)
            try:
                values = _slack_code.verify(run, work, net)
            except _slack_code.SlackOAuthRefused as exc:
                raise Refused(1, exc.rule, str(exc)) from None
        elif kind == "generated":
            values = generated(run)
        elif kind == "consumer":
            values = consumer(run, work)
        elif kind == "access-service-token":
            values = access_service_verify(run, work)
            if run.dry:
                run.ledger("allow", "preflight-only")
                print("PREFLIGHT ONLY: Access settings matched; no rotation, pair verification or GitHub storage.")
                return 0
        else:
            raise Refused(1, "recipe-invalid", "NG: recipe %s has an unknown kind %r" % (run.recipe_name, kind))
        if run.dry:
            run.ledger("allow", "dry-run-verified")
            print("DRY RUN: %s were not stored." % ", ".join(run.names))
            return 0
        if run.recipe.get("keep") == "bitwarden":
            role = run.recipe["values"][0]
            values = {role: keep_in_bitwarden(run, run.names[0], values[role] if values else "")}
        store(run, values, work)
        run.ledger("allow", "registered")
        if kind == "access-service-token":
            run.preserve_work = False
        return 0
    except Refused as r:
        if r.rule:
            run.ledger("warn" if r.code == 4 else "deny", r.rule)
        print(after_keep(run, r.message, r.rule), file=sys.stderr)
        if getattr(run, "slack_outcome_unknown", False):
            print("Slack exchange outcome is unknown: revoke the new grant in Slack before any retry.", file=sys.stderr)
        access_recovery_notice(run, work)
        return r.code
    except SystemExit:
        if run.recipe["kind"] == "slack-oauth-code":
            run.detail = "interrupted; check new Slack grant and GitHub secret metadata before retry"
            run.ledger("deny", "interrupted")
            print("Interrupted: check the new Slack grant and GitHub secret metadata before any retry.", file=sys.stderr)
        elif run.recipe["kind"] == "access-service-token":
            run.detail = "interrupted; inspect rotation and GitHub metadata before any retry"
            run.ledger("deny", "interrupted")
            access_recovery_notice(run, work)
        elif run.created or run.kept:
            # a signal once the Bitwarden item exists still names that item and what GitHub has (#480)
            run.detail = "interrupted after the Bitwarden write"
            run.ledger("deny", "interrupted")
            print(after_keep(run, "NG: interrupted.", "interrupted"), file=sys.stderr)
        elif getattr(run, "creating", None):
            run.detail = "interrupted during bw create"
            run.ledger("deny", "interrupted")
            print("NG: interrupted during bw create. Check the env ledger for %s by hand: it may exist with "
                  "_bw.status=unverified. GitHub was not touched." % run.creating, file=sys.stderr)
        raise
    except Exception as exc:  # an unexpected failure is still a ledger row, and says whether Bitwarden was written
        run.detail = (run.detail + "; " if run.detail else "") + type(exc).__name__
        run.ledger("deny", "internal-error")
        print(after_keep(run, "NG: unexpected %s; nothing more was stored." % type(exc).__name__, "internal-error"),
              file=sys.stderr)
        if getattr(run, "slack_outcome_unknown", False):
            print("Slack exchange outcome is unknown: revoke the new grant in Slack before any retry.", file=sys.stderr)
        access_recovery_notice(run, work)
        return 1
    finally:
        if not getattr(run, "preserve_work", False):
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
