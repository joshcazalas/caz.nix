import importlib.util
from pathlib import Path
import os
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "storage", ROOT / "scripts/check-deployment-storage.py"
)
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.requirement = {
            "path": "/var/lib/example",
            "filesystem": {
                "mountPoint": "/",
                "device": "/dev/disk/by-label/ROOT",
                "fsType": "ext4",
            },
            "minimumFreeMiB": 2048,
            "minimumFreeInodes": 1024,
        }
        self.mount = {
            "target": "/",
            "fstype": "ext4",
            "maj:min": "8:1",
            "fsroot": "/",
            "vfs-options": "rw,relatime",
            "fs-options": "rw",
        }
        self.space = SimpleNamespace(
            f_bavail=524288,
            f_frsize=4096,
            f_files=100000,
            f_favail=1024,
        )
        for owner, name, value in [
            (storage.Path, "is_dir", True),
            (storage, "find_mount", self.mount),
            (storage.os, "access", True),
            (
                storage.os,
                "stat",
                SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(8, 1)),
            ),
            (storage.os, "statvfs", self.space),
        ]:
            mock = patch.object(owner, name, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)

    def check(self):
        return storage.check_path(self.requirement)

    def test_exact_capacity_and_inode_thresholds_pass(self):
        self.assertEqual(self.check(), [])

    def test_missing_directory_fails_without_querying_parent_mount(self):
        with patch.object(storage.Path, "is_dir", return_value=False):
            self.assertEqual(
                self.check(), ["required directory is missing or inaccessible"]
            )
        storage.find_mount.assert_not_called()

    def test_missing_efi_mount_does_not_accept_root_fallback(self):
        self.requirement["path"] = "/boot"
        self.requirement["filesystem"].update(mountPoint="/boot", fsType="vfat")
        self.assertIn("expected mount /boot, found /", self.check())

    def test_wrong_device_is_rejected_even_when_type_and_mount_match(self):
        self.mount["maj:min"] = "8:2"
        self.assertIn(
            "mounted device does not match /dev/disk/by-label/ROOT", self.check()
        )

    def test_read_only_vfs_or_superblock_is_rejected(self):
        for field in ("vfs-options", "fs-options"):
            with self.subTest(field=field):
                original = self.mount[field]
                self.mount[field] = "ro,relatime"
                self.assertIn("filesystem is read-only", self.check())
                self.mount[field] = original

    def test_available_space_uses_unreserved_blocks(self):
        self.space.f_bavail -= 1
        self.space.f_bfree = 900000
        self.assertIn("2047 MiB available; need at least 2048 MiB", self.check())

    def test_exhausted_inodes_are_rejected(self):
        self.space.f_favail = 0
        self.assertIn("0 inodes available; need at least 1024", self.check())

    def test_filesystems_without_an_inode_pool_are_allowed(self):
        self.space.f_files = 0
        self.space.f_favail = 0
        self.assertEqual(self.check(), [])

    def test_directory_permissions_are_checked(self):
        with patch.object(storage.os, "access", return_value=False):
            self.assertIn(
                "directory is not writable/searchable by the updater", self.check()
            )

    def test_nix_store_read_only_bind_is_allowed_but_not_read_only_disk(self):
        self.requirement["path"] = "/nix/store"
        self.mount.update(target="/nix/store", fsroot="/nix/store")
        self.mount["vfs-options"] = "ro,relatime"
        with patch.object(storage.os, "access", return_value=False):
            self.assertEqual(self.check(), [])
            self.mount["fs-options"] = "ro"
            self.assertIn("filesystem is read-only", self.check())

    def test_unexpected_store_bind_source_is_rejected(self):
        self.requirement["path"] = "/nix/store"
        self.mount.update(target="/nix/store", fsroot="/somewhere-else")
        self.assertIn("expected mount /, found /nix/store", self.check())

    def test_systemd_state_directory_self_bind_passes(self):
        self.requirement["path"] = "/var/lib/caz-release-updater"
        self.mount.update(target=self.requirement["path"], fsroot=self.requirement["path"])
        self.assertEqual(self.check(), [])

    def test_state_bind_keeps_source_device_access_and_capacity_checks(self):
        self.requirement["path"] = "/var/lib/caz-release-updater"
        self.mount.update(target=self.requirement["path"], fsroot=self.requirement["path"])
        for field, value, error in [
            ("fsroot", "/somewhere-else", "expected mount /"),
            ("maj:min", "8:2", "mounted device does not match"),
            ("fstype", "tmpfs", "expected filesystem type ext4"),
            ("vfs-options", "ro", "filesystem is read-only"),
            ("fs-options", "ro", "filesystem is read-only"),
        ]:
            with self.subTest(field=field), patch.dict(self.mount, {field: value}):
                self.assertTrue(any(error in failure for failure in self.check()))
        with patch.object(storage.os, "access", return_value=False):
            self.assertIn("directory is not writable/searchable by the updater", self.check())
        self.space.f_bavail = 0
        self.assertIn("0 MiB available; need at least 2048 MiB", self.check())

    def test_other_self_binds_remain_rejected(self):
        self.mount.update(target=self.requirement["path"], fsroot=self.requirement["path"])
        self.assertIn("expected mount /, found /var/lib/example", self.check())


if __name__ == "__main__":
    unittest.main()
