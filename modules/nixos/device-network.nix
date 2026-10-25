{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  cfg = config.homelab.deviceNetwork;
  runtime = "/run/caz-device-network";
  command = pkgs.writeShellApplication {
    name = "caz-device-network";
    runtimeInputs = with pkgs; [
      iproute2
      iptables
      iw
      procps
      dnsmasq
      hostapd
      socat
      systemd
    ];
    text = ''
      umask 077
      exec ${lib.getExe pkgs.python3} ${../../packages/device-network/device-network.py} --config ${lib.escapeShellArg cfg.configFile} "$@"
    '';
  };
  executable = lib.getExe command;
  generator = pkgs.writeShellScript "device-network-generator" ''
    exec ${executable} generate "$@"
  '';
  member = {
    requires = [ "device-network.service" ];
    after = [ "device-network.service" ];
    bindsTo = [ "device-network.service" ];
    partOf = [
      "device-network.target"
      "device-network.service"
    ];
  };
  hardened = {
    Restart = "on-failure";
    RestartSec = 3;
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    UMask = "0077";
    ReadWritePaths = [ runtime ];
    TimeoutStopSec = 15;
  };
  proxy =
    side:
    member
    // {
      description = "Fixed TCP grant for the isolated device network (${side}, %i)";
      serviceConfig =
        hardened
        // {
          ExecStart = "${executable} --config ${runtime}/config.json proxy-${side} %i";
          # socat handles SIGTERM and exits with 128 + signal rather than
          # letting the kernel report a signal termination to systemd.
          SuccessExitStatus = [ 143 ];
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_UNIX"
          ];
          TasksMax = 128;
          MemoryMax = "128M";
        }
        // lib.optionalAttrs (side == "network") {
          NetworkNamespacePath = "/run/netns/devices";
        };
    };
in
{
  options.homelab.deviceNetwork = {
    enable = lib.mkEnableOption "an isolated network for devices using local services";

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${settings.server.dataRoot}/device-network/network.json";
      description = ''
        Root-owned mode 0600 runtime JSON defining the dedicated interface,
        Wi-Fi identity, subnet, local DNS and exact TCP service grants. Read
        at runtime; never import this file into Nix or commit its contents.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = command;
      description = "Validation and health command for deployment integration.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "${settings.server.dataRoot}/" cfg.configFile;
        message = "Device network configuration must remain beneath the private homelab data root.";
      }
      {
        assertion = !config.networking.enableIPv6;
        message = "The device network currently supports the reviewed IPv4-only host policy.";
      }
    ];

    environment.systemPackages = [ command ];
    systemd.tmpfiles.rules = [
      "d ${settings.server.dataRoot}/device-network 0700 root root -"
    ];

    # Only proxy instance names are generated. All service definitions and
    # executables belong to the NixOS release; household configuration and
    # credentials remain private. A daemon-reload rereads the grant list.
    systemd.generators.device-network = generator;

    systemd.targets.device-network = {
      description = "Isolated devices and their explicitly granted local services";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "device-network.service"
        "device-network-dns.service"
      ];
      after = [
        "device-network.service"
        "device-network-dns.service"
      ];
    };

    systemd.services = {
      device-network = {
        description = "Prepare the dedicated device network without a host uplink";
        partOf = [ "device-network.target" ];
        before = [ "device-network.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "caz-device-network";
          RuntimeDirectoryMode = "0700";
          # Retain ownership information if cleanup refuses a busy namespace.
          RuntimeDirectoryPreserve = true;
          ExecStartPre = "${executable} prepare";
          ExecStart = "${executable} --config ${runtime}/config.json up";
          ExecStopPost = "${executable} down";
          TimeoutStartSec = 45;
          TimeoutStopSec = 30;
          UMask = "0077";
        };
      };

      device-network-dns = member // {
        description = "DHCP and local-only DNS for isolated devices";
        serviceConfig = hardened // {
          NetworkNamespacePath = "/run/netns/devices";
          ExecStart = "${lib.getExe pkgs.dnsmasq} --keep-in-foreground --conf-file=${runtime}/dnsmasq.conf";
          CapabilityBoundingSet = [
            "CAP_NET_BIND_SERVICE"
            "CAP_NET_ADMIN"
            "CAP_NET_RAW"
            "CAP_SETUID"
            "CAP_SETGID"
          ];
        };
      };

      device-network-wifi = member // {
        description = "Dedicated access point for isolated devices";
        serviceConfig = hardened // {
          NetworkNamespacePath = "/run/netns/devices";
          ExecStart = "${lib.getExe' pkgs.hostapd "hostapd"} ${runtime}/hostapd.conf";
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN"
            "CAP_NET_RAW"
          ];
        };
      };

      "device-network-host@" = proxy "host";
      "device-network-network@" = proxy "network";
    };
  };
}
