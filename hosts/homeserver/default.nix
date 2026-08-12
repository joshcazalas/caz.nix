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
    ../../modules/nixos/monitoring.nix
    ../../modules/nixos/optional-services.nix
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
