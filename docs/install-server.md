# Server installation-day checklist

Nothing in this document should be run against a disk until the PC is present
and every device identity has been checked. Only the explicitly verified NVMe
is an installation target; the unreliable HDD must remain untouched.

## Proposed layout

| Physical disk | Partition | Filesystem | Label | Mount |
| --- | --- | --- | --- | --- |
| NVMe SSD | 1 GiB EFI system partition | FAT32 | `NIXOS_BOOT` | `/boot` |
| NVMe SSD | remainder | ext4 | `NIXOS_ROOT` | `/` |

There is no RAID and no disk swap. zram is enabled. The operating system,
application databases, and current shared data all live on the root NVMe. The
unreliable HDD is deliberately absent from the configuration, and `/srv` is not
a storage contract. A second SSD will be designed and added separately after it
is connected and tested.

## Before erasing anything

1. Leave the unreliable HDD and any unrelated USB storage unplugged.
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
7. Record `/dev/disk/by-id/` names in the installation notes.

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

The i7-9700K's Intel UHD 630 is configured for Jellyfin VA-API transcoding
through the `iHD` driver. When an RTX 2080 remains installed, configure the ASUS
firmware under `Advanced > System Agent (SA) Configuration > Graphics
Configuration` with `Primary Display` set to `PCIE` and `iGPU Multi-Monitor`
enabled. Jellyfin selects the Intel render device by its stable PCI path, leaving
the RTX available for later CUDA workloads.

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
   the router's LAN DNS to the server's reserved address. Keep a fallback plan:
   if the server is down, clients otherwise lose DNS.
5. Provision the monitoring secrets and the external dead man's switch before
   the first release that enables monitoring. See `docs/monitoring.md`; the
   build fails closed until those keys exist. Grafana is then reached over SSH
   forwarding rather than the LAN.
6. Verify the Intel media path with `vainfo` and watch activity during a test
   transcode with `intel_gpu_top`.

## Deliberately postponed

- A UPS and automated graceful shutdown.
- Off-site backups and a second local copy.
- Filesystem snapshots, after the long-term storage architecture is revisited.
- Immich and Home Assistant activation.
- Public Jellyfin and its port forwarding.
