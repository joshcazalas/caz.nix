{
  config,
  settings,
  ...
}:
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

  sops = {
    defaultSopsFile = ../../secrets/homeserver.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      minecraft-whitelist = {
        owner = "minecraft";
        group = "minecraft";
        mode = "0400";
      };
      minecraft-operators = {
        owner = "minecraft";
        group = "minecraft";
        mode = "0400";
      };
    };
  };

  homelab.minecraft = {
    enable = true;
    acceptEula = true;
    openFirewall = true;
    gameMode = "survival";
    difficulty = "hard";
    seed = "1691256543523180978";
    whitelistFile = config.sops.secrets.minecraft-whitelist.path;
    operatorsFile = config.sops.secrets.minecraft-operators.path;
  };

  systemd.services.docker-minecraft = {
    requires = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = { inherit settings; };
    users.${settings.user.name} = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
