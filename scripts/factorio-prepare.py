"""Install pinned portal mods and select a world before the game starts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request


OFFICIAL_MODS = ["base", "quality", "elevated-rails", "space-age"]


def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def install_mods(manifest, directory, credentials, cache=None):
    """Only publish verified archives; an existing complete set works offline."""
    directory.mkdir(parents=True, exist_ok=True)
    for mod in manifest:
        name = mod["name"]
        filename = mod["file_name"]
        if (not re.fullmatch(r"[A-Za-z0-9_-]+", name)
                or not re.fullmatch(r"\d+\.\d+\.\d+", mod["version"])
                or filename != f'{name}_{mod["version"]}.zip'
                or not re.fullmatch(r"[0-9a-f]{64}", mod["sha256"])
                or not re.fullmatch(r"/download/" + re.escape(name) + r"/[0-9a-f]+",
                                    mod["download_path"])):
            raise ValueError("Invalid pinned mod metadata")
        target = directory / filename
        if target.is_file() and checksum(target) == mod["sha256"]:
            continue
        fd, temporary = tempfile.mkstemp(prefix=".download-", dir=directory)
        temporary = Path(temporary)
        try:
            with os.fdopen(fd, "wb") as output:
                cached = cache / filename if cache else None
                if cached and cached.is_file():
                    with cached.open("rb") as source:
                        shutil.copyfileobj(source, output)
                else:
                    if credentials is None:
                        raise RuntimeError(f"Missing cached archive for {name}")
                    login = json.loads(credentials.read_text())
                    query = urllib.parse.urlencode({
                        "username": login["username"], "token": login["token"],
                    })
                    request = urllib.request.Request(
                        "https://mods.factorio.com" + mod["download_path"] + "?" + query,
                        headers={"User-Agent": "Factorio/2.0.77"},
                    )
                    try:
                        with urllib.request.urlopen(request, timeout=120) as source:
                            shutil.copyfileobj(source, output)
                    except Exception:
                        # Network exceptions can contain the authenticated URL.
                        raise RuntimeError(f"Download failed for {name}; check portal credentials/network") from None
            if checksum(temporary) != mod["sha256"]:
                raise RuntimeError(f"Checksum mismatch for {name}")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    names = OFFICIAL_MODS + [mod["name"] for mod in manifest]
    temporary = directory / ".mod-list.json"
    temporary.write_text(json.dumps({"mods": [{"name": name, "enabled": True} for name in names]}))
    temporary.replace(directory / "mod-list.json")


def prepare_world(state, world, create):
    """A stable world name survives restarts and mod/configuration updates."""
    if not re.fullmatch(r"[A-Za-z0-9_-]+", world):
        raise ValueError("Invalid world name")
    directory = state / "worlds" / world
    saves = directory / "saves"
    if not saves.exists():
        directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".create-", dir=directory) as staging:
            staging = Path(staging)
            create(staging)
            staging.rename(saves)
    active = state / "saves"
    if active.is_symlink() and active.resolve() == saves.resolve():
        return
    # Retire the original unplayed world's directory only after the new save
    # exists. Future world selections replace a symlink atomically.
    if active.exists() and not active.is_symlink():
        active.rename(state / "saves-before-declarative-worlds")
    temporary = state / ".saves-next"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(saves.relative_to(state), target_is_directory=True)
    temporary.replace(active)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--mod-directory", type=Path, required=True)
    parser.add_argument("--credentials", type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--world", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--map-gen-settings", required=True)
    parser.add_argument("--save-name", default="default")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.save_name):
        parser.error("Invalid save name")
    install_mods(json.loads(args.manifest.read_text()), args.mod_directory, args.credentials, args.cache)

    def create(directory):
        subprocess.run([
            args.binary, f"--config={args.config}",
            f"--mod-directory={args.mod_directory}",
            f"--map-gen-settings={args.map_gen_settings}",
            f"--create={directory / (args.save_name + '.zip')}",
        ], check=True)

    prepare_world(args.state_dir, args.world, create)


if __name__ == "__main__":
    main()
