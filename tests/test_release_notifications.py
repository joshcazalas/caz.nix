import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import shlex
import sys
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "notifications", ROOT / "scripts/release-notifications.py"
)
notifications = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notifications)
RELEASE = "caz.nix-2026.09.14-g0123456789ab"


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.queue = self.root / "queue"
        self.requests = []
        self.response_status = 200
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                payload = json.loads(
                    self.rfile.read(int(self.headers["Content-Length"]))
                )
                owner.requests.append((self.path, payload))
                self.send_response(owner.response_status)
                self.end_headers()

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.endpoint = f"http://127.0.0.1:{self.server.server_port}/api/v2/alerts"

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def enqueue(
        self, event="deployed", reboot=False, release=RELEASE, rollback="not-needed"
    ):
        notifications.enqueue(
            self.queue,
            event,
            "example/homelab",
            release,
            "health",
            reboot,
            rollback,
            "test-server",
        )

    def test_success_reboot_and_private_atomic_queue(self):
        self.enqueue(reboot=True)
        self.assertEqual(self.queue.stat().st_mode & 0o777, 0o700)
        files = list(self.queue.glob("*.json"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.queue.glob(".event-*")), [])
        notifications.drain(self.queue, self.endpoint)
        alert = self.requests[0][1][0]
        self.assertEqual(alert["labels"]["event"], "deployed")
        self.assertEqual(alert["labels"]["severity"], "info")
        self.assertIn(
            "requires an ordinary reboot", alert["annotations"]["description"]
        )
        self.assertEqual(
            alert["generatorURL"],
            f"https://github.com/example/homelab/releases/tag/{RELEASE}",
        )
        self.assertEqual(list(self.queue.glob("*.json")), [])

    def test_failed_handoff_retries_same_event_before_following_events(self):
        self.enqueue("available")
        self.enqueue("rolled-back", rollback="succeeded")
        self.response_status = 503
        with self.assertRaises(HTTPError):
            notifications.drain(self.queue, self.endpoint)
        self.assertEqual(len(list(self.queue.glob("*.json"))), 2)
        first_id = self.requests[0][1][0]["labels"]["event_id"]
        self.response_status = 200
        notifications.drain(self.queue, self.endpoint)
        self.assertEqual(self.requests[1][1][0]["labels"]["event_id"], first_id)
        self.assertEqual(self.requests[2][1][0]["labels"]["event"], "rolled-back")
        self.assertIn(
            "Rollback result: succeeded",
            self.requests[2][1][0]["annotations"]["description"],
        )
        notifications.drain(self.queue, self.endpoint)
        self.assertEqual(len(self.requests), 3)

    def test_delivery_lock_does_not_block_producers(self):
        self.enqueue("available")
        with (self.queue / ".delivery.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.enqueue("deployed")
            notifications.drain(self.queue, self.endpoint)
        self.assertEqual(self.requests, [])
        self.assertEqual(len(list(self.queue.glob("*.json"))), 2)
        notifications.drain(self.queue, self.endpoint)
        self.assertEqual(len(self.requests), 2)

    def test_delayed_delivery_window_and_retention(self):
        self.enqueue()
        path = next(self.queue.glob("*.json"))
        record = json.loads(path.read_text())
        record["recordedAt"] = notifications.timestamp(
            notifications.utcnow() - timedelta(days=1)
        )
        path.write_text(json.dumps(record))
        notifications.drain(self.queue, self.endpoint)
        alert = self.requests[0][1][0]
        self.assertGreater(
            notifications.datetime.fromisoformat(alert["endsAt"]),
            notifications.utcnow(),
        )
        self.enqueue()
        path = next(self.queue.glob("*.json"))
        record["recordedAt"] = notifications.timestamp(
            notifications.utcnow() - timedelta(days=15)
        )
        path.write_text(json.dumps(record))
        notifications.drain(self.queue, self.endpoint)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(list(self.queue.glob("*.json")), [])

    def test_failed_rollback_is_critical_and_untrusted_tag_is_omitted(self):
        self.enqueue(
            "rollback-failed",
            release="remote response containing private text",
            rollback="health-check-failed",
        )
        notifications.drain(self.queue, self.endpoint)
        alert = self.requests[0][1][0]
        self.assertEqual(alert["labels"]["severity"], "critical")
        self.assertIn("health-check-failed", alert["annotations"]["description"])
        self.assertNotIn("private text", json.dumps(alert))
        self.assertIn("Release: unknown", alert["annotations"]["description"])

    def test_read_only_updater_failure_keeps_exit_code_and_sends_nothing(self):
        commands = self.root / "bin"
        commands.mkdir()
        curl = commands / "curl"
        curl.write_text(f"#!{shutil.which('bash')}\nexit 22\n")
        curl.chmod(0o755)
        spy = commands / "notify-spy"
        spy.write_text(f"#!{shutil.which('bash')}\n" + 'touch "$NOTIFICATION_MARKER"\n')
        spy.chmod(0o755)
        marker = self.root / "called"
        env = dict(
            os.environ,
            PATH=f"{commands}:{os.environ['PATH']}",
            CAZ_RELEASE_NOTIFICATION_COMMAND=str(spy),
            NOTIFICATION_MARKER=str(marker),
            CAZ_RELEASE_STATE_DIRECTORY=str(self.root / "state"),
            RUNTIME_DIRECTORY=str(self.root),
            TRIGGER_UNIT="caz-release-updater.timer",
        )
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/stage-server-release.sh"), "--check-only"],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 22, result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / "state").exists())
        self.assertEqual(list(self.root.glob("caz-release.*")), [])

    def run_deployment_discovery(
        self,
        metadata=None,
        accepted=False,
        quarantined=False,
        broken_notifier=False,
        trigger="caz-release-updater.timer",
        force=False,
    ):
        if not shutil.which("fakeroot"):
            self.skipTest(
                "run through the Nix check for the unprivileged fake-root updater tests"
            )
        commands = self.root / "bin"
        commands.mkdir()
        state = self.root / "state"
        state.mkdir()
        data = (
            metadata
            if metadata is not None
            else {
                "id": 123,
                "tag_name": RELEASE,
                "target_commitish": "0123456789ab" + "0" * 28,
                "published_at": "2026-09-14T00:00:00Z",
                "draft": False,
                "prerelease": False,
                "immutable": True,
                "assets": [],
            }
        )
        metadata_path = self.root / "metadata.json"
        metadata_path.write_text(json.dumps(data))

        def command(name, body):
            path = commands / name
            path.write_text(f"#!{shutil.which('bash')}\nset -eu\n{body}\n")
            path.chmod(0o755)
            return path

        command(
            "curl",
            """while (( $# > 0 )); do
  if [[ "$1" == --output ]]; then
    cp "$TEST_METADATA" "$2"
    exit 0
  fi
  shift
done
exit 22""",
        )
        command("readlink", "echo /nix/store/test-accepted-system")
        # No production network or privileged operations are performed. The
        # real script exits at discovery/no-op/preflight, before any build.
        notifier = command(
            "notifier",
            "exit 71"
            if broken_notifier
            else f'exec {shlex.quote(sys.executable)} {shlex.quote(str(ROOT / "scripts/release-notifications.py"))} "$@"',
        )
        if accepted:
            (state / "accepted-release.json").write_text(
                json.dumps(
                    {
                        "releaseId": 123,
                        "storePath": "/nix/store/test-accepted-system",
                    }
                )
            )
        if quarantined:
            (state / "failed-release.json").write_text(json.dumps({"releaseId": 123}))
        env = dict(
            os.environ,
            PATH=f"{commands}:{os.environ['PATH']}",
            CAZ_RELEASE_STATE_DIRECTORY=str(state),
            RUNTIME_DIRECTORY=str(self.root),
            TEST_METADATA=str(metadata_path),
            CAZ_RELEASE_NOTIFICATION_COMMAND=str(notifier),
        )
        env.pop("TRIGGER_UNIT", None)
        if trigger is not None:
            env["TRIGGER_UNIT"] = trigger
        result = subprocess.run(
            [
                "fakeroot",
                "--",
                "bash",
                str(ROOT / "scripts/stage-server-release.sh"),
            ]
            + (["--force"] if force else []),
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        alerts = [
            json.loads(path.read_text())["alert"]
            for path in sorted((state / "notifications").glob("*.json"))
        ]
        return result, alerts

    def test_updater_discovery_failure_notifies_and_preserves_failure(self):
        result, alerts = self.run_deployment_discovery(metadata={})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([a["labels"]["event"] for a in alerts], ["failed"])
        self.assertIn("Stage: discovery", alerts[0]["annotations"]["description"])
        self.assertIn("Release: unknown", alerts[0]["annotations"]["description"])

    def test_updater_notification_error_does_not_mask_deployment_failure(self):
        result, alerts = self.run_deployment_discovery(
            metadata={}, broken_notifier=True
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("could not queue", result.stderr)
        self.assertEqual(alerts, [])

    def test_updater_already_accepted_is_quiet(self):
        result, alerts = self.run_deployment_discovery(accepted=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing to do", result.stdout)
        self.assertEqual(alerts, [])

    def test_updater_quarantined_is_quiet(self):
        result, alerts = self.run_deployment_discovery(quarantined=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("quarantined", result.stdout)
        self.assertEqual(alerts, [])

    def test_manual_deployment_failure_is_quiet(self):
        result, alerts = self.run_deployment_discovery(metadata={}, trigger=None)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(alerts, [])

    def test_manual_forced_deployment_failure_is_quiet(self):
        result, alerts = self.run_deployment_discovery(
            metadata={}, trigger=None, force=True
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(alerts, [])

    def test_other_systemd_trigger_is_quiet(self):
        result, alerts = self.run_deployment_discovery(
            metadata={}, trigger="other.timer"
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(alerts, [])

    @unittest.skipUnless(
        shutil.which("alertmanager") and os.environ.get("ALERTMANAGER_CONFIG_FILE"),
        "run through the Nix check to test the configured Alertmanager routes",
    )
    def test_real_alertmanager_routes_events_without_resolved_followup(self):
        config = json.loads(Path(os.environ["ALERTMANAGER_CONFIG_FILE"]).read_text())
        production_receiver = next(
            r for r in config["receivers"] if r["name"] == "deployment-events"
        )
        self.assertFalse(production_receiver["email_configs"][0]["send_resolved"])
        self.assertFalse(production_receiver["discord_configs"][0]["send_resolved"])
        event_route = next(
            r for r in config["route"]["routes"] if r["receiver"] == "deployment-events"
        )
        self.assertEqual(event_route["group_by"], ["event_id"])
        self.assertEqual(event_route["group_wait"], "0s")
        self.assertEqual(event_route["repeat_interval"], "24h")
        # Exercise the actual routing tree against a local recording webhook.
        # Shorten normal grouping delays so incident routing is tested promptly.
        config["route"]["group_wait"] = "0s"
        config["route"]["group_interval"] = "1s"
        for route in config["route"]["routes"]:
            route["group_interval"] = "1s"
        config["receivers"] = [
            {
                "name": receiver["name"],
                "webhook_configs": [
                    {
                        "url": f"http://127.0.0.1:{self.server.server_port}/{receiver['name']}",
                        "send_resolved": receiver["name"] == "operator",
                    }
                ],
            }
            for receiver in config["receivers"]
        ]
        configuration = self.root / "alertmanager.json"
        configuration.write_text(json.dumps(config))
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        log = (self.root / "alertmanager.log").open("w")
        process = subprocess.Popen(
            [
                "alertmanager",
                f"--config.file={configuration}",
                f"--storage.path={self.root / 'am'}",
                f"--web.listen-address=127.0.0.1:{port}",
                "--cluster.listen-address=",
            ],
            stdout=log,
            stderr=log,
        )

        def stop():
            process.terminate()
            process.wait(timeout=10)
            log.close()

        self.addCleanup(stop)
        address = f"http://127.0.0.1:{port}"

        def wait_until(predicate):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                try:
                    if predicate():
                        return
                except OSError:
                    pass
                time.sleep(0.05)
            self.fail((self.root / "alertmanager.log").read_text())

        def ready():
            with urlopen(address + "/-/ready", timeout=1) as response:
                return response.status == 200

        wait_until(ready)
        self.enqueue(reboot=True)
        queued = json.loads(next(self.queue.glob("*.json")).read_text())["alert"]
        notifications.drain(self.queue, address + "/api/v2/alerts")
        wait_until(lambda: len(self.requests) == 1)
        self.assertEqual(self.requests[0][0], "/deployment-events")
        self.assertIn(
            "requires an ordinary reboot",
            self.requests[0][1]["commonAnnotations"]["description"],
        )
        # Resolve the same event. It must not emit a second message.
        queued["startsAt"] = notifications.timestamp(
            notifications.utcnow() - timedelta(minutes=1)
        )
        queued["endsAt"] = notifications.timestamp(
            notifications.utcnow() - timedelta(seconds=1)
        )
        request = Request(
            address + "/api/v2/alerts",
            data=json.dumps([queued]).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request, timeout=3):
            pass
        time.sleep(2)
        self.assertEqual(len(self.requests), 1)
        controls = [
            {
                "labels": {
                    "alertname": "SystemdUnitFailed",
                    "component": "services",
                    "instance": "test-server",
                }
            },
            {
                "labels": {
                    "alertname": "Watchdog",
                    "component": "meta",
                    "instance": "test-server",
                }
            },
        ]
        with urlopen(
            Request(
                address + "/api/v2/alerts",
                data=json.dumps(controls).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            ),
            timeout=3,
        ):
            pass
        wait_until(lambda: len(self.requests) >= 3)
        self.assertEqual(
            {request[0] for request in self.requests},
            {"/deployment-events", "/operator", "/dead-man-switch"},
        )


if __name__ == "__main__":
    unittest.main()
