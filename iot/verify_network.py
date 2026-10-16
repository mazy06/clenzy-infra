#!/usr/bin/env python3
"""Prove blocked connections hit our firewall, rather than merely timing out remotely."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys


def counters():
    value = json.loads(subprocess.check_output(["nft", "-j", "list", "chain", "inet", "baitly_iot", "output"]))
    return sum(part["counter"]["packets"] for entry in value["nftables"]
               for part in entry.get("rule", {}).get("expr", []) if "counter" in part)


def probe(user, host, port):
    code = "import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=2); s.close()"
    result = subprocess.run(["runuser", "-u", user, "--", "python3", "-c", code,
                             host, str(port)], capture_output=True, timeout=6)
    return result.returncode == 0


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--probe":
        try:
            with socket.create_connection((sys.argv[2], int(sys.argv[3])), timeout=2):
                return 0
        except OSError:
            return 1
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--settings", type=Path, required=True)
    p.add_argument("--sha", required=True)
    a = p.parse_args()
    if os.geteuid() != 0:
        raise PermissionError("Network verification requires the dedicated VM root context")
    settings = json.loads(a.settings.read_text())
    if Path("/etc/baitly-iot/deployed-sha").read_text().strip() != a.sha:
        raise ValueError("Wrong staging release")
    if Path("/etc/machine-id").read_text().strip() == settings["pms_machine_id"]:
        raise ValueError("IoT and PMS are on the same VM")
    checks = []
    for user in ("baitly_iot_runtime", "mosquitto", "www-data"):
        if not probe(user, "127.0.0.1", 8096):
            raise RuntimeError("Loopback positive control failed")
        for label, host, port in (("pms", settings["pms_ip"], 443), ("pms-database", settings["pms_database_ip"], 5432),
                                  ("cloud-metadata", "169.254.169.254", 80)):
            before = counters()
            if probe(user, host, port) or counters() <= before:
                raise RuntimeError("Isolation not proven for " + user + ":" + label)
            checks.append(user + ":" + label + ":blocked-by-local-firewall")
    print(json.dumps({"sourceSha": a.sha, "networkIsolation": "passed", "checks": checks}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
