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
        email = settings.user.gitEmail;
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
    # dig and friends. Checking a DNS record is a routine step in this
    # homelab's runbooks, and reaching for `nix-shell` every time is friction
    # in exactly the moment something is already broken.
    bind.dnsutils
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
