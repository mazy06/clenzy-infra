#!/usr/bin/env python3
"""Transport a validated release over pinned SSH; never run commands on the PMS."""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from deployment_contract import validate_settings, require_approval
from install import verify_release, unpack_tls


def main():
    require_approval(os.environ)
    host, user = os.environ["IOT_HOST"], os.environ["IOT_USER"]
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", host) or not re.fullmatch(r"[a-z_][a-z0-9_-]*", user):
        raise ValueError("Invalid IoT SSH destination")
    if host == os.environ["PMS_IP"]:
        raise ValueError("Refusing to deploy on the PMS")
    port = int(os.environ.get("IOT_SSH_PORT", "22"))
    sha = os.environ["APP_SHA"]
    if not re.fullmatch("[a-f0-9]{40}", sha):
        raise ValueError("Full source SHA required")
    settings = {"pms_ip": os.environ["PMS_IP"], "pms_database_ip": os.environ["PMS_DATABASE_IP"],
                "pms_machine_id": os.environ["PMS_MACHINE_ID"], "ssh_port": port,
                "service_token": os.environ["IOT_SERVICE_TOKEN"], "store_password": os.environ["IOT_STORE_PASSWORD"]}
    validate_settings(settings)
    verify_release(Path("release"), sha)
    with tempfile.TemporaryDirectory(prefix="baitly-iot-deploy-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        key = root / "ssh-key"
        key.write_text(os.environ["IOT_SSH_KEY"] + "\n"); key.chmod(0o600)
        known = root / "known_hosts"
        known.write_text(os.environ["IOT_KNOWN_HOSTS"] + "\n"); known.chmod(0o600)
        options = ["-F", "/dev/null", "-i", str(key), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                   "-o", "ForwardAgent=no", "-o", "IdentitiesOnly=yes",
                   "-o", "UserKnownHostsFile=" + str(known), "-o", "ConnectTimeout=10"]
        ssh = ["ssh", *options, "-p", str(port), user + "@" + host]
        payload = root / "payload"; payload.mkdir(mode=0o700)
        shutil.copytree("release", payload / "release")
        shutil.copytree("iot", payload / "iot", ignore=shutil.ignore_patterns("__pycache__"))
        (payload / "tls.tar.gz").write_bytes(base64.b64decode(os.environ["IOT_RUNTIME_TLS_B64"], validate=True))
        (payload / "settings.json").write_text(json.dumps(settings))
        (payload / "settings.json").chmod(0o600)
        (payload / "tls.tar.gz").chmod(0o600)
        preflight = root / "tls-check"; preflight.mkdir()
        unpack_tls(payload / "tls.tar.gz", preflight)
        remote = subprocess.check_output([*ssh, "mktemp -d /tmp/baitly-iot.XXXXXXXXXX"], text=True, timeout=20).strip()
        if not re.fullmatch(r"/tmp/baitly-iot\.[a-zA-Z0-9]+", remote):
            raise ValueError("Unexpected remote staging directory")
        try:
            subprocess.run(["scp", *options, "-P", str(port), "-r", str(payload) + "/.", user + "@" + host + ":" + remote], check=True)
            bootstrap = " --bootstrap" if os.environ.get("IOT_BOOTSTRAP") == "true" else ""
            subprocess.run([*ssh, "sudo python3 " + remote + "/iot/install.py --approve-staging --release " + remote + "/release --sha " + sha
                            + " --settings " + remote + "/settings.json --tls-bundle " + remote + "/tls.tar.gz" + bootstrap], check=True)
            report = subprocess.check_output([*ssh, "sudo python3 " + remote + "/iot/verify_network.py --settings "
                                               + remote + "/settings.json --sha " + sha], text=True)
            Path("network-qualification.json").write_text(report)
        finally:
            subprocess.run([*ssh, "sudo rm -rf -- " + remote], check=True)


if __name__ == "__main__":
    main()
