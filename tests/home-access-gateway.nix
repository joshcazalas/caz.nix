{
  pkgs,
  sops-nix,
}:
let
  # Disposable test-only keys are split so generic secret scanners continue to
  # catch accidentally committed production WireGuard material.
  fixtureKeys = {
    gateway = builtins.concatStringsSep "" [
      "+MAAEjYR"
      "wLJa9J3N"
      "3L7IvM0U"
      "rhK/305n"
      "Z64BtT3C"
      "IEM="
    ];
    administrator = builtins.concatStringsSep "" [
      "MGFxeYcN"
      "LTNBCgz5"
      "PmZMqoyy"
      "fx6L5P0g"
      "0dLZOXs4"
      "E1o="
    ];
    resident = builtins.concatStringsSep "" [
      "+FuZGhtd"
      "nKQPerel"
      "WrOnbarO"
      "znjF1aix"
      "CA3O/gm9"
      "lVE="
    ];
  };
  gatewayPublicKey = "bW/PIeb0C8q05svQlT24VAaw58GQrk/0tErYhFsJOjQ=";
  administratorPublicKey = "RYOxSmSdLVmFheEeofQGbQMLQLxhUjX5NdLu7H2P6VM=";
  residentPublicKey = "xIW4eCfneRlGcuNXvKJsGKdLUas+3XzQaln0eQfxyVg=";

  gatewayExternalAddress = "203.0.113.1";
  administratorExternalAddress = "203.0.113.2";
  residentExternalAddress = "203.0.113.3";
  gatewayLanAddress = "192.0.2.1";
  targetLanAddress = "192.0.2.2";
  otherLanAddress = "192.0.2.3";
  gatewayTunnelAddress = "198.51.100.1";
  administratorTunnelAddress = "198.51.100.2";
  residentTunnelAddress = "198.51.100.3";
  listenerPort = 51821;

  gatewayFixture = pkgs.writeText "wg-home-test.conf" ''
    [Interface]
    Address = ${gatewayTunnelAddress}/32
    PrivateKey = ${fixtureKeys.gateway}
    ListenPort = ${toString listenerPort}

    [Peer]
    PublicKey = ${administratorPublicKey}
    AllowedIPs = ${administratorTunnelAddress}/32

    [Peer]
    PublicKey = ${residentPublicKey}
    AllowedIPs = ${residentTunnelAddress}/32
  '';

  clientFixture =
    privateKey: address:
    pkgs.writeText "wg-home-client-test.conf" ''
      [Interface]
      Address = ${address}/32
      PrivateKey = ${privateKey}

      [Peer]
      PublicKey = ${gatewayPublicKey}
      Endpoint = ${gatewayExternalAddress}:${toString listenerPort}
      AllowedIPs = ${gatewayTunnelAddress}/32, ${targetLanAddress}/32, ${otherLanAddress}/32, ${administratorTunnelAddress}/32, ${residentTunnelAddress}/32
      PersistentKeepalive = 25
    '';

  staticAddress = address: {
    ipv4.addresses = [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };

  commonNode = {
    networking = {
      useDHCP = false;
      firewall.enable = true;
      nftables.enable = false;
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.socat
      pkgs.wireguard-tools
    ];
    system.stateVersion = "26.05";
  };

  tcpListener =
    {
      address,
      after ? [ "network-online.target" ],
      name,
      port,
    }:
    {
      description = "Throwaway ${name} listener";
      wantedBy = [ "multi-user.target" ];
      requires = after;
      inherit after;
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python -m http.server ${toString port} --bind ${address}";
        Restart = "on-failure";
      };
    };

  udpEchoServer = pkgs.writeText "udp-echo-server.py" ''
    import socket
    import sys

    address = sys.argv[1]
    port = int(sys.argv[2])
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind((address, port))

    while True:
        data, peer = server.recvfrom(65535)
        server.sendto(data, peer)
  '';
in
pkgs.testers.runNixOSTest {
  name = "home-access-gateway";

  nodes = {
    gateway = {
      imports = [
        sops-nix.nixosModules.sops
        ../modules/nixos/home-access-gateway.nix
        commonNode
      ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.interfaces = {
        eth1 = staticAddress gatewayExternalAddress;
        eth2 = staticAddress gatewayLanAddress;
      };
      networking.firewall = {
        allowedTCPPorts = [
          2222
          8123
          9999
        ];
        allowedUDPPorts = [ 53 ];
      };
      homelab.homeAccessGateway = {
        enable = true;
        listenPort = listenerPort;
        _testConfigFile = toString gatewayFixture;
        administrator = {
          peerAddresses = [ "${administratorTunnelAddress}/32" ];
          gatewayTCPPorts = [
            2222
            8123
          ];
          gatewayUDPPorts = [ 53 ];
          forwardTargets = [
            {
              address = targetLanAddress;
              tcpPorts = [ 3389 ];
              udpPorts = [ 47998 ];
            }
          ];
        };
        resident = {
          peerAddresses = [ "${residentTunnelAddress}/32" ];
          gatewayTCPPorts = [ 8123 ];
          gatewayUDPPorts = [ 53 ];
        };
      };
      systemd.services = {
        gateway-admin-listener = tcpListener {
          address = gatewayTunnelAddress;
          after = [ "wg-quick-wg-home.service" ];
          name = "administrator-only gateway";
          port = 2222;
        };
        gateway-resident-listener = tcpListener {
          address = gatewayTunnelAddress;
          after = [ "wg-quick-wg-home.service" ];
          name = "resident gateway";
          port = 8123;
        };
        gateway-blocked-listener = tcpListener {
          address = gatewayTunnelAddress;
          after = [ "wg-quick-wg-home.service" ];
          name = "blocked gateway";
          port = 9999;
        };
        gateway-dns-udp = {
          description = "Throwaway allowed gateway UDP echo listener";
          wantedBy = [ "multi-user.target" ];
          requires = [ "wg-quick-wg-home.service" ];
          after = [ "wg-quick-wg-home.service" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python ${udpEchoServer} ${gatewayTunnelAddress} 53";
            Restart = "on-failure";
          };
        };
      };
    };

    target = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = targetLanAddress;
          prefixLength = 24;
        }
        {
          address = otherLanAddress;
          prefixLength = 24;
        }
      ];
      networking.firewall = {
        allowedTCPPorts = [
          3389
          9999
        ];
        allowedUDPPorts = [ 47998 ];
      };
      systemd.services = {
        target-admin-listener = tcpListener {
          address = targetLanAddress;
          after = [ "network-addresses-eth1.service" ];
          name = "allowed administrator target";
          port = 3389;
        };
        target-blocked-listener = tcpListener {
          address = targetLanAddress;
          after = [ "network-addresses-eth1.service" ];
          name = "blocked target service";
          port = 9999;
        };
        other-target-listener = tcpListener {
          address = otherLanAddress;
          after = [ "network-addresses-eth1.service" ];
          name = "blocked alternate target";
          port = 3389;
        };
        target-admin-udp = {
          description = "Throwaway allowed target UDP echo listener";
          wantedBy = [ "multi-user.target" ];
          requires = [ "network-addresses-eth1.service" ];
          after = [ "network-addresses-eth1.service" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python ${udpEchoServer} ${targetLanAddress} 47998";
            Restart = "on-failure";
          };
        };
      };
    };

    administrator = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = staticAddress administratorExternalAddress;
      networking.wg-quick.interfaces.wg-test.configFile = toString (
        clientFixture fixtureKeys.administrator administratorTunnelAddress
      );
    };

    resident = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = staticAddress residentExternalAddress;
      networking.firewall.allowedTCPPorts = [ 7777 ];
      networking.wg-quick.interfaces.wg-test.configFile = toString (
        clientFixture fixtureKeys.resident residentTunnelAddress
      );
      systemd.services.resident-test-listener = tcpListener {
        address = residentTunnelAddress;
        after = [ "wg-quick-wg-test.service" ];
        name = "blocked resident peer";
        port = 7777;
      };
    };
  };

  testScript = ''
    start_all()

    gateway.wait_for_unit("wg-quick-wg-home.service")
    gateway.wait_for_unit("gateway-admin-listener.service")
    gateway.wait_for_unit("gateway-resident-listener.service")
    gateway.wait_for_unit("gateway-blocked-listener.service")
    gateway.wait_for_unit("gateway-dns-udp.service")
    target.wait_for_unit("target-admin-listener.service")
    target.wait_for_unit("target-blocked-listener.service")
    target.wait_for_unit("other-target-listener.service")
    target.wait_for_unit("target-admin-udp.service")
    administrator.wait_for_unit("wg-quick-wg-test.service")
    resident.wait_for_unit("wg-quick-wg-test.service")
    resident.wait_for_unit("resident-test-listener.service")

    gateway.succeed("iptables -w -C nixos-fw -i wg-home -j nixos-fw-log-refuse")
    gateway.succeed("iptables -w -C FORWARD -i wg-home -j DROP")
    gateway.succeed(
      "iptables -w -C nixos-fw -i wg-home -s ${administratorTunnelAddress}/32 "
      "-p tcp --dport 2222 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j nixos-fw-accept"
    )
    gateway.succeed(
      "iptables -w -C FORWARD -i wg-home -s ${administratorTunnelAddress}/32 "
      "-d ${targetLanAddress}/32 -p tcp --dport 3389 "
      "-m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
    )
    gateway.succeed(
      "iptables -w -C nixos-fw -i wg-home -s ${residentTunnelAddress}/32 "
      "-p udp --dport 53 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j nixos-fw-accept"
    )
    gateway.succeed("iptables -w -t nat -C nixos-nat-pre -i wg-home -j MARK --set-mark 1")

    administrator.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${gatewayTunnelAddress}:2222/ >/dev/null"
    )
    administrator.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${gatewayTunnelAddress}:8123/ >/dev/null"
    )
    administrator.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${targetLanAddress}:3389/ >/dev/null"
    )
    administrator.succeed(
      "test \"$(printf ping | socat -T 5 - UDP4:${gatewayTunnelAddress}:53)\" = ping"
    )
    administrator.succeed(
      "test \"$(printf ping | socat -T 5 - UDP4:${targetLanAddress}:47998)\" = ping"
    )

    resident.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${gatewayTunnelAddress}:8123/ >/dev/null"
    )
    resident.succeed(
      "test \"$(printf ping | socat -T 5 - UDP4:${gatewayTunnelAddress}:53)\" = ping"
    )
    resident.fail("curl --fail --silent --connect-timeout 2 http://${gatewayTunnelAddress}:2222/")
    resident.fail("curl --fail --silent --connect-timeout 2 http://${targetLanAddress}:3389/")

    administrator.fail("curl --fail --silent --connect-timeout 2 http://${gatewayTunnelAddress}:9999/")
    administrator.fail("curl --fail --silent --connect-timeout 2 http://${targetLanAddress}:9999/")
    administrator.fail("curl --fail --silent --connect-timeout 2 http://${otherLanAddress}:3389/")
    administrator.fail("curl --fail --silent --connect-timeout 2 http://${residentTunnelAddress}:7777/")

    gateway.succeed("systemctl stop firewall.service")
    gateway.fail("wg show wg-home")
    gateway.succeed("systemctl start firewall.service")
    gateway.succeed("systemctl start wg-quick-wg-home.service")
    gateway.succeed(
      "systemctl start gateway-admin-listener.service gateway-resident-listener.service"
    )
    administrator.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${gatewayTunnelAddress}:2222/ >/dev/null"
    )

    gateway.succeed("systemctl reload firewall.service")
    administrator.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${targetLanAddress}:3389/ >/dev/null"
    )

    gateway.succeed("wg set wg-home peer ${administratorPublicKey} remove")
    administrator.fail("curl --fail --silent --connect-timeout 2 http://${gatewayTunnelAddress}:8123/")
    resident.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${gatewayTunnelAddress}:8123/ >/dev/null"
    )
  '';
}
