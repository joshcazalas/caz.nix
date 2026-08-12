# Secrets

The flake includes sops-nix, but no secret is needed for the current local-only
configuration. Never put private keys, API tokens, passwords, or plaintext
secret values directly in a Nix expression: evaluated Nix values can end up in
the world-readable Nix store.

The intended later workflow is:

1. Create a dedicated age identity for the server and keep a recovery identity
   somewhere other than the server.
2. Copy `.sops.yaml.example` to `.sops.yaml` and replace both recipients.
3. Create an encrypted `secrets/homeserver.yaml` with `sops`. Encrypted secret
   files are safe and expected to be committed.
4. Declare only runtime file paths with sops-nix, such as
   `/run/secrets/wireguard-private-key`.

The first likely secrets are the WireGuard private key and a narrowly scoped
Cloudflare DNS API token. Jellyfin and Samba manage user password hashes in
their own state and do not belong in this Git repository.

Reference: <https://github.com/Mic92/sops-nix>
