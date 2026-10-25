#!/usr/bin/env python3
"""Run privately configured local integrations on the shared Docker runtime."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


def validate(config, directory=Path("/var/lib/homelab/local-integrations")):
    networks = config.get("networks", {})
    if not networks or any(n.get("internal") is not True or n.get("enable_ipv6", False)
                           or n.get("external", False) or n.get("driver", "bridge") != "bridge"
                           or n.get("driver_opts") for n in networks.values()):
        raise ValueError("Every integration network must be an internal IPv4 Docker bridge")
    services = config.get("services", {})
    if not services:
        raise ValueError("At least one integration service is required")
    volumes = config.get("volumes", {})
    if any(v.get("external") or v.get("driver_opts") or v.get("driver", "local") != "local"
           for v in volumes.values()):
        raise ValueError("Named volumes must be ordinary project-local Docker volumes")
    for service in services.values():
        if not re.fullmatch(r"(?:[^\s]+@)?sha256:[0-9a-f]{64}", service.get("image", "")):
            raise ValueError("Integration images must be pinned by digest or local image ID")
        attached = service.get("networks", {})
        if not attached or not set(attached) <= networks.keys():
            raise ValueError("Each integration must attach only to declared internal networks")
        if any(service.get(key) for key in ("build", "network_mode", "privileged", "ports", "devices",
                                            "cap_add", "pid", "ipc", "external_links", "use_api_socket")):
            raise ValueError("Host networking, ports, hardware and privilege grants are not supported")
        if (set(service.get("cap_drop", [])) != {"ALL"}
                or not service.get("read_only")
                or "no-new-privileges:true" not in service.get("security_opt", [])
                or service.get("dns") != ["127.0.0.1"]):
            raise ValueError("Integrations require read-only roots, dropped capabilities and local-only DNS")
        user = str(service.get("user", "")).split(":")[0]
        if not user.isdigit() or int(user) == 0:
            raise ValueError("Integrations require an explicit non-root numeric user")
        for volume in service.get("volumes", []):
            if volume.get("type") == "bind":
                source = Path(volume.get("source", ""))
                if ".." in source.parts or not source.is_relative_to(directory) or source == directory:
                    raise ValueError("Bind mounts must remain beneath the private integration directory")
            if volume.get("type") == "volume" and volume.get("source") not in volumes:
                raise ValueError("Named volumes must be declared in this project")
    return config


def compose(directory, *args, capture=False, check=True):
    return subprocess.run(["docker", "compose", "--project-name", "local-integrations",
                           "--file", str(directory / "compose.yaml"), *args],
                          cwd=directory, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", default="/var/lib/homelab/local-integrations")
    parser.add_argument("command", choices=("validate", "start", "stop", "health"))
    args = parser.parse_args()
    directory = Path(args.directory)
    if args.command == "stop":
        ids = subprocess.run(["docker", "ps", "--all", "--filter",
                              "label=com.docker.compose.project=local-integrations", "--format", "{{.ID}}"],
                             check=True, capture_output=True, text=True).stdout.splitlines()
        if ids:
            subprocess.run(["docker", "stop", "--time", "30", *ids], check=True)
        return
    info = (directory / "compose.yaml").lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("Compose configuration must be a regular root-owned mode 0600 file")
    config = validate(json.loads(compose(directory, "config", "--format", "json", capture=True).stdout), directory)
    if args.command == "start":
        # Immutable image archives preserve private patched builds through image
        # pruning, without publishing their source or allowing runtime pulls.
        for image in {service["image"] for service in config["services"].values()}:
            result = subprocess.run(["docker", "image", "inspect", image], capture_output=True)
            if result.returncode:
                archive = directory / "images" / (image.rsplit("sha256:", 1)[1] + ".tar")
                subprocess.run(["docker", "load", "--input", str(archive)], check=True, stdout=subprocess.DEVNULL)
                subprocess.run(["docker", "image", "inspect", image], check=True, stdout=subprocess.DEVNULL)
        os.chdir(directory)
        os.execlp("docker", "docker", "compose", "--project-name", "local-integrations",
                  "--file", str(directory / "compose.yaml"), "up", "--no-build", "--pull", "never",
                  "--abort-on-container-exit", "--remove-orphans")
    elif args.command == "health":
        statuses = [json.loads(line) for line in compose(directory, "ps", "--all", "--format", "json", capture=True).stdout.splitlines()]
        healthy = {item["Service"] for item in statuses
                   if item["State"] == "running" and item.get("Health", "") in ("", "healthy")}
        if healthy != config["services"].keys():
            raise ValueError("A configured local integration is not healthy")
        ids = [item["ID"] for item in statuses]
        containers = json.loads(subprocess.run(["docker", "inspect", *ids], check=True, capture_output=True, text=True).stdout)
        network_ids = {value["NetworkID"] for container in containers
                       for value in container["NetworkSettings"]["Networks"].values()}
        if not network_ids:
            raise ValueError("Integration containers have no isolated network")
        actual_networks = json.loads(subprocess.run(["docker", "network", "inspect", *network_ids],
                                                   check=True, capture_output=True, text=True).stdout)
        if any(not value["Internal"] or value["EnableIPv6"] for value in actual_networks):
            raise ValueError("An integration container has an unexpected network connection")
        print("Local integrations: all configured containers running")
    else:
        print("Private integration configuration is valid")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError):
        print("Local integrations failed validation or execution; inspect private service state.", file=sys.stderr)
        sys.exit(1)
