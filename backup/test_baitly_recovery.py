import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import baitly_archive as archives
from baitly_restore_rehearsal import rehearse, sandbox, Sandbox


class ArchiveTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.files = self.root / "snapshot"
        self.files.mkdir()
        (self.files / "postgres_fixture.dump").write_bytes(b"PGDMP-fixture")
        (self.files / "keycloak_db_fixture.dump").write_bytes(b"PGDMP-auth-fixture")

    def bundle(self):
        archives.create(self.files, "staging", "2026-10-22T00:00:00Z")
        target = self.root / "fixture.tar.gz"
        with tarfile.open(target, "w:gz") as out:
            out.add(self.files, arcname="20261022_000000")
        return target

    def test_integrity_and_coverage_do_not_claim_full_recovery(self):
        manifest = archives.verify(self.bundle())
        self.assertTrue(manifest["coverage"]["authentication_database"])
        self.assertFalse(manifest["coverage"]["offsite"])
        self.assertFalse(manifest["coverage"]["documents"])

    def test_corruption_is_rejected_before_extraction(self):
        archive = self.bundle()
        (self.files / "postgres_fixture.dump").write_bytes(b"changed")
        with tarfile.open(archive, "w:gz") as out:
            out.add(self.files, arcname="20261022_000000")
        with self.assertRaises(ValueError):
            archives.verify(archive)

    def test_auth_database_is_required(self):
        (self.files / "keycloak_db_fixture.dump").unlink()
        with self.assertRaises(ValueError):
            self.bundle()

    def test_traversal_links_and_duplicate_paths_are_refused(self):
        for name, kind in (("../escape", tarfile.REGTYPE), ("root/link", tarfile.SYMTYPE), ("root/link", tarfile.LNKTYPE)):
            with self.subTest(kind=kind):
                target = self.root / "bad.tar.gz"
                with tarfile.open(target, "w:gz") as out:
                    item = tarfile.TarInfo(name)
                    item.type = kind
                    item.linkname = "/tmp/PRIVATE"
                    out.addfile(item)
                with self.assertRaises(ValueError):
                    archives.verify(target)
        target = self.root / "duplicate.tar.gz"
        with tarfile.open(target, "w:gz") as out:
            out.addfile(tarfile.TarInfo("root/same"))
            out.addfile(tarfile.TarInfo("root/same"))
        with self.assertRaises(ValueError):
            archives.verify(target)

    def test_declared_archive_size_is_bounded(self):
        with self.assertRaises(ValueError):
            archives.verify(self.bundle(), max_bytes=2)

    def test_retention_preserves_monthly_weekly_and_unrelated_files(self):
        today = dt.date(2026, 10, 22)
        names = ["clenzy_backup_prod_20261001_010000.tar.gz",
                 "clenzy_backup_prod_20261004_010000.tar.gz",
                 "clenzy_backup_prod_20261005_010000.tar.gz",
                 "clenzy_backup_prod_20260401_010000.tar.gz",
                 "clenzy_backup_prod_20261021_010000.tar.gz",
                 "clenzy_backup_staging_20260401_010000.tar.gz", "unrelated.txt"]
        for name in names:
            (self.root / name).touch()
        self.assertEqual(archives.retention(self.root, "prod", today), 2)
        self.assertTrue(all((self.root / name).exists() for name in names))
        self.assertEqual(archives.retention(self.root, "prod", today, apply=True), 2)
        for name in (names[0], names[1], names[4], names[5], names[6]):
            self.assertTrue((self.root / name).exists())

    def test_legacy_live_restore_is_refused_without_touching_docker(self):
        result = subprocess.run(["bash", str(pathlib.Path(__file__).with_name("restore.sh")),
                                 "--archive", "PRIVATE", "--env", "prod", "--yes"], capture_output=True)
        self.assertEqual(result.returncode, 64)
        self.assertNotIn(b"PRIVATE", result.stdout + result.stderr)


class RealDatabaseTest(unittest.TestCase):
    def test_database_and_both_realms_restore_into_owned_cluster(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = pathlib.Path(temp) / "snapshot"
            directory.mkdir()
            with patch.dict(os.environ, {"PGHOST": "production.invalid", "PGDATABASE": "production", "PGOPTIONS": "PRIVATE"}):
                with sandbox(120) as source:
                    source.run("createdb", "baitly_application")
                    source.run("createdb", "baitly_authentication")
                    source.sql("baitly_application", "CREATE TABLE baitly_probe(id int PRIMARY KEY); INSERT INTO baitly_probe VALUES (1),(2)")
                    source.sql("baitly_authentication", "CREATE TABLE realm(name text); INSERT INTO realm VALUES ('clenzy'),('clenzy-guests')")
                    if os.environ.get("BAITLY_EXPECT_VECTOR") == "1":
                        source.sql("baitly_application", "CREATE EXTENSION vector; CREATE TABLE baitly_embeddings(value vector(3)); INSERT INTO baitly_embeddings VALUES ('[1,2,3]')")
                    for name, database in (("postgres_fixture.dump", "baitly_application"), ("keycloak_db_fixture.dump", "baitly_authentication")):
                        (directory / name).write_bytes(source.run("pg_dump", "--format=custom", "--no-password", "-d", database))
                archives.create(directory, "staging", "2026-10-22T00:00:00Z")
                archive = pathlib.Path(temp) / "fixture.tar.gz"
                with tarfile.open(archive, "w:gz") as out:
                    out.add(directory, arcname="20261022_000000")
                restore = Sandbox.restore
                def verify_rows(cluster, database, dump):
                    count = restore(cluster, database, dump)
                    if database == "baitly_application":
                        self.assertEqual(cluster.sql(database, "SELECT count(*) FROM baitly_probe"), "2")
                        if os.environ.get("BAITLY_EXPECT_VECTOR") == "1":
                            self.assertEqual(cluster.sql(database, "SELECT count(*) FROM baitly_embeddings"), "1")
                    return count
                with patch.object(Sandbox, "restore", verify_rows):
                    report = rehearse(archive, 120)
            self.assertEqual(report["authentication_realms"], 2)
            self.assertEqual(report["restored_tables"], dict(application=2 if os.environ.get("BAITLY_EXPECT_VECTOR") == "1" else 1, authentication=1))
            self.assertFalse(report["live_target_used"])
            self.assertFalse(report["full_rto_proven"])


class BackupCommandTest(unittest.TestCase):
    def fixture(self, failure=""):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = pathlib.Path(temp.name)
        backup = root / "infra" / "backup"
        backup.mkdir(parents=True)
        for name in ("backup.sh", "baitly_archive.py"):
            (backup / name).write_bytes(pathlib.Path(__file__).with_name(name).read_bytes())
        (backup.parent / ".env").write_text("POSTGRES_DB=app_fixture\nPOSTGRES_USER=fixture\nKEYCLOAK_DB_NAME=auth_fixture\n")
        binary = root / "bin"
        binary.mkdir()
        docker = binary / "docker"
        docker.write_text("""#!/usr/bin/env python3
import json, os, sys
a=sys.argv[1:]
with open(os.environ['FIXTURE_LOG'],'a') as log: log.write(json.dumps(a)+'\\n')
if a[0]=='ps': print('clenzy-postgres-prod'); sys.exit(0)
if 'pg_dump' in a:
    database=a[a.index('-d')+1]
    if os.environ.get('FIXTURE_FAILURE')==database:
        print('PRIVATE FIXTURE SECRET',file=sys.stderr); sys.exit(1)
    sys.stdout.buffer.write(b'PGDMP-synthetic-dump'); sys.exit(0)
if 'pg_restore' in a:
    sys.exit(0 if sys.stdin.buffer.read().startswith(b'PGDMP') else 1)
sys.exit(99)
""")
        docker.chmod(0o700)
        env = dict(os.environ, PATH=str(binary)+os.pathsep+os.environ["PATH"],
                   FIXTURE_LOG=str(root / "calls.jsonl"), FIXTURE_FAILURE=failure)
        output = root / "output"
        result = subprocess.run(["bash", str(backup / "backup.sh"), "--env", "prod", "--db-only", "--backup-dir", str(output)],
                                env=env, capture_output=True)
        return root, output, result

    def test_failed_auth_dump_never_publishes_successful_archive(self):
        root, output, result = self.fixture("auth_fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(output.rglob("*.tar.gz")), [])
        self.assertNotIn(b"PRIVATE FIXTURE SECRET", result.stdout + result.stderr)

    def test_both_dumps_and_private_verified_archive_are_required(self):
        root, output, result = self.fixture()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        files = list(output.rglob("*.tar.gz"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        manifest = archives.verify(files[0])
        self.assertEqual({x["role"] for x in manifest["files"]}, {"application", "authentication", "auxiliary"})
        calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
        self.assertTrue(any("auth_fixture" in call for call in calls))
        self.assertFalse(any("kcadm" in " ".join(call) or "restart" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
