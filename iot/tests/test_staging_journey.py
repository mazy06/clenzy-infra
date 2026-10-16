import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import validate_staging


class JourneyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        os.chdir(temporary.name)
        self.calls, self.messages = [], []
        self.synthetic, self.decibels, self.refused = True, 62.4, True
        self.environment = {"IOT_STAGING_VALIDATION_APPROVED": "true", "APP_SHA": "a" * 40,
            "IOT_STAGING_PMS_TOKEN": "user-jwt-fixture", "IOT_TEST_PROPERTY_ID": "11",
            "IOT_MQTT_HOST": "iot-staging.example.test", "IOT_DEVICE_CA_CERT": "certificate-fixture",
            "IOT_DEVICE_CA_KEY": "private-signing-key-fixture", "IOT_SERVER_CA_CERT": "server-ca-fixture",
            "GH_TOKEN": "control-plane-token-fixture", "PATH": os.environ.get("PATH", "")}

    def response(self, request, timeout):
        method, url = request.get_method(), request.full_url
        self.calls.append((method, url))
        self.assertTrue(url.startswith("https://app.clenzy.fr/api/"))
        if url.endswith("/configuration"): body = {"configured": True}
        elif method == "POST" and url.endswith("/noise-devices"):
            self.assertEqual(json.loads(request.data)["propertyId"], 11)
            body = {"id": 7}
        elif url.endswith("/credentials"): body = {"token": "b" * 43}
        elif "/data?" in url: body = [{"time": "2026-10-16T12:00:00Z", "decibels": self.decibels}]
        elif method == "GET": body = {"simulation": self.synthetic, "online": True}
        else: body = None
        class Response(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
        return Response(json.dumps(body).encode() if body is not None else b"")

    def execute(self, command, **kwargs):
        environment = kwargs["env"]
        self.assertNotIn("IOT_DEVICE_CA_KEY", environment)
        self.assertNotIn("IOT_STAGING_PMS_TOKEN", environment)
        self.assertNotIn("GH_TOKEN", environment)
        if "issue-device" in command:
            return subprocess.CompletedProcess(command, 0, "", "")
        self.messages.append(command)
        if len(self.messages) == 1:
            return subprocess.CompletedProcess(command, 0, 'SIMULATION: MQTT persisted {"duplicate": false}', "")
        if len(self.messages) == 2:
            return subprocess.CompletedProcess(command, 0, 'SIMULATION: MQTT persisted {"duplicate": true}', "")
        return subprocess.CompletedProcess(command, 1 if self.refused else 0, "", "MQTT receipt 401" if self.refused else "")

    def run_journey(self):
        opener = unittest.mock.Mock()
        opener.open.side_effect = self.response
        with patch.dict(os.environ, self.environment, clear=True), \
                patch.object(validate_staging.urllib.request, "build_opener", return_value=opener), \
                patch.object(validate_staging.subprocess, "run", side_effect=self.execute):
            validate_staging.main()

    def test_full_orchestration_retry_history_revocation_cleanup_and_secret_separation(self):
        self.run_journey()
        self.assertEqual(self.messages[0], self.messages[1])
        self.assertEqual(self.messages[0], self.messages[2])
        self.assertEqual(self.calls[-1], ("DELETE", "https://app.clenzy.fr/api/baitly-iot/noise-devices/7"))
        report = json.loads(Path("mqtt-staging-qualification.json").read_text())
        self.assertEqual(report["status"], "passed")
        self.assertTrue(report["pmsHistory"] and report["deduplicated"] and report["revoked"])
        self.assertNotIn("token", json.dumps(report).lower())

    def test_wrong_measurement_fails_and_still_cleans_up(self):
        self.decibels = 40.0
        Path("mqtt-staging-qualification.json").write_text('{"status":"passed"}')
        with self.assertRaisesRegex(RuntimeError, "history"):
            self.run_journey()
        self.assertEqual(self.calls[-1][0], "DELETE")
        self.assertFalse(Path("mqtt-staging-qualification.json").exists())

    def test_physical_device_is_neither_rotated_nor_deleted(self):
        self.synthetic = False
        with self.assertRaisesRegex(RuntimeError, "physical"):
            self.run_journey()
        self.assertFalse(any(method == "DELETE" or url.endswith("/credentials") for method, url in self.calls))
        self.assertEqual(self.messages, [])

    def test_revocation_must_be_explicitly_proven(self):
        self.refused = False
        with self.assertRaisesRegex(RuntimeError, "Revoked"):
            self.run_journey()
        self.assertEqual(self.calls[-1][0], "DELETE")
        self.assertFalse(Path("mqtt-staging-qualification.json").exists())


if __name__ == "__main__":
    unittest.main()
