# WSL bootstrap reference

The complete first-install guide and interactive script now live together in
[`bootstrap/README.md`](../bootstrap/README.md) and
[`bootstrap/wsl.sh`](../bootstrap/wsl.sh).

For an already cloned checkout, run:

```bash
./bootstrap/wsl.sh
```

For routine updates after the first activation:

```bash
git pull --ff-only
nix flake check --no-build
home-manager switch --flake .#joshcaz@wsl
```

Home Manager starts one `ssh-agent` for the WSL user session. The first local
interactive Bash shell after WSL starts prompts for the configured GitHub key's
passphrase and adds it automatically; later terminals and tools inherit the
same unlocked identity without a manual `ssh-add`. The identity expires after
twelve hours or when the WSL session shuts down, whichever comes first. Remote
SSH shells do not trigger this automatic prompt.

Docker Engine remains an Ubuntu system service; the bootstrap installs it from
Docker's official apt repository. Home Manager owns the Docker client baseline
along with OpenTofu, Node/TypeScript, Go, Rust, uv, and the shell environment.

Windows software and optional preferences are deliberately outside the WSL
activation. Apply a generic WinGet/DSC profile from Windows PowerShell after
the WSL bootstrap; see [`../windows/README.md`](../windows/README.md). The
profile owns the Windows VS Code client, WSL extension, and Terminal. Selecting
a compatible Windows Terminal font remains a one-time manual preference.
