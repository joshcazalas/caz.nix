{ pkgs }:
let
  serverAddress = "192.168.20.1";
  trustedAddress = "192.168.20.2";
  restrictedAddress = "192.168.20.3";

  settings.public = {
    ssh = true;
    jellyfin = false;
    bluemap = false;
  };

  homelabOptionStubs = { lib, ... }: {
    options.homelab = {
      gameStreamGateway = {
        enable = lib.mkEnableOption "test game-stream gateway";
        listenPort = lib.mkOption {
          type = lib.types.port;
          default = 51820;
        };
      };
      homeAccessGateway = {
        enable = lib.mkEnableOption "test home-access gateway";
        listenPort = lib.mkOption {
          type = lib.types.port;
          default = 51821;
        };
      };
      homeAssistant.enable = lib.mkEnableOption "test Home Assistant";
      immich.enable = lib.mkEnableOption "test Immich";
      minecraft = {
        enable = lib.mkEnableOption "test Minecraft";
        openFirewall = lib.mkEnableOption "test public Minecraft";
        port = lib.mkOption {
          type = lib.types.port;
          default = 25565;
        };
      };
    };
  };

  commonNode = {
    _module.args = { inherit settings; };
    imports = [ homelabOptionStubs ];
    networking.useDHCP = false;
    environment.systemPackages = [
      pkgs.curl
      pkgs.netcat-openbsd
    ];
    system.stateVersion = "26.05";
  };

  staticAddress = address: {
    ipv4.addresses = [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "network-policy";

  nodes = {
    server = {
      imports = [
        ../modules/nixos/network-policy.nix
        commonNode
      ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = staticAddress serverAddress;
      networking.firewall.allowedTCPPorts = [ 22 ];
      services.openssh.enable = true;
      homelab.networkPolicy.restrictedLANClients = [
        {
          address = restrictedAddress;
          allowedTCPPorts = [ 3000 ];
        }
      ];
      systemd.services.private-test-listener = {
        description = "Throwaway private service listener";
        wantedBy = [ "multi-user.target" ];
        requires = [ "network-addresses-eth1.service" ];
        after = [ "network-addresses-eth1.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python -m http.server 3000 --bind ${serverAddress}";
          Restart = "on-failure";
        };
      };
    };

    trusted = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = staticAddress trustedAddress;
    };

    restricted = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = staticAddress restrictedAddress;
    };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("firewall.service")
    server.wait_for_unit("sshd.service")
    server.wait_for_unit("private-test-listener.service")

    server.succeed(
      "iptables -w -C nixos-fw -s ${restrictedAddress}/32 -p tcp "
      "-m multiport --dports 3000 -j nixos-fw-accept"
    )
    server.succeed(
      "iptables -w -C nixos-fw -s ${restrictedAddress}/32 -p tcp "
      "-m multiport --dports 22,53,139,445,3000,5357,8096 -j nixos-fw-log-refuse"
    )
    server.succeed(
      "iptables -w -C nixos-fw ! -i 'wg+' -s 192.168.0.0/16 -p tcp "
      "-m multiport --dports 22,53,139,445,3000,5357,8096 -j nixos-fw-accept"
    )

    trusted.wait_until_succeeds("nc -z -w 2 ${serverAddress} 22")
    trusted.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${serverAddress}:3000/ >/dev/null"
    )

    restricted.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${serverAddress}:3000/ >/dev/null"
    )
    restricted.fail("nc -z -w 2 ${serverAddress} 22")

    server.succeed("systemctl reload firewall.service")
    restricted.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${serverAddress}:3000/ >/dev/null"
    )
    restricted.fail("nc -z -w 2 ${serverAddress} 22")
  '';
}
