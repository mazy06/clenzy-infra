"""Baitly : routage CI/CD et sélection d'images sans réseau ni Docker."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

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


if __name__ == '__main__':
    unittest.main()
