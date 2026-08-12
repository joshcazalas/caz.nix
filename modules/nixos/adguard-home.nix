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

  # These ports are for LAN and WireGuard clients. Do not forward them at the
  # router; especially never expose an open DNS resolver to the Internet.
  networking.firewall = {
    allowedTCPPorts = [
      53
      3000
    ];
    allowedUDPPorts = [ 53 ];
  };
}
