"""Offline Access contracts and their counterexamples. No external requests."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("access_service_token", Path(__file__).resolve().parents[1] / "scripts/lib/access_service_token.py")
ACCESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ACCESS)
CONFIG = dict(account_id="9973f2d2304b58a1f90d4d9409e9f8cc", service_token_id="00e4af01-4b7b-4f77-a6c7-2038d2c26050",
              service_token_name="cor-os-llm-router", app_id="07144d8d-0512-4ce1-943a-a72def65aac0", app_name="Cor OS Ollama Origins",
              policy_id="c0fcff31-7e27-441c-bdc2-a454fb7ab062", policy_name="LLMルーターのみ",
              origins=["llm-origin-" + x + ".cor-jp.com" for x in "abcf"], probe_path="/v1/models", values=["client_id", "client_secret"])
BASE = "https://api.cloudflare.com/client/v4/accounts/" + CONFIG["account_id"]
MANAGER, CLIENT, SECRET = "offline-management-credential", "offline-access-client", "offline-new-secret"


class FrozenDateTime(datetime):
    @classmethod
    def now(cls, tz=None):
        current = cls(2026, 11, 1, 15, 5, tzinfo=timezone.utc)
        return current if tz is None else current.astimezone(tz)


class Refused(Exception):
    def __init__(self, code, rule, message):
        super().__init__(message)
        self.code, self.rule, self.message = code, rule, message


def fixtures():
    token = dict(id=CONFIG["service_token_id"], name=CONFIG["service_token_name"], enabled=True, client_id=CLIENT,
                 created_at="2026-08-15T00:11:26Z", updated_at="2026-08-15T00:12:15Z", expires_at="2027-08-15T00:11:26Z",
                 duration="8760h", previous_client_secret_expires_at="2026-08-15T00:12:15Z")
    policy = dict(id=CONFIG["policy_id"], name=CONFIG["policy_name"], decision="non_identity", reusable=True, app_count=1,
                  include=[{"service_token": {"token_id": CONFIG["service_token_id"]}}], require=[], exclude=[])
    app = dict(id=CONFIG["app_id"], name=CONFIG["app_name"], type="self_hosted", domain=CONFIG["origins"][0],
               self_hosted_domains=CONFIG["origins"].copy(), destinations=[{"type": "public", "uri": h} for h in CONFIG["origins"]],
               policies=[copy.deepcopy(policy)])
    unrelated = dict(id="other-app", type="self_hosted", domain="os.cor-jp.com", self_hosted_domains=["os.cor-jp.com"],
                     destinations=[{"type": "public", "uri": "os.cor-jp.com"}])
    portal = dict(id="mcp-app", type="mcp", domain=None, self_hosted_domains=None,
                  destinations=[{"type": "via_mcp_server_portal", "mcp_server_id": "offline"}])
    return token, app, policy, [unrelated, portal, copy.deepcopy(app)]


class FakeTransport:
    def __init__(self, work, fail=None):
        self.work, self.fail = work, fail
        self.token, self.app, self.policy, self.apps = fixtures()
        self.global_policies = [self.policy]
        self.app_policies = {CONFIG["app_id"]: [self.policy]}
        self.requests, self.responses, self.extra_pages = [], {}, {}
        self.rotation_transform = self.after_transform = lambda value: value
        self.api_response = lambda path, pair: pair
        self.rotate_exception = self.fleet_info = None

    def request(self, url, headers, payload=None, result_path=None):
        self.requests.append(dict(url=url, headers=copy.deepcopy(headers), payload=copy.deepcopy(payload)))
        if url.startswith(BASE):
            assert headers.get("Authorization") == "Bearer " + MANAGER
            assert not any(k.startswith("CF-Access") for k in headers)
            path = url[len(BASE):]
            if path.endswith("/rotate"):
                assert payload == {"previous_client_secret_expires_at": self.token["expires_at"]}, "old expiry omitted or changed"
                after = dict(self.token, updated_at="2026-11-01T15:05:00Z", previous_client_secret_expires_at=self.token["expires_at"])
                value = self.rotation_transform(dict(after, client_secret=SECRET))
                self.token = self.after_transform(after)
                doc = {"success": True, "result": value}
                ACCESS.private_file(result_path, json.dumps(doc))
                if self.rotate_exception:
                    raise self.rotate_exception
            elif path == "/access/service_tokens/" + CONFIG["service_token_id"]:
                doc = {"success": True, "result": copy.deepcopy(self.token)}
            elif path == "/access/apps/" + CONFIG["app_id"]:
                doc = {"success": True, "result": copy.deepcopy(self.app)}
            elif path == "/access/policies/" + CONFIG["policy_id"]:
                doc = {"success": True, "result": copy.deepcopy(self.policy)}
            elif path == "/access/apps/" + CONFIG["app_id"] + "/policies":
                doc = {"success": True, "result": [copy.deepcopy(self.policy)]}
            elif path == "/access/apps?per_page=100&page=1":
                info = self.fleet_info or dict(page=1, per_page=100, count=len(self.apps), total_count=len(self.apps), total_pages=1)
                doc = {"success": True, "result": copy.deepcopy(self.apps), "result_info": copy.deepcopy(info)}
            elif path == "/access/policies?per_page=100&page=1":
                doc = self.policy_page(self.global_policies)
            elif re.fullmatch(r"/access/apps/[^/]+/policies\?per_page=100&page=1", path):
                doc = self.policy_page(self.app_policies.get(path.split("/")[3], []))
            elif path in self.extra_pages:
                doc = copy.deepcopy(self.extra_pages[path])
            else:
                raise AssertionError("unexpected offline path")
            return self.api_response(path, (200, doc))
        assert "Authorization" not in headers
        secret = headers.get("CF-Access-Client-Secret")
        stage = "baseline" if secret is None else "real" if secret == SECRET else "control"
        if (stage, url) in self.responses:
            value = self.responses[stage, url]
            if isinstance(value, BaseException):
                raise value
            return value
        if stage == "real":
            assert headers.get("CF-Access-Client-Id") == CLIENT
            return 200, {"object": "list", "data": [{"id": "offline-model"}]}
        return 403, None

    @staticmethod
    def policy_page(items):
        return dict(success=True, result=copy.deepcopy(items),
                    result_info=dict(page=1, per_page=100, count=len(items), total_count=len(items), total_pages=1))


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.reset()

    def reset(self):
        self.work = tempfile.mkdtemp(dir=self.tmp.name)
        self.run = SimpleNamespace(recipe=copy.deepcopy(CONFIG), repo="Cor-Incorporated/cor-os", env="", names=["CF_ACCESS_CLIENT_ID", "CF_ACCESS_CLIENT_SECRET"],
                                   params={"rotate-confirmed": "yes"}, dry=False, preserve_work=False, detail="")
        self.net, self.out = FakeTransport(self.work), io.StringIO()

    def call(self):
        def factory(work, fail):
            self.net.fail = fail
            return self.net
        with patch.object(ACCESS, "datetime", FrozenDateTime), patch.object(sys, "stdin", io.StringIO(MANAGER)), redirect_stdout(self.out), redirect_stderr(self.out):
            return ACCESS.verify(self.run, self.work, Refused, transport_factory=factory)

    def refused(self, rule=None):
        with self.assertRaises(Refused) as caught:
            self.call()
        if rule:
            self.assertEqual(caught.exception.rule, "access-" + rule)
        for value in (MANAGER, CLIENT, SECRET):
            self.assertNotIn(value, self.out.getvalue() + str(caught.exception) + self.run.detail)
        return caught.exception

    def rotations(self):
        return [r for r in self.net.requests if r["url"].endswith("/rotate")]

    def reals(self):
        return [r for r in self.net.requests if r["headers"].get("CF-Access-Client-Secret") == SECRET]

    def test_success_preserves_old_expiry_and_recovery_until_storage(self):
        self.assertEqual(self.call(), {"client_id": CLIENT, "client_secret": SECRET})
        self.assertEqual(len(self.rotations()), 1)
        self.assertEqual(self.rotations()[0]["payload"], {"previous_client_secret_expires_at": "2027-08-15T00:11:26Z"})
        self.assertEqual(len(self.reals()), 4)
        self.assertTrue(self.run.preserve_work)
        self.assertIn("control=4/4 denied; real=4/4", self.run.detail)
        self.assertIn("old-expiry-preserved", self.run.detail)
        for name in ("rotation-state.json", "rotation-result.json"):
            path = Path(self.work, name)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertNotIn(MANAGER, path.read_text())
        self.assertNotIn(SECRET, self.out.getvalue())

    def test_dry_run_never_rotates_or_verifies_a_pair(self):
        self.run.dry = True
        self.assertIsNone(self.call())
        self.assertFalse(self.rotations() or self.reals() or self.run.preserve_work)
        self.assertEqual(list(Path(self.work).iterdir()), [])
        self.assertIn("no rotation or pair verification", self.run.detail)

    def test_fixed_registration_contract(self):
        for key, value in (("repo", "other/repo"), ("env", "production"), ("names", ["WRONG_ID", "WRONG_SECRET"]),
                           ("params", {}), ("params", {"rotate-confirmed": "no"}), ("params", {"rotate-confirmed": "yes", "host": "evil.example"})):
            with self.subTest(key=key, value=value):
                self.reset(); setattr(self.run, key, value)
                self.refused("contract")
                self.assertFalse(self.net.requests)

    def test_recipe_resource_and_host_contracts(self):
        for key, value in (("account_id", "../account"), ("app_id", "wrong"), ("origins", CONFIG["origins"][:3]),
                           ("origins", CONFIG["origins"] + ["extra.example"]), ("origins", [CONFIG["origins"][0]] * 4),
                           ("origins", ["https://evil.example"] + CONFIG["origins"][1:]), ("probe_path", "/v1/chat/completions")):
            with self.subTest(key=key):
                self.reset(); self.run.recipe[key] = value
                self.refused("contract")
                self.assertFalse(self.net.requests)

    def test_nonprivate_directory_and_bad_management_input(self):
        os.chmod(self.work, 0o755)
        self.refused("input")
        self.assertFalse(self.net.requests)
        def fail(rule, text):
            raise Refused(1, rule, text)
        for value in ("", "first\nsecond", "has\tcontrol", "x" * 262145):
            with self.subTest(length=len(value)), patch.object(sys, "stdin", io.StringIO(value)), self.assertRaises(Refused):
                ACCESS.management_token(fail)

    def test_disabled_expired_wrong_or_malformed_token(self):
        for field, value in (("enabled", False), ("id", "different"), ("name", "different"), ("expires_at", "2026-11-01T15:05:00Z"),
                             ("created_at", "bad-date"), ("updated_at", "2026-08-15T00:12:15"), ("client_id", "bad\nheader")):
            with self.subTest(field=field):
                self.reset(); self.net.token[field] = value
                self.refused("metadata")
                self.assertFalse(self.rotations())

    def test_active_old_overlap_prevents_a_second_rotation(self):
        self.net.token["previous_client_secret_expires_at"] = "2027-08-15T00:11:26Z"
        self.refused("overlap")
        self.assertFalse(self.rotations())

    def test_missing_or_invalid_duration_blocks_before_rotation(self):
        missing = object()
        for value in (missing, None, "", 123):
            with self.subTest(value="missing" if value is missing else value):
                self.reset()
                if value is missing:
                    self.net.token.pop("duration")
                else:
                    self.net.token["duration"] = value
                self.net.rotation_transform = lambda doc: dict(doc, duration="8760h")
                self.refused("metadata")
                self.assertFalse(self.rotations())

    def test_policy_differences_block_rotation(self):
        for field, value in (("decision", "allow"), ("include", [{"everyone": {}}]), ("require", [{"everyone": {}}]),
                             ("exclude", [{"everyone": {}}]), ("reusable", False), ("reusable", 1), ("app_count", 2), ("app_count", True)):
            with self.subTest(field=field):
                self.reset(); self.net.policy[field] = value
                self.refused("policy")
                self.assertFalse(self.rotations())

    def test_inline_and_attached_policy_lists_are_both_checked(self):
        self.net.app["policies"][0]["decision"] = "bypass"
        self.refused("policy")
        self.reset()
        self.net.api_response = lambda path, pair: (200, {"success": True, "result": []}) if path.endswith("/policies") else pair
        self.refused("policy")
        self.assertFalse(self.rotations())

    def test_origin_and_destination_difference_blocks_rotation(self):
        for field, value in (("self_hosted_domains", CONFIG["origins"][:3]), ("self_hosted_domains", CONFIG["origins"] + ["extra.example"]),
                             ("destinations", [{"type": "public", "uri": x} for x in CONFIG["origins"][:3]]), ("domain", "*.cor-jp.com"), ("type", "saas")):
            with self.subTest(field=field):
                self.reset(); self.net.app[field] = value
                self.refused("app")
                self.assertFalse(self.rotations())

    def test_shadow_app_wildcard_path_or_destination_blocks_rotation(self):
        for field, value in (("domain", "*.cor-jp.com"), ("domain", CONFIG["origins"][0] + "/v1/models"),
                             ("self_hosted_domains", [CONFIG["origins"][1]]), ("destinations", [{"type": "public", "uri": CONFIG["origins"][2]}])):
            with self.subTest(field=field):
                self.reset(); self.net.apps[0][field] = value
                self.refused("fleet")
                self.assertFalse(self.rotations())

    def test_missing_target_duplicate_id_or_extra_origin_in_inventory(self):
        self.net.apps.pop()
        self.refused("fleet")
        self.reset(); self.net.apps.append(copy.deepcopy(self.net.apps[0]))
        self.refused("fleet")
        self.reset(); self.net.apps[-1]["destinations"].append({"type": "public", "uri": "extra.example"})
        self.refused("fleet")
        self.assertFalse(self.rotations())

    def another_policy(self, selectors=None, reusable=False):
        return dict(id="11111111-1111-4111-8111-111111111111", decision="non_identity", name="offline unrelated",
                    include=[] if selectors is None else selectors, require=[], exclude=[], reusable=reusable, app_count=0)

    def test_service_token_on_another_app_distinct_policy_blocks_before_rotation(self):
        reference = [{"service_token": {"token_id": CONFIG["service_token_id"]}}]
        self.net.app_policies["other-app"] = [self.another_policy(reference, reusable=True)]
        self.refused("token-use")
        self.assertFalse(self.rotations())

    def test_legacy_policy_nested_token_reference_in_any_condition_is_rejected(self):
        for condition in ("include", "require", "exclude"):
            with self.subTest(condition=condition):
                self.reset()
                policy = self.another_policy()
                policy[condition] = [{"nested": [{"service_token": {"token_id": CONFIG["service_token_id"]}}]}]
                self.net.app_policies["other-app"] = [policy]
                self.refused("token-use")
                self.assertFalse(self.rotations())

    def test_global_unattached_token_reference_is_also_rejected(self):
        self.net.global_policies.append(self.another_policy([{"service_token": {"token_id": CONFIG["service_token_id"]}}], reusable=True))
        self.refused("token-use")
        self.assertFalse(self.rotations())

    def test_matching_service_token_tag_is_rejected_in_global_and_attached_policy(self):
        for scope in ("global", "attached"):
            with self.subTest(scope=scope):
                self.reset()
                self.net.token["tags"] = {"service": "cor-os"}
                policy = self.another_policy([{"service_token_tag": {"key": "service", "value": "cor-os"}}])
                if scope == "global":
                    self.net.global_policies.append(policy)
                else:
                    self.net.app_policies["other-app"] = [policy]
                self.refused("token-use")
                self.assertFalse(self.rotations())

    def test_unreviewed_selector_forms_are_rejected_in_global_and_attached_policy(self):
        selectors = [{"linked_app_token": {"app_uid": CONFIG["app_id"]}}, {"future_selector": {}},
                     {"everyone": {}}, {"ip": {"ip": "192.0.2.1"}}, {"group": {"id": "offline-group"}},
                     {"any_valid_service_token": {}}]
        for scope in ("global", "attached"):
            for selector in selectors:
                with self.subTest(scope=scope, selector=next(iter(selector))):
                    self.reset()
                    policy = self.another_policy([selector])
                    if scope == "global":
                        self.net.global_policies.append(policy)
                    else:
                        self.net.app_policies["other-app"] = [policy]
                    self.refused("token-use")
                    self.assertFalse(self.rotations())

    def test_unknown_policy_decision_is_rejected_before_rotation(self):
        for decision in (None, "", "bypass", "deny", "future_decision", True, {}):
            with self.subTest(decision=decision):
                self.reset()
                policy = self.another_policy()
                policy["decision"] = decision
                self.net.app_policies["other-app"] = [policy]
                self.refused("token-use")
                self.assertFalse(self.rotations())

    def test_selector_item_and_inner_value_must_match_one_closed_form(self):
        cases = [("allow", {"email": {"email": "offline@example.com"}, "login_method": {"id": "offline-id"}}),
                 ("allow", {"email": {"email": "offline@example.com", "extra": "unreviewed"}}),
                 ("allow", {"email": {"email": {"nested": "offline@example.com"}}}),
                 ("allow", {"service_token": {"token_id": "other-token"}}),
                 ("non_identity", {"email": {"email": "offline@example.com"}}),
                 ("non_identity", {"service_token": {"token_id": "other-token", "extra": "unreviewed"}}),
                 ("non_identity", {"service_token": {"token_id": 123}}),
                 ("non_identity", {"service_token": {"token_id": ""}}),
                 ("non_identity", {"service_token": {"token_id": "  "}}), ("allow", "unknown-scalar")]
        for condition in ("include", "require", "exclude"):
            for decision, item in cases:
                with self.subTest(condition=condition, decision=decision, item=item):
                    self.reset()
                    policy = self.another_policy()
                    policy["decision"] = decision
                    policy[condition] = [item]
                    self.net.app_policies["other-app"] = [policy]
                    self.refused("token-use")
                    self.assertFalse(self.rotations())

    def test_current_three_identity_selector_forms_are_allowed(self):
        for scope in ("global", "attached"):
            with self.subTest(scope=scope):
                self.reset()
                policy = self.another_policy()
                policy.update(decision="allow", include=[{"email": {"email": "offline@example.com"}}],
                              require=[{"login_method": {"id": "offline-idp"}}],
                              exclude=[{"email_domain": {"domain": "blocked.example"}}])
                if scope == "global":
                    self.net.global_policies.append(policy)
                else:
                    self.net.app_policies["other-app"] = [policy]
                self.assertEqual(self.call(), {"client_id": CLIENT, "client_secret": SECRET})
                self.assertEqual(len(self.rotations()), 1)
                self.assertEqual(len(self.reals()), 4)

    def test_group_or_any_valid_token_is_rejected_without_groups_api(self):
        for scope in ("global", "attached"):
            for selector in ({"group": {"id": "offline-group"}}, {"any_valid_service_token": {}}):
                with self.subTest(scope=scope, selector=next(iter(selector))):
                    self.reset()
                    policy = self.another_policy([{ "nested": [selector]}])
                    if scope == "global":
                        self.net.global_policies.append(policy)
                    else:
                        self.net.app_policies["mcp-app"] = [policy]
                    self.refused("token-use")
                    self.assertFalse(self.rotations())
                    self.assertFalse(any("/groups" in request["url"] for request in self.net.requests))

    def test_legacy_other_token_is_allowed_and_all_apps_are_read(self):
        self.net.app_policies["other-app"] = [self.another_policy([{"service_token": {"token_id": "22222222-2222-4222-8222-222222222222"}}])]
        self.run.dry = True
        self.assertIsNone(self.call())
        read = {request["url"] for request in self.net.requests}
        for app in self.net.apps:
            self.assertIn(BASE + "/access/apps/" + app["id"] + "/policies?per_page=100&page=1", read)
        self.assertIn(BASE + "/access/policies?per_page=100&page=1", read)

    def test_policy_page_count_missing_and_http_failure_block_before_rotation(self):
        for suffix in ("/access/policies?per_page=100&page=1", "/access/apps/other-app/policies?per_page=100&page=1"):
            for kind in ("pagination", "http"):
                with self.subTest(suffix=suffix, kind=kind):
                    self.reset()
                    def change(path, pair):
                        if path == suffix:
                            if kind == "http":
                                return 503, None
                            pair[1].pop("result_info")
                        return pair
                    self.net.api_response = change
                    self.refused("policy-fleet" if kind == "pagination" else "api")
                    self.assertFalse(self.rotations())

    def test_global_policy_target_is_unique_and_must_match(self):
        self.net.global_policies = []
        self.refused("token-use")
        self.assertFalse(self.rotations())
        self.reset()
        self.net.global_policies.append(copy.deepcopy(self.net.policy))
        self.refused("policy-fleet")
        self.assertFalse(self.rotations())

    def test_policy_second_page_missing_duplicate_or_token_reference(self):
        for scope in ("global", "attached"):
            for outcome in ("missing", "duplicate", "reference"):
                with self.subTest(scope=scope, outcome=outcome):
                    self.reset()
                    items = [dict(self.another_policy(), id="offline-policy-%d" % i) for i in range(100)]
                    if scope == "global":
                        items[0] = self.net.policy
                        self.net.global_policies = items
                        path = "/access/policies"
                    else:
                        self.net.app_policies["other-app"] = items
                        path = "/access/apps/other-app/policies"
                    tail = self.another_policy()
                    if outcome == "duplicate":
                        tail = copy.deepcopy(items[0])
                    elif outcome == "reference":
                        tail["include"] = [{"service_token": {"token_id": CONFIG["service_token_id"]}}]
                    page = dict(success=True, result=[tail], result_info=dict(page=2, per_page=100, count=1, total_count=101, total_pages=2))
                    if outcome == "missing":
                        page.pop("result_info")
                    self.net.extra_pages[path + "?per_page=100&page=2"] = page
                    def paginate(request_path, pair):
                        if request_path == path + "?per_page=100&page=1":
                            pair[1]["result_info"].update(total_count=101, total_pages=2)
                        return pair
                    self.net.api_response = paginate
                    self.refused("token-use" if outcome == "reference" else "policy-fleet")
                    self.assertFalse(self.rotations())

    def test_unknown_condition_or_token_selector_shape_blocks_before_rotation(self):
        missing = object()
        for value in (missing, None, "not-a-list", ["not-a-selector"], [{"service_token": None}], [{"service_token": {}}]):
            with self.subTest(value="missing" if value is missing else value):
                self.reset()
                policy = self.another_policy()
                if value is missing:
                    policy.pop("include")
                else:
                    policy["include"] = value
                self.net.app_policies["other-app"] = [policy]
                self.refused("policy-fleet" if value is missing or not isinstance(value, list) else "token-use")
                self.assertFalse(self.rotations())

    def test_target_queried_policy_cannot_differ_from_direct_readback(self):
        for path in ("/access/policies?per_page=100&page=1", "/access/apps/" + CONFIG["app_id"] + "/policies?per_page=100&page=1"):
            with self.subTest(path=path):
                self.reset()
                def change(request_path, pair):
                    if request_path == path:
                        pair[1]["result"][0]["decision"] = "allow"
                    return pair
                self.net.api_response = change
                self.refused("token-use" if path.startswith("/access/policies?") else "policy")
                self.assertFalse(self.rotations())

    def test_other_app_token_reference_after_rotation_or_probe_is_rechecked(self):
        for phase in ("after-rotation", "after-probes"):
            with self.subTest(phase=phase):
                self.reset()
                original = self.net.request
                def drift(url, headers, **kwargs):
                    result = original(url, headers, **kwargs)
                    if ((phase == "after-rotation" and url.endswith("/rotate")) or
                            (phase == "after-probes" and url.endswith(CONFIG["origins"][-1] + "/v1/models") and
                             headers.get("CF-Access-Client-Secret") == SECRET)):
                        self.net.app_policies["other-app"] = [self.another_policy([{"service_token": {"token_id": CONFIG["service_token_id"]}}])]
                    return result
                self.net.request = drift
                self.refused("token-use")
                self.assertEqual(len(self.rotations()), 1)
                self.assertEqual(len(self.reals()), 4 if phase == "after-probes" else 0)
                self.assertTrue(self.run.preserve_work)

    def test_incomplete_or_unstable_pagination_blocks_rotation(self):
        for info in (dict(page=2, per_page=100, count=3, total_count=3, total_pages=1), dict(page=1, per_page=100, count=2, total_count=3, total_pages=1),
                     dict(page=1, per_page=100, count=3, total_count=4, total_pages=1), dict(page=1, per_page=100, count=3, total_count=101, total_pages=1),
                     dict(page=1, per_page=100, count=3, total_count=2001, total_pages=21)):
            with self.subTest(info=info):
                self.reset(); self.net.fleet_info = info
                self.refused("fleet")
                self.assertFalse(self.rotations())

    def test_complete_pagination_is_read_and_drift_is_rejected(self):
        def prepare():
            self.net.apps += [dict(id="extra-%d" % i, domain="unused-%d.example" % i) for i in range(97)]
            self.net.fleet_info = dict(page=1, per_page=100, count=100, total_count=101, total_pages=2)
            self.net.extra_pages["/access/apps?per_page=100&page=2"] = dict(success=True, result=[dict(id="last", domain="last.example")],
                result_info=dict(page=2, per_page=100, count=1, total_count=101, total_pages=2))
        self.run.dry = True; prepare()
        self.assertIsNone(self.call())
        self.reset(); prepare()
        self.net.extra_pages["/access/apps?per_page=100&page=2"]["result_info"]["total_count"] = 102
        self.refused("fleet")

    def test_unknown_management_status_or_json_blocks_rotation(self):
        for response in ((403, {"success": False}), (429, None), (500, {}), (200, None), (200, {"success": 1, "result": {}}), (200, {"success": True})):
            with self.subTest(response=response):
                self.reset(); self.net.api_response = lambda path, pair: response
                self.refused("api")
                self.assertFalse(self.rotations())

    def test_unauthenticated_success_or_unknown_status_blocks_before_rotation(self):
        for status in (200, 302, 401, 429, 500, 0):
            with self.subTest(status=status):
                self.reset(); self.net.responses["baseline", "https://" + CONFIG["origins"][3] + "/v1/models"] = (status, None)
                self.refused("baseline")
                self.assertFalse(self.rotations())

    def test_wrong_rotation_fields_or_shortened_old_expiry_are_retained_and_refused(self):
        for field, value in (("id", "different"), ("client_id", "different"), ("client_secret", ""), ("name", "different"), ("enabled", False),
                             ("duration", "1h"), ("expires_at", "2026-11-01T15:06:00Z"), ("previous_client_secret_expires_at", "2026-11-01T15:06:00Z"),
                             ("updated_at", "2026-08-15T00:12:15Z")):
            with self.subTest(field=field):
                self.reset(); self.net.rotation_transform = lambda doc: dict(doc, **{field: value})
                self.refused()
                self.assertTrue(self.run.preserve_work)
                self.assertEqual(len(self.rotations()), 1)
                self.assertFalse(self.reals())
                self.assertTrue(Path(self.work, "rotation-result.json").exists())

    def test_documented_optional_rotation_expiry_still_requires_get_readback(self):
        def omit(doc):
            for key in ("expires_at", "previous_client_secret_expires_at"):
                doc.pop(key)
            return doc
        self.net.rotation_transform = omit
        self.assertEqual(self.call()["client_secret"], SECRET)

    def test_post_rotation_readback_must_preserve_old_expiry(self):
        self.net.after_transform = lambda token: dict(token, previous_client_secret_expires_at="2026-11-01T15:05:00Z")
        self.refused("readback")
        self.assertTrue(self.run.preserve_work)
        self.assertFalse(self.reals())

    def test_policy_or_token_drift_during_probes_blocks_returning_the_pair(self):
        for drift in ("policy", "token"):
            with self.subTest(drift=drift):
                self.reset()
                original = self.net.request
                def drifting(url, headers, **kwargs):
                    result = original(url, headers, **kwargs)
                    if url.endswith(CONFIG["origins"][-1] + "/v1/models") and headers.get("CF-Access-Client-Secret") == SECRET:
                        if drift == "policy":
                            self.net.policy["include"] = [{"everyone": {}}]
                        else:
                            self.net.token["updated_at"] = "2026-11-01T15:05:01Z"
                    return result
                self.net.request = drifting
                self.refused("policy" if drift == "policy" else "readback")
                self.assertEqual(len(self.reals()), 4)
                self.assertTrue(self.run.preserve_work)

    def test_rotation_timeout_or_interrupt_retains_outcome_without_retry(self):
        for error in (TimeoutError("offline timeout"), SystemExit(143)):
            with self.subTest(error=type(error).__name__):
                self.reset(); self.net.rotate_exception = error
                with self.assertRaises(type(error)):
                    self.call()
                self.assertTrue(self.run.preserve_work)
                self.assertEqual(len(self.rotations()), 1)
                self.assertTrue(Path(self.work, "rotation-result.json").exists())
                self.assertFalse(self.reals())

    def test_wrong_secret_success_is_refused_before_any_real_probe(self):
        self.net.responses["control", "https://" + CONFIG["origins"][3] + "/v1/models"] = (200, {"object": "list", "data": []})
        self.refused("control")
        self.assertTrue(self.run.preserve_work)
        self.assertFalse(self.reals())

    def test_unknown_wrong_secret_response_never_counts_as_a_control(self):
        for status in (302, 401, 429, 500, 0):
            with self.subTest(status=status):
                self.reset(); self.net.responses["control", "https://" + CONFIG["origins"][0] + "/v1/models"] = (status, None)
                self.refused("control")
                self.assertFalse(self.reals())

    def test_every_real_origin_must_return_models_json(self):
        for response in ((403, None), (302, None), (429, None), (500, None), (200, None), (200, {"ok": True}),
                         (200, {"object": "list", "data": "wrong"}), (200, {"object": "list", "data": ["wrong"]}),
                         (200, {"object": "list", "data": [{"id": ""}]})):
            with self.subTest(response=response):
                self.reset(); self.net.responses["real", "https://" + CONFIG["origins"][3] + "/v1/models"] = response
                self.refused("probe")
                self.assertEqual(len(self.reals()), 4)
                self.assertTrue(self.run.preserve_work)

    def test_controls_precede_real_and_no_inference_or_cross_target_auth(self):
        self.call()
        stages = []
        for request in self.net.requests:
            if request["url"].startswith(BASE):
                self.assertNotIn(SECRET, request["headers"].values())
            else:
                self.assertIn(request["url"], ["https://" + host + "/v1/models" for host in CONFIG["origins"]])
                self.assertIsNone(request["payload"])
                self.assertNotIn("Authorization", request["headers"])
                stages.append(request["headers"].get("CF-Access-Client-Secret"))
        self.assertEqual(stages[:4], [None] * 4)
        self.assertEqual(len(stages), 12)
        self.assertTrue(all(x not in (None, SECRET) for x in stages[4:8]))
        self.assertEqual(stages[8:], [SECRET] * 4)


class RecoveryTests(unittest.TestCase):
    call, refused = VerifyTests.call, VerifyTests.refused
    rotations, reals = VerifyTests.rotations, VerifyTests.reals

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.work, self.source = tempfile.mkdtemp(dir=self.tmp.name), tempfile.mkdtemp(dir=self.tmp.name)
        self.run = SimpleNamespace(recipe=dict(copy.deepcopy(CONFIG), operation="recover"), repo="Cor-Incorporated/cor-os", env="",
                                   names=["CF_ACCESS_CLIENT_ID", "CF_ACCESS_CLIENT_SECRET"], params={"recovery-dir": self.source},
                                   dry=False, preserve_work=False, detail="")
        self.net, self.out = FakeTransport(self.work), io.StringIO()
        self.net.token.update(updated_at="2026-11-01T15:05:00Z", previous_client_secret_expires_at=self.net.token["expires_at"])
        self.state = dict(phase="rotation-outcome-pending", service_token_id=CONFIG["service_token_id"],
                          previous_client_secret_expires_at=self.net.token["expires_at"],
                          preflight_updated_at="2026-08-15T00:12:15Z", started_at="2026-11-01T15:05:00.123456+00:00")
        self.response = dict(success=True, result=dict(self.net.token, client_secret=SECRET))
        for name, value in (("rotation-state.json", self.state), ("rotation-result.json", self.response)):
            ACCESS.private_file(os.path.join(self.source, name), json.dumps(value))

    def snapshot(self):
        result = {}
        for path in [Path(self.source)] + sorted(Path(self.source).iterdir()):
            info = path.lstat()
            result[path.name] = ((info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink, info.st_size, info.st_mtime_ns),
                                 path.read_bytes() if stat.S_ISREG(info.st_mode) else None)
        return result

    def write_source(self):
        for name, value in (("rotation-state.json", self.state), ("rotation-result.json", self.response)):
            Path(self.source, name).write_text(json.dumps(value))

    def checked_refusal(self, rule=None):
        before = self.snapshot()
        self.refused(rule)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.rotations())
        self.assertTrue(all(request["payload"] is None for request in self.net.requests))

    def test_same_pair_recovery_never_rotates_and_copies_raw_without_changing_source(self):
        before = self.snapshot()
        self.assertEqual(self.call(), {"client_id": CLIENT, "client_secret": SECRET})
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.rotations())
        self.assertTrue(all(request["payload"] is None for request in self.net.requests))
        self.assertTrue(self.run.preserve_work)
        self.assertEqual(len(self.reals()), 4)
        for name in ("rotation-state.json", "rotation-result.json"):
            copy_path = Path(self.work, name)
            self.assertEqual(copy_path.read_bytes(), Path(self.source, name).read_bytes())
            self.assertEqual(stat.S_IMODE(copy_path.stat().st_mode), 0o600)

    def test_recovery_dry_run_only_checks_binding_preflight_and_baseline(self):
        self.run.dry = True
        before = self.snapshot()
        self.assertIsNone(self.call())
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.rotations() or self.reals() or self.run.preserve_work)
        self.assertEqual(list(Path(self.work).iterdir()), [])
        self.assertFalse(any("CF-Access-Client-Secret" in request["headers"] for request in self.net.requests))

    def test_recovery_cannot_mutate_even_through_an_internal_callback(self):
        for payload in (None, {}):
            with self.subTest(payload=payload), patch.object(ACCESS, "preflight", side_effect=lambda rec, api, fail, **kwargs:
                    api("/access/service_tokens/" + CONFIG["service_token_id"] + "/rotate", payload=payload)):
                self.checked_refusal("recovery")
                self.assertFalse(self.net.requests)

    def test_recovery_and_rotation_parameter_sets_are_disjoint(self):
        for params in ({}, {"rotate-confirmed": "yes"}, {"recovery-dir": "relative"}, {"recovery-dir": None},
                       {"recovery-dir": self.source, "rotate-confirmed": "yes"}):
            with self.subTest(params=params):
                self.run.params = params; self.checked_refusal("contract")
        self.run.recipe["operation"] = "unknown"; self.run.params = {"recovery-dir": self.source}
        self.checked_refusal("contract")

    def test_directory_mode_owner_symlink_and_same_work_are_refused(self):
        os.chmod(self.source, 0o755); self.checked_refusal("recovery"); os.chmod(self.source, 0o700)
        link = Path(self.tmp.name, "source-link"); link.symlink_to(self.source, target_is_directory=True)
        self.run.params["recovery-dir"] = str(link); self.checked_refusal("recovery")
        self.run.params["recovery-dir"] = str(link) + "/"; self.checked_refusal("recovery")
        self.run.params["recovery-dir"] = self.source
        self.check_wrong_owner(Path(self.source).stat().st_ino)
        self.work = self.source; self.net.work = self.work
        self.checked_refusal("recovery")
        self.assertTrue(self.run.preserve_work)

    def check_wrong_owner(self, inode):
        original = os.fstat
        def wrong_owner(fd):
            info = original(fd)
            if info.st_ino == inode:
                fields = {key: getattr(info, key) for key in dir(info) if key.startswith("st_")}
                fields["st_uid"] = os.getuid() + 1
                return SimpleNamespace(**fields)
            return info
        with patch.object(os, "fstat", side_effect=wrong_owner):
            self.checked_refusal("recovery")

    def test_each_source_file_refuses_symlink_hardlink_mode_nonregular_or_oversize(self):
        for name in ("rotation-state.json", "rotation-result.json"):
            for kind in ("symlink", "hardlink", "mode", "directory", "fifo", "oversize"):
                with self.subTest(name=name, kind=kind):
                    path = Path(self.source, name); original = path.read_bytes(); alias = Path(self.tmp.name, "alias")
                    if kind == "symlink":
                        path.rename(alias); path.symlink_to(alias)
                    elif kind == "hardlink":
                        os.link(path, alias)
                    elif kind == "mode":
                        path.chmod(0o644)
                    elif kind == "directory":
                        path.unlink(); path.mkdir(mode=0o700)
                    elif kind == "fifo":
                        path.unlink(); os.mkfifo(path, mode=0o600)
                    else:
                        path.write_bytes(b" " * (ACCESS.LIMIT + 1))
                    self.checked_refusal("recovery")
                    if kind == "directory":
                        path.rmdir()
                    else:
                        path.unlink()
                    if alias.exists():
                        alias.unlink()
                    ACCESS.private_file(str(path), original)

    def test_each_source_file_refuses_a_different_owner(self):
        for name in ("rotation-state.json", "rotation-result.json"):
            with self.subTest(name=name):
                self.check_wrong_owner(Path(self.source, name).stat().st_ino)

    def test_source_snapshot_change_is_refused_before_copying(self):
        original = os.stat
        def changed(path, **kwargs):
            info = original(path, **kwargs)
            if kwargs.get("dir_fd") is not None and path == "rotation-state.json":
                fields = {key: getattr(info, key) for key in dir(info) if key.startswith("st_")}
                fields["st_mtime_ns"] += 1
                return SimpleNamespace(**fields)
            return info
        with patch.object(os, "stat", side_effect=changed):
            self.checked_refusal("recovery")
        self.assertFalse(Path(self.work, "rotation-result.json").exists())

    def test_missing_or_duplicate_json_source_is_not_consumed(self):
        for name in ("rotation-state.json", "rotation-result.json"):
            with self.subTest(name=name):
                path = Path(self.source, name); original = path.read_bytes(); path.unlink()
                self.checked_refusal("recovery")
                ACCESS.private_file(str(path), original)
                path.write_bytes(b'{"success":false,"success":true}'); self.checked_refusal("recovery")
                path.write_bytes(original)

    def test_required_timestamps_cannot_be_missing_none_malformed_or_naive(self):
        missing = object()
        for place, fields in (("state", ("started_at", "preflight_updated_at", "previous_client_secret_expires_at")), ("result", ("updated_at",))):
            for field in fields:
                for value in (missing, None, "", "not-a-date", "2026-11-01T15:05:00"):
                    with self.subTest(place=place, field=field, value="missing" if value is missing else value):
                        target = self.state if place == "state" else self.response["result"]; old = target[field]
                        if value is missing:
                            target.pop(field)
                        else:
                            target[field] = value
                        self.write_source(); self.checked_refusal()
                        target[field] = old; self.write_source()

    def test_state_times_and_old_expiry_must_bind_to_current_metadata(self):
        for field, value in (("preflight_updated_at", "2026-11-01T15:05:00Z"), ("started_at", "2026-11-01T15:05:01Z"),
                             ("previous_client_secret_expires_at", "2028-08-15T00:11:26Z"), ("service_token_id", "other-token"), ("phase", "unreviewed")):
            with self.subTest(field=field):
                old = self.state[field]; self.state[field] = value; self.write_source(); self.checked_refusal("recovery")
                self.state[field] = old; self.write_source()
        self.net.token["previous_client_secret_expires_at"] = "2026-08-15T00:12:15Z"
        self.checked_refusal("recovery")

    def test_saved_pair_identity_updated_at_and_envelope_must_match(self):
        for field, value in (("id", "other-token"), ("name", "other-name"), ("client_id", "other-client"), ("updated_at", "2026-11-01T15:04:59Z"),
                             ("client_secret", ""), ("enabled", False), ("duration", "1h"), ("expires_at", "2028-08-15T00:11:26Z")):
            with self.subTest(field=field):
                old = self.response["result"][field]; self.response["result"][field] = value
                self.write_source(); self.checked_refusal(); self.response["result"][field] = old; self.write_source()
        self.response["success"] = 1; self.write_source(); self.checked_refusal("recovery")

    def test_failed_control_or_real_probe_keeps_original_and_new_copy(self):
        for stage, outcome, rule in (("control", (200, {"object": "list", "data": []}), "control"), ("real", (530, None), "probe"), ("real", (200, None), "probe")):
            with self.subTest(stage=stage, outcome=outcome):
                self.work = tempfile.mkdtemp(dir=self.tmp.name); self.run.preserve_work = False; self.net = FakeTransport(self.work)
                self.net.token.update(updated_at="2026-11-01T15:05:00Z", previous_client_secret_expires_at=self.net.token["expires_at"])
                self.net.responses[stage, "https://" + CONFIG["origins"][-1] + "/v1/models"] = outcome
                self.checked_refusal(rule)
                self.assertTrue(self.run.preserve_work)
                self.assertTrue(Path(self.work, "rotation-result.json").exists())

    def test_recovery_runs_the_same_final_full_preflight(self):
        original = self.net.request
        def drift(url, headers, **kwargs):
            result = original(url, headers, **kwargs)
            if url.endswith(CONFIG["origins"][-1] + "/v1/models") and headers.get("CF-Access-Client-Secret") == SECRET:
                self.net.policy["include"] = [{"everyone": {}}]
            return result
        self.net.request = drift; self.checked_refusal("policy")
        self.assertEqual(len(self.reals()), 4)
        self.assertTrue(self.run.preserve_work)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        def fail(rule, text):
            raise Refused(1, "access-" + rule, text)
        self.net = ACCESS.CurlTransport(self.tmp.name, fail)

    def fake_run(self, args, **kwargs):
        config = Path(args[-1]); self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        cfg = config.read_text(); self.assertIn(MANAGER, cfg); self.assertNotIn(MANAGER, " ".join(args))
        for option in ("--proto", "=https", "--max-filesize", "--max-time"):
            self.assertIn(option, args)
        self.assertNotIn("--location", args); self.assertNotIn("-L", args)
        answer = json.loads(next(line for line in cfg.splitlines() if line.startswith("output = ")).split(" = ", 1)[1])
        self.assertEqual(stat.S_IMODE(Path(answer).stat().st_mode), 0o600)
        Path(answer).write_bytes(self.response)
        return SimpleNamespace(returncode=self.returncode, stdout=self.status, stderr=b"reflected " + MANAGER.encode())

    def call(self, payload=None, result_path=None):
        return self.net.request(BASE + "/access/service_tokens/" + CONFIG["service_token_id"], {"Authorization": "Bearer " + MANAGER},
                                payload=payload, result_path=result_path)

    def test_private_config_tls_no_redirect_and_cleanup(self):
        self.response, self.returncode, self.status = b'{"success":true,"result":{}}', 0, b"200"
        with patch.object(subprocess, "run", side_effect=self.fake_run):
            self.assertEqual(self.call(), (200, {"success": True, "result": {}}))
        self.assertEqual(list(Path(self.tmp.name).iterdir()), [])

    def test_duplicate_nonfinite_nonjson_and_nonutf8_are_not_success(self):
        for body in (b'{"success":false,"success":true}', b'{"value":NaN}', b'not json', b'\xff'):
            self.response, self.returncode, self.status = body, 0, b"200"
            with self.subTest(body=body), patch.object(subprocess, "run", side_effect=self.fake_run):
                self.assertEqual(self.call(), (200, None))
                self.assertEqual(list(Path(self.tmp.name).iterdir()), [])

    def test_rotated_pair_retained_management_config_removed_on_failure(self):
        self.response, self.returncode, self.status = SECRET.encode(), 28, b"000"
        saved = os.path.join(self.tmp.name, "rotation-result.json")
        with patch.object(subprocess, "run", side_effect=self.fake_run), self.assertRaises(Refused) as caught:
            self.call(payload={"previous_client_secret_expires_at": "2027-08-15T00:11:26Z"}, result_path=saved)
        self.assertNotIn(MANAGER, str(caught.exception))
        self.assertEqual([p.name for p in Path(self.tmp.name).iterdir()], ["rotation-result.json"])
        self.assertEqual(Path(saved).read_text(), SECRET)

    def test_interrupt_also_removes_management_config_and_keeps_response(self):
        saved = os.path.join(self.tmp.name, "rotation-result.json")
        with patch.object(subprocess, "run", side_effect=SystemExit(143)), self.assertRaises(SystemExit):
            self.call(payload={}, result_path=saved)
        self.assertEqual([p.name for p in Path(self.tmp.name).iterdir()], ["rotation-result.json"])

    def test_response_size_bound_and_ambiguous_status(self):
        for body, status in ((b"x" * (ACCESS.LIMIT + 1), b"200"), (b"{}", b"200\n200")):
            self.response, self.returncode, self.status = body, 0, status
            with self.subTest(status=status), patch.object(subprocess, "run", side_effect=self.fake_run), self.assertRaises(Refused):
                self.call()
            self.assertEqual(list(Path(self.tmp.name).iterdir()), [])

    def test_symlink_response_is_never_overwritten(self):
        target = Path(self.tmp.name, "existing"); target.write_text("unchanged")
        saved = Path(self.tmp.name, "rotation-result.json"); saved.symlink_to(target)
        with self.assertRaises(FileExistsError):
            self.call(payload={}, result_path=str(saved))
        self.assertEqual(target.read_text(), "unchanged")

    def test_unsafe_url_refuses_before_a_process(self):
        for url in ("http://example.com", "https://user:password@example.com", "https://example.com:8443", "https://example.com/#fragment"):
            with self.subTest(url=url), patch.object(subprocess, "run") as call, self.assertRaises(Refused):
                self.net.request(url, {})
            call.assert_not_called()


if __name__ == "__main__":
    unittest.main()
