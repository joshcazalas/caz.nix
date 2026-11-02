"""Ensure Dependabot's manifests are the images actually deployed by NixOS."""

import json
import os
from pathlib import Path
import re

root = Path(os.environ["CONTAINER_MANIFESTS"])
images = json.loads(os.environ["CONTAINER_IMAGES"])
for service in ["home-assistant", "minecraft"]:
    manifest = (root / service / "Dockerfile").read_text()
    match = re.fullmatch(r"FROM ([^\s@]+:[^\s@:/]+@sha256:[0-9a-f]{64})\s*", manifest)
    assert match, f"{service}: expected one tag- and digest-pinned FROM"
    assert images[service] == match[1], f"{service}: runtime diverges from Dependabot manifest"

print("Container manifests match the deployed image references.")
