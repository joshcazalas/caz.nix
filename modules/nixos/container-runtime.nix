{
  config,
  lib,
  pkgs,
  ...
}:
let
  containerMaintenanceDirectory = "/run/caz-container-maintenance";
  containerMaintenanceLock = "${containerMaintenanceDirectory}/lock";
  containerRuntimeRequired =
    config.homelab.minecraft.enable
    || config.homelab.homeAssistant.enable
    || (config.services.auxide.enable && config.services.auxide.poTokenProvider.enable);
  dockerPrune = pkgs.writeShellApplication {
    name = "caz-docker-prune";
    runtimeInputs = [
      config.virtualisation.docker.package
      pkgs.util-linux
    ];
    text = ''
      exec 8>${lib.escapeShellArg containerMaintenanceLock}
      echo "Waiting for exclusive container maintenance access"
      flock --exclusive 8

      docker system prune --force --all
    '';
  };
in
{
  config = lib.mkIf containerRuntimeRequired {
    virtualisation.docker = {
      enable = true;

      # Required by the KillMode=process the upstream unit ships. systemd
      # kills only dockerd on stop and leaves every container, shim, and
      # port forwarder running. Re-adopting those processes prevents stale
      # listeners from becoming detached from the daemon after a restart.
      daemon.settings.live-restore = true;

      # Every mutable service directory is mounted from the host, so unused
      # images are disposable. Aggressive pruning shares a lock with backups
      # and deployments because the generated OCI units remove their stopped
      # containers, briefly leaving their pinned images unreferenced.
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" ];
      };
    };

    virtualisation.oci-containers.backend = "docker";

    systemd.tmpfiles.rules = [
      "d ${containerMaintenanceDirectory} 0700 root root -"
    ];

    systemd.services.docker-prune.serviceConfig = {
      ExecStart = lib.mkForce (lib.getExe dockerPrune);
      # A deployment may legitimately hold the lock through activation, a
      # ten-minute health window, and rollback. Wait instead of skipping that
      # week's cleanup at systemd's default start timeout.
      TimeoutStartSec = "infinity";
    };
  };
}
