# Remote access and public Jellyfin

Use separate trust paths rather than treating every person, device, and web app
the same. Public services remain public by deliberate exception; private
household access uses role-filtered WireGuard. Remote administration uses SSH
through `wg-home`; trusted LAN SSH and the local console provide recovery paths.
External VPN SSH was verified after removing the router's TCP 22 forward.

## Private household access

`homelab.homeAccessGateway` defines a second client-to-site WireGuard interface,
`wg-home`. It is separate from the low-trust `wg-game` tunnel: joining one never
grants access to the other. Each peer receives one exact `/32` address and is
assigned to one of two deliberately small roles:

- `administrator` devices may reach only the listed homeserver services and
  listed LAN targets;
- `resident` devices may reach only their own, usually smaller, service list;
- neither role receives arbitrary LAN access, peer-to-peer access, or an
  Internet default route.

The initial deployment keeps each peer pseudonymous and grants only the service
set required by its role. A peer does not need a tunnel identity merely because
an authorized client may reach a selected service on it later. The policy in
`hosts/homeserver/default.nix`:

```nix
homelab.homeAccessGateway = {
  enable = true;
  address = "10.77.1.1/24";
  listenPort = 51821;

  administrator = {
    peers = [
      {
        address = "10.77.1.2";
        publicKey = "ADMIN_CLIENT_PUBLIC_KEY";
      }
    ];
    gatewayTCPPorts = [
      22
      53
      8123
    ];
    gatewayUDPPorts = [ 53 ];
  };

  resident = {
    peers = [
      {
        address = "10.77.1.3";
        publicKey = "APPLICATION_CLIENT_PUBLIC_KEY";
      }
    ];
    gatewayTCPPorts = [
      53
      8123
    ];
    gatewayUDPPorts = [ 53 ];
  };
};
```

The administrator role may reach SSH, DNS, and Home Assistant on the gateway.
The resident role may reach only DNS and Home Assistant. Neither peer may reach
an arbitrary LAN address or the other peer, and the gaming tunnel inherits none
of these grants.

Only the gateway's bare private key belongs in the encrypted
`homeAccessGatewayPrivateKey` value. Peer public keys are not secrets. The
module generates the server's peer configuration from each role declaration,
so the same peer object owns identity, its exact `/32` cryptokey route, and its
firewall grants. A peer cannot accidentally receive a subnet-wide server
`AllowedIPs` entry through a second configuration source.

Create each tunnel directly in the official client so that client generates and
retains `CLIENT_PRIVATE_KEY`; never put it in this repository or SOPS. An
administrator client uses:

```ini
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY
Address = 10.77.1.2/32
DNS = 10.77.1.1

[Peer]
PublicKey = GATEWAY_PUBLIC_KEY
AllowedIPs = 10.77.1.1/32
Endpoint = home-vpn.joshcaz.com:51821
PersistentKeepalive = 25
```

A resident application client uses a separate identity:

```ini
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY
Address = 10.77.1.3/32
DNS = 10.77.1.1

[Peer]
PublicKey = GATEWAY_PUBLIC_KEY
AllowedIPs = 10.77.1.1/32
Endpoint = home-vpn.joshcaz.com:51821
PersistentKeepalive = 25
```

Keep `AllowedIPs` to the exact destinations granted by that peer's role; do not
use `0.0.0.0/0` or the whole home subnet. The firewall is the authorization
boundary, but narrow client routes prevent accidental traffic capture and make
the intended scope visible on the device.

Mobile clients should activate the tunnel on demand away from the trusted LAN.
When the tunnel is active, `http://10.77.1.1:8123` reaches Home Assistant and
`ssh homeserver-vpn` reaches the administrative endpoint. The managed WSL SSH
profile keeps the LAN alias separate from the remote WireGuard aliases. Consult
the client platform's private enrollment notes rather than publishing device
inventory in this repository.

Activation is intentionally ordered:

1. Generate each tunnel in the official WireGuard client so its private key
   never leaves that device. Record only its public key.
2. Store only the gateway private key in SOPS. Add each device's public key and
   address to exactly one declarative role in Nix.
3. Deploy, then forward only router UDP 51821 to the homeserver and create the
   DNS-only `home-vpn` record through the existing DDNS configuration.
4. Test every role from a genuinely external network: Home Assistant, allowed
   administrator SSH, blocked resident SSH, blocked LAN targets, and peer
   isolation.
5. Only after repeated external tests, remove the router's TCP 22 forward and
   set `settings.public.ssh = false`. LAN SSH remains available to trusted LAN
   clients; the gaming host is explicitly excluded from it.

The TCP 22 forward has now been removed and a fresh external VPN SSH login
succeeded. The repository disables public SSH and retains UDP 51821 for
`wg-home`. Deploy the server configuration to apply the host firewall and key
changes; apply Home Manager on the laptop to move `homeserver-remote` to the
VPN address. `homeserver-vpn` already uses that address. Disabling public SSH
also stops DDNS updates for `ssh.joshcaz.com`; any existing DNS record is not
automatically deleted and does not grant access.

Removing one declarative peer object revokes one device without rotating
everyone else. A stolen resident device therefore exposes only that resident
role, not SSH, the gaming host, or other peers. A flat LAN still cannot
cryptographically stop a compromised machine from spoofing another LAN source
address, so VLAN isolation remains an optional future hardening layer rather
than a prerequisite for this design.

## Dynamic DNS

`homelab.cloudflareDdns` uses NixOS's packaged `favonia/cloudflare-ddns`
service. It checks the public IPv4 address through Cloudflare every five
minutes and reconciles only the explicitly configured DNS records. IPv6
updates are disabled alongside host IPv6, records are never deleted when the
service stops, and the updater has no inbound listener.

`homelab.cloudflareDdns.allowedZones` permits records at the apex or under
`joshcaz.com` and `joshcazalas.com`. Only the names listed in `domains` are
managed; this includes the website apex even while public serving is disabled.

Create a Cloudflare API token with exactly:

- permission `Zone` / `DNS` / `Edit`;
- zone resources `Include` / `Specific zone` for both `joshcaz.com` and
  `joshcazalas.com`;
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

Keep game, VPN, SSH, and media records in **DNS-only** (gray-cloud) mode.
The website apex can use Cloudflare's proxy. The updater preserves an existing
record's proxy setting, while `proxied = false` is the fallback for records it
creates. Managed names must use A records, not CNAME aliases.

Operate and verify it with:

```bash
systemctl status cloudflare-ddns.service --no-pager
journalctl -u cloudflare-ddns.service -n 100 --no-pager
dig @1.1.1.1 +short mc.joshcaz.com A
curl -4fsS https://api.ipify.org; echo
```

The two addresses should match for the DNS-only Minecraft record. For a proxied
website record, public DNS returns Cloudflare addresses; check its origin IPv4
in the Cloudflare dashboard against the home's public address instead.
Cloudflare may also return its own IPv6 addresses for a proxied record without
enabling IPv6 on the homeserver. Revoking the scoped token stops future DNS
updates but grants no shell, Cloudflare account, or non-DNS access.

## Public media path

1. Choose the domain and set it in `settings.nix`.
2. Add `jellyfin.<domain>` in Cloudflare DNS as a **DNS-only** A record. Do not
   add an AAAA record while IPv6 remains disabled on the server.
3. The host configuration includes this name in Cloudflare DDNS automatically
   when `settings.public.jellyfin` is enabled.
4. Forward router TCP 80 and 443 to the server's reserved LAN address.
5. In Jellyfin's dashboard, add `127.0.0.1` under `Networking > Known proxies`
   so its authorization decisions and security log contain the real client IP.
6. Give every person a separate strong password and non-admin account. Restrict
   each account to the intended libraries and capabilities. Keep the admin
   account hidden and disallow its remote connections; use an SSH local forward
   for remote administration instead.
7. Set `settings.public.jellyfin = true`, evaluate, and deploy. Caddy will obtain
   and renew HTTPS certificates and proxy only to Jellyfin on port 8096.
8. Confirm `sudo fail2ban-client status jellyfin` reports the active jail.
9. Test from cellular data, not from home Wi-Fi, including a native client.

Do not forward Jellyfin's port 8096. Do not put Cloudflare Access in front of
Jellyfin: its browser login can work, but native clients expect the Jellyfin API
and authentication flow. The Caddy endpoint deliberately keeps request access
logging off because Jellyfin can place API keys in URLs. Fail2ban instead reads
Jellyfin's authentication log and blocks an address on TCP 80/443 after five
failures in ten minutes. Its first ban lasts one hour and repeat bans grow.

Cloudflare Tunnel remains an option later for small browser-only applications,
but not for the video stream itself. Cloudflare documents that Tunnel-published
traffic passes through its network, and its current delivery policy restricts
using ordinary CDN service for disproportionate video or large-file delivery:

- <https://developers.cloudflare.com/tunnel/>
- <https://developers.cloudflare.com/fundamentals/reference/policies-compliances/delivering-videos-with-cloudflare/>

## Administration over WireGuard

Away from home, activate the administrator's `wg-home` tunnel and connect with
`ssh homeserver-vpn`. WireGuard controls network access, and OpenSSH still
requires the administrator's authorized SSH key. At home, `ssh homeserver`
continues to use the trusted LAN path.

The declarative policy layers the following controls:

- only the declared administrator username is accepted;
- only public-key authentication is accepted; root, password, keyboard-
  interactive, empty-password, X11, agent-forwarding, remote-forwarding, and
  tunnel-device paths are disabled;
- local TCP forwarding remains available for private web dashboards;
- each connection gets at most three authentication attempts and each source
  gets at most three concurrent unauthenticated connections;
- `sudo` requires the local account password, which sshd does not accept.

Fail2ban is disabled while both public SSH and public Jellyfin are disabled.
Enabling public Jellyfin enables its jail without enabling the SSH jail. If
public SSH is explicitly enabled again, its jail blocks a source after five
failures in ten minutes, starting with a one-hour ban and increasing to one
week. Private IPv4 ranges remain exempt.

Verify both the SSH key and the separate sudo password through the VPN:

```bash
ssh homeserver-vpn
sudo -k
sudo true
```

The first command must use the intended private key, and the last command must
accept the local account password. Keep a passphrase on the SSH private key:

```bash
ssh-keygen -p -f ~/.ssh/id_ed25519
```

Changing a key's passphrase does not change its public key. Store an encrypted
backup of the private key away from the server; never commit or copy the private
key into this repository. `ssh-agent` can cache the unlocked key for the current
login session without removing its at-rest encryption.

The managed WSL SSH profile uses the LAN resolver for `ssh homeserver`.
Both `ssh homeserver-vpn` and `ssh homeserver-remote` use `10.77.1.1` while
public SSH is disabled. Server aliases require the key's passphrase for each
new connection rather than using the agent. Only the current administrator
laptop's SSH public key is declared in `settings.nix`.

After deploying:

1. Keep an existing VPN SSH session open and confirm a fresh
   `ssh homeserver-vpn` connection succeeds from outside home.
2. Confirm the router still forwards UDP 51821 to the server's reserved LAN
   address and has no TCP 22 forward.
3. Confirm the services and authorized public-key fingerprints on the server:

   ```bash
   systemctl is-active sshd wg-quick-wg-home
   systemctl is-active fail2ban # expected: inactive with public SSH/Jellyfin off
   ssh-keygen -lf /etc/ssh/authorized_keys.d/joshcaz
   ```

If WireGuard fails while away, use trusted LAN SSH or the local console when
home. The public SSH endpoint is no longer a recovery path.

Private dashboards remain private. Reach them through the same SSH connection
with `wg-home` active:

```bash
ssh \
  -L 3000:127.0.0.1:3000 \
  -L 3001:127.0.0.1:3001 \
  -L 8096:127.0.0.1:8096 \
  -L 8123:127.0.0.1:8123 \
  -L 9093:127.0.0.1:9093 \
  -L 9095:127.0.0.1:9095 \
  homeserver-vpn
```

While that session is open, the remote laptop can browse AdGuard at
`http://127.0.0.1:3000`, Grafana at `http://127.0.0.1:3001`, Jellyfin's local
endpoint at `http://127.0.0.1:8096`, Home Assistant at
`http://127.0.0.1:8123`, Alertmanager at `http://127.0.0.1:9093`, and
Prometheus at `http://127.0.0.1:9095`. Do not forward Samba, AdGuard DNS, Home
Assistant, or arbitrary administration ports through the router.

Grafana, Prometheus, and Alertmanager bind to loopback only, so this tunnel is
the sole path to them from anywhere, including the LAN. That is deliberate: an
observability stack knows the shape of every service on the host, and a
dashboard is not worth a new listening port.

IPv6 is disabled on this host for now. Enable it only alongside an explicit
IPv6 firewall review and external test. Before forwarding any port, also verify
that the router's WAN address matches the address seen externally; a mismatch
would indicate another NAT layer.

## Primary references

- OpenSSH server controls: <https://man.openbsd.org/sshd_config>
- NixOS Fail2ban module: <https://wiki.nixos.org/wiki/Fail2ban>
- Jellyfin reverse proxy guidance:
  <https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/>
- Jellyfin Fail2ban filter and rotation guidance:
  <https://jellyfin.org/docs/general/post-install/networking/advanced/fail2ban/>
