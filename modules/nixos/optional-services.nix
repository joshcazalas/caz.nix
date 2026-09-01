{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.homelab;
  dataRoot = settings.server.dataRoot;
in
{
  options.homelab.immich.enable = lib.mkEnableOption "Immich photo management";

  config = lib.mkIf cfg.immich.enable {
    services.immich = {
      enable = true;
      host = "0.0.0.0";
      port = 2283;
      openFirewall = false;
      mediaLocation = "${dataRoot}/photos/immich";
      accelerationDevices = [ "/dev/dri/renderD128" ];
    };
    users.users.immich.extraGroups = [
      "media"
      "render"
      "video"
    ];
  };
}
