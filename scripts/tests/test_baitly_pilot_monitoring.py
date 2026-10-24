"""Baitly monitoring tests; all Docker/network calls are mocked."""
import importlib.util
import json
import pathlib
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("pilot", pathlib.Path(__file__).parents[1] / "baitly-pilot-monitoring.py")
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


class PilotTests(unittest.TestCase):
    def test_external_docker_address_is_refused(self):
        with patch.object(pilot, "inspect", return_value={"NetworkSettings": {"Networks": {"n": {"IPAddress": "8.8.8.8"}}}}):
            with self.assertRaises(RuntimeError):
                pilot.endpoint("container", 9090)

    def test_missing_and_nonfinite_samples_fail_closed(self):
        for rows in ([], [{"value": [0, "NaN"]}], [{"value": [0, "1"]}] * 2):
            with patch.object(pilot, "request", return_value=json.dumps({"status": "success", "data": {"result": rows}})):
                with self.assertRaises(RuntimeError):
                    pilot.query("private", "aggregate")

    def test_failed_command_never_reveals_stderr(self):
        with patch.object(pilot.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "SECRET", "PRIVATE")):
            with self.assertRaisesRegex(RuntimeError, "details withheld") as error:
                pilot.command("docker")
            self.assertNotIn("SECRET", str(error.exception))
            self.assertNotIn("PRIVATE", str(error.exception))

    def test_reload_requires_fresh_success_not_previous_good_state(self):
        with patch.object(pilot, "request", return_value="prometheus_config_last_reload_successful 1\nprometheus_config_last_reload_success_timestamp_seconds 10\n"):
            self.assertTrue(pilot.reload_confirmed("private", "prometheus", 9))
            self.assertFalse(pilot.reload_confirmed("private", "prometheus", 11))

    def test_reload_uses_only_hup_and_checks_container_start_times(self):
        with patch.object(pilot, "inspect", return_value={"State": {"StartedAt": "unchanged"}}), \
             patch.object(pilot, "command") as command, patch.object(pilot, "wait_for"):
            pilot.reload_configuration("prom", "am")
            signals = [c.args for c in command.call_args_list if c.args[:2] == ("docker", "kill")]
            self.assertEqual(signals, [("docker", "kill", "--signal=HUP", "clenzy-prometheus-prod"),
                                       ("docker", "kill", "--signal=HUP", "clenzy-alertmanager-prod")])

    def test_unexpected_restart_is_detected(self):
        states = [{"State": {"StartedAt": v}} for v in ("old", "old", "new")]
        with patch.object(pilot, "inspect", side_effect=states), patch.object(pilot, "command"), patch.object(pilot, "wait_for"):
            with self.assertRaisesRegex(RuntimeError, "restart"):
                pilot.reload_configuration("prom", "am")

    def test_canary_refuses_production_before_any_request(self):
        with patch.object(pilot.pathlib.Path, "read_text", return_value="APP_DOMAIN=app.baitly.fr\nSECRET=private"), patch.object(pilot, "request") as request:
            with self.assertRaisesRegex(RuntimeError, "staging"):
                pilot.canary("prom", "am")
            request.assert_not_called()

    def test_failed_canary_still_sends_resolution_without_private_data(self):
        with patch.object(pilot.pathlib.Path, "read_text", return_value="APP_DOMAIN=app.clenzy.fr"), \
             patch.object(pilot, "notification_count", return_value=0), \
             patch.object(pilot, "query", return_value=0), patch.object(pilot, "wait_for", side_effect=RuntimeError("timeout")), \
             patch.object(pilot, "request") as request:
            with self.assertRaisesRegex(RuntimeError, "timeout"):
                pilot.canary("prom", "am")
            self.assertEqual(request.call_count, 2)
            self.assertEqual(request.call_args.args[1], "/api/v2/alerts")
            self.assertEqual(request.call_args.args[2][0]["labels"]["job"], "baitly-pilot-recipe")

    def test_notification_proof_returns_only_count_and_rejects_free_text(self):
        with patch.object(pilot, "command", return_value="2\n") as command:
            self.assertEqual(pilot.notification_count("firing", 1700000000), 2)
            self.assertIn("SELECT count(*)", command.call_args.args[-1])
            with self.assertRaises(RuntimeError):
                pilot.notification_count("private-input", 1700000000)
            self.assertEqual(command.call_count, 1)

    def test_missing_backend_samples_prevent_rule_activation(self):
        with patch("sys.argv", ["pilot", "--reload"]), patch.object(pilot, "endpoint", return_value="private"), \
             patch.object(pilot, "validate_backend", side_effect=RuntimeError("not ready")), \
             patch.object(pilot, "reload_configuration") as reload:
            with self.assertRaisesRegex(RuntimeError, "not ready"):
                pilot.main()
            reload.assert_not_called()

    def test_missing_recovery_snapshot_prevents_reload_even_when_legacy_metrics_are_healthy(self):
        def sample(base, expr):
            if "baitly_recovery_" in expr:
                raise RuntimeError("Recovery snapshot missing")
            return 1
        with patch("sys.argv", ["pilot", "--reload"]), patch.object(pilot, "endpoint", return_value="private"), \
             patch.object(pilot, "query", side_effect=sample), \
             patch.object(pilot, "wait_for", side_effect=lambda check: check()), \
             patch.object(pilot, "reload_configuration") as reload:
            with self.assertRaisesRegex(RuntimeError, "Recovery snapshot missing"):
                pilot.main()
            reload.assert_not_called()

    def test_ready_backend_requires_all_recovery_aggregates_to_be_present(self):
        with patch.object(pilot, "query", side_effect=lambda base, expr: 0 if expr in (pilot.RECOVERY_COVERAGE,pilot.NOISE_COVERAGE,pilot.AUTOMATION_COVERAGE,pilot.EXTERNAL_EFFECT_COVERAGE) else 1) as query, \
             patch.object(pilot, "wait_for", side_effect=lambda check: self.assertTrue(check())):
            pilot.validate_backend("private")
            expressions = [call.args[1] for call in query.call_args_list]
            for name in pilot.RECOVERY_METRICS:
                self.assertTrue(any("min(baitly_recovery_" + name + "{" in expr for expr in expressions))
            self.assertTrue(any("baitly_recovery_snapshot_healthy" in expr for expr in expressions))
            self.assertTrue(any("baitly_recovery_snapshot_last_success" in expr for expr in expressions))

    def test_stale_or_negative_recovery_samples_are_not_ready(self):
        for bad in ("stale", "negative"):
            with self.subTest(bad=bad):
                def sample(base, expr):
                    if expr == pilot.RECOVERY_COVERAGE:
                        return 0
                    if bad == "stale" and "time() - baitly_recovery_" in expr:
                        return 181
                    if bad == "negative" and "accounting_unknown" in expr:
                        return -1
                    return 1
                with patch.object(pilot, "query", side_effect=sample), \
                     patch.object(pilot, "wait_for", side_effect=lambda check: self.assertFalse(check())):
                    pilot.validate_backend("private")

    def test_qualification_counts_replica_aggregates_once_and_requires_new_rules(self):
        rules = {"data": {"groups": [{"rules": [{"name": name, "health": "ok"} for name in pilot.RULES]}]}}
        with patch.object(pilot, "validate_backend"), \
             patch.object(pilot, "request", return_value=json.dumps(rules)), \
             patch.object(pilot, "wait_for", side_effect=lambda check: self.assertTrue(check())), \
             patch.object(pilot, "query", return_value=1) as query, patch("builtins.print"):
            pilot.validate("private")
            for call in query.call_args_list:
                if "baitly_recovery_" in call.args[1] or "baitly_automation_" in call.args[1]:
                    self.assertTrue(call.args[1].startswith("max("))
        self.assertTrue({"BaitlyRecoveryMetricsUnavailable", "BaitlyRecoveryMetricsStale",
                         "BaitlyAccountingExportStalled", "BaitlyAccountingExportUncertain"}.issubset(pilot.RULES))

    def test_one_updated_replica_cannot_hide_missing_gauges_on_another_replica(self):
        with patch.object(pilot, "query", return_value=1) as query, \
             patch.object(pilot, "wait_for", side_effect=lambda check: self.assertFalse(check())):
            pilot.validate_backend("private")
            self.assertIn(pilot.RECOVERY_COVERAGE,[call.args[1] for call in query.call_args_list])

    def test_missing_minut_gauge_prevents_activation_with_other_journals_healthy(self):
        def sample(base, expr):
            if expr == pilot.RECOVERY_COVERAGE:
                return 0
            if 'baitly_recovery_minut_' in expr:
                raise RuntimeError('Minut snapshot missing')
            return 1
        with patch('sys.argv', ['pilot', '--reload']), patch.object(pilot, 'endpoint', return_value='private'), \
             patch.object(pilot, 'query', side_effect=sample), \
             patch.object(pilot, 'wait_for', side_effect=lambda check: check()), \
             patch.object(pilot, 'reload_configuration') as reload:
            with self.assertRaisesRegex(RuntimeError, 'Minut snapshot missing'):
                pilot.main()
            reload.assert_not_called()

    def test_minut_coverage_and_rules_are_required_without_customer_labels(self):
        self.assertEqual(len(pilot.RECOVERY_REQUIRED), 13)
        self.assertTrue({'BaitlyMinutRecoveryStalled', 'BaitlyMinutRecoveryUncertain'}.issubset(pilot.RULES))
        for name in ('minut_ready', 'minut_uncertain', 'minut_review', 'minut_oldest_ready_seconds', 'minut_oldest_uncertain_seconds'):
            self.assertIn(name, pilot.RECOVERY_METRICS)
            self.assertIn(name, pilot.RECOVERY_COVERAGE)

    def test_noise_warning_coverage_and_rules_are_required(self):
        self.assertEqual(len(pilot.NOISE_REQUIRED),5)
        self.assertTrue({"BaitlyNoiseWarningMetricsUnavailable","BaitlyNoiseWarningUncertain",
                         "BaitlyNoiseWarningRepairStalled"}.issubset(pilot.RULES))
        self.assertEqual(len(pilot.RULES),33)
        for metric in pilot.NOISE_REQUIRED:
            self.assertIn(metric,pilot.NOISE_COVERAGE)

    def test_missing_noise_metrics_on_one_replica_prevent_reload(self):
        def sample(base,expr):
            if expr==pilot.RECOVERY_COVERAGE: return 0
            if expr==pilot.NOISE_COVERAGE: raise RuntimeError("Noise coverage incomplete")
            return 1
        with patch("sys.argv",["pilot","--reload"]), patch.object(pilot,"endpoint",return_value="private"), \
             patch.object(pilot,"query",side_effect=sample), patch.object(pilot,"wait_for",side_effect=lambda check: check()), \
             patch.object(pilot,"reload_configuration") as reload:
            with self.assertRaisesRegex(RuntimeError,"Noise coverage incomplete"):
                pilot.main()
            reload.assert_not_called()

    def test_stale_or_negative_noise_snapshot_is_refused(self):
        for bad in ("stale","negative"):
            def sample(base,expr):
                if expr in (pilot.RECOVERY_COVERAGE,pilot.NOISE_COVERAGE,pilot.AUTOMATION_COVERAGE,pilot.EXTERNAL_EFFECT_COVERAGE): return 0
                if bad=="stale" and "time() - baitly_noise_warning_" in expr: return 181
                if bad=="negative" and "min(baitly_noise_warning_uncertain" in expr: return -1
                return 1
            with patch.object(pilot,"query",side_effect=sample), \
                 patch.object(pilot,"wait_for",side_effect=lambda check: self.assertFalse(check())):
                pilot.validate_backend("private")

    def test_automation_requires_all_nine_valid_samples_per_live_replica(self):
        self.assertEqual(len(pilot.AUTOMATION_REQUIRED),9)
        for metric in pilot.AUTOMATION_REQUIRED:
            self.assertIn(metric,pilot.AUTOMATION_COVERAGE)
        self.assertIn("count by(job,instance)",pilot.AUTOMATION_COVERAGE)
        self.assertIn("< +Inf",pilot.AUTOMATION_COVERAGE)
        self.assertIn(">= -60",pilot.AUTOMATION_COVERAGE)
        self.assertIn("<= 180",pilot.AUTOMATION_COVERAGE)
        self.assertTrue({"BaitlyAutomationMetricsUnavailable","BaitlyAutomationStalled",
                         "BaitlyAutomationUncertain","BaitlyAutomationReviewRequired"}.issubset(pilot.RULES))

    def test_invalid_automation_replica_prevents_reload_even_when_other_collectors_are_healthy(self):
        def sample(base,expr):
            if expr in (pilot.RECOVERY_COVERAGE,pilot.NOISE_COVERAGE): return 0
            if expr==pilot.AUTOMATION_COVERAGE: raise RuntimeError("Automation coverage invalid")
            return 1
        with patch("sys.argv",["pilot","--reload"]), patch.object(pilot,"endpoint",return_value="private"), \
             patch.object(pilot,"query",side_effect=sample), patch.object(pilot,"wait_for",side_effect=lambda check: check()), \
             patch.object(pilot,"reload_configuration") as reload:
            with self.assertRaisesRegex(RuntimeError,"Automation coverage invalid"):
                pilot.main()
            reload.assert_not_called()

    def test_nonzero_invalid_automation_replica_count_is_not_ready(self):
        def sample(base,expr):
            if expr in (pilot.RECOVERY_COVERAGE,pilot.NOISE_COVERAGE): return 0
            return 1
        with patch.object(pilot,"query",side_effect=sample), \
             patch.object(pilot,"wait_for",side_effect=lambda check: self.assertFalse(check())):
            pilot.validate_backend("private")


    def test_external_effects_require_all_nine_finite_fresh_samples_per_replica(self):
        self.assertEqual(len(pilot.EXTERNAL_EFFECT_REQUIRED), 9)
        for metric in pilot.EXTERNAL_EFFECT_REQUIRED:
            self.assertIn(metric, pilot.EXTERNAL_EFFECT_COVERAGE)
        for fragment in ("count by(job,instance)", "on(__name__,job,instance)", "< +Inf", ">= -60", "<= 180"):
            self.assertIn(fragment, pilot.EXTERNAL_EFFECT_COVERAGE)
        self.assertTrue({"BaitlyExternalEffectMetricsUnavailable", "BaitlyLockEffectUncertain",
                         "BaitlyReportEffectUncertain", "BaitlyReportEffectPartial"}.issubset(pilot.RULES))

    def test_external_effects_missing_snapshot_prevents_reload(self):
        def sample(base, expr):
            if expr == pilot.EXTERNAL_EFFECT_COVERAGE:
                raise RuntimeError("External effect coverage invalid")
            if expr in (pilot.RECOVERY_COVERAGE, pilot.NOISE_COVERAGE, pilot.AUTOMATION_COVERAGE):
                return 0
            return 1
        with patch("sys.argv", ["pilot", "--reload"]), patch.object(pilot, "endpoint", return_value="private"), \
             patch.object(pilot, "query", side_effect=sample), patch.object(pilot, "wait_for", side_effect=lambda check: check()), \
             patch.object(pilot, "reload_configuration") as reload:
            with self.assertRaisesRegex(RuntimeError, "External effect coverage invalid"):
                pilot.main()
            reload.assert_not_called()

    def test_external_effects_one_incomplete_replica_is_not_ready(self):
        def sample(base, expr):
            if expr in (pilot.RECOVERY_COVERAGE, pilot.NOISE_COVERAGE, pilot.AUTOMATION_COVERAGE):
                return 0
            return 1
        with patch.object(pilot, "query", side_effect=sample), \
             patch.object(pilot, "wait_for", side_effect=lambda check: self.assertFalse(check())):
            pilot.validate_backend("private")

    def test_external_effect_summary_uses_max_without_customer_labels(self):
        with patch.object(pilot, "validate_backend"), patch.object(pilot, "wait_for"), \
             patch.object(pilot, "query", return_value=0) as query, patch("builtins.print"):
            pilot.validate("private")
        expressions = [call.args[1] for call in query.call_args_list if "baitly_external_effect_" in call.args[1]]
        self.assertEqual(len(expressions), len(pilot.EXTERNAL_EFFECT_METRICS))
        self.assertTrue(all(expr.startswith("max(") for expr in expressions))
        self.assertTrue(all("organization" not in expr and "resource" not in expr for expr in expressions))

if __name__ == "__main__":
    unittest.main()
