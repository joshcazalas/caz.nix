#!/usr/bin/env python3
"""Validate private HA inputs and prepare one narrowly scoped serial alias."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys


def private_json(path, owner=0):
    """Read JSON (also valid YAML) without accepting links or loose permissions."""
    parent = path.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != owner or stat.S_IMODE(parent.st_mode) != 0o700:
        raise ValueError("Private configuration directory must be owner-only (0700).")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("Private configuration files must be owner-only (0600).")
        if info.st_size > 65536:
            raise ValueError("Private configuration is unexpectedly large.")
        return json.load(stream)


def validate_inputs(data):
    keys = {"hvac_thermostats", "hvac_day_temperature", "hvac_night_temperature"}
    if not isinstance(data, dict) or set(data) != keys:
        raise ValueError("Private package inputs have an unsupported schema.")
    entities = data["hvac_thermostats"]
    if (not isinstance(entities, list) or not 1 <= len(entities) <= 32
            or any(not isinstance(e, str) or not re.fullmatch(r"climate\.[a-z0-9_]+", e) for e in entities)
            or len(set(entities)) != len(entities)):
        raise ValueError("Configure distinct climate entities in the private inputs.")
    for key in ("hvac_day_temperature", "hvac_night_temperature"):
        value = data[key]
        if type(value) not in (int, float) or not 62 <= value <= 85:
            raise ValueError("Private cooling setpoints must be between 62 and 85 Fahrenheit.")


def validate_hardware(data):
    if not isinstance(data, dict) or set(data) != {"serial_device"}:
        raise ValueError("Private hardware selection has an unsupported schema.")
    source = data["serial_device"]
    if not isinstance(source, str) or not re.fullmatch(r"/dev/serial/by-id/[A-Za-z0-9_.+-]+", source):
        raise ValueError("Select a stable serial by-id device in private hardware configuration.")
    if not stat.S_ISCHR(Path(source).stat().st_mode):
        raise ValueError("The selected serial device is not a character device.")
    return source


def prepare(private_dir, runtime_dir, serial=False):
    validate_inputs(private_json(private_dir / "package-secrets.yaml"))
    if not serial:
        return
    source = validate_hardware(private_json(private_dir / "hardware.json"))
    info = runtime_dir.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("Hardware runtime directory must be root-only (0700).")
    # Only this fixed alias is replaced; never edit a device node or follow an
    # existing alias. systemd creates and owns the runtime directory.
    temporary = runtime_dir / "serial.new"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(source)
    temporary.replace(runtime_dir / "serial")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-dir", required=True, type=Path)
    parser.add_argument("--runtime-dir", required=True, type=Path)
    parser.add_argument("--serial", action="store_true")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run as root through the Home Assistant service.")
    try:
        prepare(args.private_dir, args.runtime_dir, args.serial)
    except (OSError, ValueError, TypeError):
        # Parsing errors and paths may contain private household identifiers.
        print("Private HA inputs are missing, invalid, insecure, or hardware is unavailable. "
              "Check the private configuration; no container was started.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
