{
  settings,
  ...
}:
{
  imports = [ ../../modules/home/common.nix ];

  home = {
    username = settings.user.name;
    homeDirectory = "/home/${settings.user.name}";
    stateVersion = "26.05";
  };
}
