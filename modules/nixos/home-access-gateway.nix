{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.homeAccessGateway;
  interfaceName = "wg-home";
  secretName = "home-access-gateway/config";
  productionConfiguration = cfg._testConfigFile == null;
  configurationFile =
    if productionConfiguration then config.sops.secrets.${secretName}.path else cfg._testConfigFile;

  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    unique
    ;

  forwardTargetType = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
        description = "Reserved LAN IPv4 address of one reachable target.";
      };
      tcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = "TCP ports this role may reach on the target.";
      };
      udpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = "UDP ports this role may reach on the target.";
      };
    };
  };

  roleType = lib.types.submodule {
    options = {
      peerAddresses = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/32");
        default = [ ];
        description = ''
          Exact WireGuard peer addresses assigned to this role. The encrypted
          wg-quick configuration binds each address to one peer public key.
        '';
      };
      gatewayTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = "TCP ports this role may reach on the homeserver itself.";
      };
      gatewayUDPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = "UDP ports this role may reach on the homeserver itself.";
      };
      forwardTargets = lib.mkOption {
        type = lib.types.listOf forwardTargetType;
        default = [ ];
        description = "Exact LAN destinations and ports this role may reach through the gateway.";
      };
    };
  };

  roles = [
    cfg.administrator
    cfg.resident
  ];
  allPeerAddresses = builtins.concatLists (map (role: role.peerAddresses) roles);

  inputRule =
    protocol: port: address:
    "iptables -w -I nixos-fw 1 -i ${interfaceName} -s ${address} -p ${protocol} --dport ${toString port} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j nixos-fw-accept";
  forwardRule =
    protocol: port: address: target:
    "iptables -w -I FORWARD 1 -i ${interfaceName} -s ${address} -d ${target.address}/32 -p ${protocol} --dport ${toString port} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT";

  roleRules =
    role:
    concatStringsSep "\n" (
      builtins.concatLists (
        map (
          address:
          map (port: inputRule "tcp" port address) role.gatewayTCPPorts
          ++ map (port: inputRule "udp" port address) role.gatewayUDPPorts
          ++ builtins.concatLists (
            map (
              target:
              map (port: forwardRule "tcp" port address target) target.tcpPorts
              ++ map (port: forwardRule "udp" port address target) target.udpPorts
            ) role.forwardTargets
          )
        ) role.peerAddresses
      )
    );
  firewallRules = concatMapStringsSep "\n" roleRules roles;

  roleHasAccess =
    role:
    role.gatewayTCPPorts != [ ]
    || role.gatewayUDPPorts != [ ]
    || lib.any (target: target.tcpPorts != [ ] || target.udpPorts != [ ]) role.forwardTargets;
in
{
  options.homelab.homeAccessGateway = {
    enable = lib.mkEnableOption "the role-filtered household WireGuard gateway";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51821;
      description = "The single public UDP listener forwarded to this gateway.";
    };

    administrator = lib.mkOption {
      type = roleType;
      default = { };
      description = "Policy for explicitly designated administration devices.";
    };

    resident = lib.mkOption {
      type = roleType;
      default = { };
      description = "Policy for household devices that need selected applications but no administration.";
    };

    _testConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      internal = true;
      description = "Test-only throwaway WireGuard configuration override.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !lib.elem interfaceName config.networking.firewall.trustedInterfaces;
        message = "The household WireGuard interface must remain untrusted.";
      }
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "The household gateway currently requires the NixOS iptables firewall backend.";
      }
      {
        assertion = allPeerAddresses != [ ];
        message = "The household gateway requires at least one exact peer address.";
      }
      {
        assertion = builtins.length (unique allPeerAddresses) == builtins.length allPeerAddresses;
        message = "Household WireGuard peer addresses must be unique across roles.";
      }
      {
        assertion = lib.all (role: role.peerAddresses == [ ] || roleHasAccess role) roles;
        message = "Every populated household access role must grant at least one explicit service.";
      }
      {
        assertion = lib.all (
          role: lib.all (target: target.tcpPorts != [ ] || target.udpPorts != [ ]) role.forwardTargets
        ) roles;
        message = "Household gateway forwarding targets must grant at least one explicit port.";
      }
    ];

    sops.secrets.${secretName} = lib.mkIf productionConfiguration {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "homeAccessGatewayConfig";
      mode = "0400";
      restartUnits = [ "wg-quick-${interfaceName}.service" ];
    };

    networking.wg-quick.interfaces.${interfaceName} = {
      autostart = true;
      configFile = configurationFile;
    };

    networking.nat = {
      enable = true;
      internalInterfaces = [ interfaceName ];
    };

    networking.firewall = {
      allowedUDPPorts = [ cfg.listenPort ];

      # Put a role-independent deny at the bottom of each tunnel ingress path,
      # then insert exact peer/service exceptions ahead of it. No peer receives
      # an implicit LAN, gateway, or peer-to-peer permission.
      extraCommands = lib.mkBefore ''
        iptables -w -I nixos-fw 1 -i ${interfaceName} -j nixos-fw-log-refuse
        iptables -w -I FORWARD 1 -i ${interfaceName} -j DROP

        ${firewallRules}
      '';
    };

    systemd.services."wg-quick-${interfaceName}" = {
      requires = [ "firewall.service" ];
      after = [ "firewall.service" ];
      partOf = [ "firewall.service" ];
    };
  };
}
