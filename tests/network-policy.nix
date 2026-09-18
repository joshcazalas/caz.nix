{ pkgs }:
let
  serverAddress = "192.168.20.1";
  trustedAddress = "192.168.20.2";
  restrictedAddress = "192.168.20.3";

  updater = pkgs.callPackage ../packages/website-updater { };
  fixtures = pkgs.runCommand "website-test-bundles" { nativeBuildInputs = [ pkgs.nodejs_24 ]; } ''
    cp -r ${updater}/lib/caz-website-updater app
    chmod -R u+w app
    mkdir app/test "$out"
    cp ${../packages/website-updater/test/fixture.ts} app/test/fixture.ts
    cd app
    node --input-type=module - "$out" <<'JS'
    import { bundle } from './test/fixture.ts';
    for (const digit of ['a', 'b']) bundle(process.argv[2], digit);
    JS
  '';

  settings.server.lanAddress = serverAddress;
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
    imports = [
      homelabOptionStubs
      ../modules/nixos/website.nix
    ];
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
      homelab.website.enable = true;
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
    server.wait_for_unit("caddy.service")
    server.wait_for_open_port(8088)
    assert "caz-website-updater.timer" not in server.succeed("systemctl list-timers --all")
    server.fail("test -e /var/lib/caz-website-release")

    updater = "runuser -u caz-website -- caz-website-updater --config /etc/website-updater.json"
    a, b = "a" * 40, "b" * 40
    server.succeed(f"{updater} preview ${fixtures}/a --commit {a}")
    trusted.wait_until_succeeds("curl -fsS http://${serverAddress}:8088/release.json")
    assert a in trusted.succeed("curl -fsS http://${serverAddress}:8088/release.json")
    restricted.fail("nc -z -w 2 ${serverAddress} 8088")
    server.fail("iptables -w -C nixos-fw -p tcp --dport 8088 -j nixos-fw-accept")
    server.fail("ss -ltn | grep -E '0.0.0.0:8088|\[::\]:8088'")
    assert "no-store" in trusted.succeed("curl -fsSI http://${serverAddress}:8088/")

    server.succeed(f"{updater} preview ${fixtures}/b --commit {b}")
    assert b in trusted.succeed("curl -fsS http://${serverAddress}:8088/release.json")
    # A page opened before activation can still fetch its old lazy audio.
    assert "sound-a" in trusted.succeed(f"curl -fsS http://${serverAddress}:8088/releases/{a}/factorio/sound/note.ogg")
    assert "immutable" in trusted.succeed(f"curl -fsSI http://${serverAddress}:8088/releases/{a}/assets/app.js")
    trusted.fail("curl -fsS http://${serverAddress}:8088/state.json")
    trusted.fail("curl -fsS http://${serverAddress}:8088/manifest.json")
    trusted.fail("curl -fsS http://${serverAddress}:8088/releases/invalid/assets/app.js")
    trusted.fail("curl --path-as-is -fsS http://${serverAddress}:8088/../state.json")

    server.succeed(f"{updater} rollback")
    assert a in trusted.succeed("curl -fsS http://${serverAddress}:8088/release.json")
    assert '"held": true' in server.succeed(f"{updater} status")
    server.succeed(f"{updater} resume")
    assert '"held": false' in server.succeed(f"{updater} status")
    server.fail(f"{updater} update")
    server.succeed("runuser -u caz-website -- flock /var/lib/caz-website-preview/update.lock sleep 10 &")
    server.wait_until_succeeds("pgrep -f 'flock /var/lib/caz-website-preview/update.lock'")
    server.fail(f"{updater} status")

    server.succeed(
      "iptables -w -C nixos-fw -s ${restrictedAddress}/32 -p tcp "
      "-m multiport --dports 3000 -j nixos-fw-accept"
    )
    server.succeed(
      "iptables -w -C nixos-fw -s ${restrictedAddress}/32 -p tcp "
      "-m multiport --dports 22,53,139,445,3000,5357,8096,8088 -j nixos-fw-log-refuse"
    )
    server.succeed(
      "iptables -w -C nixos-fw ! -i 'wg+' -s 192.168.0.0/16 -p tcp "
      "-m multiport --dports 22,53,139,445,3000,5357,8096,8088 -j nixos-fw-accept"
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
    restricted.fail("nc -z -w 2 ${serverAddress} 8088")
    restricted.wait_until_succeeds(
      "curl --fail --silent --max-time 5 http://${serverAddress}:3000/ >/dev/null"
    )
    restricted.fail("nc -z -w 2 ${serverAddress} 22")
  '';
}
