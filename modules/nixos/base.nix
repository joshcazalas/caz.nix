{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
{
  networking.hostName = settings.server.hostName;
  time.timeZone = settings.server.timeZone;

  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    graphics = {
      enable = true;
      extraPackages = [ pkgs.intel-media-driver ];
    };
  };

  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      trusted-users = [
        "root"
        "@wheel"
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  users.groups.media = { };
  users.users.${settings.user.name} = {
    isNormalUser = true;
    description = settings.user.name;
    extraGroups = [
      "docker"
      "media"
      "render"
      "video"
      "wheel"
    ];
    openssh.authorizedKeys.keys = [ settings.user.sshPublicKey ];
  };

  # SSH is key-only, so passwordless sudo provides a usable recovery path for
  # the initial bootstrap. Revisit this if the server becomes multi-user.
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services = {
    fstrim.enable = true;
    smartd = {
      enable = true;
      autodetect = true;
    };
  };

  zramSwap.enable = true;

  virtualisation = {
    docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" ];
      };
    };
    oci-containers.backend = "docker";
  };

  environment.systemPackages = with pkgs; [
    btop
    curl
    git
    htop
    intel-gpu-tools
    libva-utils
    lm_sensors
    pciutils
    smartmontools
    usbutils
    vim
  ];
}
