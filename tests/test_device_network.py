"""Validation tests for private network policy, using synthetic configuration."""

import copy
import importlib.util
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "device_network", Path(__file__).parents[1] / "packages/device-network/device-network.py"
)
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)


def fixture():
    return {
        "interface": "wlan-test",
        "address": "192.168.70.1/24",
        "dhcp": {"start": "192.168.70.20", "end": "192.168.70.50"},
        "wifi": {"ssid": "Synthetic test", "passphraseFile": "/run/private-test-key",
                 "channel": 6, "countryCode": "US"},
        "dns": {"service.test": "192.168.70.1"},
        "tcp": {
            "events": {"direction": "toHost", "listenPort": 8883,
                       "targetAddress": "127.0.0.1", "targetPort": 1883},
            "control": {"direction": "toNetwork", "listenPort": 19080,
                        "targetAddress": "192.168.70.10", "targetPort": 80},
        },
    }


class ValidationTests(unittest.TestCase):
    def test_wifi_health_reply_socket_is_visible_with_private_tmp(self):
        config = fixture()
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            control = runtime / "hostapd"
            control.mkdir()
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as daemon:
                daemon.bind(str(control / config["interface"]))
                daemon.settimeout(5)
                replies = []

                def respond():
                    try:
                        request, peer = daemon.recvfrom(4096)
                        # Model PrivateTmp: hostapd can only reply through the
                        # shared runtime directory, not another service's /tmp.
                        if request == b"STATUS" and Path(peer).parent == runtime:
                            daemon.sendto(b"state=ENABLED\n", peer)
                            replies.append(peer)
                    except TimeoutError:
                        pass

                worker = threading.Thread(target=respond)
                worker.start()

                def client(*args, capture=False):
                    return subprocess.run(args, check=True, capture_output=capture,
                                          text=True, timeout=5)

                try:
                    with patch.object(network, "RUNTIME", runtime), \
                            patch.object(network, "load", return_value=config), \
                            patch.object(network, "check_isolation"), \
                            patch.object(network, "run"), \
                            patch.object(network, "ns", side_effect=client):
                        network.health(config)
                finally:
                    worker.join(timeout=6)
                self.assertEqual(len(replies), 1)
            self.assertEqual(list(runtime.glob("wpa_ctrl_*")), [])

    def test_valid_wireless_and_wired_configuration(self):
        config = fixture()
        self.assertIs(network.validate(config), config)
        del config["wifi"]
        self.assertIs(network.validate(config), config)

    def test_rejects_external_destinations_and_dns_escape(self):
        for key, target in (("events", "8.8.8.8"), ("events", "example.com"),
                            ("events", "::1"), ("events", "169.254.169.254"),
                            ("control", "192.168.71.10"), ("control", "127.0.0.1"),
                            ("control", "192.168.70.1"), ("events", "192.168.70.10")):
            with self.subTest(key=key, target=target):
                config = fixture()
                config["tcp"][key]["targetAddress"] = target
                with self.assertRaises(ValueError):
                    network.validate(config)
        config = fixture()
        config["dns"]["service.test"] = "8.8.8.8"
        with self.assertRaises(ValueError):
            network.validate(config)

    def test_no_configuration_injection(self):
        for target, key, value in (("top", "interface", "eth0\ncommand"),
                                   ("wifi", "countryCode", "US\nwpa=0"),
                                   ("wifi", "passphraseFile", "/tmp/key\n"),
                                   ("wifi", "passphraseFile", "/nix/store/plaintext")):
            config = fixture()
            (config if target == "top" else config[target])[key] = value
            with self.assertRaises(ValueError):
                network.validate(config)
        config = fixture()
        config["tcp"]["../bad"] = config["tcp"].pop("events")
        with self.assertRaises(ValueError):
            network.validate(config)
        config = fixture()
        config["dns"]["example.test\nserver=8.8.8.8"] = "192.168.70.1"
        with self.assertRaises(ValueError):
            network.validate(config)

    def test_rejects_unrecognized_fields_and_ambiguous_listeners(self):
        config = fixture()
        config["internet"] = True
        with self.assertRaises(ValueError):
            network.validate(config)
        config = fixture()
        config["tcp"]["duplicate"] = copy.deepcopy(config["tcp"]["events"])
        with self.assertRaises(ValueError):
            network.validate(config)
        for value in (0, 65536, True, "1883", 53):
            config = fixture()
            config["tcp"]["events"]["listenPort"] = value
            with self.assertRaises(ValueError):
                network.validate(config)

    def test_rejects_bad_subnets_and_dhcp_pools(self):
        for address in ("0.0.0.0/0", "8.8.8.1/24", "192.168.70.0/24", "192.168.70.255/24"):
            config = fixture()
            config["address"] = address
            with self.assertRaises(ValueError):
                network.validate(config)
        for start, end in (("192.168.70.0", "192.168.70.50"),
                           ("192.168.70.1", "192.168.70.50"),
                           ("192.168.70.100", "192.168.70.50"),
                           ("192.168.70.50", "192.168.71.50")):
            config = fixture()
            config["dhcp"] = {"start": start, "end": end}
            with self.assertRaises(ValueError):
                network.validate(config)

    def test_generator_activates_only_declared_grants(self):
        with tempfile.TemporaryDirectory() as temporary:
            network.generate(fixture(), temporary)
            directory = Path(temporary) / "device-network.target.wants"
            self.assertEqual({p.name for p in directory.iterdir()}, {
                "device-network-wifi.service", "device-network-host@events.service",
                "device-network-network@events.service", "device-network-host@control.service",
                "device-network-network@control.service",
            })
            self.assertEqual((directory / "device-network-host@events.service").readlink(),
                             Path("/etc/systemd/system/device-network-host@.service"))


if __name__ == "__main__":
    unittest.main()
