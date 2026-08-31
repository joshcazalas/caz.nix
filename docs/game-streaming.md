# Private game streaming

This setup keeps the Windows path small and puts remote-access policy on the
NixOS gateway:

```text
Remote Moonlight client
        │
        │ WireGuard (one encrypted client-to-site tunnel)
        ▼
NixOS gateway
        │
        │ exact Sunshine ports, source NAT, ordinary home LAN
        ▼
Sunshine host at its reserved LAN address
```

The Sunshine host does not run WireGuard. While home, connect directly to its
LAN address with the client tunnel off. While away, enable the client tunnel;
that same host `/32` is routed through the gateway.

The separate `wg-game` interface is not an administrative VPN. An authenticated
client can reach only the Sunshine host at `192.168.1.127`, only on TCP `47984`,
`47989`, and `48010` and UDP `47998-48000`, `48002`, and `48010`. Gateway-local
traffic, other LAN destinations, other clients, and every other host port are
denied. A future `wg-home` interface should remain a different trust plane.

## What owns each part

| Owner | State |
| --- | --- |
| NixOS | WireGuard listener, encrypted client peers, DDNS, forwarding, NAT, and isolation |
| Windows host | Sunshine package, service, localhost-only Web UI, UPnP off, and private-LAN firewall |
| Windows client | Moonlight and WireGuard packages plus one WireGuard-owned tunnel |
| WSL | Thin launcher for native Windows PowerShell and WinGet |
| Operator | Router forward, DHCP reservation, peer admission, Sunshine credentials, and Moonlight pairing |

The repository never needs Windows Git, Windows SSH keys, a Windows checkout,
or a custom DSC resource. A stale handshake, sleeping host, or untested display
is an observation rather than configuration drift.

## Windows baseline

Run the focused host role from the host's WSL checkout:

```bash
cd ~/develop/caz.nix
./bootstrap/windows.sh game-stream-host
./bootstrap/windows.sh game-stream-host --check
```

It uses ordinary WinGet to install Sunshine when absent, then applies the stable
host policy directly in one elevated PowerShell process. It does not install or
configure WireGuard on the host. Create Sunshine's local Web UI credentials at
`https://localhost:47990` and keep the Windows network marked `Private`.

On every Windows client, run:

```bash
./bootstrap/windows.sh game-stream-client
./bootstrap/windows.sh game-stream-client --check
```

That installs Moonlight and WireGuard and clears rules left by the retired
custom implementation. It deliberately does not maintain a client firewall
policy, generate a key, import a tunnel, or decide which peer the gateway
should authorize.

Both commands stage only one PowerShell file under `%LOCALAPPDATA%` for the UAC
boundary and remove it afterward. `--check` validates stable package and policy
state. Tunnel presence and handshake state are printed as observations.

## Migrate the existing deployment

The merged pre-migration setup already created durable gateway and client keys.
Reuse them instead of rotating identities.

Before leaving physical access to the host, confirm that `192.168.1.127` is
still reserved for it, its active Windows network is `Private`, Sunshine is
running and already paired, and plugged-in sleep is disabled for the pilot.
Power and login readiness remain explicit operating choices rather than
configuration drift.

1. Before removing the old host tunnel, record its public key transiently from
   the Sunshine host:

   ```bash
   powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
     '& "$env:ProgramFiles\WireGuard\wg.exe" show game-stream public-key'
   ```

   This value is not secret. Use it only to identify the old peer; do not add a
   device or location mapping to the repository.

2. On the SOPS-capable administrator laptop, open the encrypted server value:

   ```bash
   cd ~/develop/caz.nix
   nix develop
   export SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519"
   sops secrets/homeserver.yaml
   ```

3. Inside `gameStreamGatewayConfig`, keep the `[Interface]` block. Remove the
   `[Peer]` block whose `PublicKey` matches the value from step 1. Keep every
   client peer unchanged. The resulting document has this shape:

   ```ini
   [Interface]
   Address = EXISTING_GATEWAY_TUNNEL_IPV4/32
   PrivateKey = EXISTING_GATEWAY_PRIVATE_KEY
   ListenPort = 51820

   [Peer]
   PublicKey = EXISTING_CLIENT_PUBLIC_KEY
   AllowedIPs = EXISTING_CLIENT_TUNNEL_IPV4/32
   ```

   Do not add comments that map public keys to physical devices or locations.

4. Commit the changed SOPS ciphertext with this code, publish the normal
   immutable release, and deploy it to the server. The router's existing UDP
   `51820` forward and DNS-only `game-vpn` record remain unchanged.

5. On the existing laptop, open the `game-stream` tunnel in the official
   WireGuard app. Change only its peer route:

   ```ini
   AllowedIPs = 192.168.1.127/32
   ```

   Keep its interface address, private key, gateway public key, endpoint, and
   `PersistentKeepalive = 25`. Save it inactive while still on the home network;
   the public endpoint is not expected to resolve through the current internal
   DNS path.

6. Leave the old host tunnel and WireGuard installation in place for the first
   remote pilot. The new gateway configuration no longer authorizes that peer,
   and its presence does not interfere with source-NATed traffic to the host LAN
   address. Keeping it temporarily preserves the option to roll back the server
   generation and old topology if the pilot exposes a problem.

7. Put the laptop on a phone hotspot, activate its tunnel, and connect Moonlight
   to `192.168.1.127`. The existing Sunshine pairing remains valid because the
   Sunshine host itself did not change.

8. After the remote pilot succeeds and the Sunshine host is physically
   accessible again, apply the new focused host baseline. Then open WireGuard,
   deactivate the old `game-stream` host tunnel, and delete that tunnel. This
   host has no remaining WireGuard role, so uninstall its package from WSL:

   ```bash
   powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
     'winget.exe uninstall --id WireGuard.WireGuard --exact --source winget --silent --accept-source-agreements --disable-interactivity'
   ```

   Keep this as an explicit migration action: the reusable host baseline must
   not silently uninstall WireGuard from a future machine that uses it for an
   unrelated purpose.

The migration intentionally accepts a short remote-streaming interruption
between the server deploy and the client route edit. It does not attempt an
automatic rollback or dual-topology compatibility layer.

## Add a fresh client

This is a rare admission ceremony, so v1 uses the official WireGuard editor
instead of a custom enrollment protocol.

1. Apply the Windows client baseline.
2. In WireGuard, choose **Add empty tunnel** and name it `game-stream`. WireGuard
   generates and retains the client private key on Windows.
3. Review the encrypted server document and select an unused exact client `/32`.
4. Add the client's public key and address to `gameStreamGatewayConfig`:

   ```ini
   [Peer]
   PublicKey = CLIENT_PUBLIC_KEY
   AllowedIPs = CLIENT_TUNNEL_IPV4/32
   ```

5. Configure the client tunnel:

   ```ini
   [Interface]
   PrivateKey = CLIENT_PRIVATE_KEY_GENERATED_BY_WIREGUARD
   Address = CLIENT_TUNNEL_IPV4/32

   [Peer]
   PublicKey = GATEWAY_PUBLIC_KEY
   AllowedIPs = 192.168.1.127/32
   Endpoint = game-vpn.joshcaz.com:51820
   PersistentKeepalive = 25
   ```

6. Commit and deploy the encrypted server change, activate the tunnel off-LAN,
   and pair Moonlight with `192.168.1.127` if that client is not already paired.

An existing client tunnel shows the gateway public key. On the SOPS-capable
machine it can also be derived without printing the gateway private key:

```bash
sops --decrypt --extract '["gameStreamGatewayConfig"]' secrets/homeserver.yaml |
  awk -F '[[:space:]]*=[[:space:]]*' '$1 == "PrivateKey" { print $2; exit }' |
  wg pubkey
```

Public keys and private tunnel addresses are not cryptographic secrets, but the
server document remains SOPS-encrypted to avoid publishing stable topology
metadata. Private keys must never be copied into Git or passed as command-line
arguments.

## Status and recovery

The server uses standard tools:

```bash
sudo systemctl status wg-quick-wg-game.service
sudo wg show wg-game
```

The client can be inspected from WSL without installing Linux PowerShell:

```bash
powershell.exe -NoLogo -NoProfile -Command \
  '& "$env:ProgramFiles\WireGuard\wg.exe" show game-stream'
```

Recovery stays explicit:

- package missing: rerun the relevant `bootstrap/windows.sh` role;
- host policy changed: rerun the host role;
- tunnel malformed: inspect it in WireGuard, then remove and re-import it;
- client key lost: remove that public-key peer from SOPS and create a new one;
- bad gateway deployment: roll back the NixOS generation.

The setup never stops the WireGuard manager, deletes DPAPI configuration behind
its back, silently rotates keys, or reconstructs a partially imported tunnel.

## Pilot acceptance

Pair and prove Sunshine directly on the LAN first. Then test from an actual
external network:

1. Confirm a recent WireGuard handshake.
2. Connect Moonlight to `192.168.1.127` and prove video, audio, input, controller,
   resolution, and game launch.
3. Confirm a non-Sunshine host port is blocked, for example:

   ```bash
   powershell.exe -NoLogo -NoProfile -Command \
     'Test-NetConnection 192.168.1.127 -Port 3389'
   ```

4. Stream at the intended resolution, frame rate, and bitrate for at least
   fifteen minutes. Use Moonlight statistics (`Ctrl+Alt+Shift+S` on PC) to
   compare direct-LAN and remote performance.
5. Record display/EDID, power, reboot, Windows login-screen, shared-console, and
   simultaneous local/remote behavior as pilot evidence—not declarative state.

Keep home/away switching manual until repetition proves that automating it is
worth another moving part. Wake-on-LAN, virtual service addresses, scheduled key
rotation, and the future `wg-home` policy are separate projects.
