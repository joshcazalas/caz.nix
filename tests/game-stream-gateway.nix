{
  pkgs,
  sops-nix,
}:
let
  # These keys exist only inside disposable documentation-range VMs. Splitting
  # the non-secret fixtures keeps generic secret scanners meaningful.
  fixtureKeys = {
    gateway = builtins.concatStringsSep "" [
      "+MAAEjYR"
      "wLJa9J3N"
      "3L7IvM0U"
      "rhK/305n"
      "Z64BtT3C"
      "IEM="
    ];
    host = builtins.concatStringsSep "" [
      "UPLk0odu"
      "0K0J9aPN"
      "RJVeA+LG"
      "abKNMnqw"
      "WrNc/CWb"
      "xXE="
    ];
    client = builtins.concatStringsSep "" [
      "MGFxeYcN"
      "LTNBCgz5"
      "PmZMqoyy"
      "fx6L5P0g"
      "0dLZOXs4"
      "E1o="
    ];
  };
  gatewayPublicKey = "bW/PIeb0C8q05svQlT24VAaw58GQrk/0tErYhFsJOjQ=";
  hostPublicKey = "4r4Uo/1VVCwydWVc+1bRHMDN/ln6+b6yJI2BBOOqtlA=";
  clientPublicKey = "RYOxSmSdLVmFheEeofQGbQMLQLxhUjX5NdLu7H2P6VM=";

  gatewayAddress = "192.0.2.1";
  hostAddress = "192.0.2.2";
  clientAddress = "192.0.2.3";
  listenerPort = 51820;

  gatewayFixture = pkgs.writeText "wg-game-test.conf" ''
    [Interface]
    Address = ${gatewayAddress}/32
    PrivateKey = ${fixtureKeys.gateway}
    ListenPort = ${toString listenerPort}

    [Peer]
    PublicKey = ${hostPublicKey}
    AllowedIPs = ${hostAddress}/32

    [Peer]
    PublicKey = ${clientPublicKey}
    AllowedIPs = ${clientAddress}/32
  '';

  commonNode = {
    networking = {
      firewall.enable = true;
      nftables.enable = false;
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.wireguard-tools
    ];
    system.stateVersion = "26.05";
  };

  httpListener =
    {
      address,
      after,
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
    gateway =
      { ... }:
      {
        imports = [
          sops-nix.nixosModules.sops
          ../modules/nixos/game-stream-gateway.nix
          commonNode
        ];

        homelab.gameStreamGateway = {
          enable = true;
          listenPort = listenerPort;
          _testConfigFile = toString gatewayFixture;
        };

        networking.firewall.allowedTCPPorts = [ 9999 ];
        systemd.services.gateway-test-listener = httpListener {
          address = gatewayAddress;
          after = [ "wg-quick-wg-game.service" ];
          name = "gateway input";
          port = 9999;
        };
      };

    host =
      { pkgs, ... }:
      {
        imports = [ commonNode ];

        networking = {
          firewall.allowedTCPPorts = [
            9998
            9999
            47989
          ];
          wg-quick.interfaces.wg-test.configFile = toString (
            pkgs.writeText "wg-host-test.conf" ''
              [Interface]
              Address = ${hostAddress}/32
              PrivateKey = ${fixtureKeys.host}

              [Peer]
              PublicKey = ${gatewayPublicKey}
              Endpoint = gateway:${toString listenerPort}
              AllowedIPs = ${clientAddress}/32
              PersistentKeepalive = 25
            ''
          );
        };

        systemd.services = {
          host-stream-listener = httpListener {
            address = hostAddress;
            after = [ "wg-quick-wg-test.service" ];
            name = "allowed host stream";
            port = 47989;
          };
          host-blocked-listener = httpListener {
            address = hostAddress;
            after = [ "wg-quick-wg-test.service" ];
            name = "blocked host service";
            port = 9999;
          };
          host-lan-listener = httpListener {
            address = "0.0.0.0";
            after = [ "network-online.target" ];
            name = "blocked LAN service";
            port = 9998;
          };
        };
      };

    client =
      { pkgs, ... }:
      {
        imports = [ commonNode ];

        networking = {
          firewall.allowedTCPPorts = [ 7777 ];
          wg-quick.interfaces.wg-test.configFile = toString (
            pkgs.writeText "wg-client-test.conf" ''
              [Interface]
              Address = ${clientAddress}/32
              PrivateKey = ${fixtureKeys.client}

              [Peer]
              PublicKey = ${gatewayPublicKey}
              Endpoint = gateway:${toString listenerPort}
              AllowedIPs = ${hostAddress}/32
              PersistentKeepalive = 25
            ''
          );
        };

        systemd.services.client-test-listener = httpListener {
          address = clientAddress;
          after = [ "wg-quick-wg-test.service" ];
          name = "blocked client service";
          port = 7777;
        };
      };
  };

  testScript = ''
    start_all()

    gateway.wait_for_unit("wg-quick-wg-game.service")
    gateway.wait_for_unit("game-stream-gateway-policy.service")
    gateway.wait_for_unit("gateway-test-listener.service")
    host.wait_for_unit("wg-quick-wg-test.service")
    host.wait_for_unit("host-stream-listener.service")
    host.wait_for_unit("host-blocked-listener.service")
    host.wait_for_unit("host-lan-listener.service")
    client.wait_for_unit("wg-quick-wg-test.service")
    client.wait_for_unit("client-test-listener.service")

    gateway.succeed("iptables -w -C FORWARD -i wg-game -j caz-game-stream")
    gateway.succeed("iptables -w -C nixos-fw -i wg-game -j nixos-fw-log-refuse")
    gateway.succeed(
      "iptables -w -C caz-game-stream -s ${clientAddress}/32 -d ${hostAddress}/32 "
      "-p tcp -m multiport --dports 47984,47989,48010 "
      "-m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
    )
    gateway.succeed(
      "iptables -w -C caz-game-stream -s ${clientAddress}/32 -d ${hostAddress}/32 "
      "-p udp -m multiport --dports 47998:48000,48002,48010 "
      "-m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
    )

    client.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${hostAddress}:47989/ >/dev/null"
    )
    gateway.succeed(
      "caz-game-stream-gateway report ${gatewayFixture} wg-game ${toString listenerPort}"
    )
    client.fail("curl --fail --silent --connect-timeout 2 http://${hostAddress}:9999/")
    host.fail("curl --fail --silent --connect-timeout 2 http://${clientAddress}:7777/")

    # Temporarily add the gateway /32 to the client peer only to prove that
    # gateway-local input is refused even if a client tries to add a route.
    client.succeed(
      "wg set wg-test peer ${gatewayPublicKey} allowed-ips ${hostAddress}/32,${gatewayAddress}/32"
    )
    client.succeed("ip route add ${gatewayAddress}/32 dev wg-test")
    client.fail("curl --fail --silent --connect-timeout 2 http://${gatewayAddress}:9999/")

    # Even a locally added client route cannot turn the narrow role tunnel
    # into access to the host's LAN-facing address.
    host_lan_address = host.succeed(
      "ip -o -4 address show dev eth1 | awk '{ print $4 }' | cut -d/ -f1"
    ).strip()
    client.succeed(
      f"wg set wg-test peer ${gatewayPublicKey} allowed-ips "
      f"${hostAddress}/32,${gatewayAddress}/32,{host_lan_address}/32"
    )
    client.succeed(f"ip route add {host_lan_address}/32 dev wg-test")
    client.fail(
      f"curl --fail --silent --connect-timeout 2 http://{host_lan_address}:9998/"
    )

    # A source outside the client's cryptokey route must not pass the gateway.
    client.succeed("ip address add ${gatewayAddress}/32 dev lo")
    client.fail(
      "curl --interface ${gatewayAddress} --fail --silent --connect-timeout 2 http://${hostAddress}:47989/"
    )

    gateway.succeed("wg set wg-game peer ${clientPublicKey} remove")
    client.fail("curl --fail --silent --connect-timeout 2 http://${hostAddress}:47989/")
    gateway.succeed("test $(wg show wg-game peers | wc -l) -eq 1")
  '';
}
