"""Le diagnostic ne doit publier ni messages, ni identité, ni secrets."""
import unittest
from baitly_staging_error_classes import summarize


class ErrorClassesTest(unittest.TestCase):
    def test_only_structural_fields_leave_the_parser(self):
        raw = """ERROR email=private@example.com token=secret-value
java.lang.IllegalStateException: user private@example.com password=secret-value
Caused by: org.postgresql.util.PSQLException: sensitive query
SQLState: 23505
 at com.clenzy.service.UserService.findByKeycloakId(UserService.java:123)
 at unrelated.Private.method(Private.java:456)
"""
        result = summarize(raw)
        self.assertEqual(result, {
            "exceptionClasses": ["java.lang.IllegalStateException", "org.postgresql.util.PSQLException"],
            "applicationFrames": ["com.clenzy.service.UserService.findByKeycloakId"],
            "sqlStates": ["23505"], "responseStatuses": [], "knownAuthReasons": []})
        for value in ("private@example.com", "secret-value", "sensitive query", "unrelated"):
            self.assertNotIn(value, str(result))

    def test_duplicates_are_collapsed_and_output_is_bounded(self):
        raw = "\n".join(f"com.clenzy.X{i}Exception" for i in range(100))
        self.assertEqual(len(summarize(raw)["exceptionClasses"]), 30)
        self.assertEqual(summarize("token=secret"), {"exceptionClasses": [], "applicationFrames": [], "sqlStates": [], "responseStatuses": [], "knownAuthReasons": []})

    def test_auth_reason_is_only_a_fixed_category(self):
        raw = 'ResponseStatusException: 409 CONFLICT "Ce compte nécessite une réconciliation d’identité vérifiée" email=private@example.com'
        result = summarize(raw)
        self.assertEqual(result['responseStatuses'], ['409'])
        self.assertEqual(result['knownAuthReasons'], ['identityReconciliationRequired'])
        self.assertNotIn('private@example.com', str(result))
