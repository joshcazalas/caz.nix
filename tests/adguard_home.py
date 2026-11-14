"""Exercise production DNS settings with synthetic names and a local upstream."""

import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time


def query(name):
    question = b"".join(bytes([len(label)]) + label.encode() for label in name.split("."))
    return struct.pack("!6H", 1, 0x0100, 1, 0, 0, 0) + question + b"\0\0\1\0\1"


def lookup(port, name):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(1)
        client.sendto(query(name), ("127.0.0.1", port))
        answer = client.recv(4096)
    _, flags, _, count, _, _ = struct.unpack("!6H", answer[:12])
    assert flags & 0xF == 0 and count == 1, answer
    return socket.inet_ntoa(answer[-4:])


with tempfile.TemporaryDirectory() as directory, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as upstream:
    upstream.bind(("127.0.0.1", 0))
    upstream.settimeout(0.2)
    stopped = threading.Event()

    def serve():
        while not stopped.is_set():
            try:
                request, peer = upstream.recvfrom(4096)
            except socket.timeout:
                continue
            header = request[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0)
            # Copy only the question, excluding any EDNS additional record.
            question_end = request.index(b"\0", 12) + 5
            record = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4)
            upstream.sendto(header + request[12:question_end] + record + socket.inet_aton("192.0.2.20"), peer)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    # Avoid collisions when several checks execute on the same builder.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        dns_port = reservation.getsockname()[1]
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        http_port = reservation.getsockname()[1]

    config = json.loads(Path(sys.argv[1]).read_text())
    config["http"] = {"address": f"127.0.0.1:{http_port}"}
    config["dns"].update({
        "bind_hosts": ["127.0.0.1"],
        "port": dns_port,
        "upstream_dns": [f"127.0.0.1:{upstream.getsockname()[1]}"],
        "fallback_dns": [],
        "bootstrap_dns": [],
    })
    config["filters"] = []
    path = Path(directory) / "AdGuardHome.yaml"
    # JSON is valid YAML and avoids adding a YAML parser to the fixture.
    path.write_text(json.dumps(config))
    os.chmod(path, 0o600)
    with (Path(directory) / "adguard.log").open("w+") as log:
        process = subprocess.Popen(
            ["AdGuardHome", "--no-check-update", "-c", str(path), "-w", directory],
            stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 30
            while True:
                try:
                    assert lookup(dns_port, "server") == "192.0.2.10"
                    break
                except (TimeoutError, ConnectionRefusedError):
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("AdGuard did not become ready")
                    time.sleep(0.1)
            assert lookup(dns_port, "service.example.test") == "192.0.2.10"
            assert lookup(dns_port, "unmapped.example.test") == "192.0.2.20"
            # The builder has localhost in /etc/hosts. It must not leak into DNS.
            assert socket.gethostbyname("localhost") == "127.0.0.1"
            assert lookup(dns_port, "localhost") == "192.0.2.20"
            print("Server and public rewrites work; OS hosts entries are not served.")
        except BaseException:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            process.terminate()
            process.wait(timeout=10)
            stopped.set()
            thread.join(timeout=2)
