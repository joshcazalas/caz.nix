{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  # Managed public names keep their existing LAN answers.
  localRewrites = map (domain: {
    inherit domain;
    answer = settings.server.lanAddress;
    enabled = true;
  }) config.homelab.cloudflareDdns.domains;
  homeAccess = config.homelab.homeAccessGateway or { enable = false; };
  vpnClients = lib.optionals homeAccess.enable (
    map (peer: peer.address) (homeAccess.administrator.peers ++ homeAccess.resident.peers)
  );
  gatewayAddress = lib.head (lib.splitString "/" homeAccess.address);
  hostnames = [
    settings.server.hostName
  ]
  ++ lib.optional config.homelab.homeAssistant.enable config.homelab.homeAssistant.https.hostName;
  # Each exact name gets mutually exclusive answers so VPN clients can keep /32 routes.
  rulesFor =
    hostname:
    let
      prefix = "|${hostname}|$dnsrewrite=NOERROR;A;";
    in
    [
      (
        prefix
        + settings.server.lanAddress
        +
          lib.optionalString (vpnClients != [ ])
            ",client=${lib.concatMapStringsSep "|" (ip: "~${ip}") vpnClients}"
      )
    ]
    ++ lib.optional (vpnClients != [ ]) (
      prefix + gatewayAddress + ",client=${lib.concatStringsSep "|" vpnClients}"
    );
  hostnamePlan = pkgs.writeText "adguard-hostname-plan.json" (
    builtins.toJSON {
      inherit hostnames;
      rules = lib.concatMap rulesFor hostnames;
    }
  );
  python = pkgs.python3.withPackages (ps: [
    ps.bcrypt
    ps.pyyaml
  ]);
in
{
  services.adguardhome = {
    enable = true;
    host = "0.0.0.0";
    port = 3000;
    mutableSettings = true;
    settings = {
      dns = {
        # NixOS maps its own hostname to loopback in /etc/hosts. Those local
        # aliases must not become DNS answers sent to other machines.
        hostsfile_enabled = false;
        upstream_dns = [ "https://dns.quad9.net/dns-query" ];
        # Keep encrypted resolution available when Quad9's DoH connection
        # fails. This alternate provider also filters malware domains.
        fallback_dns = [ "https://security.cloudflare-dns.com/dns-query" ];
        bootstrap_dns = [
          "9.9.9.9"
          "149.112.112.112"
          "1.1.1.2"
          "1.0.0.2"
        ];
      };
      filtering = {
        protection_enabled = true;
        rewrites = localRewrites;
        rewrites_enabled = true;
      };
    };
  };

  # Run after NixOS merges its settings into the mutable file. Managing
  # settings.user_rules directly would erase custom rules saved through the UI.
  systemd.services.adguardhome.preStart = lib.mkAfter ''
    ${python}/bin/python ${../../scripts/prepare-adguard-home.py} \
      "$STATE_DIRECTORY/AdGuardHome.yaml" ${hostnamePlan}
  '';

  # DNS and the administration UI are admitted only from private addresses by
  # network-policy.nix. Never expose an open DNS resolver to the Internet.
}
