from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).resolve().parent.parent / "scripts/check-server-health.sh"


class ServerHealthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                status = cls.responses[0]
                if len(cls.responses) > 1:
                    cls.responses.popleft()
                cls.requests.append(self.path)
                self.send_response(status)
                if status == 302:
                    self.send_header("Location", "/redirect-target")
                self.send_header("Content-Length", "100" if cls.partial else "2")
                self.end_headers()
                self.wfile.write(b"ok")
                self.close_connection = True

            def log_message(self, *_args):
                pass

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(
            target=lambda: cls.server.serve_forever(poll_interval=0.01), daemon=True
        )
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        type(self).responses = deque([200])
        type(self).requests = []
        type(self).partial = False
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.url = f"http://127.0.0.1:{self.server.server_port}/probe"

    def run_health(
        self, statuses="200", url=None, args=(), contract=None, short_sleep=False,
        factorio_status=None
    ):
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("CAZ_HEALTH_")
        }
        env.update(
            CAZ_HEALTH_HTTP_ENDPOINTS=contract
            if contract is not None
            else f"test={statuses}={url or self.url}",
            CURL_HOME=str(self.root),
            NO_PROXY="127.0.0.1",
            no_proxy="127.0.0.1",
        )
        if factorio_status is not None:
            probe = self.root / "factorio-access"
            probe.write_text(
                f'#!{shutil.which("bash")}\n[[ "$1" == health ]] || exit 99\nexit {factorio_status}\n'
            )
            probe.chmod(0o755)
            env["CAZ_HEALTH_CHECK_FACTORIO"] = "true"
            env["CAZ_HEALTH_FACTORIO_COMMAND"] = str(probe)
        if short_sleep:
            # Keep the production wait/stabilization control flow. Only its
            # sleeps are shortened so recheck tests take seconds, not minutes.
            commands = self.root / "bin"
            commands.mkdir()
            sleep = commands / "sleep"
            sleep.write_text(
                f"#!{shutil.which('bash')}\nexec {shutil.which('sleep')} 0.6\n"
            )
            sleep.chmod(0o755)
            env["PATH"] = f"{commands}:{env['PATH']}"
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def test_health_endpoint_requires_200(self):
        for status in (200, 204, 302, 304, 400, 401, 403, 404, 429, 500, 503):
            with self.subTest(status=status):
                type(self).responses = deque([status])
                result = self.run_health()
                self.assertEqual(
                    result.returncode, 0 if status == 200 else 1, result.stderr
                )
                if status != 200:
                    self.assertIn(
                        f"http:test:status={status}(expected=200)", result.stderr
                    )

    def test_factorio_probe_failure_rejects_release(self):
        for status in (0, 1):
            with self.subTest(status=status):
                result = self.run_health(factorio_status=status)
                self.assertEqual(result.returncode, status, result.stderr)
                if status:
                    self.assertIn("factorio:listener-or-whitelist", result.stderr)

    def test_frontend_redirect_is_explicit_and_not_followed(self):
        type(self).responses = deque([302, 404])
        result = self.run_health(statuses="200,302")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, ["/probe"])

    def test_frontend_does_not_accept_arbitrary_client_errors(self):
        for status in (401, 403, 404, 429):
            with self.subTest(status=status):
                type(self).responses = deque([status])
                result = self.run_health(statuses="200,302")
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_authentication_exception_requires_explicit_status(self):
        type(self).responses = deque([401])
        result = self.run_health(statuses="200,401")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_multiple_probes_keep_separate_contracts_and_url_query(self):
        type(self).responses = deque([302, 404])
        result = self.run_health(
            contract=f"frontend=200,302={self.url}?next=home ready=200={self.url}"
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("http:ready:status=404(expected=200)", result.stderr)
        self.assertNotIn("http:frontend:", result.stderr)
        self.assertEqual(self.requests, ["/probe?next=home", "/probe"])

    def test_malformed_contract_fails_before_requests(self):
        for contract in (
            f"test={self.url}",
            f"test=20={self.url}",
            f"test=200,={self.url}",
            "test=200=file:///etc/passwd",
        ):
            with self.subTest(contract=contract):
                result = self.run_health(contract=contract)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("Invalid HTTP health probe", result.stderr)
        self.assertEqual(self.requests, [])

    def test_partial_response_does_not_accept_200_headers(self):
        type(self).partial = True
        result = self.run_health()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("http:test:transport", result.stderr)

    def test_connection_failure_is_unhealthy(self):
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
            result = self.run_health(url=f"http://127.0.0.1:{port}/")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("http:test:transport", result.stderr)

    def test_curlrc_cannot_enable_redirect_following(self):
        (self.root / ".curlrc").write_text("location\n")
        type(self).responses = deque([302, 200])
        result = self.run_health()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("status=302", result.stderr)
        self.assertEqual(self.requests, ["/probe"])

    def test_wait_allows_endpoint_to_become_ready(self):
        type(self).responses = deque([503, 200])
        result = self.run_health(args=("--wait", "2"), short_sleep=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)

    def test_stabilization_confirms_transient_failure_before_rejecting(self):
        type(self).responses = deque([200, 503, 200])
        result = self.run_health(args=("--stabilize", "1"), short_sleep=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Re-checking", result.stderr)
        self.assertEqual(len(self.requests), 3)

    def test_stabilization_rejects_two_consecutive_failures(self):
        type(self).responses = deque([200, 503, 503])
        result = self.run_health(args=("--stabilize", "1"), short_sleep=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("failed twice", result.stderr)
        self.assertEqual(len(self.requests), 3)


if __name__ == "__main__":
    unittest.main()
