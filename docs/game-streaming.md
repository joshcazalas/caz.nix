# Declarative private game streaming

The repository defines three reusable roles without assigning them to a
physical device:

- `game-stream-gateway`: a disabled-by-default NixOS WireGuard hub;
- `game-stream-host`: Sunshine, WireGuard, and narrow host security policy;
- `game-stream-client`: Moonlight, WireGuard, and narrow client routing policy.

One host can serve multiple independently enrolled clients. Each Windows
device generates and retains its own WireGuard private key. Adding or revoking
a client updates the encrypted gateway peer list without replacing the host
tunnel.

Applying one of these roles is always explicit. Merely evaluating the flake or
checking out this repository does not run WinGet, install software, create an
account, open a port, generate a key, or enroll a peer.

The host and client lifecycles are intentionally staged. The `Lan` stage
installs and secures Sunshine on the host and installs Moonlight on each client
without requiring WireGuard enrollment. The `Remote` stage is enabled only
after that pilot and requires the independent tunnel enrollment described
below.

The declarative layer does not prove that a route is playable. Issue #63's
local, external, negative-access, performance, headless-display, session, and
revocation tests remain required before treating the pilot as complete.

## Network and trust model

The two supported streaming paths are deliberately separate:

| Source | Destination | Policy |
| --- | --- | --- |
| Home device | Host's ordinary LAN IPv4 address | Sunshine only, from the Windows `Private` local subnet |
| Enrolled remote device | Host's tunnel `/32` through the gateway | Sunshine only, from that client's exact WireGuard `/32` |
| Game-stream tunnel | Gateway, host LAN address, another client, or another LAN device | Denied |

Direct LAN is the preferred path while both devices are home. It avoids an
unnecessary gateway hop and supports Moonlight discovery. The WireGuard path
is the remote path and can also be tested from home when the router supports
hairpin NAT or the endpoint resolves privately.

The client tunnel is split: it routes only the host tunnel `/32`. It does not
install a default route, DNS setting, LAN route, or command hook. The host
tunnel routes one reserved client-role `/28`; the gateway is the trusted
mediator that admits only individually enrolled client `/32` sources from that
subnet.

The gateway treats `wg-game` as untrusted before the repository's broader
RFC1918 policy. A persistent guard remains fail closed while the exact role
policy is absent, stopped, interrupted, or rebuilt. It permits each client to
reach only the host's TCP `47984`, `47989`, and `48010` and UDP `47998-48000`,
`48002`, and `48010`; the host can return only established traffic.

This game tunnel does not provide SSH or general home-network access. A future
WireGuard replacement for public SSH should be a separate administrative role
with different peers and policy.

That separation is intentional, not an unfinished general VPN. WireGuard
authenticates device keys and binds them to tunnel addresses, but does not
distribute configuration or authorize users to individual services. Putting a
future TV, handheld, or other streaming client on the same security plane as
homeserver administration would therefore make every firewall change harder to
review and increase the effect of a compromised client.

The maintainable long-term shape is two small interfaces rather than one policy
framework:

- `wg-game` admits only enrolled streaming devices and only Sunshine traffic;
- a future `wg-home` admits separately enrolled administrator devices to
  explicitly selected homeserver services; and
- later device-to-device access is added as narrow grants, never a blanket
  any-to-any home subnet.

After the administrative tunnel has passed an off-LAN test and a LAN recovery
path is documented, public TCP 22 and its SSH Fail2ban jail can be retired.
Intentionally public services such as Minecraft or the read-only map are a
separate publishing decision and do not become VPN-only automatically. This
keeps the current project small while avoiding a migration or trust-boundary
mistake later.

## Private input boundary

Never commit plaintext addresses, endpoints, keys, peer mappings, account
names, device names, request files, or response files. The gateway's complete
configuration and opaque allocation state live together in the single SOPS
value `gameStreamGatewayConfig` in `secrets/homeserver.yaml`. Its ciphertext is
safe to commit; its plaintext is not.

The decrypted runtime document is an ordinary `wg-quick` configuration in this
fixed order:

```ini
[Interface]
Address = GATEWAY_TUNNEL_IPV4/32
PrivateKey = GATEWAY_PRIVATE_KEY
ListenPort = 51820

# First peer is always the host.
[Peer]
PublicKey = HOST_PUBLIC_KEY
AllowedIPs = HOST_TUNNEL_IPV4/32

# Every remaining peer is an independent client.
[Peer]
PublicKey = CLIENT_PUBLIC_KEY
AllowedIPs = CLIENT_TUNNEL_IPV4/32
```

The runtime validator requires one gateway `/32`, one host peer, zero or more
client peers, distinct keys, and distinct exact peer `/32` routes. It rejects
`SaveConfig`, DNS/table changes, unsupported directives, and every
`PreUp`/`PostUp`/`PreDown`/`PostDown` hook. The decrypted file is mode `0400`
under `/run/secrets`; it never enters the Nix store.

## WSL-first LAN pilot

Run the Windows host profile from the repository in WSL. Linux Git supplies the
reviewed commit, `wslpath` supplies the Windows path, and native Windows
PowerShell and WinGet perform the Windows work:

```bash
cd ~/develop/caz.nix
./bootstrap/windows.sh game-stream-host
./bootstrap/windows.sh game-stream-host --check
```

Approve the Windows UAC prompt. The first command is rerunnable and does not
generate a WireGuard key, create a tunnel, decrypt SOPS, or require an enrollment
response. It disables broad installer-created Sunshine firewall rules and opens
only the required Sunshine ports from `LocalSubnet4` on active Windows `Private`
wired or wireless networks.

On each Windows client, run the matching LAN stage from that device's WSL
checkout:

```bash
./bootstrap/windows.sh game-stream-client
./bootstrap/windows.sh game-stream-client --check
```

This installs Moonlight through WinGet, disables the installer's unrestricted
inbound application rule, and replaces it with a program-scoped rule limited to
`LocalSubnet4` on `Private` wired or wireless networks. It records the client
role without creating or starting a WireGuard tunnel. The host and client
commands both default to `Lan`; selecting `--stage remote` is always explicit.

Create the Sunshine Web UI credential at `https://localhost:47990`, pair a local
Moonlight client, and prove video, audio, input, display, and game launching over
the host's ordinary LAN address. Keep the gateway disabled and router port
closed during this stage.

## WSL-first remote enrollment workflow

Only after the LAN pilot passes, prepare each device from its own WSL checkout.
The launcher stages the reviewed source on the Windows filesystem and requests
UAC for the native Windows portion. `Prepare` installs WireGuard through WinGet
if necessary, generates the device key locally, and writes only a public
request back to WSL. Repeating it reproduces the same request instead of
silently rotating the key.

```bash
# On the living-room host:
./bootstrap/windows.sh game-stream-host \
  --prepare /tmp/host.game-stream-request.json

# On the laptop that will run Moonlight:
./bootstrap/windows.sh game-stream-client \
  --prepare /tmp/client.game-stream-request.json
```

Requests contain only a schema, generic role, random request ID, and public
key. The private key remains under an administrator-only ACL in ProgramData.
Copy the host request into `/tmp` on the SOPS-capable administrator laptop; the
client request is already there when that laptop is the first client. Do not
put either file in the repository.

From the repository root in WSL, enter the pinned development shell and make
the administrator SSH identity available to SOPS:

```bash
nix develop
export SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519"
```

Initialize the gateway and produce the host response once. Select a private
gateway `/32`, a distinct host `/32`, and a non-overlapping aligned `/28` for
up to fourteen clients. Check the home LAN, WSL, Docker, and likely remote LAN
routes first; if they overlap, select a different private block rather than
adding route workarounds.

Give the host the server's reserved home-LAN endpoint so its always-on tunnel
does not depend on router hairpin NAT. Give remote clients the dedicated
DNS-only public endpoint. Keep the private allocation and host's LAN endpoint
in the operator handoff and encrypted state; the public DNS name remains in the
reviewed DDNS declaration.

```bash
./scripts/game-stream-enrollment.sh init-host /tmp/host.game-stream-request.json \
  --host-endpoint SERVER_HOME_LAN_IPV4:51820 \
  --client-endpoint WIREGUARD_PUBLIC_NAME_OR_IP:51820 \
  --gateway-address GATEWAY_TUNNEL_IPV4/32 \
  --host-address HOST_TUNNEL_IPV4/32 \
  --client-pool CLIENT_ROLE_NETWORK_IPV4/28 \
  --output /tmp/host.game-stream-enrollment.json
```

Enroll each client. Repeating the same request returns the same `/32` and
response; it does not create a duplicate peer.

```bash
./scripts/game-stream-enrollment.sh add-client /tmp/client.game-stream-request.json \
  --output /tmp/client.game-stream-enrollment.json

./scripts/game-stream-enrollment.sh status
```

The administrator tool sends private material to SOPS through files rather
than command arguments. Its response contains the gateway public key,
endpoint, assigned address, narrow route, and request ID—but never either
device's private key or the gateway private key.

## Server activation

Commit the changed SOPS ciphertext before applying a client response that uses
the public endpoint. Configure the router's single UDP `51820` forward, enable
the gateway, merge the reviewed change, publish the immutable release, and
deploy it. The real addresses and keys remain encrypted in Git.

Only after the encrypted input and router forward are ready, change the
reviewed declaration in `hosts/homeserver/default.nix`:

```nix
homelab.gameStreamGateway = {
  enable = true;
  listenPort = 51820;
};
```

The same switch adds the dedicated game VPN name to the existing Cloudflare
DDNS declaration. Keep that record DNS-only: Cloudflare's ordinary proxy does
not proxy arbitrary WireGuard UDP. Before deployment, compare the router's WAN
IPv4 address to a public IPv4 lookup. If they differ, another NAT layer or
carrier-grade NAT must be resolved; adding more local port forwards cannot fix
it.

Wait until the public endpoint resolves in Windows before applying the client
response. Endpoint reachability and a handshake are not required for
enrollment, but WireGuard for Windows must resolve the endpoint while starting
its automatic tunnel service. A same-LAN handshake additionally requires
router hairpin NAT or split-horizon DNS; use direct LAN streaming while home.

After deployment, this command reports compliance without printing keys,
endpoints, addresses, or mappings:

```bash
sudo caz-game-stream-gateway report \
  /run/secrets/game-stream-gateway/config wg-game 51820
```

Copy each response to `/tmp` in the WSL distribution on the device that created
its matching request, then apply it from that checkout:

```bash
# Host device:
./bootstrap/windows.sh game-stream-host \
  --enroll /tmp/host.game-stream-enrollment.json

# Client device:
./bootstrap/windows.sh game-stream-client \
  --enroll /tmp/client.game-stream-enrollment.json
```

The WSL launcher supplies the reviewed commit from Linux Git. Its Windows
wrapper copies only the required source and one-time response into a restricted
local staging directory before elevation. The setup composes the WireGuard
document only inside administrator-only state, runs the declarative WinGet
profile, waits for WireGuard's DPAPI conversion, and removes the plaintext
configuration and both response copies after success. A failed run leaves the
original response and restricted recovery state available for a safe rerun.

Normal remote-stage convergence no longer needs an enrollment input. From WSL,
the preferred commands are:

```bash
./bootstrap/windows.sh game-stream-host --stage remote
./bootstrap/windows.sh game-stream-client --stage remote

./bootstrap/windows.sh game-stream-host --stage remote --check
./bootstrap/windows.sh game-stream-client --stage remote --check
```

The equivalent direct PowerShell commands remain available:

```powershell
.\bootstrap\game-stream-setup.ps1 -Role Host -SourceCommit REVIEWED_SOURCE_COMMIT
.\bootstrap\game-stream-setup.ps1 -Role Client -SourceCommit REVIEWED_SOURCE_COMMIT

.\bootstrap\game-stream-setup.ps1 -Role Host -Check
.\bootstrap\game-stream-setup.ps1 -Role Client -Check
```

The underlying profile records both the Git provenance commit and a digest of
the exact staged source bytes. The WSL launcher supplies the commit with Linux
Git. A direct PowerShell apply or enrollment requires `-SourceCommit` when
Windows Git is intentionally absent; Windows SSH keys are never required.

WinGet or Microsoft App Installer repair remains a manual prerequisite when
`winget.exe` itself is unavailable. No setup script downloads an unreviewed
installer as a fallback.

## Windows host policy

The host role:

- rejects Sunshine versions below stable `2026.516.143833`;
- disables WireGuard Local System command hooks;
- sets Sunshine UPnP off, Web UI access to localhost, and IPv4-only binding;
- disables app notifications on the Windows lock screen for the whole device;
- disables installer-created or other broad Sunshine inbound rules;
- permits tunnel streaming only from the reserved client `/28` on the exact
  `game-stream` interface and exact Sunshine executable/ports;
- permits direct LAN streaming only from `LocalSubnet4`, on wired or wireless
  interfaces, while the Windows network profile is `Private`;
- permits UDP `5353` only on that private LAN path for discovery;
- removes retired session-arbiter, handoff-control, and Sunshine preparation
  command state;
- configures Sunshine and the tunnel as automatic services; and
- records the reviewed source digest and `trusted-shared-console` session model.

Mark only the trusted home network `Private`. Direct LAN streaming remains
closed on `Public` networks. The local rule allows other devices on that home
subnet to reach Sunshine's paired-client protocol, but it does not expose the
Sunshine Web UI and it does not make those devices paired clients.

There is no remote mode, idle detector, user-switch hook, scheduled session
task, or per-play handoff. Subject to the pilot-proven display, power, reboot,
and Windows login behavior, an enrolled and paired client can connect without
someone preparing the host each time.

## Trusted shared-console boundary

V1 deliberately exposes the PC's single active Windows console. Sunshine
follows that console, and Moonlight pairing is host-wide rather than tied to a
Windows account. A paired user can therefore view and control the login screen
or whichever account is active, including the main account, subject to what the
pilot proves on the actual hardware. This behavior follows Sunshine's
documented [Windows service model](https://github.com/LizardByte/Sunshine/blob/master/tools/sunshinesvc.cpp).

This is a trust model, not account isolation. Anyone who controls both an
enrolled WireGuard client and its paired Moonlight state can act through the
active Windows session. If that session is an administrator account, they have
the same ordinary desktop access that account has. Treat the Windows login
credential, WireGuard key, and Moonlight pairing as sensitive credentials.

The configuration does not infer whether the local owner is active. A local
player and a remote player share the same display, audio, and input; they must
coordinate. Stopping Sunshine is an available manual emergency action, but the
declarative check correctly reports it as drift because V1 is always available.

Signing out of email, browsers, messaging, password managers, or other private
applications and requiring purchase confirmation in game stores remain useful
personal hygiene, not enforced boundaries. If technical account separation is
required later, use a dedicated VM or physical host instead of session-detection
scripts on the shared console. Do not expose RDP, WinRM, SMB, or Sunshine's Web
UI to make this design work.

## Local and remote pilot

Test in this order:

1. On the trusted home network, mark the host connection `Private` and pair
   Moonlight with the host's ordinary LAN IPv4 address.
2. Prove video, audio, controller/input, resolution, and game launch directly
   over LAN.
3. Deploy the encrypted gateway state and forward only UDP `51820` from the
   router to the server.
4. Put the client on a phone hotspot or another external network, confirm the
   WireGuard handshake, and add the host tunnel `/32` to Moonlight.
5. Prove streaming works and confirm the client cannot reach the gateway, host
   LAN address, another client, or another home device through the tunnel.
6. Stream at the intended resolution, frame rate, and bitrate for at least
   fifteen minutes. On a PC client, enable Moonlight's statistics with
   `Ctrl+Alt+Shift+S`. Network-dropped frames should remain effectively zero,
   jitter should stay near or below 1 ms without recurring spikes, latency
   should remain stable, and the gateway must remain well below CPU and NIC
   saturation. A visible stutter or input regression fails the pilot even when
   the services report healthy.
7. Record power, display/EDID, reboot, Windows login-screen, and simultaneous
   local/remote behavior on the real hardware.

A same-LAN tunnel test is optional and does not replace step 4. It may require
router hairpin NAT or split-horizon DNS even when the external path is correct.
It is useful for comparing direct-LAN statistics with the relayed path while
removing most Internet variability. The expected relay cost is sub-millisecond;
investigate a repeatable 1-2 ms or larger increase before accepting it.

## Revocation and rotation

Find the opaque request ID without printing topology or keys:

```bash
./scripts/game-stream-enrollment.sh status
```

Remove it from the encrypted gateway state, commit and deploy the new
ciphertext, and remove the same device from Sunshine's paired clients:

```bash
./scripts/game-stream-enrollment.sh remove-client CLIENT_REQUEST_ID
```

Only after gateway revocation, explicitly remove local tunnel material on the
retired device from WSL:

```bash
./bootstrap/windows.sh game-stream-client --reset-enrollment
```

Rotation is explicit: revoke the old request, reset that device, run `Prepare`
again, and enroll its new request. No rerunnable convergence command silently
changes a key or identity.

## Remaining manual ceremonies

These remain intentionally manual:

- repairing or installing Microsoft App Installer when WinGet is absent;
- selecting the private tunnel ranges and public endpoint;
- router UDP forwarding;
- committing, releasing, and deploying changed SOPS ciphertext;
- Sunshine Web UI credentials and Moonlight PIN pairing;
- deciding how the trusted user unlocks the shared Windows account;
- game-account sign-in, MFA, licenses, and purchase confirmation;
- EDID/dummy-plug and host power handling; and
- recording pilot evidence before relying on unattended access.

Do not add declarative power/display changes until the hardware pilot shows
which settings are actually necessary.

## Primary references

- WireGuard cryptokey routing and configuration scope:
  <https://www.wireguard.com/>
- WireGuard NAT keepalive guidance:
  <https://www.wireguard.com/quickstart/>
- WireGuard protocol and performance paper:
  <https://www.wireguard.com/papers/wireguard.pdf>
- Official WireGuard for Windows enterprise/service behavior:
  <https://git.zx2c4.com/wireguard-windows/about/docs/enterprise.md>
- Moonlight connection statistics:
  <https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions>
- Sunshine network and MTU testing:
  <https://github.com/LizardByte/Sunshine/blob/master/docs/troubleshooting.md>
- NIST zero-trust resource and least-privilege model:
  <https://csrc.nist.gov/pubs/sp/800/207/final>
- CISA microsegmentation guidance:
  <https://www.cisa.gov/news-events/alerts/2025/07/29/cisa-releases-part-one-zero-trust-microsegmentation-guidance>
- Cloudflare DNS proxy limitations:
  <https://developers.cloudflare.com/dns/proxy-status/limitations/>
