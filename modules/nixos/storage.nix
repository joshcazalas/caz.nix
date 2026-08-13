{
  pkgs,
  settings,
  ...
}:
let
  dataMount = settings.server.dataMount;
in
{
  # A single Btrfs disk gives checksums, compression, and snapshots, but it is
  # not redundancy and cannot repair corrupted data without another copy.
  fileSystems.${dataMount} = {
    device = "/dev/disk/by-label/HOMELAB_DATA";
    fsType = "btrfs";
    options = [
      "compress=zstd:3"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=10s"
    ];
  };

  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ dataMount ];
    interval = "monthly";
  };

  # Do not create these directories on the SSD when the data disk is missing.
  systemd.services.homelab-data-directories = {
    description = "Create homelab data directories on the mounted data disk";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = dataMount;
    path = [ pkgs.coreutils ];
    script = ''
      install -d -m 2775 -o root -g media \
        ${dataMount}/backups \
        ${dataMount}/media \
        ${dataMount}/photos \
        ${dataMount}/shares
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };
}
