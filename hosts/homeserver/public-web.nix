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
  credential = "public-web-tunnel";
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

  # The dashboard owns the two hostname routes. The operator provisions the
  # connector token as a host-encrypted systemd credential before deployment.
  systemd.services.public-web-tunnel = {
    description = "Cloudflare Tunnel for public websites";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      DynamicUser = true;
      LoadCredentialEncrypted = credential;
      ExecStart = "${lib.getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/${credential}";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
}
