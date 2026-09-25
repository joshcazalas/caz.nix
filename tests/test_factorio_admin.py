import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parent.parent / "scripts/factorio-admin.py"
SPEC = importlib.util.spec_from_file_location("factorio_admin", SCRIPT)
admin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(admin)


class FactorioAdministrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.state.mkdir()
        admin.initialize(self.state)
        self.commands = []
        self.active = "active"
        self.stop_result = "success"
        self.fail_archive = False
        self.real_run = subprocess.run

        def output(command, **kwargs):
            if "--property=ActiveState" in command:
                return self.active + "\n"
            if "--property=Result" in command:
                return self.stop_result + "\n"
            raise AssertionError(command)

        def run(command, **kwargs):
            self.commands.append(command)
            if command[0] == "tar":
                if self.fail_archive:
                    raise subprocess.CalledProcessError(1, command)
                return self.real_run(command, **kwargs)
            return subprocess.CompletedProcess(command, 0)

        self.patches = [
            patch.object(admin.subprocess, "check_output", side_effect=output),
            patch.object(admin.subprocess, "run", side_effect=run),
        ]
        for mock in self.patches:
            mock.start()
            self.addCleanup(mock.stop)

    def test_first_boot_and_reinitialization_preserve_membership(self):
        self.assertEqual(admin.read_players(self.state / "server-whitelist.json"), [admin.GUARD])
        admin.access(self.state, "whitelist", "add", "Friend")
        admin.access(self.state, "operator", "add", "Friend")
        admin.initialize(self.state)
        self.assertIn("Friend", admin.read_players(self.state / "server-whitelist.json"))
        self.assertEqual(admin.read_players(self.state / "server-adminlist.json"), ["Friend"])
        self.assertEqual(self.commands, [
            ["systemctl", "stop", admin.UNIT], ["systemctl", "start", admin.UNIT],
            ["systemctl", "stop", admin.UNIT], ["systemctl", "start", admin.UNIT],
        ])

    def test_last_player_removal_retains_banned_guard(self):
        admin.access(self.state, "whitelist", "add", "Friend")
        admin.access(self.state, "whitelist", "remove", "Friend")
        self.assertEqual(admin.read_players(self.state / "server-whitelist.json"), [admin.GUARD])
        bans = admin.read_list(self.state / "server-banlist.json")
        self.assertTrue(any(ban["username"] == admin.GUARD for ban in bans))

    def test_operator_requires_membership_and_blocks_whitelist_removal(self):
        with self.assertRaisesRegex(ValueError, "before granting"):
            admin.access(self.state, "operator", "add", "Friend")
        admin.access(self.state, "whitelist", "add", "Friend")
        admin.access(self.state, "operator", "add", "Friend")
        with self.assertRaisesRegex(ValueError, "Remove operator"):
            admin.access(self.state, "whitelist", "remove", "Friend")
        self.assertEqual(self.commands[-1], ["systemctl", "start", admin.UNIT])

    def test_corrupt_membership_is_not_silently_reset(self):
        path = self.state / "server-whitelist.json"
        path.write_text('{"broken": true}')
        with self.assertRaises(ValueError):
            admin.access(self.state, "whitelist", "add", "Friend")
        self.assertEqual(path.read_text(), '{"broken": true}')
        self.assertEqual(self.commands[-1], ["systemctl", "start", admin.UNIT])

    def test_failed_shutdown_does_not_edit_membership(self):
        self.stop_result = "timeout"
        with self.assertRaisesRegex(RuntimeError, "did not stop cleanly"):
            admin.access(self.state, "whitelist", "add", "Friend")
        self.assertEqual(admin.read_players(self.state / "server-whitelist.json"), [admin.GUARD])
        self.assertEqual(self.commands[-1], ["systemctl", "start", admin.UNIT])

    def test_offline_edits_do_not_start_the_game(self):
        self.active = "inactive"
        admin.access(self.state, "whitelist", "add", "Friend")
        self.assertEqual(self.commands, [])

    def test_names_match_case_insensitively_after_game_normalization(self):
        admin.write_json(self.state / "server-whitelist.json", [admin.GUARD, "friend"])
        admin.access(self.state, "whitelist", "add", "Friend")
        self.assertEqual(admin.read_players(self.state / "server-whitelist.json"), [admin.GUARD, "friend"])
        admin.access(self.state, "operator", "add", "Friend")
        with self.assertRaises(ValueError):
            admin.access(self.state, "whitelist", "remove", "FRIEND")
        admin.access(self.state, "operator", "remove", "FRIEND")
        admin.access(self.state, "whitelist", "remove", "FRIEND")
        self.assertEqual(admin.read_players(self.state / "server-whitelist.json"), [admin.GUARD])

    def make_save(self):
        (self.state / "saves").mkdir()
        (self.state / "saves/default.zip").write_bytes(b"a saved factory")

    def test_backup_follows_state_directory_link_and_can_be_restored(self):
        self.make_save()
        world = self.state / "worlds/modded-v1"
        world.mkdir(parents=True)
        (self.state / "saves").rename(world / "saves")
        (self.state / "saves").symlink_to("worlds/modded-v1/saves", target_is_directory=True)
        alias = self.root / "factorio"
        alias.symlink_to(self.state, target_is_directory=True)
        backups = self.root / "backups"
        admin.backup(alias, backups)
        archive = next(backups.glob("*.tar.zst"))
        restored = self.root / "restored"
        restored.mkdir()
        self.real_run(["tar", "--extract", "--zstd", "--file", str(archive),
                       "--directory", str(restored)], check=True)
        self.assertEqual((restored / "saves/default.zip").read_bytes(), b"a saved factory")
        self.assertTrue((restored / "saves").is_symlink())
        self.assertIn(admin.GUARD, admin.read_players(restored / "server-whitelist.json"))
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.commands[-1], ["systemctl", "start", admin.UNIT])

    def test_archive_failure_restarts_game_and_retains_previous_backups(self):
        self.make_save()
        backups = self.root / "backups"
        backups.mkdir()
        previous = backups / "factorio-old.tar.zst"
        previous.write_bytes(b"previous backup")
        self.fail_archive = True
        with self.assertRaises(subprocess.CalledProcessError):
            admin.backup(self.state, backups)
        self.assertEqual(list(backups.iterdir()), [previous])
        self.assertEqual(self.commands[-1], ["systemctl", "start", admin.UNIT])

    def test_backup_refuses_missing_world(self):
        with self.assertRaisesRegex(RuntimeError, "No Factorio save"):
            admin.backup(self.state, self.root / "backups")
        self.assertEqual(self.commands[-1], ["systemctl", "start", admin.UNIT])

    def test_atomic_membership_files_are_private(self):
        admin.access(self.state, "whitelist", "add", "Friend")
        self.assertEqual((self.state / "server-whitelist.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.state.glob(".*")), [])

    def test_health_requires_socket_owned_by_factorio_and_banned_guard(self):
        for pid, socket, healthy in (
            ("123", "UNCONN 0 0 0.0.0.0:34197 users:((factorio,pid=123,fd=4))", True),
            ("123", "UNCONN 0 0 0.0.0.0:34197 users:((other,pid=456,fd=4))", False),
            ("0", "", False),
        ):
            with self.subTest(pid=pid, socket=socket):
                with patch.object(admin.subprocess, "check_output", side_effect=[pid, socket]):
                    if healthy:
                        admin.health(self.state, 34197)
                    else:
                        with self.assertRaises(RuntimeError):
                            admin.health(self.state, 34197)
        admin.write_json(self.state / "server-banlist.json", [])
        with patch.object(admin.subprocess, "check_output", side_effect=["123", "pid=123,"]):
            with self.assertRaisesRegex(RuntimeError, "not banned"):
                admin.health(self.state, 34197)


if __name__ == "__main__":
    unittest.main()
