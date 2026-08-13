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
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.homeAssistant.enable {
      services.home-assistant = {
        enable = true;
        openFirewall = false;
        extraComponents = [ "default_config" ];
        config.default_config = { };
      };
    })

    (lib.mkIf cfg.immich.enable {
      services.immich = {
        enable = true;
        host = "0.0.0.0";
        port = 2283;
        openFirewall = false;
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

  ];
}
