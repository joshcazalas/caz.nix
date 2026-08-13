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

  # Public publishing is intentionally two-step. Replace the placeholder and
  # then opt in, so an evaluation can never expose a service by accident.
  public = {
    domain = "example.invalid";
    jellyfin = false;
  };
}
