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
- at least one valid Java username is in the whitelist;
- the whitelist is enforced while Mojang account authentication and secure
  profiles remain enabled.

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

Production points only at sops-nix runtime paths, so neither player names nor a
decryption key enters the Nix store:

```nix
homelab.minecraft = {
  enable = true;
  acceptEula = true;
  openFirewall = true;
  gameMode = "survival";
  difficulty = "hard";
  seed = "...";
  whitelistFile = "/run/secrets/minecraft-whitelist";
  operatorsFile = "/run/secrets/minecraft-operators";
};
```

The selected seed is applied only when `/var/lib/minecraft` has no existing
world. Changing it later does not regenerate the world. Paper is running with
no plugins, so normal unmodified Minecraft Java clients can connect even though
the server implementation is Paper rather than Mojang's server JAR.

The encrypted whitelist contains the confirmed Java profile names for the
initial group. All players connect with normal, unmodified Java clients; no
Bedrock protocol translation or Floodgate authentication is enabled.

After activation:

```bash
systemctl status docker-minecraft --no-pager
sudo docker logs --tail 100 minecraft
systemctl status minecraft-proxy.socket --no-pager
systemctl list-timers minecraft-backup.timer --no-pager
```

Test from another LAN device with the server's reserved LAN address before
creating any public DNS record or router rule.

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

These backups protect against a bad update or accidental world damage, but they
are on the same NVMe and therefore are not a disaster-recovery copy. Copy them
to the replacement mirrored storage once it exists, then add an off-machine
copy before the world becomes irreplaceable.

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
Minecraft and its encrypted-secret wiring.
