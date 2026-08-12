{
  settings,
  ...
}:
{
  imports = [
    ../../modules/home/common.nix
    ../../modules/home/shell.nix
  ];

  home = {
    username = settings.user.name;
    homeDirectory = "/home/${settings.user.name}";
    stateVersion = "26.05";
  };

  # SSH clients render the Nerd Font, so the server only needs the shared
  # interactive shell configuration—not a local copy of the font files.
  caz.shell.blesh.enable = true;
}
