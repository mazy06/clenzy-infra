import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('cloudflare', Path(__file__).resolve().parents[1] / 'scripts/baitly-cloudflare.py')
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)


class CloudflareSecurity(unittest.TestCase):
    def test_free_plan_uses_supported_fields_and_periods(self):
        rules = cf.desired_rules('baitly.fr')
        self.assertNotIn(' matches ', str(rules))
        rate = rules['http_ratelimit']
        self.assertNotIn('http.host', rate['expression'])
        self.assertEqual(rate['ratelimit']['period'], 10)
        self.assertEqual(rate['ratelimit']['mitigation_timeout'], 10)

    def test_full_free_quota_never_deletes_or_replaces_existing_rules(self):
        api = Mock()
        api.call.side_effect = [{'name': 'baitly.fr'}, {'id': 'set', 'rules': [{'ref': str(i)} for i in range(5)]}]
        with self.assertRaisesRegex(ValueError, 'quota'):
            cf.prepare(api, 'zone', 'baitly.fr', cf.desired_rules('baitly.fr'))
        self.assertTrue(all(call.args[0] == 'GET' for call in api.call.call_args_list))

    def test_wrong_zone_refuses_all_mutations(self):
        api = Mock()
        api.call.return_value = {'name': 'another.example'}
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            cf.prepare(api, 'zone', 'baitly.fr', cf.desired_rules('baitly.fr'))
        api.call.assert_called_once()

    def test_reconcile_modifies_only_owned_rules_and_is_idempotent(self):
        desired = cf.desired_rules('baitly.fr')
        snapshots = {phase: {'id': phase, 'rules': [{'id': 'other', 'ref': 'unrelated'}, {**rule, 'id': 'owned'}]}
                     for phase, rule in desired.items()}
        snapshots['http_ratelimit']['rules'][1]['ratelimit'] = {
            **desired['http_ratelimit']['ratelimit'], 'requests_to_origin': False,
        }
        api = Mock()
        cf.reconcile(api, 'zone', desired, snapshots)
        api.call.assert_not_called()
        snapshots['http_ratelimit']['rules'][1]['enabled'] = False
        cf.reconcile(api, 'zone', desired, snapshots)
        self.assertEqual(api.call.call_count, 1)
        self.assertEqual(api.call.call_args.args[0], 'PATCH')
        self.assertTrue(api.call.call_args.args[1].endswith('/rules/owned'))

    def test_disable_touches_only_owned_rules(self):
        desired = cf.desired_rules('baitly.fr')
        snapshots = {phase: {'id': phase, 'rules': [{'id': 'other', 'ref': 'unrelated'}, {**rule, 'id': 'owned'}]}
                     for phase, rule in desired.items()}
        api = Mock()
        cf.reconcile(api, 'zone', desired, snapshots, disable=True)
        self.assertEqual(api.call.call_count, 2)
        for call in api.call.call_args_list:
            self.assertTrue(call.args[1].endswith('/rules/owned'))
            self.assertEqual(call.args[2], {'enabled': False})


if __name__ == '__main__':
    unittest.main()
