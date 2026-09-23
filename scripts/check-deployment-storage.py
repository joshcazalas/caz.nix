#!/usr/bin/env python3
"""Check deployment storage without writing files or changing mounts."""

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def find_mount(path):
    result = subprocess.run(
        [
            "findmnt",
            "--json",
            "--target",
            path,
            "--output",
            "TARGET,FSTYPE,MAJ:MIN,FSROOT,VFS-OPTIONS,FS-OPTIONS",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    mounts = json.loads(result.stdout)["filesystems"]
    if len(mounts) != 1:
        raise ValueError("expected one containing filesystem")
    return mounts[0]


def check_path(requirement):
    path = requirement["path"]
    if not Path(path).is_dir():
        return ["required directory is missing or inaccessible"]

    mount = find_mount(path)
    expected = requirement["filesystem"]
    # NixOS can bind-mount the store read-only for clients. The daemon still
    # writes through its own mount namespace, on the same declared filesystem.
    store_bind = (
        path == "/nix/store"
        and mount["target"] == path
        and mount["fsroot"] == path
        and expected["mountPoint"] == "/"
    )
    # StateDirectory= creates a self-bind inside the updater's systemd mount
    # namespace. Accept only this known directory on our declared root disk;
    # a different source, device, or read-only bind must still fail below.
    state_bind = (
        path == "/var/lib/caz-release-updater"
        and mount["target"] == path
        and mount["fsroot"] == path
        and expected["mountPoint"] == "/"
    )
    failures = []
    if mount["target"] != expected["mountPoint"] and not (store_bind or state_bind):
        failures.append(
            f"expected mount {expected['mountPoint']}, found {mount['target']}"
        )
    if mount["fstype"] != expected["fsType"]:
        failures.append(
            f"expected filesystem type {expected['fsType']}, found {mount['fstype']}"
        )
    device = os.stat(expected["device"])
    if not stat.S_ISBLK(device.st_mode):
        failures.append(f"configured device {expected['device']} is not a block device")
    elif mount["maj:min"] != f"{os.major(device.st_rdev)}:{os.minor(device.st_rdev)}":
        failures.append(f"mounted device does not match {expected['device']}")

    vfs_options = set((mount["vfs-options"] or "").split(","))
    fs_options = set((mount["fs-options"] or "").split(","))
    if "ro" in fs_options or ("ro" in vfs_options and not store_bind):
        failures.append("filesystem is read-only")
    if not store_bind and not os.access(path, os.W_OK | os.X_OK):
        failures.append("directory is not writable/searchable by the updater")

    space = os.statvfs(path)
    available_mib = space.f_bavail * space.f_frsize // (1024 * 1024)
    if available_mib < requirement["minimumFreeMiB"]:
        failures.append(
            f"{available_mib} MiB available; need at least {requirement['minimumFreeMiB']} MiB"
        )
    # FAT and some other filesystems do not report a finite inode pool.
    if space.f_files > 0 and space.f_favail < requirement["minimumFreeInodes"]:
        failures.append(
            f"{space.f_favail} inodes available; need at least {requirement['minimumFreeInodes']}"
        )
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    requirements = json.loads(args.config.read_text())
    failed = False
    for requirement in requirements:
        try:
            failures = check_path(requirement)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            failures = [f"cannot inspect storage ({type(error).__name__})"]
        for failure in failures:
            print(
                f"Storage preflight: {requirement['path']}: {failure}", file=sys.stderr
            )
            failed = True
    if failed:
        print(
            "Refusing deployment: restore the configured mounts or free space, then retry. "
            "No mounts or files were changed by this check.",
            file=sys.stderr,
        )
        return 1
    print("Deployment storage preflight passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
