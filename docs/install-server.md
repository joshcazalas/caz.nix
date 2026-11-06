# Server installation-day checklist

Nothing in this document should be run against a disk until the PC is present
and every device identity has been checked. Only the explicitly verified NVMe
is an installation target; all unrelated disks must remain untouched.

## Proposed layout

| Physical disk | Partition | Filesystem | Label | Mount |
| --- | --- | --- | --- | --- |
| NVMe SSD | 1 GiB EFI system partition | FAT32 | `NIXOS_BOOT` | `/boot` |
| NVMe SSD | remainder | ext4 | `NIXOS_ROOT` | `/` |

There is no RAID and no disk swap. zram is enabled. The operating system,
application databases, and current shared data all live on the root NVMe. The
secondary backup filesystem is mounted separately as described below. `/srv`
is not a storage contract. Only the root disk is an initial OS installation target.

## Before erasing anything

1. Leave unrelated storage unplugged.
2. Boot the current NixOS minimal ISO in UEFI mode.
3. Inventory disks with model, serial, size, transport, and existing mounts:

   ```bash
   lsblk -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
   findmnt
   ```

4. Match model **and serial** to the physical drive. Never select a target by
   `/dev/sdX` name or size alone.
5. Inspect SMART data before trusting it:

   ```bash
   sudo smartctl --scan-open
   sudo smartctl -a /dev/DEVICE
   sudo smartctl -t long /dev/DEVICE
   ```

6. After the reported test duration, confirm the extended test completed
   without error.
7. Keep device identifiers and health reports in private installation notes
   outside Git.

The exact destructive partitioning commands are intentionally deferred until
those identifiers are available. At that point the declarative label contract
in `hosts/homeserver/hardware.nix` can be verified before formatting.

## Installation sequence

1. Partition and format only the verified NVMe with the labels in the table
   above.
2. Mount `NIXOS_ROOT` at `/mnt` and `NIXOS_BOOT` at `/mnt/boot`.
3. Make this repository available in the installer environment.
4. Check evaluation before installation:

   ```bash
   nix flake check --no-build
   sudo nixos-install --flake .#homeserver
   ```

5. Reboot, then make a DHCP reservation in the router so the server's LAN
   address stays stable.

Jellyfin uses Intel VA-API through the `iHD` driver. Verify its configured
render-device path locally before testing transcoding.

## Secondary backup filesystem

The primary filesystem keeps live application state, media, and original
backups. A separate ext4 filesystem labeled `CAZ_BACKUPS` supplies a second
copy at `/var/backup-secondary`.

### Provisioning

Identify and test the intended disk locally, confirm whether its existing files
can be erased, and verify that neither it nor its partitions are mounted.
Partition and format only that verified device. Assign `CAZ_BACKUPS` to the
new ext4 filesystem and ensure that this label is unique among attached disks.
Never repeat formatting on an existing backup volume. No format or wipe occurs
during NixOS activation.

Device serials, filesystem UUIDs, hardware inventory, diagnostic results, and
installation history belong in private records, not this public guide. The
configuration uses `/dev/disk/by-label/CAZ_BACKUPS`; its preflight compares the
mounted block device against the device resolved by that label. This relies on
correct local provisioning and a unique label, rather than a published serial.

Deploy the reviewed repository change using the normal release process, or
switch a reviewed checkout with `sudo nixos-rebuild switch --flake .#homeserver`.
Then create the first second copy and inspect it:

```bash
findmnt /var/backup-secondary
sudo systemctl start caz-secondary-backup.service
sudo journalctl -u caz-secondary-backup.service -n 60 --no-pager
sudo du -h --max-depth=1 /var/backup-secondary
sudo cat /var/backup-secondary/last-success
systemctl list-timers caz-secondary-backup.timer
```

The timer runs daily at 06:30 plus up to 15 minutes, and catches up after a missed
run. It copies only finalized Minecraft, Factorio, and pre-deployment application
archives. Existing original backups remain intact. Retention on the secondary
filesystem is 30 days by archive mtime, plus any older archives still retained
on the main SSD; pruning occurs only
after all three sources copy successfully. This is not a fixed space quota.

The service verifies the exact mounted block device, ext4, writable status,
at least 10 GiB free before copying, and available inodes. An empty/missing
source fails the job without pruning. Rsync checks file contents on repeat runs
and publishes copies by rename. These checks verify copying, not restorability
of application data; a restore drill remains necessary. Failed services are
covered by the existing systemd monitoring alert.

The mount is optional at boot (`nofail`) but required by the copy service.
A missing or failed backup filesystem cannot redirect copies onto the main disk.
The copy service does not stop applications or create fresh archives: game backups keep
their daily schedules, while Home Assistant, Jellyfin, AdGuard, Samba and Grafana
state is only as fresh as the latest pre-deployment backup. Media and general
shared files are not included. The two disks share a host and power supply;
an off-site copy is still separate future work.

## First local setup

From another LAN machine:

```bash
ssh joshcaz@homeserver
```

Then:

1. Create the Samba password with `sudo smbpasswd -a joshcaz`. Samba does not
   use the SSH key as a share password.
2. Open Jellyfin on `http://homeserver:8096`, create a unique admin account,
   and add `/var/lib/homelab/media/...` libraries. Give other people non-admin
   accounts.
3. In Jellyfin networking settings, add `127.0.0.1` as a known proxy before
   enabling Caddy.
4. Open AdGuard Home on `http://homeserver:3000`, finish setup, then configure
   the router's DHCP/LAN DNS server as `192.168.1.124`. Leave secondary DNS
   empty: a public secondary such as `1.1.1.1` or `9.9.9.9` can be selected at
   any time and would bypass the private `joshcaz.com` answers. After renewing
   a client's DHCP lease, verify both paths:

   ```bash
   dig @192.168.1.124 +short map.joshcaz.com A
   dig +short map.joshcaz.com A
   ```

   Both commands should return `192.168.1.124` on the LAN. Keep the
   [DNS recovery guide](dns-recovery.md) available locally: it covers temporary
   client/router DNS, restoring AdGuard, and a single-client drill. If the
   server is down, clients otherwise lose DNS. A future secondary local resolver
   should carry the same declarative rewrites.
5. Open Home Assistant on `http://homeserver:8123`, create its owner account,
   and verify the location, time zone, and units. See `docs/home-assistant.md`.
6. Provision the monitoring secrets and the external dead man's switch before
   the first release that enables monitoring. See `docs/monitoring.md`; the
   build fails closed until those keys exist. Grafana is then reached over SSH
   forwarding rather than the LAN.
7. Verify the Intel media path with `vainfo` and watch activity during a test
   transcode with `intel_gpu_top`.

## Deliberately postponed

- A UPS and automated graceful shutdown.
- Off-site backups and a tested application restore from the second local copy.
- Filesystem snapshots, after the long-term storage architecture is revisited.
- Immich activation.
- Public Jellyfin and its port forwarding.
