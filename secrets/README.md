# Secrets

The homeserver uses sops-nix to decrypt secrets only at activation/runtime.
Never put private keys, API tokens, passwords, hostnames intended to remain
private, or plaintext secret values in a Nix expression: evaluated Nix values
can end up in the world-readable Nix store.

`secrets/homeserver.yaml` is encrypted for two identities derived from existing
Ed25519 SSH keys:

- the administrator's raw SSH public key, so the repository owner can edit and
  recover it with the normal SSH private key;
- the native age recipient produced from the homeserver SSH host public key by
  `ssh-to-age`, matching how sops-nix imports `sops.age.sshKeyPaths` during
  activation.

The public recipients in `.sops.yaml` and ciphertext in
`secrets/homeserver.yaml` are safe and expected to be committed. Neither
private key belongs in this repository.

To edit the encrypted file locally:

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

Minecraft consumes the whitelist and operator list as runtime files under
`/run/secrets`; the names never enter the Nix store. A future Cloudflare DDNS
token—and its hostname if the hostname should stay out of Git—belong here too.
Jellyfin and Samba manage user password hashes in their own state and do not
belong in this repository.

Reference: <https://github.com/Mic92/sops-nix>
