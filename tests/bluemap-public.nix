{ pkgs, unstablePkgs }:
pkgs.testers.runNixOSTest {
  name = "bluemap-public";

  nodes.server =
    { lib, ... }:
    {
      imports = [
        ../modules/nixos/bluemap.nix
        ../modules/nixos/minecraft.nix
      ];
      _module.args = {
        inherit unstablePkgs;
        settings = {
          public = {
            bluemap = true;
            domain = "example.test";
          };
          server.timeZone = "UTC";
        };
      };
      homelab.bluemap.enable = true;
      homelab.minecraft = {
        enable = true;
        acceptEula = true;
      };
      # Write fixtures as the renderer's host UID without pulling a game image.
      virtualisation.oci-containers.backend = "docker";
      virtualisation.oci-containers.containers.minecraft.autoStart = lib.mkForce false;
      services.caddy.virtualHosts."map.example.test".extraConfig = "tls internal";
      environment.systemPackages = [ pkgs.curl ];
      system.stateVersion = "26.05";
    };

  testScript = ''
    import shlex

    def render(command):
        server.succeed("cd /var/lib/bluemap && sudo -u minecraft sh -eu -c " + shlex.quote(command))

    def fetch(path):
        return "curl -ksS --resolve map.example.test:443:127.0.0.1 https://map.example.test/" + path

    def check_blocked(path):
        status = server.succeed(fetch(path) + " -o /dev/null -w '%{http_code}'")
        assert status[0] in ("4", "5"), (path, status)

    server.wait_for_unit("caddy.service")
    server.wait_for_unit("run-bluemap.mount")
    server.succeed("findmnt --mountpoint /run/bluemap --options ro,nosymfollow")
    server.fail("touch /run/bluemap/web/readonly-check")

    with subtest("Caddy sees the renderer's current tiles"):
        render("mkdir web/maps && echo viewer > web/index.html && echo first > web/maps/tile")
        server.wait_until_succeeds(fetch("") + " --fail | grep -Fx viewer")
        assert server.succeed(fetch("maps/tile") + " --fail").strip() == "first"
        render("echo second > web/maps/next && mv web/maps/next web/maps/tile")
        assert server.succeed(fetch("maps/tile") + " --fail").strip() == "second"

    with subtest("Every renderer-controlled path component rejects symlinks"):
        render("ln -s tile web/maps/alias && ln -s maps web/alias")
        check_blocked("maps/alias")
        check_blocked("alias/tile")
        render("mv web original && ln -s original web")
        check_blocked("maps/tile")
        render("unlink web && mv original web")
        assert server.succeed(fetch("maps/tile") + " --fail").strip() == "second"

    with subtest("An unavailable mount takes only the map offline"):
        server.succeed("systemctl stop run-bluemap.mount")
        server.succeed("systemctl is-active caddy.service")
        check_blocked("maps/tile")
        server.succeed("systemctl start run-bluemap.mount")
        assert server.succeed(fetch("maps/tile") + " --fail").strip() == "second"
  '';
}
