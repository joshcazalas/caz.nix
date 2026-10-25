{ pkgs }:
let
  integrationImage = pkgs.dockerTools.buildLayeredImage {
    name = "local-integration-test";
    tag = "fixture";
    contents = [ pkgs.busybox ];
    config.Cmd = [
      "/bin/sleep"
      "infinity"
    ];
  };
  dhcpHook = pkgs.writeShellScript "test-device-dhcp" ''
    if [ "$1" = bound ]; then
      printf '%s\n' "$ip" "$router" "$dns" > /run/device-dhcp-result
    fi
  '';
  # Synthetic addresses and services only; no household configuration enters CI.
  privateConfig = pkgs.writeText "synthetic-device-network.json" (
    builtins.toJSON {
      interface = "eth2";
      address = "192.168.70.1/24";
      dhcp = {
        start = "192.168.70.20";
        end = "192.168.70.50";
      };
      dns."service.test" = "192.168.70.1";
      tcp = {
        events = {
          direction = "toHost";
          listenPort = 8883;
          targetAddress = "127.0.0.1";
          targetPort = 18080;
        };
        control = {
          direction = "toNetwork";
          listenPort = 19080;
          targetAddress = "192.168.70.10";
          targetPort = 80;
        };
      };
    }
  );
  common = {
    networking.useDHCP = false;
    networking.enableIPv6 = false;
    environment.systemPackages = with pkgs; [
      curl
      netcat-openbsd
      bind.dnsutils
      iptables
      python3
      busybox
    ];
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "device-network";
  # Also runnable under software emulation from a WSL development machine.
  requiredFeatures.kvm = false;
  nodes = {
    server = {
      imports = [
        common
        ../modules/nixos/device-network.nix
        ../modules/nixos/local-integrations.nix
      ];
      _module.args.settings.server.dataRoot = "/var/lib/homelab";
      virtualisation.vlans = [
        1
        2
      ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "192.168.71.1";
          prefixLength = 24;
        }
      ];
      homelab.deviceNetwork.enable = true;
      homelab.localIntegrations.enable = true;
      virtualisation.docker.enable = true;
      # The VM harness normally configures every VLAN NIC. This one belongs
      # exclusively to the isolated network, as a dedicated radio would.
      systemd.services.network-addresses-eth2.enable = false;
      # Mimic other applications with global host listeners and an intentionally
      # permissive firewall: the device namespace must not inherit that trust.
      networking.firewall.enable = false;
      systemd.services.test-local-service = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 18080 --bind 0.0.0.0";
      };
      systemd.services.test-private-config = {
        wantedBy = [ "multi-user.target" ];
        before = [
          "device-network.service"
          "local-integrations.service"
        ];
        wants = [ "docker.service" ];
        after = [ "docker.service" ];
        path = [
          pkgs.docker
          pkgs.python3
        ];
        script = ''
          # Under software emulation containerd may outlast Docker's first
          # internal startup timeout. Wait for its normal automatic retry.
          timeout 180 ${pkgs.bash}/bin/bash -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
          install -d -m 0700 /var/lib/homelab/device-network
          install -m 0600 ${privateConfig} /var/lib/homelab/device-network/network.json
          install -d -m 0700 /var/lib/homelab/local-integrations
          docker load --input ${integrationImage}
          image=$(docker image inspect local-integration-test:fixture --format '{{.Id}}')
          python - "$image" <<'PY'
          import json, os, sys
          path = "/var/lib/homelab/local-integrations/compose.yaml"
          config = {
            "services": {"test": {
              "image": sys.argv[1], "user": "1000:1000", "read_only": True,
              "cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"],
              "dns": ["127.0.0.1"], "networks": ["private"]
            }},
            "networks": {"private": {"internal": True, "enable_ipv6": False}}
          }
          with open(path, "w") as stream:
              json.dump(config, stream)
          os.chmod(path, 0o600)
          PY
          # This test fixture is installed after the boot generator has run.
          systemctl daemon-reload
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 240;
        };
      };
      systemd.services.device-network.requires = [ "test-private-config.service" ];
      systemd.services.local-integrations.requires = [ "test-private-config.service" ];
    };
    device = {
      imports = [ common ];
      boot.kernelModules = [ "macvlan" ];
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "192.168.70.10";
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = {
        address = "192.168.70.1";
        interface = "eth1";
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
      systemd.services.test-device-service = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 80 --bind 0.0.0.0";
      };
    };
    lan = {
      imports = [ common ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "192.168.71.2";
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedTCPPorts = [ 80 ];
      systemd.services.test-lan-service = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 80 --bind 0.0.0.0";
      };
    };
  };
  testScript = ''
    start_all()
    server.wait_for_unit("device-network.service")
    server.wait_for_unit("local-integrations.service")
    server.wait_until_succeeds("caz-local-integrations health")
    # The fixture's first daemon-reload can add new Wants after the boot start
    # transaction. Restarting the target also exercises the supported apply path.
    server.succeed("systemctl restart device-network.target")
    server.wait_for_unit("device-network-dns.service")
    for side in ("host", "network"):
        for grant in ("events", "control"):
            server.wait_for_unit(f"device-network-{side}@{grant}.service")
    server.wait_for_open_port(18080)
    device.wait_for_open_port(80)
    lan.wait_for_open_port(80)

    def check_boundary():
        server.succeed("caz-device-network health")
        # Active systemd units do not guarantee that the proxy listeners and
        # HTTP backends are ready yet, especially immediately after reboot.
        # Wait for both allowed paths before asserting the isolation boundary.
        device.wait_until_succeeds("curl -fsS --max-time 5 http://192.168.70.1:8883/ >/dev/null", timeout=60)
        server.wait_until_succeeds("curl -fsS --max-time 5 http://127.0.0.1:19080/ >/dev/null", timeout=60)
        assert "192.168.70.1" in device.succeed("dig +short @192.168.70.1 service.test")
        assert "NXDOMAIN" in device.succeed("dig +time=2 +tries=1 @192.168.70.1 example.com")
        assert "NXDOMAIN" in device.succeed("dig +tcp +time=2 +tries=1 @192.168.70.1 example.com")
        for address, port in [("192.168.70.1", 22), ("192.168.70.1", 18080),
                              ("192.168.70.1", 8123), ("192.168.71.1", 18080),
                              ("192.168.71.2", 80), ("1.1.1.1", 443)]:
            device.fail(f"nc -z -w 1 {address} {port}")
        device.fail("dig +time=1 +tries=1 @1.1.1.1 example.com")
        lan.fail("nc -z -w 1 192.168.71.1 19080")
        lan.succeed("curl -fsS --max-time 5 http://192.168.71.1:18080/ >/dev/null")

    with subtest("Only explicit local services cross the boundary"):
        check_boundary()

    with subtest("DHCP advertises only the local gateway and resolver"):
        device.succeed("ip link add dhcp-test link eth1 type macvlan mode bridge")
        device.succeed("ip link set dhcp-test up")
        device.succeed("udhcpc -i dhcp-test -n -q -t 4 -T 2 -s ${dhcpHook}")
        lease = device.succeed("cat /run/device-dhcp-result").splitlines()
        assert lease[0].startswith("192.168.70."), lease
        assert lease[1:] == ["192.168.70.1", "192.168.70.1"], lease
        device.succeed("ip link delete dhcp-test")

    with subtest("Host forwarding and NAT rules cannot open an uplink"):
        server.succeed("sysctl -w net.ipv4.ip_forward=1")
        server.succeed("iptables -P FORWARD ACCEPT")
        server.succeed("iptables -t nat -A POSTROUTING -j MASQUERADE")
        check_boundary()

    with subtest("Integration containers have no internet route and drift is detected"):
        container = server.succeed("docker ps --filter label=com.docker.compose.service=test --format '{{.ID}}'").strip()
        assert "default" not in server.succeed(f"docker exec {container} /bin/ip route show")
        server.fail(f"docker exec {container} /bin/timeout 3 /bin/nc 1.1.1.1 443 </dev/null")
        server.succeed(f"docker network connect bridge {container}")
        server.fail("caz-local-integrations health")
        server.succeed(f"docker network disconnect bridge {container}")
        server.succeed("caz-local-integrations health")
        server.succeed("systemctl restart local-integrations.service")
        server.wait_until_succeeds("caz-local-integrations health")

    with subtest("Stopping the target restores the dedicated interface safely"):
        server.succeed("systemctl stop device-network.target device-network.service")
        server.succeed("test ! -e /run/netns/devices")
        server.succeed("ip link show eth2 | grep 'state DOWN'")
        server.succeed("test -z \"$(ip -4 addr show dev eth2 scope global)\"")
        server.succeed("systemctl start device-network.target")
        server.wait_until_succeeds("caz-device-network health")
        check_boundary()

    with subtest("Restarting the namespace also restores its dependents"):
        server.succeed("systemctl restart device-network.service")
        server.wait_until_succeeds("caz-device-network health")
        check_boundary()

    with subtest("Revoking a grant closes the old listener"):
        config_file = "/var/lib/homelab/device-network/network.json"
        server.succeed(f"cp {config_file} /run/device-network-original.json")
        server.succeed(f"python -c 'import json; p=\"{config_file}\"; c=json.load(open(p)); del c[\"tcp\"][\"control\"]; json.dump(c,open(p,\"w\"))'")
        server.fail("caz-device-network health")
        server.succeed("systemctl stop device-network.target device-network.service")
        server.succeed("systemctl daemon-reload && systemctl start device-network.target")
        server.wait_until_succeeds("caz-device-network health")
        server.fail("nc -z -w 1 127.0.0.1 19080")
        device.wait_until_succeeds("curl -fsS --max-time 5 http://192.168.70.1:8883/ >/dev/null", timeout=60)
        server.succeed("systemctl stop device-network.target device-network.service")
        server.succeed(f"cp /run/device-network-original.json {config_file}")
        server.succeed("systemctl daemon-reload && systemctl start device-network.target")
        server.wait_until_succeeds("caz-device-network health")
        check_boundary()

    with subtest("Unsafe file permissions fail validation"):
        server.succeed(f"chmod 0644 {config_file}")
        server.fail("caz-device-network validate")
        server.fail("caz-device-network health")
        server.succeed(f"chmod 0600 {config_file}")

    with subtest("Reboot recreates the network and grants from private configuration"):
        server.shutdown()
        server.start()
        server.wait_until_succeeds("caz-device-network health")
        check_boundary()
        server.wait_until_succeeds("caz-local-integrations health")
  '';
}
