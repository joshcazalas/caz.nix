{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  website = config.homelab.website;
  hostnames =
    lib.optional (website.enable && website.public.enable) website.public.domain
    ++ lib.optional (
      config.homelab.bluemap.enable && settings.public.bluemap
    ) "map.${settings.public.domain}";
  secretName = "cloudflare/tunnel-token";
in
lib.mkIf (hostnames != [ ]) {
  assertions = [
    {
      assertion = lib.intersectLists hostnames config.homelab.cloudflareDdns.domains == [ ];
      message = "Tunnel hostnames must be excluded from the public IPv4 updater.";
    }
  ];

  # Household clients connect straight to Caddy using the same HTTPS names.
  services.adguardhome.settings.filtering.rewrites = lib.mkAfter (
    map (domain: {
      inherit domain;
      answer = settings.server.lanAddress;
      enabled = true;
    }) hostnames
  );

  services.caddy.virtualHosts = lib.genAttrs hostnames (name: {
    useACMEHost = name;
  });
  security.acme = {
    acceptTerms = true;
    certs = lib.genAttrs hostnames (_: {
      dnsProvider = "cloudflare";
      dnsResolver = "1.1.1.1:53";
      credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets."cloudflare/api-token".path;
    });
  };

  sops.secrets.${secretName} = {
    sopsFile = ../../secrets/homeserver.yaml;
    key = "cloudflare/tunnelToken";
    restartUnits = [ "public-web-tunnel.service" ];
  };

  # The dashboard owns the two hostname routes.
  systemd.services.public-web-tunnel = {
    description = "Cloudflare Tunnel for public websites";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      "adguardhome.service"
    ];
    after = [
      "network-online.target"
      "adguardhome.service"
    ];

    # During a live switch AdGuard can be starting while network-online is
    # already active. Probe the same discovery chain cloudflared needs.
    path = [
      pkgs.bind.dnsutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    preStart = ''
      for attempt in {1..20}; do
        if edge=$(dig +time=1 +tries=1 +short SRV _v2-origintunneld._tcp.argotunnel.com. |
            awk 'NF == 4 && $3 == 7844 { print $4; exit }') &&
          [[ -n "$edge" ]] &&
          dig +time=1 +tries=1 +short A "$edge" | grep -Eq '^[0-9]+([.][0-9]+){3}$'; then
          exit 0
        fi
        sleep 1
      done
      echo "Cloudflare edge discovery DNS is unavailable" >&2
      exit 1
    '';
    serviceConfig = {
      DynamicUser = true;
      Type = "notify";
      TimeoutStartSec = "120s";
      LoadCredential = "tunnel-token:${config.sops.secrets.${secretName}.path}";
      ExecStart = "${lib.getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/tunnel-token";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
}
