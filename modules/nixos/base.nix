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
    # Deliberately excludes "docker". Membership in that group is equivalent to
    # passwordless root, because anyone in it can bind-mount the host
    # filesystem into a privileged container. Granting it here would let a
    # stolen SSH key reach root without ever meeting the separate sudo
    # password. Use `sudo docker` for the occasional manual container command.
    extraGroups = [
      "media"
      "render"
      "video"
      "wheel"
    ];
    openssh.authorizedKeys.keys = settings.user.sshPublicKeys;
  };

  # A stolen SSH key should not immediately grant root. The local account
  # password remains a separate sudo factor and is never accepted by sshd.
  security.sudo.wheelNeedsPassword = true;

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      AllowAgentForwarding = false;
      AllowTcpForwarding = "local";
      AllowUsers = [ settings.user.name ];
      AuthenticationMethods = "publickey";
      ClientAliveCountMax = 2;
      ClientAliveInterval = 300;
      GatewayPorts = "no";
      KbdInteractiveAuthentication = false;
      LoginGraceTime = 30;
      MaxAuthTries = 3;
      MaxStartups = "10:30:30";
      PasswordAuthentication = false;
      PerSourceMaxStartups = 3;
      PermitEmptyPasswords = false;
      PermitRootLogin = "no";
      PermitTunnel = false;
      PubkeyAuthentication = true;
      X11Forwarding = false;
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

  # The container runtime is not part of the base system. It is enabled by the
  # module that actually needs it, so a host running no containers does not
  # carry a root-privileged daemon and its bridge networks.

  environment.systemPackages = with pkgs; [
    bind.dnsutils
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
