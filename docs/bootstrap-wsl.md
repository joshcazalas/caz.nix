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

Docker Engine remains an Ubuntu system service; the bootstrap installs it from
Docker's official apt repository. Home Manager owns the Docker client baseline
along with OpenTofu, Node/TypeScript, Go, Rust, uv, and the shell environment.

Windows software and preferences are deliberately outside the WSL activation.
Apply the single shared WinGet/DSC profile from Windows PowerShell after the WSL
bootstrap; see [`../windows/README.md`](../windows/README.md). That profile owns
the Windows VS Code client, WSL extension, Terminal, and required host font.
