{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.auxide;

  providerEnabled = config.services.auxide.poTokenProvider.enable;
  providerName = "auxide-pot-provider";
  providerBackend = config.virtualisation.oci-containers.backend;
  providerService = "${providerBackend}-${providerName}";
  providerContainer = config.virtualisation.oci-containers.containers.${providerName};
  providerBackendPackage =
    if providerBackend == "docker" then
      config.virtualisation.docker.package
    else
      config.virtualisation.podman.package;

  # The generic oci-containers pre-start unconditionally reloads imageFile and
  # proceeds straight from removing the old container to publishing its port.
  # Both are poor activation boundaries: an already-present immutable image
  # needs no daemon mutation, and docker-proxy can retain the loopback listener
  # briefly after `docker rm` returns. A failure there fails systemd's initial
  # start job, which makes switch-to-configuration reject the entire release
  # before the provider's Restart= policy gets a chance to recover.
  #
  # Keep the wait bounded so a real port conflict still fails activation. The
  # release updater then rolls back exactly as it does for any other unit that
  # cannot start.
  providerPreStart = pkgs.writeShellApplication {
    name = "caz-auxide-pot-provider-pre-start";
    runtimeInputs = [
      providerBackendPackage
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
    ];
    text = ''
      backend=${lib.escapeShellArg providerBackend}
      container_name=${lib.escapeShellArg providerName}
      image=${lib.escapeShellArg providerContainer.image}
      port=${lib.escapeShellArg (toString config.services.auxide.poTokenProvider.port)}

      "$backend" rm --force "$container_name" >/dev/null 2>&1 || true

      ${lib.optionalString (providerContainer.imageFile != null) ''
        if ! "$backend" image inspect "$image" >/dev/null 2>&1; then
          echo "Loading the pinned Auxide proof-of-origin provider image"
          "$backend" load --input ${lib.escapeShellArg (toString providerContainer.imageFile)}
        fi
      ''}

      for attempt in {1..12}; do
        if ! ss --no-header --listening --numeric --tcp "sport = :$port" | grep --quiet .; then
          exit 0
        fi

        if (( attempt == 12 )); then
          echo "Port 127.0.0.1:$port is still occupied after waiting for the old provider to stop." >&2
          exit 1
        fi

        echo "Waiting for the old Auxide provider to release 127.0.0.1:$port (attempt $attempt/12)"
        sleep 5
      done
    '';
  };
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

    systemd.services = lib.mkIf providerEnabled {
      ${providerService}.serviceConfig.ExecStartPre = lib.mkForce [ (lib.getExe providerPreStart) ];
    };
  };
}
