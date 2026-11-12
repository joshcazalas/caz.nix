"""Regression coverage for selective CI and fail-closed check ownership."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_checks as ci


class CISelection(unittest.TestCase):
    def classify(self, *paths):
        with contextlib.redirect_stderr(io.StringIO()):
            return ci.classify(paths)

    def checks(self, result):
        return {check for row in result["integration_matrix"]["include"] for check in row["checks"]}

    def assert_all(self, result):
        for component in ci.COMPONENTS:
            self.assertTrue(result[component], component)
        self.assertTrue(result["integration"])
        self.assertEqual(self.checks(result), ci.INTEGRATION_CHECKS)

    def test_unknown_shared_empty_and_manual_run_everything(self):
        for path in ["new-package/build.nix", "tests/new-test.py", "modules/nixos/new-service.nix",
                     "flake.nix", "flake.lock", "settings.nix", "secrets/homeserver.yaml",
                     ".github/workflows/ci.yml", "scripts/ci_checks.py"]:
            with self.subTest(path=path):
                self.assert_all(self.classify(path))
        self.assert_all(self.classify())
        self.assert_all(ci.classify(["README.md"], all_checks=True))

    def test_docs_select_no_component(self):
        result = self.classify("docs/home-assistant.md", "README.md", "esphome/README.md")
        self.assertFalse(any(result[key] for key in (*ci.COMPONENTS, "integration")))
        self.assertEqual(result["integration_matrix"], {"include": []})

    def test_ha_preparation_selects_server_and_bluetooth_only(self):
        for path in ["scripts/prepare-ha-private.py", "modules/nixos/home-assistant.nix",
                     "home-assistant/packages/private.yaml"]:
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertTrue(result["homeserver"])
                self.assertEqual(self.checks(result), {"ha-bluetooth"})
                self.assertFalse(result["wsl"] or result["windows"] or result["esphome"])

    def test_unit_tests_select_their_actual_owner(self):
        for path in ["tests/test_ha_private.py", "tests/test_schlage_local.py",
                     "tests/test_release_downloads.py", "tests/test_secondary_backup.py"]:
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertTrue(result["homeserver"])
                self.assertFalse(result["integration"])
        for path in ["tests/test_device_network.py", "tests/test_local_integrations.py"]:
            self.assertEqual(self.checks(self.classify(path)), {"device-network-config"})

    def test_test_only_changes_do_not_build_the_server(self):
        mapping = {
            "ha_bluetooth_probe.py": "ha-bluetooth",
            "ha-bluetooth.nix": "ha-bluetooth",
            "deployment-storage.nix": "deployment-storage-integration",
            "device-network.nix": "device-network",
            "game-stream-gateway.nix": "game-stream-gateway",
            "home-access-gateway.nix": "home-access-gateway",
            "network-policy.nix": "network-policy",
            "network-readiness.nix": "network-readiness",
        }
        for filename, check in mapping.items():
            with self.subTest(filename=filename):
                result = self.classify(f"tests/{filename}")
                self.assertEqual(self.checks(result), {check})
                self.assertFalse(result["homeserver"])

    def test_source_dependencies_select_consuming_tests(self):
        mapping = {
            "modules/nixos/device-network.nix": {"device-network", "device-network-config"},
            "packages/device-network/local-integrations.py": {"device-network", "device-network-config"},
            "packages/website-updater/src/index.ts": {"network-policy"},
            "modules/nixos/networking.nix": {"network-readiness"},
            "modules/nixos/game-stream-gateway.nix": {"game-stream-gateway"},
            "scripts/stage-server-release.sh": {"deployment-storage-integration"},
        }
        for path, checks in mapping.items():
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertTrue(result["homeserver"])
                self.assertEqual(self.checks(result), checks)

    def test_selection_unions_changes_and_deduplicates_shards(self):
        result = self.classify("tests/device-network.nix", "tests/test_device_network.py",
                               "tests/network-readiness.nix", "tests/network-readiness.nix")
        self.assertEqual(result["integration_matrix"], {"include": [
            {"name": "devices", "checks": ["device-network", "device-network-config"]},
            {"name": "services", "checks": ["network-readiness"]},
        ]})
        self.assert_all(self.classify("tests/ha-bluetooth.nix", "unknown/file"))

    def test_esphome_only_runs_for_relevant_changes(self):
        for path in ["esphome/requirements.txt", "esphome/bluetooth-proxy.yaml", "tests/esphome_config.py"]:
            result = self.classify(path)
            self.assertTrue(result["esphome"])
            self.assertFalse(result["homeserver"] or result["integration"])
        result = self.classify("scripts/prepare-esphome-proxy.py")
        self.assertTrue(result["homeserver"] and result["esphome"])
        self.assertFalse(self.classify("modules/nixos/home-assistant.nix")["esphome"])

    def test_cli_handles_renames_deletions_and_unusual_paths(self):
        # The workflow uses --no-renames: both sides of a rename enter the union.
        payload = b"tests/device-network.nix\0tests/ha-bluetooth.nix\0"
        result = subprocess.run([str(ROOT / "scripts/classify-ci-changes.sh")],
                                input=payload, capture_output=True, check=True)
        outputs = dict(line.split("=", 1) for line in result.stdout.decode().splitlines())
        self.assertEqual(self.checks({"integration_matrix": json.loads(outputs["integration_matrix"])}),
                         {"device-network", "ha-bluetooth"})
        result = subprocess.run([str(ROOT / "scripts/classify-ci-changes.sh")],
                                input=b"unknown\nesphome=false\0", capture_output=True, check=True)
        outputs = dict(line.split("=", 1) for line in result.stdout.decode().splitlines())
        self.assertEqual(outputs["esphome"], "true")
        result = subprocess.run([str(ROOT / "scripts/classify-ci-changes.sh")],
                                input=b"unterminated", capture_output=True)
        self.assertNotEqual(result.returncode, 0)


class CheckOwnership(unittest.TestCase):
    def setUp(self):
        self.declared = sorted(ci.HOMESERVER_CHECKS | ci.INTEGRATION_CHECKS | {"wsl-home"})

    def test_full_and_selective_builds(self):
        self.assertEqual(set(ci.select_checks(self.declared, "integration")), ci.INTEGRATION_CHECKS)
        self.assertEqual(ci.select_checks(self.declared, "integration", ["ha-bluetooth"]), ["ha-bluetooth"])
        self.assertEqual(ci.select_checks(self.declared, "validate"), [])
        self.assertEqual(ci.select_checks(self.declared, "wsl"), ["wsl-home"])

    def test_unknown_checks_fail_even_for_unrelated_groups(self):
        with self.assertRaises(ValueError):
            ci.select_checks(self.declared + ["new-check"], "wsl")

    def test_stale_matrix_fails_instead_of_silently_skipping_tests(self):
        with self.assertRaises(ValueError):
            ci.select_checks([check for check in self.declared if check != "ha-bluetooth"], "validate")

    def test_invalid_explicit_selections_fail(self):
        for checks in [[], ["homeserver"], ["unknown"], ["ha-bluetooth", "ha-bluetooth"],
                       "ha-bluetooth", [42], [{}]]:
            with self.subTest(checks=checks), self.assertRaises(ValueError):
                ci.select_checks(self.declared, "integration", checks)

    def test_every_integration_check_has_exactly_one_shard(self):
        checks = [check for shard in ci.INTEGRATION_SHARDS.values() for check in shard]
        self.assertEqual(len(checks), len(set(checks)))


class RequiredStatus(unittest.TestCase):
    def setUp(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.script = textwrap.dedent(workflow.split("  validate:\n", 1)[1].split("        run: |\n", 1)[1])
        self.env = {**os.environ, "CHANGES_RESULT": "success", "LINT_RESULT": "success"}
        for component in (*ci.COMPONENTS, "integration"):
            self.env[f"{component.upper()}_SELECTED"] = "false"
            self.env[f"{component.upper()}_RESULT"] = "skipped"

    def run_gate(self, **overrides):
        return subprocess.run(["bash", "-euo", "pipefail", "-c", self.script],
                              env={**self.env, **overrides}, capture_output=True).returncode

    def test_intentional_skips_and_selected_success_pass(self):
        self.assertEqual(self.run_gate(), 0)
        self.assertEqual(self.run_gate(INTEGRATION_SELECTED="true", INTEGRATION_RESULT="success",
                                       ESPHOME_SELECTED="true", ESPHOME_RESULT="success"), 0)

    def test_failed_cancelled_or_missing_selected_jobs_block_merge(self):
        for component in (*ci.COMPONENTS, "integration"):
            for result in ("failure", "cancelled", "skipped", ""):
                with self.subTest(component=component, result=result):
                    self.assertNotEqual(self.run_gate(**{
                        f"{component.upper()}_SELECTED": "true",
                        f"{component.upper()}_RESULT": result,
                    }), 0)
        self.assertNotEqual(self.run_gate(CHANGES_RESULT="failure"), 0)
        self.assertNotEqual(self.run_gate(LINT_RESULT="failure"), 0)
        self.assertNotEqual(self.run_gate(INTEGRATION_SELECTED=""), 0)


if __name__ == "__main__":
    unittest.main()
