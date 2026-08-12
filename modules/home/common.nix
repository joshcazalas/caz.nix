{
  pkgs,
  settings,
  ...
}:
{
  programs.home-manager.enable = true;

  programs.bash = {
    enable = true;
    enableCompletion = true;
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = settings.user.name;
        email = settings.user.email;
      };
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  home.packages = with pkgs; [
    age
    bat
    btop
    eza
    fd
    gh
    jq
    ripgrep
    sops
    tree
    unzip
    yq-go
    zip
  ];
}
