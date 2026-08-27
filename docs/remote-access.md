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

## Public administration path

The administration endpoint is ordinary OpenSSH, so Windows, WSL, macOS, and
Linux can use their existing `ssh` command. There is no VPN agent, account, or
background client. A device still needs the administrator's private key; a
username or server password is never sufficient.

The declarative policy layers the following controls:

- only the declared administrator username is accepted;
- only public-key authentication is accepted; root, password, keyboard-
  interactive, empty-password, X11, agent-forwarding, remote-forwarding, and
  tunnel-device paths are disabled;
- local TCP forwarding remains available for private web dashboards;
- each connection gets at most three authentication attempts and each source
  gets at most three concurrent unauthenticated connections;
- Fail2ban blocks an Internet source after five logged failures in ten minutes.
  The first ban is one hour and repeat bans grow to at most one week;
- private IPv4 ranges are exempt from Fail2ban so a mistake on the home LAN
  cannot remove the local recovery path;
- `sudo` requires the local account password, which sshd does not accept.

Changing TCP 22 to an unusual port can reduce log noise but does not add an
authentication boundary, so this setup keeps the standard port and ordinary SSH
commands. Some guest networks block outbound SSH; use a trusted mobile hotspot
instead of weakening the endpoint to work around that policy.

Before merging or deploying this policy, verify both credentials while still on
the LAN:

```bash
ssh -o PreferredAuthentications=publickey joshcaz@homeserver
sudo -k
sudo true
```

The first command must use the intended private key, and the last command must
accept the local account password. Put a passphrase on the private key before
publishing SSH if it does not already have one:

```bash
ssh-keygen -p -f ~/.ssh/id_ed25519
```

Changing a key's passphrase does not change its public key. Store an encrypted
backup of the private key away from the server; never commit or copy the private
key into this repository. `ssh-agent` can cache the unlocked key for the current
login session without removing its at-rest encryption.

The managed WSL SSH profile keeps the two network paths explicit: `ssh homeserver`
uses the LAN resolver, while `ssh homeserver-remote` uses the public
`ssh.joshcaz.com` endpoint. The public alias is for testing from a different
network; it is not expected to resolve from the home LAN.

After deploying:

1. Confirm `ssh.joshcaz.com` is a **DNS-only** A record and resolves to the same
   IPv4 address as `curl -4fsS https://api.ipify.org` on the server.
2. In the router, forward external TCP 22 to TCP 22 on the server's reserved
   LAN address. Do not use DMZ, a port range, or UPnP.
3. Keep an existing LAN SSH session open during the first test.
4. Disconnect the laptop from home Wi-Fi, use a phone hotspot, and run
   `ssh joshcaz@ssh.joshcaz.com`.
5. Confirm the protections on the server:

   ```bash
   systemctl is-active sshd fail2ban
   sudo fail2ban-client status sshd
   sudo ss -ltnp | rg ':22\\b'
   ```

If a trusted external address is accidentally banned, recover from the LAN and
run `sudo fail2ban-client set sshd unbanip ADDRESS`. Do not permanently exempt a
mobile or residential public address because it can later belong to someone
else.

Private dashboards remain private. Reach them through the same SSH connection
without installing a VPN client:

```bash
ssh \
  -L 3000:127.0.0.1:3000 \
  -L 3001:127.0.0.1:3001 \
  -L 8096:127.0.0.1:8096 \
  -L 9093:127.0.0.1:9093 \
  -L 9095:127.0.0.1:9095 \
  joshcaz@ssh.joshcaz.com
```

While that session is open, the remote laptop can browse AdGuard at
`http://127.0.0.1:3000`, Grafana at `http://127.0.0.1:3001`, Jellyfin's local
endpoint at `http://127.0.0.1:8096`, Alertmanager at `http://127.0.0.1:9093`,
and Prometheus at `http://127.0.0.1:9095`. Do not forward Samba, AdGuard DNS,
or arbitrary administration ports through the router.

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
