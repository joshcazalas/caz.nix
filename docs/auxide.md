# Auxide

[Auxide](https://github.com/joshcazalas/auxide) is integrated as a pinned flake input and hardened
native NixOS service. It remains disabled until its server-local configuration and host-encrypted
Discord token have been provisioned. Neither file belongs in this repository, SOPS, an environment
variable, or a release artifact.

## Provision local state

The application IDs in `config.toml` are non-secret Discord snowflakes. Start from Auxide's
`config.example.toml`, replace the examples, and preserve the systemd credential token path.

```console
sudo install -d -m 0700 -o root -g root /var/lib/auxide
sudoedit /var/lib/auxide/config.toml
sudo chmod 0600 /var/lib/auxide/config.toml
sudo chown root:root /var/lib/auxide/config.toml
sudo auxide-credential set
sudo auxide-credential status
```

The helper prompts without placing the token in shell history, encrypts it to this host's systemd
credential key, verifies it, and atomically writes `/var/lib/auxide/discord-token`. A release never
creates, overwrites, or rotates either local file.

## Enable and validate

Change `homelab.auxide.enable` in `hosts/homeserver/default.nix` only after both files exist. The
next release includes `auxide.service` and `http://127.0.0.1:9090/health/ready` in automatic
post-deployment health checks. No firewall port or public reverse proxy is added.

Register slash commands once using the systemd credentials, then start the service. Follow
Auxide's operator guide for the exact command and deferred private-guild voice acceptance test.

The service has supplementary membership in `media`, reserving read-only access to
`/var/lib/homelab/media` for a future local-library adapter. Phase 1 YouTube playback does not write
media files there and does not use `/srv`.
