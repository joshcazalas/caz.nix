{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  windowsBrowser = lib.getExe pkgs.wsl-open;
  awsRegion = "us-east-1";
  awsSsoSession = "personal-aws";
  mkAwsProfile = sso_account_id: sso_role_name: {
    inherit sso_account_id sso_role_name;
    sso_session = awsSsoSession;
    region = awsRegion;
    output = "json";
  };
in
{
  imports = [
    ../../modules/home/common.nix
    ../../modules/home/development.nix
    ../../modules/home/shell.nix
    ../../modules/home/ssh.nix
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
      "sso-session ${awsSsoSession}" = {
        sso_start_url = "https://d-906786c4bb.awsapps.com/start";
        sso_region = awsRegion;
        sso_registration_scopes = "sso:account:access";
      };

      "profile management" = mkAwsProfile "357964519547" "BootstrapAdministrator";
      "profile management-readonly" = mkAwsProfile "357964519547" "ReadOnly";
      "profile deployment" = mkAwsProfile "245459924498" "BootstrapAdministrator";
      "profile deployment-readonly" = mkAwsProfile "245459924498" "ReadOnly";
      "profile uat" = mkAwsProfile "732006412638" "BootstrapAdministrator";
      "profile uat-readonly" = mkAwsProfile "732006412638" "ReadOnly";
      "profile production" = mkAwsProfile "134604497564" "BootstrapAdministrator";
      "profile production-readonly" = mkAwsProfile "134604497564" "ReadOnly";
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
}
