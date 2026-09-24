{ settings, ... }:
{
  # Only the physical uplink owns a DHCP lease. VPN/container addresses must
  # neither satisfy dhcpcd's readiness check nor acquire link-local addresses.
  networking.useDHCP = false;
  networking.interfaces.${settings.server.lanInterface}.useDHCP = true;
  networking.dhcpcd = {
    wait = "ipv4";
    # Manager mode otherwise backgrounds after 30 seconds without a lease.
    # Only a DHCP address should satisfy readiness, never IPv4 link-local.
    extraConfig = ''
      timeout 0
      noipv4ll
    '';
    # Keep the address, routes, and resolver configuration across live switches.
    persistent = true;
  };
  # Let systemd fail and retry an unavailable uplink instead of reporting ready.
  systemd.services.dhcpcd.serviceConfig.TimeoutStartSec = 90;
}
