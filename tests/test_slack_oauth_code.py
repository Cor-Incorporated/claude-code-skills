"""No provider, Vault or GitHub calls: exercise the actual runner through its storage gate."""
import contextlib
import copy
import html
import importlib.util
import io
import json
from pathlib import Path
import re
import stat
import socket
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import urllib.parse
import warnings

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("recipes", ROOT / "scripts/lib/secret_recipes.py")
recipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipes)
PAIR = {"client_id": "fixture-id", "client_secret": "fixture-secret"}
TOKEN = "fixture-access-token"
GOOD = {"ok": True, "app_id": "A0CDE0UUC79", "team": {"id": "T062U0CS2RJ"},
        "authed_user": {"id": "UCOMPANY", "scope": "users:read", "token_type": "user", "access_token": TOKEN}}


class CodeFlowTests(unittest.TestCase):
    def execute(self, *, control=None, real=None, revoke=None, callback="good", fresh=True, tty=True, dry=False,
                interrupted=False, mutation=None, expired=False, journal_error=False, echo_warning=None, ledger=False,
                transport_failure=False, unexpected_failure=False, port_busy=False):
        control = (200, {"ok": False, "error": "bad_client_secret"}) if control is None else control
        real = (200, copy.deepcopy(GOOD)) if real is None else real
        revoke = (200, {"ok": True, "revoked": True}) if revoke is None else revoke
        self.events, self.requests, self.work = [], [], None
        self.values_read = False
        self.output = io.StringIO()
        with tempfile.TemporaryDirectory() as parent:
            mkdir = recipes.tempfile.mkdtemp

            def tempdir(**kwargs):
                self.work = Path(mkdir(dir=parent, **kwargs))
                self.assertEqual(stat.S_IMODE(self.work.stat().st_mode), 0o700)
                return str(self.work)

            def hidden(_prompt):
                if echo_warning == "callback":
                    warnings.warn("echo unavailable", recipes.getpass.GetPassWarning)
                page = self.work / "authorize.html"
                self.assertEqual(stat.S_IMODE(page.stat().st_mode), 0o600)
                url = html.unescape(re.search(r'href="([^"]+)"', page.read_text()).group(1))
                params = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
                self.assertEqual(params["user_scope"], ["users:read"])
                self.assertEqual(params["team"], ["T062U0CS2RJ"])
                state = params["state"][0] if callback != "state" else "wrong-state"
                base = "https://127.0.0.1:8765/slack-register" if callback != "origin" else "https://evil.example/"
                result = base + "?" + urllib.parse.urlencode({"state": state, "code": "fixture-valid-code"})
                if callback == "duplicate":
                    result += "&code=other"
                if callback == "fragment":
                    result += "#fragment"
                return result

            def ask(net, values, *, request=None, form=None, received=None):
                actual = request or net.run.recipe["request"]
                method = actual["url"].rsplit("/", 1)[1]
                self.events.append(method)
                self.requests.append((dict(values), dict(form)))
                if method == "auth.revoke":
                    answer = copy.deepcopy(revoke)
                else:
                    answer = copy.deepcopy(control if len(self.requests) == 1 else real)
                if received:
                    received(answer[1])
                if transport_failure and method == "oauth.v2.access" and len(self.requests) == 2:
                    raise recipes.Refused(1, "unreachable", "fixture transport failure")
                if unexpected_failure and method == "oauth.v2.access" and len(self.requests) == 2:
                    raise ValueError("fixture unexpected failure")
                if interrupted and method == "oauth.v2.access" and len(self.requests) == 2:
                    raise SystemExit(143)
                return answer

            parse = recipes.Run.parse

            def load(run, argv):
                parse(run, argv)
                if mutation:
                    mutation(run.recipe)

            def read_values(run):
                self.values_read = True
                if echo_warning == "pair":
                    warnings.warn("echo unavailable", recipes.getpass.GetPassWarning)
                return dict(PAIR)

            write = recipes._slack_code.private_file

            def private(path, text):
                if journal_error and str(path).endswith("cleanup-pending.json"):
                    raise OSError("fixture disk full")
                return write(path, text)

            args = ["--recipe", "slack-oauth-code", "SLACK_OAUTH_CLIENT_ID", "SLACK_OAUTH_CLIENT_SECRET",
                    "Cor-Incorporated/cor-os", "--param", "user-id=UCOMPANY"]
            if fresh:
                args += ["--param", "fresh-grant=yes"]
            if dry:
                args += ["--dry-run"]
            with (mock.patch.object(recipes.tempfile, "mkdtemp", side_effect=tempdir),
                  mock.patch.object(recipes.Run, "read_values", new=read_values),
                  mock.patch.object(recipes.Run, "parse", new=load),
                  mock.patch.object(recipes.sys, "stdin", mock.Mock(isatty=lambda: tty)),
                  mock.patch.object(recipes._slack_code.getpass, "getpass", side_effect=hidden),
                  mock.patch.object(recipes._slack_code, "private_file", side_effect=private),
                  mock.patch.object(recipes._slack_code.socket, "socket") as reservation,
                  mock.patch.object(recipes.Network, "ask", autospec=True, side_effect=ask),
                  mock.patch.object(recipes._slack_code.time, "monotonic", side_effect=[0, 601] if expired else [0, 1]),
                  mock.patch.object(recipes, "store", side_effect=lambda *_: self.events.append("store")),
                  mock.patch.dict(recipes.os.environ, {
                      "AIDD_SECRET_LEDGER_LIB": str(ROOT / "hooks/lib/aidd-ledger.sh") if ledger else "",
                      "AIDD_LEDGER_PATH": str(Path(parent) / "ledger.jsonl"),
                      "AIDD_LEDGER_SOURCE": "test", "AIDD_LEDGER_AGENT": "codex"}),
                  contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output)):
                if port_busy:
                    reservation.return_value.__enter__.return_value.bind.side_effect = OSError("busy")
                try:
                    result = recipes.main(args)
                except SystemExit as exc:
                    result = exc.code
                reservation.return_value.__enter__.return_value.listen.assert_not_called()
                if self.values_read:
                    reservation.return_value.__exit__.assert_called_once()
            self.journal = self.work / "cleanup-pending.json"
            self.preserved = self.work.exists()
            self.pending = json.loads(self.journal.read_text()) if self.journal.exists() else None
            if self.journal.exists():
                self.assertEqual(stat.S_IMODE(self.journal.stat().st_mode), 0o600)
            self.ledger = (Path(parent) / "ledger.jsonl").read_text() if ledger else ""
            for value in [*PAIR.values(), TOKEN, "fixture-valid-code"]:
                self.assertNotIn(value, self.output.getvalue())
                self.assertNotIn(value, self.ledger)
            return result

    def test_success_requires_control_exchange_and_cleanup_in_order(self):
        self.assertEqual(self.execute(), 0)
        self.assertEqual(self.events, ["oauth.v2.access", "oauth.v2.access", "auth.revoke", "store"])
        self.assertNotEqual(self.requests[0][0]["client_secret"], PAIR["client_secret"])
        self.assertEqual(self.requests[1][0], PAIR)
        self.assertEqual(self.requests[0][1], self.requests[1][1])
        self.assertFalse(self.preserved)

    def test_dry_run_still_revokes_and_never_stores(self):
        self.assertEqual(self.execute(dry=True), 0)
        self.assertEqual(self.events, ["oauth.v2.access", "oauth.v2.access", "auth.revoke"])

    def test_indistinguishable_or_transient_controls_stop_before_real_pair(self):
        for status, doc in [(200, {"ok": False, "error": "invalid_code"}),
                            (200, {"ok": 0, "error": "bad_client_secret"}),
                            (200, {"error": "bad_client_secret"}),
                            (429, {"ok": False, "error": "bad_client_secret"}), (200, None)]:
            with self.subTest(status=status, doc=doc):
                self.assertEqual(self.execute(control=(status, doc)), 1)
                self.assertEqual(self.events, ["oauth.v2.access"])

    def test_callback_errors_send_nothing(self):
        for callback in ["state", "origin", "duplicate", "fragment"]:
            with self.subTest(callback=callback):
                self.assertEqual(self.execute(callback=callback), 1)
                self.assertEqual(self.events, [])

    def test_preconditions_send_nothing(self):
        for kwargs in [{"fresh": False}, {"tty": False}]:
            with self.subTest(kwargs=kwargs):
                self.assertEqual(self.execute(**kwargs), 1)
                self.assertEqual(self.events, [])

    def test_busy_callback_port_refuses_before_values(self):
        self.assertEqual(self.execute(port_busy=True), 1)
        self.assertFalse(self.values_read)
        self.assertEqual(self.events, [])

    def test_echo_fallback_is_refused_before_it_can_read_input(self):
        for stage in ["pair", "callback"]:
            self.assertEqual(self.execute(echo_warning=stage), 1)
            self.assertEqual(self.events, [])

    def test_journal_write_failure_does_not_skip_revocation(self):
        self.assertEqual(self.execute(journal_error=True), 1)
        self.assertEqual(self.events, ["oauth.v2.access", "oauth.v2.access", "auth.revoke"])
        self.assertTrue(self.preserved)
        self.assertIn("journaling failed", self.output.getvalue())

    def test_journal_and_revoke_failure_still_refuse_storage(self):
        self.assertEqual(self.execute(journal_error=True, revoke=(503, {})), 1)
        self.assertEqual(self.events[-1], "auth.revoke")
        self.assertTrue(self.preserved)
        self.assertNotIn("store", self.events)
        self.assertIn("recovery journal is unavailable", self.output.getvalue())
        self.assertNotIn("private recovery file:", self.output.getvalue())

    def test_failed_exchange_transport_cleans_received_token_and_warns(self):
        self.assertEqual(self.execute(transport_failure=True), 1)
        self.assertEqual(self.events[-1], "auth.revoke")
        self.assertNotIn("store", self.events)
        self.assertIn("outcome is unknown", self.output.getvalue())

    def test_unexpected_exchange_exception_cleans_up_and_warns(self):
        self.assertEqual(self.execute(unexpected_failure=True), 1)
        self.assertEqual(self.events[-1], "auth.revoke")
        self.assertNotIn("store", self.events)
        self.assertIn("outcome is unknown", self.output.getvalue())

    def test_ambiguous_exchange_json_refuses_and_warns_about_unknown_outcome(self):
        for doc in [{}, {"error": "invalid_code"}, {"ok": 1}, {"ok": True}]:
            with self.subTest(doc=doc):
                self.assertEqual(self.execute(real=(200, doc)), 1)
                self.assertNotIn("store", self.events)
                self.assertIn("outcome is unknown", self.output.getvalue())

    def test_real_ledger_receives_the_failed_control_without_values(self):
        self.assertEqual(self.execute(control=(200, {"ok": False, "error": "invalid_code"}), ledger=True), 1)
        row = json.loads(self.ledger.splitlines()[-1])
        self.assertEqual(row["rule"], "recipe-slack-oauth-code-control-failed")
        self.assertEqual(row["decision"], "deny")
        self.assertNotIn("store", self.events)

    def test_expired_authorization_window_sends_nothing(self):
        self.assertEqual(self.execute(expired=True), 1)
        self.assertEqual(self.events, [])

    def test_declaration_only_mutation_refuses_before_values_or_network(self):
        for mutation in [lambda r: r["grant"].update(user_scope="chat:write"),
                         lambda r: r["grant"].update(redirect_uri="https://evil.example/"),
                         lambda r: r["pass"].update(json={"ok": False}),
                         lambda r: r["control"]["fail_unless"].update(json={"ok": False, "error": "invalid_code"})]:
            self.assertEqual(self.execute(mutation=mutation), 1)
            self.assertEqual(self.events, [])

    def test_unexpected_identity_or_scope_revokes_and_does_not_store(self):
        variants = []
        for key, value in [("id", "UOTHER"), ("scope", "users:read,chat:write"), ("token_type", "bot")]:
            doc = copy.deepcopy(GOOD)
            doc["authed_user"][key] = value
            variants.append(doc)
        for key, value in [("app_id", "AOTHER"), ("team", {"id": "TOTHER"}), ("ok", 1), ("team", [])]:
            doc = copy.deepcopy(GOOD)
            doc[key] = value
            variants.append(doc)
        for doc in variants:
            with self.subTest(doc=doc):
                self.assertEqual(self.execute(real=(200, doc)), 1)
                self.assertEqual(self.events[-1], "auth.revoke")
                self.assertNotIn("store", self.events)

    def test_consumed_or_invalid_code_never_stores(self):
        self.assertEqual(self.execute(real=(200, {"ok": False, "error": "invalid_code"})), 1)
        self.assertNotIn("store", self.events)

    def test_unexpected_control_token_is_revoked_before_refusal(self):
        self.assertEqual(self.execute(control=(200, {"ok": True, "access_token": TOKEN})), 1)
        self.assertEqual(self.events, ["oauth.v2.access", "auth.revoke"])

    def test_bot_or_refresh_tokens_are_all_cleaned_up_and_refused(self):
        for key in ["access_token", "refresh_token"]:
            doc = copy.deepcopy(GOOD)
            doc[key] = "fixture-extra-token"
            self.assertEqual(self.execute(real=(200, doc)), 1)
            self.assertEqual(self.events.count("auth.revoke"), 2)
            self.assertNotIn("store", self.events)

    def test_revocation_failure_retains_private_recovery_and_never_stores(self):
        for status, doc in [(200, {"ok": True, "revoked": False}), (200, {"ok": 1, "revoked": True}),
                            (503, {"ok": True, "revoked": True}), (200, None)]:
            self.assertEqual(self.execute(revoke=(status, doc)), 1)
            self.assertEqual(self.pending, {"tokens": [TOKEN]})
            self.assertTrue(self.preserved)
            self.assertNotIn("store", self.events)

    def test_interruption_after_receipt_still_revokes_and_never_stores(self):
        self.assertEqual(self.execute(interrupted=True, ledger=True), 143)
        self.assertEqual(self.events[-1], "auth.revoke")
        self.assertFalse(self.preserved)
        self.assertNotIn("store", self.events)
        self.assertEqual(json.loads(self.ledger.splitlines()[-1])["rule"], "recipe-slack-oauth-code-interrupted")


class TransportTests(unittest.TestCase):
    def test_dynamic_form_is_encoded_once_and_values_never_enter_argv(self):
        run = recipes.Run(["--recipe", "slack-oauth-code", "SLACK_OAUTH_CLIENT_ID", "SLACK_OAUTH_CLIENT_SECRET",
                           "Cor-Incorporated/cor-os"])
        with tempfile.TemporaryDirectory() as work:
            def curl(argv, **kwargs):
                self.assertEqual(argv[-2], "-K")
                self.assertNotIn(PAIR["client_secret"], " ".join(argv))
                config = Path(argv[-1])
                self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
                conf = dict(re.findall(r'^(\S+) = "([^"\n]*)"$', config.read_text(), re.M))
                body = Path(conf["data-binary"][1:])
                self.assertEqual(stat.S_IMODE(body.stat().st_mode), 0o600)
                self.assertEqual(urllib.parse.parse_qs(body.read_text()), {"code": ["code+%&="]})
                Path(conf["output"]).write_text(json.dumps({"ok": True, "access_token": TOKEN}))
                return SimpleNamespace(stdout="200", returncode=1)

            seen = []
            net = recipes.Network(run, work)
            with mock.patch.object(recipes.subprocess, "run", side_effect=curl):
                with self.assertRaises(recipes.Refused):
                    net.ask(PAIR, form={"code": "code+%&="}, received=lambda d: seen.append(d))
            self.assertEqual(seen, [{"ok": True, "access_token": TOKEN}])
            self.assertEqual(list(Path(work).iterdir()), [])

    def test_override_cannot_send_tokens_to_another_host(self):
        run = recipes.Run(["--recipe", "slack-oauth-code", "SLACK_OAUTH_CLIENT_ID", "SLACK_OAUTH_CLIENT_SECRET",
                           "Cor-Incorporated/cor-os"])
        with tempfile.TemporaryDirectory() as work, mock.patch.object(recipes.subprocess, "run") as command:
            with self.assertRaises(recipes.Refused):
                recipes.Network(run, work).ask({}, request={"url": "https://evil.example/"}, form={"token": TOKEN})
            command.assert_not_called()


class LoopbackReservationTests(unittest.TestCase):
    def test_non_listening_reservation_excludes_other_binds_and_refuses_connections(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            endpoint = reservation.getsockname()
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as other:
                with self.assertRaises(OSError):
                    other.bind(endpoint)
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                client.settimeout(1)
                self.assertNotEqual(client.connect_ex(endpoint), 0)

    def test_later_reused_wildcard_listener_cannot_receive_the_reserved_callback(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            endpoint = reservation.getsockname()
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as other:
                other.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    other.bind(("0.0.0.0", endpoint[1]))
                    other.listen(1)
                except OSError:
                    return  # OS denied the overlap altogether, also safe.
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                    client.settimeout(0.1)
                    self.assertNotEqual(client.connect_ex(endpoint), 0)
                other.settimeout(0.1)
                with self.assertRaises(socket.timeout):
                    other.accept()


if __name__ == "__main__":
    unittest.main()
