# Bootstrap a new Ubuntu WSL environment

[`wsl.sh`](wsl.sh) installs the system-level prerequisites that standalone Home
Manager cannot own, validates this flake, and activates the portable
`joshcaz@wsl` profile. It is interactive and safe to rerun after a failure.

The intended result is:

- the official multi-user Nix installation and `nix-daemon`;
- this private repository cloned over SSH;
- Docker Engine running inside Ubuntu, with Buildx and Compose;
- the complete Home Manager development and Bash profile;
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

## Private-repository chicken and egg

The normal path requires SSH access before the private repository can be
cloned. These are the only genuinely manual prerequisites:

1. Install the small Ubuntu tools needed to reach GitHub.
2. Generate an SSH key.
3. Add its **public** half to GitHub.
4. Clone the repository.
5. Run the bootstrap from the clone.

The exact commands are:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssh-client xz-utils

install -d -m 0700 ~/.ssh
ssh-keygen -t ed25519 -a 100 -C "73436834+joshcazalas@users.noreply.github.com" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub | clip.exe
```

Add the clipboard contents at <https://github.com/settings/ssh/new>. Use the
`Authentication Key` type. The private file `~/.ssh/id_ed25519` must never be
copied to GitHub or committed anywhere.

Verify the host fingerprint against GitHub's published values when SSH asks,
then verify access and clone:

```bash
git ls-remote git@github.com:joshcazalas/caz.nix.git HEAD
mkdir -p ~/develop
git clone git@github.com:joshcazalas/caz.nix.git ~/develop/caz.nix
cd ~/develop/caz.nix
./bootstrap/wsl.sh
```

GitHub publishes its current SSH fingerprints at
<https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>.

SSH authentication is sufficient for `git clone`, pull, and push. Authenticating
the `gh` CLI is optional and can be done after Home Manager installs it with
`gh auth login --git-protocol ssh --web`. On WSL without a credential store,
`gh` may warn that its API token will be stored in a plain-text config file;
read that prompt before accepting.

### Fully guided alternative

If a copy of `wsl.sh` is available before the repository is cloned—for example,
download it from GitHub in a signed-in Windows browser and copy it through
`/mnt/c/Users/<windows-user>/Downloads/`—it can perform the SSH-key walkthrough
and clone step too:

```bash
chmod +x ./wsl.sh
./wsl.sh
```

It displays the public key, copies it with `clip.exe`, opens GitHub's SSH-key
page when `powershell.exe` is available, and waits while the key is added.

## What the script changes

The script clearly asks before each system-level change. It may:

- install missing prerequisite packages with Ubuntu's `apt`;
- edit `/etc/wsl.conf` only in the simple cases described above;
- run Nix's official installer from <https://nixos.org/nix/install>;
- add Docker's official Ubuntu apt signing key and repository;
- install Docker Engine packages and add `joshcaz` to the `docker` group;
- clone this repository when it is not already available;
- run `nix flake check --no-build` and the pinned Home Manager CLI;
- preserve any colliding unmanaged dotfiles with a timestamped
  `.pre-caz-nix-*` suffix before Home Manager creates its managed links.

Membership in the `docker` group is effectively root-level access inside the
WSL distribution. This is a deliberate convenience for this single-user
development environment, not a security boundary.

It does not install or configure Windows software, upload private keys, create
a GitHub token, enable Atuin sync, or overwrite an unrelated repository
directory. The guided SSH step may copy a public key to the Windows clipboard
and open GitHub in the default Windows browser.

Use a different checkout path or omit Docker when needed:

```bash
./bootstrap/wsl.sh --repo-dir ~/src/caz.nix
./bootstrap/wsl.sh --skip-docker
```

## After bootstrap

Open a fresh Ubuntu terminal so Bash loads the new generation. If Docker group
membership was added, first run `wsl.exe --shutdown` from PowerShell.

Useful checks:

```bash
nix --version
home-manager generations
atuin doctor
docker run --rm hello-world
docker compose version
```

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
