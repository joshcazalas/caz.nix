#!/usr/bin/env python3
"""Provision private inputs from the running HA deployment without restarting it.

This migration uses Docker's installed Python/YAML parser, not a new host Python
dependency. Only the new private directory is written. It refuses conflicting
existing files and never prints values extracted from the running deployment.
"""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("prepare_ha_private", Path(__file__).with_name("prepare-ha-private.py"))
prepare_module = module_from_spec(spec)
spec.loader.exec_module(prepare_module)


def extract_household(package):
    script = package["script"]["apply_hvac_sun_schedule"]
    choice = next(s["choose"] for s in script["sequence"] if "choose" in s)[0]
    entities = [c["entity_id"] for c in choice["conditions"] if c.get("condition") == "state"]
    if not entities or any(c.get("state") != "cool" for c in choice["conditions"] if c.get("condition") == "state"):
        raise ValueError("Unsupported legacy thermostat conditions.")
    automation = next(a for a in package["automation"] if a["id"] == "hvac_sun_schedule")
    branches = next(a["choose"] for a in automation["actions"] if "choose" in a)
    values = {}
    for branch in branches:
        trigger = branch["conditions"][0]
        action = branch["sequence"][0]
        if trigger.get("condition") != "trigger" or action.get("action") != "script.apply_hvac_sun_schedule":
            raise ValueError("Unsupported legacy scheduling action.")
        values[trigger["id"]] = action["data"]["scheduled_temperature"]
    data = {"hvac_thermostats": entities, "hvac_day_temperature": values["sunrise"],
            "hvac_night_temperature": values["sunset"]}
    prepare_module.validate_inputs(data)
    template = next(s["variables"]["desired_temperature"] for s in script["sequence"] if "variables" in s)
    match = re.search(r"\{\{\s*([0-9.]+)\s+if is_state\('sun.sun', 'above_horizon'\) else ([0-9.]+)\s*\}\}", template)
    if not match or tuple(map(float, match.groups())) != (values["sunrise"], values["sunset"]):
        raise ValueError("Legacy automatic setpoints disagree; migration requires review.")
    return data


def run(*args, input_text=None):
    result = subprocess.run(args, input=input_text, capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        raise ValueError("A deployment inspection command failed; no raw output was disclosed.")
    return result.stdout


def write_private(path, content):
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600 or path.read_text() != content):
            raise ValueError("Existing private inputs differ or have unsafe permissions; nothing was overwritten.")
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as output:
        output.write(content)


def migrate(directory):
    inspect = json.loads(run("docker", "inspect", "homeassistant"))[0]
    if not inspect["State"]["Running"]:
        raise ValueError("Home Assistant must be running for this pre-deployment migration.")
    devices = [d for d in inspect["HostConfig"].get("Devices", []) if d["PathInContainer"] == "/dev/ttyZigbee"]
    if len(devices) != 1 or devices[0]["CgroupPermissions"] != "rw":
        raise ValueError("Expected one existing serial mapping with read/write permissions.")
    hardware = {"serial_device": devices[0]["PathOnHost"]}
    prepare_module.validate_hardware(hardware)
    legacy = run("docker", "exec", "homeassistant", "cat", "/config/packages/hvac.yaml")
    parsed = run("docker", "exec", "-i", "homeassistant", "python", "-c",
                 "import sys,json,yaml; print(json.dumps(yaml.safe_load(sys.stdin.read())))", input_text=legacy)
    inputs = extract_household(json.loads(parsed))
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("The private directory must already be root-only if it exists.")
    # JSON is valid YAML and avoids introducing a host YAML dependency.
    files = {"package-secrets.yaml": json.dumps(inputs, indent=2) + "\n",
             "hardware.json": json.dumps(hardware, indent=2) + "\n",
             "migration-source.yaml": legacy}
    for name, content in files.items():
        path = directory / name
        if path.exists() or path.is_symlink():
            # Validate all existing targets before writing any missing files.
            write_private(path, content)
    for name, content in files.items():
        write_private(directory / name, content)
    prepare_module.validate_inputs(prepare_module.private_json(directory / "package-secrets.yaml"))
    prepare_module.validate_hardware(prepare_module.private_json(directory / "hardware.json"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-dir", type=Path, default=Path("/var/lib/homelab/home-assistant-private"))
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run with sudo on the Home Assistant server.")
    os.umask(0o077)
    try:
        migrate(args.private_dir)
    except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.TimeoutExpired):
        print("Private HA migration could not be verified. Existing files were not overwritten; "
              "the running configuration was not changed. Review the source schema and private file permissions.", file=sys.stderr)
        return 1
    print("Private HA inputs provisioned and validated. No services, thermostat settings, or lock settings changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
