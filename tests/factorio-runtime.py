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
    (state / "mods").mkdir()
    (state / "mods/mod-list.json").write_text(json.dumps({"mods": [
        {"name": name, "enabled": True}
        for name in ["base", "quality", "elevated-rails", "space-age"]
    ]}))
    subprocess.run([sys.executable, str(script), "--state-dir", str(state), "initialize"], check=True)
    save = state / "saves/default.zip"
    subprocess.run([binary, "--config", str(config), "--create", str(save)], check=True, timeout=120)
    # Exercise the generated service arguments and settings, with isolated
    # storage/binding and the explicit offline-auth exception below.
    command = []
    for arg in shlex.split(os.environ["FACTORIO_EXEC_START"]):
        if arg.startswith("--config="):
            arg = f"--config={config}"
        elif arg.startswith("--bind="):
            arg = "--bind=127.0.0.1"
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
                process.stdin.flush()
                deadline = time.monotonic() + 10
                while "runtimefriend" not in log.read_text().lower():
                    if time.monotonic() > deadline:
                        raise RuntimeError("Runtime whitelist was not applied\n" + log.read_text())
                    time.sleep(0.2)
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
    print("Space Age startup, live whitelist persistence, graceful save, and restart passed.")
