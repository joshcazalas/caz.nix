# Nix homelab

One repository, one flake, and separate machine outputs:

- `nixosConfigurations.homeserver` owns the complete NixOS server.
- `homeConfigurations."joshcaz@wsl"` owns the portable Ubuntu/WSL user environment.
- `homeConfigurations."joshcaz@cazpc"` remains an alias for the same profile.
- Project-specific versions still belong in each project's `devShell`; the
  Home Manager profile is only the useful baseline.

This is a scaffold, not a ready-to-install disk image. No drive has been read,
partitioned, formatted, mounted, or otherwise changed.

## Why this split

NixOS and Home Manager solve different layers of the same problem. NixOS owns
boot, disks, networking, daemons, users, and firewall rules. Home Manager owns
the user's shell and CLI tools and can also run standalone on Ubuntu. Windows
packages remain outside the Nix store, but the WSL profile reconciles its
explicit Windows user integrations through WSL interoperability.

The stable NixOS and Home Manager branches are pinned in `flake.lock` once Nix
first evaluates the repo. Developer toolchains come from a separately pinned
`nixos-unstable` input so the baseline can track current Node, Go, Rust, uv, and
OpenTofu without moving the server onto unstable.

## Development shell experience

The WSL profile keeps Bash as the actual shell while adding modern interactive
behavior:

- ble.sh supplies syntax highlighting and Right-Arrow ghost suggestions;
- Atuin supplies local full-screen history on Up Arrow and Ctrl-R;
- fzf supplies fuzzy file, directory, and completion selection;
- Starship supplies the Gruvbox Rainbow cross-shell prompt;
- zoxide learns frequently used directories without replacing `cd`.

Atuin sync, its update network check, and its AI features are explicitly off.
WSL installs Meslo LG Nerd Font for Linux applications through Nix; the guided
bootstrap separately installs MesloLGL on Windows because Windows Terminal is
the process that renders WSL text. Home Manager similarly uses WinGet to ensure
the supported Windows VS Code client and its WSL extension are present instead
of installing the Linux GUI build under WSLg. The same interactive shell and
prompt are used on the NixOS server, while the connecting client supplies its
font.
The ble.sh integration is the only experimental component and can be disabled
with one option in `hosts/cazpc/home.nix`; the other tools then fall back to
their standard Bash integrations.

## Initial service set

| Service | Default | Reachability | Purpose |
| --- | --- | --- | --- |
| SSH | on | Public TCP 22 | Key-only administration; Fail2ban-protected |
| Samba | on | LAN only | Windows-friendly NAS shares |
| Jellyfin | on | LAN; public is opt-in | Media streaming and per-person accounts |
| AdGuard Home | on | LAN or SSH forwarding | Network DNS filtering; simpler NixOS fit than Pi-hole |
| Prometheus + Alertmanager | on | Loopback; SSH forwarding | Metrics, declarative alert rules validated in CI, email and Discord notifications |
| Grafana | on | Loopback; SSH forwarding | Provisioned dashboard over the Prometheus data source |
| Cloudflare DDNS | on | Outbound HTTPS only | Keep reviewed public IPv4 records synchronized |
| Home Assistant | off | LAN or SSH forwarding | Enable when the first devices arrive |
| Immich | off | LAN or SSH forwarding initially | Photo library, not a backup by itself |
| Minecraft | on | LAN TCP 25565; Internet after manual DNS/router setup | Pinned Paper server with a locally managed whitelist and daily backups |
| BlueMap | on | Public HTTPS after manual router setup | Static 3D world map served by Caddy; no player markers, bounded render |
| Release updater | on | outbound HTTPS only | Verified maintenance-window deployment, health checks, and rollback |

The host firewall accepts storage, monitoring, discovery, and DNS traffic only
from RFC 1918 private IPv4 sources. Public SSH is restricted to the declared
administrator and public-key authentication, with five failures in ten minutes
earning a one-hour Fail2ban block. Minecraft TCP 25565 remains the other
globally allowed port. IPv6 is temporarily disabled until its firewall and
external reachability are reviewed and tested deliberately.

Minecraft and the optional public Jellyfin endpoint have separate, explicitly
reviewed exposure paths. Jellyfin's design is:

```text
friends/family -> jellyfin.your-domain -> router TCP 80/443
               -> Caddy HTTPS -> Jellyfin accounts

you while away -> ssh.your-domain -> router TCP 22
               -> key-only OpenSSH -> shell/sudo
               -> optional SSH local forwarding -> private dashboards
```

Cloudflare should host the DNS record in **DNS-only** mode. A Cloudflare Tunnel
is useful for ordinary web dashboards, but normal Tunnel traffic traverses
Cloudflare's network and is the wrong transport for a personal video origin on
ordinary Cloudflare plans. It would also add an authentication layer that many
native Jellyfin clients cannot use. Caddy provides automatic certificates;
Jellyfin provides separate, non-admin usernames and passwords.

## Storage plan

- The healthy NVMe contains a 1 GiB EFI partition labeled `NIXOS_BOOT`; the
  remaining ext4 filesystem is labeled `NIXOS_ROOT`.
- Shared media, photo, file, and application storage currently lives under
  `/var/lib/homelab` on that root NVMe. `/srv` is intentionally unconfigured.
- Minecraft state and its local backup set live separately at
  `/var/lib/minecraft` and `/var/backup/minecraft`.
- Three pre-deployment archives of mutable application state are retained under
  `/var/backup/caz-release-updater`.
- The unreliable HDD is not mounted, scrubbed, or referenced by this flake.
- zram handles incidental swap; there is no disk swap partition.

This SSD-only phase has no disk redundancy: local Minecraft archives protect
against bad edits and upgrades, but not NVMe failure. A second SSD can become a
separate data or backup target after it is connected and tested. Anything that
becomes emotionally valuable still needs an independent off-machine copy.

## Repository map

```text
flake.nix                         pinned inputs and machine outputs
settings.nix                      user, host, domain, exposure toggle
hosts/cazpc/                      Ubuntu/WSL Home Manager profile
hosts/homeserver/                 NixOS host and disk-label contract
modules/home/                     shared CLI and developer packages
modules/home/starship-gruvbox-rainbow.toml
                                  pinned shared prompt preset
bootstrap/README.md               manual prerequisites and recovery notes
bootstrap/wsl.sh                  interactive new-WSL bootstrap
bootstrap/windows-font.ps1        pinned Windows Meslo font installer
modules/nixos/                    storage, network, and service modules
modules/nixos/cloudflare-ddns.nix scoped IPv4-only Cloudflare DNS updater
secrets/                          sops-nix workflow for future runtime secrets
docs/bootstrap-wsl.md             short WSL command reference
docs/install-server.md            safe installation-day checklist
docs/remote-access.md             DNS, hardened SSH, and public Jellyfin plan
docs/minecraft.md                 pinned server, backups, and exposure checklist
docs/ci-and-releases.md           update, validation, SBOM, and release design
docs/publication-checklist.md     safe path from private to public
scripts/                          local CI, secret scan, and release tooling
.githooks/                        tracked local secret-scanning hook
```

## What can be done now

1. Follow [`bootstrap/README.md`](bootstrap/README.md) on a new WSL device.
2. Run the guided bootstrap from this directory:

   ```bash
   ./bootstrap/wsl.sh
   ```

3. Open a new Ubuntu terminal and rate the Bash experience. If ble.sh is not a
   net improvement, disable only `caz.shell.blesh.enable` and switch again.

Do not enable public Jellyfin until the domain is replaced in `settings.nix`,
DNS is configured, and the deployment checklist has been completed.

## Routine commands

```bash
nix fmt
nix flake check --no-build
home-manager switch --flake .#joshcaz@wsl
sudo nixos-rebuild switch --flake .#homeserver
nix flake update
```

Run `nix flake update` intentionally and review changes before switching the
server. The lock file, once generated, belongs in Git.

Dependabot proposes grouped weekly lock-file updates. Each reviewed merge to
`main` produces a dated `caz.nix-*` release with SBOMs, provenance, closure
metadata, checksums, and attestations. The homeserver verifies and deploys new
releases during its maintenance window, with pre-deployment backups, health
checks, and live-generation rollback. See
[`docs/ci-and-releases.md`](docs/ci-and-releases.md) for the complete model,
[`docs/server-updates.md`](docs/server-updates.md) for deployment operations,
and [`docs/publication-checklist.md`](docs/publication-checklist.md)
before changing repository visibility.

Omit `--no-build` when you intentionally want to build both the full NixOS
system closure and Home Manager generation, not merely evaluate them.

## License

This project is available under the [MIT License](LICENSE).
