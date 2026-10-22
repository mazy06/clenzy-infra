"""Baitly staging routing must never redirect production or expose deployment values."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
KEY = 'phc_' + 'a' * 40
BASE = 'APP_DOMAIN=app.clenzy.fr\nOTHER_SECRET=keep-me\nVITE_POSTHOG_KEY=old\nVITE_ENV=production\n'


class StagingTelemetryTest(unittest.TestCase):
    def run_config(self, **values):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text(BASE)
            result = subprocess.run(['bash', str(ROOT / 'scripts/baitly-staging-telemetry.sh')],
                                    cwd=directory, capture_output=True, text=True,
                                    env={**os.environ, 'DEPLOY_EXPECTED_DOMAIN': 'app.clenzy.fr',
                                         'APP_DOMAIN': 'app.clenzy.fr', 'DEPLOY_POSTHOG_KEY': KEY,
                                         'DEPLOY_SENTRY_WEB_DSN': '', 'DEPLOY_SENTRY_API_DSN': '', **values})
            return result, path.read_text(), path.stat().st_mode & 0o777

    def test_staging_destination_environment_and_existing_secrets(self):
        result, content, mode = self.run_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('VITE_POSTHOG_KEY=' + KEY + '\n', content)
        self.assertIn('VITE_ENV=staging\n', content)
        self.assertIn('VITE_POSTHOG_HOST=https://eu.i.posthog.com\n', content)
        self.assertEqual(content.count('VITE_POSTHOG_KEY='), 1)
        self.assertIn('OTHER_SECRET=keep-me\n', content)
        self.assertNotIn(KEY, result.stdout + result.stderr)
        self.assertEqual(mode, 0o600)

    def test_production_is_untouched_even_with_staging_key_inherited(self):
        result, content, _ = self.run_config(DEPLOY_EXPECTED_DOMAIN='app.baitly.fr', APP_DOMAIN='app.baitly.fr')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(content, BASE)

    def test_missing_key_preserves_existing_configuration(self):
        result, content, _ = self.run_config(DEPLOY_POSTHOG_KEY='')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(content, BASE)

    def test_sentry_uses_two_eu_projects_and_staging_without_logging_dsns(self):
        web = 'https://' + 'a' * 32 + '@o4512297046048768.ingest.de.sentry.io/1'
        api = 'https://' + 'b' * 32 + '@o4512297046048768.ingest.de.sentry.io/2'
        result, content, _ = self.run_config(DEPLOY_SENTRY_WEB_DSN=web, DEPLOY_SENTRY_API_DSN=api)
        self.assertEqual(result.returncode, 0)
        self.assertIn('VITE_SENTRY_DSN=' + web + '\n', content)
        self.assertIn('SENTRY_DSN=' + api + '\n', content)
        self.assertIn('SENTRY_ENVIRONMENT=staging\n', content)
        self.assertNotIn(web, result.stdout + result.stderr)
        self.assertNotIn(api, result.stdout + result.stderr)

    def test_arbitrary_sentry_destination_is_rejected(self):
        result, content, _ = self.run_config(DEPLOY_SENTRY_WEB_DSN='https://abc@collector.example/1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(content, BASE)

    def test_wrong_target_and_injected_values_fail_without_modification(self):
        for values in [{'APP_DOMAIN': 'app.baitly.fr'}, {'DEPLOY_POSTHOG_KEY': KEY + '\nINJECTED=true'},
                       {'DEPLOY_POSTHOG_KEY': '$(touch forbidden)'}]:
            with self.subTest(values=values):
                result, content, _ = self.run_config(**values)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(content, BASE)

    def test_repeated_configuration_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text(BASE)
            env = {**os.environ, 'DEPLOY_EXPECTED_DOMAIN': 'app.clenzy.fr',
                   'APP_DOMAIN': 'app.clenzy.fr', 'DEPLOY_POSTHOG_KEY': KEY}
            for _ in range(2):
                subprocess.run(['bash', str(ROOT / 'scripts/baitly-staging-telemetry.sh')], cwd=directory,
                               env=env, capture_output=True, check=True)
            self.assertEqual(path.read_text().count('VITE_POSTHOG_KEY='), 1)


if __name__ == '__main__':
    unittest.main()
