{ pkgs, nixpkgs }:
let
  prepare =
    name: gateway:
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
            options.homelab.homeAssistant = lib.mkOption {
              type = lib.types.attrs;
              default = {
                enable = true;
                https.hostName = "ha.example.test";
              };
            };
            options.homelab.cloudflareDdns.domains = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "service.example.test" ];
            };
            options.homelab.homeAccessGateway = lib.mkOption {
              type = lib.types.attrs;
              default = gateway;
            };
          })
        ];
      };
    in
    pkgs.writeShellScript "prepare-adguard-${name}" ''
      set -eu
      umask 077
      ${evaluated.config.systemd.services.adguardhome.preStart}
    '';
  gateway = {
    enable = true;
    address = "198.51.100.1/24";
    # Loopback sources allow testing both roles without a privileged network.
    administrator.peers = [ { address = "127.0.0.2"; } ];
    resident.peers = [ { address = "127.0.0.3"; } ];
  };
  preparations = {
    enabled = prepare "enabled" gateway;
    disabled = prepare "disabled" { enable = false; };
    empty = prepare "empty" (
      gateway
      // {
        administrator.peers = [ ];
        resident.peers = [ ];
      }
    );
    changed = prepare "changed" (
      gateway
      // {
        address = "198.51.100.2/24";
        administrator.peers = [ { address = "127.0.0.4"; } ];
      }
    );
  };
in
pkgs.runCommand "check-adguard-home"
  {
    nativeBuildInputs = [
      pkgs.adguardhome
      (pkgs.python3.withPackages (ps: [
        ps.pyyaml
        ps.dnspython
      ]))
    ];
    preparations = builtins.toJSON preparations;
    passAsFile = [ "preparations" ];
  }
  ''
    python ${./adguard_home.py} "$preparationsPath"
    touch "$out"
  ''
