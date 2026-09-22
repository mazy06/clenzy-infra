import os
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/baitly-security-preflight.sh'


class SecurityPreflight(unittest.TestCase):
    def run_preflight(self, **env):
        return subprocess.run(['bash', str(SCRIPT)], env={'PATH': os.environ['PATH'], **env}, capture_output=True, text=True)

    def test_staged_default_passes(self):
        self.assertEqual(self.run_preflight().returncode, 0)

    def test_partial_activation_fails_without_logging_secret(self):
        result = self.run_preflight(BAITLY_CAPTCHA_ENABLED='true', TURNSTILE_SECRET_KEY='DO_NOT_LOG')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('DO_NOT_LOG', result.stdout + result.stderr)

    def test_complete_captcha_configuration_passes(self):
        result = self.run_preflight(BAITLY_CAPTCHA_ENABLED='true', TURNSTILE_SECRET_KEY='secret',
                                   TURNSTILE_ALLOWED_HOSTNAMES='app.baitly.fr,baitly.fr', VITE_TURNSTILE_SITE_KEY='public')
        self.assertEqual(result.returncode, 0)

    def test_origin_activation_requires_proxy_verification(self):
        self.assertNotEqual(self.run_preflight(BAITLY_ORIGIN_LOCKDOWN='1').returncode, 0)
        self.assertEqual(self.run_preflight(BAITLY_ORIGIN_LOCKDOWN='1', BAITLY_ORIGIN_PROXY_VERIFIED='true').returncode, 0)

    def test_missing_deployed_hostname_is_rejected(self):
        result = self.run_preflight(BAITLY_CAPTCHA_ENABLED='true', TURNSTILE_SECRET_KEY='secret',
                                   TURNSTILE_ALLOWED_HOSTNAMES='app.baitly.fr', VITE_TURNSTILE_SITE_KEY='public',
                                   DOMAIN='baitly.fr', APP_DOMAIN='app.baitly.fr')
        self.assertNotEqual(result.returncode, 0)
