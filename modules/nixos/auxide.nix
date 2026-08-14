{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.auxide;
in
{
  options.homelab.auxide.enable = lib.mkEnableOption "Auxide Discord music bot";

  config = lib.mkIf cfg.enable {
    services.auxide = {
      enable = true;
      # The first release streams YouTube directly. This read-only membership
      # reserves access to /var/lib/homelab/media for the future NAS adapter.
      extraGroups = [ "media" ];
      memoryMax = "1G";
    };
  };
}
