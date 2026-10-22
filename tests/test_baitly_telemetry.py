"""Exercise deployment isolation, validation failures and atomic environment updates."""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('telemetry', ROOT / 'scripts/baitly-telemetry-config.py')
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)
KEYS = {'app.clenzy.fr': 'phc_' + 'a' * 40, 'app.baitly.fr': 'phc_' + 'b' * 40}


class TelemetryTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / '.env'
        fixtures = {domain: (target[0], hashlib.sha256(KEYS[domain].encode()).hexdigest(), *target[2:])
                    for domain, target in telemetry.DESTINATIONS.items()}
        self.patch = patch.dict(telemetry.DESTINATIONS, fixtures)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def environment(self, domain):
        _, _, web, api = telemetry.DESTINATIONS[domain]
        self.base = f'APP_DOMAIN={domain}\nOTHER_SECRET=keep-me\nVITE_POSTHOG_KEY=old\nVITE_ENV=old\nSENTRY_DSN=old\n'
        self.path.write_text(self.base)
        return {'APP_DOMAIN': domain, 'DEPLOY_EXPECTED_DOMAIN': domain, 'DEPLOY_POSTHOG_KEY': KEYS[domain],
                'DEPLOY_SENTRY_WEB_DSN': f'https://{"a" * 32}@{telemetry.SENTRY_ORIGIN}/{web}',
                'DEPLOY_SENTRY_API_DSN': f'https://{"b" * 32}@{telemetry.SENTRY_ORIGIN}/{api}'}

    def test_separate_destinations_idempotence_permissions_and_no_values_in_output(self):
        for domain, name in [('app.clenzy.fr', 'staging'), ('app.baitly.fr', 'production')]:
            with self.subTest(domain=domain):
                env = self.environment(domain)
                output = io.StringIO()
                with redirect_stdout(output):
                    telemetry.configure(env, self.path)
                    telemetry.configure(env, self.path)
                content = self.path.read_text()
                self.assertIn(f'VITE_ENV={name}\n', content)
                self.assertIn(f'SENTRY_ENVIRONMENT={name}\n', content)
                self.assertIn('VITE_POSTHOG_HOST=https://eu.i.posthog.com\n', content)
                self.assertIn('OTHER_SECRET=keep-me\n', content)
                self.assertEqual(content.count('VITE_POSTHOG_KEY='), 1)
                self.assertEqual(content.count('SENTRY_DSN='), 2)
                self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
                for value in [KEYS[domain], env['DEPLOY_SENTRY_WEB_DSN'], env['DEPLOY_SENTRY_API_DSN'], 'keep-me']:
                    self.assertNotIn(value, output.getvalue())

    def test_keys_from_other_environment_and_swapped_projects_are_rejected(self):
        staging = self.environment('app.clenzy.fr')
        production = self.environment('app.baitly.fr')
        for field in ['DEPLOY_POSTHOG_KEY', 'DEPLOY_SENTRY_WEB_DSN', 'DEPLOY_SENTRY_API_DSN']:
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    telemetry.configure({**production, field: staging[field]}, self.path)
                self.assertEqual(self.path.read_text(), self.base)
        with self.assertRaises(ValueError):
            telemetry.configure({**production, 'DEPLOY_SENTRY_WEB_DSN': production['DEPLOY_SENTRY_API_DSN']}, self.path)

    def test_missing_values_wrong_domain_and_injections_never_mutate_file(self):
        for domain in KEYS:
            env = self.environment(domain)
            variants = [{key: ''} for key in env]
            variants += [{'APP_DOMAIN': 'other.example'}, {'DEPLOY_EXPECTED_DOMAIN': 'other.example'},
                         {'DEPLOY_POSTHOG_KEY': KEYS[domain] + '\nINJECTED=true'},
                         {'DEPLOY_SENTRY_WEB_DSN': 'https://abc@collector.example/1'},
                         {'DEPLOY_SENTRY_API_DSN': '$(touch forbidden)'}]
            for values in variants:
                with self.subTest(domain=domain, fields=list(values)):
                    with self.assertRaises(ValueError):
                        telemetry.configure({**env, **values}, self.path)
                    self.assertEqual(self.path.read_text(), self.base)

    def test_file_domain_cannot_be_spoofed_by_sourced_environment(self):
        env = self.environment('app.baitly.fr')
        self.path.write_text(self.base.replace('app.baitly.fr', 'app.clenzy.fr'))
        with self.assertRaises(ValueError):
            telemetry.configure(env, self.path)

    def test_symlink_is_rejected_and_original_remains_intact(self):
        env = self.environment('app.baitly.fr')
        link = self.path.parent / 'link'
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            telemetry.configure(env, link)
        self.assertEqual(self.path.read_text(), self.base)

    def test_failed_replace_preserves_original_and_cleans_temporary(self):
        env = self.environment('app.baitly.fr')
        with patch.object(telemetry.os, 'replace', side_effect=OSError('failure')):
            with self.assertRaises(OSError):
                telemetry.configure(env, self.path)
        self.assertEqual(self.path.read_text(), self.base)
        self.assertEqual(list(self.path.parent.glob('.env.telemetry.*')), [])


if __name__ == '__main__':
    unittest.main()
