"""Offline acceptance checks at the wrapper runner's storage/cleanup boundary."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('recipe_runner', ROOT / 'scripts/lib/secret_recipes.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
ARGS = ['--recipe', 'access-service-token', 'CF_ACCESS_CLIENT_ID', 'CF_ACCESS_CLIENT_SECRET',
        'Cor-Incorporated/cor-os', '--param', 'rotate-confirmed=yes']
RECOVERY_ARGS = ['--recipe', 'access-service-token-recovery', 'CF_ACCESS_CLIENT_ID', 'CF_ACCESS_CLIENT_SECRET',
                 'Cor-Incorporated/cor-os', '--param', 'recovery-dir=/absolute/owner-only/register-secret.attempt']
PAIR = {'client_id': 'offline-client', 'client_secret': 'offline-secret'}


class RunnerBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name) / 'private-work'
        self.rows = []
        self.output = io.StringIO()

    def run_case(self, verify, store=None, extra=(), argv=ARGS):
        def make_work(**_):
            self.work.mkdir(mode=0o700)
            return str(self.work)

        def ledger(run, decision, rule):
            self.rows.append((decision, rule))

        with patch.object(RUNNER.tempfile, 'mkdtemp', side_effect=make_work), \
                patch.object(RUNNER, 'access_service_verify', side_effect=verify), \
                patch.object(RUNNER, 'store', side_effect=store) as saved, \
                patch.object(RUNNER.Run, 'ledger', ledger), \
                contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            code = RUNNER.main(argv + list(extra))
        return code, saved

    @staticmethod
    def rotated(run, work):
        run.preserve_work = True
        (Path(work) / 'rotation-result.json').write_text('offline recovery fixture')
        return PAIR

    def test_success_removes_recovery_only_after_store(self):
        def store(run, values, work):
            self.assertTrue(run.preserve_work)
            self.assertEqual(values, PAIR)
            self.assertTrue((Path(work) / 'rotation-result.json').is_file())

        code, saved = self.run_case(self.rotated, store)
        self.assertEqual(code, 0)
        saved.assert_called_once()
        self.assertFalse(self.work.exists())
        self.assertEqual(self.rows, [('allow', 'registered')])
        self.assertNotIn(PAIR['client_secret'], self.output.getvalue())

    def test_dry_run_does_not_claim_pair_verified_or_store(self):
        code, saved = self.run_case(lambda *_: None, extra=['--dry-run'])
        self.assertEqual(code, 0)
        saved.assert_not_called()
        self.assertFalse(self.work.exists())
        self.assertEqual(self.rows, [('allow', 'preflight-only')])
        self.assertIn('no rotation, pair verification or GitHub storage', self.output.getvalue())

    def test_failed_preflight_cannot_store(self):
        def fail(*_):
            raise RUNNER.Refused(1, 'access-preflight', 'fixed preflight refusal')

        code, saved = self.run_case(fail)
        self.assertEqual(code, 1)
        saved.assert_not_called()
        self.assertFalse(self.work.exists())
        self.assertEqual(self.rows, [('deny', 'access-preflight')])

    def test_failed_probe_keeps_recovery_without_store(self):
        def fail(run, work):
            self.rotated(run, work)
            raise RUNNER.Refused(1, 'access-probe', 'fixed probe refusal')

        code, saved = self.run_case(fail)
        self.assertEqual(code, 1)
        saved.assert_not_called()
        self.assertTrue((self.work / 'rotation-result.json').is_file())
        self.assertIn('Do not rotate again', self.output.getvalue())

    def test_partial_github_failure_keeps_same_pair_recovery(self):
        def fail(*_):
            raise RUNNER.Refused(3, 'set-failed', 'second fixed secret failed')

        code, _ = self.run_case(self.rotated, fail)
        self.assertEqual(code, 3)
        self.assertTrue((self.work / 'rotation-result.json').is_file())
        self.assertEqual(self.rows, [('deny', 'set-failed')])

    def test_stale_github_readback_keeps_recovery(self):
        def fail(*_):
            raise RUNNER.Refused(4, 'readback-stale', 'fixed readback stale')

        code, _ = self.run_case(self.rotated, fail)
        self.assertEqual(code, 4)
        self.assertTrue(self.work.is_dir())
        self.assertEqual(self.rows, [('warn', 'readback-stale')])

    def test_interruption_keeps_recovery_and_records_denial(self):
        def interrupt(run, work):
            self.rotated(run, work)
            raise SystemExit(143)

        with self.assertRaises(SystemExit) as stop:
            self.run_case(interrupt)
        self.assertEqual(stop.exception.code, 143)
        self.assertTrue(self.work.is_dir())
        self.assertEqual(self.rows, [('deny', 'interrupted')])

    def test_unknown_exception_does_not_print_provider_message(self):
        def fail(run, work):
            self.rotated(run, work)
            raise ValueError(PAIR['client_secret'])

        code, saved = self.run_case(fail)
        self.assertEqual(code, 1)
        saved.assert_not_called()
        self.assertNotIn(PAIR['client_secret'], self.output.getvalue())
        self.assertTrue(self.work.is_dir())

    def test_fixed_names_repo_level_and_explicit_go_are_required(self):
        cases = [ARGS + ['--env', 'production'], ARGS + ['--param', 'origin=evil.example'],
                 ARGS[:-2], [a.replace('Cor-Incorporated/cor-os', 'other/repo') for a in ARGS],
                 [a.replace('CF_ACCESS_CLIENT_SECRET', 'OTHER_SECRET') for a in ARGS]]
        for argv in cases:
            with self.subTest(argv=argv), self.assertRaises(RUNNER.Refused):
                RUNNER.Run(argv)

    def test_recovery_contract_rejects_rotation_or_extra_parameters(self):
        self.assertEqual(RUNNER.Run(RECOVERY_ARGS).recipe.get('operation'), 'recover')
        cases = [RECOVERY_ARGS + ['--env', 'production'], RECOVERY_ARGS + ['--param', 'rotate-confirmed=yes'],
                 RECOVERY_ARGS[:-2], [a.replace('Cor-Incorporated/cor-os', 'other/repo') for a in RECOVERY_ARGS],
                 [a.replace('CF_ACCESS_CLIENT_SECRET', 'OTHER_SECRET') for a in RECOVERY_ARGS]]
        for argv in cases:
            with self.subTest(argv=argv), self.assertRaises(RUNNER.Refused):
                RUNNER.Run(argv)

    def test_recovery_uses_existing_store_and_removes_only_new_work(self):
        code, saved = self.run_case(self.rotated, argv=RECOVERY_ARGS)
        self.assertEqual(code, 0)
        saved.assert_called_once()
        self.assertFalse(self.work.exists())
        self.assertEqual(self.rows, [('allow', 'registered')])

    def test_recovery_dry_run_cannot_store_or_claim_pair_verified(self):
        code, saved = self.run_case(lambda *_: None, extra=['--dry-run'], argv=RECOVERY_ARGS)
        self.assertEqual(code, 0)
        saved.assert_not_called()
        self.assertEqual(self.rows, [('allow', 'preflight-only')])

    def test_failed_github_readback_with_fresh_stdout_keeps_recovery(self):
        calls = []
        fresh = RUNNER.datetime.now(RUNNER.timezone.utc).isoformat()

        def gh(argv, **kwargs):
            calls.append(argv)
            if argv[:3] == ['gh', 'secret', 'set']:
                self.assertIn(kwargs['stdin'].read().decode(), PAIR.values())
                return subprocess.CompletedProcess(argv, 0, b'', b'')
            self.assertEqual(argv[:3], ['gh', 'secret', 'list'])
            stdout = json.dumps([{'name': name, 'updatedAt': fresh} for name in RECOVERY_ARGS[2:4]])
            return subprocess.CompletedProcess(argv, 1, stdout, PAIR['client_secret'])

        with patch.object(RUNNER.subprocess, 'run', side_effect=gh):
            code, saved = self.run_case(self.rotated, store=RUNNER.store, argv=RECOVERY_ARGS)
        self.assertEqual(code, 4)
        saved.assert_called_once()
        self.assertEqual(len(calls), 3)
        self.assertTrue((self.work / 'rotation-result.json').is_file())
        self.assertEqual(self.rows, [('warn', 'readback-failed')])
        self.assertNotIn('REGISTERED:', self.output.getvalue())
        self.assertNotIn(PAIR['client_secret'], self.output.getvalue())

    def test_recipe_declaration_and_runbook_match_the_provider_contract_fixture(self):
        spec = importlib.util.spec_from_file_location('access_contract_fixture', ROOT / 'tests/test-access-service-token.py')
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        rec = json.loads((ROOT / 'scripts/lib/secret-verify-recipes.json').read_text())['recipes']['access-service-token']
        self.assertEqual({key: rec[key] for key in fixture.CONFIG}, fixture.CONFIG)
        commands = [line for line in (ROOT / 'docs/runbooks/access-service-token-registration.md').read_text().splitlines()
                    if line.startswith('bash ~/.claude/scripts/register-secret-verified.sh ')]
        self.assertEqual(len(commands), 4)
        counts = {}
        for command in commands:
            argv = shlex.split(command)[2:]
            run = RUNNER.Run(argv)
            self.assertIn(run.recipe_name, ('access-service-token', 'access-service-token-recovery'))
            counts[run.recipe_name] = counts.get(run.recipe_name, 0) + 1
            self.assertEqual(run.names, ['CF_ACCESS_CLIENT_ID', 'CF_ACCESS_CLIENT_SECRET'])
            self.assertEqual(run.repo, 'Cor-Incorporated/cor-os')
        self.assertEqual(counts, {'access-service-token': 2, 'access-service-token-recovery': 2})
        recovery = json.loads((ROOT / 'scripts/lib/secret-verify-recipes.json').read_text())['recipes']['access-service-token-recovery']
        self.assertEqual({key: recovery[key] for key in fixture.CONFIG}, fixture.CONFIG)
        self.assertEqual(recovery['operation'], 'recover')


if __name__ == '__main__':
    unittest.main()
