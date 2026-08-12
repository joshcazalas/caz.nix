{
  settings,
  ...
}:
{
  imports = [
    ../../modules/home/common.nix
    ../../modules/home/development.nix
  ];

  home = {
    username = settings.user.name;
    homeDirectory = "/home/${settings.user.name}";
    stateVersion = "26.05";
  };

  # This profile targets Ubuntu under WSL2, not NixOS-WSL.
  targets.genericLinux.enable = true;
}
