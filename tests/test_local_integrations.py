import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "local_integrations", Path(__file__).parents[1] / "packages/device-network/local-integrations.py"
)
integrations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integrations)


def fixture():
    return {
        "networks": {"private": {"internal": True, "enable_ipv6": False}},
        "services": {"test": {
            "image": "sha256:" + "a" * 64, "networks": {"private": {}},
            "user": "1000:1000", "read_only": True, "cap_drop": ["ALL"],
            "security_opt": ["no-new-privileges:true"], "dns": ["127.0.0.1"],
            "volumes": [{"type": "bind", "source": "/var/lib/homelab/local-integrations/test.conf",
                         "target": "/config/test.conf", "read_only": True}],
        }},
    }


class IntegrationPolicyTests(unittest.TestCase):
    def test_valid_private_services(self):
        integrations.validate(fixture())

    def test_rejects_outbound_networks_and_privileges(self):
        for key, value in (("image", "example:latest"), ("network_mode", "host"),
                           ("privileged", True), ("ports", ["1883:1883"]),
                           ("user", "0"), ("user", "root"), ("cap_drop", []),
                           ("cap_add", ["NET_ADMIN"]), ("dns", ["8.8.8.8"]),
                           ("read_only", False), ("security_opt", []),
                           ("pid", "host"), ("networks", {"undeclared": {}})):
            with self.subTest(key=key):
                config = fixture()
                config["services"]["test"][key] = value
                with self.assertRaises(ValueError):
                    integrations.validate(config)
        for key, value in (("internal", False), ("enable_ipv6", True), ("external", True),
                           ("driver", "host"), ("driver_opts", {"parent": "eth0"})):
            config = fixture()
            config["networks"]["private"][key] = value
            with self.assertRaises(ValueError):
                integrations.validate(config)

    def test_rejects_host_sockets_and_external_volumes(self):
        config = fixture()
        config["services"]["test"]["volumes"][0]["source"] = "/run/docker.sock"
        with self.assertRaises(ValueError):
            integrations.validate(config)
        config["services"]["test"]["volumes"][0]["source"] = "/var/lib/homelab/local-integrations/../../../../run/docker.sock"
        with self.assertRaises(ValueError):
            integrations.validate(config)
        config = fixture()
        config["volumes"] = {"unsafe": {"driver_opts": {"device": "/", "type": "none", "o": "bind"}}}
        with self.assertRaises(ValueError):
            integrations.validate(config)
        config = copy.deepcopy(fixture())
        config["volumes"] = {"unsafe": {"external": True}}
        with self.assertRaises(ValueError):
            integrations.validate(config)


if __name__ == "__main__":
    unittest.main()
