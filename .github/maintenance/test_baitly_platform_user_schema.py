import base64
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import baitly_platform_user_schema as repair


ENV = {"APP_DOMAIN": "app.baitly.fr", "POSTGRES_DB": "baitly_prod",
       "POSTGRES_USER": "test_user", "POSTGRES_PASSWORD": "test_secret",
       "BAITLY_APP_GIT_TOKEN": "test_token"}


class PlatformUserSchemaTest(unittest.TestCase):
    def test_other_instance_is_rejected_before_any_command(self):
        for domain in ("app.clenzy.fr", "", "app.baitly.fr.attacker.example"):
            with self.subTest(domain=domain), patch.object(repair, "run") as run:
                with self.assertRaises(ValueError):
                    repair.execute(Path("/tmp/infra"), {**ENV, "APP_DOMAIN": domain}, True)
                run.assert_not_called()

    def test_database_url_cannot_be_overridden(self):
        with self.assertRaises(ValueError):
            repair.validate_environment({**ENV, "POSTGRES_DB": "baitly?host=elsewhere"})

    def test_source_is_merged_immutable_commit_and_files_are_verified(self):
        body = "reviewed migration\n"
        responses = [{"status": "ahead"}, {"encoding": "base64", "content": base64.b64encode(body.encode()).decode()}]
        with tempfile.TemporaryDirectory() as directory, patch.object(repair, "github_json", side_effect=responses) as get, \
                patch.object(repair, "FILE_HASHES", {repair.SQL_FILE: hashlib.sha256(body.encode()).hexdigest()}):
            repair.export_migration(Path(directory), "test_token")
            get.assert_any_call(f"compare/{repair.APP_COMMIT}...main", "test_token")
            get.assert_any_call(f"contents/server/src/main/resources/{repair.SQL_FILE}?ref={repair.APP_COMMIT}", "test_token")
            self.assertEqual((Path(directory) / repair.SQL_FILE).read_text(), body)

    def test_digest_mismatch_stops_export(self):
        responses = [{"status": "ahead"}, {"encoding": "base64", "content": base64.b64encode(b"changed SQL").decode()}]
        with tempfile.TemporaryDirectory() as directory, patch.object(repair, "github_json", side_effect=responses):
            with self.assertRaises(ValueError):
                repair.export_migration(Path(directory), "test_token")

    def test_unmerged_application_commit_is_rejected(self):
        for status in ("behind", "diverged", None):
            with self.subTest(status=status), patch.object(repair, "github_json", return_value={"status": status}) as get:
                with self.assertRaises(ValueError):
                    repair.export_migration(Path("/tmp"), "test_token")
                self.assertEqual(get.call_count, 1)

    def test_dry_run_does_not_update(self):
        with patch.object(repair, "export_migration"), patch.object(repair, "liquibase") as lb, \
                patch.object(repair, "verify_applied") as verify:
            repair.execute(Path("/tmp/infra"), ENV)
            self.assertEqual([call.args[-1] for call in lb.call_args_list], ["validate", "status"])
            verify.assert_not_called()

    def test_apply_validates_then_updates_and_verifies(self):
        with patch.object(repair, "export_migration"), patch.object(repair, "liquibase") as lb, \
                patch.object(repair, "verify_applied") as verify:
            repair.execute(Path("/tmp/infra"), ENV, True)
            self.assertEqual([call.args[-1] for call in lb.call_args_list], ["validate", "status", "update"])
            verify.assert_called_once_with(Path("/tmp/infra"), ENV)

    def test_credentials_are_not_in_command_arguments(self):
        with patch.object(repair, "run", return_value="") as run:
            repair.liquibase(Path("/tmp/resources"), ENV, "update")
            args = run.call_args.args
            self.assertNotIn(ENV["POSTGRES_PASSWORD"], " ".join(args))
            self.assertNotIn(ENV["POSTGRES_USER"], " ".join(args))
            self.assertIn(f"--changelog-file={repair.CHANGELOG}", args)
            self.assertEqual(run.call_args.kwargs["env"]["LIQUIBASE_COMMAND_PASSWORD"], ENV["POSTGRES_PASSWORD"])

    def test_no_sync_or_arbitrary_liquibase_command(self):
        with patch.object(repair, "run") as run:
            with self.assertRaises(ValueError):
                repair.liquibase(Path("/tmp"), ENV, "changelog-sync")
            run.assert_not_called()

    def test_postcondition_requires_nullable_and_canonical_execution(self):
        for result in ("NO|1", "YES|0", "YES|2", ""):
            with self.subTest(result=result), patch.object(repair, "run", return_value=result):
                with self.assertRaises(RuntimeError):
                    repair.verify_applied(Path("/tmp"), ENV)
        with patch.object(repair, "run", return_value="YES|1\n"):
            repair.verify_applied(Path("/tmp"), ENV)


if __name__ == "__main__":
    unittest.main()
