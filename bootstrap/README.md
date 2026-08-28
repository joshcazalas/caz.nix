# Bootstrap a new Ubuntu WSL environment

[`wsl.sh`](wsl.sh) installs the system-level prerequisites that standalone Home
Manager cannot own, validates this flake, and activates the portable
`joshcaz@wsl` profile. It is interactive and safe to rerun after a failure.

The intended result is:

- the official multi-user Nix installation and `nix-daemon`;
- this public repository cloned over HTTPS by default, with SSH available for
  authenticated writes;
- Docker Engine running inside Ubuntu, with Buildx and Compose;
- the complete Home Manager development and Bash profile;
- a repository-local pre-commit Gitleaks scan;
- no Python installation outside uv;
- local-only Atuin history with its network and AI features disabled.

## Before running the script

The current flake expects all WSL distributions to use the Linux username
`joshcaz` and an x86-64 Ubuntu installation. Choose that username during
Ubuntu's first-run setup. Changing it later requires changing `settings.nix`
and the Home Manager output.

The script requires systemd. Current Ubuntu WSL installations generally enable
it automatically. Check inside Ubuntu:

```bash
ps -p 1 -o comm=
```

If that does not print `systemd`, the script can safely create or extend
`/etc/wsl.conf` when there is no existing `[boot]` section. When a custom boot
section already exists, manually ensure it contains:

```ini
[boot]
systemd=true
```

Then run `wsl.exe --shutdown` from PowerShell and reopen Ubuntu.

## Obtain the public repository

Read-only access does not require a GitHub account or SSH key. Install the
small Ubuntu prerequisites, clone over HTTPS, and run the bootstrap:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssh-client xz-utils

mkdir -p ~/develop
git clone https://github.com/joshcazalas/caz.nix.git ~/develop/caz.nix
cd ~/develop/caz.nix
./bootstrap/wsl.sh
```

To create an SSH-authenticated checkout instead, run `./wsl.sh --ssh-clone`.
That opt-in path generates or reuses an Ed25519 key, copies only its public half
to the Windows clipboard, opens GitHub's key page, and verifies GitHub's host
fingerprint before cloning. The private key must never be uploaded or committed.
Authenticating the `gh` CLI remains optional.

### Fully guided alternative

If a copy of `wsl.sh` is available before the repository is cloned—for example,
download it from GitHub in a Windows browser and copy it through
`/mnt/c/Users/<windows-user>/Downloads/`—it can perform the public HTTPS clone
too:

```bash
chmod +x ./wsl.sh
./wsl.sh
```

Pass `--ssh-clone` only when authenticated Git operations are needed.

## What the script changes

The script clearly asks before each system-level change. It may:

- install missing prerequisite packages with Ubuntu's `apt`;
- edit `/etc/wsl.conf` only in the simple cases described above;
- run Nix's official installer from <https://nixos.org/nix/install>;
- add Docker's official Ubuntu apt signing key and repository;
- install Docker Engine packages and add `joshcaz` to the `docker` group;
- clone this repository when it is not already available;
- configure this checkout to use the tracked `.githooks` directory;
- run `nix flake check --no-build` and the pinned Home Manager CLI;
- preserve any colliding unmanaged dotfiles with a timestamped
  `.pre-caz-nix-*` suffix before Home Manager creates its managed links.

Membership in the `docker` group is effectively root-level access inside the
WSL distribution. This is a deliberate convenience for this single-user
development environment, not a security boundary.

It does not upload private keys, create a GitHub token, enable Atuin sync, or
overwrite an unrelated repository directory. The guided SSH step may copy a
public key to the Windows clipboard and open GitHub in the default Windows
browser. It does not install or configure Windows applications; the capability
profiles in [`../windows/`](../windows/) own the Windows side.

Use a different checkout path or omit an optional host integration when needed:

```bash
./bootstrap/wsl.sh --repo-dir ~/src/caz.nix
./bootstrap/wsl.sh --skip-docker
```

### Rerunning safely

The bootstrap is intended to reconcile an existing machine as well as create a
new one. On a configured machine it skips apt, repository clone authentication,
Nix, and Docker when their expected state is already present. It always reevaluates
the flake and runs Home Manager so repository changes are applied; that may
download newly declared Nix packages and create a new Home Manager generation,
but it does not reinstall the system components or modify the Windows host.

## After bootstrap

Open a fresh Ubuntu terminal so Bash loads the new generation. If Docker group
membership was added, first run `wsl.exe --shutdown` from PowerShell.

From Windows PowerShell, apply one of the generic profiles documented in
[`../windows/README.md`](../windows/README.md). The default `workstation`
profile installs common applications, VS Code, declared extensions, and game
launchers. UI and privacy preferences are available through the explicit
`workstation-preferences` profile. Windows font selection and WSL feature
installation remain short one-time prerequisites. Home Manager intentionally
has no Windows-side activation effects.

Useful checks:

```bash
nix --version
home-manager generations
atuin doctor
docker run --rm hello-world
docker compose version
code . # after applying the Windows profile
```

After the Windows profile has installed VS Code, `code .` should open the
Windows client with a `WSL: Ubuntu` indicator. Use a fresh Ubuntu terminal so
WSL inherits the Windows installer's updated `PATH`.

The shell bindings are:

| Input | Result |
| --- | --- |
| Up Arrow | Search Atuin history from the current directory |
| Ctrl-R | Search all local Atuin history |
| Right Arrow | Accept the current ble.sh suggestion |
| Ctrl-T | Select a file with fzf |
| Alt-C | Select and enter a directory with fzf |

Atuin inserts the selected command for review instead of executing it. History
is stored locally under `~/.local/share/atuin`; no account or sync is configured.

## Disable the experimental line editor

If ble.sh causes any odd input or display behavior, edit
`hosts/cazpc/home.nix`:

```nix
caz.shell.blesh.enable = false;
```

Then apply the same profile again:

```bash
home-manager switch --flake ~/develop/caz.nix#joshcaz@wsl
```

This returns Bash to Readline and automatically enables the ordinary fzf and
Atuin integrations. Starship, zoxide, searchable history, and every development
tool remain installed. For emergency troubleshooting, `bash --norc` starts a
clean Bash session without loading Home Manager's Bash configuration.
