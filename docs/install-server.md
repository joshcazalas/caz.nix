# Server installation-day checklist

Nothing in this document should be run against a disk until the PC is present
and every device identity has been checked. Both target drives will be erased.

## Proposed layout

| Physical disk | Partition | Filesystem | Label | Mount |
| --- | --- | --- | --- | --- |
| SSD | 1 GiB EFI system partition | FAT32 | `NIXOS_BOOT` | `/boot` |
| SSD | remainder | ext4 | `NIXOS_ROOT` | `/` |
| 2 TB HDD | entire disk | Btrfs | `HOMELAB_DATA` | `/srv` |

There is no RAID and no disk swap. zram is enabled. The operating system and
application databases live on the SSD; bulky media and shares live on the HDD.

## Before erasing anything

1. Leave any unrelated USB storage unplugged.
2. Boot the current NixOS minimal ISO in UEFI mode.
3. Inventory disks with model, serial, size, transport, and existing mounts:

   ```bash
   lsblk -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
   findmnt
   ```

4. Match model **and serial** to the physical drives. Never select a target by
   `/dev/sdX` name or size alone.
5. Inspect SMART data for both drives before trusting them:

   ```bash
   sudo smartctl --scan-open
   sudo smartctl -a /dev/DEVICE
   ```

6. Record `/dev/disk/by-id/` names in the installation notes.

The exact destructive partitioning commands are intentionally deferred until
those identifiers are available. At that point the declarative label contract
in `hosts/homeserver/hardware.nix` can be verified before formatting.

## Installation sequence

1. Partition and format only the two verified target drives with the labels in
   the table above.
2. Mount `NIXOS_ROOT` at `/mnt`, `NIXOS_BOOT` at `/mnt/boot`, and
   `HOMELAB_DATA` at `/mnt/srv`.
3. Make this repository available in the installer environment.
4. Check evaluation before installation:

   ```bash
   nix flake check --no-build
   sudo nixos-install --flake .#homeserver
   ```

5. Reboot, then make a DHCP reservation for the server in the Google Fiber
   router so its LAN address stays stable.

The i7-9700K's Intel UHD 630 is configured for Jellyfin Quick Sync through the
`iHD` driver. Start without the RTX 2080 if practical: it saves idle power and a
PCIe slot, avoids proprietary driver state, and the iGPU is well suited to media
transcoding. Keep the card available if later workloads genuinely need CUDA.

## First local setup

From another LAN machine:

```bash
ssh joshcaz@homeserver
```

Then:

1. Create the Samba password with `sudo smbpasswd -a joshcaz`. Samba does not
   use the SSH key as a share password.
2. Open Jellyfin on `http://homeserver:8096`, create a unique admin account,
   and add `/srv/media/...` libraries. Give other people non-admin accounts.
3. In Jellyfin networking settings, add `127.0.0.1` as a known proxy before
   enabling Caddy.
4. Open AdGuard Home on `http://homeserver:3000`, finish setup, then configure
   the router's LAN DNS to the server's reserved address. Keep a fallback plan:
   if the server is down, clients otherwise lose DNS.
5. Open Beszel at `http://homeserver:8090`; add agents only after its initial
   account is established.
6. Verify the Intel media path with `vainfo` and watch activity during a test
   transcode with `intel_gpu_top`.

## Deliberately postponed

- A UPS and automated graceful shutdown.
- Off-site backups and a second local copy.
- Btrfs snapshot policy; snapshots are useful only after there is data worth
  retaining, and retention needs to match the small 2 TB capacity.
- Immich, Home Assistant, and Minecraft activation.
- Public DNS, port forwarding, WireGuard peers, and secret material.
