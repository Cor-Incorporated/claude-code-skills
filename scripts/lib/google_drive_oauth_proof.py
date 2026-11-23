"""Pre-admission provider proof. The installed registrar does not enable this recipe."""

import secrets

TOKEN = {"method": "POST", "url": "https://oauth2.googleapis.com/token"}
REVOKE = {"method": "POST", "url": "https://oauth2.googleapis.com/revoke"}
REDIRECT = "http://localhost:8926/google-drive-register"


class ProofRefused(Exception):
    """Refusal contains an outcome label only."""


def verify(network, client_id, client_secret, control, positive):
    """Check two independent, consented authorization-code proofs; keep no grant.

    The caller owns a loopback listener and validates state before passing
    (authorization_code, code_verifier) pairs. No caller receives a token.
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
