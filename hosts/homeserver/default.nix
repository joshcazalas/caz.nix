{
  config,
  lib,
  settings,
  ...
}:
let
  sopsInstallUnit = "sops-install-secrets.service";
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

  sops = {
    defaultSopsFile = ../../secrets/homeserver.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      minecraft-whitelist = {
        owner = "minecraft";
        group = "minecraft";
        mode = "0400";
        restartUnits = [ "docker-minecraft.service" ];
      };
      minecraft-operators = {
        owner = "minecraft";
        group = "minecraft";
        mode = "0400";
        restartUnits = [ "docker-minecraft.service" ];
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
    # With the default sops-nix activation mode, secrets are installed before
    # switch-to-configuration starts services and no systemd unit exists. If
    # systemd activation is enabled later, order against the unit it creates.
    requires = lib.optional config.sops.useSystemdActivation sopsInstallUnit;
    after = lib.optional config.sops.useSystemdActivation sopsInstallUnit;
  };

  assertions = [
    {
      assertion = lib.elem "multi-user.target" config.systemd.services.docker-minecraft.wantedBy;
      message = "Minecraft must remain enabled for automatic startup.";
    }
    {
      assertion =
        config.sops.useSystemdActivation
        || !lib.elem sopsInstallUnit config.systemd.services.docker-minecraft.requires;
      message = "Minecraft cannot require a sops-nix service when secrets use activation scripts.";
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
