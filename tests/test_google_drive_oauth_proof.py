import base64
import hashlib
import importlib.util
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

spec = importlib.util.spec_from_file_location(
    "proof", Path(__file__).resolve().parents[1] / "scripts/lib/google_drive_oauth_proof.py"
)
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)

NEGATIVE = (401, {"error": "invalid_client"})
POSITIVE = (200, {"access_token": "fixture-access", "token_type": "Bearer", "scope": "openid"})
REVOKED = (200, None)


class Provider:
    def __init__(self, *answers):
        self.answers = iter(answers)
        self.calls = []

    def ask(self, values, *, request, form, received=None):
        self.calls.append((request["url"], form))
        status, body = next(self.answers)
        if received:
            received(body)
        return status, body


class GoogleDriveProofTests(unittest.TestCase):
    def run_proof(self, fake):
        proof.verify(fake, "client-id", "fixture-secret", ("control", "a"), ("valid", "b"))

    def test_local_callbacks_feed_verified_pair_and_cannot_be_replayed(self):
        inputs = []
        for suffix in ("control", "positive"):
            attempt = proof.AuthorizationAttempt("fixture-client")
            auth_url = urlsplit(attempt.url)
            params = parse_qs(auth_url.query)
            self.assertEqual(auth_url.netloc, "accounts.google.com")
            self.assertEqual(params["redirect_uri"], [proof.REDIRECT])
            self.assertEqual(params["scope"], ["openid"])
            self.assertEqual(params["access_type"], ["online"])
            self.assertEqual(params["code_challenge_method"], ["S256"])
            callback = "/google-drive-register?" + urlencode({"state": params["state"][0], "code": suffix})
            result = attempt.accept_callback(callback)
            challenge = base64.urlsafe_b64encode(hashlib.sha256(result[1].encode()).digest()).decode().rstrip("=")
            self.assertEqual(params["code_challenge"], [challenge])
            with self.assertRaisesRegex(proof.ProofRefused, "attempt_closed"):
                attempt.accept_callback(callback)
            inputs.append(result)
        fake = Provider(NEGATIVE, POSITIVE, REVOKED)
        proof.verify(fake, "fixture-client", "fixture-secret", *inputs)
        self.assertEqual([call[1]["code"] for call in fake.calls[:2]], ["control", "positive"])
        self.assertNotEqual(inputs[0][1], inputs[1][1])

    def test_callback_refuses_other_path_cross_attempt_state_and_duplicate_values(self):
        attempt = proof.AuthorizationAttempt("fixture-client")
        state = parse_qs(urlsplit(attempt.url).query)["state"][0]
        other_state = parse_qs(urlsplit(proof.AuthorizationAttempt("fixture-client").url).query)["state"][0]
        with self.assertRaisesRegex(proof.ProofRefused, "invalid_callback"):
            attempt.accept_callback(f"/other?state={state}&code=fixture")
        with self.assertRaisesRegex(proof.ProofRefused, "invalid_state"):
            attempt.accept_callback(f"/google-drive-register?state={other_state}&code=fixture")
        with self.assertRaisesRegex(proof.ProofRefused, "invalid_state"):
            attempt.accept_callback(f"/google-drive-register?state={state}&state={state}&code=fixture")
        with self.assertRaisesRegex(proof.ProofRefused, "invalid_code"):
            attempt.accept_callback(f"/google-drive-register?state={state}&code=one&code=two")

    def test_denied_or_expired_callback_cannot_yield_proof(self):
        attempt = proof.AuthorizationAttempt("fixture-client")
        state = parse_qs(urlsplit(attempt.url).query)["state"][0]
        with self.assertRaisesRegex(proof.ProofRefused, "authorization_denied"):
            attempt.accept_callback(f"/google-drive-register?state={state}&error=access_denied&code=fixture")
        with self.assertRaisesRegex(proof.ProofRefused, "attempt_closed"):
            attempt.accept_callback(f"/google-drive-register?state={state}&code=fixture")
        now = [100]
        expired = proof.AuthorizationAttempt("fixture-client", clock=lambda: now[0])
        exp_state = parse_qs(urlsplit(expired.url).query)["state"][0]
        now[0] += 300
        with self.assertRaisesRegex(proof.ProofRefused, "attempt_closed"):
            expired.accept_callback(f"/google-drive-register?state={exp_state}&code=fixture")

    def test_exchanges_independent_codes_and_revokes_grant(self):
        fake = Provider(NEGATIVE, POSITIVE, REVOKED)
        self.run_proof(fake)
        control, positive, revoke = fake.calls
        self.assertNotEqual(control[1]["client_secret"], positive[1]["client_secret"])
        self.assertNotEqual(control[1]["code"], positive[1]["code"])
        self.assertEqual(control[1]["redirect_uri"], positive[1]["redirect_uri"])
        self.assertEqual(revoke, (proof.REVOKE["url"], {"token": "fixture-access"}))

    def test_non_discriminating_provider_does_not_get_correct_pair(self):
        fake = Provider((400, {"error": "invalid_grant"}))
        with self.assertRaisesRegex(proof.ProofRefused, "negative_control_failed"):
            self.run_proof(fake)
        self.assertEqual(len(fake.calls), 1)

    def test_unexpected_token_from_control_is_revoked_then_rejected(self):
        fake = Provider(POSITIVE, REVOKED)
        with self.assertRaisesRegex(proof.ProofRefused, "negative_control_failed"):
            self.run_proof(fake)
        self.assertEqual(len(fake.calls), 2)

    def test_bad_real_response_never_passes(self):
        fake = Provider(NEGATIVE, (200, {"token_type": "Bearer", "scope": "openid"}))
        with self.assertRaisesRegex(proof.ProofRefused, "client_proof_failed"):
            self.run_proof(fake)

    def test_revocation_unconfirmed_never_passes(self):
        fake = Provider(NEGATIVE, POSITIVE, (503, None))
        with self.assertRaisesRegex(proof.ProofRefused, "revocation_unconfirmed"):
            self.run_proof(fake)

    def test_reused_proof_is_rejected_before_network(self):
        fake = Provider()
        with self.assertRaisesRegex(proof.ProofRefused, "reused_proof"):
            proof.verify(fake, "client-id", "fixture-secret", ("same", "a"), ("same", "b"))
        self.assertFalse(fake.calls)


if __name__ == "__main__":
    unittest.main()
