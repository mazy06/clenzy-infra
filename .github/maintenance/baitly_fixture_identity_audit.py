"""Vérification en lecture seule d'une identité synthétique, sans identifiant publié."""
import hashlib
import importlib.util
import json
from pathlib import Path
import uuid


def audit(ops):
    name = 'baitly-perf-10-01'
    clients = ops.keycloak(['get', 'clients', '-r', 'clenzy', '-q', f'clientId={name}'])
    if len(clients) != 1 or clients[0].get('clientId') != name or clients[0].get('attributes', {}).get('baitly_fixture') != 'baitly-planning-performance-v1':
        raise RuntimeError('Client synthétique non reconnu ; aucune identité publiée')
    client = str(uuid.UUID(clients[0]['id']))
    user = ops.keycloak(['get', f'clients/{client}/service-account-user', '-r', 'clenzy'])
    subject = str(uuid.UUID(user['id']))
    return ops.sql("""BEGIN READ ONLY;
SELECT json_build_object(
 'matchingSubjectProfiles',(SELECT count(*) FROM users WHERE keycloak_id=:'subject'),
 'matchingSyntheticEmailProfiles',(SELECT count(*) FROM users WHERE email_hash=:'emailHash'),
 'matchingSubjectInFixtureOrg',(SELECT count(*) FROM users u JOIN organizations o ON o.id=u.organization_id
   WHERE o.slug=:'name' AND o.name=:'name' AND u.keycloak_id=:'subject'),
 'fixtureOrgProfiles',(SELECT count(*) FROM users u JOIN organizations o ON o.id=u.organization_id
   WHERE o.slug=:'name' AND o.name=:'name'),
 'matchingProfileEmailInFixtureOrg',(SELECT count(*) FROM users u JOIN organizations o ON o.id=u.organization_id
   WHERE o.slug=:'name' AND o.name=:'name' AND u.email_hash=:'emailHash'));
COMMIT;
""", subject=subject, name=name, emailHash=hashlib.sha256(f'{name}@example.invalid'.encode()).hexdigest())


if __name__ == '__main__':
    spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('baitly-staging-fixtures.py'))
    fixtures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixtures)
    fixtures.require_staging()
    print(json.dumps(audit(fixtures.Staging()), sort_keys=True))
