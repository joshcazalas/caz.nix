{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.homelab;
  dataMount = settings.server.dataMount;
in
{
  options.homelab = {
    homeAssistant.enable = lib.mkEnableOption "Home Assistant";

    immich.enable = lib.mkEnableOption "Immich photo management";

    minecraft = {
      enable = lib.mkEnableOption "a containerized Paper Minecraft server";
      acceptEula = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Confirm acceptance of the Minecraft EULA.";
      };
      memory = lib.mkOption {
        type = lib.types.str;
        default = "6G";
      };
      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow TCP 25565 through the host firewall.";
      };
    };
  };

  config = lib.mkMerge [
    {
      # Enable these deliberately in hosts/homeserver/default.nix when wanted.
      homelab = {
        homeAssistant.enable = false;
        immich.enable = false;
        minecraft.enable = false;
        wireguard.enable = false;
      };

      assertions = [
        {
          assertion = !cfg.minecraft.enable || cfg.minecraft.acceptEula;
          message = "Minecraft requires homelab.minecraft.acceptEula = true.";
        }
      ];
    }

    (lib.mkIf cfg.homeAssistant.enable {
      services.home-assistant = {
        enable = true;
        openFirewall = true;
        extraComponents = [ "default_config" ];
        config.default_config = { };
      };
    })

    (lib.mkIf cfg.immich.enable {
      services.immich = {
        enable = true;
        host = "0.0.0.0";
        port = 2283;
        openFirewall = true;
        mediaLocation = "${dataMount}/photos/immich";
        accelerationDevices = [ "/dev/dri/renderD128" ];
      };
      users.users.immich.extraGroups = [
        "media"
        "render"
        "video"
      ];
      systemd.services.immich-server = {
        requires = [ "homelab-data-directories.service" ];
        after = [ "homelab-data-directories.service" ];
      };
    })

    (lib.mkIf cfg.minecraft.enable {
      virtualisation.oci-containers.containers.minecraft = {
        image = "itzg/minecraft-server:java21";
        autoStart = true;
        ports = [ "25565:25565" ];
        volumes = [ "${dataMount}/minecraft:/data" ];
        environment = {
          EULA = "TRUE";
          TYPE = "PAPER";
          MEMORY = cfg.minecraft.memory;
          ENABLE_ROLLING_LOGS = "true";
        };
      };
      networking.firewall.allowedTCPPorts = lib.mkIf cfg.minecraft.openFirewall [ 25565 ];
      systemd.services.docker-minecraft = {
        requires = [ "homelab-data-directories.service" ];
        after = [ "homelab-data-directories.service" ];
      };
    })
  ];
}
