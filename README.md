# Nix homelab

One repository, one flake, and separate machine outputs:

- `nixosConfigurations.homeserver` owns the complete NixOS server.
- `homeConfigurations."joshcaz@cazpc"` owns the Ubuntu/WSL user environment.
- Project-specific versions still belong in each project's `devShell`; the
  Home Manager profile is only the useful baseline.

This is a scaffold, not a ready-to-install disk image. No drive has been read,
partitioned, formatted, mounted, or otherwise changed.

## Why this split

NixOS and Home Manager solve different layers of the same problem. NixOS owns
boot, disks, networking, daemons, users, and firewall rules. Home Manager owns
the user's shell and CLI tools and can also run standalone on Ubuntu. Windows
itself stays outside this flake; Ubuntu under WSL2 is the portable boundary.

The stable NixOS and Home Manager branches are pinned in `flake.lock` once Nix
first evaluates the repo. Developer toolchains come from a separately pinned
`nixos-unstable` input so the baseline can track current Node, Go, Rust, uv, and
OpenTofu without moving the server onto unstable.

## Initial service set

| Service | Default | Reachability | Purpose |
| --- | --- | --- | --- |
| SSH | on | LAN/WireGuard | Key-only administration |
| Samba | on | LAN/WireGuard | Windows-friendly NAS shares |
| Jellyfin | on | LAN; public is opt-in | Media streaming and per-person accounts |
| AdGuard Home | on | LAN/WireGuard | Network DNS filtering; simpler NixOS fit than Pi-hole |
| Beszel hub | on | LAN/WireGuard | Lightweight monitoring before committing to Prometheus/Grafana |
| WireGuard | off | UDP 51820 when enabled | Private remote administration |
| Home Assistant | off | LAN/WireGuard | Enable when the first devices arrive |
| Immich | off | LAN/WireGuard initially | Photo library, not a backup by itself |
| Minecraft | off | LAN or TCP 25565 by choice | Paper server in an OCI container |

Only Jellyfin is intended to be directly public at first. Its design is:

```text
friends/family -> jellyfin.your-domain -> router TCP 80/443
               -> Caddy HTTPS -> Jellyfin accounts

you while away -> vpn.your-domain -> router UDP 51820
               -> WireGuard -> SSH and private dashboards
```

Cloudflare should host the DNS record in **DNS-only** mode. A Cloudflare Tunnel
is useful for ordinary web dashboards, but normal Tunnel traffic traverses
Cloudflare's network and is the wrong transport for a personal video origin on
ordinary Cloudflare plans. It would also add an authentication layer that many
native Jellyfin clients cannot use. Caddy provides automatic certificates;
Jellyfin provides separate, non-admin usernames and passwords.

## Storage plan

- SSD: 1 GiB EFI partition labeled `NIXOS_BOOT`; remaining space ext4 labeled
  `NIXOS_ROOT`.
- 2 TB HDD: single Btrfs filesystem labeled `HOMELAB_DATA`, mounted at `/srv`.
- `/srv/media`, `/srv/photos`, `/srv/shares`, `/srv/minecraft`, and
  `/srv/backups` are created only after the data disk is mounted.
- zram handles incidental swap; there is no disk swap partition initially.

Btrfs gives checksums, compression, and snapshots. One disk is still one copy:
neither Btrfs nor snapshots protect against losing the drive. That is acceptable
for this disposable first phase, but anything that becomes emotionally valuable
needs a second independent copy.

## Repository map

```text
flake.nix                         pinned inputs and machine outputs
settings.nix                      user, host, domain, exposure toggle
hosts/cazpc/                      Ubuntu/WSL Home Manager profile
hosts/homeserver/                 NixOS host and disk-label contract
modules/home/                     shared CLI and developer packages
modules/nixos/                    storage, network, and service modules
secrets/                          sops-nix workflow; encrypted files only
docs/bootstrap-wsl.md             set up this laptop's WSL environment
docs/install-server.md            safe installation-day checklist
docs/remote-access.md             DNS, HTTPS, Jellyfin, and WireGuard plan
```

## What can be done now

1. Install Nix in WSL using [`docs/bootstrap-wsl.md`](docs/bootstrap-wsl.md).
2. Run `nix flake lock` and `nix flake check --no-build` from this directory.
3. Apply the development profile with:

   ```bash
   nix run home-manager/release-26.05 -- switch --flake .#joshcaz@cazpc
   ```

4. Create an empty private GitHub repository and add it as this directory's
   `origin`, or provide its SSH URL so that step can be completed here.

Do not enable public Jellyfin until the domain is replaced in `settings.nix`,
DNS is configured, and the deployment checklist has been completed.

## Routine commands

```bash
nix fmt
nix flake check --no-build
home-manager switch --flake .#joshcaz@cazpc
sudo nixos-rebuild switch --flake .#homeserver
nix flake update
```

Run `nix flake update` intentionally and review changes before switching the
server. The lock file, once generated, belongs in Git.

Omit `--no-build` when you intentionally want to build both the full NixOS
system closure and Home Manager generation, not merely evaluate them.
