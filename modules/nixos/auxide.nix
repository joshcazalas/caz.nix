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
    assertions = [
      {
        # homelab.minecraft owns the container runtime on this host, so turning
        # Minecraft off takes the provider with it. Left unasserted that arrives
        # as YouTube tracks stopping a minute in, which reads as a bot problem
        # and never points here.
        assertion =
          !config.services.auxide.poTokenProvider.enable
          || config.virtualisation.docker.enable
          || config.virtualisation.podman.enable;
        message = ''
          Auxide's proof-of-origin token provider runs as a container and no container
          runtime is enabled. Enable one (homelab.minecraft.enable currently provides
          Docker), or set services.auxide.poTokenProvider.enable = false and point
          youtube.po_token_base_url at a provider running elsewhere.
        '';
      }
    ];

    services.auxide = {
      enable = true;
      # The first release streams YouTube directly. This read-only membership
      # reserves access to /var/lib/homelab/media for the future NAS adapter.
      extraGroups = [ "media" ];
      memoryMax = "1G";
    };
  };
}
