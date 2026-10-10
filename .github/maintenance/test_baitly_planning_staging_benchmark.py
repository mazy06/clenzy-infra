"""Contrat CI du benchmark staging : domaine fixe, secrets privés, pas de redémarrage."""
from pathlib import Path
import unittest


class PlanningStagingBenchmarkTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.workflow = (self.root / '.github/workflows/baitly-planning-staging-benchmark.yml').read_text()
        self.script = (self.root / '.github/maintenance/baitly_planning_staging_benchmark.sh').read_text()

    def test_dispatch_is_main_only_with_no_production_target_input(self):
        self.assertIn("github.ref == 'refs/heads/main'", self.workflow)
        self.assertIn('url: https://app.clenzy.fr', self.workflow)
        self.assertNotIn('name: production-baitly', self.workflow)
        self.assertIn('group: cd-deploy-production', self.workflow)

    def test_domain_is_checked_before_any_remote_fixture_operation(self):
        guard = self.script.index('[ "${APP_DOMAIN:-}" != app.clenzy.fr ]')
        execute = self.script.index('case "$BAITLY_OPERATION"')
        self.assertLess(guard, execute)
        self.assertIn('export BASE_URL=https://app.clenzy.fr', self.script)

    def test_private_actor_file_is_outside_artifacts_and_removed(self):
        self.assertIn('path: baitly-benchmark-results/', self.workflow)
        self.assertIn('actors="${RUNNER_TEMP}/', self.script)
        self.assertIn('chmod 600 "$actors"', self.script)
        self.assertIn('rm -f -- "$key" "$actors"', self.script)
        self.assertIn('trap cleanup EXIT', self.script)

    def test_clients_are_disabled_even_after_a_failed_measurement(self):
        self.assertIn('if ! remote disable', self.script)
        self.assertIn('prepared=true', self.script)
        self.assertIn('original_status=$?', self.script)

    def test_no_container_lifecycle_operations(self):
        for forbidden in ('docker restart', 'docker stop', 'docker compose up', 'docker compose down'):
            self.assertNotIn(forbidden, self.script)

    def test_diagnostic_does_not_provision_or_disable_clients(self):
        self.assertIn('&& "$BAITLY_BENCHMARK_MODE" != diagnostic', self.script)
        diagnostic = self.script.index('if [[ "$BAITLY_BENCHMARK_MODE" == diagnostic ]]')
        provision = self.script.index('\nremote provision')
        self.assertLess(diagnostic, provision)
        self.assertIn('remote diagnostic > baitly-benchmark-results/error-classes.json\n  exit 0', self.script)


if __name__ == '__main__':
    unittest.main()
