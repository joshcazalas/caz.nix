{
  config,
  lib,
  settings,
  ...
}:
let
  minecraftEnvironment = config.virtualisation.oci-containers.containers.minecraft.environment;
  releaseManagedMembershipVariables = [
    "EXISTING_OPS_FILE"
    "EXISTING_WHITELIST_FILE"
    "OPS"
    "OPS_FILE"
    "WHITELIST"
    "WHITELIST_FILE"
  ];
in
{
  imports = [
    ./hardware.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/storage.nix
    ../../modules/nixos/networking.nix
    ../../modules/nixos/network-policy.nix
    ../../modules/nixos/game-stream-gateway.nix
    ../../modules/nixos/security.nix
    ../../modules/nixos/cloudflare-ddns.nix
    ../../modules/nixos/filesharing.nix
    ../../modules/nixos/adguard-home.nix
    ../../modules/nixos/auxide.nix
    ../../modules/nixos/bluemap.nix
    ../../modules/nixos/jellyfin.nix
    ../../modules/nixos/minecraft.nix
    ../../modules/nixos/monitoring.nix
    ../../modules/nixos/monitoring-rules.nix
    ../../modules/nixos/optional-services.nix
    ../../modules/nixos/release-updater.nix
  ];

  # Releases deploy automatically during the configured maintenance window.
  # Kernel/initrd changes wait for a normal reboot; unattended reboot remains
  # disabled until boot-success rollback has been tested on this hardware.
  homelab.releaseUpdater.enable = true;

  # Keep each explicitly reviewed public hostname synchronized when the
  # residential IPv4 address changes. The scoped Cloudflare token is decrypted
  # only at activation time and never enters the Nix store.
  homelab.cloudflareDdns = {
    enable = true;
    domains = [
      "mc.${settings.public.domain}"
    ]
    ++ lib.optionals config.homelab.gameStreamGateway.enable [
      "game-vpn.${settings.public.domain}"
    ]
    ++ lib.optionals settings.public.ssh [ "ssh.${settings.public.domain}" ]
    ++ lib.optionals settings.public.jellyfin [ "jellyfin.${settings.public.domain}" ]
    ++ lib.optionals settings.public.bluemap [ "map.${settings.public.domain}" ];
  };

  # The game-stream VPN is a client-to-site gateway. It forwards only Sunshine
  # traffic to the host's reserved LAN address and remains isolated from a
  # future administrative/home VPN.
  homelab.gameStreamGateway = {
    enable = true;
    listenPort = 51820;
    hostAddress = "192.168.1.127";
  };

  homelab.auxide.enable = true;

  # Every listener stays on loopback and is reached through SSH local
  # forwarding. Alerts leave the house by email and Discord, and an external
  # dead man's switch reports the one failure this host can never report
  # itself: its own death. Add the Pi to `peers` once it is a NixOS host, and
  # the pair begins monitoring each other.
  homelab.monitoring = {
    enable = true;
    peers = [ ];
  };

  # Renders the overworld around spawn into static tiles served by Caddy over
  # HTTPS. Player markers stay off: the map is public, and live markers would
  # publish friends' usernames and positions to anyone with the URL.
  homelab.bluemap = {
    enable = true;
    # The permanent base, roughly 12k blocks from the world origin. The default
    # centre is the origin rather than the world spawn point, so this has to be
    # stated explicitly; moving spawn in-game does not move the render mask.
    renderCenter = {
      x = 12175;
      z = 1441;
    };
  };

  homelab.minecraft = {
    enable = true;
    acceptEula = true;
    openFirewall = true;
    gameMode = "survival";
    difficulty = "hard";
    seed = "1691256543523180978";
  };

  assertions = [
    {
      assertion = config.homelab.releaseUpdater.enable;
      message = "The homeserver policy requires verified automatic release deployment.";
    }
    {
      assertion = lib.elem "multi-user.target" config.systemd.services.docker-minecraft.wantedBy;
      message = "Minecraft must remain enabled for automatic startup.";
    }
    {
      assertion =
        minecraftEnvironment.ENABLE_WHITELIST == "TRUE" && minecraftEnvironment.ENFORCE_WHITELIST == "TRUE";
      message = "Minecraft must keep its locally managed whitelist enabled and enforced.";
    }
    {
      assertion = lib.all (
        variable: !builtins.hasAttr variable minecraftEnvironment
      ) releaseManagedMembershipVariables;
      message = "Minecraft releases must not synchronize mutable whitelist or operator membership.";
    }
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = { inherit settings; };
    users.${settings.user.name} = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
