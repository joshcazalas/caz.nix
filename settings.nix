{
  user = {
    name = "joshcaz";
    gitEmail = "73436834+joshcazalas@users.noreply.github.com";
    sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJPPR7VdBolKryex6C9qgqq6XQU5snK1Z3HcEkqRkK/a";
  };

  server = {
    hostName = "homeserver";
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
