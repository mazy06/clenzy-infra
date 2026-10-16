from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class WorkflowTests(unittest.TestCase):
    def load(self, name):
        return yaml.load((ROOT / ".github/workflows" / name).read_text(), Loader=yaml.BaseLoader)

    def test_deployment_is_manual_and_requires_the_hold_to_be_explicitly_lifted(self):
        workflow = self.load("baitly-iot-staging.yml")
        self.assertEqual(set(workflow["on"]), {"workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        guard = workflow["jobs"]["guard"]["steps"][0]
        self.assertIn("IOT_STAGING_DEPLOY_ENABLED", guard["env"]["ENABLED"])
        self.assertIn("refs/heads/main", guard["run"])
        self.assertIn("DEPLOY IOT STAGING", guard["run"])
        deploy = workflow["jobs"]["deploy-and-qualify"]
        self.assertEqual(deploy["needs"], "guard")
        self.assertEqual(deploy["environment"], "iot-staging")
        self.assertEqual(workflow["concurrency"]["cancel-in-progress"], "false")

    def test_ci_never_calls_deployment_or_reads_runtime_secrets(self):
        workflow = self.load("ci-baitly-iot-infra.yml")
        self.assertEqual(set(workflow["on"]), {"push", "pull_request"})
        source = (ROOT / ".github/workflows/ci-baitly-iot-infra.yml").read_text()
        for forbidden in ("secrets.", "deploy_ci.py", "validate_staging.py", "workflow_dispatch"):
            self.assertNotIn(forbidden, source)
        self.assertIn("unshare --net", source)

    def test_signing_key_is_not_provided_to_the_deployment_step(self):
        deploy = self.load("baitly-iot-staging.yml")["jobs"]["deploy-and-qualify"]
        for step in deploy["steps"]:
            if "deploy_ci.py" in step.get("run", ""):
                self.assertNotIn("IOT_DEVICE_CA_KEY", step.get("env", {}))
            if "validate_staging.py" in step.get("run", ""):
                self.assertIn("IOT_DEVICE_CA_KEY", step["env"])


if __name__ == "__main__":
    unittest.main()
