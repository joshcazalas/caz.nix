# Remote access and public Jellyfin

Use two different trust paths rather than treating every web app the same.

## Public media path

1. Choose the domain and set it in `settings.nix`.
2. Add `jellyfin.<domain>` in Cloudflare DNS as a **DNS-only** A record. Do not
   add an AAAA record while IPv6 remains disabled on the server.
3. If the public address changes, add a Cloudflare DNS updater later using a
   narrowly scoped API token stored with sops-nix.
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
