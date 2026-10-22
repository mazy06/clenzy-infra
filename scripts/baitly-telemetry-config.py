#!/usr/bin/env python3
"""Route Baitly telemetry to the reviewed EU projects for each deployment."""
import hashlib
import os
from pathlib import Path
import re
import tempfile

# Public destination fingerprints, not authentication secrets. Rotation requires review.
DESTINATIONS = {
    'app.clenzy.fr': ('staging',
                      '904a9fb427c6fbf1e1aca7ae000b6ab05b8b52cfcf84353f584e43ddc54d88ec',
                      '4512297102999632', '4512297107914832'),
    'app.baitly.fr': ('production',
                      'd66d815ef141fef78ca393648aba8bfdef7dc6c87d5fbd087733e1cee3f99010',
                      '4512297279881296', '4512297283747920'),
}
SENTRY_ORIGIN = 'o4512297046048768.ingest.de.sentry.io'


def configure(env, path=Path('.env')):
    domain = env.get('DEPLOY_EXPECTED_DOMAIN', '')
    if domain not in DESTINATIONS or env.get('APP_DOMAIN') != domain:
        raise ValueError('Telemetry target mismatch')
    environment, fingerprint, web_id, api_id = DESTINATIONS[domain]
    key = env.get('DEPLOY_POSTHOG_KEY', '')
    web = env.get('DEPLOY_SENTRY_WEB_DSN', '')
    api = env.get('DEPLOY_SENTRY_API_DSN', '')
    if not re.fullmatch(r'phc_[A-Za-z0-9_]{20,128}', key):
        raise ValueError('Missing or invalid PostHog public project key')
    if hashlib.sha256(key.encode()).hexdigest() != fingerprint:
        raise ValueError('PostHog project does not match deployment target')
    for dsn, project_id in ((web, web_id), (api, api_id)):
        pattern = r'https://[a-f0-9]+@' + re.escape(SENTRY_ORIGIN) + '/' + project_id
        if not re.fullmatch(pattern, dsn):
            raise ValueError('Sentry project does not match deployment target')
    if path.is_symlink() or not path.is_file():
        raise ValueError('Regular deployment environment file required')
    original = path.read_text()
    # Verify the file as well as the sourced environment before atomically replacing it.
    if re.findall(r'^APP_DOMAIN=(.*)$', original, re.MULTILINE) != [domain]:
        raise ValueError('Deployment environment file target mismatch')
    values = {
        'VITE_ENV': environment, 'VITE_POSTHOG_KEY': key,
        'VITE_POSTHOG_HOST': 'https://eu.i.posthog.com',
        'VITE_SENTRY_DSN': web, 'SENTRY_DSN': api, 'SENTRY_ENVIRONMENT': environment,
    }
    lines = [line for line in original.splitlines() if line.split('=', 1)[0] not in values]
    content = '\n'.join(lines) + '\n' + ''.join(f'{name}={value}\n' for name, value in values.items())
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.env.telemetry.', delete=False) as file:
            temporary = Path(file.name)
            os.chmod(temporary, 0o600)
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f'Baitly {environment} telemetry configured (reviewed EU projects; values not logged)')


if __name__ == '__main__':
    try:
        configure(os.environ)
    except (ValueError, OSError):
        # Never include environment values or file contents in CI output.
        raise SystemExit('Baitly telemetry configuration rejected; verify target and dedicated public destinations')
