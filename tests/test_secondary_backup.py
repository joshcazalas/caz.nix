"""Exercise backup copying and deletion boundaries with real rsync in a tempdir."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/copy-secondary-backups.sh"


class SecondaryBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.target = self.root / "target"
        self.target.mkdir()
        self.archives = {}
        for group, prefix in [
            ("minecraft", "minecraft"), ("factorio", "factorio"),
            ("caz-release-updater", "state"),
        ]:
            directory = self.source / group
            directory.mkdir(parents=True)
            archive = directory / f"{prefix}-20261106T120000Z.tar.zst"
            archive.write_bytes(b"completed archive content")
            self.archives[group] = archive
        self.env = {
            **os.environ,
            "CAZ_SECONDARY_BACKUP_MOUNT": str(self.target),
            "CAZ_SECONDARY_BACKUP_PREFLIGHT": shutil.which("true"),
            "CAZ_BACKUP_SOURCE_ROOT": str(self.source),
            "CAZ_MINECRAFT_BACKUP_DIR": str(self.source / "minecraft"),
            "CAZ_CONTAINER_MAINTENANCE_LOCK": str(self.root / "lock"),
        }

    def run_copy(self, success=True):
        result = subprocess.run(
            ["bash", str(SCRIPT)], env=self.env, capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_only_complete_regular_archives_are_copied_privately(self):
        directory = self.source / "minecraft"
        (directory / ".minecraft-backup.partial.tar.zst").write_bytes(b"incomplete")
        (directory / "minecraft-symlink.tar.zst").symlink_to(self.archives["minecraft"])
        (directory / "minecraft-directory.tar.zst").mkdir()
        self.run_copy()
        for group, archive in self.archives.items():
            copied = self.target / group / archive.name
            self.assertEqual(copied.read_bytes(), archive.read_bytes())
            self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
            self.assertEqual((self.target / group).stat().st_mode & 0o777, 0o700)
        self.assertEqual(len(list((self.target / "minecraft").iterdir())), 1)
        self.assertTrue((self.target / "last-success").exists())

    def test_failed_mount_preflight_writes_nothing(self):
        self.env["CAZ_SECONDARY_BACKUP_PREFLIGHT"] = shutil.which("false")
        self.run_copy(success=False)
        self.assertEqual(list(self.target.iterdir()), [])

    def test_empty_source_preserves_existing_second_copy(self):
        self.run_copy()
        before = (self.target / "last-success").read_bytes()
        archive = self.archives["minecraft"]
        archive.unlink()
        self.run_copy(success=False)
        self.assertTrue((self.target / "minecraft" / archive.name).exists())
        self.assertEqual((self.target / "last-success").read_bytes(), before)

    def test_retention_keeps_recent_and_primary_retained_archives(self):
        old_time = time.time() - 40 * 86400
        for archive in self.archives.values():
            os.utime(archive, (old_time, old_time))
        self.run_copy()
        directory = self.target / "minecraft"
        expired = directory / "minecraft-expired.tar.zst"
        expired.write_bytes(b"old backup")
        os.utime(expired, (old_time, old_time))
        recent = directory / "minecraft-recent.tar.zst"
        recent.write_bytes(b"recent backup no longer on primary")
        self.run_copy()
        self.assertFalse(expired.exists())
        self.assertTrue(recent.exists())
        self.assertTrue((directory / self.archives["minecraft"].name).exists())

    def test_same_size_and_time_corruption_is_repaired(self):
        self.run_copy()
        original = self.archives["minecraft"]
        copied = self.target / "minecraft" / original.name
        copied.write_bytes(b"x" * original.stat().st_size)
        os.utime(copied, ns=(original.stat().st_atime_ns, original.stat().st_mtime_ns))
        self.run_copy()
        self.assertEqual(copied.read_bytes(), original.read_bytes())

    def test_copy_failure_never_prunes_or_marks_success(self):
        directory = self.target / "minecraft"
        directory.mkdir()
        old = directory / "minecraft-old.tar.zst"
        old.write_bytes(b"only surviving backup")
        old_time = time.time() - 40 * 86400
        os.utime(old, (old_time, old_time))
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        failing_rsync = bin_dir / "rsync"
        failing_rsync.write_text("#!/usr/bin/env bash\nexit 23\n")
        failing_rsync.chmod(0o755)
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env["PATH"]
        self.run_copy(success=False)
        self.assertTrue(old.exists())
        self.assertFalse((self.target / "last-success").exists())


if __name__ == "__main__":
    unittest.main()
