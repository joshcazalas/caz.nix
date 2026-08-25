{
  lib,
  pkgs,
  settings,
  ...
}:
let
  windowsBrowser = lib.getExe pkgs.wsl-open;
in
{
  imports = [
    ../../modules/home/common.nix
    ../../modules/home/development.nix
    ../../modules/home/shell.nix
    ../../modules/home/windows-vscode.nix
  ];

  home = {
    username = settings.user.name;
    homeDirectory = "/home/${settings.user.name}";
    packages = [ pkgs.wsl-open ];
    sessionVariables = {
      # OAuth and other web flows launched in WSL should use the Windows
      # default browser rather than searching for a Linux desktop browser.
      BROWSER = windowsBrowser;
      GH_BROWSER = windowsBrowser;
    };
    stateVersion = "26.05";
  };

  # This profile targets Ubuntu under WSL2, not NixOS-WSL.
  targets.genericLinux.enable = true;

  # This is the one experimental part of the shell stack. Turn it off and run
  # Home Manager again to return to ordinary Bash/Readline without removing
  # Atuin, fzf, Starship, or zoxide.
  caz.shell.blesh.enable = true;
  caz.shell.fonts.enable = true;
  caz.windows.vscode.enable = true;
}
