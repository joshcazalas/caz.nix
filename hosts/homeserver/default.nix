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
    ../../modules/nixos/cloudflare-ddns.nix
    ../../modules/nixos/filesharing.nix
    ../../modules/nixos/adguard-home.nix
    ../../modules/nixos/jellyfin.nix
    ../../modules/nixos/minecraft.nix
    ../../modules/nixos/monitoring.nix
    ../../modules/nixos/optional-services.nix
    ../../modules/nixos/release-updater.nix
  ];

  # Releases deploy automatically during the configured maintenance window.
  # Kernel/initrd changes wait for a normal reboot; unattended reboot remains
  # disabled until boot-success rollback has been tested on this hardware.
  homelab.releaseUpdater.enable = true;

  # Keep the public Minecraft A record synchronized when the residential
  # public IPv4 address changes. The scoped Cloudflare token is decrypted only
  # at activation time and never enters the Nix store.
  homelab.cloudflareDdns.enable = true;

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
