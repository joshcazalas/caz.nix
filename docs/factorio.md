# Factorio Space Age

The homeserver runs the native NixOS `services.factorio` service with the
`factorio-headless` package pinned by `flake.lock` (currently 2.0.77).
The official base, quality, elevated-rails, and space-age content is enabled.
No Steam client, server Steam login, Factorio account token, or third-party
mods are required on the server. Players need the matching game version and
Space Age content.

## What lives where

- `hosts/homeserver/default.nix` enables the service and its public game port,
  and includes `factorio.joshcaz.com` in the existing dynamic DNS updater.
- `modules/nixos/factorio.nix` configures the upstream service, adds access
  initialization, and schedules backups. It uses the upstream service's
  DynamicUser, state directory, save creation, shutdown signal, and sandbox.
- `scripts/factorio-admin.py` owns local membership changes and backups.
- `modules/nixos/network-policy.nix` includes the reviewed UDP game port.
- `modules/nixos/release-updater.nix` includes Factorio health, backup, and
  storage checks in the deployment transaction.

Configuration lives in Nix. World saves, whitelist membership, operators, and
bans are mutable files under `/var/lib/factorio`. With systemd's DynamicUser,
that path points into `/var/lib/private/factorio`; backups resolve the link
and archive the contents, not an empty symlink. Access files and archives are
private. Player names never need to enter Git or release artifacts.

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

Start with the host's two service choices, then read `services.factorio` in
the local module. These assign existing upstream options. The additions below
that configure systemd lifecycle behavior; they do not reimplement the game
service. `lib.mkBefore` makes access initialization run before upstream world
creation, and `lib.mkIf` ties supporting behavior to service enablement.

The module explicitly manages the official Space Age mod list on startup.
Third-party mods need a deliberate extension of that policy, matching client
versions, and a save backup. A future map viewer can be a separate module,
with its own publishing and resource decisions.

The `factorio` flake check tests membership and backup failure handling, then
starts the real pinned Space Age binary using the generated service settings,
changes its whitelist, saves, and restarts it. It runs without a Factorio
account or VM. The offline build test asserts production identity verification
is enabled, then disables it only in the temporary loopback test settings;
`FACTORIO_TEST_ONLINE=true` preserves verification for a networked test run.
The generated systemd sandbox and real external player joins
still require validation on the NixOS host.

References: [upstream NixOS module](https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/services/games/factorio.nix),
[Factorio multiplayer](https://wiki.factorio.com/Multiplayer),
[console commands and whitelist behavior](https://wiki.factorio.com/Console).
