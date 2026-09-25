import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parent.parent / "scripts/factorio-prepare.py"
SPEC = importlib.util.spec_from_file_location("factorio_prepare", SCRIPT)
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.mods = self.root / "mods"
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.mod = {
            "name": "example", "version": "1.0.0", "file_name": "example_1.0.0.zip",
            "download_path": "/download/example/123abc",
            "sha256": hashlib.sha256(b"archive").hexdigest(),
        }
        (self.cache / self.mod["file_name"]).write_bytes(b"archive")

    def test_pins_verified_and_reused_offline_with_expansion(self):
        prepare.install_mods([self.mod], self.mods, None, self.cache)
        (self.cache / self.mod["file_name"]).unlink()
        with patch.object(prepare.urllib.request, "urlopen", side_effect=AssertionError("Network used")):
            prepare.install_mods([self.mod], self.mods, None)
        names = [mod["name"] for mod in json.loads((self.mods / "mod-list.json").read_text())["mods"]]
        self.assertIn("space-age", names)
        self.assertIn("example", names)

    def test_corrupt_download_never_replaces_verified_file_or_mod_list(self):
        prepare.install_mods([self.mod], self.mods, None, self.cache)
        original = (self.mods / "mod-list.json").read_bytes()
        changed = dict(self.mod, sha256="0" * 64)
        with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
            prepare.install_mods([changed], self.mods, None, self.cache)
        self.assertEqual((self.mods / self.mod["file_name"]).read_bytes(), b"archive")
        self.assertEqual((self.mods / "mod-list.json").read_bytes(), original)
        self.assertFalse(list(self.mods.glob(".download-*")))

    def test_network_exception_does_not_expose_authenticated_url(self):
        credentials = self.root / "credentials"
        credentials.write_text(json.dumps({"username": "user", "token": "sensitive-token"}))
        with patch.object(prepare.urllib.request, "urlopen", side_effect=OSError("https://host/?token=sensitive-token")):
            with self.assertRaisesRegex(RuntimeError, "Download failed") as raised:
                prepare.install_mods([self.mod], self.mods, credentials)
        self.assertNotIn("sensitive-token", str(raised.exception))
        self.assertTrue(raised.exception.__suppress_context__)
        self.assertFalse(list(self.mods.iterdir()))

    def test_metadata_cannot_escape_directory_or_portal(self):
        for change in [{"file_name": "../outside.zip"}, {"download_path": "https://evil.example/"}]:
            with self.assertRaises(ValueError):
                prepare.install_mods([dict(self.mod, **change)], self.mods, None, self.cache)

    def create(self, directory):
        (directory / "default.zip").write_bytes(b"new save")

    def test_new_world_replaces_unplayed_world_once_and_keeps_autosaves(self):
        (self.root / "saves").mkdir()
        (self.root / "saves/default.zip").write_bytes(b"old world")
        prepare.prepare_world(self.root, "modded-v1", self.create)
        self.assertTrue((self.root / "saves").is_symlink())
        self.assertEqual((self.root / "saves/default.zip").read_bytes(), b"new save")
        (self.root / "saves/_autosave1.zip").write_bytes(b"progress")
        with patch.object(self, "create", side_effect=AssertionError("World reset")):
            prepare.prepare_world(self.root, "modded-v1", self.create)
        self.assertEqual((self.root / "saves/_autosave1.zip").read_bytes(), b"progress")
        self.assertEqual((self.root / "saves-before-declarative-worlds/default.zip").read_bytes(), b"old world")

    def test_failed_creation_preserves_active_world_and_retries(self):
        prepare.prepare_world(self.root, "first", self.create)
        def fail(directory):
            (directory / "default.zip").write_bytes(b"incomplete")
            raise RuntimeError("Failed creation")
        with self.assertRaises(RuntimeError):
            prepare.prepare_world(self.root, "second", fail)
        self.assertEqual((self.root / "saves").resolve(), self.root / "worlds/first/saves")
        self.assertFalse((self.root / "worlds/second/saves").exists())
        prepare.prepare_world(self.root, "second", self.create)
        self.assertEqual((self.root / "saves").resolve(), self.root / "worlds/second/saves")
        # Selecting a previous identity restores its existing world.
        prepare.prepare_world(self.root, "first", fail)
        self.assertEqual((self.root / "saves").resolve(), self.root / "worlds/first/saves")


if __name__ == "__main__":
    unittest.main()
