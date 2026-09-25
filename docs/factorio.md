# Factorio Space Age

The homeserver runs the native NixOS `services.factorio` service with the
`factorio-headless` package pinned by `flake.lock` (currently 2.0.77).
The official base, quality, elevated-rails, and space-age content is enabled.
Players need the matching game version, Space Age content, and the pinned
mods below. No Steam client or server Steam login is required. Mod downloads
use an encrypted Factorio portal credential, delivered through systemd
credentials rather than stored in Nix expressions or command-line arguments.

## What lives where

- `hosts/homeserver/default.nix` enables the service and its public game port,
  and includes `factorio.joshcaz.com` in the existing dynamic DNS updater.
- `modules/nixos/factorio.nix` configures the upstream service, adds access
  initialization, and schedules backups. It uses the upstream service's
  DynamicUser, state directory, save creation, shutdown signal, and sandbox.
- `scripts/factorio-admin.py` owns local membership changes and backups.
- `modules/nixos/factorio-mods.json` pins the third-party mod archives.
- `scripts/factorio-prepare.py` verifies/downloads mods and selects the world.
- `modules/nixos/network-policy.nix` includes the reviewed UDP game port.
- `modules/nixos/release-updater.nix` includes Factorio health, backup, and
  storage checks in the deployment transaction.

Configuration lives in Nix. World saves, whitelist membership, operators, and
bans are mutable files under `/var/lib/factorio`. With systemd's DynamicUser,
that path points into `/var/lib/private/factorio`; backups resolve the link
and archive the contents, not an empty symlink. Access files and archives are
private. Player names never need to enter Git or release artifacts.

## Mods and world generation

The declared mod set is:

| Mod | Version |
| --- | --- |
| Alien Biomes | 0.7.4 |
| Alien Biomes Graphics (dependency) | 0.7.1 |
| Jetpack | 0.4.17 |
| AAI Containers & Warehouses | 0.3.2 |
| Rate Calculator | 3.3.8 |
| Factorio Library / flib (dependency) | 0.16.5 |
| Auto Deconstruct | 1.0.14 |
| Text Plates | 0.7.2 |
| Grappling Gun | 0.4.1 |
| Squeak Through 2 | 0.1.5 |

These versions were tested together with Factorio 2.0.77 and Space Age.
The manifest records exact portal download paths and SHA-256 checksums.
Startup fetches missing archives and verifies them before starting the game.
Already downloaded, verified archives work offline. The first download is
about 200 MiB, mostly Alien Biomes Graphics. Each manifest has its own mod
directory under `mod-sets/`, so stale mods cannot remain enabled after an
update. The downloader explicitly enables the official expansion as well.

The portal login is in `secrets/factorio.yaml`, encrypted for the same
administrator/server recipients as the other secrets. See
[`../secrets/README.md`](../secrets/README.md). Mod ZIP files and plaintext
credentials are not committed or included in public Nix build outputs.
`homelab.factorio.modManifest` owns the mod set; leave the upstream
`services.factorio.mods` and `mods-dat` options unset.

The host selects `homelab.factorio.world = "modded-space-age-v1"`. On first
activation, preparation creates a fresh modded world and selects it through
the state's `saves` symlink. The previously unplayed world's saves are moved
to `saves-before-declarative-worlds` after successful creation. Access lists
are preserved. Subsequent restarts, deployments, and mod updates reuse the
same world, including its newest autosave. Changing the world identity
explicitly selects another existing world or creates a new one; changing a
mod version or map setting alone never resets progress.

The three local Space Age saves inspected on 2026-09-24 all used standard
enemy settings. The new server world instead uses **75% enemy-base frequency**
and **100% base size** on Nauvis, with normal evolution and expansion.
This controls map generation, not an exact count of biters. The declaration
is `homelab.factorio.mapGenSettings.autoplace_controls.enemy-base` in the host.
Generation settings apply only when a world is first created. Later changes
to existing-world enemy generation, evolution, or expansion need an explicit
save/game update; reducing generation frequency does not remove existing
bases. Back up first when making such changes.

## First deployment and connecting

Review and release through the normal repository workflow. This change does
not itself modify the router. Forward **UDP 34197** to the homeserver's
reserved address, **192.168.1.124**. TCP forwarding and Caddy are not involved
in Factorio game traffic.

The existing Cloudflare updater creates/maintains a DNS-only IPv4 record for
`factorio.joshcaz.com` after activation. Check its service log if the record
does not appear. Keep this record DNS-only. IPv6 remains disabled by the
existing network policy.

On the server, add your **Factorio username**, then optionally make yourself
an operator:

```console
sudo factorio-access whitelist add YOUR_FACTORIO_USERNAME
sudo factorio-access operator add YOUR_FACTORIO_USERNAME
```

In Factorio, use Multiplayer -> Connect to address -> `factorio.joshcaz.com`.
The game is deliberately absent from the public server browser. Direct
connections remain available, and Factorio verifies player identities with
its account service. Use the in-game/account username, not a Steam display
name that differs from it.

Test from an external network as well as the LAN. If the router lacks NAT
loopback, LAN clients can use `192.168.1.124` while external friends use the
hostname. A successful local listener check cannot prove the router forward
or Internet path works.

## Managing access without a release

```console
sudo factorio-access whitelist list
sudo factorio-access whitelist add FRIEND
sudo factorio-access whitelist remove FRIEND
sudo factorio-access operator list
sudo factorio-access operator add FRIEND
sudo factorio-access operator remove FRIEND
```

Membership changes briefly stop the server, allowing it to save, then update
the JSON atomically and restart it. Connected players must reconnect. Listing
does not restart it. If the server was already stopped, it stays stopped.
Remove operator privileges before removing someone from the whitelist.
Names are compared without regard to case, matching Factorio's normalization.
A failed shutdown prevents the edit; a failed
edit still attempts to restart a previously running server.

Changes share a maintenance lock with deployment and backups, so the command
may wait during those operations. There is no RCON listener or administrative
password to distribute. Use these local commands for membership management.

**An empty Factorio whitelist permits everyone to join.** Initialization keeps
`__caz_whitelist_guard__` both whitelisted and banned. This reserved entry
cannot join, and ensures that first boot and removing the last real member
remain closed. The tool hides it from list output and refuses to change it.
Do not manually clear the whitelist or remove this ban, including through
in-game admin commands. Initialization repairs the guard at startup, and the
health probe rejects missing guard entries.

## Saves, backups, and resources

The world autosaves every ten minutes and pauses when empty. Startup selects
the latest save, including autosaves after an unclean exit.

A daily backup runs around 05:00–05:15 in the server's configured timezone.
It briefly stops the game, archives its state, and restarts it. Pre-deployment
backups use the same implementation. The seven most recent successful archives
are retained under `/var/backup/factorio`; extra manual/deployment backups also
count toward that limit. Archives include saves, access lists, and mod state;
logs and temporary files are excluded.

```console
sudo factorio-access backup
sudo systemctl status factorio factorio-backup.timer
sudo journalctl -u factorio -n 80
sudo factorio-access health
```

The health probe checks that the service's main process owns the expected UDP
listener and that the whitelist guard is present and banned. It does not
simulate a player login or check factory tick performance.

The initial service memory thresholds are 2 GiB (`MemoryHigh`) and 3 GiB
(`MemoryMax`). They are limits, not reserved RAM. This server has 8 GiB shared
with Minecraft and other applications; monitor memory pressure and revisit
both games' budgets as the factory grows. Hitting the hard limit can kill the
game, losing progress since its latest save.

The first release enabling Factorio is backed up by the previous generation,
which has no Factorio world yet. Subsequent deployments include it. Reverting
a NixOS generation restores software/configuration, **not mutable game state**.
For a save-format-incompatible update, restoring a matching pre-update archive
may also be necessary.

For recovery, stop Factorio, keep a separate copy of the current state, and
extract the chosen archive into the actual state directory. Review the archive
with `tar --list --zstd --file ARCHIVE` first. Restore matching game/mod versions
before starting; systemd re-establishes DynamicUser directory ownership. These
local archives are on the same SSD as the world and need an off-machine copy
for protection against disk failure.

## Reading and extending the implementation

Start with the host's service and world settings, then read `services.factorio` in
the local module. These assign existing upstream options. The additions below
that configure systemd lifecycle behavior; they do not reimplement the game
service. `lib.mkBefore` makes access initialization run before upstream world
creation, and `lib.mkIf` ties supporting behavior to service enablement.

The preparation hook runs before upstream save creation and installs an
explicit mod list containing Space Age and the pinned third-party mods.
Portal access runs at service startup so public CI does not need account
credentials. Adding/updating a mod means updating the manifest, including
required dependencies and a verified archive checksum, then testing the set
with the pinned game. Clients must synchronize to the same versions.

The `factorio` flake check tests mod checksum enforcement, credential error
redaction, world-switch failure handling, and restart idempotence, as well as
membership and backup failure handling. It then
starts the real pinned Space Age binary using the generated service settings,
checks the 75% enemy setting, changes its whitelist, saves, and restarts it.
Public CI tests the official expansion without third-party archives. Set
`FACTORIO_MOD_CACHE` to a directory of the pinned ZIPs when running
`tests/factorio-runtime.py` locally to test the complete mod set; provide the
other `FACTORIO_*` variables declared by the flake check as well. Neither run
needs a Factorio account or VM once archives are cached.
The offline build test asserts production identity verification
is enabled, then disables it only in the temporary loopback test settings;
`FACTORIO_TEST_ONLINE=true` preserves verification for a networked test run.
The generated systemd sandbox and real external player joins
still require validation on the NixOS host.

References: [upstream NixOS module](https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/services/games/factorio.nix),
[Factorio multiplayer](https://wiki.factorio.com/Multiplayer),
[console commands and whitelist behavior](https://wiki.factorio.com/Console).
