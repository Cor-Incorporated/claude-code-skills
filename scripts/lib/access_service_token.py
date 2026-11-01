"""One approved Access service-token rotation; no storage and no automatic retry.

The caller keeps the private work directory after any attempted rotation until
GitHub storage/readback succeeds. Only the reviewed recipe supplies resources.
"""
import fnmatch
import getpass
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import warnings
from datetime import datetime, timezone
from urllib.parse import quote as path_quote, urlsplit

LIMIT = 1024 * 1024
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
ACCOUNT = re.compile(r"[0-9a-f]{32}\Z")
HOST = re.compile(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\Z")


def private_file(path, data):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data.encode("utf-8") if isinstance(data, str) else data)
        handle.flush()
        os.fsync(handle.fileno())


def parse_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate-json-field")
            result[key] = value
        return result

    def invalid_constant(_):
        raise ValueError("nonfinite-json-number")

    return json.loads(raw.decode("utf-8"), object_pairs_hook=pairs, parse_constant=invalid_constant)


class CurlTransport:
    """curl gets credentials only through owner-only config files, never argv."""
    def __init__(self, work, fail):
        self.work, self.fail, self.sequence = work, fail, 0

    def request(self, url, headers, payload=None, result_path=None):
        self.sequence += 1
        prefix = os.path.join(self.work, "access-request-%d" % self.sequence)
        config, body = prefix + ".curl", prefix + ".body"
        answer = result_path or prefix + ".answer"
        parts = urlsplit(url)
        if (parts.scheme != "https" or not parts.hostname or parts.username or parts.password or
                parts.fragment or parts.port not in (None, 443)):
            self.fail("transport", "Access request URL was refused")

        def quote(value):
            if not isinstance(value, str) or any(c in value for c in "\r\n\0"):
                self.fail("transport", "Access request field was refused")
            return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

        lines = ["url = " + quote(url), "request = " + quote("POST" if payload is not None else "GET"),
                 "output = " + quote(answer), 'write-out = "%{http_code}"', "globoff"]
        for key, value in headers.items():
            lines.append("header = " + quote(key + ": " + value))
        try:
            if payload is not None:
                private_file(body, json.dumps(payload, separators=(",", ":")))
                lines.extend(['header = "Content-Type: application/json"', "data-binary = " + quote("@" + body)])
            private_file(answer, b"")
            private_file(config, "\n".join(lines) + "\n")
            try:
                result = subprocess.run(
                    ["curl", "-q", "-sS", "--proto", "=https", "--proto-redir", "=https",
                     "--connect-timeout", "10", "--max-time", "20", "--max-filesize", str(LIMIT),
                     "--retry", "0", "-K", config], capture_output=True, check=False, timeout=25)
            except (OSError, subprocess.TimeoutExpired):
                self.fail("transport", "Access request did not complete")
            if result.returncode or not re.fullmatch(rb"[1-5][0-9]{2}", result.stdout):
                self.fail("transport", "Access request did not complete")
            with open(answer, "rb") as handle:
                raw = handle.read(LIMIT + 1)
            if len(raw) > LIMIT:
                self.fail("transport", "Access response exceeded its bound")
            try:
                doc = parse_json(raw)
            except (ValueError, UnicodeDecodeError):
                doc = None
            return int(result.stdout), doc
        finally:
            for path in (config, body, answer if result_path is None else None):
                if path is not None:
                    try:
                        os.unlink(path)
                    except FileNotFoundError:
                        pass


def config(run, fail):
    rec = run.recipe
    if (run.repo != "Cor-Incorporated/cor-os" or run.env or
            run.names != ["CF_ACCESS_CLIENT_ID", "CF_ACCESS_CLIENT_SECRET"] or
            rec.get("values") != ["client_id", "client_secret"] or
            set(run.params) != {"rotate-confirmed"} or run.params.get("rotate-confirmed") != "yes"):
        fail("contract", "Access recipe requires its fixed repository, names and explicit rotation confirmation")
    if (not isinstance(rec.get("account_id"), str) or not ACCOUNT.fullmatch(rec["account_id"]) or
            any(not isinstance(rec.get(k), str) or not UUID.fullmatch(rec[k])
                for k in ("service_token_id", "app_id", "policy_id"))):
        fail("contract", "Access recipe resource IDs are invalid")
    origins = rec.get("origins")
    if (not isinstance(origins, list) or len(origins) != 4 or
            any(not isinstance(host, str) or not HOST.fullmatch(host) for host in origins) or len(set(origins)) != 4 or
            rec.get("probe_path") != "/v1/models" or
            any(not isinstance(rec.get(k), str) or not rec[k] for k in ("service_token_name", "app_name", "policy_name"))):
        fail("contract", "Access recipe requires four fixed origins and a read-only models probe")
    return rec


def timestamp(value, fail):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError
        return parsed.astimezone(timezone.utc)
    except (AttributeError, TypeError, ValueError):
        fail("metadata", "Access token timestamps did not match the contract")


def header_value(value, fail):
    if (not isinstance(value, str) or not value or value.strip() != value or
            any(not char.isprintable() for char in value)):
        fail("metadata", "Access credential field did not match the contract")
    return value


def policy_contract(policy, rec, fail, global_policy=False):
    expected = {"id": rec["policy_id"], "name": rec["policy_name"], "decision": "non_identity",
                "include": [{"service_token": {"token_id": rec["service_token_id"]}}],
                "require": [], "exclude": [], "reusable": True}
    if (not isinstance(policy, dict) or any(policy.get(k) != v for k, v in expected.items()) or
            policy.get("reusable") is not True or
            (global_policy and (type(policy.get("app_count")) is not int or policy["app_count"] != 1))):
        fail("policy", "Access service-auth policy differs from the reviewed token-only rule")
    return expected


def app_contract(app, rec, fail):
    hosts = rec["origins"]
    if (not isinstance(app, dict) or app.get("id") != rec["app_id"] or app.get("name") != rec["app_name"] or
            app.get("type") != "self_hosted" or app.get("domain") != hosts[0] or
            not isinstance(app.get("self_hosted_domains"), list) or
            sorted(app["self_hosted_domains"]) != sorted(hosts) or
            not isinstance(app.get("destinations"), list) or
            sorted((d.get("type"), d.get("uri")) for d in app["destinations"] if isinstance(d, dict)) !=
            sorted(("public", host) for host in hosts) or len(app["destinations"]) != 4 or
            not isinstance(app.get("policies"), list) or len(app["policies"]) != 1):
        fail("app", "Access application differs from the reviewed four-origin application")
    policy_contract(app["policies"][0], rec, fail)


def resource_hosts(app, fail):
    """All visible public host forms, including wildcard/path shadows."""
    if not isinstance(app, dict) or not isinstance(app.get("id"), str):
        fail("fleet", "Access application inventory is incomplete")
    fields = []
    if app.get("domain") is not None:
        fields.append(app["domain"])
    if app.get("self_hosted_domains") is not None:
        if not isinstance(app["self_hosted_domains"], list):
            fail("fleet", "Access application inventory is incomplete")
        fields.extend(app["self_hosted_domains"])
    destinations = app.get("destinations")
    if destinations is not None:
        if not isinstance(destinations, list):
            fail("fleet", "Access application inventory is incomplete")
        for destination in destinations:
            if not isinstance(destination, dict):
                fail("fleet", "Access application inventory is incomplete")
            if destination.get("type") == "public":
                fields.append(destination.get("uri"))
            elif "uri" in destination:
                # A new URI-bearing destination cannot silently escape shadow detection.
                fail("fleet", "Access application has an unreviewed URI-bearing destination")
    hosts = set()
    for field in fields:
        if not isinstance(field, str) or not field or "://" in field or any(c.isspace() for c in field):
            fail("fleet", "Access public hostname inventory is invalid")
        parsed = urlsplit("https://" + field)
        if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            fail("fleet", "Access public hostname inventory is invalid")
        hosts.add(parsed.hostname.lower().rstrip("."))
    return hosts


def paged(api, path, fail, rule="fleet"):
    items, page, total, pages = [], 1, None, None
    while True:
        doc = api(path + "?per_page=100&page=%d" % page, envelope=True)
        info, batch = doc.get("result_info"), doc.get("result")
        if (not isinstance(info, dict) or not isinstance(batch, list) or
                any(type(info.get(k)) is not int for k in ("page", "per_page", "count", "total_count", "total_pages")) or
                info["page"] != page or info["per_page"] != 100 or info["count"] != len(batch) or
                not 1 <= info["total_pages"] <= 20 or not 0 <= info["total_count"] <= 2000 or
                info["total_pages"] != max(1, (info["total_count"] + 99) // 100) or len(batch) > 100):
            fail(rule, "Access inventory pagination is incomplete")
        if page == 1:
            total, pages = info["total_count"], info["total_pages"]
        elif total != info["total_count"] or pages != info["total_pages"]:
            fail(rule, "Access inventory changed during pagination")
        items.extend(batch)
        if page == pages:
            break
        page += 1
    if len(items) != total or any(not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"] for item in items):
        fail(rule, "Access inventory is incomplete")
    if len({item["id"] for item in items}) != len(items):
        fail(rule, "Access inventory contains duplicate IDs")
    return items


def token_reference(policy, rec, fail):
    """Only the measured identity rules or a direct service-token rule are understood."""
    if (not isinstance(policy, dict) or
            any(not isinstance(policy.get(field), list) for field in ("include", "require", "exclude"))):
        fail("policy-fleet", "Access policy condition inventory is incomplete")
    forms = {"allow": {"email": "email", "email_domain": "domain", "login_method": "id"},
             "non_identity": {"service_token": "token_id"}}
    decision = policy.get("decision")
    if not isinstance(decision, str) or decision not in forms:
        fail("token-use", "Access policy decision is outside the reviewed forms")
    referenced = False
    for field in ("include", "require", "exclude"):
        for item in policy[field]:
            if not isinstance(item, dict) or len(item) != 1:
                fail("token-use", "Access policy selector is outside the reviewed forms")
            selector = next(iter(item))
            if selector not in forms[decision]:
                fail("token-use", "Access policy selector is outside the reviewed forms")
            key, value = forms[decision][selector], item[selector]
            if (not isinstance(value, dict) or set(value) != {key} or
                    not isinstance(value[key], str) or not value[key].strip()):
                fail("token-use", "Access policy selector value is outside the reviewed forms")
            if selector == "service_token":
                referenced |= value[key] == rec["service_token_id"]
    return referenced


def policy_fleet(rec, apps, api, fail):
    globals_ = paged(api, "/access/policies", fail, "policy-fleet")
    if len([policy for policy in globals_ if policy["id"] == rec["policy_id"]]) != 1:
        fail("token-use", "Access global policy inventory did not uniquely identify the reviewed policy")
    for policy in globals_:
        referenced = token_reference(policy, rec, fail)
        if policy["id"] == rec["policy_id"]:
            policy_contract(policy, rec, fail, global_policy=True)
        elif referenced:
            fail("token-use", "Access token is referenced by another global policy")
    for app in apps:
        policies = paged(api, "/access/apps/" + path_quote(app["id"], safe="") + "/policies", fail, "policy-fleet")
        if app["id"] == rec["app_id"]:
            if len(policies) != 1:
                fail("policy", "Access target app has additional or missing policies")
            policy_contract(policies[0], rec, fail)
        for policy in policies:
            referenced = token_reference(policy, rec, fail)
            if app["id"] != rec["app_id"] and (referenced or policy["id"] == rec["policy_id"]):
                fail("token-use", "Access token or reviewed policy is referenced by another application")


def preflight(rec, api, fail, allow_active_previous=False):
    token = api("/access/service_tokens/" + rec["service_token_id"])
    if (not isinstance(token, dict) or token.get("id") != rec["service_token_id"] or
            token.get("name") != rec["service_token_name"] or token.get("enabled") is not True or
            not isinstance(token.get("duration"), str) or not token["duration"].strip()):
        fail("metadata", "Access service token differs from the reviewed enabled token")
    header_value(token.get("client_id"), fail)
    now = datetime.now(timezone.utc)
    if timestamp(token.get("expires_at"), fail) <= now:
        fail("metadata", "Access service token has expired")
    timestamp(token.get("created_at"), fail)
    timestamp(token.get("updated_at"), fail)
    if token.get("previous_client_secret_expires_at") is not None:
        previous = timestamp(token["previous_client_secret_expires_at"], fail)
        if not allow_active_previous and previous > now:
            fail("overlap", "Access token already has a live previous secret; do not rotate again")
    app_contract(api("/access/apps/" + rec["app_id"]), rec, fail)
    policy_contract(api("/access/policies/" + rec["policy_id"]), rec, fail, global_policy=True)
    policies = api("/access/apps/" + rec["app_id"] + "/policies")
    if not isinstance(policies, list) or len(policies) != 1:
        fail("policy", "Access app policy inventory is incomplete")
    policy_contract(policies[0], rec, fail)
    apps = paged(api, "/access/apps", fail)
    matches = []
    for app in apps:
        patterns = resource_hosts(app, fail)
        if any(fnmatch.fnmatchcase(host, pattern) for host in rec["origins"] for pattern in patterns):
            matches.append(app["id"])
            if app["id"] == rec["app_id"]:
                if patterns != set(rec["origins"]):
                    fail("fleet", "Access target app inventory differs from the reviewed origins")
    if matches != [rec["app_id"]]:
        fail("fleet", "Access origins have missing or overlapping applications")
    policy_fleet(rec, apps, api, fail)
    return token


def management_token(fail):
    if sys.stdin.isatty():
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            try:
                value = getpass.getpass("Paste the temporary Cloudflare management API token (hidden): ")
            except getpass.GetPassWarning:
                fail("input", "A hidden management token prompt is unavailable")
    else:
        value = sys.stdin.read(262145)
        if len(value) > 262144:
            fail("input", "Management token input exceeded its bound")
    return header_value(value.strip(), fail)


def verify(run, work, Refused, transport_factory=None):
    def fail(rule, text):
        run.detail = "access service-token " + rule + "; no automatic retry"
        raise Refused(1, "access-" + rule, "NG: " + text)

    rec = config(run, fail)
    fd = os.open(work, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            fail("input", "Access work directory must be owner-only")
    finally:
        os.close(fd)
    manager = management_token(fail)
    net = (transport_factory or CurlTransport)(work, fail)
    base = "https://api.cloudflare.com/client/v4/accounts/" + rec["account_id"]

    def api(path, envelope=False, payload=None, result_path=None):
        status, doc = net.request(base + path, {"Authorization": "Bearer " + manager, "Accept": "application/json"},
                                  payload=payload, result_path=result_path)
        if status != 200 or not isinstance(doc, dict) or doc.get("success") is not True or "result" not in doc:
            fail("api", "Cloudflare API response did not confirm the reviewed operation")
        return doc if envelope else doc["result"]

    try:
        before = preflight(rec, api, fail)
        # Read-only baseline before any mutation; the four hosts must deny a request without credentials.
        for host in rec["origins"]:
            status, _ = net.request("https://" + host + rec["probe_path"], {"Accept": "application/json"})
            if status != 403:
                fail("baseline", "An origin did not definitely deny the unauthenticated probe")
        if run.dry:
            run.detail = "read-only Access preflight passed; no rotation or pair verification attempted"
            return None
        run.preserve_work = True
        started = datetime.now(timezone.utc)
        state = {"phase": "rotation-outcome-pending", "service_token_id": rec["service_token_id"],
                 "previous_client_secret_expires_at": before["expires_at"], "preflight_updated_at": before["updated_at"],
                 "started_at": started.isoformat()}
        private_file(os.path.join(work, "rotation-state.json"), json.dumps(state, separators=(",", ":")))
        result_path = os.path.join(work, "rotation-result.json")
        rotated = api("/access/service_tokens/" + rec["service_token_id"] + "/rotate",
                      payload={"previous_client_secret_expires_at": before["expires_at"]}, result_path=result_path)
        if (not isinstance(rotated, dict) or rotated.get("id") != before["id"] or
                rotated.get("client_id") != before["client_id"] or rotated.get("name") != before["name"] or
                ("enabled" in rotated and rotated["enabled"] is not True) or
                any(k in rotated and rotated[k] != before[k] for k in ("created_at", "duration", "expires_at")) or
                ("previous_client_secret_expires_at" in rotated and rotated["previous_client_secret_expires_at"] != before["expires_at"])):
            fail("rotation", "Cloudflare rotation response differs from the reviewed token")
        pair = {key: header_value(rotated.get(key), fail) for key in ("client_id", "client_secret")}
        updated = timestamp(rotated.get("updated_at"), fail)
        if updated <= timestamp(before["updated_at"], fail) or updated < started.replace(microsecond=0):
            fail("rotation", "Cloudflare rotation timestamp is stale")
        after = preflight(rec, api, fail, allow_active_previous=True)
        if (after.get("updated_at") != rotated["updated_at"] or after.get("client_id") != pair["client_id"] or
                any(after.get(k) != before.get(k) for k in ("id", "name", "created_at", "duration", "expires_at")) or
                after.get("previous_client_secret_expires_at") != before["expires_at"]):
            fail("readback", "Cloudflare token readback did not confirm preserved old-secret expiry")
        wrong = secrets.token_urlsafe(32)
        if secrets.compare_digest(wrong, pair["client_secret"]):
            fail("control", "Negative control did not differ from the generated secret")
        for host in rec["origins"]:
            status, _ = net.request("https://" + host + rec["probe_path"],
                                    {"CF-Access-Client-Id": pair["client_id"], "CF-Access-Client-Secret": wrong,
                                     "Accept": "application/json"})
            if status != 403:
                fail("control", "An origin did not definitely deny the wrong-secret probe")
        for host in rec["origins"]:
            status, doc = net.request("https://" + host + rec["probe_path"],
                                      {"CF-Access-Client-Id": pair["client_id"], "CF-Access-Client-Secret": pair["client_secret"],
                                       "Accept": "application/json"})
            if (status != 200 or not isinstance(doc, dict) or doc.get("object") != "list" or
                    not isinstance(doc.get("data"), list) or
                    any(not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]
                        for row in doc["data"])):
                fail("probe", "An origin did not return the reviewed authenticated models response")
        final = preflight(rec, api, fail, allow_active_previous=True)
        if any(final.get(k) != after.get(k) for k in
               ("id", "name", "client_id", "created_at", "updated_at", "duration", "expires_at", "previous_client_secret_expires_at")):
            fail("readback", "Cloudflare token changed during the origin probes")
        run.detail = "four origins: unauthenticated=4/4 denied; control=4/4 denied; real=4/4 HTTP200 models JSON; old-expiry-preserved"
        print("VERIFIED access-service-token: four origins denied controls and accepted the new pair; old expiry preserved")
        return pair
    finally:
        manager = ""
