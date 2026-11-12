"""Validation tests for private network policy, using synthetic configuration."""

import copy
import importlib.util
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import threading
from types import SimpleNamespace
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
                            patch.object(network, "check_proxy_listeners"), \
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


class HardeningTests(unittest.TestCase):
    def test_reservations_are_unique_unicast_and_outside_pool(self):
        config = fixture()
        config["dhcp"]["reservations"] = {"02:00:00:00:00:AB": "192.168.70.11"}
        self.assertIs(network.validate(config), config)
        invalid = [
            {"02:00:00:00:00:ab": "192.168.70.20"},
            {"02:00:00:00:00:ab": "192.168.70.1"},
            {"02:00:00:00:00:ab": "192.168.71.11"},
            {"02:00:00:00:00:ab": "192.168.70.0"},
            {"02:00:00:00:00:ab": "192.168.70.255"},
            {"03:00:00:00:00:ab": "192.168.70.11"},
            {"00:00:00:00:00:00": "192.168.70.11"},
            {"02:00:00:00:00:ab\n": "192.168.70.11"},
            {"02:00:00:00:00:ab": "192.168.70.11", "02:00:00:00:00:AB": "192.168.70.12"},
            {"02:00:00:00:00:ab": "192.168.70.11", "02:00:00:00:00:ac": "192.168.70.11"},
        ]
        for reservations in invalid:
            with self.subTest(reservations=reservations):
                config["dhcp"]["reservations"] = reservations
                with self.assertRaises(ValueError):
                    network.validate(config)

    def test_same_port_on_distinct_loopback_addresses(self):
        config = fixture()
        config["tcp"]["control"].update(listenAddress="127.0.0.2", listenPort=443)
        config["tcp"]["second"] = dict(config["tcp"]["control"], listenAddress="127.0.0.3")
        self.assertIs(network.validate(config), config)
        config["tcp"]["second"]["listenAddress"] = "127.0.0.2"
        with self.assertRaises(ValueError):
            network.validate(config)
        del config["tcp"]["second"]
        for address in ("0.0.0.0", "192.168.71.1", "::1", "localhost", "127.0.0.2,reuseaddr"):
            config["tcp"]["control"]["listenAddress"] = address
            with self.subTest(address=address), self.assertRaises(ValueError):
                network.validate(config)

    def test_sources_are_individual_device_addresses(self):
        config = fixture()
        config["tcp"]["events"]["sourceAddresses"] = ["192.168.70.10", "192.168.70.11"]
        self.assertIs(network.validate(config), config)
        for sources in ([], "192.168.70.10", ["192.168.70.0/24"], ["192.168.70.1"],
                        ["192.168.71.10"], ["192.168.70.10", "192.168.70.10"]):
            config["tcp"]["events"]["sourceAddresses"] = sources
            with self.subTest(sources=sources), self.assertRaises(ValueError):
                network.validate(config)
        config = fixture()
        config["tcp"]["control"]["sourceAddresses"] = ["192.168.70.10"]
        with self.assertRaises(ValueError):
            network.validate(config)
        config = fixture()
        config["tcp"]["events"]["listenAddress"] = "127.0.0.2"
        with self.assertRaises(ValueError):
            network.validate(config)

    def test_prepare_writes_reservation_without_changing_dynamic_pool(self):
        config = fixture()
        config["dhcp"]["reservations"] = {"02:00:00:00:00:AB": "192.168.70.11"}
        del config["wifi"]
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            with patch.object(network, "RUNTIME", runtime), \
                    patch.object(Path, "lstat", return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o700)), \
                    patch.object(network, "run"):
                network.prepare(config)
            text = (runtime / "dnsmasq.conf").read_text()
            self.assertIn("dhcp-host=02:00:00:00:00:ab,192.168.70.11\n", text)
            self.assertIn("dhcp-range=192.168.70.20,192.168.70.50,255.255.255.0,12h\n", text)

    @staticmethod
    def saved_rules():
        # Representative iptables-save output, independent of the rule builder.
        return """# Generated by iptables-save
*filter
:INPUT DROP [8:640]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [1:80]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i wlan-test -p udp -m udp --sport 68 --dport 67 -j ACCEPT
-A INPUT -s 192.168.70.0/24 -d 192.168.70.1/32 -i wlan-test -p udp -m udp --dport 53 -j ACCEPT
-A INPUT -s 192.168.70.0/24 -d 192.168.70.1/32 -i wlan-test -p tcp -m tcp --dport 53 -j ACCEPT
-A INPUT -s 192.168.70.10/32 -d 192.168.70.1/32 -i wlan-test -p tcp -m tcp --dport 8883 -j ACCEPT
COMMIT
"""

    def test_full_firewall_policy_and_drift_detection(self):
        config = fixture()
        config["tcp"]["events"]["sourceAddresses"] = ["192.168.70.10"]
        saved = self.saved_rules()
        network.check_firewall(config, saved)
        variations = [
            saved.replace("COMMIT", "-A INPUT -j ACCEPT\nCOMMIT"),
            saved.replace("COMMIT", "-A FORWARD -j ACCEPT\nCOMMIT"),
            saved.replace(":INPUT DROP", ":INPUT ACCEPT"),
            saved.replace("-s 192.168.70.10/32", "-s 192.168.70.0/24"),
            saved.replace("--dport 8883", "--dport 8123"),
            saved.replace(":FORWARD DROP", ":UNUSED - [0:0]\n:FORWARD DROP"),
            saved + "*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -j MASQUERADE\nCOMMIT\n",
            saved + "*raw\n:PREROUTING ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A PREROUTING -j NOTRACK\nCOMMIT\n",
        ]
        for drifted in variations:
            with self.subTest(drifted=drifted), self.assertRaises(ValueError):
                network.check_firewall(config, drifted)
        network.check_firewall(config, saved + "*nat\n:PREROUTING ACCEPT [0:0]\n:INPUT ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\nCOMMIT\n")

    def test_listener_ownership_binding_and_socket_permissions(self):
        config = fixture()
        config["tcp"] = {"control": dict(config["tcp"]["control"], listenAddress="127.0.0.2", listenPort=443)}

        def verify(binding="127.0.0.2:443", process="pid=123", mode=0o600, extra=""):
            def command(*args, capture=False):
                if args[:2] == ("systemctl", "list-units"):
                    out = "device-network-host@control.service loaded active running\ndevice-network-network@control.service loaded active running\n" + extra
                elif args[:2] == ("systemctl", "show"):
                    out = "123\n"
                elif args[0] == "ss":
                    out = f'LISTEN 0 5 {binding} 0.0.0.0:* users:(("socat",{process},fd=5))\n'
                else:
                    raise AssertionError(args)
                return SimpleNamespace(stdout=out)
            with patch.object(network, "run", side_effect=command), \
                    patch.object(Path, "lstat", return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFSOCK | mode)):
                network.check_proxy_listeners(config)
        verify()
        for binding in ("0.0.0.0:443", "127.0.0.1:443", "127.0.0.2:444", "[::]:443"):
            with self.subTest(binding=binding), self.assertRaises(ValueError):
                verify(binding=binding)
        with self.assertRaises(ValueError):
            verify(process="pid=124")
        with self.assertRaises(ValueError):
            verify(mode=0o666)
        with self.assertRaises(ValueError):
            verify(extra="device-network-host@removed.service loaded active running\n")

    def test_proxy_binds_only_the_selected_loopback_endpoint(self):
        config = fixture()
        config["tcp"]["control"].update(listenAddress="127.0.0.2", listenPort=443)
        with patch.object(network.os, "execlp") as execute:
            network.proxy(config, "host", "control")
        self.assertEqual(execute.call_args.args[2], "TCP4-LISTEN:443,bind=127.0.0.2,reuseaddr,fork,max-children=64")


if __name__ == "__main__":
    unittest.main()
