#!/usr/bin/env python3
"""Cloudflare Free rules: offline plan, read-only check, or CI-only apply/disable.

Only the two named Baitly rules are managed. Unrelated rules are never replaced.
"""
import argparse
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request

PHASES = {'http_request_firewall_custom': 5, 'http_ratelimit': 1}


def matches(actual, expected):
    """Cloudflare adds default fields to nested objects when reading a rule back."""
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(matches(actual.get(key), value) for key, value in expected.items())
    return actual == expected


def desired_rules(zone):
    if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+', zone):
        raise ValueError('Invalid zone name')
    path = 'lower(http.request.uri.path)'
    probes = [f'{path} contains "{value}"' for value in ('/.env', '/.git', '/.svn', '/.hg')]
    probes += [f'ends_with({path}, "{value}")' for value in ('.sql', '.bak', '.swp', '.swo')]
    hosts = ' '.join(json.dumps(prefix + zone) for prefix in ('', 'www.', 'app.', 'auth.', 'monitoring.', 'prometheus.', 'kafka.'))
    return {
        'http_request_firewall_custom': {
            'ref': 'baitly_sensitive_files_v1', 'description': 'Baitly: block secret and backup probes',
            'action': 'block', 'enabled': True,
            'expression': f'(http.host in {{{hosts}}} and (' + ' or '.join(probes) + '))',
        },
        # Free supports Path, not Host/Method; scope to this exact login path.
        'http_ratelimit': {
            'ref': 'baitly_login_rate_v1', 'description': 'Baitly: login burst limit',
            'action': 'block', 'enabled': True,
            'expression': '(http.request.uri.path eq "/api/auth/login")',
            'ratelimit': {'characteristics': ['cf.colo.id', 'ip.src'], 'period': 10,
                          'requests_per_period': 10, 'mitigation_timeout': 10},
        },
    }


class Api:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, data=None):
        request = urllib.request.Request('https://api.cloudflare.com/client/v4' + path,
                                         data=json.dumps(data).encode() if data is not None else None,
                                         method=method, headers={'Authorization': 'Bearer ' + self.token,
                                                                'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404 and method == 'GET' and '/phases/' in path:
                return None
            # No request body, bearer token or Cloudflare response is printed.
            raise RuntimeError(f'Cloudflare {method} failed (HTTP {error.code})') from None
        if not payload.get('success'):
            raise RuntimeError('Cloudflare rejected the request')
        return payload['result']


def prepare(api, zone_id, zone, desired):
    if api.call('GET', f'/zones/{zone_id}')['name'] != zone:
        raise ValueError('Zone ID/name mismatch; no changes made')
    snapshots = {}
    # Check every quota before the first write. Never evict an existing rule.
    for phase, rule in desired.items():
        state = api.call('GET', f'/zones/{zone_id}/rulesets/phases/{phase}/entrypoint')
        rules = (state or {}).get('rules', [])
        matches = [r for r in rules if r.get('ref') == rule['ref']]
        if len(matches) > 1:
            raise ValueError('Duplicate Baitly rule reference; review required')
        if not matches and len(rules) >= PHASES[phase]:
            raise ValueError(f'Free quota already used for {phase}; preserve existing rules and review allocation')
        snapshots[phase] = state
    return snapshots


def reconcile(api, zone_id, desired, snapshots, disable=False):
    for phase, rule in desired.items():
        state = snapshots[phase]
        current = next((r for r in (state or {}).get('rules', []) if r.get('ref') == rule['ref']), None)
        if disable:
            if current:
                api.call('PATCH', f'/zones/{zone_id}/rulesets/{state["id"]}/rules/{current["id"]}', {'enabled': False})
            continue
        if current and matches(current, rule):
            continue
        if state is None:
            api.call('POST', f'/zones/{zone_id}/rulesets', {
                'name': 'Baitly ' + phase, 'kind': 'zone', 'phase': phase, 'rules': [rule]})
        elif current:
            api.call('PATCH', f'/zones/{zone_id}/rulesets/{state["id"]}/rules/{current["id"]}', rule)
        else:
            # First position prevents an earlier Skip rule bypassing the new block.
            api.call('POST', f'/zones/{zone_id}/rulesets/{state["id"]}/rules', {**rule, 'position': {'index': 1}})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zone', default='baitly.fr')
    parser.add_argument('--mode', choices=('plan', 'check', 'apply', 'disable'), default='plan')
    args = parser.parse_args()
    desired = desired_rules(args.zone)
    if args.mode == 'plan':
        print(json.dumps(desired, indent=2))
        return
    if args.mode in ('apply', 'disable') and (os.getenv('GITHUB_ACTIONS') != 'true'
                                              or os.getenv('GITHUB_REF') != 'refs/heads/production'):
        raise ValueError('Production mutations must run from the production CI workflow')
    token, zone_id = os.getenv('CLOUDFLARE_API_TOKEN'), os.getenv('CLOUDFLARE_ZONE_ID')
    if not token or not zone_id or not re.fullmatch('[a-f0-9]{32}', zone_id):
        raise ValueError('Set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID in the GitHub environment')
    api = Api(token)
    # Disable must work even if unrelated rules now fill the quota.
    if args.mode == 'disable':
        if api.call('GET', f'/zones/{zone_id}')['name'] != args.zone:
            raise ValueError('Zone ID/name mismatch')
        snapshots = {phase: api.call('GET', f'/zones/{zone_id}/rulesets/phases/{phase}/entrypoint') for phase in desired}
    else:
        snapshots = prepare(api, zone_id, args.zone, desired)
    Path('baitly-cloudflare-before.json').write_text(json.dumps(snapshots, indent=2))
    if args.mode != 'check':
        reconcile(api, zone_id, desired, snapshots, disable=args.mode == 'disable')
        # Re-read actual state: a successful write alone is not a verified deployment.
        for phase, expected in desired.items():
            actual = api.call('GET', f'/zones/{zone_id}/rulesets/phases/{phase}/entrypoint')
            owned = next((r for r in (actual or {}).get('rules', []) if r.get('ref') == expected['ref']), None)
            if args.mode == 'apply' and not matches(owned, expected):
                raise RuntimeError('Cloudflare rule verification failed; inspect the saved snapshot')
            if args.mode == 'disable' and owned and owned.get('enabled'):
                raise RuntimeError('Cloudflare rule still enabled')
    print('Cloudflare ' + args.mode + ' completed; unrelated rules preserved.')


if __name__ == '__main__':
    main()
