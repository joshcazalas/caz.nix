{
  config,
  inputs,
  lib,
  pkgs,
  settings,
  ...
}:
let
  cfg = config.homelab.homeAssistant;
  containerName = "homeassistant";
  container = config.virtualisation.oci-containers.containers.${containerName};
  declarativeConfig = ../../home-assistant;
  configurationMount = "${declarativeConfig}/configuration.yaml:/config/configuration.yaml:ro";
  packagesMount = "${declarativeConfig}/packages:/config/packages:ro";
  # Make bundled software available; private HA config entries enable it.
  componentSources = builtins.readDir (declarativeConfig + /custom_components);
  componentMounts =
    map (name: "${declarativeConfig}/custom_components/${name}:/config/custom_components/${name}:ro")
      (
        builtins.filter (name: componentSources.${name} == "directory") (
          builtins.attrNames componentSources
        )
      );
  upstreamComponents = pkgs.callPackage ../../packages/home-assistant-integrations {
    inherit inputs;
  };
  upstreamMounts = lib.mapAttrsToList (
    name: source: "${source}:/config/custom_components/${name}:ro"
  ) { inherit (upstreamComponents) ha_lightfx scene_presets; };
  # Preserve the upstream private-data location, including existing manual installs.
  scenePresetsUserdata = "${cfg.dataDir}/custom_components/scene_presets/userdata";
  scenePresetsUserdataMount = "${scenePresetsUserdata}:/config/custom_components/scene_presets/userdata:rw";
  packageInputsMount = "${cfg.privateConfigDir}/package-secrets.yaml:/config/packages/secrets.yaml:ro";
  runtime = "/run/caz-home-assistant";
  prepare = pkgs.writeShellApplication {
    name = "caz-prepare-home-assistant";
    text = ''
      exec ${lib.getExe pkgs.python3} ${../../scripts/prepare-ha-private.py} \
        --private-dir ${lib.escapeShellArg cfg.privateConfigDir} \
        --runtime-dir ${runtime} ${lib.optionalString cfg.serialDevice.enable "--serial"}
    '';
  };
in
{
  options.homelab.homeAssistant = {
    enable = lib.mkEnableOption "Home Assistant Container";

    image = lib.mkOption {
      type = lib.types.strMatching ".+@sha256:[0-9a-f]{64}";
      default = (import ../../containers).home-assistant;
      description = "Immutable linux/amd64 Home Assistant Container image reference.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${settings.server.dataRoot}/home-assistant";
      description = "Persistent Home Assistant configuration and database directory.";
    };

    privateConfigDir = lib.mkOption {
      type = lib.types.str;
      default = "${settings.server.dataRoot}/home-assistant-private";
      description = ''
        Root-only runtime inputs, outside the HA writable mount and Nix store.
        Provision package-secrets.yaml and optional hardware.json before deployment.
      '';
    };

    serialDevice.enable = lib.mkEnableOption "a privately selected serial device";

    bluetooth.enable = lib.mkEnableOption ''
      local Bluetooth via BlueZ (grants HA host D-Bus and network administration access)
    '';
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "${settings.server.dataRoot}/" cfg.dataDir;
        message = "Home Assistant state must reside beneath the declared homelab data root.";
      }
      {
        assertion =
          lib.hasPrefix "${settings.server.dataRoot}/" cfg.privateConfigDir
          && cfg.privateConfigDir != cfg.dataDir
          && !lib.hasPrefix "${cfg.dataDir}/" cfg.privateConfigDir;
        message = "Private HA inputs must live under the data root, outside HA's writable directory.";
      }
      {
        assertion = config.virtualisation.docker.enable;
        message = "Home Assistant Container requires the shared Docker runtime.";
      }
      {
        assertion = container.ports == [ ] && lib.elem "--network=host" container.extraOptions;
        message = ''
          Home Assistant must use host networking for LAN discovery without a
          Docker-published port; the NixOS firewall remains authoritative.
        '';
      }
      {
        assertion = !container.privileged && !lib.elem "--privileged" container.extraOptions;
        message = "Home Assistant hardware access must be granted per device, not with --privileged.";
      }
      {
        assertion = !lib.elem "--init" container.extraOptions;
        message = ''
          Home Assistant's s6-overlay must run as PID 1; Docker's --init flag
          inserts another init process and prevents the container from starting.
        '';
      }
      {
        assertion = lib.elem "${cfg.dataDir}:/config:rw" container.volumes;
        message = "Home Assistant's persistent state directory must be mounted at /config.";
      }
      {
        assertion =
          lib.elem configurationMount container.volumes
          && lib.elem packagesMount container.volumes
          && lib.elem packageInputsMount container.volumes;
        message = "Home Assistant's release-managed YAML must be mounted read-only beneath /config.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 root root -"
      "d ${cfg.privateConfigDir} 0700 root root -"
      "d ${settings.server.dataRoot}/esphome-private 0700 root root -"
      "f ${cfg.dataDir}/automations.yaml 0600 root root - []"
      "f ${cfg.dataDir}/scripts.yaml 0600 root root - {}"
      "f ${cfg.dataDir}/scenes.yaml 0600 root root - []"
      "d ${scenePresetsUserdata} 0700 root root -"
    ];

    hardware.bluetooth = lib.mkIf cfg.bluetooth.enable {
      enable = true;
      powerOnBoot = true;
    };
    services.dbus.enable = lib.mkIf cfg.bluetooth.enable true;

    virtualisation.oci-containers.containers.${containerName} = {
      inherit (cfg) image;
      autoStart = true;
      devices = lib.optional cfg.serialDevice.enable "${runtime}/serial:/dev/ttyZigbee:rw";
      volumes = [
        "${cfg.dataDir}:/config:rw"
        configurationMount
        packagesMount
        packageInputsMount
        "/etc/localtime:/etc/localtime:ro"
      ]
      ++ componentMounts
      ++ upstreamMounts
      ++ [ scenePresetsUserdataMount ]
      ++ lib.optional cfg.bluetooth.enable "/run/dbus:/run/dbus:ro";
      environment.TZ = settings.server.timeZone;
      extraOptions = [
        "--memory=2g"
        "--network=host"
        "--pids-limit=512"
        "--security-opt=no-new-privileges:true"
        "--stop-timeout=60"
      ]
      # Upstream requires both capabilities for scanning and adapter recovery.
      # With host networking, NET_ADMIN also permits changes to the host's
      # interfaces, routes and firewall; this is not a Bluetooth-only grant.
      ++ lib.optionals cfg.bluetooth.enable [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
    };

    # Home Assistant may need more than Docker's default ten seconds to close
    # its SQLite database cleanly. The container stop timeout is the effective
    # grace period; leave additional room for the generated systemd wrapper.
    systemd.services.docker-homeassistant = {
      # Order startup after BlueZ takes its bus name. A failed or absent radio
      # must not stop HA's other integrations or its remote Bluetooth proxies.
      wants = lib.optionals cfg.bluetooth.enable [
        "bluetooth.service"
        "dbus.service"
      ];
      after = lib.optionals cfg.bluetooth.enable [
        "bluetooth.service"
        "dbus.service"
      ];
      serviceConfig = {
        TimeoutStopSec = lib.mkForce 90;
        RuntimeDirectory = "caz-home-assistant";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = lib.mkBefore [ (lib.getExe prepare) ];
      };
    };
  };
}
