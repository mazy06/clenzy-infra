#!/usr/bin/env python3
"""PMS tenant authorization → simulated device → public MQTT/mTLS → PMS noise history."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.parse
import urllib.request
import uuid
import re


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def main():
    if os.environ.get("IOT_STAGING_VALIDATION_APPROVED") != "true":
        raise ValueError("Staging validation is on hold; no API calls authorized")
    if not re.fullmatch("[a-f0-9]{40}", os.environ["APP_SHA"]):
        raise ValueError("Full source SHA required")
    Path("mqtt-staging-qualification.json").unlink(missing_ok=True)
    base = "https://app.clenzy.fr/api"
    bearer = os.environ["IOT_STAGING_PMS_TOKEN"]
    property_id = int(os.environ["IOT_TEST_PROPERTY_ID"])
    if property_id < 1 or not bearer or any(c.isspace() for c in bearer):
        raise ValueError("Dedicated staging test account and property required")
    opener = urllib.request.build_opener(NoRedirect())

    def api(method, path, body=None):
        request = urllib.request.Request(base + path, method=method,
                data=None if body is None else json.dumps(body).encode(),
                headers={"Authorization": "Bearer " + bearer, "Content-Type": "application/json"})
        try:
            with opener.open(request, timeout=10) as response:
                data = response.read(4 * 1024 * 1024 + 1)
                if len(data) > 4 * 1024 * 1024: raise ValueError("Excessive staging response")
                return json.loads(data) if data else None
        except Exception:
            raise RuntimeError("Staging PMS API step failed; response and credentials withheld") from None

    if not api("GET", "/baitly-iot/configuration").get("configured"):
        raise RuntimeError("PMS IoT integration is not configured in staging")
    request_id = str(uuid.uuid4())
    device = api("POST", "/baitly-iot/noise-devices", {"requestId": request_id, "propertyId": property_id,
                 "name": "MQTT staging qualification", "roomName": "CI simulator"})
    device_id = int(device["id"])
    prefix = "/baitly-iot/noise-devices/" + str(device_id)
    synthetic_confirmed = False
    try:
        state = api("GET", prefix)
        if state.get("simulation") is not True:
            raise RuntimeError("Refusing synthetic data for a physical device")
        synthetic_confirmed = True
        token = api("POST", prefix + "/credentials")["token"]
        with tempfile.TemporaryDirectory(prefix="baitly-mqtt-qualification-") as temporary:
            pki = Path(temporary); pki.chmod(0o700)
            for name, env in (("devices-ca.crt", "IOT_DEVICE_CA_CERT"), ("devices-ca.key", "IOT_DEVICE_CA_KEY"), ("server-ca.crt", "IOT_SERVER_CA_CERT")):
                (pki / name).write_text(os.environ[env] + "\n"); (pki / name).chmod(0o600)
            fingerprint = hashlib.sha256(token.encode()).hexdigest()
            child_env = {**{key: value for key, value in os.environ.items() if key in
                           ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR")},
                         "BAITLY_MQTT_P12_PASSWORD": uuid.uuid4().hex,
                         "BAITLY_IOT_DEVICE_TOKEN": token}
            subprocess.run(["python3", "release/scripts/mqtt_pki.py", "issue-device", "--directory", str(pki),
                "--fingerprint", fingerprint, "--days", "1"], env=child_env, check=True, capture_output=True)
            measured = dt.datetime.now(dt.timezone.utc)
            event = str(uuid.uuid4())
            command = ["python3", "release/scripts/simulate_noise.py", "--transport", "mqtt", "--mqtt-host", os.environ["IOT_MQTT_HOST"],
                "--ca-file", str(pki / "server-ca.crt"), "--cert-file", str(pki / ("device-" + fingerprint + ".crt")),
                "--key-file", str(pki / ("device-" + fingerprint + ".key")), "--level", "62.4", "--event-id", event,
                "--measured-at", measured.isoformat(timespec="milliseconds")]

            def send():
                result = subprocess.run(command, env=child_env, capture_output=True, text=True, timeout=30)
                if result.returncode:
                    raise RuntimeError("MQTT staging simulation failed; no persistence proved")
                return result.stdout

            send()
            if '"duplicate": true' not in send():
                raise RuntimeError("MQTT retry was not idempotent")
            query = urllib.parse.urlencode({"start": (measured - dt.timedelta(minutes=1)).isoformat(),
                                           "end": (measured + dt.timedelta(minutes=1)).isoformat()})
            history = api("GET", "/noise-devices/" + str(device_id) + "/data?" + query)
            if len(history) != 1 or float(history[0]["decibels"]) != 62.4:
                raise RuntimeError("PMS history did not return the committed MQTT sample")
            if not api("GET", prefix).get("online"):
                raise RuntimeError("PMS did not observe live device reception")
            api("POST", prefix + "/revoke")
            refused = subprocess.run(command, env=child_env, capture_output=True, text=True, timeout=30)
            if refused.returncode == 0 or "401" not in refused.stderr:
                raise RuntimeError("Revoked MQTT identity was not explicitly refused")
            Path("mqtt-staging-qualification.json").write_text(json.dumps({"status": "passed", "pms": base,
                "sourceSha": os.environ["APP_SHA"], "synthetic": True, "mqttPersisted": True,
                "pmsHistory": True, "deduplicated": True, "revoked": True}))
    finally:
        if synthetic_confirmed:
            api("DELETE", prefix)


if __name__ == "__main__":
    main()
