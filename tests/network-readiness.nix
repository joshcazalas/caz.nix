{ pkgs, auxide }:
let
  routerAddress = "192.168.30.1";
  serverAddress = "192.168.30.2";
  probe = pkgs.writeShellScriptBin "auxide" ''
    set -eu
    ${pkgs.getent}/bin/getent ahostsv4 discord.com >/dev/null
    touch "$RUNTIME_DIRECTORY/started"
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
in
pkgs.testers.runNixOSTest {
  name = "network-readiness";

  defaults = {
    networking.enableIPv6 = false;
    virtualisation.vlans = [ 1 ];
    system.stateVersion = "26.05";
  };

  nodes = {
    router = { lib, ... }: {
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = routerAddress;
          prefixLength = 24;
        }
      ];
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = "${serverAddress},${serverAddress},255.255.255.0,1h";
          dhcp-option = [
            "3,${routerAddress}"
            "6,${routerAddress}"
          ];
          address = "/discord.com/${routerAddress}";
          no-resolv = true;
        };
      };
      systemd.services.dnsmasq.wantedBy = lib.mkForce [ ];
      networking.firewall.allowedUDPPorts = [
        53
        67
      ];
      networking.firewall.allowedTCPPorts = [ 53 ];
    };

    server = { lib, ... }: {
      imports = [
        ../modules/nixos/networking.nix
        ../modules/nixos/auxide.nix
        auxide.nixosModules.default
      ];
      _module.args.settings.server.lanInterface = "eth1";
      homelab.auxide.enable = true;
      users.groups.media = { };
      services.auxide = {
        package = probe;
        poTokenProvider.enable = false;
      };
      # Exercise the real service sandbox and DNS pre-start without a bot token.
      systemd.services.auxide = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.LoadCredential = lib.mkForce [ ];
        serviceConfig.LoadCredentialEncrypted = lib.mkForce [ ];
      };
      networking.resolvconf.useLocalResolver = false;
      # Start DHCP explicitly after both VMs boot, so runner load cannot consume
      # the readiness window before the test begins withholding the lease.
      systemd.services.dhcpcd.wantedBy = lib.mkForce [ ];
      systemd.services.test-virtual-interfaces = {
        wantedBy = [ "multi-user.target" ];
        before = [ "dhcpcd.service" ];
        requiredBy = [ "dhcpcd.service" ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        script = ''
          ${pkgs.iproute2}/bin/ip link add wg-game type dummy
          ${pkgs.iproute2}/bin/ip address add 10.203.113.1/32 dev wg-game
          ${pkgs.iproute2}/bin/ip link set wg-game up
          ${pkgs.iproute2}/bin/ip link add veth-test type veth peer name veth-peer
          ${pkgs.iproute2}/bin/ip link set veth-test up
          ${pkgs.iproute2}/bin/ip link set veth-peer up
        '';
      };
    };
  };

  testScript = ''
    start_all()
    router.wait_for_unit("multi-user.target")
    server.wait_for_unit("multi-user.target")

    with subtest("VPN addresses cannot satisfy uplink readiness"):
        server.wait_for_unit("test-virtual-interfaces.service")
        server.succeed("systemctl start --no-block dhcpcd.service")
        server.wait_until_succeeds("journalctl -u dhcpcd.service --no-pager | grep -F 'eth1: soliciting a DHCP lease'")
        # The default 30-second timeout must not report success without a lease.
        server.succeed("sleep 35; test $(systemctl show dhcpcd.service -p ActiveState --value) = activating")
        server.fail("systemctl is-active --quiet dhcpcd.service")
        server.fail("ip -4 address show dev eth1 | grep -F '169.254.'")
        server.succeed("ip -4 address show dev wg-game | grep -F '10.203.113.1/32'")
        router.succeed("systemctl start dnsmasq.service")
        server.wait_for_unit("dhcpcd.service")
        server.succeed("ip -4 address show dev eth1 | grep -F '${serverAddress}/24'")
        server.succeed("ip route show default | grep -F 'via ${routerAddress} dev eth1'")
        server.succeed("getent ahostsv4 discord.com")
        logs = server.succeed("journalctl -u dhcpcd.service --no-pager")
        assert "wg-game:" not in logs, logs
        assert "veth-test:" not in logs, logs

    with subtest("Stopping DHCP retains the lease, routes, and DNS"):
        server.succeed("systemctl stop dhcpcd.service")
        server.succeed("ip -4 address show dev eth1 | grep -F '${serverAddress}/24'")
        server.succeed("ip route show default | grep -F 'via ${routerAddress} dev eth1'")
        server.succeed("getent ahostsv4 discord.com")
        server.succeed("systemctl start dhcpcd.service")

    with subtest("Auxide waits for DNS during a live switch"):
        server.succeed("systemctl start network-online.target")
        router.succeed("systemctl stop dnsmasq.service")
        server.fail("getent ahostsv4 discord.com")
        server.succeed("systemctl is-active network-online.target")
        server.succeed("systemd-run --no-block --unit=auxide-start-test --property=Type=oneshot --remain-after-exit /run/current-system/sw/bin/systemctl start auxide.service")
        server.wait_until_succeeds("journalctl -u auxide.service --no-pager | grep -F 'Waiting for Discord DNS'")
        server.succeed("test $(systemctl show auxide.service -p SubState --value) = start-pre")
        server.fail("test -e /run/auxide/started")
        router.succeed("systemctl start dnsmasq.service")
        server.wait_for_unit("auxide-start-test.service")
        server.wait_for_file("/run/auxide/started")
        server.succeed("systemctl stop auxide-start-test.service auxide.service")

    with subtest("A lasting DNS outage fails the start job"):
        router.succeed("systemctl stop dnsmasq.service")
        server.fail("systemctl start auxide.service")
        server.succeed("journalctl -u auxide.service --no-pager | grep -F 'Discord DNS is still unavailable after 60 seconds.'")
        server.fail("test -e /run/auxide/started")
        server.succeed("systemctl stop auxide.service")
        router.succeed("systemctl start dnsmasq.service")
        server.succeed("systemctl start auxide.service")
        server.wait_for_file("/run/auxide/started")
  '';
}
