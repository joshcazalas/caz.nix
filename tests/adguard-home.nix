{ pkgs, nixpkgs }:
let
  evaluated = nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    specialArgs.settings.server = {
      hostName = "server";
      lanAddress = "192.0.2.10";
    };
    modules = [
      ../modules/nixos/adguard-home.nix
      ({ lib, ... }: {
        options.homelab.cloudflareDdns.domains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "service.example.test" ];
        };
      })
    ];
  };
in
pkgs.runCommand "check-adguard-home"
  {
    nativeBuildInputs = [
      pkgs.adguardhome
      pkgs.python3
    ];
    settings = builtins.toJSON evaluated.config.services.adguardhome.settings;
    passAsFile = [ "settings" ];
  }
  ''
    python ${./adguard_home.py} "$settingsPath"
    touch "$out"
  ''
