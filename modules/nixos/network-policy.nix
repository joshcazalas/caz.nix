{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.homelab.networkPolicy;
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    optionals
    unique
    ;

  # Deliberately broad enough for ordinary home LANs without publishing this
  # home's exact network topology.
  privateIPv4Ranges = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];

  privateTCPPorts = [
    22 # SSH
    53 # AdGuard Home DNS
    139 # Samba/NetBIOS session
    445 # Samba direct hosting
    3000 # AdGuard Home administration
    5357 # Web Services Discovery
    8096 # Jellyfin HTTP
  ]
  ++ optionals config.homelab.homeAssistant.enable [ 8123 ]
  ++ optionals config.homelab.immich.enable [ 2283 ];

  privateUDPPorts = [
    53 # AdGuard Home DNS
    137 # Samba/NetBIOS name service
    138 # Samba/NetBIOS datagram service
    1900 # Jellyfin SSDP discovery
    3702 # Web Services Discovery
    5353 # Avahi/mDNS
    7359 # Jellyfin client discovery
  ];

  portList = ports: concatStringsSep "," (map toString ports);
  allowedRestrictedClientRules =
    client:
    concatStringsSep "\n" (
      optionals (client.allowedTCPPorts != [ ]) [
        "iptables -w -I nixos-fw 1 -s ${client.address}/32 -p tcp -m multiport --dports ${portList client.allowedTCPPorts} -j nixos-fw-accept"
      ]
      ++ optionals (client.allowedUDPPorts != [ ]) [
        "iptables -w -I nixos-fw 1 -s ${client.address}/32 -p udp -m multiport --dports ${portList client.allowedUDPPorts} -j nixos-fw-accept"
      ]
    );
  restrictedClientRules = concatMapStringsSep "\n" (client: ''
    # Insert the broad denies first, then the narrow exceptions at the same
    # chain position so the exceptions finish ahead of the denies.
    iptables -w -I nixos-fw 1 -s ${client.address}/32 -p tcp -m multiport --dports ${portList privateTCPPorts} -j nixos-fw-log-refuse
    iptables -w -I nixos-fw 1 -s ${client.address}/32 -p udp -m multiport --dports ${portList privateUDPPorts} -j nixos-fw-log-refuse
    ${allowedRestrictedClientRules client}
  '') cfg.restrictedLANClients;
  privateContainerDenyRules =
    concatMapStringsSep "\n"
      (interface: ''
        iptables -w -A nixos-fw -i ${interface} -p tcp -m multiport --dports ${portList privateTCPPorts} -j nixos-fw-log-refuse
        iptables -w -A nixos-fw -i ${interface} -p udp -m multiport --dports ${portList privateUDPPorts} -j nixos-fw-log-refuse
      '')
      [
        "docker+"
        "br-+"
      ];
  privateAcceptRules = concatMapStringsSep "\n" (source: ''
    iptables -w -A nixos-fw ! -i wg+ -s ${source} -p tcp -m multiport --dports ${portList privateTCPPorts} -j nixos-fw-accept
    iptables -w -A nixos-fw ! -i wg+ -s ${source} -p udp -m multiport --dports ${portList privateUDPPorts} -j nixos-fw-accept
  '') privateIPv4Ranges;

  expectedPublicTCPPorts =
    optionals settings.public.ssh config.services.openssh.ports
    ++ optionals (config.homelab.minecraft.enable && config.homelab.minecraft.openFirewall) [
      config.homelab.minecraft.port
    ]
    ++ optionals (settings.public.jellyfin || settings.public.bluemap) [
      80
      443
    ];
  expectedPublicUDPPorts =
    optionals config.homelab.gameStreamGateway.enable [
      config.homelab.gameStreamGateway.listenPort
    ]
    ++ optionals config.homelab.homeAccessGateway.enable [
      config.homelab.homeAccessGateway.listenPort
    ];

  normalized = ports: lib.sort builtins.lessThan (unique ports);
in
{
  options.homelab.networkPolicy.restrictedLANClients = lib.mkOption {
    default = [ ];
    description = ''
      LAN clients that must not inherit the ordinary private-network service
      policy. Narrow exceptions are inserted before an explicit deny for every
      private service port.
    '';
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
            description = "Reserved IPv4 address of the restricted LAN client.";
          };
          allowedTCPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
            description = "Private TCP service exceptions for this client.";
          };
          allowedUDPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
            description = "Private UDP service exceptions for this client.";
          };
        };
      }
    );
  };

  config = {
    # The host currently has globally routed IPv6. Keep it disabled until an
    # explicit IPv6 firewall and external exposure test are reviewed. Minecraft
    # remains available over the intentionally forwarded IPv4 port.
    networking.enableIPv6 = false;
    networking.nftables.enable = false;

    networking.firewall = {
      enable = true;
      checkReversePath = true;

      # The current iptables firewall backend inserts these rules immediately
      # before its final reject rule. Service modules keep openFirewall disabled,
      # so private applications and discovery traffic are accepted only from
      # private IPv4 sources. Public SSH is listed separately in
      # expectedPublicTCPPorts. Reverse-path checking helps reject spoofed sources.
      extraCommands = ''
        # Restricted LAN clients are still physically local, but do not inherit
        # the broad household-client policy. These inserted rules also precede
        # globally open public ports such as SSH.
        ${restrictedClientRules}

        # Docker also uses RFC 1918 addresses. Do not treat containers as trusted
        # LAN clients if one of them becomes compromised.
        ${privateContainerDenyRules}

        ${privateAcceptRules}
      '';
    };

    assertions = [
      {
        assertion =
          builtins.length (unique (map (client: client.address) cfg.restrictedLANClients))
          == builtins.length cfg.restrictedLANClients;
        message = "Restricted LAN client addresses must be unique.";
      }
      {
        assertion = lib.all (
          client:
          lib.all (port: lib.elem port privateTCPPorts) client.allowedTCPPorts
          && lib.all (port: lib.elem port privateUDPPorts) client.allowedUDPPorts
        ) cfg.restrictedLANClients;
        message = "Restricted LAN client exceptions must be subsets of the reviewed private service ports.";
      }
      {
        assertion = lib.all (
          client: builtins.length client.allowedTCPPorts <= 15 && builtins.length client.allowedUDPPorts <= 15
        ) cfg.restrictedLANClients;
        message = "Restricted LAN client protocol exceptions may contain at most 15 ports per iptables multiport rule.";
      }
      {
        assertion = !config.networking.enableIPv6;
        message = "IPv6 requires an explicit firewall policy and external exposure test.";
      }
      {
        assertion = !config.networking.nftables.enable;
        message = "network-policy.nix currently requires the NixOS iptables firewall backend.";
      }
      {
        assertion =
          normalized config.networking.firewall.allowedTCPPorts == normalized expectedPublicTCPPorts;
        message = ''
          The global TCP firewall ports differ from the reviewed public-service
          policy. Keep management ports in network-policy.nix and explicitly
          review any new Internet-facing service.
        '';
      }
      {
        assertion =
          normalized config.networking.firewall.allowedUDPPorts == normalized expectedPublicUDPPorts;
        message = ''
          The global UDP firewall ports differ from the reviewed public-service
          policy. Keep management ports in network-policy.nix and explicitly
          review any new Internet-facing service.
        '';
      }
      {
        assertion =
          config.networking.firewall.allowedTCPPortRanges == [ ]
          && config.networking.firewall.allowedUDPPortRanges == [ ];
        message = "Global firewall port ranges require an explicit network-policy review.";
      }
    ];
  };
}
