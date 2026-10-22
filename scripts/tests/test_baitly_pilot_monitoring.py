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
             patch.object(pilot, "query", return_value=0), patch.object(pilot, "wait_for", side_effect=RuntimeError("timeout")), \
             patch.object(pilot, "request") as request:
            with self.assertRaisesRegex(RuntimeError, "timeout"):
                pilot.canary("prom", "am")
            self.assertEqual(request.call_count, 2)
            self.assertEqual(request.call_args.args[1], "/api/v2/alerts")
            self.assertEqual(request.call_args.args[2][0]["labels"]["job"], "baitly-pilot-recipe")


if __name__ == "__main__":
    unittest.main()
