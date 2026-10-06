"""Exercise updater discovery and build recovery with deterministic failures."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class DownloadTests(unittest.TestCase):
    def run_discovery(self, responses):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = root / "bin"
            commands.mkdir()
            (root / "responses.json").write_text(json.dumps(responses))
            # Advance Bash's clock without spending minutes in each test.
            (root / "clock.sh").write_text(
                'sleep() { echo "$1" >> "$TEST_ROOT/delays"; SECONDS=$((SECONDS + $1)); }\n'
            )
            curl = commands / "curl"
            curl.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "root = Path(os.environ['TEST_ROOT'])\n"
                "calls = root / 'calls'\n"
                "count = int(calls.read_text()) if calls.exists() else 0\n"
                "calls.write_text(str(count + 1))\n"
                "responses = json.loads((root / 'responses.json').read_text())\n"
                "response = responses[min(count, len(responses) - 1)]\n"
                "args = sys.argv[1:]\n"
                "output = Path(args[args.index('--output') + 1])\n"
                "output.write_text(response.get('body', '{}'))\n"
                "headers = Path(args[args.index('--dump-header') + 1])\n"
                "headers.write_text(response.get('headers', ''))\n"
                "print(response.get('status', '000'), end='')\n"
                "sys.exit(response.get('code', 0))\n"
            )
            curl.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/stage-server-release.sh"), "--check-only"],
                env=dict(
                    os.environ,
                    PATH=f"{commands}:{os.environ['PATH']}",
                    BASH_ENV=str(root / "clock.sh"),
                    TEST_ROOT=str(root),
                    RUNTIME_DIRECTORY=str(root),
                    CAZ_RELEASE_STATE_DIRECTORY=str(root / "state"),
                ),
                capture_output=True,
                text=True,
                timeout=10,
            )
            calls = int((root / "calls").read_text())
            delays = (root / "delays").read_text().splitlines() if (root / "delays").exists() else []
            self.assertFalse((root / "state").exists())
            self.assertEqual(list(root.glob("caz-release.*")), [])
            return result, calls, delays

    @unittest.skipUnless(shutil.which("jq"), "jq is required by the updater")
    def test_transient_failures_recover_then_metadata_policy_still_rejects(self):
        for code in [6, 7, 18, 28, 52, 56]:
            with self.subTest(code=code):
                result, calls, delays = self.run_discovery([
                    {"code": code, "body": "partial"},
                    {"code": 0, "status": "200"},
                ])
                self.assertEqual(result.returncode, 1)
                self.assertIn("not a published, immutable release", result.stderr)
                self.assertEqual(calls, 2)
                self.assertEqual(delays, ["15"])

    def test_persistent_dns_failure_has_bounded_retries(self):
        result, calls, delays = self.run_discovery([{"code": 6}])
        self.assertEqual(result.returncode, 6)
        self.assertEqual(calls, 12)
        self.assertEqual(sum(map(int, delays)), 165)
        self.assertIn("retry budget", result.stderr)

    def test_permanent_http_certificate_and_local_errors_do_not_retry(self):
        for code, status in [(22, "401"), (22, "403"), (22, "404"), (60, "000"), (23, "200")]:
            with self.subTest(code=code, status=status):
                result, calls, delays = self.run_discovery([{"code": code, "status": status}])
                self.assertEqual(result.returncode, code)
                self.assertEqual(calls, 1)
                self.assertEqual(delays, [])

    @unittest.skipUnless(shutil.which("jq"), "jq is required by the updater")
    def test_temporary_http_error_recovers_and_honors_retry_after(self):
        result, calls, delays = self.run_discovery([
            {"code": 22, "status": "503", "headers": "HTTP/2 503\r\nRetry-After: 45\r\n"},
            {"status": "200"},
        ])
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a published, immutable release", result.stderr)
        self.assertEqual(calls, 2)
        self.assertEqual(delays, ["45"])

    def test_retry_after_cannot_extend_budget(self):
        result, calls, delays = self.run_discovery([
            {"code": 22, "status": "429", "headers": "Retry-After: 600\r\n"},
        ])
        self.assertEqual(result.returncode, 22)
        self.assertEqual(calls, 1)
        self.assertEqual(delays, [])


class BuildRetryTests(unittest.TestCase):
    def run_build(self, responses, derivation="/nix/store/expected.drv"):
        # Execute the production build stage, including manifest comparisons.
        script = (ROOT / "scripts/stage-server-release.sh").read_text()
        stage = script.split("reproduce_release_build() {", 1)[1]
        stage = "reproduce_release_build() {" + stage.split(
            'if [[ "${check_only}" == true ]]; then', 1
        )[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = root / "bin"
            commands.mkdir()
            (root / "responses.json").write_text(json.dumps(responses))
            nix = commands / "nix"
            nix.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "root = Path(os.environ['work_directory'])\n"
                "if sys.argv[1] == 'path-info':\n"
                "    print(os.environ['TEST_DERIVATION']); sys.exit(0)\n"
                "calls = root / 'calls'\n"
                "count = int(calls.read_text()) if calls.exists() else 0\n"
                "calls.write_text(str(count + 1))\n"
                "with (root / 'arguments').open('a') as f:\n"
                "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "responses = json.loads((root / 'responses.json').read_text())\n"
                "response = responses[min(count, len(responses) - 1)]\n"
                "print(response.get('output', '/nix/store/expected'))\n"
                "print(response.get('error', ''), file=sys.stderr)\n"
                "sys.exit(response.get('code', 0))\n"
            )
            nix.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", 'set -Eeuo pipefail\n'
                 'sleep() { echo "$1" >> "$work_directory/delays"; }\n' + stage],
                env=dict(
                    os.environ,
                    PATH=f"{commands}:{os.environ['PATH']}",
                    work_directory=str(root),
                    flake_reference="github:owner/repo/pinned-commit",
                    expected_store_path="/nix/store/expected",
                    expected_derivation="/nix/store/expected.drv",
                    TEST_DERIVATION=derivation,
                    release_tag="test-release",
                    commit_sha="pinned-commit",
                ),
                capture_output=True,
                text=True,
                timeout=10,
            )
            calls = int((root / "calls").read_text())
            delays = (root / "delays").read_text().splitlines() if (root / "delays").exists() else []
            arguments = [json.loads(line) for line in (root / "arguments").read_text().splitlines()]
            self.assertTrue(all(args == arguments[0] for args in arguments))
            self.assertIn("github:owner/repo/pinned-commit#nixosConfigurations.homeserver.config.system.build.toplevel", arguments[0])
            return result, calls, delays

    def test_success_needs_no_retry(self):
        result, calls, delays = self.run_build([{}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 1)
        self.assertEqual(delays, [])

    def test_dns_failure_recovers_and_discards_partial_stdout(self):
        result, calls, delays = self.run_build([
            {"code": 1, "error": "> curl: (6) Could not resolve host: static.crates.io", "output": "partial"},
            {},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 2)
        self.assertEqual(delays, ["60"])
        self.assertIn("Could not resolve host", result.stderr)

    def test_persistent_dns_failure_is_bounded(self):
        result, calls, delays = self.run_build([
            {"code": 1, "error": "> curl: (6) Could not resolve host: static.crates.io"},
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, 3)
        self.assertEqual(delays, ["60", "60"])
        self.assertIn("exhausted", result.stderr)

    def test_deterministic_errors_fail_without_retry(self):
        for error in ["error: compilation failed", "hash mismatch", "curl: (60) certificate problem", "curl: (22) HTTP 404"]:
            with self.subTest(error=error):
                result, calls, delays = self.run_build([{"code": 1, "error": error}])
                self.assertEqual(result.returncode, 1)
                self.assertEqual(calls, 1)
                self.assertEqual(delays, [])

    def test_successful_retry_still_enforces_manifest(self):
        failure = {"code": 1, "error": "curl: (6) Could not resolve host"}
        for response, derivation, message in [
            ({"output": "/nix/store/wrong"}, "/nix/store/expected.drv", "Built store path does not match"),
            ({}, "/nix/store/wrong.drv", "Built derivation does not match"),
            ({"output": "/nix/store/expected\n/nix/store/extra"}, "/nix/store/expected.drv", "Expected one homeserver output"),
        ]:
            with self.subTest(message=message):
                result, calls, _ = self.run_build([failure, response], derivation)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(calls, 2)
                self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
