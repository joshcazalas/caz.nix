"""Exercise real updater discovery with deterministic curl failures and time."""

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


if __name__ == "__main__":
    unittest.main()
