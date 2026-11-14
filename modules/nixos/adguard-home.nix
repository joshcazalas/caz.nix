{ config, settings, ... }:
let
  # Resolve the server's short name and managed public names to its reserved
  # LAN address. Reuse existing settings without publishing device inventory.
  localRewrites = map (domain: {
    inherit domain;
    answer = settings.server.lanAddress;
    enabled = true;
  }) ([ settings.server.hostName ] ++ config.homelab.cloudflareDdns.domains);
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

  # DNS and the administration UI are admitted only from private addresses by
  # network-policy.nix. Never expose an open DNS resolver to the Internet.
}
