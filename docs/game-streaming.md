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

## Rerunnable enrollment workflow

Run the Windows commands from PowerShell as Administrator. `Prepare` installs
WireGuard through WinGet if necessary, generates the device key locally, and
writes a public request. Repeating it reproduces the same request instead of
silently rotating the key.

```powershell
# On the living-room host:
.\bootstrap\game-stream-setup.ps1 `
  -Role Host `
  -Prepare `
  -Output "$env:USERPROFILE\Downloads\host.game-stream-request.json"

# On each laptop independently:
.\bootstrap\game-stream-setup.ps1 `
  -Role Client `
  -Prepare `
  -Output "$env:USERPROFILE\Downloads\client.game-stream-request.json"
```

Requests contain only a schema, generic role, random request ID, and public
key. The private key remains under an administrator-only ACL in ProgramData.
Copy each request to the administrator's WSL environment; do not put it in the
repository.

From the repository root in WSL, enter the pinned development shell and make
the administrator SSH identity available to SOPS:

```bash
nix develop
export SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519"
```

Initialize the gateway and produce the host response once. Select a private
gateway `/32`, a distinct host `/32`, and a non-overlapping aligned `/28` for
up to fourteen clients. Give the host the server's home-LAN endpoint so the
always-on host tunnel does not depend on router hairpin NAT; give clients the
public endpoint used away from home. Both ports must equal `--listen-port`.

```bash
./scripts/game-stream-enrollment.sh init-host /private/host.game-stream-request.json \
  --host-endpoint SERVER_HOME_LAN_IPV4:51820 \
  --client-endpoint WIREGUARD_PUBLIC_NAME_OR_IP:51820 \
  --gateway-address GATEWAY_TUNNEL_IPV4/32 \
  --host-address HOST_TUNNEL_IPV4/32 \
  --client-pool CLIENT_ROLE_NETWORK_IPV4/28 \
  --output /private/host.game-stream-enrollment.json
```

Enroll each client. Repeating the same request returns the same `/32` and
response; it does not create a duplicate peer.

```bash
./scripts/game-stream-enrollment.sh add-client /private/client.game-stream-request.json \
  --output /private/client.game-stream-enrollment.json

./scripts/game-stream-enrollment.sh status
```

The administrator tool sends private material to SOPS through files rather
than command arguments. Its response contains the gateway public key,
endpoint, assigned address, narrow route, and request ID—but never either
device's private key or the gateway private key.

Copy the appropriate response back to the device that created its matching
request, then apply it:

```powershell
# Host:
.\bootstrap\game-stream-setup.ps1 `
  -Role Host `
  -Enroll "$env:USERPROFILE\Downloads\host.game-stream-enrollment.json"

# Client:
.\bootstrap\game-stream-setup.ps1 `
  -Role Client `
  -Enroll "$env:USERPROFILE\Downloads\client.game-stream-enrollment.json"
```

The wrapper composes the WireGuard document only inside its restricted local
state, runs the existing declarative WinGet profile, waits for WireGuard's
DPAPI conversion, and removes the plaintext configuration and response after
success. A failed run retains only the restricted recovery material needed for
a safe rerun.

Normal convergence no longer needs an enrollment input:

```powershell
.\bootstrap\game-stream-setup.ps1 -Role Host
.\bootstrap\game-stream-setup.ps1 -Role Client

.\bootstrap\game-stream-setup.ps1 -Role Host -Check
.\bootstrap\game-stream-setup.ps1 -Role Client -Check
```

The underlying profile records the reviewed Git commit. A normal clone derives
it from Git. If the source was copied without `.git` metadata, pass the exact
reviewed 40-character commit with `-SourceCommit` on apply or enrollment runs.

WinGet or Microsoft App Installer repair remains a manual prerequisite when
`winget.exe` itself is unavailable. No setup script downloads an unreviewed
installer as a fallback.

## Server activation

Commit the changed SOPS ciphertext, merge it, publish the immutable release,
and deploy that release before expecting a new remote client to connect. The
real addresses and keys remain encrypted in Git.

Only after the private input and router's single UDP `51820` forward are
ready, enable the gateway in the host configuration or a private deployment
overlay:

```nix
homelab.gameStreamGateway = {
  enable = true;
  listenPort = 51820;
};
```

After deployment, this command reports compliance without printing keys,
endpoints, addresses, or mappings:

```bash
sudo caz-game-stream-gateway report \
  /run/secrets/game-stream-gateway/config wg-game 51820
```

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
6. Record power, display/EDID, reboot, Windows login-screen, and simultaneous
   local/remote behavior on the real hardware.

A same-LAN tunnel test is optional and does not replace step 4. It may require
router hairpin NAT or split-horizon DNS even when the external path is correct.

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
retired device:

```powershell
.\bootstrap\game-stream-setup.ps1 -Role Client -ResetEnrollment
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
