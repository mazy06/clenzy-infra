import unittest
from baitly_fixture_identity_audit import audit


class IdentityAuditTest(unittest.TestCase):
    def test_only_recognized_fixture_is_read(self):
        class Ops:
            def keycloak(self, args):
                if args[1] == 'clients':
                    return [{'id': '00000000-0000-0000-0000-000000000001', 'clientId': 'baitly-perf-10-01',
                             'attributes': {'baitly_fixture': 'baitly-planning-performance-v1'}}]
                return {'id': '00000000-0000-0000-0000-000000000002'}
            def sql(self, query, **variables):
                assert query.startswith('BEGIN READ ONLY;')
                assert variables['name'] == 'baitly-perf-10-01'
                assert len(variables['emailHash']) == 64
                return {'matchingSubjectProfiles': 1}
        self.assertEqual(audit(Ops()), {'matchingSubjectProfiles': 1})

    def test_unrecognized_client_refuses_sql(self):
        class Ops:
            def keycloak(self, args):
                return [{'clientId': 'baitly-perf-10-01'}]
            def sql(self, *args, **kwargs):
                raise AssertionError('No SQL allowed')
        with self.assertRaises(RuntimeError):
            audit(Ops())
