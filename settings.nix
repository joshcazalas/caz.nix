{
  user = {
    name = "joshcaz";
    gitEmail = "73436834+joshcazalas@users.noreply.github.com";
    sshPublicKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJPPR7VdBolKryex6C9qgqq6XQU5snK1Z3HcEkqRkK/a"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXty6E2n/hPoz1jIwHVKk5RWmOGBSZdrqgSJ7pMZW3J"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKgqSWIPoN6upB8ACKHRcINxl1EaVJxEJi6Smqnitrid"
    ];
  };

  server = {
    hostName = "homeserver";
    # The router keeps this address reserved for the homeserver. Services that
    # publish or route back into the LAN share it from this single setting.
    lanAddress = "192.168.1.127";
    timeZone = "America/Chicago";
    # Until reliable secondary storage is installed, shared service data lives
    # explicitly on the root NVMe instead of implying that /srv is available.
    dataRoot = "/var/lib/homelab";
  };

  # Public application publishing remains opt-in even though the DNS zone is
  # declared. A domain name alone never opens a firewall port or service.
  public = {
    domain = "joshcaz.com";
    ssh = true;
    jellyfin = false;
    # A read-only static tile server. Much smaller attack surface than
    # Jellyfin, but still a deliberate Internet exposure: it needs the router
    # forward and DNS record from docs/bluemap.md before it can work.
    bluemap = true;
  };
}
