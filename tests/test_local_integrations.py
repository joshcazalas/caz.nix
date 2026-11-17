import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

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

    def test_backup_follows_only_required_private_file_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "project"
            directory.mkdir()
            key = Path(tmp) / "versioned key"
            key.touch()
            current = Path(tmp) / "current"
            current.symlink_to(key.name)
            (directory / "key").symlink_to(current)
            external_env = Path(tmp) / "runtime.env"
            external_env.touch()
            config = {"secrets": {"private": {"file": str(directory / "key")}},
                      "services": {"app": {"env_file": [{"path": str(external_env)},
                                                       {"path": str(directory / "optional"), "required": False}]}}}
            with patch.object(integrations.subprocess, "run", return_value=Mock(stdout="")):
                self.assertEqual(set(integrations.backup_paths(config, directory)),
                                 {directory, current, key, external_env})
                external_env.unlink()
                with self.assertRaises(integrations.BackupError):
                    integrations.backup_paths(config, directory)

    def test_backup_refuses_running_killed_or_unrecoverable_containers(self):
        config = {"services": {"app": {}}, "volumes": {"data": {"name": "private-data"}}}
        for state, code, oom, mounts in [
            ("running", 0, False, []), ("exited", 137, False, []), ("exited", 1, True, []),
            ("exited", 0, False, [{"Type": "volume", "Name": "anonymous"}]),
        ]:
            replies = [Mock(stdout="id"), Mock(stdout=json.dumps([state, code, oom, mounts]))]
            with self.subTest(state=state, code=code, oom=oom), self.assertRaises(integrations.BackupError), \
                    patch.object(integrations.subprocess, "run", side_effect=replies):
                integrations.backup_paths(config, Path("/unused"))

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
