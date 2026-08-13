{
  services.adguardhome = {
    enable = true;
    host = "0.0.0.0";
    port = 3000;
    mutableSettings = true;
    settings = {
      dns = {
        upstream_dns = [ "https://dns.quad9.net/dns-query" ];
        bootstrap_dns = [
          "9.9.9.9"
          "149.112.112.112"
        ];
        protection_enabled = true;
      };
    };
  };

  # DNS and the administration UI are admitted only from private addresses by
  # network-policy.nix. Never expose an open DNS resolver to the Internet.
}
