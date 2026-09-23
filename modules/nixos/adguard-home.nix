{ config, settings, ... }:
let
  # These are exactly the public records whose address follows this home's
  # connection. Inside the LAN, answer them with the server's reserved address
  # instead, while every other name continues to the normal upstream resolver.
  localRewrites = map (domain: {
    inherit domain;
    answer = settings.server.lanAddress;
    enabled = true;
  }) config.homelab.cloudflareDdns.domains;
in
{
  services.adguardhome = {
    enable = true;
    host = "0.0.0.0";
    port = 3000;
    mutableSettings = true;
    settings = {
      dns = {
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

  # DNS and the administration UI are admitted only from private addresses by
  # network-policy.nix. Never expose an open DNS resolver to the Internet.
}
