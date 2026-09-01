# Secrets

The repository retains a sops-nix recipient policy for runtime secrets. The
first active consumer is the optional Cloudflare DDNS service.
Never put private keys, API tokens, passwords, hostnames intended to remain
private, or plaintext secret values in a Nix expression: evaluated Nix values
can end up in the world-readable Nix store.

When a future `secrets/homeserver.yaml` is created, `.sops.yaml` encrypts it for
two identities derived from existing Ed25519 SSH keys:

- the administrator's raw SSH public key, so the repository owner can edit and
  recover it with the normal SSH private key;
- the native age recipient produced from the homeserver SSH host public key by
  `ssh-to-age`, matching how sops-nix imports `sops.age.sshKeyPaths` during
  activation.

The public recipients in `.sops.yaml` and any future ciphertext are safe and
expected to be committed. Neither private key belongs in this repository.

To edit that file locally after it exists:

```bash
nix develop
SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519" \
  sops secrets/homeserver.yaml
```

To replace the homeserver recipient, convert its public host key first:

```bash
nix shell nixpkgs#ssh-to-age --command sh -c \
  'ssh-to-age < /path/to/ssh_host_ed25519_key.pub'
```

Put that `age1...` value in `.sops.yaml`, then rewrap the data keys:

```bash
SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519" \
  sops updatekeys secrets/homeserver.yaml
```

Keep an encrypted backup of the administrator private key somewhere other than
the server. Losing both private keys makes the ciphertext unrecoverable.

Minecraft membership is mutable server state under `/var/lib/minecraft`, not a
repository secret. The Cloudflare DDNS API token belongs here; public DNS
hostnames do not. Jellyfin and Samba manage user password hashes in their own
state and do not belong in this repository.

When the private game-stream gateway is enabled, `gameStreamGatewayConfig`
contains an ordinary `wg-quick` server document: one interface and one exact
`/32` peer entry per remote client. Edit it with `sops
secrets/homeserver.yaml`. Only the gateway private key is secret; peer public
keys and tunnel addresses remain encrypted here as a metadata-privacy choice.
The public Nix module passes the document directly to `wg-quick` and does not
parse it or derive firewall policy from peer order.

Client private keys stay in the official WireGuard app on their originating
Windows devices. Never copy a client private key into this repository. The
gateway document must not contain a Sunshine-host peer: remote traffic is
forwarded and source-NATed to the host's reserved LAN address instead.

When private household access is enabled, `homeAccessGatewayConfig` follows the
same ownership model for the separate `wg-home` interface. Every peer must use
an exact `/32` `AllowedIPs` entry that also appears in exactly one declarative
`administrator` or `resident` role. The encrypted document proves possession of
a tunnel key; the public Nix firewall policy decides which homeserver and LAN
services that address may reach. Never reuse a `wg-game` peer or private key in
`wg-home`.

Reference: <https://github.com/Mic92/sops-nix>
