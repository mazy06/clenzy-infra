import contextlib
import copy
import hashlib
import io
import json
import os
import unittest
from unittest.mock import patch

from baitly_admin_role import DOMAIN, ROLE, Production, RepairError, repair


SUBJECT = "3a4134bd-cc3f-4de0-8c66-7b019a107319"
OTHER = "b13f34b8-e32f-4ac3-a9a5-2d905f47e3cc"
EMAIL = "admin@example.test"


class FakeProduction:
    def __init__(self):
        self.accounts = [{"id": SUBJECT, "username": "admin", "enabled": True,
                          "email": EMAIL, "emailVerified": True}]
        self.users = [{"id": 17, "role": "HOST", "status": "ACTIVE",
                       "emailHash": hashlib.sha256(EMAIL.encode()).hexdigest()}]
        self.roles = {"HOST"}
        self.available = [{"id": OTHER, "name": ROLE, "clientRole": False}]
        self.conflicts = 0
        self.writes = []

    def keycloak(self, args, body=None):
        if args[:2] == ["get", "users"]:
            return copy.deepcopy(self.accounts)
        if args[:2] == ["get", "roles"]:
            return self.available
        if args[0] == "get" and args[1].endswith("/composite"):
            return [{"name": role} for role in self.roles]
        if args[0] == "create":
            self.writes.append(("keycloak", args[1], body))
            self.roles.add(ROLE)
            return None
        raise AssertionError(args)

    def profile(self, subject, email_hash):
        assert subject == SUBJECT
        return {"users": copy.deepcopy(self.users), "emailConflicts": self.conflicts}

    def promote_profile(self, subject, profile):
        self.writes.append(("pms", subject, profile["id"]))
        self.users[0]["role"] = ROLE

    def clear_user_cache(self, subject):
        self.writes.append(("cache", subject))


class AdminRoleTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {"APP_DOMAIN": DOMAIN})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.ops = FakeProduction()
        self.output = io.StringIO()

    def execute(self, apply=True, subject=SUBJECT, previous="HOST"):
        with contextlib.redirect_stdout(self.output):
            return repair(self.ops, apply, subject, previous)

    def assert_blocked(self, message, **kwargs):
        with self.assertRaisesRegex(RepairError, message):
            self.execute(**kwargs)
        self.assertEqual([], self.ops.writes)

    def test_diagnosis_has_no_writes_or_email_output(self):
        report = self.execute(apply=False)
        self.assertEqual("HOST", report["pmsRole"])
        self.assertEqual(SUBJECT, report["keycloakId"])
        self.assertEqual([], self.ops.writes)
        self.assertNotIn(EMAIL, self.output.getvalue())
        self.assertNotIn(self.ops.users[0]["emailHash"], self.output.getvalue())

    def test_other_production_instance_is_rejected(self):
        os.environ["APP_DOMAIN"] = "app.clenzy.fr"
        self.assert_blocked("APP_DOMAIN")

    def test_missing_or_mismatched_expected_subject_is_rejected(self):
        for subject in ("", OTHER):
            with self.subTest(subject=subject):
                self.assert_blocked("exact Keycloak ID", subject=subject)

    def test_recreated_account_is_not_promoted(self):
        self.ops.accounts[0]["id"] = OTHER
        self.ops.profile = lambda *args: {"users": [], "emailConflicts": 0}
        self.assert_blocked("exact Keycloak ID")

    def test_missing_or_changed_expected_role_is_rejected(self):
        for previous in ("", "TECHNICIAN"):
            with self.subTest(previous=previous):
                self.assert_blocked("role differs", previous=previous)

    def test_non_exact_or_ambiguous_username_is_rejected(self):
        self.ops.accounts[0]["username"] = "admin-other"
        self.assert_blocked("exactly one account")
        self.ops.accounts *= 2
        self.assert_blocked("exactly one account")

    def test_disabled_account_is_not_reenabled(self):
        self.ops.accounts[0]["enabled"] = False
        self.assert_blocked("Disabled account")

    def test_inactive_profile_is_not_reactivated(self):
        self.ops.users[0]["status"] = "INACTIVE"
        self.assert_blocked("not active")

    def test_conflicting_identity_is_not_linked_or_promoted(self):
        self.ops.conflicts = 1
        self.assert_blocked("conflicting identity")
        self.ops.conflicts = 0
        self.ops.users[0]["emailHash"] = "different"
        self.assert_blocked("conflicting identity")

    def test_missing_realm_role_is_not_created(self):
        self.ops.available = []
        self.assert_blocked("realm role is missing")

    def test_existing_profile_and_realm_role_are_promoted_together(self):
        result = self.execute()
        self.assertEqual(ROLE, result["pmsRole"])
        self.assertTrue(result["keycloakSuperAdmin"])
        self.assertEqual(["keycloak", "pms", "cache"], [w[0] for w in self.ops.writes])
        self.assertEqual(("pms", SUBJECT, 17), self.ops.writes[1])
        self.assertEqual(("cache", SUBJECT), self.ops.writes[2])
        self.assertIn("HOST", self.ops.roles)  # no unrelated realm role is removed

    def test_repeat_application_only_invalidates_target_cache(self):
        self.ops.roles.add(ROLE)
        self.ops.users[0]["role"] = ROLE
        self.execute()
        self.assertEqual([("cache", SUBJECT)], self.ops.writes)

    def test_missing_profile_needs_verified_email(self):
        self.ops.users = []
        self.ops.roles = set()
        self.ops.accounts[0]["emailVerified"] = False
        self.assert_blocked("verified Keycloak email", previous="ABSENT")
        self.ops.accounts[0]["emailVerified"] = True
        self.ops.accounts[0]["email"] = None
        self.assert_blocked("verified Keycloak email", previous="ABSENT")

    def test_missing_profile_with_competing_role_is_rejected(self):
        self.ops.users = []
        self.assert_blocked("competing business roles", previous="ABSENT")

    def test_missing_profile_is_left_to_verified_application_provisioning(self):
        self.ops.users = []
        self.ops.roles = {"offline_access"}
        result = self.execute(previous="ABSENT")
        self.assertTrue(result["keycloakSuperAdmin"])
        self.assertEqual("ABSENT", result["pmsRole"])
        self.assertEqual(["keycloak", "cache"], [w[0] for w in self.ops.writes])

    def test_concurrent_database_change_is_reported(self):
        with patch.object(Production, "sql", return_value=[]):
            with self.assertRaisesRegex(RepairError, "concurrently"):
                Production().promote_profile(SUBJECT, self.ops.users[0])

    def test_sql_values_are_bound_and_update_is_conditional(self):
        with patch.object(Production, "sql", return_value=[17]) as query:
            Production().promote_profile(SUBJECT, self.ops.users[0])
        sql = query.call_args.args[0]
        self.assertIn("keycloak_id = :'subject'", sql)
        self.assertIn("role = :'previous_role'", sql)
        self.assertNotIn(SUBJECT, sql)
        self.assertEqual(SUBJECT, query.call_args.kwargs["subject"])

    def test_redis_errors_are_not_reported_as_success(self):
        with patch("baitly_admin_role.run", return_value="NOAUTH Authentication required"):
            with self.assertRaisesRegex(RepairError, "cache invalidation failed"):
                Production().clear_user_cache(SUBJECT)


if __name__ == "__main__":
    unittest.main()
