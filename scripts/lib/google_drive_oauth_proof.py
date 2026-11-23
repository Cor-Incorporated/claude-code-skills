"""Pre-admission provider proof. The installed registrar does not enable this recipe."""

import base64
import hashlib
import secrets
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock
from urllib.parse import parse_qs, urlencode, urlsplit

AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN = {"method": "POST", "url": "https://oauth2.googleapis.com/token"}
REVOKE = {"method": "POST", "url": "https://oauth2.googleapis.com/revoke"}
REDIRECT = "http://localhost:8926/google-drive-register"


class ProofRefused(Exception):
    """Refusal contains an outcome label only."""


class AuthorizationAttempt:
    """One in-memory proof for the fixed local callback. A listener owns its lifecycle."""

    def __init__(self, client_id, *, clock=time.monotonic):
        if not client_id or client_id.strip() != client_id:
            raise ProofRefused("invalid_client_id")
        self._lock = Lock()
        self._clock = clock
        self._expires = clock() + 300
        self._state = secrets.token_urlsafe(32)
        self._verifier = secrets.token_urlsafe(32)
        digest = hashlib.sha256(self._verifier.encode("ascii")).digest()
        challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
        self.url = AUTHORIZE + "?" + urlencode({
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "scope": "openid",
            "access_type": "online",
            "prompt": "select_account",
            "state": self._state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        })

    def accept_callback(self, request_target):
        """Accept the origin-form target from a local HTTP request, once."""
        try:
            if len(request_target) > 8192 or not request_target.startswith("/"):
                raise ValueError
            target = urlsplit(request_target)
            if target.scheme or target.netloc or target.fragment or target.path != urlsplit(REDIRECT).path:
                raise ValueError
            params = parse_qs(target.query, keep_blank_values=True, max_num_fields=16, errors="strict")
        except ValueError:
            raise ProofRefused("invalid_callback") from None
        states = params.get("state", [])
        with self._lock:
            if self._verifier is None or self._clock() >= self._expires:
                self._verifier = None
                raise ProofRefused("attempt_closed")
            if len(states) != 1 or not secrets.compare_digest(states[0].encode(), self._state.encode()):
                raise ProofRefused("invalid_state")
            verifier, self._verifier = self._verifier, None
        if "error" in params:
            raise ProofRefused("authorization_denied")
        codes = params.get("code", [])
        if len(codes) != 1 or not codes[0] or any(character.isspace() for character in codes[0]):
            raise ProofRefused("invalid_code")
        return codes[0], verifier


class _LoopbackServer(HTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(1)
        return connection, address

    def handle_error(self, request, client_address):
        # An interrupted response must never expose a callback target or code.
        pass


def capture_authorization(client_id, present_url):
    """Return a one-time proof from the private listener, with no persisted URL or code."""
    attempt = AuthorizationAttempt(client_id)
    callback = urlsplit(REDIRECT)
    outcome = None

    class CallbackHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            nonlocal outcome
            status, message = 400, b"Authorization callback refused."
            if self.headers.get_all("Host") == [callback.netloc]:
                try:
                    outcome = attempt.accept_callback(self.path)
                except ProofRefused as refusal:
                    if str(refusal) in {"authorization_denied", "invalid_code", "attempt_closed"}:
                        outcome = refusal
                else:
                    status, message = 200, b"Authorization received. Return to the registrar."
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(message)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(message)

    try:
        listener = _LoopbackServer(("127.0.0.1", callback.port), CallbackHandler)
    except OSError:
        raise ProofRefused("callback_listener_unavailable") from None
    with listener:
        present_url(attempt.url)
        while outcome is None:
            remaining = attempt._expires - attempt._clock()
            if remaining <= 0:
                raise ProofRefused("authorization_timeout")
            listener.timeout = min(remaining, 1)
            listener.handle_request()
    if isinstance(outcome, ProofRefused):
        raise outcome
    return outcome


def verify(network, client_id, client_secret, control, positive):
    """Check two independent, consented authorization-code proofs; keep no grant.

    Capture both (authorization_code, code_verifier) pairs with the private
    loopback listener. No caller receives a token.
    """
    if not all((client_id, client_secret, *control, *positive)):
        raise ProofRefused("missing_input")
    if control[0] == positive[0] or control[1] == positive[1]:
        raise ProofRefused("reused_proof")

    control_ok = exchange(network, client_id, secrets.token_urlsafe(32), control, negative=True)
    if not control_ok:
        raise ProofRefused("negative_control_failed")
    if not exchange(network, client_id, client_secret, positive, negative=False):
        raise ProofRefused("client_proof_failed")


def exchange(network, client_id, client_secret, proof, *, negative):
    code, verifier = proof
    tokens = set()

    def received(document):
        if isinstance(document, dict):
            for key in ("access_token", "refresh_token"):
                value = document.get(key)
                if isinstance(value, str) and value:
                    tokens.add(value)

    form = {
        "client_id": client_id,
        "client_secret": client_secret,
        "code": code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": REDIRECT,
    }
    try:
        status, result = network.ask({}, request=TOKEN, form=form, received=received)
    finally:
        # Attempt every revocation even if a previous token could not be revoked.
        failures = 0
        for token in tokens:
            try:
                status_revoke, _ = network.ask({}, request=REVOKE, form={"token": token})
                failures += status_revoke != 200
            except Exception:
                failures += 1
        if failures:
            raise ProofRefused("revocation_unconfirmed") from None
    if not isinstance(result, dict):
        return False
    if negative:
        return status == 401 and result.get("error") == "invalid_client" and not tokens
    access_token = result.get("access_token")
    token_type = result.get("token_type")
    scope = result.get("scope")
    return (
        status == 200
        and "error" not in result
        and isinstance(access_token, str)
        and access_token in tokens
        and isinstance(token_type, str)
        and token_type.lower() == "bearer"
        and isinstance(scope, str)
        and set(scope.split()) == {"openid"}
        and "refresh_token" not in result
    )
