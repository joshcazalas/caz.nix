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
denied. The role-filtered `wg-home` module remains a different trust plane and
does not inherit `wg-game` peers.

## What owns each part

| Owner | State |
| --- | --- |
| NixOS | WireGuard listener, encrypted client peers, DDNS, forwarding, NAT, isolation, and the Ethernet neighbor entry for waking |
| Windows host | Sunshine package, service, virtual-display selection and modes, localhost-only Web UI, UPnP off, and private-LAN firewall |
| Windows client | Moonlight and WireGuard packages plus one WireGuard-owned tunnel |
| WSL | Thin launcher for native Windows PowerShell and WinGet |
| Operator | Router forward, Ethernet DHCP reservation, peer admission, signed display-driver installation, hardware wake settings, Sunshine credentials, and Moonlight pairing |

The repository never needs Windows Git, a Windows checkout, or a custom DSC
resource. The WSL checkout may use anonymous HTTPS and therefore does not need a
GitHub or homeserver SSH credential. A stale handshake, sleeping host, or
untested display is an observation rather than configuration drift.

## Retire administration credentials from the host

The Sunshine host is intentionally a low-trust entertainment endpoint. Among
private homeserver services, its reserved LAN address is restricted at the
firewall to TCP/UDP DNS 53; it no longer inherits SSH, Samba, Home Assistant, or
other private services from being on the home LAN. Deliberately public services
remain reachable just as they are from an Internet client. That source-address
rule is useful containment, not a substitute for removing credentials: a valid
GitHub write credential could still publish a release, and some routers may
hairpin the public SSH endpoint.

Keep WSL and the focused declarative role. They are not the privilege boundary.
The public repository can be cloned and updated without an account:

```bash
git remote set-url origin https://github.com/joshcazalas/caz.nix.git
git pull --ff-only
./bootstrap/windows.sh game-stream-host
./bootstrap/windows.sh game-stream-host --check
```

Do not use the bootstrap's optional `--ssh-clone` path on this host. Before
removing anything, identify the host's exact key rather than guessing from key
order or age:

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub
git remote -v
ssh-add -l
gh auth status
```

Then perform the credential retirement as one reviewed change:

1. Remove the matching public key from the homeserver account's
   `authorizedKeys` in `settings.nix` and deploy that release.
2. If the same key is registered with GitHub, delete that one GitHub SSH key.
   Do not remove keys belonging to administrator devices.
3. Change the checkout to HTTPS, clear the agent with `ssh-add -D`, and sign out
   any cached GitHub CLI session with `gh auth logout --hostname github.com`.
4. Run `aws sso logout` as defense in depth. Declarative AWS SSO profile names
   are not credentials, and an account that has never logged in has no SSO
   session to steal.
5. Confirm the public checkout still pulls and both declarative host commands
   still pass. Confirm `ssh homeserver` and `ssh homeserver-remote` fail from the
   gaming host before deleting its local private/public key files.

A passphrase protects a private-key file at rest, but an unlocked `ssh-agent`
can use it without asking for that passphrase again. The shared WSL profile may
cache a key for up to twelve hours, which is why this host should not retain a
reusable administrator/GitHub key even though every key is passphrase
protected. There is no need to split or erase the Home Manager profile once the
actual credentials and cached sessions are absent.

## Windows baseline

Install the signed [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
on the **gaming host**, with its physical TV on for initial setup:

```powershell
winget install --id VirtualDrivers.Virtual-Display-Driver --exact --source winget
```

Open **VDD Control**, install its **display** driver, and confirm Windows Display
Settings shows one additional monitor. The current WinGet package installs the
control app; it does not itself install the display device. Keep the adapter
enabled. Do not install this driver on the Moonlight laptops.

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

The host role verifies the real display adapter, adds 720p/800p/1080p/1200p/
1440p/1600p modes at 30 and 60 Hz while preserving other driver settings, and
selects the virtual monitor using its machine-specific Sunshine `device_id`.
Sunshine activates that monitor and makes it primary during streaming, then
restores the previous layout when the last client disconnects. The TV may
remain a secondary display; this is still the same Windows console session.
The host role never silently falls back to capturing the TV.

In Moonlight, enable **Optimize game settings** to let Sunshine match the virtual
display's resolution to the client. Sunshine also matches the requested frame
rate when the display supports it. The driver and Sunshine configuration files
get a one-time local `.before-headless` backup. The bootstrap uses Sunshine's
native display management, not preparation commands or a background monitor
switching task.

If selection fails, inspect **Troubleshooting** in Sunshine for its latest
display list. The driver must appear there exactly once. A disabled display in
Windows Display Settings is acceptable; a disabled driver in Device Manager is
not. To undo display selection, clear **Display ID** and disable display-device
configuration in Sunshine, save/restart, then disable or uninstall VDD locally.
Before major GPU/chipset-driver updates, follow the VDD project's guidance to
uninstall VDD, update the GPU driver, reinstall VDD, and rerun the host role.

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

## Wake from sleep

Turning off the TV does not require sleeping the PC. The virtual display keeps
capture independent of the TV; waking the computer itself requires hardware
support and a separate acceptance test.

The gateway's `wakeOnLan` configuration pins the host's Ethernet MAC to its
reserved IP on the homeserver's physical LAN interface. Moonlight sends its
magic packet on Sunshine's existing UDP ports, so both clients can use
**Wake PC** through their existing game tunnel. The permanent neighbor entry
lets those packets reach the NIC even after the PC stops answering ARP during
sleep. No UDP 9 forward, new server listener, or broader VPN access is needed.
Keep this MAC, the Ethernet DHCP reservation, and the physical interface in
`hosts/homeserver/default.nix` synchronized if hardware changes.

On the gaming PC:

1. Check `powercfg /a` for supported sleep states.
2. Enable Wake-on-LAN/PCIe wake in the motherboard's BIOS/UEFI if needed.
3. For the wired NIC in Device Manager, enable **Wake on Magic Packet** and
   **Allow this device to wake the computer**. Prefer magic-packet-only wake
   over waking on arbitrary traffic. Options depend on the NIC and sleep model.
4. Connect Moonlight once while the PC is awake on Ethernet so each client learns
   the current Ethernet MAC. Existing Wi-Fi pairing does not prove it has the
   right wake address.
5. With the TV off, sleep the PC and use Moonlight's **Wake PC**. Repeat through
   WireGuard from an external network, then after extended idle. A successful
   wake must lead to usable video and input.

The integration test proves magic-packet delivery when the target refuses ARP;
it cannot emulate a physical NIC waking the Windows PC. Keep automatic PC sleep
disabled until the real sleep/wake test passes. Windows shutdown, hibernation,
Modern Standby, and ordinary sleep can have different wake support; do not
infer shutdown support from a successful sleep test.

References: [Moonlight wake implementation](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/backend/nvcomputer.cpp),
[Moonlight wake guide](https://github.com/moonlight-stream/moonlight-docs/wiki/WOL-%28Wake-On-LAN%29),
and [Windows power states](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states).

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
5. With the TV off, prove a new Desktop stream, disconnect/reconnect, idle, and
   a reboot to the Windows login screen. Confirm image and input rather than
   relying only on Moonlight's frame-rate overlay. Repeat through the VPN.
6. Prove sleep/wake with the TV off using the steps above before enabling
   unattended PC sleep. Record shared-console and simultaneous local/remote
   behavior as pilot evidence.

Keep home/away switching manual until repetition proves that automating it is
worth another moving part. Virtual service addresses, scheduled key rotation,
and adding further `wg-home` forwarding targets remain separate projects.
