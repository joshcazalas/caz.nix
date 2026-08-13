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
    ../../modules/nixos/filesharing.nix
    ../../modules/nixos/adguard-home.nix
    ../../modules/nixos/jellyfin.nix
    ../../modules/nixos/minecraft.nix
    ../../modules/nixos/monitoring.nix
    ../../modules/nixos/optional-services.nix
    ../../modules/nixos/release-updater.nix
  ];

  # The verified updater is ready to opt into after the physical server has
  # been installed and its first known-good generation has been tested.
  homelab.releaseUpdater.enable = false;

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
