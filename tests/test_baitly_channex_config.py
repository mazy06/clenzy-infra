"""Environment isolation and secret-safe provisioning for Baitly Channex."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("channex_config", ROOT / "scripts/baitly-channex-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class Response:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class ChannexConfigTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / ".env"
        self.original = "APP_DOMAIN=app.clenzy.fr\nOTHER_SECRET=keep-me\nCHANNEX_API_KEY=old\n"
        self.path.write_text(self.original)

    def apply(self, domain="app.clenzy.fr", **env):
        calls = []

        def opener(request, timeout):
            calls.append(request)
            return Response()

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            config.configure(self.path, domain, {"APP_DOMAIN": domain, **env}, opener)
        return calls, output.getvalue()

    def test_staging_key_goes_only_to_staging_and_enables_integration(self):
        calls, output = self.apply(DEPLOY_CHANNEX_API_KEY="test-staging-key")
        self.assertEqual(calls[0].full_url, config.ENDPOINTS["app.clenzy.fr"] + "/properties?pagination[limit]=1")
        content = self.path.read_text()
        self.assertIn("CHANNEX_ENABLED=true", content)
        self.assertIn("CHANNEX_API_KEY=test-staging-key", content)
        self.assertIn("CHANNEX_WEBHOOK_CALLBACK_URL=https://app.clenzy.fr/api/webhooks/channex", content)
        self.assertIn("OTHER_SECRET=keep-me", content)
        self.assertNotIn("test-staging-key", output)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_production_key_goes_only_to_production(self):
        calls, _ = self.apply(domain="app.baitly.fr", DEPLOY_CHANNEX_API_KEY="test-production-key")
        self.assertTrue(calls[0].full_url.startswith(config.ENDPOINTS["app.baitly.fr"] + "/"))

    def test_base64_credentials_are_preserved(self):
        calls, _ = self.apply(DEPLOY_CHANNEX_API_KEY="test+key/value==")
        self.assertEqual(calls[0].get_header("User-api-key"), "test+key/value==")
        self.assertIn("CHANNEX_API_KEY=test+key/value==", self.path.read_text())

    def test_absent_secret_keeps_disabled_state_and_does_not_call_api(self):
        calls, _ = self.apply()
        self.assertFalse(calls)
        self.assertIn("CHANNEX_API_KEY=old", self.path.read_text())
        self.assertNotIn("CHANNEX_ENABLED=true", self.path.read_text())

    def test_existing_active_key_is_checked_without_rotation(self):
        calls, _ = self.apply(CHANNEX_ENABLED="true", CHANNEX_API_KEY="old")
        self.assertEqual(calls[0].get_header("User-api-key"), "old")
        self.assertIn("CHANNEX_API_KEY=old", self.path.read_text())

    def test_unauthorized_response_preserves_file_and_hides_server_body(self):
        def unauthorized(request, timeout):
            raise HTTPError(request.full_url, 401, "sensitive-body", {}, None)

        with self.assertRaisesRegex(ValueError, r"\(HTTP 401\)") as error:
            config.configure(self.path, "app.clenzy.fr", {
                "APP_DOMAIN": "app.clenzy.fr", "DEPLOY_CHANNEX_API_KEY": "test-key"
            }, unauthorized)
        self.assertNotIn("sensitive-body", str(error.exception))
        self.assertEqual(self.path.read_text(), self.original)

    def test_wrong_domain_and_invalid_credentials_preserve_file(self):
        for domain, env in [("unknown.fr", {"APP_DOMAIN": "unknown.fr"}),
                            ("app.clenzy.fr", {"APP_DOMAIN": "app.baitly.fr"}),
                            ("app.clenzy.fr", {"APP_DOMAIN": "app.clenzy.fr", "DEPLOY_CHANNEX_API_KEY": "key\nINJECT=value"}),
                            ("app.clenzy.fr", {"APP_DOMAIN": "app.clenzy.fr", "CHANNEX_ENABLED": "true"})]:
            with self.assertRaises(ValueError):
                config.configure(self.path, domain, env)
            self.assertEqual(self.path.read_text(), self.original)

    def test_duplicate_values_are_replaced_and_repeated_provisioning_is_stable(self):
        self.path.write_text(self.original + "export CHANNEX_API_KEY=older\nCHANNEX_BASE_URL=wrong\n")
        self.apply(DEPLOY_CHANNEX_API_KEY="test-key")
        first = self.path.read_text()
        self.apply(DEPLOY_CHANNEX_API_KEY="test-key")
        self.assertEqual(first, self.path.read_text())
        self.assertEqual(first.count("CHANNEX_API_KEY="), 1)

    def test_redirects_cannot_forward_credentials(self):
        self.assertIsNone(config.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.fr"))

    def test_workflow_selects_distinct_keys_and_provisions_before_services(self):
        workflow = (ROOT / ".github/workflows/cd-deploy.yml").read_text()
        selection = next(line for line in workflow.splitlines() if "DEPLOY_CHANNEX_API_KEY:" in line)
        self.assertIn("matrix.target == 'staging' && secrets.BAITLY_CHANNEX_STAGING_API_KEY", selection)
        self.assertIn("matrix.target == 'production-baitly' && secrets.BAITLY_CHANNEX_PRODUCTION_API_KEY", selection)
        self.assertLess(workflow.index("python3 scripts/baitly-channex-config.py"),
                        workflow.index("# --- Stockage objet OVH"))
        compose = (ROOT / "docker-compose.prod.yml").read_text()
        self.assertIn("CHANNEX_WEBHOOK_CALLBACK_URL: ${CHANNEX_WEBHOOK_CALLBACK_URL:-}", compose)
        self.assertIn('SPRING_LIQUIBASE_ENABLED: "true"', compose)
        self.assertIn("SPRING_JPA_HIBERNATE_DDL_AUTO: validate", compose)


if __name__ == "__main__":
    unittest.main()
