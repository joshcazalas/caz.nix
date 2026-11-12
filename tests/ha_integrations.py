"""Check upstream artifacts and the read-only code/private userdata boundary."""

import ast
import json
import os
from pathlib import Path
import runpy
import shutil
import tempfile


volumes = json.loads(os.environ["HA_VOLUMES"])
state_dir = os.environ["HA_STATE_DIR"]
lock = json.loads(Path(os.environ["HA_LOCKFILE"]).read_text())
for variable, domain, input_name in [
    ("HA_LIGHTFX", "ha_lightfx", "ha-lightfx-src"),
    ("SCENE_PRESETS", "scene_presets", "scene-presets-src"),
]:
    node = lock["nodes"][lock["nodes"][lock["root"]]["inputs"][input_name]]
    assert node["flake"] is False
    version = node["original"]["ref"].removeprefix("v")
    source = Path(os.environ[variable])
    manifest = json.loads((source / "manifest.json").read_text())
    assert (manifest["domain"], manifest["version"]) == (domain, version)
    assert manifest["config_flow"] is True
    assert f"{source}:/config/custom_components/{domain}:ro" in volumes
    assert not any(source.rglob(".storage"))
    for path in source.rglob("*.py"):
        ast.parse(path.read_text(), filename=str(path))

userdata_mount = (
    f"{state_dir}/custom_components/scene_presets/userdata:"
    "/config/custom_components/scene_presets/userdata:rw"
)
assert userdata_mount in volumes
assert volumes.index(userdata_mount) > volumes.index(
    f"{os.environ['SCENE_PRESETS']}:/config/custom_components/scene_presets:ro"
)
assert f"{state_dir}:/config:rw" in volumes
private_dir = os.environ["HA_PRIVATE_DIR"]
assert f"{private_dir}/extensions:/config/private:ro" in volumes
assert not any(mount.split(":")[0] == private_dir for mount in volumes)
assert not any(mount.split(":")[1] == "/config/private" and not mount.endswith(":ro")
               for mount in volumes)

source = Path(os.environ["SCENE_PRESETS"])
assert (source / "userdata").is_dir()
assert not list((source / "userdata").iterdir())
presets = json.loads((source / "presets.json").read_text())
assert presets["presets"]
for preset in presets["presets"]:
    if preset.get("img"):
        assert (source / "assets" / preset["img"]).is_file()

# Exercise the upstream loader with immutable code and separately writable data.
# No real HA state or household configuration is read by this check.
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    code = root / "component"
    shutil.copytree(source, code)
    code.chmod(0o700)
    (code / "userdata").rmdir()
    userdata = root / "private-userdata"
    userdata.mkdir()
    (code / "userdata").symlink_to(userdata, target_is_directory=True)
    code.chmod(0o500)
    try:
        runpy.run_path(str(code / "file_utils.py"))
        assert (userdata / "custom/assets").is_dir()
        custom = userdata / "custom/presets.json"
        contents = json.dumps({
            "categories": [],
            "presets": [{"id": "private-test-preset", "name": "Test", "lights": []}],
        })
        custom.write_text(contents)
        loaded = runpy.run_path(str(code / "file_utils.py"))
        assert custom.read_text() == contents
        assert any(
            preset["id"] == "private-test-preset" and preset["custom"]
            for preset in loaded["PRESET_DATA"]["presets"]
        )
    finally:
        code.chmod(0o700)

print("Pinned integrations and private userdata boundary verified.")
