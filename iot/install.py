#!/usr/bin/env python3
"""CI/CD only. Install a pinned Baitly release on a dedicated Ubuntu 24.04 staging VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import tarfile
import tempfile

from database import provision, grant_runtime
from render_firewall import render
from deployment_contract import validate_settings

TLS_FILES = {"server.crt", "server.key", "server-ca.crt", "devices-ca.crt", "ingestion-ca.crt", "ingestor.p12"}


def run(*args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=kwargs.pop("timeout", 120), **kwargs)
    if result.returncode:
        raise RuntimeError("Deployment step failed: " + args[0] + " (output withheld)")
    return result.stdout


def verify_release(root, sha):
    if not re.fullmatch("[a-f0-9]{40}", sha) or (root / "source-sha").read_text().strip() != sha:
        raise ValueError("Release does not match the approved commit")
    expected = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and path != root / "SHA256SUMS"}
    if any(path.is_symlink() for path in root.rglob("*")):
        raise ValueError("Release symlinks are forbidden")
    required = {"source-sha", "baitly-iot.jar", "deploy/mosquitto.conf", "deploy/devices.acl", "deploy/ingestion.acl",
                "deploy/nginx-ingestion.conf", "deploy/nginx-private-api.conf", "scripts/mqtt_pki.py", "scripts/simulate_noise.py",
                "scripts/requirements.txt"}
    if not required <= expected:
        raise ValueError("Incomplete release")
    seen = set()
    for line in (root / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ", 1)
        name = name.removeprefix("./")
        if not re.fullmatch("[a-f0-9]{64}", digest) or name in seen:
            raise ValueError("Invalid or duplicate manifest entry")
        seen.add(name)
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()) or path.is_symlink() or not path.is_file():
            raise ValueError("Invalid release manifest path")
        with path.open("rb") as source:
            actual = hashlib.file_digest(source, "sha256").hexdigest()
        if actual != digest:
            raise ValueError("Release checksum mismatch")
    if seen != expected:
        raise ValueError("Manifest must cover the complete release")


def unpack_tls(bundle, target):
    with tarfile.open(bundle, "r:gz") as archive:
        members = archive.getmembers()
        if len(members) != len(TLS_FILES) or {item.name for item in members} != TLS_FILES or any(not item.isfile() or not 0 < item.size <= 32768 for item in members):
            raise ValueError("TLS bundle must contain only the six runtime files, never a CA signing key")
        for item in members:
            path = target / item.name
            path.write_bytes(archive.extractfile(item).read())
            path.chmod(0o640)


def write(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
    path.chmod(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--tls-bundle", type=Path, required=True)
    parser.add_argument("--bootstrap", action="store_true")
    parser.add_argument("--approve-staging", action="store_true")
    args = parser.parse_args()
    if not args.approve_staging:
        raise ValueError("Deployment is on hold; --approve-staging is required")
    if os.geteuid() != 0:
        raise PermissionError("CI/CD installer requires sudo on the dedicated VM")
    os.umask(0o077)
    verify_release(args.release, args.sha)
    settings = json.loads(args.settings.read_text())
    validate_settings(settings)
    # Reject malformed TLS inputs before apt, SQL, firewall or service mutations.
    with tempfile.TemporaryDirectory(prefix="baitly-tls-preflight-") as temporary:
        unpack_tls(args.tls_bundle, Path(temporary))
    if Path("/etc/machine-id").read_text().strip() == settings["pms_machine_id"] or Path("/var/run/docker.sock").exists():
        raise ValueError("Refusing the PMS/shared Docker host")
    marker = Path("/etc/baitly-iot/staging-vm")
    if not marker.exists():
        if not args.bootstrap or 'ID=ubuntu\n' not in Path("/etc/os-release").read_text() or 'VERSION_ID="24.04"' not in Path("/etc/os-release").read_text():
            raise ValueError("First install requires --bootstrap and dedicated Ubuntu 24.04")
        run("apt-get", "update", timeout=300)
        # Prevent distribution packages from exposing their default services during bootstrap.
        policy_rc = Path("/usr/sbin/policy-rc.d")
        created_policy = not policy_rc.exists()
        if created_policy:
            write(policy_rc, "#!/bin/sh\nexit 101\n", 0o755)
        try:
            run("apt-get", "install", "-y", "openjdk-21-jre-headless", "postgresql-16", "mosquitto", "nginx", "nftables", "python3-venv", timeout=600,
                env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
        finally:
            if created_policy:
                policy_rc.unlink()
        try:
            pwd.getpwnam("baitly_iot_runtime")
        except KeyError:
            run("useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", "baitly_iot_runtime")
        # Only new native services on the dedicated VM; no Docker/PMS operations.
        run("systemctl", "disable", "--now", "mosquitto.service", "nginx.service")
        run("systemctl", "enable", "--now", "postgresql.service")
        write(marker, "Baitly IoT staging only\n")
    runtime = pwd.getpwnam("baitly_iot_runtime")
    mqtt = pwd.getpwnam("mosquitto")
    edge = pwd.getpwnam("www-data")
    policy = render(settings["pms_ip"], settings["pms_database_ip"], runtime.pw_uid, mqtt.pw_uid, edge.pw_uid, settings["ssh_port"])
    write("/etc/baitly-iot/isolation.nft", "add table inet baitly_iot\ndelete table inet baitly_iot\n" + policy)
    run("nft", "-c", "-f", "/etc/baitly-iot/isolation.nft")
    config = Path("/etc/baitly-iot")
    credentials = provision(config)
    release = Path("/opt/baitly-iot/releases") / args.sha
    release.mkdir(parents=True, exist_ok=True)
    for directory in (release, release.parent, release.parent.parent):
        directory.chmod(0o755)
    shutil.copy2(args.release / "baitly-iot.jar", release / "baitly-iot.jar")
    (release / "baitly-iot.jar").chmod(0o644)
    # Migration identity exists only in this root-only file; the runtime never receives it.
    migration = config / "migration.properties"
    write(migration, "\n".join(("url=jdbc:postgresql://127.0.0.1:5432/baitly_iot_staging", "username=baitly_iot_migration",
         "password=" + credentials["migration"], "changeLogFile=db/changelog/db.changelog-master.yaml")) + "\n")
    try:
        run("java", "-Dloader.main=com.baitly.iot.IotMigrationMain", "-cp", str(release / "baitly-iot.jar"),
            "org.springframework.boot.loader.launch.PropertiesLauncher", str(migration))
    finally:
        migration.unlink(missing_ok=True)
    grant_runtime()
    tls = Path("/etc/baitly-mqtt/tls")
    tls.mkdir(parents=True, exist_ok=True)
    for directory in (tls, tls.parent):
        directory.chmod(0o750)
        os.chown(directory, 0, mqtt.pw_gid)
    # The receiver needs its own identity, not the server's key or the device CA private key.
    identity = config / "tls"
    identity.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="baitly-tls-") as temporary:
        unpack_tls(args.tls_bundle, Path(temporary))
        for name in TLS_FILES - {"ingestor.p12"}:
            shutil.copy2(Path(temporary) / name, tls / name)
            os.chown(tls / name, 0, mqtt.pw_gid)
        for name in ("server-ca.crt", "ingestor.p12"):
            shutil.copy2(Path(temporary) / name, identity / name)
            os.chown(identity / name, 0, runtime.pw_gid)
            (identity / name).chmod(0o640)
    os.chmod(config, 0o755)
    os.chmod(identity, 0o750)
    os.chown(identity, 0, runtime.pw_gid)
    for name in ("mosquitto.conf", "devices.acl", "ingestion.acl"):
        shutil.copy2(args.release / "deploy" / name, tls.parent / name)
        os.chown(tls.parent / name, 0, mqtt.pw_gid)
        (tls.parent / name).chmod(0o640)
    runtime_env = {
        "SPRING_PROFILES_ACTIVE": "hardened", "BAITLY_IOT_BIND_ADDRESS": "127.0.0.1",
        "BAITLY_IOT_DATABASE_URL": "jdbc:postgresql://127.0.0.1:5432/baitly_iot_staging",
        "BAITLY_IOT_DATABASE_USER": "baitly_iot_runtime", "BAITLY_IOT_DATABASE_PASSWORD": credentials["runtime"],
        "BAITLY_IOT_SERVICE_TOKEN": settings["service_token"], "BAITLY_IOT_MQTT_ENABLED": "true",
        "BAITLY_IOT_MQTT_HOST": "localhost", "BAITLY_IOT_MQTT_PORT": "8884",
        "BAITLY_IOT_MQTT_CA_FILE": str(identity / "server-ca.crt"),
        "BAITLY_IOT_MQTT_CLIENT_STORE": str(identity / "ingestor.p12"),
        "BAITLY_IOT_MQTT_CLIENT_STORE_PASSWORD": settings["store_password"],
    }
    write(config / "runtime.env", "".join(key + "=" + value + "\n" for key, value in runtime_env.items()))
    edge_dir = Path("/etc/baitly-iot-edge")
    edge_dir.mkdir(exist_ok=True)
    nginx = (args.release / "deploy/nginx-ingestion.conf").read_text().replace("events {", "user www-data;\npid /run/baitly-iot-edge/nginx.pid;\nerror_log /var/log/baitly-iot-edge/error.log;\nevents {")
    nginx = nginx.replace("http {", "http {\n client_body_temp_path /run/baitly-iot-edge/client;\n proxy_temp_path /run/baitly-iot-edge/proxy;")
    nginx = nginx.replace("/var/log/nginx/", "/var/log/baitly-iot-edge/")
    nginx = nginx.replace("/etc/nginx/tls/fullchain.pem", str(tls / "server.crt")).replace("/etc/nginx/tls/privkey.pem", str(tls / "server.key"))
    private = (args.release / "deploy/nginx-private-api.conf").read_text().replace("/etc/nginx/tls/fullchain.pem", str(tls / "server.crt")).replace("/etc/nginx/tls/privkey.pem", str(tls / "server.key"))
    nginx = nginx.replace("http {", "http {\n" + private, 1)
    write(edge_dir / "nginx.conf", nginx)
    for path in Path(__file__).parent.glob("*.service"):
        shutil.copy2(path, Path("/etc/systemd/system") / path.name)
    current = Path("/opt/baitly-iot/current")
    next_link = current.with_name(".next")
    next_link.unlink(missing_ok=True)
    next_link.symlink_to(release)
    next_link.replace(current)
    run("systemctl", "daemon-reload")
    run("systemctl", "enable", "baitly-iot-firewall", "baitly-iot-mqtt", "baitly-iot", "baitly-iot-edge")
    run("systemctl", "restart", "baitly-iot-firewall", "baitly-iot-mqtt", "baitly-iot", "baitly-iot-edge")
    run("systemctl", "is-active", "baitly-iot-firewall", "baitly-iot-mqtt", "baitly-iot", "baitly-iot-edge")
    write(config / "deployed-sha", args.sha + "\n")
    print("Pinned IoT staging release installed; network and end-to-end qualification still required")


if __name__ == "__main__":
    main()
