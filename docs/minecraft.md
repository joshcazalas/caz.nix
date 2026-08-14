# Minecraft server

The homeserver has a declarative Paper server designed for a small trusted
group. It currently pins all three moving parts:

- Minecraft Java Edition `26.2`;
- stable Paper build `87`;
- `itzg/minecraft-server` release `2026.8.0` on Java 25, by OCI digest.

Paper 26.2 cannot safely downgrade a world after it upgrades its storage. Treat
every future version bump as a reviewed migration and verify a fresh backup
before deployment.

## Security model

The server starts only after all of these are set deliberately:

- the Minecraft EULA is accepted;
- the whitelist is enforced while Mojang account authentication and secure
  profiles remain enabled;
- membership and operator state persist locally and are changed only through
  the authenticated server console.

Docker publishes the game only on host loopback at TCP 25566. When
`openFirewall` is enabled, a sandboxed systemd socket proxy listens on TCP 25565
and the NixOS firewall opens that one port. This avoids Docker's published-port
rules bypassing the host firewall.

The host currently serves Minecraft over IPv4 only. IPv6 is disabled until a
separate IPv6 exposure policy has been reviewed and externally tested; do not
create an AAAA record for the server yet.

Internet access still requires a separate router TCP port forward. Do not
publish RCON, SSH, Docker, or a management dashboard. RCON remains reachable
only inside the container network so the backup job can quiesce the world.

## First activation

Nix declares the server policy but deliberately does not declare player names:

```nix
homelab.minecraft = {
  enable = true;
  acceptEula = true;
  openFirewall = true;
  gameMode = "survival";
  difficulty = "hard";
  seed = "...";
};
```

The selected seed is applied only when `/var/lib/minecraft` has no existing
world. Changing it later does not regenerate the world. Paper is running with
no plugins, so normal unmodified Minecraft Java clients can connect even though
the server implementation is Paper rather than Mojang's server JAR.

The container is enabled by default and starts with `multi-user.target`.
`whitelist.json` and `ops.json` live inside the persistent Minecraft data
directory. Releases never synchronize or overwrite them. A new installation
therefore starts fail-closed with nobody admitted until an administrator adds
the first account locally:

```bash
sudo minecraft-access whitelist add YOUR_JAVA_USERNAME
sudo minecraft-access operator add YOUR_JAVA_USERNAME
```

All players connect with normal, unmodified Java clients; no Bedrock protocol
translation or Floodgate authentication is enabled.

After activation:

```bash
systemctl status docker-minecraft --no-pager
sudo docker logs --tail 100 minecraft
systemctl status minecraft-proxy.socket --no-pager
systemctl list-timers minecraft-backup.timer --no-pager
```

Every `docker` command here needs `sudo`, and that is deliberate. The
administrator is not in the `docker` group, because membership in it allows
bind-mounting the host filesystem into a privileged container and is therefore
equivalent to passwordless root. Granting it would let a stolen SSH key reach
root without ever meeting the separate sudo password, which is the boundary
that makes public SSH acceptable. An assertion in `modules/nixos/security.nix`
keeps it that way.

Docker itself is enabled by this module rather than the base system, so a
homeserver with Minecraft disabled runs no container daemon at all.

Test from another LAN device with the server's reserved LAN address before
creating any public DNS record or router rule.

## Player access

Whitelist membership is operational state, not a release artifact. Manage it
immediately on the server without a Git commit, CI run, container restart, or
NixOS activation:

```bash
sudo minecraft-access whitelist add USERNAME
sudo minecraft-access whitelist remove USERNAME
sudo minecraft-access whitelist list

sudo minecraft-access operator add USERNAME
sudo minecraft-access operator remove USERNAME
sudo minecraft-access operator list
```

The wrapper validates Java usernames, requires root, sends changes over RCON
inside the container, persists Minecraft's standard JSON files, and records
successful mutations in the local system journal:

```bash
journalctl -t caz-minecraft-access
```

An operator must already be whitelisted, and the wrapper requires operator
privileges to be removed before that player can be removed from the whitelist.
This keeps the two local authorization lists consistent. Usernames appear only
in the server's state, backups, Minecraft logs, and local system journal—not in
the public repository or Nix store.

The underlying image also supports release-driven `WHITELIST_FILE`
synchronization, but that makes every small membership change a deployment and
can overwrite console changes at restart. This server intentionally uses
Minecraft's native mutable list instead. See the upstream image's
[whitelist documentation](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/#whitelist-players).

## Backups

The live world and local backups intentionally use the healthy NVMe:

```text
/var/lib/minecraft
/var/backup/minecraft
```

Every night the backup service disables world saving, flushes current state,
creates a compressed archive (excluding disposable logs, caches, and crash
reports), re-enables saving even if the archive fails, and retains seven daily
archives. Run and inspect it manually before inviting players:

```bash
sudo systemctl start minecraft-backup.service
systemctl status minecraft-backup.service --no-pager
sudo ls -lh /var/backup/minecraft
```

The archive includes `whitelist.json` and `ops.json`. These backups protect
against a bad update or accidental world damage, but they are on the same NVMe
and therefore are not a disaster-recovery copy. Copy them to the second SSD
after it is connected and tested, then add an off-machine copy before the world
becomes irreplaceable.

## Cloudflare DNS and router forwarding

For the default port, create a DNS-only `A` record such as
`play.example.com` pointing to the current public IPv4 address. Keep the real
hostname out of Git if desired: neither Minecraft nor this NixOS module needs
it. The orange-cloud
HTTP proxy cannot carry ordinary Minecraft Java TCP traffic; Cloudflare
Spectrum is a separate paid product. Forward only external TCP 25565 to TCP
25565 on the homeserver's reserved LAN address.

A hostname cannot remain genuinely private after it is published in public
DNS, and public TLS certificates can also make hostnames discoverable through
certificate-transparency logs. Encryption can keep it out of this repository;
it cannot hide a public Internet endpoint.

A domain is routing convenience, not authentication. The Microsoft/Mojang
login and enforced whitelist are what authorize players. If the public address
changes, add a narrowly scoped Cloudflare dynamic-DNS updater later rather than
placing an API token in Git.

## Routine operations

```bash
# Server log
sudo docker logs --follow minecraft

# One console command; RCON is not exposed on the host
sudo docker exec minecraft rcon-cli list

# Stop and start through systemd so Docker and dependencies stay coordinated
sudo systemctl stop docker-minecraft.service
sudo systemctl start docker-minecraft.service
```

Do not change `VERSION`, `PAPER_BUILD`, or the image digest directly on the
server. Propose all three through Git, require CI, and create a fresh backup
before activating the release. CI builds the real homeserver closure, including
Minecraft and its root-only access-management tool.
