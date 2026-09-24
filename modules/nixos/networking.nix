{ settings, ... }:
{
  # Only the physical uplink owns a DHCP lease. VPN/container addresses must
  # neither satisfy dhcpcd's readiness check nor acquire link-local addresses.
  networking.useDHCP = false;
  networking.interfaces.${settings.server.lanInterface}.useDHCP = true;
  networking.dhcpcd = {
    wait = "ipv4";
    # Keep the address, routes, and resolver configuration across live switches.
    persistent = true;
  };
}
