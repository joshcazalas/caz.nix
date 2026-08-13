# Remote access and public Jellyfin

Use two different trust paths rather than treating every web app the same.

## Dynamic DNS

`homelab.cloudflareDdns` uses NixOS's packaged `favonia/cloudflare-ddns`
service. It checks the public IPv4 address through Cloudflare every five
minutes and reconciles only the explicitly configured DNS records. IPv6
updates are disabled alongside host IPv6, records are never deleted when the
service stops, and the updater has no inbound listener.

Create a Cloudflare API token with exactly:

- permission `Zone` / `DNS` / `Edit`;
- zone resource `Include` / `Specific zone` / `joshcaz.com`;
- no account permissions, global API key, or source-IP restriction.

A source-IP restriction defeats recovery after the public address changes.
Cloudflare displays the token once; put it directly in the sops editor and
never paste it into chat, a command argument, or a plaintext file:

```bash
cd ~/develop/caz.nix
nix develop
SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519" \
  sops secrets/homeserver.yaml
```

The decrypted editor content is:

```yaml
cloudflare:
  apiToken: PASTE_THE_TOKEN_HERE
```

The saved file must contain `ENC[...]` ciphertext and a `sops:` metadata
section. Committing that encrypted file is intentional: only the administrator
SSH key or homeserver SSH host key can unwrap its data key. The active NixOS
generation decrypts the token into a root-managed `/run/secrets` filesystem,
renders a mode-0400 environment file owned by the unprivileged DDNS service,
and never places plaintext in the Nix store.

Before enabling the service, keep every managed Cloudflare record in
**DNS-only** (gray-cloud) mode. The updater preserves an existing record's
proxy setting, while `proxied = false` is the safe fallback for records it
creates.

Operate and verify it with:

```bash
systemctl status cloudflare-ddns.service --no-pager
journalctl -u cloudflare-ddns.service -n 100 --no-pager
dig @1.1.1.1 +short mc.joshcaz.com A
curl -4fsS https://api.ipify.org; echo
```

The two addresses should match. Revoking the scoped token stops future DNS
updates but grants no shell, Cloudflare account, or non-DNS access.

## Public media path

1. Choose the domain and set it in `settings.nix`.
2. Add `jellyfin.<domain>` in Cloudflare DNS as a **DNS-only** A record. Do not
   add an AAAA record while IPv6 remains disabled on the server.
3. Include the hostname in `homelab.cloudflareDdns.domains` so public-address
   changes are reconciled automatically.
4. Forward router TCP 80 and 443 to the server's reserved LAN address.
5. Set `settings.public.jellyfin = true`, evaluate, and deploy. Caddy will obtain
   and renew HTTPS certificates and proxy only to Jellyfin on port 8096.
6. Test from cellular data, not from the home Wi-Fi, including a native client.

Do not forward Jellyfin's port 8096. Do not put Cloudflare Access in front of
Jellyfin: its browser login can work, but native clients generally expect the
Jellyfin API and authentication flow. Each person gets a separate Jellyfin
account and only the owner account is an administrator.

Cloudflare Tunnel remains an option later for small browser-only applications,
but not for the video stream itself. Cloudflare documents that Tunnel-published
traffic passes through its network, and its current delivery policy restricts
using ordinary CDN service for disproportionate video or large-file delivery:

- <https://developers.cloudflare.com/tunnel/>
- <https://developers.cloudflare.com/fundamentals/reference/policies-compliances/delivering-videos-with-cloudflare/>

## Private administration path

WireGuard is the simple, fully open-source default. It gives the owner normal
network access to SSH, AdGuard's UI, Beszel, Home Assistant, Immich, and Samba
without publishing those services.

Before enabling `homelab.wireguard`:

1. Generate a server private key and one keypair per client.
2. Store the server key as `/run/secrets/wireguard-private-key` using sops-nix.
3. Declare peers in the host config; peer public keys are not secrets.
4. Add a DNS-only `vpn.<domain>` record or DDNS updater for the public IP.
5. Forward UDP 51820 only to the server.
6. Enable WireGuard and test SSH over `10.100.0.1` before relying on it away
   from home.

WireGuard initially reaches the server itself, which is enough for nearly full
administrative control. Routing the rest of the home LAN through it can be added
later once the LAN subnet and server interface name are known.

The server firewall admits private services only from RFC 1918 IPv4 sources,
which includes the default WireGuard subnet without publishing the home's exact
LAN. IPv6 is disabled on this host for now; enable it only alongside an explicit
IPv6 firewall review and an external exposure test.

Before deployment, verify that the router's WAN address matches the public
address seen externally; a mismatch would indicate another NAT layer.
