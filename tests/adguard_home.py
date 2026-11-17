"""Exercise AdGuard account preparation, web authentication, and DNS policy."""

import base64
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

import dns.message
import dns.query
import dns.rcode
import dns.rrset
import yaml


CUSTOM_RULE = "|custom.example.test|$dnsrewrite=NOERROR;A;192.0.2.30"
TIMESTAMP = "2020-01-01T00:00:00Z"


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def lookup(port, name, source="127.0.0.1", transport="udp", record_type="A"):
    response = getattr(dns.query, transport)(
        dns.message.make_query(name, record_type), "127.0.0.1",
        port=port, source=source, timeout=1,
    )
    assert response.rcode() == dns.rcode.NOERROR, response
    return [record.to_text() for answer in response.answer for record in answer]


def prepare(script, directory):
    subprocess.run([script], env={**os.environ, "STATE_DIRECTORY": str(directory)}, check=True)
    path = directory / "AdGuardHome.yaml"
    assert path.stat().st_mode & 0o777 == 0o600
    return yaml.safe_load(path.read_text())


def check_admin_login(port, username, password):
    connection = HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request("GET", "/control/status")
        denied = connection.getresponse()
        denied.read()
        assert denied.status in (401, 403), denied.status
        credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
        connection.request("GET", "/control/status", headers={"Authorization": f"Basic {credentials}"})
        granted = connection.getresponse()
        assert granted.status == 200, granted.status
        assert "version" in json.loads(granted.read())
    finally:
        connection.close()


def exercise(directory, config, upstream_port, expected, username, password):
    dns_port, http_port = free_port(), free_port()
    config["http"] = {"address": f"127.0.0.1:{http_port}"}
    config["dns"].update({
        "bind_hosts": ["127.0.0.1"],
        "port": dns_port,
        # This synthetic regression deliberately sends a burst of queries.
        "ratelimit": 0,
        "upstream_dns": [f"127.0.0.1:{upstream_port}"],
        "fallback_dns": [],
        "bootstrap_dns": [],
    })
    config["filters"] = []
    path = directory / "AdGuardHome.yaml"
    path.write_text(json.dumps(config))
    with (directory / "adguard.log").open("w+") as log:
        process = subprocess.Popen(
            ["AdGuardHome", "--no-check-update", "-c", str(path), "-w", str(directory)],
            stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 30
            while True:
                try:
                    assert lookup(dns_port, "server") == ["192.0.2.10"]
                    break
                except (dns.exception.Timeout, ConnectionRefusedError):
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("AdGuard did not become ready")
                    time.sleep(0.1)
            check_admin_login(http_port, username, password)
            for transport in ("udp", "tcp"):
                # Alternate clients repeatedly to catch cross-client cache leaks.
                for source, address in list(expected.items()) * 2:
                    for name in ("server", "SERVER."):
                        result = lookup(dns_port, name, source, transport)
                        assert result == [address], (source, name, result, address)
                    assert lookup(dns_port, "server", source, transport, "AAAA") == []
                    for name, answer in (
                        ("service.example.test", "192.0.2.10"),
                        ("custom.example.test", "192.0.2.30"),
                        ("unmapped.example.test", "192.0.2.20"),
                        ("server.example.test", "192.0.2.20"),
                        ("sub.server", "192.0.2.20"),
                        ("otherserver", "192.0.2.20"),
                        ("localhost", "192.0.2.20"),
                    ):
                        assert lookup(dns_port, name, source, transport) == [answer], (source, name)
            assert socket.gethostbyname("localhost") == "127.0.0.1"
        except BaseException:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            process.terminate()
            process.wait(timeout=10)


def main():
    preparations = json.loads(Path(sys.argv[1]).read_text())
    with tempfile.TemporaryDirectory() as temporary, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as upstream:
        directory = Path(temporary)
        upstream.bind(("127.0.0.1", 0))
        upstream.settimeout(0.2)
        stopped = threading.Event()

        def serve():
            while not stopped.is_set():
                try:
                    request, peer = upstream.recvfrom(4096)
                except socket.timeout:
                    continue
                message = dns.message.from_wire(request)
                response = dns.message.make_response(message)
                question = message.question[0]
                response.answer.append(dns.rrset.from_text(question.name, 60, "IN", "A", "192.0.2.20"))
                upstream.sendto(response.to_wire(), peer)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            config = prepare(preparations["enabled"], directory)
            path = directory / "AdGuardHome.yaml"
            password_path = directory / "initial-admin-password"
            assert password_path.stat().st_mode & 0o777 == 0o600
            password = password_path.read_text().strip()
            assert [user["name"] for user in config["users"]] == ["admin"]
            assert password and password not in path.read_text()
            password_path.unlink()
            users = config["users"]
            config["user_rules"].insert(0, CUSTOM_RULE)
            # Exercise migration from the previous global hostname rewrite.
            config["filtering"]["rewrites"].append({"domain": "SERVER.", "answer": "192.0.2.10", "enabled": True})
            config["filtering"]["protection_disabled_until"] = TIMESTAMP
            config["querylog"] = {"enabled": False}
            path.write_text(json.dumps(config))
            for iteration, variant in enumerate(("enabled", "enabled", "changed", "disabled", "empty", "enabled")):
                if iteration == 1:
                    # Subsequent boots must also preserve operator-managed accounts.
                    users = [{"name": "existing-owner", "password": users[0]["password"]}]
                    config["users"] = users
                    path.write_text(yaml.safe_dump(config))
                config = prepare(preparations[variant], directory)
                assert config["users"] == users
                assert not password_path.exists()
                rules = config["user_rules"]
                assert rules.count(CUSTOM_RULE) == 1
                assert rules.count("! BEGIN caz managed server hostname") == 1
                assert config["querylog"]["enabled"] is False
                # safe_load may parse timestamps; inspect the serialized representation too.
                if iteration == 0:
                    assert "2020-01-01T00:00:00" in path.read_text()
                assert not any(item["domain"].lower().rstrip(".") == "server"
                               for item in config["filtering"]["rewrites"])
                # Keep the test's JSON serializer independent of YAML datetime objects.
                config["filtering"]["protection_disabled_until"] = TIMESTAMP
                expected = {f"127.0.0.{index}": "192.0.2.10" for index in range(1, 6)}
                if variant == "enabled":
                    expected.update({"127.0.0.2": "198.51.100.1", "127.0.0.3": "198.51.100.1"})
                elif variant == "changed":
                    expected.update({"127.0.0.4": "198.51.100.2", "127.0.0.3": "198.51.100.2"})
                exercise(directory, config, upstream.getsockname()[1], expected, users[0]["name"], password)
                print(f"{variant}: LAN/VPN DNS, OS-host exclusion, custom rules, and upstream passed.")
            # An existing installation can explicitly store an empty user list.
            config["users"] = []
            path.write_text(yaml.safe_dump(config))
            updated = prepare(preparations["enabled"], directory)
            new_password = password_path.read_text().strip()
            assert new_password and new_password != password
            assert [user["name"] for user in updated["users"]] == ["admin"]
            assert new_password not in path.read_text()
        finally:
            stopped.set()
            thread.join(timeout=2)


if __name__ == "__main__":
    main()
