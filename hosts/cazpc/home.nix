{
  config,
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
    ../../modules/home/ssh.nix
    ../../modules/home/windows-vscode.nix
  ];

  home = {
    username = settings.user.name;
    homeDirectory = "/home/${settings.user.name}";
    packages = with pkgs; [
      wsl-open
    ];
    sessionVariables = {
      # OAuth and other web flows launched in WSL should use the Windows
      # default browser rather than searching for a Linux desktop browser.
      BROWSER = windowsBrowser;
      GH_BROWSER = windowsBrowser;
    };
    stateVersion = "26.05";
  };

  programs.awscli = {
    enable = true;
    settings = {
      "sso-session mor" = {
        sso_start_url = "https://d-906786c4bb.awsapps.com/start";
        sso_region = "us-east-1";
        sso_registration_scopes = "sso:account:access";
      };

      "profile mor-management" = {
        sso_session = "mor";
        sso_account_id = "357964519547";
        sso_role_name = "BootstrapAdministrator";
        region = "us-east-1";
        output = "json";
      };

      "profile mor-management-readonly" = {
        sso_session = "mor";
        sso_account_id = "357964519547";
        sso_role_name = "ReadOnly";
        region = "us-east-1";
        output = "json";
      };

      "profile mor-uat" = {
        sso_session = "mor";
        sso_account_id = "732006412638";
        sso_role_name = "BootstrapAdministrator";
        region = "us-east-1";
        output = "json";
      };

      "profile mor-uat-readonly" = {
        sso_session = "mor";
        sso_account_id = "732006412638";
        sso_role_name = "ReadOnly";
        region = "us-east-1";
        output = "json";
      };

      "profile mor-prod" = {
        sso_session = "mor";
        sso_account_id = "134604497564";
        sso_role_name = "BootstrapAdministrator";
        region = "us-east-1";
        output = "json";
      };

      "profile mor-prod-readonly" = {
        sso_session = "mor";
        sso_account_id = "134604497564";
        sso_role_name = "ReadOnly";
        region = "us-east-1";
        output = "json";
      };
    };
  };

  # Adopt the existing hand-written config on the first Home Manager switch.
  home.file."${config.home.homeDirectory}/.aws/config".force = true;

  # This profile targets Ubuntu under WSL2, not NixOS-WSL.
  targets.genericLinux.enable = true;

  # This is the one experimental part of the shell stack. Turn it off and run
  # Home Manager again to return to ordinary Bash/Readline without removing
  # Atuin, fzf, Starship, or zoxide.
  caz.shell.blesh.enable = true;
  caz.shell.fonts.enable = true;
  caz.windows.vscode.enable = true;
}
