{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.homeAccessGateway;
  interfaceName = "wg-home";
  secretName = "home-access-gateway/private-key";
  productionPrivateKey = cfg._testPrivateKeyFile == null;
  privateKeyFile =
    if productionPrivateKey then
      config.sops.secrets.${secretName}.path
    else
      toString cfg._testPrivateKeyFile;

  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    unique
    ;

  peerType = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
        description = "Exact WireGuard IPv4 address assigned to this peer.";
      };
      publicKey = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9+/]{43}=";
        description = "WireGuard public key generated on this peer device.";
      };
    };
  };

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
      peers = lib.mkOption {
        type = lib.types.listOf peerType;
        default = [ ];
        description = ''
          WireGuard peers assigned to this role. Each declaration generates
          both its exact /32 cryptokey route and its firewall grants.
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
  allPeers = builtins.concatLists (map (role: role.peers) roles);
  allPeerAddresses = map (peer: peer.address) allPeers;
  allPeerPublicKeys = map (peer: peer.publicKey) allPeers;
  gatewayAddress = lib.head (lib.splitString "/" cfg.address);

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
          peer:
          map (port: inputRule "tcp" port "${peer.address}/32") role.gatewayTCPPorts
          ++ map (port: inputRule "udp" port "${peer.address}/32") role.gatewayUDPPorts
          ++ builtins.concatLists (
            map (
              target:
              map (port: forwardRule "tcp" port "${peer.address}/32" target) target.tcpPorts
              ++ map (port: forwardRule "udp" port "${peer.address}/32" target) target.udpPorts
            ) role.forwardTargets
          )
        ) role.peers
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

    address = lib.mkOption {
      type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])";
      default = "10.77.1.1/24";
      description = "IPv4 address and prefix assigned to the household gateway interface.";
    };

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

    _testPrivateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      internal = true;
      description = "Test-only throwaway WireGuard private-key file override.";
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
        assertion = builtins.length (unique allPeerPublicKeys) == builtins.length allPeerPublicKeys;
        message = "Household WireGuard public keys must be unique across roles.";
      }
      {
        assertion = lib.all (address: address != gatewayAddress) allPeerAddresses;
        message = "A household WireGuard peer may not use the gateway interface address.";
      }
      {
        assertion = lib.all (role: role.peers == [ ] || roleHasAccess role) roles;
        message = "Every populated household access role must grant at least one explicit service.";
      }
      {
        assertion = lib.all (
          role: lib.all (target: target.tcpPorts != [ ] || target.udpPorts != [ ]) role.forwardTargets
        ) roles;
        message = "Household gateway forwarding targets must grant at least one explicit port.";
      }
    ];

    sops.secrets.${secretName} = lib.mkIf productionPrivateKey {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "homeAccessGatewayPrivateKey";
      mode = "0400";
      restartUnits = [ "wg-quick-${interfaceName}.service" ];
    };

    networking.wg-quick.interfaces.${interfaceName} = {
      autostart = true;
      address = [ cfg.address ];
      inherit (cfg) listenPort;
      inherit privateKeyFile;
      peers = map (peer: {
        inherit (peer) publicKey;
        allowedIPs = [ "${peer.address}/32" ];
      }) allPeers;
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
