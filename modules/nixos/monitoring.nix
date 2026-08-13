{
  services.beszel.hub = {
    enable = true;
    host = "0.0.0.0";
    port = 8090;
  };
  # network-policy.nix admits the dashboard only from private addresses.
}
