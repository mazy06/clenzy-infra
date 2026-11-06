"""Baitly : routage CI/CD et sélection d'images sans réseau ni Docker."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class DeploymentTargetsTest(unittest.TestCase):
    def resolve(self, **values):
        workflow = (ROOT / '.github/workflows/cd-deploy.yml').read_text()
        plan = workflow.split('  plan:', 1)[1].split('\n  deploy:', 1)[0]
        code = textwrap.dedent(plan.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            env = {**os.environ, 'GITHUB_OUTPUT': str(output), 'GITHUB_REPOSITORY': 'mazy06/clenzy-infra',
                   'EVENT_NAME': 'push', 'EVENT_ACTION': '', 'INPUT_TARGET': '', 'PAYLOAD_TARGET': '',
                   'SOURCE_REF': '', 'SOURCE_SHA': '', 'SOURCE_REPO': '', **values}
            result = subprocess.run(['bash', '-c', code], env=env, capture_output=True, text=True)
            targets = json.loads(output.read_text().removeprefix('targets=')) if output.exists() else None
            return result.returncode, targets

    def test_infra_push_and_default_manual_target_staging_only(self):
        for event in ['push', 'workflow_dispatch']:
            rc, targets = self.resolve(EVENT_NAME=event)
            self.assertEqual(rc, 0)
            self.assertEqual(len(targets), 1)
            self.assertEqual(targets[0]['domain'], 'app.clenzy.fr')
            self.assertEqual(targets[0]['environment'], 'production')

    def test_application_branches_route_to_their_own_instance(self):
        for target, branch, domain in [('staging', 'main', 'app.clenzy.fr'),
                                      ('production-baitly', 'production', 'app.baitly.fr')]:
            rc, targets = self.resolve(EVENT_NAME='repository_dispatch', EVENT_ACTION='deploy-clenzy-backend',
                                      PAYLOAD_TARGET=target, SOURCE_REF='refs/heads/' + branch,
                                      SOURCE_SHA='a' * 40, SOURCE_REPO='mazy06/clenzy')
            self.assertEqual(rc, 0)
            self.assertEqual(targets[0]['domain'], domain)
            self.assertEqual(targets[0]['app_ref'], branch)

    def test_missing_target_wrong_branch_repo_and_sha_are_rejected(self):
        valid = dict(EVENT_NAME='repository_dispatch', EVENT_ACTION='deploy-clenzy-frontend',
                     PAYLOAD_TARGET='staging', SOURCE_REF='refs/heads/main',
                     SOURCE_SHA='a' * 40, SOURCE_REPO='mazy06/clenzy')
        for key, value in [('PAYLOAD_TARGET', ''), ('SOURCE_REF', 'refs/heads/production'),
                           ('SOURCE_REPO', 'other/clenzy'), ('SOURCE_SHA', 'latest'), ('PAYLOAD_TARGET', 'all')]:
            rc, targets = self.resolve(**{**valid, key: value})
            self.assertNotEqual(rc, 0)
            self.assertIsNone(targets)

    def test_legacy_ops_target_still_points_to_staging(self):
        rc, targets = self.resolve(EVENT_NAME='workflow_dispatch', INPUT_TARGET='production')
        self.assertEqual(rc, 0)
        self.assertEqual(targets[0]['domain'], 'app.clenzy.fr')

    def test_explicit_manual_production_has_one_target(self):
        rc, targets = self.resolve(EVENT_NAME='workflow_dispatch', INPUT_TARGET='production-baitly')
        self.assertEqual(rc, 0)
        self.assertEqual([t['domain'] for t in targets], ['app.baitly.fr'])

    def test_other_dispatch_producers_cannot_implicitly_deploy_production(self):
        rc, _ = self.resolve(EVENT_NAME='repository_dispatch', EVENT_ACTION='deploy-service',
                             PAYLOAD_TARGET='production-baitly')
        self.assertNotEqual(rc, 0)


class DeploymentImagesTest(unittest.TestCase):
    def prepare(self, directory, **values):
        env = {**os.environ, 'APP_DOMAIN': 'app.clenzy.fr', 'DEPLOY_APP_REF': '',
               'DEPLOY_EXPECTED_DOMAIN': '', 'DEPLOY_IMAGE_TAG': '', 'DEPLOY_SERVICES': '', **values}
        return subprocess.run(['bash', '-c', 'source "$1"; baitly_prepare_deployment_images',
                               'test', str(ROOT / 'scripts/baitly-deployment-images.sh')],
                              cwd=directory, env=env, capture_output=True, text=True).returncode

    def test_staging_defaults_to_main_and_production_to_latest(self):
        for domain, tag in [('app.clenzy.fr', 'main'), ('app.baitly.fr', 'latest')]:
            with tempfile.TemporaryDirectory() as directory:
                self.assertEqual(self.prepare(directory, APP_DOMAIN=domain), 0)
                content = (Path(directory) / '.env.baitly-images').read_text()
                self.assertEqual(content.count('=' + tag + '\n'), 3)

    def test_partial_deploy_preserves_other_service_shas(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / '.env.baitly-images'
            self.assertEqual(self.prepare(directory, DEPLOY_IMAGE_TAG='a' * 40, DEPLOY_SERVICES='pms-server'), 0)
            self.assertEqual(self.prepare(directory, DEPLOY_IMAGE_TAG='b' * 40, DEPLOY_SERVICES='pms-client,baitly-site'), 0)
            self.assertIn('PMS_SERVER_IMAGE_TAG=' + 'a' * 40, file.read_text())
            self.assertIn('PMS_CLIENT_IMAGE_TAG=' + 'b' * 40, file.read_text())
            self.assertEqual(self.prepare(directory), 0)
            self.assertIn('PMS_SERVER_IMAGE_TAG=' + 'a' * 40, file.read_text())

    def test_invalid_domain_branch_tag_and_service_do_not_create_state(self):
        for values in [{'APP_DOMAIN': 'other.fr'}, {'DEPLOY_EXPECTED_DOMAIN': 'app.baitly.fr'},
                       {'DEPLOY_APP_REF': 'production'}, {'DEPLOY_IMAGE_TAG': 'latest'},
                       {'DEPLOY_IMAGE_TAG': 'a' * 40},
                       {'DEPLOY_IMAGE_TAG': 'a' * 40, 'DEPLOY_SERVICES': 'postgres'}]:
            with tempfile.TemporaryDirectory() as directory:
                self.assertNotEqual(self.prepare(directory, **values), 0)
                self.assertFalse((Path(directory) / '.env.baitly-images').exists())

    def test_state_file_is_validated_without_executing_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / '.env.baitly-images'
            file.write_text('PMS_CLIENT_IMAGE_TAG=$(touch marker)\n')
            self.assertNotEqual(self.prepare(directory), 0)
            self.assertFalse((Path(directory) / 'marker').exists())

    def test_branch_tags_from_another_environment_are_rejected(self):
        for domain, tag in [('app.clenzy.fr', 'latest'), ('app.baitly.fr', 'main')]:
            with tempfile.TemporaryDirectory() as directory:
                file = Path(directory) / '.env.baitly-images'
                file.write_text('PMS_CLIENT_IMAGE_TAG=' + tag + '\n')
                self.assertNotEqual(self.prepare(directory, APP_DOMAIN=domain), 0)


# The fake records argv privately, including test-only credentials. Only stdout and
# stderr are checked for secret disclosure. Local PostgreSQL checks always pass.
DOCKER_FAKE = r'''
import json, os, pathlib, sys
args = sys.argv[1:]
trace = pathlib.Path(os.environ['DEPLOY_TEST_TRACE'])
with trace.open('a') as output:
    output.write(json.dumps(args) + '\n')
if 'psql' in args and ('pgbouncer' in ' '.join(args) or os.environ.get('PGHOST') == 'pgbouncer'):
    counter = trace.with_suffix('.attempts')
    attempt = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(attempt))
    mode = os.environ['DEPLOY_TEST_SQL']
    if mode == 'transient' and attempt <= 2 or mode in ('network', 'auth'):
        print('connection refused' if mode != 'auth' else 'password authentication failed', file=sys.stderr)
        sys.exit(2)
    print('0' if mode == 'incorrect' else '1')
elif 'psql' in args:
    print('1')
elif 'inspect' in args:
    print(json.dumps([{'NetworkSettings': {'Networks': {'test-api-network': {}}}}]))
elif 'ps' in args:
    if '{{.State}}' in args:
        svc = args[-1]
        marker = trace.with_suffix('.crash-' + svc)
        if svc == os.environ.get('DEPLOY_TEST_CRASH') and not marker.exists():
            marker.touch()
            print('restarting')
        else:
            print('running')
    elif '{{.Health}}' in args:
        print('healthy')
    elif '-q' in args:
        print('test-api-container')
elif 'exec' in args and any('wget' in arg for arg in args):
    print('{"status":"UP"}')
'''


class DeploymentSqlReadinessTest(unittest.TestCase):
    def deploy(self, mode='update', services='', force=False, sql='success', crash=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'infra'
            root.mkdir()
            shutil.copytree(ROOT / 'scripts', root / 'scripts')
            # These unrelated host mutations are replaced, not deployment logic.
            for name in ('baitly-security-preflight.sh', 'baitly-alertmanager-token.sh',
                         'vps-swap-setup.sh'):
                (root / 'scripts' / name).write_text('exit 0\n')
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            docker = bin_dir / 'docker'
            docker.write_text('#!' + sys.executable + '\n' + DOCKER_FAKE)
            docker.chmod(0o755)
            for name in ('sleep', 'curl', 'sudo', 'python3'):
                command = bin_dir / name
                command.write_text('#!/bin/sh\nexit 0\n')
                command.chmod(0o755)
            trace = root / 'trace.jsonl'
            env = {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
                   'HOME': directory, 'APP_DOMAIN': 'app.clenzy.fr',
                   'KAFKA_CLUSTER_ID': 'test-cluster', 'POSTGRES_USER': 'test_admin',
                   'POSTGRES_PASSWORD': 'test-admin-secret', 'POSTGRES_DB': 'clenzy_prod',
                   'CLENZY_APP_DB_USER': 'clenzy_app',
                   'CLENZY_APP_DB_PASSWORD': 'test-app-secret',
                   'CLENZY_APP_DB_USER_PASSWORD': 'test-app-secret',
                   'DEPLOY_MODE': mode, 'DEPLOY_SERVICES': services,
                   'DEPLOY_FORCE_RECREATE': str(force).lower(),
                   'DEPLOY_TEST_TRACE': str(trace), 'DEPLOY_TEST_SQL': sql,
                   'DEPLOY_TEST_CRASH': crash}
            result = subprocess.run(['bash', 'scripts/deploy.sh'], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=30)
            commands = [json.loads(line) for line in trace.read_text().splitlines()]
            return result, commands

    def probes(self, commands):
        return [i for i, args in enumerate(commands)
                if 'psql' in args and 'pgbouncer' in ' '.join(args)]

    def application_starts(self, commands):
        return [i for i, args in enumerate(commands) if 'up' in args
                and (args[-1] == '-d' or 'pms-server' in args)]

    def assert_probe(self, commands, start, end):
        probes = [i for i in self.probes(commands) if start < i < end]
        self.assertTrue(probes, 'SELECT 1 via PgBouncer requis avant la poursuite applicative')
        args = commands[probes[-1]]
        self.assertIn('SELECT 1', args)
        self.assertIn('clenzy_app', args)
        self.assertIn('clenzy_prod', args)
        self.assertIn('6432', args)
        self.assertTrue('run' in args and any('network' in arg for arg in args)
                        and any('test-api-network' in arg for arg in args),
                        'La sonde cliente doit utiliser le réseau API')
        return probes[-1]

    def test_complete_update_requires_network_sql_after_recreation(self):
        result, commands = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        for service in ('postgres', 'db-app-role', 'pgbouncer'):
            self.assertTrue(any('up' in args and '--force-recreate' in args
                                and service in args for args in commands))
        recreate = max(i for i, args in enumerate(commands)
                       if 'up' in args and 'pgbouncer' in args)
        self.assertTrue(any('pg_isready' in args for args in commands[:recreate]))
        self.assert_probe(commands, recreate, self.application_starts(commands)[0])

    def test_persistent_sql_failures_exhaust_exact_budget_and_block_application(self):
        # The existing readiness policy is 30 attempts. Lock the same bounded
        # budget for the network check rather than allowing an unbounded retry.
        for failure in ('network', 'auth', 'incorrect'):
            with self.subTest(failure=failure):
                result, commands = self.deploy(sql=failure)
                self.assertNotEqual(result.returncode, 0, 'Trajet SQL invalide accepté')
                self.assertEqual(len(self.probes(commands)), 30)
                self.assertEqual(self.application_starts(commands), [])
                output = result.stdout + result.stderr
                self.assertRegex(output.lower(), r'(sql|pgbouncer)')
                for secret in ('test-app-secret', 'test-admin-secret'):
                    self.assertNotIn(secret, output)

    def test_two_failures_then_select_one_allow_one_application_start(self):
        result, commands = self.deploy(sql='transient')
        self.assertEqual(result.returncode, 0, result.stderr)
        starts = self.application_starts(commands)
        self.assertEqual(len(starts), 1)
        probes = [i for i in self.probes(commands) if i < starts[0]]
        self.assertEqual(len(probes), 3)
        self.assertLess(probes[-1], starts[0])
        self.assertNotIn('test-app-secret', result.stdout + result.stderr)

    def test_full_rebuild_and_targeted_dependency_paths_are_gated(self):
        for mode, services, force in [('full-rebuild', '', False),
                                      ('update', 'pms-server', False),
                                      ('update', 'pms-server', True),
                                      ('update', 'postgres,pgbouncer,pms-server', False),
                                      ('update', 'postgres,pgbouncer,pms-server', True)]:
            with self.subTest(mode=mode, services=services, force=force):
                result, commands = self.deploy(mode, services, force)
                self.assertEqual(result.returncode, 0, result.stderr)
                start = self.application_starts(commands)[0]
                dependency_starts = [i for i, args in enumerate(commands[:start])
                                     if 'up' in args and ('postgres' in args or 'pgbouncer' in args)]
                self.assertTrue(dependency_starts)
                self.assert_probe(commands, dependency_starts[-1], start)
                if force:
                    self.assertIn('--force-recreate', commands[start])

    def test_frontend_force_recreate_does_not_recreate_untargeted_sql_dependencies(self):
        for force in (False, True):
            with self.subTest(force=force):
                result, commands = self.deploy(services='pms-client', force=force)
                self.assertEqual(result.returncode, 0, result.stderr)
                frontend_starts = [i for i, args in enumerate(commands)
                                   if 'up' in args and 'pms-client' in args]
                self.assertEqual(len(frontend_starts), 1)
                start = frontend_starts[0]
                self.assertEqual('--force-recreate' in commands[start], force)
                dependency_starts = []
                for service in ('postgres', 'pgbouncer'):
                    starts = [i for i, args in enumerate(commands[:start])
                              if 'up' in args and service in args]
                    self.assertTrue(starts, f'{service} doit toujours etre demarre')
                    for index in starts:
                        self.assertNotIn(
                            '--force-recreate', commands[index],
                            f'{service} ne fait pas partie des services cibles du frontend')
                    dependency_starts.extend(starts)
                self.assert_probe(commands, max(dependency_starts), start)

    def test_crash_loop_recovery_rechecks_sql_before_continuing(self):
        for service in ('pgbouncer', 'pms-server', 'keycloak'):
            with self.subTest(service=service):
                result, commands = self.deploy(crash=service)
                self.assertEqual(result.returncode, 0, result.stderr)
                removed = next(i for i, args in enumerate(commands) if 'rm' in args and service in args)
                recovered = next(i for i, args in enumerate(commands)
                                 if i > removed and 'up' in args and service in args)
                cleanup = next(i for i, args in enumerate(commands) if 'prune' in args)
                self.assert_probe(commands, recovered, cleanup)

    def test_production_liquibase_invariants_remain_enabled(self):
        compose = (ROOT / 'docker-compose.prod.yml').read_text()
        self.assertIn('SPRING_LIQUIBASE_ENABLED: "true"', compose)
        self.assertIn('SPRING_JPA_HIBERNATE_DDL_AUTO: validate', compose)


class DeploymentSqlDockerIntegrationTest(unittest.TestCase):
    def test_real_network_and_authentication_through_pgbouncer(self):
        if not shutil.which('docker'):
            self.skipTest('Docker requis pour la stack éphémère')
        available = subprocess.run(['docker', 'info'], capture_output=True, timeout=15)
        if available.returncode:
            self.skipTest('Daemon Docker indisponible')
        project = 'sql-readiness-' + uuid.uuid4().hex[:12]
        env = {'PATH': os.environ['PATH'], 'POSTGRES_DB': 'clenzy_prod',
               'POSTGRES_USER': 'test_admin', 'POSTGRES_PASSWORD': 'test-admin-secret',
               'CLENZY_APP_DB_PASSWORD': 'test-app-secret'}

        def docker(*args):
            return subprocess.run(['docker', *args], env=env, capture_output=True,
                                  text=True, timeout=120)

        # Resolve real services, then remove host ports, names and production
        # storage. Retain their images, commands, configuration and entrypoints.
        resolved = docker('compose', '--env-file', os.devnull, '-f',
                          str(ROOT / 'docker-compose.prod.yml'), 'config', '--format', 'json')
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        production = json.loads(resolved.stdout)['services']
        with tempfile.TemporaryDirectory() as directory:
            services = {}
            for name in ('postgres', 'pgbouncer'):
                original = production[name]
                services[name] = {key: original[key] for key in
                                  ('image', 'environment', 'command', 'entrypoint', 'healthcheck')
                                  if key in original}
                services[name]['networks'] = ['api']
                services[name]['volumes'] = [mount for mount in original.get('volumes', [])
                                            if mount['type'] == 'bind']
            # The client service shares precisely this isolated API network.
            services['api-client'] = {'image': production['postgres']['image'],
                                      'networks': ['api'], 'entrypoint': ['psql']}
            config = Path(directory) / 'compose.json'
            config.write_text(json.dumps({'services': services, 'networks': {'api': {}}}))

            def compose(*args):
                return docker('compose', '-p', project, '-f', str(config), *args)

            def probe(password):
                return compose('run', '--rm', '--no-deps', '-e', 'PGCONNECT_TIMEOUT=3',
                               '-e', 'PGPASSWORD=' + password, 'api-client', '-h', 'pgbouncer',
                               '-p', '6432', '-U', 'clenzy_app', '-d', 'clenzy_prod',
                               '-v', 'ON_ERROR_STOP=1', '-tAc', 'SELECT 1')

            try:
                started = compose('up', '-d', '--wait', '--wait-timeout', '60', 'postgres')
                self.assertEqual(started.returncode, 0, started.stderr)
                role = compose('exec', '-T', 'postgres', 'psql', '-U', 'test_admin',
                               '-d', 'clenzy_prod', '-v', 'ON_ERROR_STOP=1', '-c',
                               "CREATE ROLE clenzy_app LOGIN PASSWORD 'test-app-secret';")
                self.assertEqual(role.returncode, 0, role.stderr)
                self.assertNotEqual(probe('test-app-secret').returncode, 0)
                started = compose('up', '-d', '--wait', '--wait-timeout', '60', 'pgbouncer')
                self.assertEqual(started.returncode, 0, started.stderr)
                success = probe('test-app-secret')
                self.assertEqual(success.returncode, 0, success.stderr)
                self.assertEqual(success.stdout.strip(), '1')
                self.assertNotEqual(probe('wrong-test-password').returncode, 0)
                self.assertEqual(compose('stop', 'pgbouncer').returncode, 0)
                self.assertNotEqual(probe('test-app-secret').returncode, 0)
                restarted = compose('up', '-d', '--wait', '--wait-timeout', '60', 'pgbouncer')
                self.assertEqual(restarted.returncode, 0, restarted.stderr)
                self.assertEqual(probe('test-app-secret').stdout.strip(), '1')
            finally:
                cleaned = compose('down', '--volumes', '--remove-orphans')
                self.assertEqual(cleaned.returncode, 0, cleaned.stderr)


if __name__ == '__main__':
    unittest.main()
