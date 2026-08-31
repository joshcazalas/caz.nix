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
    client = builtins.concatStringsSep "" [
      "MGFxeYcN"
      "LTNBCgz5"
      "PmZMqoyy"
      "fx6L5P0g"
      "0dLZOXs4"
      "E1o="
    ];
    client2 = builtins.concatStringsSep "" [
      "+FuZGhtd"
      "nKQPerel"
      "WrOnbarO"
      "znjF1aix"
      "CA3O/gm9"
      "lVE="
    ];
  };
  gatewayPublicKey = "bW/PIeb0C8q05svQlT24VAaw58GQrk/0tErYhFsJOjQ=";
  clientPublicKey = "RYOxSmSdLVmFheEeofQGbQMLQLxhUjX5NdLu7H2P6VM=";
  client2PublicKey = "xIW4eCfneRlGcuNXvKJsGKdLUas+3XzQaln0eQfxyVg=";

  gatewayExternalAddress = "203.0.113.1";
  clientExternalAddress = "203.0.113.2";
  client2ExternalAddress = "203.0.113.3";
  gatewayLanAddress = "192.0.2.1";
  hostLanAddress = "192.0.2.2";
  otherLanAddress = "192.0.2.3";
  gatewayTunnelAddress = "198.51.100.1";
  clientTunnelAddress = "198.51.100.2";
  client2TunnelAddress = "198.51.100.3";
  listenerPort = 51820;

  gatewayFixture = pkgs.writeText "wg-game-test.conf" ''
    [Interface]
    Address = ${gatewayTunnelAddress}/32
    PrivateKey = ${fixtureKeys.gateway}
    ListenPort = ${toString listenerPort}

    [Peer]
    PublicKey = ${clientPublicKey}
    AllowedIPs = ${clientTunnelAddress}/32

    [Peer]
    PublicKey = ${client2PublicKey}
    AllowedIPs = ${client2TunnelAddress}/32
  '';

  clientFixture =
    privateKey: address:
    pkgs.writeText "wg-client-test.conf" ''
      [Interface]
      Address = ${address}/32
      PrivateKey = ${privateKey}

      [Peer]
      PublicKey = ${gatewayPublicKey}
      Endpoint = ${gatewayExternalAddress}:${toString listenerPort}
      AllowedIPs = ${hostLanAddress}/32
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
in
pkgs.testers.runNixOSTest {
  name = "game-stream-gateway";

  nodes = {
    gateway = {
      imports = [
        sops-nix.nixosModules.sops
        ../modules/nixos/game-stream-gateway.nix
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
      networking.firewall.allowedTCPPorts = [ 9999 ];
      homelab.gameStreamGateway = {
        enable = true;
        hostAddress = hostLanAddress;
        listenPort = listenerPort;
        _testConfigFile = toString gatewayFixture;
      };
      systemd.services.gateway-test-listener = tcpListener {
        address = gatewayTunnelAddress;
        after = [ "wg-quick-wg-game.service" ];
        name = "gateway input";
        port = 9999;
      };
    };

    host = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = hostLanAddress;
          prefixLength = 24;
        }
        {
          address = otherLanAddress;
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedTCPPorts = [
        47989
        9999
      ];
      networking.firewall.allowedUDPPorts = [ 47998 ];
      systemd.services = {
        host-stream-listener = tcpListener {
          address = hostLanAddress;
          after = [ "network-addresses-eth1.service" ];
          name = "allowed Sunshine TCP";
          port = 47989;
        };
        host-blocked-listener = tcpListener {
          address = hostLanAddress;
          after = [ "network-addresses-eth1.service" ];
          name = "blocked host service";
          port = 9999;
        };
        other-lan-listener = tcpListener {
          address = otherLanAddress;
          after = [ "network-addresses-eth1.service" ];
          name = "blocked alternate LAN destination";
          port = 47989;
        };
        host-stream-udp = {
          description = "Throwaway allowed Sunshine UDP echo listener";
          wantedBy = [ "multi-user.target" ];
          requires = [ "network-addresses-eth1.service" ];
          after = [ "network-addresses-eth1.service" ];
          serviceConfig = {
            ExecStart = "${pkgs.socat}/bin/socat UDP4-RECVFROM:47998,bind=${hostLanAddress},fork EXEC:${pkgs.coreutils}/bin/cat";
            Restart = "on-failure";
          };
        };
      };
    };

    client = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = staticAddress clientExternalAddress;
      networking.wg-quick.interfaces.wg-test.configFile = toString (
        clientFixture fixtureKeys.client clientTunnelAddress
      );
    };

    client2 = {
      imports = [ commonNode ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = staticAddress client2ExternalAddress;
      networking.firewall.allowedTCPPorts = [ 7777 ];
      networking.wg-quick.interfaces.wg-test.configFile = toString (
        clientFixture fixtureKeys.client2 client2TunnelAddress
      );
      systemd.services.client-test-listener = tcpListener {
        address = client2TunnelAddress;
        after = [ "wg-quick-wg-test.service" ];
        name = "blocked client service";
        port = 7777;
      };
    };
  };

  testScript = ''
    start_all()

    gateway.wait_for_unit("wg-quick-wg-game.service")
    gateway.wait_for_unit("gateway-test-listener.service")
    host.wait_for_unit("host-stream-listener.service")
    host.wait_for_unit("host-stream-udp.service")
    host.wait_for_unit("host-blocked-listener.service")
    host.wait_for_unit("other-lan-listener.service")
    client.wait_for_unit("wg-quick-wg-test.service")
    client2.wait_for_unit("wg-quick-wg-test.service")
    client2.wait_for_unit("client-test-listener.service")

    gateway.succeed("iptables -w -C nixos-fw -i wg-game -j nixos-fw-log-refuse")
    gateway.succeed(
      "iptables -w -C FORWARD -i wg-game -d ${hostLanAddress}/32 "
      "-p tcp -m multiport --dports 47984,47989,48010 "
      "-m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
    )
    gateway.succeed(
      "iptables -w -C FORWARD -i wg-game -d ${hostLanAddress}/32 "
      "-p udp -m multiport --dports 47998:48000,48002,48010 "
      "-m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
    )
    gateway.succeed("iptables -w -C FORWARD -i wg-game -j DROP")
    gateway.succeed("iptables -w -t nat -C nixos-nat-pre -i wg-game -j MARK --set-mark 1")

    client.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${hostLanAddress}:47989/ >/dev/null"
    )
    client.succeed(
      "test \"$(printf ping | socat -T 5 - UDP4:${hostLanAddress}:47998)\" = ping"
    )
    client2.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${hostLanAddress}:47989/ >/dev/null"
    )

    client.fail("curl --fail --silent --connect-timeout 2 http://${hostLanAddress}:9999/")
    client.succeed(
      "wg set wg-test peer ${gatewayPublicKey} allowed-ips ${hostLanAddress}/32,${otherLanAddress}/32"
    )
    client.succeed("ip route add ${otherLanAddress}/32 dev wg-test")
    client.fail("curl --fail --silent --connect-timeout 2 http://${otherLanAddress}:47989/")

    client.succeed(
      "wg set wg-test peer ${gatewayPublicKey} allowed-ips "
      "${hostLanAddress}/32,${otherLanAddress}/32,${gatewayTunnelAddress}/32,${client2TunnelAddress}/32"
    )
    client.succeed("ip route add ${gatewayTunnelAddress}/32 dev wg-test")
    client.succeed("ip route add ${client2TunnelAddress}/32 dev wg-test")
    client.fail("curl --fail --silent --connect-timeout 2 http://${gatewayTunnelAddress}:9999/")
    client.fail("curl --fail --silent --connect-timeout 2 http://${client2TunnelAddress}:7777/")

    gateway.succeed("systemctl stop firewall.service")
    gateway.fail("wg show wg-game")
    gateway.succeed("systemctl start firewall.service")
    gateway.succeed("systemctl start wg-quick-wg-game.service")
    client.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${hostLanAddress}:47989/ >/dev/null"
    )

    gateway.succeed("systemctl reload firewall.service")
    client.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${hostLanAddress}:47989/ >/dev/null"
    )

    gateway.succeed("wg set wg-game peer ${clientPublicKey} remove")
    client.fail("curl --fail --silent --connect-timeout 2 http://${hostLanAddress}:47989/")
    client2.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${hostLanAddress}:47989/ >/dev/null"
    )
  '';
}
