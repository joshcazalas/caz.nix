{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.homelab.homeAssistant;
  containerName = "homeassistant";
  container = config.virtualisation.oci-containers.containers.${containerName};
in
{
  options.homelab.homeAssistant = {
    enable = lib.mkEnableOption "Home Assistant Container";

    image = lib.mkOption {
      type = lib.types.strMatching ".+@sha256:[0-9a-f]{64}";
      default = "ghcr.io/home-assistant/home-assistant:2026.8.3@sha256:8e9751cb66d3ba6624f5360a7d31b0c6821f7f5b3fb8ba0d10d58f0f481c540c";
      description = "Immutable linux/amd64 Home Assistant Container image reference.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${settings.server.dataRoot}/home-assistant";
      description = "Persistent Home Assistant configuration and database directory.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "${settings.server.dataRoot}/" cfg.dataDir;
        message = "Home Assistant state must reside beneath the declared homelab data root.";
      }
      {
        assertion = config.virtualisation.docker.enable;
        message = "Home Assistant Container requires the shared Docker runtime.";
      }
      {
        assertion = container.ports == [ ] && lib.elem "--network=host" container.extraOptions;
        message = ''
          Home Assistant must use host networking for LAN discovery without a
          Docker-published port; the NixOS firewall remains authoritative.
        '';
      }
      {
        assertion = !container.privileged && !lib.elem "--privileged" container.extraOptions;
        message = "Home Assistant hardware access must be granted per device, not with --privileged.";
      }
      {
        assertion = lib.elem "${cfg.dataDir}:/config:rw" container.volumes;
        message = "Home Assistant's persistent state directory must be mounted at /config.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 root root -"
    ];

    virtualisation.oci-containers.containers.${containerName} = {
      inherit (cfg) image;
      autoStart = true;
      volumes = [
        "${cfg.dataDir}:/config:rw"
        "/etc/localtime:/etc/localtime:ro"
      ];
      environment.TZ = settings.server.timeZone;
      extraOptions = [
        "--init"
        "--memory=2g"
        "--network=host"
        "--pids-limit=512"
        "--security-opt=no-new-privileges:true"
        "--stop-timeout=60"
      ];
    };

    # Home Assistant may need more than Docker's default ten seconds to close
    # its SQLite database cleanly. The container stop timeout is the effective
    # grace period; leave additional room for the generated systemd wrapper.
    systemd.services.docker-homeassistant.serviceConfig.TimeoutStopSec = lib.mkForce 90;
  };
}
