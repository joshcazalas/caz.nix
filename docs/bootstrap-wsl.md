# Bootstrap Ubuntu under WSL2

This keeps Docker Engine inside Ubuntu instead of using Docker Desktop. Docker
is a system service, so it is installed outside Home Manager; the Docker client
and the rest of the developer CLI are managed by the flake.

## 1. Confirm systemd

Current Ubuntu installations from `wsl --install` usually enable systemd by
default. Check inside Ubuntu:

```bash
ps -p 1 -o comm=
```

If the result is not `systemd`, add this to `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then run `wsl.exe --shutdown` in PowerShell, reopen Ubuntu, and verify again.
Microsoft's current instructions are at
<https://learn.microsoft.com/windows/wsl/systemd>.

## 2. Install Nix

With systemd enabled, Nix recommends the multi-user daemon installation:

```bash
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install \
  | sh -s -- --daemon
```

Review the official instructions at <https://nixos.org/download/> before
running a remote installer. Close and reopen the Ubuntu shell afterward, then
verify `nix --version`.

## 3. Enable flakes

Create or edit `/etc/nix/nix.conf` and include:

```ini
experimental-features = nix-command flakes
```

Restart the daemon with `sudo systemctl restart nix-daemon`.

## 4. Install Docker Engine

Use Docker's current Ubuntu repository instructions rather than a convenience
script: <https://docs.docker.com/engine/install/ubuntu/>. Install Docker Engine,
containerd, Buildx, and the Compose plugin. Then allow this user to access the
daemon and restart the WSL session:

```bash
sudo usermod -aG docker "$USER"
wsl.exe --shutdown
```

Membership in the `docker` group is effectively root access. That is reasonable
for a single-user development distro, but it is not a security boundary.

After reopening Ubuntu:

```bash
systemctl is-active docker
docker run --rm hello-world
docker compose version
```

## 5. Activate Home Manager

From this repository:

```bash
nix flake lock
nix flake check --no-build
nix run home-manager/release-26.05 -- switch --flake .#joshcaz@cazpc
```

Later activations are shorter:

```bash
home-manager switch --flake .#joshcaz@cazpc
```

The profile supplies Docker CLI/Compose, OpenTofu (`tofu`), Node and TypeScript,
Go, Rust, and uv. It deliberately installs no global Python interpreter. Use,
for example, `uv python install`, `uv init`, `uv add`, and `uv run`; the profile
sets uv to prefer only Python versions managed by uv.
