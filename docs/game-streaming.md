# Declarative private game streaming

The repository defines three reusable roles without assigning them to a
physical device:

- `game-stream-gateway`: a disabled-by-default NixOS WireGuard hub;
- `game-stream-host`: Sunshine, WireGuard, and narrow host security policy;
- `game-stream-client`: Moonlight, WireGuard, and narrow client routing policy.

Applying one of these roles is always explicit. Merely evaluating the flake or
checking out this repository does not run WinGet, install software, create an
account, open a port, or enroll a peer.

The declarative layer does not prove that a route is playable. Issue #63's
local, external, negative-access, performance, headless-display, session, and
revocation tests remain required before enabling the production gateway.

## Private input boundary

Never commit real addresses, endpoints, keys, peer mappings, account names, or
device names. The gateway consumes one SOPS value named
`gameStreamGatewayConfig`; Windows consumes a one-time local enrollment file.

The decrypted gateway value is an ordinary `wg-quick` document in this fixed
role order:

```ini
[Interface]
Address = GATEWAY_TUNNEL_IPV4/32
PrivateKey = GATEWAY_PRIVATE_KEY
ListenPort = 51820

# First peer is always the generic host role.
[Peer]
PublicKey = HOST_PUBLIC_KEY
AllowedIPs = HOST_TUNNEL_IPV4/32

# Second peer is always the generic client role.
[Peer]
PublicKey = CLIENT_PUBLIC_KEY
AllowedIPs = CLIENT_TUNNEL_IPV4/32
```

The runtime validator requires one gateway `/32`, exactly two distinct peer
`/32` routes, and the reviewed listener. It rejects `SaveConfig`, DNS/table
changes, and every `PreUp`/`PostUp`/`PreDown`/`PostDown` hook. The decrypted
file is rendered mode `0400` under `/run/secrets`; it never enters the Nix
store.

Edit the existing encrypted file with SOPS and add the multiline value:

```bash
nix develop
SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519" \
  sops secrets/homeserver.yaml
```

Only after the private input and router's single UDP forward are ready, enable
the gateway in a private deployment overlay or the host configuration:

```nix
homelab.gameStreamGateway = {
  enable = true;
  listenPort = 51820;
};
```

The gateway treats `wg-game` as untrusted before the broader RFC1918 policy.
It drops all tunnel traffic to the gateway and LAN. Forwarding permits only
the client role to reach the host role on TCP `47984`, `47989`, and `48010`
and UDP `47998-48000`, `48002`, and `48010`; the host may return only
established traffic. WireGuard's exact `AllowedIPs` rejects spoofed role
sources. A persistent guard chain drops tunnel forwarding while the exact
role policy is absent, stopped, or being rebuilt. The guard remains when the
general firewall service stops, so neither service lifecycle can make tunnel
traffic fall through to broader forwarding rules.

After deployment, this report prints counts and compliance categories without
printing keys, endpoints, addresses, or peer mappings:

```bash
sudo caz-game-stream-gateway report \
  /run/secrets/game-stream-gateway/config wg-game 51820
```

## Windows enrollment documents

Generate each Windows enrollment outside the repository. Each file must have:

- one interface IPv4 `/32` and private key;
- one gateway peer and endpoint;
- exactly one opposite-role IPv4 `/32` in `AllowedIPs`;
- `PersistentKeepalive = 25`;
- no default, LAN, DNS, table, save, or command-hook directive.

Review the source commit before applying. No device, person, Windows account,
or private network value is selected in the repository.

```powershell
$commit = git rev-parse HEAD

# Intended host only. The input file is deleted after a successful DPAPI import.
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\bootstrap\windows.ps1 `
  -Profile game-stream-host `
  -GameStreamEnrollmentFile C:\private\game-stream-host.conf `
  -SourceCommit $commit

# Intended Windows client only.
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\bootstrap\windows.ps1 `
  -Profile game-stream-client `
  -GameStreamEnrollmentFile C:\private\game-stream-client.conf `
  -SourceCommit $commit
```

The bootstrap copies every elevated payload into a restricted local staging
directory. WireGuard's manager converts the one-time plaintext enrollment into
its machine-protected `.conf.dpapi` format, deletes the staged plaintext, and
runs the official `WireGuardTunnel$game-stream` service. A failed apply retains
the caller's source file for recovery; secure it and rerun. A successful apply
deletes it. Once DPAPI enrollment exists, omit the enrollment argument on
later applies; replacement requires an explicit revocation first.

The host policy:

- rejects Sunshine versions below stable `2026.516.143833`;
- disables WireGuard Local System command hooks;
- sets Sunshine UPnP off, Web UI access to localhost, and IPv4-only binding;
- disables app notifications on the Windows lock screen for the whole device;
- disables installer-created or other broad Sunshine inbound rules;
- permits only the enrolled client `/32`, the `game-stream` interface, the
  Sunshine executable, and the exact streaming ports;
- removes retired session-arbiter, handoff-control, and Sunshine preparation
  command state;
- configures Sunshine as an automatic, running service so the shared console is
  available without a per-session setup step;
- records a digest of the exact profile, capability, and helper bytes being
  applied; and
- records `trusted-shared-console` as the deliberate Windows session model.

There is no remote mode, idle detector, user-switch hook, scheduled session
task, or per-play handoff. The WireGuard tunnel and Sunshine service start
automatically. Subject to the pilot-proven display, power, reboot, and Windows
login behavior, an enrolled and paired client can connect without anyone first
preparing the host.

Check without installing, importing, or changing state:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\bootstrap\windows.ps1 `
  -Profile game-stream-host `
  -Check
```

Compliance output uses `compliant`, `drifted`, `manual ceremony required`, or
`environmental warning`. It verifies the applied source digest but reports only
the generic role and reviewed source commit. It never prints keys, endpoints,
addresses, peer mappings, or the source digest.

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
credential, WireGuard key, and Moonlight pairing as sensitive credentials, and
revoke both network enrollment and pairing when a client is lost or retired.

The configuration does not try to infer whether the local owner is active. A
local player and a remote player would share the same display, audio, and input;
they must coordinate who is using the PC. Stopping Sunshine is an available
manual emergency action, but the declarative check will correctly report that
as drift because the intended v1 state is always available.

Signing out of email, browsers, messaging, password managers, or other private
applications before adopting this model is useful personal hygiene, but it is
not an enforced security boundary. Requiring purchase confirmation in game
stores is similarly independent of this repository. If future requirements
need technical separation from the main account, the next architecture should
be a dedicated VM or physical host rather than session-detection scripts on the
shared console. Do not expose RDP, WinRM, SMB, or Sunshine's Web UI to make this
design work. The host role also enables Microsoft's device policy to
[suppress lock-screen app notifications](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-windowslogon#disablelockscreenappnotifications).

## Manual ceremonies and pilot-owned state

These remain deliberate manual steps:

- generating keys and private enrollment files;
- router UDP forwarding;
- deciding how the trusted remote user will unlock or sign into the shared
  Windows account;
- Sunshine Web UI credentials and Moonlight PIN pairing;
- game-account sign-in, MFA, and licenses;
- EDID/dummy-plug handling;
- signing out of sensitive applications and enabling purchase confirmation as
  desired for this shared device;
- recording tested power, display, reboot, login-screen, and simultaneous local
  and remote behavior;
- two-step revocation: remove the WireGuard enrollment and Sunshine pairing.

Do not add declarative power/display changes until the pilot has shown exactly
which settings are necessary.
