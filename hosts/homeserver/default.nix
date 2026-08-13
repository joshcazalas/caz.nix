{
  settings,
  ...
}:
{
  imports = [
    ./hardware.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/storage.nix
    ../../modules/nixos/networking.nix
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

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = { inherit settings; };
    users.${settings.user.name} = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
