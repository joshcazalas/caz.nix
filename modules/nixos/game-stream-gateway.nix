{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.gameStreamGateway;
  interfaceName = "wg-game";
  secretName = "game-stream-gateway/config";
  productionConfiguration = cfg._testConfigFile == null;
  configurationFile =
    if productionConfiguration then config.sops.secrets.${secretName}.path else cfg._testConfigFile;
in
{
  options.homelab.gameStreamGateway = {
    enable = lib.mkEnableOption "the narrowly filtered game-stream WireGuard gateway";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = "The single public UDP listener forwarded to this gateway.";
    };

    hostAddress = lib.mkOption {
      type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
      description = ''
        The Sunshine host's reserved LAN IPv4 address. Authenticated game-stream
        clients can reach only this address and only Sunshine's streaming ports.
      '';
    };

    wakeOnLan = {
      enable = lib.mkEnableOption "delivery of Moonlight wake packets while the host cannot answer ARP";
      interface = lib.mkOption {
        type = lib.types.strMatching "[a-zA-Z0-9_.:-]+";
        description = "The physical LAN interface directly connected to the gaming host's subnet.";
      };
      macAddress = lib.mkOption {
        type = lib.types.strMatching "([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}";
        description = "The host's Ethernet MAC address, matching its DHCP reservation.";
      };
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
        message = "The game-stream WireGuard interface must remain untrusted.";
      }
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "The game-stream gateway currently requires the NixOS iptables firewall backend.";
      }
    ];

    sops.secrets.${secretName} = lib.mkIf productionConfiguration {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "gameStreamGatewayConfig";
      mode = "0400";
      restartUnits = [ "wg-quick-${interfaceName}.service" ];
    };

    networking.wg-quick.interfaces.${interfaceName} = {
      autostart = true;
      configFile = configurationFile;
    };

    # NixOS marks packets arriving on wg-game and masquerades them after the
    # kernel selects the ordinary LAN route. No physical interface name or
    # return route on the Windows host is required.
    networking.nat = {
      enable = true;
      internalInterfaces = [ interfaceName ];
    };

    # Moonlight sends its magic packet to the normal streaming UDP ports as
    # well as port 9. Existing forwarding rules already permit those packets.
    # A permanent neighbor lets the gateway deliver them after the sleeping
    # host stops answering ARP. No extra listener, LAN access, or client route
    # is needed. Windows must allow magic-packet wake on this Ethernet NIC.
    systemd.services.game-stream-host-neighbor = lib.mkIf cfg.wakeOnLan.enable {
      description = "Keep the gaming host's Ethernet address available for Wake-on-LAN";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "sys-subsystem-net-devices-${cfg.wakeOnLan.interface}.device"
      ];
      bindsTo = [ "sys-subsystem-net-devices-${cfg.wakeOnLan.interface}.device" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
      script = ''
        ip neigh replace ${cfg.hostAddress} lladdr ${cfg.wakeOnLan.macAddress} \
          nud permanent dev ${cfg.wakeOnLan.interface}
      '';
      preStop = ''
        ip neigh del ${cfg.hostAddress} dev ${cfg.wakeOnLan.interface} || true
      '';
    };

    networking.firewall = {
      allowedUDPPorts = [ cfg.listenPort ];

      # These rules precede NixOS's generic NAT forwarding chain. An
      # authenticated wg-game peer can reach exactly the Sunshine host and
      # ports; all other forwarding and all gateway-local input are denied.
      # WireGuard itself binds every accepted packet source to a peer's exact
      # AllowedIPs declaration in the encrypted configuration.
      extraCommands = lib.mkBefore ''
        iptables -w -I nixos-fw 1 -i ${interfaceName} -j nixos-fw-log-refuse

        iptables -w -I FORWARD 1 -i ${interfaceName} -j DROP
        iptables -w -I FORWARD 1 -i ${interfaceName} -d ${cfg.hostAddress}/32 \
          -p udp -m multiport --dports 47998:48000,48002,48010 \
          -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables -w -I FORWARD 1 -i ${interfaceName} -d ${cfg.hostAddress}/32 \
          -p tcp -m multiport --dports 47984,47989,48010 \
          -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
      '';
    };

    # Starting the tunnel requires the firewall. The ordering also stops the
    # tunnel before firewall rules are removed, so a firewall restart cannot
    # briefly turn the VPN into unrestricted forwarding.
    systemd.services."wg-quick-${interfaceName}" = {
      requires = [ "firewall.service" ];
      after = [ "firewall.service" ];
      partOf = [ "firewall.service" ];
    };
  };
}
