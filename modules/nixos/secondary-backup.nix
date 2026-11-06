{
  config,
  lib,
  pkgs,
  ...
}:
let
  mountPoint = "/var/backup-secondary";
  filesystem = config.fileSystems.${mountPoint};
  storageRequirements = pkgs.writeText "secondary-backup-storage.json" (
    builtins.toJSON [
      {
        path = mountPoint;
        filesystem = {
          inherit mountPoint;
          inherit (filesystem) device fsType;
        };
        minimumFreeMiB = 10240;
        minimumFreeInodes = 1024;
      }
    ]
  );
  preflight = pkgs.writeShellScript "secondary-backup-preflight" ''
    exec ${lib.getExe pkgs.python3} ${../../scripts/check-deployment-storage.py} \
      --config ${storageRequirements}
  '';
  copier = pkgs.writeShellApplication {
    name = "caz-copy-secondary-backups";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.rsync
      pkgs.util-linux
    ];
    text = ''
      export CAZ_SECONDARY_BACKUP_MOUNT=${lib.escapeShellArg mountPoint}
      export CAZ_SECONDARY_BACKUP_PREFLIGHT=${preflight}
      export CAZ_MINECRAFT_BACKUP_DIR=${lib.escapeShellArg config.homelab.minecraft.backupDir}
      ${builtins.readFile ../../scripts/copy-secondary-backups.sh}
    '';
  };
in
{
  systemd.services.caz-secondary-backup = {
    description = "Copy completed application backups to secondary storage";
    requires = [ "var-backup\\x2dsecondary.mount" ];
    bindsTo = [ "var-backup\\x2dsecondary.mount" ];
    after = [
      "var-backup\\x2dsecondary.mount"
      "minecraft-backup.service"
      "factorio-backup.service"
      "caz-release-updater.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe copier;
      UMask = "0077";
      Nice = 10;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "2h";
      ProtectSystem = "strict";
      ReadWritePaths = [
        mountPoint
        "/run/caz-container-maintenance"
      ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.timers.caz-secondary-backup = {
    description = "Daily second copy of application backups";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:30:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };
}
