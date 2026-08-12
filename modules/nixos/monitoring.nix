{
  services.beszel.hub = {
    enable = true;
    host = "0.0.0.0";
    port = 8090;
  };

  # Keep the dashboard private: LAN/WireGuard only, with no router forwarding.
  networking.firewall.allowedTCPPorts = [ 8090 ];
}
