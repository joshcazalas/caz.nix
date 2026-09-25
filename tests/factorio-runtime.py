"""Exercise the pinned real game without requiring a VM or Factorio account."""

import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import tempfile
import time


package = Path(os.environ["FACTORIO_PACKAGE"])
binary = str(package / "bin/factorio")
script = Path(__file__).resolve().parent.parent / "scripts/factorio-admin.py"
with tempfile.TemporaryDirectory() as temporary:
    state = Path(temporary)
    config = state / "config.ini"
    config.write_text(
        "use-system-read-write-data-directories=true\n[path]\n"
        f"read-data={package}/share/factorio/data\nwrite-data={state}\n"
    )
    subprocess.run([sys.executable, str(script), "--state-dir", str(state), "initialize"], check=True)
    manifest = state / "manifest.json"
    # Public CI needs no portal credentials. A local run with verified cached
    # archives exercises the complete production mod set using the same code.
    cache = os.environ.get("FACTORIO_MOD_CACHE")
    manifest.write_text(Path(os.environ["FACTORIO_MOD_MANIFEST"]).read_text() if cache else "[]")
    map_settings = state / "map-gen-settings.json"
    map_settings.write_text(os.environ["FACTORIO_MAP_GEN_SETTINGS"])
    prepare = [sys.executable, str(script.with_name("factorio-prepare.py")),
               "--manifest", str(manifest), "--mod-directory", str(state / "mods"),
               "--state-dir", str(state), "--world", "test-world", "--binary", binary,
               "--config", str(config), "--map-gen-settings", str(map_settings)]
    if cache:
        prepare += ["--cache", cache]
    subprocess.run(prepare, check=True, timeout=180)
    # Exercise the generated service arguments and settings, with isolated
    # storage/binding and the explicit offline-auth exception below.
    command = []
    for arg in shlex.split(os.environ["FACTORIO_EXEC_START"]):
        if arg.startswith("--config="):
            arg = f"--config={config}"
        elif arg.startswith("--bind="):
            arg = "--bind=127.0.0.1"
        elif arg.startswith("--mod-directory="):
            arg = f"--mod-directory={state / 'mods'}"
        elif arg.startswith("--server-settings="):
            settings = json.loads(Path(arg.split("=", 1)[1]).read_text())
            assert settings["require_user_verification"] is True
            assert settings["visibility"]["public"] is False
            # Nix builds have no Internet access. Keep the production setting
            # asserted above, then disable the auth-server call ONLY for the
            # isolated loopback smoke test. An optional online run keeps it.
            if os.environ.get("FACTORIO_TEST_ONLINE") != "true":
                settings["require_user_verification"] = False
            settings_path = state / "server-settings.json"
            settings_path.write_text(json.dumps(settings))
            arg = f"--server-settings={settings_path}"
        else:
            arg = arg.replace(os.environ["FACTORIO_STATE_DIR"], str(state))
        command.append(arg)
    for attempt in range(2):
        log = state / f"test-{attempt}.log"
        with log.open("w") as output:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=output,
                                       stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic() + 90
                while "to(InGame)" not in log.read_text():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError(log.read_text())
                    time.sleep(0.2)
                if attempt == 0:
                    process.stdin.write("/whitelist add RuntimeFriend\n")
                else:
                    process.stdin.write("/whitelist get\n")
                # The first use requires confirmation; this affects only the
                # disposable test world, never production saves.
                probe_path = state / "script-output/caz-map.json"
                probe_path.unlink(missing_ok=True)
                probe = '/c helpers.write_file("caz-map.json", helpers.table_to_json({enemies=game.surfaces.nauvis.map_gen_settings.autoplace_controls["enemy-base"], mods=script.active_mods}), false)\n'
                process.stdin.write(probe * 2)
                process.stdin.flush()
                deadline = time.monotonic() + 10
                while "runtimefriend" not in log.read_text().lower():
                    if time.monotonic() > deadline:
                        raise RuntimeError("Runtime whitelist was not applied\n" + log.read_text())
                    time.sleep(0.2)
                deadline = time.monotonic() + 10
                while not probe_path.exists():
                    if time.monotonic() > deadline:
                        raise RuntimeError("Map settings probe failed\n" + log.read_text())
                    time.sleep(0.2)
                actual = json.loads(probe_path.read_text())
                assert actual["enemies"]["frequency"] == 0.75, actual
                assert actual["enemies"]["size"] == 1, actual
                for mod in json.loads(manifest.read_text()):
                    assert actual["mods"][mod["name"]] == mod["version"], actual
            finally:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise
                process.stdin.close()
            assert process.returncode == 0, log.read_text()
        assert "space-age" in log.read_text(), log.read_text()
        persisted = json.loads((state / "server-whitelist.json").read_text())
        assert "runtimefriend" in [player.lower() for player in persisted], (persisted, log.read_text())
        subprocess.run([sys.executable, str(script), "--state-dir", str(state), "initialize"], check=True)
        subprocess.run(prepare, check=True, timeout=180)
    print("Space Age world preparation, 75% enemy frequency, mod versions, whitelist persistence, save, and restart passed.")
