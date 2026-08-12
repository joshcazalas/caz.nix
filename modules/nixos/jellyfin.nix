{
  config,
  lib,
  settings,
  ...
}:
let
  publicCfg = settings.public;
in
{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  users.users.jellyfin.extraGroups = [
    "media"
    "render"
    "video"
  ];

  systemd.services.jellyfin = {
    requires = [ "homelab-data-directories.service" ];
    after = [ "homelab-data-directories.service" ];
    environment.LIBVA_DRIVER_NAME = "iHD";
  };

  assertions = [
    {
      assertion = !publicCfg.jellyfin || publicCfg.domain != "example.invalid";
      message = "Set settings.public.domain before enabling public Jellyfin.";
    }
  ];

  # Jellyfin is the sole initially public application. Authentication remains
  # in Jellyfin so native TV and mobile clients work without an Access gateway.
  services.caddy = lib.mkIf publicCfg.jellyfin {
    enable = true;
    email = settings.user.email;
    virtualHosts."jellyfin.${publicCfg.domain}".extraConfig = ''
      reverse_proxy 127.0.0.1:8096
    '';
  };

  networking.firewall.allowedTCPPorts = lib.mkIf publicCfg.jellyfin [
    80
    443
  ];
}
