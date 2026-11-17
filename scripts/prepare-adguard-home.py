"""Prepare AdGuard's mutable users and managed hostname rules before startup."""

from copy import deepcopy
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile

import bcrypt
import yaml


BEGIN = "! BEGIN caz managed server hostname"
END = "! END caz managed server hostname"


def reconcile(config, plan):
    rules = []
    inside = False
    for rule in config.get("user_rules", []):
        if rule == BEGIN:
            if inside:
                raise ValueError("Nested managed hostname rule block")
            inside = True
        elif rule == END:
            if not inside:
                raise ValueError("Unmatched managed hostname rule marker")
            inside = False
        elif not inside:
            rules.append(rule)
    if inside:
        raise ValueError("Unclosed managed hostname rule block")
    config["user_rules"] = rules + [BEGIN, *plan["rules"], END]
    # A global rewrite for this exact name would take precedence over the
    # client-scoped rules. Public names and every other rewrite are retained.
    filtering = config.setdefault("filtering", {})
    filtering["rewrites"] = [
        item for item in filtering.get("rewrites", [])
        if item["domain"].rstrip(".").lower() != plan["hostname"].lower()
    ]
    return config


class ConfigLoader(yaml.SafeLoader):
    # Keep timestamps as strings. AdGuard requires RFC3339's T separator;
    # PyYAML's default datetime serializer would replace it with a space.
    yaml_implicit_resolvers = {
        key: [(tag, pattern) for tag, pattern in entries
              if tag != "tag:yaml.org,2002:timestamp"]
        for key, entries in deepcopy(yaml.SafeLoader.yaml_implicit_resolvers).items()
    }


def write_private(path, content):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    path, plan_path = map(Path, sys.argv[1:])
    config = yaml.load(path.read_text(), Loader=ConfigLoader)
    updated = reconcile(config, json.loads(plan_path.read_text()))
    if not updated.get("users"):
        password = secrets.token_urlsafe(32)
        password_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
        updated["users"] = [{"name": "admin", "password": password_hash}]
        # Publish the credential before its hash. An interrupted preparation
        # can retry while systemd still holds the daemon at ExecStartPre.
        write_private(path.with_name("initial-admin-password"), password + "\n")
    write_private(path, yaml.safe_dump(updated, sort_keys=False))


if __name__ == "__main__":
    main()
