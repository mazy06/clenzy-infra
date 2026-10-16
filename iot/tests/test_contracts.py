import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy_ci
import install
import validate_staging
import verify_network
from deployment_contract import validate_settings
from release_source import validate
from render_firewall import render


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.source = {"id": 123, "head_sha": self.sha, "head_branch": "main", "event": "push",
                       "status": "completed", "conclusion": "success", "path": ".github/workflows/ci-baitly-iot.yml",
                       "head_repository": {"full_name": "mazy06/clenzy"}}

    def test_only_complete_audited_main_run_is_accepted(self):
        validate(self.source, "mazy06/clenzy", self.sha, "123")
        for key, value in (("head_sha", "b" * 40), ("head_branch", "production"), ("event", "pull_request"),
                           ("status", "in_progress"), ("conclusion", "failure"), ("path", ".github/workflows/ci-backend.yml"),
                           ("id", 124), ("head_repository", {"full_name": "outsider/clenzy"})):
            with self.subTest(key=key):
                changed = {**self.source, key: value}
                with self.assertRaises(ValueError):
                    validate(changed, "mazy06/clenzy", self.sha, "123")

    def test_rejects_shell_metacharacters_and_short_sha(self):
        for sha, run in (("abcd", "123"), (self.sha, "1;echo bad"), (self.sha, "0")):
            with self.assertRaises(ValueError):
                validate(self.source, "mazy06/clenzy", sha, run)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sha = "a" * 40
        names = ("source-sha", "baitly-iot.jar", "deploy/mosquitto.conf", "deploy/devices.acl", "deploy/ingestion.acl",
                 "deploy/nginx-ingestion.conf", "deploy/nginx-private-api.conf", "scripts/mqtt_pki.py",
                 "scripts/simulate_noise.py", "scripts/requirements.txt")
        for name in names:
            file = self.root / name; file.parent.mkdir(exist_ok=True)
            file.write_text(self.sha + "\n" if name == "source-sha" else "fixture")
        self.manifest()

    def manifest(self):
        files = sorted(path for path in self.root.rglob("*") if path.is_file() and path.name != "SHA256SUMS")
        (self.root / "SHA256SUMS").write_text("".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  ./"
                  + path.relative_to(self.root).as_posix() + "\n" for path in files))

    def test_complete_release_is_accepted(self):
        install.verify_release(self.root, self.sha)

    def test_changed_jar_is_rejected(self):
        (self.root / "baitly-iot.jar").write_text("modified")
        with self.assertRaises(ValueError): install.verify_release(self.root, self.sha)

    def test_empty_partial_duplicate_and_traversal_manifests_are_rejected(self):
        original = (self.root / "SHA256SUMS").read_text()
        for value in ("", original.splitlines()[0] + "\n", original + original.splitlines()[0] + "\n",
                      original + "0" * 64 + "  ../outside\n"):
            with self.subTest(value=value[:30]):
                (self.root / "SHA256SUMS").write_text(value)
                with self.assertRaises(ValueError): install.verify_release(self.root, self.sha)

    def test_unlisted_file_and_symlink_are_rejected(self):
        extra = self.root / "extra.py"; extra.write_text("unexpected")
        with self.assertRaises(ValueError): install.verify_release(self.root, self.sha)
        extra.unlink(); extra.symlink_to(self.root / "baitly-iot.jar")
        with self.assertRaises(ValueError): install.verify_release(self.root, self.sha)

    def test_wrong_source_sha_is_rejected(self):
        with self.assertRaises(ValueError): install.verify_release(self.root, "b" * 40)

    def test_nested_manifest_names_are_not_exempt_from_integrity_checks(self):
        (self.root / "scripts/SHA256SUMS").write_text("unlisted")
        with self.assertRaises(ValueError): install.verify_release(self.root, self.sha)

    def bundle(self, extra=None, duplicate=False, symlink=False):
        bundle = self.root / "tls.tar.gz"
        with tarfile.open(bundle, "w:gz") as archive:
            for name in sorted(install.TLS_FILES) + ([extra] if extra else []) + (["server.key"] if duplicate else []):
                item = tarfile.TarInfo(name)
                if symlink and name == "server.key":
                    item.type = tarfile.SYMTYPE; item.linkname = "/etc/shadow"; archive.addfile(item)
                else:
                    item.size = 4; archive.addfile(item, io.BytesIO(b"test"))
        return bundle

    def test_runtime_tls_bundle_permissions_and_allowlist(self):
        target = self.root / "tls"; target.mkdir()
        install.unpack_tls(self.bundle(), target)
        self.assertEqual({p.name for p in target.iterdir()}, install.TLS_FILES)
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o640 for path in target.iterdir()))
        for kwargs in ({"extra": "devices-ca.key"}, {"extra": "../outside"}, {"duplicate": True}, {"symlink": True}):
            with self.assertRaises(ValueError): install.unpack_tls(self.bundle(**kwargs), target)


class FirewallTests(unittest.TestCase):
    def test_external_destinations_are_denied_but_reply_and_loopback_are_kept(self):
        text = render("10.20.0.1", "10.20.0.2", 1001, 1002, 1003)
        self.assertIn("policy drop", text)
        self.assertIn("meta skuid { 1001, 1002, 1003 } counter reject", text)
        self.assertLess(text.index("ct state established,related accept"), text.index("counter reject"))
        self.assertIn("ip saddr 10.20.0.1 tcp dport 8444 accept", text)
        self.assertNotIn("tcp dport 8096 accept", text)

    def test_shared_pms_database_address_is_deduplicated(self):
        self.assertIn("ip daddr { 10.20.0.1 }", render("10.20.0.1", "10.20.0.1", 1001, 1002, 1003))

    def test_invalid_addresses_ports_and_privileged_uids_are_rejected(self):
        for ip in ("127.0.0.1", "::1", "169.254.169.254", "224.0.0.1", "0.0.0.0", "10.0.0.1;bad"):
            with self.assertRaises(ValueError): render(ip, "10.20.0.2", 1001, 1002, 1003)
        for port in (0, -1, 65536, 443, 8883, 8444, True):
            with self.assertRaises(ValueError): render("10.20.0.1", "10.20.0.2", 1001, 1002, 1003, port)
        for uids in ((0, 2, 3), (1, 1, 2), (True, 2, 3)):
            with self.assertRaises(ValueError): render("10.20.0.1", "10.20.0.2", *uids)

    def test_probe_does_not_depend_on_readable_remote_temporary_files(self):
        with patch.object(verify_network.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as execute:
            self.assertFalse(verify_network.probe("mosquitto", "10.20.0.1", 443))
        self.assertIn("-c", execute.call_args.args[0])


class HoldTests(unittest.TestCase):
    def test_no_ssh_or_staging_api_calls_without_explicit_approval(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(subprocess, "run") as execute, \
                patch.object(subprocess, "check_output") as output, patch.object(validate_staging.urllib.request, "build_opener") as api:
            with self.assertRaises(ValueError): deploy_ci.main()
            with self.assertRaises(ValueError): validate_staging.main()
            execute.assert_not_called(); output.assert_not_called(); api.assert_not_called()

    def test_installer_refuses_before_mutations_without_approval(self):
        argv = ["install.py", "--release", "/nonexistent", "--sha", "a" * 40, "--settings", "/nonexistent", "--tls-bundle", "/nonexistent"]
        with patch.object(sys, "argv", argv), patch.object(install, "run") as execute:
            with self.assertRaises(ValueError): install.main()
            execute.assert_not_called()

    def test_settings_reject_secrets_injection_and_missing_fields(self):
        settings = {"pms_ip": "10.20.0.1", "pms_database_ip": "10.20.0.2", "pms_machine_id": "a" * 32,
                    "ssh_port": 22, "service_token": "b" * 43, "store_password": "c" * 32}
        validate_settings(settings)
        for key, value in (("store_password", "a\nINJECT=1"), ("pms_machine_id", "invalid"), ("ssh_port", 443)):
            with self.assertRaises(ValueError): validate_settings({**settings, key: value})
        with self.assertRaises(ValueError): validate_settings({**settings, "unexpected": "value"})


if __name__ == "__main__":
    unittest.main()
