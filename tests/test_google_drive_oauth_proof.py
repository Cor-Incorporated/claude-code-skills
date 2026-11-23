import importlib.util
import unittest
from pathlib import Path

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
