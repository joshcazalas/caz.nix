{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.wireguard;
in
{
  options.homelab.wireguard = {
    enable = lib.mkEnableOption "WireGuard access to the server";
    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.1/24";
    };
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/wireguard-private-key";
      description = "Runtime path to the WireGuard private key; never put the key in Nix source.";
    };
    peers = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Peer attribute sets accepted by networking.wg-quick.";
    };
  };

  config = lib.mkMerge [
    {
      networking.useDHCP = lib.mkDefault true;
    }
    (lib.mkIf cfg.enable {
      networking.wg-quick.interfaces.wg0 = {
        address = [ cfg.address ];
        listenPort = cfg.listenPort;
        privateKeyFile = cfg.privateKeyFile;
        peers = cfg.peers;
      };
      networking.firewall.allowedUDPPorts = [ cfg.listenPort ];
    })
  ];
}
