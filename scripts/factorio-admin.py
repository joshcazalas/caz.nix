"""Local Factorio membership and consistent backups; no remote console needed."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import syslog
import tempfile


# An empty whitelist allows everyone. Keep a reserved entry whitelisted AND
# banned so even this name cannot join. Hide it from the human-facing list.
GUARD = "__caz_whitelist_guard__"
UNIT = "factorio.service"
LOCK = "/run/caz-container-maintenance/lock"


def read_list(path):
    value = json.loads(path.read_text())
    if not isinstance(value, list):
        raise ValueError(f"Expected a JSON list in {path}")
    return value


def read_players(path):
    players = read_list(path)
    if any(not isinstance(player, str) or not player for player in players):
        raise ValueError(f"Invalid player list in {path}")
    return players


def write_json(path, value):
    """Atomic replacement, retaining DynamicUser ownership when run as root."""
    existing = path.stat() if path.exists() else None
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            if existing and os.geteuid() == 0:
                os.fchown(stream.fileno(), existing.st_uid, existing.st_gid)
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def initialize(state):
    whitelist = state / "server-whitelist.json"
    players = read_players(whitelist) if whitelist.exists() else []
    if GUARD not in players:
        write_json(whitelist, players + [GUARD])
    admins = state / "server-adminlist.json"
    if not admins.exists():
        write_json(admins, [])
    read_players(admins)
    banlist = state / "server-banlist.json"
    bans = read_list(banlist) if banlist.exists() else []
    if any(not isinstance(ban, dict) or not isinstance(ban.get("username"), str) for ban in bans):
        raise ValueError(f"Invalid ban list in {banlist}")
    if not any(ban["username"] == GUARD for ban in bans):
        write_json(banlist, bans + [{"username": GUARD, "reason": "Reserved whitelist guard"}])


@contextmanager
def maintenance_lock():
    # The verified deployment transaction already owns this same lock.
    if os.environ.get("CAZ_CONTAINER_MAINTENANCE_LOCK_HELD") == "true":
        yield
        return
    with open(LOCK, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


@contextmanager
def stopped_server():
    status = subprocess.check_output(
        ["systemctl", "show", "--property=ActiveState", "--value", UNIT], text=True
    ).strip()
    running = status in {"active", "activating", "reloading"}
    if status == "deactivating":
        raise RuntimeError("Factorio is already stopping; try again when it finishes")
    try:
        if running:
            print("Saving and stopping Factorio; connected players will disconnect.", flush=True)
            subprocess.run(["systemctl", "stop", UNIT], check=True)
            result = subprocess.check_output(
                ["systemctl", "show", "--property=Result", "--value", UNIT], text=True
            ).strip()
            if result != "success":
                raise RuntimeError(f"Factorio did not stop cleanly ({result}); state was not changed")
        yield
    finally:
        if running:
            subprocess.run(["systemctl", "start", UNIT], check=True)


def access(state, scope, action, player):
    path = state / ("server-whitelist.json" if scope == "whitelist" else "server-adminlist.json")
    if action == "list":
        print("\n".join(sorted(p for p in read_players(path) if p != GUARD)))
        return
    with stopped_server():
        initialize(state)
        players = read_players(path)
        # Factorio normalizes names to lowercase when persisting its lists.
        name = player.lower()
        if scope == "operator" and action == "add":
            if name not in [p.lower() for p in read_players(state / "server-whitelist.json")]:
                raise ValueError("Add this player to the whitelist before granting operator access")
        if scope == "whitelist" and action == "remove":
            if name in [p.lower() for p in read_players(state / "server-adminlist.json")]:
                raise ValueError("Remove operator access before removing this player from the whitelist")
        if action == "add" and name not in [p.lower() for p in players]:
            players.append(player)
        if action == "remove":
            players = [p for p in players if p.lower() != name]
        write_json(path, players)
    syslog.openlog("caz-factorio-access")
    syslog.syslog(f"{os.environ.get('SUDO_USER', 'root')} changed {scope}: {action} {player}")
    print(f"{scope}: {action} {player}")


def backup(state, directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    archive = directory / f"factorio-{stamp}.tar.zst"
    fd, temporary = tempfile.mkstemp(prefix=".factorio-backup.", dir=directory)
    os.close(fd)
    try:
        with stopped_server():
            if not any((state / "saves").glob("*.zip")):
                raise RuntimeError("No Factorio save exists; refusing an empty backup")
            subprocess.run(
                ["tar", "--create", "--zstd", "--file", temporary,
                 "--exclude=./*.log", "--exclude=./*.log.*", "--exclude=./temp",
                 "--directory", str(state.resolve(strict=True)), "."], check=True
            )
            os.replace(temporary, archive)
        # Retain seven successful archives, including pre-deployment backups.
        for old in sorted(directory.glob("factorio-*.tar.zst"), reverse=True)[7:]:
            old.unlink()
        print(f"Created {archive}")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def health(state, port):
    pid = subprocess.check_output(
        ["systemctl", "show", "--property=MainPID", "--value", UNIT], text=True
    ).strip()
    sockets = subprocess.check_output(
        ["ss", "--udp", "--listening", "--no-header", "--numeric", "--processes",
         f"sport = :{port}"], text=True
    )
    if not pid.isdecimal() or int(pid) == 0 or f"pid={pid}," not in sockets:
        raise RuntimeError("The Factorio process is not listening on its game port")
    if GUARD not in read_players(state / "server-whitelist.json"):
        raise RuntimeError("The whitelist guard is missing")
    if not any(ban.get("username") == GUARD for ban in read_list(state / "server-banlist.json")):
        raise RuntimeError("The whitelist guard is not banned")
    print("Factorio listener and access lists are healthy")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=Path("/var/lib/factorio"))
    parser.add_argument("--backup-dir", type=Path, default=Path("/var/backup/factorio"))
    parser.add_argument("--port", type=int, default=34197)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("initialize", help=argparse.SUPPRESS)
    commands.add_parser("backup", help="Save, stop, archive, and restart the server")
    commands.add_parser("health", help="Check the game's UDP listener and whitelist guard")
    for name in ("whitelist", "operator"):
        command = commands.add_parser(name)
        command.add_argument("action", choices=["add", "remove", "list"])
        command.add_argument("player", nargs="?")
    args = parser.parse_args()
    if args.command == "initialize":
        initialize(args.state_dir)
        return
    if os.geteuid() != 0:
        parser.error("Run with sudo; Factorio administration requires root")
    # Health is called while deployment already holds the maintenance lock.
    if args.command == "health":
        health(args.state_dir, args.port)
        return
    if args.command in {"whitelist", "operator"}:
        if args.action == "list":
            if args.player is not None:
                parser.error("list does not accept a player name")
        elif (not args.player or args.player.lower() == GUARD
              or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", args.player)):
            parser.error("Use a Factorio username containing letters, numbers, underscores, dots or hyphens")
    with maintenance_lock():
        if args.command == "backup":
            backup(args.state_dir, args.backup_dir)
        else:
            access(args.state_dir, args.command, args.action, args.player)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
