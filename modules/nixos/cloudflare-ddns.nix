{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.homelab.cloudflareDdns;
  secretName = "cloudflare/api-token";
in
{
  options.homelab.cloudflareDdns = {
    enable = lib.mkEnableOption "Cloudflare dynamic DNS updates";

    domains = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "mc.${settings.public.domain}" ];
      description = "DNS-only IPv4 records that should follow the home's public address.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = settings.public.domain != "example.invalid";
        message = "Set settings.public.domain before enabling Cloudflare DDNS.";
      }
      {
        assertion = lib.all (domain: lib.hasSuffix ".${settings.public.domain}" domain) cfg.domains;
        message = "Cloudflare DDNS records must remain inside settings.public.domain.";
      }
      {
        assertion = !config.networking.enableIPv6;
        message = "The initial Cloudflare DDNS policy manages IPv4 only while server IPv6 is disabled.";
      }
    ];

    sops.secrets.${secretName} = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "cloudflare/apiToken";
    };

    sops.templates."cloudflare-ddns.env" = {
      owner = config.services.cloudflare-ddns.user;
      group = config.services.cloudflare-ddns.group;
      mode = "0400";
      restartUnits = [ "cloudflare-ddns.service" ];
      content = ''
        CLOUDFLARE_API_TOKEN=${config.sops.placeholder.${secretName}}
      '';
    };

    services.cloudflare-ddns = {
      enable = true;
      credentialsFile = config.sops.templates."cloudflare-ddns.env".path;

      # IPv6 is deliberately disabled on this host. Managing only A records
      # prevents an accidental public AAAA record from bypassing that policy.
      domains = [ ];
      ip4Domains = cfg.domains;
      ip6Domains = [ ];
      provider = {
        ipv4 = "cloudflare.trace";
        ipv6 = "none";
      };

      updateCron = "@every 5m";
      updateOnStart = true;
      deleteOnStop = false;
      cacheExpiration = "6h";
      ttl = 300;
      proxied = "false";
      recordComment = "managed by caz.nix Cloudflare DDNS";
      detectionTimeout = "10s";
      updateTimeout = "30s";
    };
  };
}
