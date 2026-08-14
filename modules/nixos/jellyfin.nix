{
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
    openFirewall = false;

    # The Coffee Lake UHD 630 exposes the required codecs through the iHD
    # VA-API driver. QSV fails to create an MFX session with the current
    # oneVPL-based Jellyfin FFmpeg build, so keep the tested VA-API path as the
    # declarative source of truth.
    forceEncodingConfig = true;
    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      device = "/dev/dri/by-path/pci-0000:00:02.0-render";
    };
    transcoding = {
      enableHardwareEncoding = true;
      enableIntelLowPowerEncoding = false;
      enableToneMapping = false;
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        mpeg2 = true;
        vc1 = true;
        vp8 = true;
        vp9 = true;
      };
    };
  };

  users.users.jellyfin.extraGroups = [
    "media"
    "render"
    "video"
  ];

  systemd.services.jellyfin = {
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
    virtualHosts."jellyfin.${publicCfg.domain}" = {
      # Jellyfin can place API keys in request URLs. Keep Caddy's request log
      # disabled rather than persisting bearer credentials in access logs.
      logFormat = "output discard";
      extraConfig = ''
        reverse_proxy 127.0.0.1:8096
      '';
    };
  };

  networking.firewall.allowedTCPPorts = lib.mkIf publicCfg.jellyfin [
    80
    443
  ];
}
