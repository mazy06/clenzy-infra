"""Validate the resolved production configuration without starting containers."""

import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


def production_config(captcha_enabled):
    # Never load the operator's .env or inherit credentials for this check.
    result = subprocess.run(
        ['docker', 'compose', '--env-file', os.devnull, '-f',
         str(ROOT / 'docker-compose.prod.yml'), 'config', '--format', 'json'],
        cwd=ROOT,
        env={
            'PATH': os.environ['PATH'],
            'DOMAIN': 'baitly.example',
            'APP_DOMAIN': 'app.baitly.example',
            'AUTH_DOMAIN': 'auth.baitly.example',
            'BAITLY_CAPTCHA_ENABLED': captcha_enabled,
            'TURNSTILE_SECRET_KEY': 'test-private-key',
            'VITE_TURNSTILE_SITE_KEY': 'test-public-key',
            'TURNSTILE_ALLOWED_HOSTNAMES': 'baitly.example,app.baitly.example',
        },
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)['services']


class ProductionSecurityConfiguration(unittest.TestCase):
    def test_captcha_switch_and_keys_reach_all_three_services(self):
        for enabled in ('false', 'true'):
            with self.subTest(enabled=enabled):
                services = production_config(enabled)
                backend = services['pms-server']['environment']
                self.assertEqual(backend['BAITLY_CAPTCHA_ENABLED'], enabled)
                self.assertEqual(backend['TURNSTILE_SECRET_KEY'], 'test-private-key')
                self.assertEqual(backend['TURNSTILE_ALLOWED_HOSTNAMES'],
                                 'baitly.example,app.baitly.example')
                for name in ('pms-client', 'baitly-site'):
                    frontend = services[name]['environment']
                    self.assertEqual(frontend['VITE_BAITLY_CAPTCHA_ENABLED'], enabled)
                    self.assertEqual(frontend['VITE_TURNSTILE_SITE_KEY'], 'test-public-key')
                    self.assertNotIn('test-private-key', json.dumps(frontend))

    def test_promtail_loads_the_versioned_directory_configuration(self):
        promtail = production_config('false')['promtail']
        mount = next(volume for volume in promtail['volumes']
                     if volume['target'] == '/etc/promtail')
        self.assertTrue(mount['read_only'])
        config_path = next(arg.split('=', 1)[1] for arg in promtail['command']
                           if arg.startswith('-config.file='))
        relative_path = Path(config_path).relative_to(mount['target'])
        self.assertTrue((Path(mount['source']) / relative_path).is_file())
