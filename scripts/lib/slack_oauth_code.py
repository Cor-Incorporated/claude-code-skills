"""Credential registration probe, not a cor-os login implementation. No live calls on import."""
import getpass
import html
import json
import os
import re
import secrets
import socket
import sys
import time
import urllib.parse
import warnings


class SlackOAuthRefused(Exception):
    def __init__(self, rule, message):
        super().__init__("NG: " + message + "; nothing was stored.")
        self.rule = rule


def refuse(rule, message):
    raise SlackOAuthRefused(rule, message)


def private_file(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(text)


def hidden_read(read):
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        try:
            return read()
        except getpass.GetPassWarning:
            refuse("hidden-input-required", "terminal echo could not be disabled")


def token_values(doc):
    """Collect even tokens in an unexpected control/error response, before validating it."""
    if not isinstance(doc, dict):
        return set()
    result = {doc[k] for k in ("access_token", "refresh_token") if isinstance(doc.get(k), str) and doc[k]}
    return result | token_values(doc.get("authed_user"))


def verify(run, work, net):
    rec, params = run.recipe, run.params
    grant = rec.get("grant", {})
    # This implementation is deliberately bounded to one reviewed application and consumer.
    if (run.repo != "Cor-Incorporated/cor-os" or run.env or
            run.names != ["SLACK_OAUTH_CLIENT_ID", "SLACK_OAUTH_CLIENT_SECRET"] or
            rec.get("values") != ["client_id", "client_secret"] or
            rec.get("hosts") != ["slack.com"] or
            rec.get("request") != {"method": "POST", "url": "https://slack.com/api/oauth.v2.access",
                                   "basic": ["client_id", "client_secret"]} or
            rec.get("pass") != {"status": 200, "json": {"ok": True}} or
            rec.get("control") != {"replace": "client_secret", "fail_unless":
                                   {"status": 200, "json": {"ok": False, "error": "bad_client_secret"}}} or
            grant != {"app_id": "A0CDE0UUC79", "team_id": "T062U0CS2RJ", "user_scope": "users:read",
                      "redirect_uri": "https://127.0.0.1:8765/slack-register"}):
        refuse("recipe-invalid", "Slack code recipe differs from its reviewed contract")
    if params.get("fresh-grant") != "yes" or not re.fullmatch(r"U[A-Z0-9]+", params.get("user-id", "")):
        refuse("grant-precondition", "confirm a new grant with --param fresh-grant=yes and the allowed --param user-id")
    if not sys.stdin.isatty():
        refuse("hidden-input-required", "this code recipe requires a terminal and hidden prompts")
    # Reserve the exact TCP endpoint without accepting connections or reading HTTP/TLS.
    # An existing listener must not receive the callback's code; do not enable address/port reuse.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
        try:
            reservation.bind(("127.0.0.1", 8765))
        except OSError:
            refuse("callback-port-busy", "the private loopback callback port is unavailable")
        return _verify_grant(run, work, net, grant)


def _verify_grant(run, work, net, grant):
    params = run.params
    values = hidden_read(run.read_values)
    state = secrets.token_urlsafe(32)
    query = urllib.parse.urlencode({"client_id": values["client_id"], "user_scope": grant["user_scope"],
                                   "redirect_uri": grant["redirect_uri"], "team": grant["team_id"], "state": state})
    path = os.path.join(work, "authorize.html")
    private_file(path, '<!doctype html><meta charset="utf-8"><title>Slack credential verification</title>'
                 '<p>Only continue after the operator approves this new users:read grant.</p>'
                 '<a rel="noreferrer" href="' + html.escape("https://slack.com/oauth/v2/authorize?" + query, quote=True)
                 + '">Authorize the temporary verification grant</a>')
    print("Private authorization page: " + path, flush=True)
    print("Open that file locally. After consent capture the full loopback URL, then STOP navigation or CLOSE "
          "the callback tab BEFORE submitting the hidden prompt (no queued browser retries). "
          "The loopback page cannot load and may time out. Never paste its URL into chat or a shell command.", flush=True)
    started = time.monotonic()
    callback = hidden_read(lambda: getpass.getpass("After stopping/closing the callback tab, paste its full URL (hidden): ")).strip()
    try:
        parsed = urllib.parse.urlsplit(callback)
        fields = urllib.parse.parse_qs(parsed.query, strict_parsing=True, keep_blank_values=True)
        base = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    except ValueError:
        refuse("callback-invalid", "the callback URL is malformed")
    if (base != grant["redirect_uri"] or parsed.fragment or set(fields) != {"code", "state"} or
            any(len(v) != 1 or not v[0] for v in fields.values()) or
            not secrets.compare_digest(fields["state"][0], state) or time.monotonic() - started >= 600):
        refuse("callback-invalid", "callback origin, state, fields or time limit does not match")
    form = {"code": fields["code"][0], "redirect_uri": grant["redirect_uri"], "grant_type": "authorization_code"}
    tokens = set()
    journal = os.path.join(work, "cleanup-pending.json")

    def ask(pair):
        run.slack_outcome_unknown = True
        result = net.ask(pair, form=form, received=lambda doc: tokens.update(token_values(doc)))
        status, doc = result
        definite = (status == 200 and isinstance(doc, dict) and
                    (doc.get("ok") is False or (doc.get("ok") is True and bool(token_values(doc)))))
        run.slack_outcome_unknown = not definite
        return result

    try:
        wrong = dict(values, client_secret=secrets.token_urlsafe(32))
        status, control = ask(wrong)
        # Never include arbitrary provider strings in logs; errors may reflect input values.
        if (status != 200 or not isinstance(control, dict) or set(control) != {"ok", "error"} or
                control.get("ok") is not False or control.get("error") != "bad_client_secret"):
            run.detail = "control not a definite bad_client_secret; no real exchange attempted"
            refuse("control-failed", "Slack did not definitely reject the wrong secret")
        status, real = ask(values)
        user = real.get("authed_user", {}) if isinstance(real, dict) else {}
        if (status != 200 or not isinstance(real, dict) or real.get("ok") is not True or
                real.get("app_id") != grant["app_id"] or not isinstance(real.get("team"), dict) or
                real["team"].get("id") != grant["team_id"] or
                not isinstance(user, dict) or user.get("id") != params["user-id"] or
                user.get("scope") != grant["user_scope"] or user.get("token_type") != "user" or
                not isinstance(user.get("access_token"), str) or not user["access_token"] or
                set(real) & {"access_token", "refresh_token"} or "refresh_token" in user):
            run.detail = "control rejected; real exchange or app/team/user/scope contract did not match"
            refuse("exchange-unverified", "Slack did not return the reviewed temporary user grant")
        run.detail = "control HTTP 200 bad_client_secret; real HTTP 200 ok:true; app/team/user/scope matched"
    finally:
        if tokens:
            # Keep a private recovery record until every token is definitely revoked.
            run.preserve_work = True
            journal_failed = False
            try:
                private_file(journal, json.dumps({"tokens": sorted(tokens)}))
            except BaseException:
                # Disk-full or interruption must not skip revocation of already-received tokens.
                journal_failed = True
            pending = False
            for token in sorted(tokens):
                try:
                    status, answer = net.ask({}, request={"method": "POST", "url": "https://slack.com/api/auth.revoke"},
                                             form={"token": token})
                    pending |= status != 200 or not isinstance(answer, dict) or answer.get("ok") is not True or answer.get("revoked") is not True
                except BaseException:
                    pending = True
            if pending:
                run.preserve_work = True
                run.detail = "temporary token cleanup incomplete; GitHub storage prohibited"
                if journal_failed:
                    refuse("cleanup-failed", "temporary token revocation was not confirmed and recovery journal is unavailable; "
                           "revoke the new grant in Slack; private directory: " + work)
                refuse("cleanup-failed", "temporary token revocation was not confirmed; private recovery file: " + journal)
            if journal_failed:
                run.detail = "tokens revoked; recovery journal write failed; GitHub storage prohibited"
                refuse("cleanup-journal-failed", "temporary tokens revoked but recovery journaling failed; private directory: " + work)
            try:
                os.unlink(journal)
            except OSError:
                refuse("cleanup-journal-failed", "temporary tokens revoked but recovery file removal failed: " + journal)
            run.preserve_work = False
    print("VERIFIED slack-oauth-code: wrong secret rejected; real grant matched; temporary tokens revoked")
    return values
