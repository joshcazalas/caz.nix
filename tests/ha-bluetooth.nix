{ pkgs, inputs }:
let
  fixture = pkgs.dockerTools.buildLayeredImage {
    name = "ha-bluetooth-test";
    tag = "fixture";
    maxLayers = 2;
    contents = [
      pkgs.python3
      pkgs.dbus
      pkgs.coreutils
      pkgs.dockerTools.fakeNss
    ];
    config.Cmd = [
      "/bin/python"
      (pkgs.writeText "ha-bluetooth-probe.py" (builtins.readFile ./ha_bluetooth_probe.py))
    ];
  };
  privateInputs = pkgs.writeText "synthetic-ha-inputs.json" (
    builtins.toJSON {
      hvac_thermostats = [ "climate.test" ];
      hvac_day_temperature = 75;
      hvac_night_temperature = 72;
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "ha-bluetooth";
  requiredFeatures.kvm = false;
  nodes.server =
    { config, lib, ... }:
    {
      imports = [ ../modules/nixos/home-assistant.nix ];
      _module.args = {
        inherit inputs;
        settings.server = {
          dataRoot = "/var/lib/homelab";
          timeZone = "UTC";
        };
      };
      virtualisation = {
        memorySize = 2048;
        docker.enable = true;
        oci-containers = {
          backend = "docker";
          containers.homeassistant = {
            image = lib.mkForce "ha-bluetooth-test:fixture";
            imageFile = fixture;
            pull = "never";
            environment.EXPECT_BLUETOOTH = if config.homelab.homeAssistant.bluetooth.enable then "1" else "0";
          };
        };
      };
      homelab.homeAssistant = {
        enable = true;
        bluetooth.enable = true;
      };
      # Expose the kernel management API without needing a physical adapter.
      boot.kernelModules = [ "bluetooth" ];
      systemd.tmpfiles.rules = [
        "C /var/lib/homelab/home-assistant-private/package-secrets.yaml 0600 root root - ${privateInputs}"
      ];
      specialisation.withoutBluetooth.configuration.homelab.homeAssistant.bluetooth.enable =
        lib.mkForce false;
      system.stateVersion = "26.05";
    };
  testScript = ''
    import json

    start_all()
    server.wait_for_unit("bluetooth.service")
    server.wait_for_unit("docker-homeassistant.service")
    result = "/var/lib/homelab/home-assistant/bluetooth-probe.json"
    server.wait_until_succeeds(f"test -s {result}", timeout=60)
    assert json.loads(server.succeed(f"cat {result}")) == {"enabled": True}
    container = json.loads(server.succeed("docker inspect homeassistant"))[0]
    assert container["RestartCount"] == 0
    assert not container["HostConfig"]["Privileged"]
    assert "no-new-privileges:true" in container["HostConfig"]["SecurityOpt"]

    with subtest("BlueZ stopping does not stop Home Assistant"):
        server.succeed("systemctl stop bluetooth.service")
        server.succeed("systemctl is-active docker-homeassistant.service")
        assert server.succeed("docker inspect --format '{{.State.Running}}' homeassistant").strip() == "true"

    with subtest("Disabling local Bluetooth removes the added container access"):
        server.succeed(f"rm {result}")
        server.succeed("/run/current-system/specialisation/withoutBluetooth/bin/switch-to-configuration test")
        server.wait_for_unit("docker-homeassistant.service")
        server.wait_until_succeeds(f"test -s {result}", timeout=60)
        assert json.loads(server.succeed(f"cat {result}")) == {"enabled": False}
        container = json.loads(server.succeed("docker inspect homeassistant"))[0]
        assert not container["HostConfig"]["CapAdd"]
        assert all(mount["Destination"] != "/run/dbus" for mount in container["Mounts"])
  '';
}
