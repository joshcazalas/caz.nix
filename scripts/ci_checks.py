"""Select CI work conservatively and validate ownership of every flake check."""

import argparse
from fnmatch import fnmatchcase
import json
import subprocess
import sys


INTEGRATION_SHARDS = {
    "devices": ("device-network", "device-network-config"),
    "gateways": ("game-stream-gateway", "home-access-gateway", "network-policy"),
    "services": ("ha-bluetooth", "network-readiness", "deployment-storage-integration"),
}
INTEGRATION_CHECKS = {check for checks in INTEGRATION_SHARDS.values() for check in checks}
HOMESERVER_CHECKS = {
    "homeserver", "release-downloads", "release-notifications", "deployment-storage",
    "server-health", "factorio", "website-updater", "ha-private", "ha-integrations",
    "container-pins", "schlage-local",
}
COMPONENTS = ("homeserver", "wsl", "windows", "esphome")

# First match wins. Shared inputs and unfamiliar paths select everything.
# Keep source files and their direct test fixtures together. Changes to this
# policy run everything, and validation rejects unassigned flake checks.
RULES = [
    ((".github/workflows/ci.yml", "scripts/ci_checks.py", "scripts/classify-ci-changes.sh",
      "scripts/build-ci-check-group.sh", "tests/test_ci_checks.py", "flake.nix", "flake.lock",
      "settings.nix"), ("all",)),
    (("README.md", "SECURITY.md", "LICENSE", "docs/*", "*/README.md"), ()),
    ((".github/actions/cache-auxide/*",), ("homeserver",)),
    (("modules/nixos/game-stream-gateway.nix",), ("homeserver", "game-stream-gateway")),
    (("modules/nixos/home-access-gateway.nix",), ("homeserver", "home-access-gateway")),
    (("modules/nixos/network-policy.nix", "modules/nixos/website.nix", "packages/website-updater/*"),
     ("homeserver", "network-policy")),
    (("modules/nixos/networking.nix", "modules/nixos/auxide.nix"),
     ("homeserver", "network-readiness")),
    (("modules/nixos/device-network.nix", "modules/nixos/local-integrations.nix",
      "packages/device-network/*"), ("homeserver", "device-network", "device-network-config")),
    (("modules/nixos/home-assistant.nix", "home-assistant/*", "packages/home-assistant-integrations/*",
      "scripts/prepare-ha-private.py"), ("homeserver", "ha-bluetooth")),
    (("modules/nixos/container-runtime.nix", "modules/nixos/base.nix", "modules/nixos/security.nix",
      "secrets/*"), ("all",)),
    (("hosts/homeserver/*",), ("homeserver",)),
    # Only known server-only modules may skip integration tests. A new module
    # falls back to all rather than silently assuming it has no test consumers.
    (("modules/nixos/monitoring*.nix", "modules/nixos/jellyfin.nix", "modules/nixos/secondary-backup.nix",
      "modules/nixos/optional-services.nix", "modules/nixos/bluemap.nix", "modules/nixos/filesharing.nix",
      "modules/nixos/storage.nix", "modules/nixos/release-updater.nix", "modules/nixos/factorio.nix",
      "modules/nixos/factorio-mods.json", "modules/nixos/cloudflare-ddns.nix",
      "modules/nixos/minecraft.nix", "modules/nixos/adguard-home.nix"), ("homeserver",)),
    (("containers/*",), ("homeserver", "ha-bluetooth")),
    (("hosts/cazpc/*", "modules/home/development.nix", "modules/home/ssh.nix",
      "modules/home/windows-vscode.nix"), ("wsl",)),
    (("modules/home/*",), ("homeserver", "wsl")),
    (("scripts/stage-server-release.sh", "scripts/check-deployment-storage.py"),
     ("homeserver", "deployment-storage-integration")),
    (("scripts/check-server-health.sh", "scripts/pre-deploy-backup.sh", "scripts/copy-secondary-backups.sh",
      "scripts/release-notifications.py", "scripts/factorio-*.py", "scripts/migrate-ha-private.py"),
     ("homeserver",)),
    (("scripts/prepare-esphome-proxy.py",), ("homeserver", "esphome")),
    (("esphome/*", "tests/esphome_config.py"), ("esphome",)),
    (("tests/game-stream-gateway.nix",), ("game-stream-gateway",)),
    (("tests/home-access-gateway.nix",), ("home-access-gateway",)),
    (("tests/network-policy.nix",), ("network-policy",)),
    (("tests/network-readiness.nix",), ("network-readiness",)),
    (("tests/deployment-storage.nix",), ("deployment-storage-integration",)),
    (("tests/ha-bluetooth.nix", "tests/ha_bluetooth_probe.py"), ("ha-bluetooth",)),
    (("tests/device-network.nix",), ("device-network",)),
    (("tests/test_device_network.py", "tests/test_local_integrations.py"), ("device-network-config",)),
    (("tests/test_ha_private.py", "tests/ha_integrations.py", "tests/container_pins.py",
      "tests/test_schlage_local.py", "tests/test_secondary_backup.py", "tests/test_deployment_storage.py",
      "tests/test_release_downloads.py", "tests/test_release_notifications.py", "tests/test_server_health.py",
      "tests/test_factorio_admin.py", "tests/test_factorio_prepare.py", "tests/factorio-runtime.py"),
     ("homeserver",)),
    (("windows/*", "scripts/check-windows.ps1", "scripts/test-windows-launcher.sh", "bootstrap/windows.sh",
      "bootstrap/windows.ps1", "bootstrap/windows-vscode.ps1", "bootstrap/windows-game-stream.ps1"),
     ("windows",)),
    ((".gitignore", ".sops.yaml", ".sops.yaml.example", "statix.toml", ".github/dependabot.yml",
      ".github/workflows/release.yml", "bootstrap/wsl.sh", "scripts/build-release-artifacts.sh",
      "scripts/check.sh", "scripts/publish-release.sh", "scripts/secret-scan.sh"), ()),
]


def classify(paths, all_checks=False):
    selected = set()
    for path in paths:
        for patterns, targets in RULES:
            if any(fnmatchcase(path, pattern) for pattern in patterns):
                selected.update(targets)
                break
        else:
            print(f"Unclassified path changed; running every component: {path!r}", file=sys.stderr)
            selected.add("all")
    if all_checks or not paths or "all" in selected:
        selected.update(COMPONENTS)
        selected.update(INTEGRATION_CHECKS)
    matrix = {"include": [
        {"name": name, "checks": [check for check in checks if check in selected]}
        for name, checks in INTEGRATION_SHARDS.items() if any(check in selected for check in checks)
    ]}
    return {
        **{component: component in selected for component in COMPONENTS},
        "integration": bool(matrix["include"]),
        "integration_matrix": matrix,
    }


def check_group(name):
    if name in HOMESERVER_CHECKS:
        return "homeserver"
    if name in INTEGRATION_CHECKS:
        return "integration"
    if name.startswith("wsl-"):
        return "wsl"
    raise ValueError(f"Flake check {name!r} has no CI group; assign it in scripts/ci_checks.py.")


def select_checks(declared, group, requested=None):
    # Validate all declared checks, even when building just one component.
    groups = {name: check_group(name) for name in declared}
    missing = INTEGRATION_CHECKS - groups.keys()
    if missing:
        raise ValueError(f"Integration matrix references missing flake checks: {sorted(missing)}")
    if group == "validate":
        return []
    if requested is None:
        return [name for name, owner in groups.items() if owner == group]
    if group != "integration" or not isinstance(requested, list) or not requested:
        raise ValueError("A nonempty check list is supported only for the integration group.")
    if any(not isinstance(name, str) or groups.get(name) != group for name in requested):
        raise ValueError(f"Invalid integration check selection: {requested!r}")
    if len(set(requested)) != len(requested):
        raise ValueError("Duplicate integration checks in selection.")
    return requested


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    classify_parser = commands.add_parser("classify")
    classify_parser.add_argument("--all", action="store_true")
    build_parser = commands.add_parser("build")
    build_parser.add_argument("group", choices=("validate", "homeserver", "wsl", "integration"))
    build_parser.add_argument("--checks-json")
    args = parser.parse_args()
    if args.command == "classify":
        raw = b"" if args.all else sys.stdin.buffer.read()
        if raw and not raw.endswith(b"\0"):
            parser.error("Changed paths must be NUL-delimited.")
        paths = [path.decode("utf-8", errors="surrogateescape") for path in raw.split(b"\0") if path]
        result = classify(paths, args.all)
        for key, value in result.items():
            print(f"{key}={json.dumps(value, separators=(',', ':'))}")
        return
    declared = json.loads(subprocess.check_output([
        "nix", "eval", "--json", ".#checks.x86_64-linux", "--apply", "builtins.attrNames",
    ], text=True))
    requested = json.loads(args.checks_json) if args.checks_json is not None else None
    if args.checks_json is not None and not isinstance(requested, list):
        parser.error("--checks-json must contain a JSON array.")
    selected = select_checks(declared, args.group, requested)
    if args.group == "validate":
        print("Every flake check belongs to a CI group and every integration check has a shard.")
    elif selected:
        print(f"Building {args.group} checks: {' '.join(selected)}", flush=True)
        subprocess.run(["nix", "build", "--no-link", "--print-build-logs",
                        *[f".#checks.x86_64-linux.{name}" for name in selected]], check=True)
    else:
        print(f"No {args.group} checks are declared; nothing to build.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
